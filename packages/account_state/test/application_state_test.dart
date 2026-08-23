import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A [GraphTransport] that records outgoing requests and replays a response
/// from an injected router — the "recording fake transport" the issue's test
/// plan calls for.
class _RecordingGraphTransport implements GraphTransport {
  _RecordingGraphTransport(this._route);

  final List<GraphRequest> requests = [];
  final GraphResponse Function(GraphRequest) _route;

  @override
  Future<GraphResponse> send(GraphRequest request) async {
    requests.add(request);
    return _route(request);
  }
}

GraphResponse _jsonOk(Object body) => GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );

WisaSnapshot _emptyWisa() => WisaSnapshot(
      fetchedAt: DateTime.utc(2026),
      students: const [],
      staff: const [],
      classGroups: const [],
      schools: const [],
    );

SmartschoolSnapshot _emptySmartschool() => SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026),
      groups: const [],
      accounts: const [],
      memberships: const [],
    );

AzureSnapshot _emptyAzure() => AzureSnapshot(
      fetchedAt: DateTime.utc(2026),
      users: const [],
      groups: const [],
    );

void main() {
  group('ApplicationState.sync dispatch', () {
    late ApplicationState app;
    late List<core.Origin> synced;

    setUp(() {
      synced = [];
      SystemState<S> record<S extends core.Snapshot>(
        core.Origin system,
        S Function() make,
      ) =>
          SystemState<S>(
            system: system,
            syncer: (_, {bool fullRead = false}) async {
              synced.add(system);
              return make();
            },
          );

      app = ApplicationState(
        wisa: record(core.Origin.wisa, _emptyWisa),
        smartschool: record(core.Origin.smartschool, _emptySmartschool),
        azure: record(core.Origin.azure, _emptyAzure),
      );
    });

    test('routes each concrete system to its own SystemState', () async {
      final w = await app.sync(core.Origin.wisa);
      final s = await app.sync(core.Origin.smartschool);
      final a = await app.sync(core.Origin.azure);

      expect(w, isA<WisaSnapshot>());
      expect(s, isA<SmartschoolSnapshot>());
      expect(a, isA<AzureSnapshot>());
      expect(synced,
          [core.Origin.wisa, core.Origin.smartschool, core.Origin.azure]);
      expect(app.wisa.lastSync, isNotNull);
    });

    test('rejects the non-syncable wildcards', () {
      expect(() => app.sync(core.Origin.all), throwsArgumentError);
      expect(() => app.sync(core.Origin.other), throwsArgumentError);
      expect(synced, isEmpty);
    });
  });

  group('azureSyncer + SystemState (delta from day one, PAIN-2)', () {
    // Minimal Graph router: no groups (skips member fan-out), one user on the
    // full read, an empty delta on the incremental pass.
    GraphResponse route(GraphRequest req) {
      final path = req.url.path;
      final q = req.url.queryParameters;
      if (path.contains('groups')) return _jsonOk({'value': <Object?>[]});
      if (path.contains('users/delta')) {
        if (q[r'$deltatoken'] == 'latest') {
          return _jsonOk({
            '@odata.deltaLink':
                'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=PRIMED1',
            'value': <Object?>[],
          });
        }
        return _jsonOk({
          '@odata.deltaLink':
              'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=PRIMED2',
          'value': <Object?>[],
        });
      }
      // Full /users bulk read (single page).
      return _jsonOk({
        'value': [
          {
            'id': '00000000-0000-0000-0000-000000000001',
            'userPrincipalName': 'ann@student.school.example',
            'companyName': 'GBS',
            'accountEnabled': true,
          },
        ],
      });
    }

    late _RecordingGraphTransport transport;
    late SystemState<AzureSnapshot> azure;

    setUp(() {
      transport = _RecordingGraphTransport(route);
      final connector = AzureConnector(
        credentials: AzureCredentials(
          clientId: 'c',
          tenantId: 't',
          azureDomain: 'school.example',
          schoolPrefix: 'GBS',
        ),
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
      );
      azure = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(connector),
      );
    });

    test('first sync does a full read, stores the snapshot and stamps lastSync',
        () async {
      final snapshot = await azure.sync();

      expect(snapshot.users, hasLength(1));
      expect(snapshot.deltaToken, 'PRIMED1', reason: 'primed for next time');
      expect(azure.snapshot, same(snapshot));
      expect(azure.lastSync, snapshot.fetchedAt);

      // The full read hit /users with a $filter, not an unfiltered delta.
      final bulk =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/users'));
      expect(bulk.url.queryParameters[r'$filter'], isNotNull);
    });

    test('the next sync threads the primed token into /users/delta', () async {
      await azure.sync();
      final snapshot = await azure.sync();

      final deltaCall = transport.requests.lastWhere(
        (r) => r.url.path.contains('users/delta'),
      );
      expect(deltaCall.url.queryParameters[r'$deltatoken'], 'PRIMED1',
          reason: 'SystemState fed the stored snapshot back to azureSyncer');
      expect(snapshot.deltaToken, 'PRIMED2');
      expect(azure.lastSync, snapshot.fetchedAt);
    });

    test('the expected employeeIds are read at sync time, not at wiring time',
        () async {
      // The seam that lets the Azure pull see the WISA snapshot this pass just
      // produced (#224): the syncer is built before WISA has synced, so the ids
      // must come from a callback, not a captured value.
      var ids = <String>[];
      final state = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(
          AzureConnector(
            credentials: AzureCredentials(
              clientId: 'c',
              tenantId: 't',
              azureDomain: 'school.example',
              schoolPrefix: 'GBS',
            ),
            authProvider: const StaticAuthProvider('T'),
            transport: transport,
          ),
          expectedEmployeeIds: () => ids,
        ),
      );

      // Nothing expected yet ⇒ no employeeId lookup at all.
      await state.sync();
      expect(
        transport.requests.where(
          (r) => (r.url.queryParameters[r'$filter'] ?? '')
              .startsWith('employeeId in'),
        ),
        isEmpty,
      );

      // The WISA pull lands between the two syncs; the next Azure pass sees it.
      ids = <String>['W7'];
      await state.sync();
      expect(
        transport.requests
            .map((r) => r.url.queryParameters[r'$filter'])
            .whereType<String>()
            .where((f) => f.startsWith('employeeId in')),
        ["employeeId in ('W7')"],
      );
    });

    test(
        'the expected class-group addresses are read at sync time, with the '
        'prefix this pass resolved (#280)', () async {
      // The group half of the same seam. The addresses are `<PREFIX>-<KLAS>`,
      // so the callback is handed the prefix the pass actually pulled with —
      // it cannot close over a frozen one any more than the pull can.
      var prefix = 'GBS';
      var nicknames = <String>[];
      final seenPrefixes = <String>[];
      final state = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(
          AzureConnector(
            credentials: AzureCredentials(
              clientId: 'c',
              tenantId: 't',
              azureDomain: 'school.example',
              schoolPrefix: 'GBS',
            ),
            authProvider: const StaticAuthProvider('T'),
            transport: transport,
          ),
          expectedGroupMailNicknames: (p) {
            seenPrefixes.add(p);
            return nicknames;
          },
          schoolPrefix: () => prefix,
        ),
      );

      // Nothing expected yet ⇒ no nickname lookup at all.
      await state.sync();
      expect(
        transport.requests.where(
          (r) => (r.url.queryParameters[r'$filter'] ?? '')
              .startsWith('mailNickname in'),
        ),
        isEmpty,
      );

      // The WISA pull lands between the two syncs, and the operator moves the
      // prefix; the next Azure pass asks about the *new* school's addresses.
      prefix = 'SSM';
      nicknames = <String>['SSM-5WW1'];
      await state.sync();
      expect(seenPrefixes, ['GBS', 'SSM']);
      expect(
        transport.requests
            .map((r) => r.url.queryParameters[r'$filter'])
            .whereType<String>()
            .where((f) => f.startsWith('mailNickname in')),
        ["mailNickname in ('SSM-5WW1')"],
      );
    });

    test(
        'the school prefix is read at sync time too, not at wiring time (#246)',
        () async {
      // The prefix scopes the whole pull, and the operator can change it in
      // Instellingen mid-session. Before #246 the connector's credentials —
      // frozen when bootstrap built them — were the only answer, so a saved
      // prefix took a relaunch.
      var prefix = 'GBS';
      final state = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(
          AzureConnector(
            credentials: AzureCredentials(
              clientId: 'c',
              tenantId: 't',
              azureDomain: 'school.example',
              schoolPrefix: 'FROZEN',
            ),
            authProvider: const StaticAuthProvider('T'),
            transport: transport,
          ),
          schoolPrefix: () => prefix,
        ),
      );

      await state.sync();
      final first =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/users'));
      expect(first.url.queryParameters[r'$filter'], contains('GBS'));
      expect(first.url.queryParameters[r'$filter'], isNot(contains('FROZEN')));

      prefix = 'SSM';
      await state.sync();
      final second =
          transport.requests.lastWhere((r) => r.url.path.endsWith('/users'));
      expect(second.url.queryParameters[r'$filter'], contains('SSM'));
    });

    test(
        'a changed prefix re-reads in full instead of deltaing over the old '
        'school (#246)', () async {
      // `/users/delta` returns tenant changes filtered client-side by prefix, so
      // an incremental pass would layer the *new* school's changes on the *old*
      // school's user list — a snapshot mixing two schools that then persists to
      // the cold store and materializes for the whole team. Dropping the token
      // costs one full read and cannot lie.
      var prefix = 'GBS';
      final state = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(
          AzureConnector(
            credentials: AzureCredentials(
              clientId: 'c',
              tenantId: 't',
              azureDomain: 'school.example',
              schoolPrefix: 'GBS',
            ),
            authProvider: const StaticAuthProvider('T'),
            transport: transport,
          ),
          schoolPrefix: () => prefix,
        ),
      );

      await state.sync();
      // Unchanged prefix ⇒ the ordinary incremental pass, as before #246.
      await state.sync();
      expect(
        transport.requests
            .lastWhere((r) => r.url.path.contains('users/delta'))
            .url
            .queryParameters[r'$deltatoken'],
        'PRIMED1',
      );

      final bulkReadsBefore =
          transport.requests.where((r) => r.url.path.endsWith('/users')).length;
      prefix = 'SSM';
      final snapshot = await state.sync();

      final bulkReadsAfter =
          transport.requests.where((r) => r.url.path.endsWith('/users')).length;
      expect(bulkReadsAfter, bulkReadsBefore + 1,
          reason: 'the prefix moved ⇒ a full read, not a delta');
      expect(
        transport.requests
            .lastWhere((r) => r.url.path.endsWith('/users'))
            .url
            .queryParameters[r'$filter'],
        contains('SSM'),
      );
      expect(snapshot.deltaToken, 'PRIMED1',
          reason: 'the full read primes a fresh token for the new prefix');

      // …and the pass after that is incremental again: only the *change* forces
      // the full read, not the new prefix forever.
      final beforeSteady =
          transport.requests.where((r) => r.url.path.endsWith('/users')).length;
      await state.sync();
      expect(
        transport.requests.where((r) => r.url.path.endsWith('/users')).length,
        beforeSteady,
      );
    });
  });

  group('azureSyncer keeps a departed staff member visible (#269)', () {
    // Anna Smit's Office 365 account carries our prefix *second* in the comma
    // list other software maintains (`SSM,GBS`, #237), so the bulk read's
    // `startswith(department,'GBS')` cannot see it and #268 ruled that leg
    // cannot be widened. She has now left WISA, so `managedStaffEmployeeIds`
    // names her no more either — and the account still exists in the tenant.
    late _RecordingGraphTransport transport;

    /// The `employeeId in (…)` filters this pass issued, in order.
    List<String> lookups() => transport.requests
        .map((r) => r.url.queryParameters[r'$filter'])
        .whereType<String>()
        .where((f) => f.startsWith('employeeId in'))
        .toList();

    GraphResponse route(GraphRequest req) {
      final path = req.url.path;
      if (path.contains('groups')) return _jsonOk({'value': <Object?>[]});
      if (path.contains('users/delta')) {
        return _jsonOk({
          '@odata.deltaLink':
              'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=NEXT',
          'value': <Object?>[],
        });
      }
      final filter = req.url.queryParameters[r'$filter'] ?? '';
      if (filter.startsWith('employeeId in')) {
        return _jsonOk({
          'value': filter.contains("'42'")
              ? [
                  {
                    'id': 'az-staff',
                    'userPrincipalName': 'anna.smit@school.example',
                    'employeeId': '42',
                    'displayName': 'Smit Anna',
                    'department': 'SSM,GBS',
                    'accountEnabled': true,
                  },
                ]
              : <Object?>[],
        });
      }
      // The school-scoped bulk read: blind to her, which is the whole problem.
      return _jsonOk({'value': <Object?>[]});
    }

    AzureSnapshot held({String? deltaToken}) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026),
          deltaToken: deltaToken,
          users: const [
            AzureUser(
              id: 'az-staff',
              upn: 'anna.smit@school.example',
              employeeId: '42',
              displayName: 'Smit Anna',
              department: 'SSM,GBS',
            ),
          ],
          groups: const [],
        );

    SystemState<AzureSnapshot> stateFor(
      AzureSnapshot? initial, {
      String Function()? prefix,
    }) =>
        SystemState<AzureSnapshot>(
          system: core.Origin.azure,
          initial: initial,
          syncer: azureSyncer(
            AzureConnector(
              credentials: AzureCredentials(
                clientId: 'c',
                tenantId: 't',
                azureDomain: 'school.example',
                schoolPrefix: 'GBS',
              ),
              authProvider: const StaticAuthProvider('T'),
              transport: transport,
            ),
            // WISA no longer lists her, so the caller's set is empty — exactly
            // the state that used to lose her.
            expectedEmployeeIds: () => const <String>[],
            schoolPrefix: prefix,
          ),
        );

    setUp(() => transport = _RecordingGraphTransport(route));

    test('a full read looks her up again from the snapshot in hand', () async {
      // The full read is where she was lost: the bulk `$filter` returns nothing
      // for her and the previous user list is not carried over, so before this
      // she simply ceased to exist as far as the app was concerned.
      final snapshot = await stateFor(held()).sync();

      expect(lookups(), ["employeeId in ('42')"]);
      expect(snapshot.users.map((u) => u.id), ['az-staff'],
          reason: 'the account the linker needs to raise a deletion on');
    });

    test('an incremental pass costs no extra lookup', () async {
      // She is already in the user list the delta builds on, so the connector
      // finds her accounted for. Remembering her must not add Graph traffic to
      // the pass that never lost her.
      final snapshot = await stateFor(held(deltaToken: 'AZ-TOKEN')).sync();

      expect(lookups(), isEmpty);
      expect(snapshot.users.map((u) => u.id), ['az-staff']);
    });

    test('a moved prefix drops the memory with the rest of the snapshot',
        () async {
      // A snapshot read under another prefix describes another school —
      // token, users and the ids remembered from them alike (#246).
      var prefix = 'GBS';
      final state = stateFor(held(), prefix: () => prefix);
      await state.sync();
      expect(lookups(), ["employeeId in ('42')"]);

      prefix = 'SSM';
      await state.sync();
      expect(lookups(), ["employeeId in ('42')"],
          reason: 'no second lookup: GBS staff are not SSM\'s to remember');
    });

    test('a forced re-read drops the token but keeps remembering her (#316)',
        () async {
      // The interaction the drift pass turns on: `fullRead` drops the *resume
      // point* and nothing else. A re-read that dropped the snapshot too — the
      // way a moved prefix does — would forget the very ids the back-fill has to
      // ask about, and the account would leave the app's view on the pass meant
      // to repair it.
      final snapshot =
          await stateFor(held(deltaToken: 'AZ-TOKEN')).sync(fullRead: true);

      expect(
        transport.requests.where((r) => r.url.path.contains('users/delta')).map(
              (r) => r.url.queryParameters[r'$deltatoken'],
            ),
        isNot(contains('AZ-TOKEN')),
        reason: 'the stored token is not resumed from',
      );
      expect(
        transport.requests
            .where((r) => r.url.path.endsWith('/users'))
            .map((r) => r.url.queryParameters[r'$filter'])
            .where((f) => !(f ?? '').startsWith('employeeId in')),
        ["companyName eq 'GBS' or startswith(department,'GBS')"],
        reason: 'the school-scoped bulk read ran instead',
      );
      expect(lookups(), ["employeeId in ('42')"],
          reason: 'previous still went in, so #269 still remembers her');
      expect(snapshot.users.map((u) => u.id), ['az-staff']);
      expect(snapshot.deltaToken, 'NEXT',
          reason: 'the re-read mints a fresh token rather than carrying one');
    });
  });

  group('managedStudentEmployeeIds (#224)', () {
    WisaStudent student(String id, {int schoolId = 1}) => WisaStudent(
          wisaId: core.WisaId(id),
          classGroup: '1A',
          classSubGroup: '',
          name: 'Doe',
          firstName: 'Jane',
          preferredName: '',
          birthDate: DateTime.utc(2010),
          stemId: '',
          gender: core.Gender.female,
          nationalId: '',
          birthPlace: '',
          nationality: '',
          address: const core.Address(
            street: '',
            houseNumber: '',
            postalCode: '',
            city: '',
            country: '',
          ),
          classChange: DateTime.utc(2026),
          schoolId: schoolId,
        );

    WisaSnapshot snap(
      List<WisaStudent> students, {
      List<WisaSchool> schools = const [],
    }) =>
        WisaSnapshot(
          fetchedAt: DateTime.utc(2026),
          students: students,
          staff: const [],
          classGroups: const [],
          schools: schools,
        );

    test('no snapshot yet ⇒ nothing expected', () {
      expect(managedStudentEmployeeIds(null), isEmpty);
    });

    test('scopes to the managed schools from Settings', () {
      final ids = managedStudentEmployeeIds(
        snap([student('W1'), student('W2', schoolId: 2)]),
        ourSchoolIds: const {1},
      );
      // A sibling school's student is none of our business, and looking their
      // account up would grow the bounded pull for nothing.
      expect(ids, {'W1'});
    });

    test('the snapshot\'s school list never narrows the scope (#286)', () {
      // Ownership lives in Settings alone; a school list on the snapshot says
      // nothing about which schools are ours, so an unnamed managed set still
      // means every student counts.
      final ids = managedStudentEmployeeIds(
        snap(
          [student('W1'), student('W2', schoolId: 2)],
          schools: const [
            WisaSchool(id: 1, name: '', code: ''),
            WisaSchool(id: 2, name: '', code: ''),
          ],
        ),
      );
      expect(ids, {'W1', 'W2'});
    });

    test('an unconfigured ownership set means every student counts', () {
      final ids = managedStudentEmployeeIds(
        snap([student('W1'), student('W2', schoolId: 2)]),
      );
      expect(ids, {'W1', 'W2'});
    });
  });

  group('managedClassGroupMailNicknames (#280)', () {
    WisaStudent student(
      String id, {
      String classGroup = '1A',
      String classSubGroup = '',
      int schoolId = 1,
    }) =>
        WisaStudent(
          wisaId: core.WisaId(id),
          classGroup: classGroup,
          classSubGroup: classSubGroup,
          name: 'Doe',
          firstName: 'Jane',
          preferredName: '',
          birthDate: DateTime.utc(2010),
          stemId: '',
          gender: core.Gender.female,
          nationalId: '',
          birthPlace: '',
          nationality: '',
          address: const core.Address(
            street: '',
            houseNumber: '',
            postalCode: '',
            city: '',
            country: '',
          ),
          classChange: DateTime.utc(2026),
          schoolId: schoolId,
        );

    WisaSnapshot snap(
      List<WisaStudent> students, {
      List<WisaSchool> schools = const [],
    }) =>
        WisaSnapshot(
          fetchedAt: DateTime.utc(2026),
          students: students,
          staff: const [],
          classGroups: const [],
          schools: schools,
        );

    test('no snapshot yet ⇒ nothing expected', () {
      expect(
          managedClassGroupMailNicknames(null, schoolPrefix: 'GBS'), isEmpty);
    });

    test('one address per class, named after the bare class', () {
      // Sub-groups share their parent class's one group, so `2F ECO` and
      // `2F MAW` ask about `GBS-2F` once — never `GBS-2F ECO`.
      expect(
        managedClassGroupMailNicknames(
          snap([
            student('W1'),
            student('W2', classGroup: '2F', classSubGroup: 'ECO'),
            student('W3', classGroup: '2F', classSubGroup: 'MAW'),
          ]),
          schoolPrefix: 'GBS',
        ),
        {'GBS-1A', 'GBS-2F'},
      );
    });

    test('scopes to the managed schools, like the account back-fill', () {
      expect(
        managedClassGroupMailNicknames(
          snap([student('W1'), student('W2', classGroup: '9Z', schoolId: 2)]),
          schoolPrefix: 'GBS',
          ourSchoolIds: const {1},
        ),
        {'GBS-1A'},
      );
    });

    test('the snapshot\'s school list never narrows the scope (#286)', () {
      expect(
        managedClassGroupMailNicknames(
          snap(
            [student('W1'), student('W2', classGroup: '9Z', schoolId: 2)],
            schools: const [
              WisaSchool(id: 1, name: '', code: ''),
              WisaSchool(id: 2, name: '', code: ''),
            ],
          ),
          schoolPrefix: 'GBS',
        ),
        {'GBS-1A', 'GBS-9Z'},
      );
    });

    test('an unconfigured prefix asks about nothing', () {
      // There is no `<PREFIX>-<KLAS>` to ask about, and a bare `-1A` would be
      // somebody else's address.
      expect(
        managedClassGroupMailNicknames(snap([student('W1')]),
            schoolPrefix: ' '),
        isEmpty,
      );
    });

    test('a name Graph would reject as a nickname is dropped', () {
      // The plan refuses to propose such a create at all
      // (`isValidMailNickname`), so asking about its address would buy nothing.
      expect(
        managedClassGroupMailNicknames(
          snap([student('W1', classGroup: '1 A'), student('W2')]),
          schoolPrefix: 'GBS',
        ),
        {'GBS-1A'},
      );
    });

    test('collapses case but asks as WISA writes it', () {
      final asked = managedClassGroupMailNicknames(
        snap([
          student('W1', classGroup: '5WW1'),
          student('W2', classGroup: '5ww1')
        ]),
        schoolPrefix: 'GBS',
      );
      expect(asked, {'GBS-5WW1'});
    });
  });

  group('managedStaffEmployeeIds (#231)', () {
    WisaStaff member(String code, {String? wisaId}) => WisaStaff(
          code: core.WisaStaffCode(code),
          wisaId: wisaId == null ? null : core.WisaId(wisaId),
          firstName: 'Anna',
          lastName: 'Smit',
        );

    WisaSnapshot snap(List<WisaStaff> staff) => WisaSnapshot(
          fetchedAt: DateTime.utc(2026),
          students: const [],
          staff: staff,
          classGroups: const [],
          schools: const [],
        );

    test('no snapshot yet ⇒ nothing expected', () {
      expect(managedStaffEmployeeIds(null), isEmpty);
    });

    test('every staff member the SmaSyncPer pull returned counts', () {
      // No school scoping is possible or wanted: a staff row carries no school
      // id, so the pull is already exactly the staff we manage.
      expect(
        managedStaffEmployeeIds(
            snap([member('SMIT', wisaId: '42'), member('JANS', wisaId: '43')])),
        {'42', '43'},
      );
    });

    test('the wisaId is the id, never the staff code', () {
      // The Azure bridge for staff is `wisaId ≡ employeeId` (linker
      // `_buildStaffRecords` step 3); `code` bridges Smartschool instead
      // (OQ-1), and looking it up in Graph would match nothing.
      expect(managedStaffEmployeeIds(snap([member('SMIT', wisaId: '42')])),
          {'42'});
    });

    test('a staff member without a wisaId is dropped, not asked about', () {
      // `wisaId` is nullable on a staff row; without one there is no
      // `employeeId` to look up and none on the account to find either.
      expect(
        managedStaffEmployeeIds(
          snap([member('SMIT'), member('JANS', wisaId: '  43  ')]),
        ),
        {'43'},
      );
    });
  });

  group('retainedStaffEmployeeIds (#269)', () {
    AzureUser user(
      String id, {
      String? employeeId,
      String? department,
      String? companyName,
    }) =>
        AzureUser(
          id: id,
          upn: '$id@school.example',
          employeeId: employeeId,
          department: department,
          companyName: companyName,
        );

    AzureSnapshot snap(List<AzureUser> users) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026),
          users: users,
          groups: const [],
        );

    test('no snapshot yet ⇒ nothing remembered', () {
      expect(retainedStaffEmployeeIds(null, schoolPrefix: 'GBS'), isEmpty);
    });

    test('remembers a staff member our school lists second in department', () {
      // The case the bulk read cannot see: `startswith(department,'GBS')` is
      // false, Graph has no `contains` to widen it with (#268), and once WISA
      // stops listing them `managedStaffEmployeeIds` stops naming them too.
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', employeeId: '42', department: 'SSM,GBS')]),
          schoolPrefix: 'GBS',
        ),
        {'42'},
      );
    });

    test('another school\'s account is not remembered', () {
      // The retention rule is the account itself: the id is kept only while the
      // row still names our school. When another school's software drops our
      // prefix from the list, nothing is left to remember.
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', employeeId: '42', department: 'SSM,OTHER')]),
          schoolPrefix: 'GBS',
        ),
        isEmpty,
      );
    });

    test('reads the staff signal only, never the student one', () {
      // A student's account is found by `companyName eq '<prefix>'`, an equality
      // the bulk read answers with no help from us. Remembering them here would
      // grow the bounded lookup for nothing — and the group-wide student
      // question is #113, not this.
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', employeeId: '7', companyName: 'GBS')]),
          schoolPrefix: 'GBS',
        ),
        isEmpty,
      );
    });

    test('matches case-insensitively and trims, like every other id bridge',
        () {
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', employeeId: '  42  ', department: ' ssm,gbs ')]),
          schoolPrefix: 'GBS',
        ),
        {'42'},
      );
    });

    test('an account with no employeeId leaves nothing to ask about', () {
      // `employeeId` is the only key `loadByEmployeeIds` can use; a row without
      // one cannot be looked up again by any means.
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', department: 'SSM,GBS'), user('b', employeeId: '  ')]),
          schoolPrefix: 'GBS',
        ),
        isEmpty,
      );
    });

    test('an unconfigured prefix remembers nobody', () {
      // Every `department` contains the empty string, so a blank prefix would
      // otherwise remember the whole snapshot.
      expect(
        retainedStaffEmployeeIds(
          snap([user('a', employeeId: '42', department: 'SSM,GBS')]),
          schoolPrefix: '   ',
        ),
        isEmpty,
      );
    });
  });
}
