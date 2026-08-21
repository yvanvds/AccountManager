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
            syncer: (_) async {
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

    test('falls back to the snapshot\'s own isOurs flags', () {
      final ids = managedStudentEmployeeIds(
        snap(
          [student('W1'), student('W2', schoolId: 2)],
          schools: [
            const WisaSchool(id: 1, name: '', code: '', isOurs: false),
            const WisaSchool(id: 2, name: '', code: '', isOurs: true),
          ],
        ),
      );
      expect(ids, {'W2'});
    });

    test('an unconfigured ownership set means every student counts', () {
      final ids = managedStudentEmployeeIds(
        snap([student('W1'), student('W2', schoolId: 2)]),
      );
      expect(ids, {'W1', 'W2'});
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
}
