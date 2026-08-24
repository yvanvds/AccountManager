import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _d = DateTime.utc(2026);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

// ---------------------------------------------------------------------------
// Recording fake transports: let a real action's apply() run offline while we
// assert exactly what it wrote (a dry run must record nothing).
// ---------------------------------------------------------------------------

class _RecordingSoap implements ss.SmartschoolSoapTransport {
  _RecordingSoap({this.resultCode = 0, this.resultFor, this.throwFor});

  final List<String> soapActions = [];

  /// The request envelope of every call, in order — so a test can assert what a
  /// write carried, not merely that it happened.
  final List<String> envelopes = [];

  /// The integer result every write returns; non-zero is Smartschool's way of
  /// saying the call failed.
  final int resultCode;

  /// Per-call override of [resultCode], keyed on the SOAP action. Lets a test
  /// fail *one* step of a multi-write action — a create whose class placement
  /// Smartschool refuses (#342) — the way the connector-level fixture already
  /// can. Returning null falls back to [resultCode].
  final int? Function(String soapAction)? resultFor;

  /// Per-call **throw**, keyed on the SOAP action: returns the error one call
  /// should blow up with, or null to answer normally (#343). A result code is
  /// Smartschool refusing; this is the wire coming apart, which is the failure
  /// shape that used to escape the create's best-effort placement step and take
  /// the whole create down with it.
  final Object? Function(String soapAction)? throwFor;

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    envelopes.add(envelope);
    // Recorded first: the call went out, it just never came back.
    final failure = throwFor?.call(soapAction);
    if (failure != null) throw failure;
    final code = resultFor?.call(soapAction) ?? resultCode;
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>$code</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

/// Graph for an empty tenant. PATCH/DELETE answer `204` the way Graph does,
/// while a **create** reads before it writes — `employeeId in (…)` to prove the
/// person has no account yet (#224), then `users/<upn>` per UPN candidate until
/// one is free — so those reads must answer "nothing here" and the create must
/// echo the new resource (#230). A bare `204` would decode to an empty JSON
/// object, which `AzureUser.fromGraphJson` turns into a user, so every UPN
/// candidate would read as taken and `createPrincipalName` would spin forever.
class _RecordingGraph implements az.GraphTransport {
  final List<az.GraphRequest> requests = [];

  int _created = 0;

  static final RegExp _singleUserPath = RegExp(r'/users/(?!delta$)[^/]+$');

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return _singleUserPath.hasMatch(request.url.path)
          ? const az.GraphResponse(
              statusCode: 404,
              headers: {'content-type': 'application/json'},
              body: '{"error":{"code":"Request_ResourceNotFound"}}',
            )
          : _ok(<String, dynamic>{'value': const <Object>[]}, 200);
    }
    if (request.method == 'POST' && request.url.path.endsWith('/users')) {
      final body = Map<String, dynamic>.from(
        jsonDecode(request.body ?? '{}') as Map,
      );
      return _ok({...body, 'id': 'az-created-${++_created}'}, 201);
    }
    if (request.method == 'POST' && request.url.path.endsWith('/groups')) {
      final body = Map<String, dynamic>.from(
        jsonDecode(request.body ?? '{}') as Map,
      );
      return _ok({
        ...body,
        'id': 'az-group-${++_created}',
        'mail': '${body['mailNickname']}@student.school.example',
      }, 201);
    }
    return const az.GraphResponse(statusCode: 204);
  }

  static az.GraphResponse _ok(Map<String, dynamic> body, int statusCode) =>
      az.GraphResponse(
        statusCode: statusCode,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
}

ss.SmartschoolConnector _ssConn(_RecordingSoap t) =>
    ss.SmartschoolConnector.fromParts(
      site: 'demo',
      accessCode: 'secret',
      transport: t,
    );

az.AzureConnector _azConn(_RecordingGraph t) => az.AzureConnector(
      credentials: az.AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'SSM',
      ),
      authProvider: const az.StaticAuthProvider('token'),
      transport: t,
    );

// ---------------------------------------------------------------------------
// Record + snapshot builders.
// ---------------------------------------------------------------------------

wapi.WisaStudent _wStudent({
  String wisaId = 'W1',
  String firstName = 'Jan',
  String name = 'Peeters',
  String classGroup = '3A',
  String stemId = '',
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: name,
      firstName: firstName,
      preferredName: '',
      birthDate: _d,
      stemId: stemId,
      gender: core.Gender.male,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: _d,
      schoolId: 1,
    );

wapi.WisaStaff _wStaff({String code = 'SMIT', String wisaId = '42'}) =>
    wapi.WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: core.WisaId(wisaId),
      firstName: 'Anna',
      lastName: 'Smit',
    );

ss.SmartschoolAccount _ssAccount({
  String uid = 'jan.peeters',
  String accountId = 'W1',
  String mail = 'jan.peeters@student.school.example',
  core.PersonRole role = core.PersonRole.student,
  int stemId = 0,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: stemId,
      role: role,
      givenName: 'Jan',
      surname: 'Peeters',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.male,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: _addr,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

az.AzureUser _azUser({
  String id = 'az-1',
  String upn = 'jan.peeters@student.school.example',
  String employeeId = 'W1',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      displayName: 'Jan Peeters',
      givenName: 'Jan',
      surname: 'Peeters',
      companyName: 'SSM',
      department: '3A',
    );

wapi.WisaSnapshot _wSnap({
  List<wapi.WisaStudent> students = const [],
  List<wapi.WisaStaff> staff = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
  DateTime? workDate,
}) =>
    wapi.WisaSnapshot(
      fetchedAt: _d,
      students: students,
      staff: staff,
      classGroups: classGroups,
      schools: const [],
      workDate: workDate,
    );

ss.SmartschoolSnapshot _sSnap({
  List<ss.SmartschoolAccount> accounts = const [],
  List<core.Group> groups = const [],
  List<ss.SmartschoolMembership> memberships = const [],
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: _d,
      groups: groups,
      accounts: accounts,
      memberships: memberships,
    );

ss.SmartschoolMembership _member(String uid, String groupCode) =>
    ss.SmartschoolMembership(uid: uid, groupId: core.GroupId(groupCode));

wapi.WisaClassGroup _wClass(String name, {int schoolId = 1}) =>
    wapi.WisaClassGroup(
      name: name,
      groupName: '00',
      description: '',
      adminCode: '',
      schoolCode: '123',
      schoolId: schoolId,
    );

/// A non-class Smartschool group — the kind a membership splice must leave
/// alone (a subject group, a tree node).
core.Group _ssNode(String name, {String? code}) => core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: name,
      type: core.GroupType.group,
      official: false,
      origin: core.Origin.smartschool,
    );

/// An **official** Smartschool class, the only shape the linker ever seeds a
/// Smartschool orphan record from.
core.Group _ssClass(String name, {String? code}) => core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: 'Klas $name',
      type: core.GroupType.classGroup,
      official: true,
      origin: core.Origin.smartschool,
    );

az.AzureSnapshot _aSnap({
  List<az.AzureUser> users = const [],
  List<az.AzureGroup> groups = const [],
}) =>
    az.AzureSnapshot(fetchedAt: _d, users: users, groups: groups);

core.LinkedAccount _linkedStudent({
  wapi.WisaStudent? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 'p0',
}) =>
    core.LinkedAccount(
      id: core.LinkedAccountId(id),
      role: core.PersonRole.student,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: core.LinkConfidence.high,
    );

core.LinkedStaff _linkedStaff({
  wapi.WisaStaff? wisa,
  ss.SmartschoolAccount? smartschool,
  az.AzureUser? azure,
  String id = 's0',
}) =>
    core.LinkedStaff(
      id: core.LinkedAccountId(id),
      role: core.PersonRole.teacher,
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      confidence: core.LinkConfidence.high,
    );

/// Deterministic in-memory [core.PersonIdResolver] (mirrors the linker fixture).
class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

StudentActionConfig _studentConfig() => StudentActionConfig(
      schoolPrefix: 'SSM',
      azureDomain: 'school.example',
      newAccountPassword: () => 'FakeP4ss!',
    );

StaffActionConfig _staffConfig() => StaffActionConfig(
      schoolPrefix: 'SSM',
      azureDomain: 'school.example',
      newAccountPassword: () => 'FakeP4ss!',
    );

/// One assembled State layer: [ApplicationState] seeded with the three
/// snapshots, a [StateApplier] wired to recording connectors, and the sync-call
/// counters so a test can prove the incremental path did **not** re-sync.
class _Harness {
  _Harness({
    wapi.WisaSnapshot? wisa,
    List<wapi.WisaStaff> wisaBaseStaff = const [],
    List<wapi.WisaStudent> wisaBaseStudents = const [],
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
    int soapResultCode = 0,
    int? Function(String soapAction)? soapResultFor,
    Object? Function(String soapAction)? soapThrowFor,
  }) : soap = _RecordingSoap(
          resultCode: soapResultCode,
          resultFor: soapResultFor,
          throwFor: soapThrowFor,
        ) {
    final ssSnap = smartschool ?? _sSnap();
    final azSnap = azure ?? _aSnap();
    rules = WisaImportRules();

    final wisaState = SystemState<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      initial: wisa ?? _wSnap(),
      // A re-sync re-reads the base rows filtered by the current rule set —
      // exactly what the real WISA connector does at snapshot construction.
      syncer: (_, {bool fullRead = false}) async {
        counts[0]++;
        // Students carry no drop rule; staff are filtered by the accumulated
        // DontImportUserFromWisa rules, as the real connector does.
        return _wSnap(
          students: wisaBaseStudents,
          staff: wapi.applyRulesToStaff(wisaBaseStaff, rules.rules),
        );
      },
    );
    final ssState = SystemState<ss.SmartschoolSnapshot>(
      system: core.Origin.smartschool,
      initial: ssSnap,
      syncer: (_, {bool fullRead = false}) async {
        counts[1]++;
        return ssSnap;
      },
    );
    final azState = SystemState<az.AzureSnapshot>(
      system: core.Origin.azure,
      initial: azSnap,
      syncer: (_, {bool fullRead = false}) async {
        counts[2]++;
        return azSnap;
      },
    );

    app =
        ApplicationState(wisa: wisaState, smartschool: ssState, azure: azState);
    applier = StateApplier.fixed(
      app: app,
      connectors: Connectors(smartschool: _ssConn(soap), azure: _azConn(graph)),
      resolver: _SeqResolver(),
      wisaRules: rules,
      studentConfig: _studentConfig(),
      staffConfig: _staffConfig(),
    );
  }

  final _RecordingSoap soap;
  final graph = _RecordingGraph();
  late final WisaImportRules rules;
  late final ApplicationState app;
  late final StateApplier applier;

  /// [wisa, smartschool, azure] sync-call counters.
  final List<int> counts = [0, 0, 0];
}

void main() {
  group('dry run (PAIN-3)', () {
    test('performs zero writes, returns the projected record, patches nothing',
        () async {
      final account = _linkedStudent(
        wisa: _wStudent(wisaId: 'W1'),
        smartschool: _ssAccount(accountId: 'OLD'),
        azure: _azUser(),
      );
      final harness = _Harness(
          smartschool: _sSnap(
              accounts: [account.smartschool! as ss.SmartschoolAccount]));
      final action = ModifyAccountId(account, harness.applier.studentConfig);

      final applied =
          await harness.applier.applyStudent(action, options: ApplyOptions.dry);

      expect(harness.soap.soapActions, isEmpty,
          reason: 'no write on a dry run');
      expect(applied.result.outcome, ActionOutcome.dryRun);
      expect(applied.result.smartschool?.accountId, 'W1',
          reason: 'projected record carries the change');
      expect(applied.refreshed, isFalse, reason: 'no state change to re-link');
      expect(harness.app.smartschool.snapshot!.accounts.single.accountId, 'OLD',
          reason: 'the in-memory snapshot is untouched');
      expect(harness.counts, [0, 0, 0]);
    });
  });

  group('incremental refresh on a real Smartschool write', () {
    test('patches the owning snapshot and re-links with no second sync',
        () async {
      final account = _linkedStudent(
        wisa: _wStudent(wisaId: 'W1'),
        smartschool: _ssAccount(uid: 'jan.peeters', accountId: 'OLD'),
        azure: _azUser(),
      );
      final harness = _Harness(
        smartschool:
            _sSnap(accounts: [account.smartschool! as ss.SmartschoolAccount]),
      );
      final action = ModifyAccountId(account, harness.applier.studentConfig);

      final applied = await harness.applier.applyStudent(action);

      expect(applied.result.wrote, isTrue);
      expect(harness.soap.soapActions, isNotEmpty,
          reason: 'the write happened');
      // The snapshot now carries the mutated record, spliced in by uid.
      final patched = harness.app.smartschool.snapshot!.accounts
          .singleWhere((a) => a.uid == 'jan.peeters');
      expect(patched.accountId, 'W1');
      expect(applied.refreshed, isTrue, reason: 're-linked from the patch');
      expect(harness.counts, [0, 0, 0],
          reason: 'incremental refresh must not hit the network');
      expect(harness.app.smartschool.lastSync, _d,
          reason: 'a patch is not a fresh fetch, so lastSync is unchanged');
    });

    test('a delete drops the record (and its memberships) from the snapshot',
        () async {
      final account = _linkedStudent(
        smartschool: _ssAccount(uid: 'ghost', accountId: 'G1'),
      );
      final harness = _Harness(
        smartschool:
            _sSnap(accounts: [account.smartschool! as ss.SmartschoolAccount]),
      );
      final action =
          DeleteStudentFromSmartschool(account, harness.applier.studentConfig);

      final applied = await harness.applier.applyStudent(action);

      expect(applied.result.removed, isTrue);
      expect(harness.app.smartschool.snapshot!.accounts, isEmpty,
          reason: 'the removed account is spliced out by uid');
      expect(applied.refreshed, isTrue);
      expect(harness.counts, [0, 0, 0]);
    });
  });

  group('a successful class move reseats the membership (#341)', () {
    /// Jan sits in `3B` in Smartschool while WISA has already moved him to
    /// `3A` — the rollover shape — and he also belongs to a non-class group
    /// the move says nothing about.
    _Harness moving({String wisaStemId = '', int ssStemId = 0}) => _Harness(
          wisa: _wSnap(
            students: [_wStudent(wisaId: 'W1', stemId: wisaStemId)],
            classGroups: [_wClass('3A'), _wClass('3B')],
          ),
          smartschool: _sSnap(
            groups: [
              _ssClass('3A', code: '3A_ss'),
              _ssClass('3B', code: '3B_ss'),
              _ssNode('Wiskunde', code: 'wisk'),
            ],
            accounts: [_ssAccount(uid: 'jan.peeters', stemId: ssStemId)],
            memberships: [
              _member('jan.peeters', '3B_ss'),
              _member('jan.peeters', 'wisk'),
            ],
          ),
          azure: _aSnap(users: [_azUser()]),
        );

    test('the snapshot moves the student to the new class, keeping the rest',
        () async {
      final harness = moving();
      final before = await harness.applier.link();
      final move =
          before.studentActions.whereType<MoveToSmartschoolClassGroup>().single;

      final applied = await harness.applier.applyStudent(move);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(harness.soap.soapActions.single, endsWith('#saveUserToClass'));
      final rows = harness.app.smartschool.snapshot!.memberships
          .where((m) => m.uid == 'jan.peeters')
          .map((m) => m.groupId.value)
          .toList();
      expect(rows, containsAll(<String>['3A_ss', 'wisk']),
          reason: 'the new class is in, the subject group is untouched');
      expect(rows, isNot(contains('3B_ss')),
          reason:
              'Smartschool re-seats an official class, it does not add one');
      expect(harness.counts, [0, 0, 0],
          reason: 'the incremental refresh must not hit the network');
    });

    test('the relink no longer offers the move it just performed', () async {
      final harness = moving();
      final before = await harness.applier.link();
      final move =
          before.studentActions.whereType<MoveToSmartschoolClassGroup>().single;

      final applied = await harness.applier.applyStudent(move);

      expect(applied.refreshed, isTrue);
      expect(
        applied.linked!.studentActions.whereType<MoveToSmartschoolClassGroup>(),
        isEmpty,
        reason: 'the class the operator applied is the class Smartschool has',
      );
    });

    test('and the stamboeknummer write it was holding back is released (#338)',
        () async {
      // #338 stands the stem write down per account while a move is pending, so
      // a move that never clears itself keeps the number deferred forever.
      final harness = moving(wisaStemId: '2300033', ssStemId: 2200123);
      final before = await harness.applier.link();
      expect(
        before.studentActions.whereType<ModifySmartschoolStemId>(),
        isEmpty,
        reason: 'the running year\'s career row is still the last one',
      );

      final applied = await harness.applier.applyStudent(
        before.studentActions.whereType<MoveToSmartschoolClassGroup>().single,
      );

      expect(
        applied.linked!.studentActions.whereType<ModifySmartschoolStemId>(),
        hasLength(1),
        reason: 'the move created the row the number belongs on',
      );
    });

    test('a plain field write leaves the memberships alone', () async {
      final harness = moving();
      final account = _linkedStudent(
        wisa: _wStudent(wisaId: 'W1'),
        smartschool: _ssAccount(uid: 'jan.peeters', accountId: 'OLD'),
        azure: _azUser(),
      );

      await harness.applier.applyStudent(
        ModifyAccountId(account, harness.applier.studentConfig),
      );

      expect(
        harness.app.smartschool.snapshot!.memberships
            .map((m) => m.groupId.value),
        <String>['3B_ss', 'wisk'],
        reason: 'only a move names a class, so only a move reseats one',
      );
    });
  });

  group('a create that placed its new account seats it too (#342)', () {
    /// New intake: Jan is in WISA (class `3A`) and already has his Office 365
    /// account, so `AddStudentToSmartschool` is the one action the card raises.
    /// Smartschool knows the class but nobody sits in it yet.
    _Harness intake({
      int? Function(String soapAction)? soapResultFor,
      Object? Function(String soapAction)? soapThrowFor,
    }) =>
        _Harness(
          wisa: _wSnap(
            students: [_wStudent(wisaId: 'W1')],
            classGroups: [_wClass('3A')],
          ),
          smartschool: _sSnap(groups: [_ssClass('3A', code: '3A_ss')]),
          azure: _aSnap(users: [_azUser()]),
          soapResultFor: soapResultFor,
          soapThrowFor: soapThrowFor,
        );

    AddStudentToSmartschool createOf(LinkedState linked) =>
        linked.studentActions.whereType<AddStudentToSmartschool>().single;

    test('the new account lands in the snapshot sitting in its class',
        () async {
      final harness = intake();
      final before = await harness.applier.link();

      final applied = await harness.applier.applyStudent(createOf(before));

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(
        harness.soap.soapActions.any((a) => a.endsWith('#saveUserToClass')),
        isTrue,
        reason: 'the create places the account it just made',
      );
      expect(
        harness.app.smartschool.snapshot!.memberships
            .where((m) => m.uid == 'jan.peeters')
            .map((m) => m.groupId.value),
        <String>['3A_ss'],
        reason: 'the account arrives in the snapshot already seated',
      );
      expect(harness.counts, [0, 0, 0],
          reason: 'the incremental refresh must not hit the network');
    });

    test('so the relink does not offer a move into the class he is in',
        () async {
      // The bug: the splice added the account but no membership, so the
      // placement resolver read no current class, and the very next frame
      // offered `MoveToSmartschoolClassGroup` — bulk-applyable, and since #338
      // holding the stamboeknummer write behind it — for a student who had
      // just been placed correctly.
      final harness = intake();
      final before = await harness.applier.link();

      final applied = await harness.applier.applyStudent(createOf(before));

      expect(applied.refreshed, isTrue);
      expect(
        applied.linked!.studentActions.whereType<MoveToSmartschoolClassGroup>(),
        isEmpty,
      );
    });

    test('a placement Smartschool refused seats nobody, and the move stands',
        () async {
      // Best-effort's other half: the create still succeeds, but nothing may
      // claim a seat that was not written. The move is this path's safety net
      // — suppressing it on a placement that failed would strand the student
      // outside every class until someone noticed.
      final harness = intake(
        soapResultFor: (a) => a.endsWith('#saveUserToClass') ? 1 : null,
      );
      final before = await harness.applier.link();

      final applied = await harness.applier.applyStudent(createOf(before));

      expect(applied.result.outcome, ActionOutcome.applied,
          reason: 'a failed placement must not fail the create (INV-41)');
      expect(harness.app.smartschool.snapshot!.memberships, isEmpty);
      expect(
        applied.linked!.studentActions.whereType<MoveToSmartschoolClassGroup>(),
        hasLength(1),
        reason: 'the student really is in no class, so the move is the fix',
      );
    });

    test(
        'a placement that threw is spliced in anyway, with the move standing '
        '(#343)', () async {
      // The whole point of #343 at this layer. A `moveUserToClass` that threw
      // used to make the create report `failed`, so `_refresh` spliced nothing:
      // the account existed in Smartschool but not in the snapshot, the card
      // kept offering "Maak een nieuw Smartschool account", and applying it
      // again wrote `saveUser` a second time for the same uid.
      final harness = intake(
        soapThrowFor: (a) => a.endsWith('#saveUserToClass')
            ? StateError('connection closed')
            : null,
      );
      final before = await harness.applier.link();

      final applied = await harness.applier.applyStudent(createOf(before));

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.refreshed, isTrue,
          reason: 'the create landed, so the snapshot must learn about it');
      expect(
        harness.app.smartschool.snapshot!.accounts.map((a) => a.uid),
        contains('jan.peeters'),
      );
      expect(harness.app.smartschool.snapshot!.memberships, isEmpty,
          reason: 'nothing was seated, so nothing may be claimed');
      expect(
        applied.linked!.studentActions.whereType<AddStudentToSmartschool>(),
        isEmpty,
        reason: 'the account exists; offering the create again would write '
            'saveUser twice for the same uid',
      );
      expect(
        applied.linked!.studentActions.whereType<MoveToSmartschoolClassGroup>(),
        hasLength(1),
        reason: 'the placement is what failed, so the move is what is left',
      );
      expect(applied.result.warnings, hasLength(1),
          reason: 'and the swallowed cause must not vanish — there is no log '
              'sink on that path');
      expect(applied.result.warnings.single, contains('3A'));
      expect(harness.counts, [0, 0, 0],
          reason: 'the incremental refresh must not hit the network');
    });
  });

  group('DontImportFromWisa patches the snapshot instead of re-pulling (#345)',
      () {
    // The rule never reaches WISA: it is a client-side filter the connector
    // applies at snapshot *construction*, after all the I/O, and no row query
    // carries it. So a re-pull could only ever return "the snapshot in hand
    // minus this record" — at the price of three SOAP round trips per school,
    // which on the real scholengroep is the 20+ seconds an operator waited per
    // ignored staff member. The applier runs the same filter locally instead.

    test('a staff rule drops the row with no WISA pull at all', () async {
      final staff = _linkedStaff(wisa: _wStaff(code: 'SMIT'));
      final harness = _Harness(
        wisa: _wSnap(staff: [_wStaff(code: 'SMIT'), _wStaff(code: 'KEEP')]),
        wisaBaseStaff: [_wStaff(code: 'SMIT'), _wStaff(code: 'KEEP')],
      );
      final action =
          DontImportStaffFromWisa(staff, harness.applier.staffConfig);

      // Precondition: SMIT is present before the rule is applied.
      expect(
        harness.app.wisa.snapshot!.staff.map((s) => s.code.value),
        containsAll(['SMIT', 'KEEP']),
      );
      final fetchedAt = harness.app.wisa.snapshot!.fetchedAt;
      final lastSync = harness.app.wisa.lastSync;

      final applied = await harness.applier.applyStaff(action);

      expect(applied.result.wrote, isTrue);
      expect(harness.soap.soapActions, isEmpty,
          reason: 'WISA is read-only — the action writes nothing itself');
      // The rule still joins the shared set: the *next* real pull must filter by
      // it, and #276 persists it from there.
      expect(
          harness.rules.rules
              .whereType<wapi.DontImportUserFromWisa>()
              .single
              .userCode,
          'SMIT');
      expect(harness.counts, [0, 0, 0],
          reason: 'the rule is a local filter — nothing is re-pulled');
      // The local patch applied the rule: SMIT is gone, KEEP remains.
      expect(
        harness.app.wisa.snapshot!.staff.map((s) => s.code.value),
        ['KEEP'],
      );
      expect(applied.refreshed, isTrue);
      // A patch is not a fresh fetch, so the roster still dates from the pull it
      // came out of and the dashboard freshness badge must not reset.
      expect(harness.app.wisa.snapshot!.fetchedAt, fetchedAt);
      expect(harness.app.wisa.lastSync, lastSync);
      // The relinked view no longer offers the opt-out on SMIT — that record is
      // gone from the snapshot the link reads. KEEP is still WISA-only, so it
      // keeps its own.
      expect(
        applied.linked!.staffActions
            .whereType<DontImportStaffFromWisa>()
            .map((a) => a.target.wisa?.code.value),
        ['KEEP'],
      );
    });

    test('a class rule drops that class group and leaves the others', () async {
      // Two WISA-only classes; Smartschool holds nothing but the root a create
      // would hang under, so each raises the #244 create-or-ignore either/or.
      final harness = _Harness(
        wisa: _wSnap(classGroups: [_wClass('3A'), _wClass('3B')]),
        smartschool: _sSnap(groups: [_ssNode('Leerlingen', code: 'SCHOOL')]),
      );
      final before = await harness.applier.link();
      final ignore = before.groupActions
          .whereType<DoNotImportFromWisa>()
          .where((a) => a.target.wisa?.name == '3A')
          .single;

      final applied = await harness.applier.applyGroup(ignore);

      expect(applied.result.wrote, isTrue);
      expect(
          harness.rules.rules
              .whereType<wapi.DontImportClass>()
              .single
              .className,
          '3A');
      expect(harness.counts, [0, 0, 0],
          reason: 'the class rule is the same local filter as the staff one');
      expect(
        harness.app.wisa.snapshot!.classGroups.map((g) => g.name),
        ['3B'],
      );
      expect(applied.refreshed, isTrue);
      expect(
        applied.linked!.groupActions
            .whereType<DoNotImportFromWisa>()
            .map((a) => a.target.wisa?.name),
        ['3B'],
        reason: 'the relink sees 3A gone and still offers the choice on 3B',
      );
    });
  });

  group('provisioning a new student is one chain, not two passes (#230)', () {
    /// A student who exists only in WISA — a new intake with neither a
    /// Smartschool nor an Office 365 account. The dispatcher can only offer the
    /// Azure create: `AddStudentToSmartschool` builds its account with the Azure
    /// UPN as the `mail`, so it evaluates false until that account exists.
    _Harness newIntake({int soapResultCode = 0}) => _Harness(
          wisa: _wSnap(students: [_wStudent(wisaId: 'W1')]),
          soapResultCode: soapResultCode,
        );

    test('the Azure create chains the Smartschool create it unlocked',
        () async {
      final harness = newIntake();
      final before = await harness.applier.link();
      final create = before.studentActions.single;
      expect(create, isA<AddStudentToAzure>(),
          reason: 'the dispatcher can only see the first link of the chain');

      final applied = await harness.applier.applyStudent(create);

      // Both writes happened, off one apply.
      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.result.system, core.Origin.azure);
      expect(applied.followUps.map((r) => r.changes.summary),
          ['Maak een nieuw Smartschool account']);
      expect(applied.followUps.single.outcome, ActionOutcome.applied);

      // And both records are in the snapshots the pass left behind.
      final azure = harness.app.azure.snapshot!.users.single;
      expect(azure.employeeId, 'W1');
      final smartschool = harness.app.smartschool.snapshot!.accounts.single;
      expect(smartschool.accountId, 'W1');
      expect(smartschool.mail, azure.upn,
          reason: 'the follow-up read the UPN that actually landed, not the '
              'projected one');
      expect(harness.counts, [0, 0, 0],
          reason: 'the chain rides the incremental refresh — no re-sync');
    });

    test('the chained account is what the linker now sees', () async {
      final harness = newIntake();
      final create = (await harness.applier.link()).studentActions.single;

      final applied = await harness.applier.applyStudent(create);

      final linked = applied.linked!.snapshot.accounts.single;
      expect(linked.wisa, isNotNull);
      expect(linked.azure, isNotNull);
      expect(linked.smartschool, isNotNull,
          reason: 'the returned view is the one the *last* link produced');
      expect(
        applied.linked!.studentActions.whereType<AddStudentToAzure>(),
        isEmpty,
      );
      expect(
        applied.linked!.studentActions.whereType<AddStudentToSmartschool>(),
        isEmpty,
      );
    });

    test('a dry run projects the first write and chains nothing', () async {
      final harness = newIntake();
      final create = (await harness.applier.link()).studentActions.single;

      final applied =
          await harness.applier.applyStudent(create, options: ApplyOptions.dry);

      expect(applied.result.outcome, ActionOutcome.dryRun);
      expect(applied.followUps, isEmpty,
          reason: 'nothing was written, so nothing was unlocked');
      expect(harness.soap.soapActions, isEmpty);
      expect(harness.graph.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(harness.app.smartschool.snapshot!.accounts, isEmpty);
    });

    test('a failing follow-up stops the chain and is reported', () async {
      // Smartschool refuses the create (non-zero return code); the Azure
      // account it followed still exists and must stay in the snapshot, so the
      // next pass offers exactly the one create that is still missing.
      final harness = newIntake(soapResultCode: 1);
      final create = (await harness.applier.link()).studentActions.single;

      final applied = await harness.applier.applyStudent(create);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.followUps.single.outcome, ActionOutcome.failed);
      expect(applied.linked, isNotNull,
          reason: 'the successful Azure write is still reflected');
      expect(harness.app.azure.snapshot!.users, hasLength(1));
      expect(harness.app.smartschool.snapshot!.accounts, isEmpty);
      expect(
        applied.linked!.studentActions.single,
        isA<AddStudentToSmartschool>(),
      );
    });

    test('both minted passwords land on one password sheet (#105)', () async {
      final queue = InMemoryPasswordQueueStore();
      final harness = newIntake();
      final applier = StateApplier.fixed(
        app: harness.app,
        connectors: Connectors(
          smartschool: _ssConn(harness.soap),
          azure: _azConn(harness.graph),
        ),
        resolver: _SeqResolver(),
        wisaRules: harness.rules,
        studentConfig: _studentConfig(),
        staffConfig: _staffConfig(),
        passwordQueue: queue,
      );

      await applier.applyStudent((await applier.link()).studentActions.single);

      final entry = (await queue.load()).single;
      expect(entry.azurePassword, isNotNull);
      expect(entry.smartschoolPassword, isNotNull,
          reason: 'the chained create merges onto the entry the first left');
    });
  });

  group('provisioning a new staff member is one chain, not two passes (#240)',
      () {
    /// A staff member who exists only in WISA — a new hire with neither a
    /// Smartschool nor an Office 365 account. The dispatch can only offer the
    /// Azure create: `AddStaffToSmartschool` builds its account with the Azure
    /// UPN as the `mail`, so it evaluates false until that account exists.
    _Harness newHire({int soapResultCode = 0}) => _Harness(
          wisa: _wSnap(staff: [_wStaff(code: 'SMIT', wisaId: '42')]),
          wisaBaseStaff: [_wStaff(code: 'SMIT', wisaId: '42')],
          soapResultCode: soapResultCode,
        );

    test('the Azure create chains the Smartschool create it unlocked',
        () async {
      final harness = newHire();
      final before = await harness.applier.link();
      final create = before.staffActions.whereType<AddStaffToAzure>().single;

      final applied = await harness.applier.applyStaff(create);

      // Both writes happened, off one apply.
      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.result.system, core.Origin.azure);
      expect(applied.followUps.map((r) => r.changes.summary),
          ['Maak een nieuw Smartschool account']);
      expect(applied.followUps.single.outcome, ActionOutcome.applied);

      // And both records are in the snapshots the pass left behind.
      final azure = harness.app.azure.snapshot!.users.single;
      expect(azure.employeeId, '42');
      final smartschool = harness.app.smartschool.snapshot!.accounts.single;
      expect(smartschool.accountId, 'SMIT',
          reason: 'staff bridge to Smartschool by their WISA code, not wisaId');
      expect(smartschool.mail, azure.upn,
          reason: 'the follow-up read the UPN that actually landed, not the '
              'projected one');
      expect(harness.counts, [0, 0, 0],
          reason: 'the chain rides the incremental refresh — no re-sync');
    });

    test('the chained account is what the linker now sees', () async {
      final harness = newHire();
      final create = (await harness.applier.link())
          .staffActions
          .whereType<AddStaffToAzure>()
          .single;

      final applied = await harness.applier.applyStaff(create);

      final linked = applied.linked!.snapshot.staff.single;
      expect(linked.wisa, isNotNull);
      expect(linked.azure, isNotNull);
      expect(linked.smartschool, isNotNull,
          reason: 'the returned view is the one the *last* link produced');
      expect(
          applied.linked!.staffActions.whereType<AddStaffToAzure>(), isEmpty);
      expect(applied.linked!.staffActions.whereType<AddStaffToSmartschool>(),
          isEmpty);
    });

    test('a dry run projects the first write and chains nothing', () async {
      final harness = newHire();
      final create = (await harness.applier.link())
          .staffActions
          .whereType<AddStaffToAzure>()
          .single;

      final applied =
          await harness.applier.applyStaff(create, options: ApplyOptions.dry);

      expect(applied.result.outcome, ActionOutcome.dryRun);
      expect(applied.followUps, isEmpty,
          reason: 'nothing was written, so nothing was unlocked');
      expect(harness.soap.soapActions, isEmpty);
      expect(harness.graph.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(harness.app.smartschool.snapshot!.accounts, isEmpty);
    });

    test('a failing follow-up stops the chain and is reported', () async {
      // Smartschool refuses the create (non-zero return code); the Azure
      // account it followed still exists and must stay in the snapshot, so the
      // next pass offers exactly the one create that is still missing.
      final harness = newHire(soapResultCode: 1);
      final create = (await harness.applier.link())
          .staffActions
          .whereType<AddStaffToAzure>()
          .single;

      final applied = await harness.applier.applyStaff(create);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.followUps.single.outcome, ActionOutcome.failed);
      expect(applied.linked, isNotNull,
          reason: 'the successful Azure write is still reflected');
      expect(harness.app.azure.snapshot!.users, hasLength(1));
      expect(harness.app.smartschool.snapshot!.accounts, isEmpty);
      expect(
        applied.linked!.staffActions.whereType<AddStaffToSmartschool>(),
        hasLength(1),
      );
    });

    test('an unrelated staff action chains nothing', () async {
      // The chain is opt-in per action: applying the copy-code repair on a
      // complete record must stay one write.
      final staff = _linkedStaff(
        wisa: _wStaff(code: 'SMIT', wisaId: '42'),
        smartschool: _ssAccount(
          uid: 'anna.smit',
          accountId: 'SMIT',
          mail: 'anna.smit@school.example',
          role: core.PersonRole.teacher,
        ),
        azure: _azUser(id: 'az-9', upn: 'anna.smit@school.example'),
      );
      final harness = _Harness(
        wisa: _wSnap(staff: [_wStaff(code: 'SMIT', wisaId: '42')]),
        smartschool:
            _sSnap(accounts: [staff.smartschool! as ss.SmartschoolAccount]),
        azure: _aSnap(users: [staff.azure! as az.AzureUser]),
      );
      final action = SetStaffCopyCode(staff, harness.applier.staffConfig);

      final applied = await harness.applier.applyStaff(action);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.followUps, isEmpty);
    });

    test('both minted passwords land on one password sheet (#105)', () async {
      final queue = InMemoryPasswordQueueStore();
      final harness = newHire();
      final applier = StateApplier.fixed(
        app: harness.app,
        connectors: Connectors(
          smartschool: _ssConn(harness.soap),
          azure: _azConn(harness.graph),
        ),
        resolver: _SeqResolver(),
        wisaRules: harness.rules,
        studentConfig: _studentConfig(),
        staffConfig: _staffConfig(),
        passwordQueue: queue,
      );

      await applier.applyStaff(
        (await applier.link()).staffActions.whereType<AddStaffToAzure>().single,
      );

      final entry = (await queue.load()).single;
      expect(entry.azurePassword, isNotNull);
      expect(entry.smartschoolPassword, isNotNull,
          reason: 'the chained create merges onto the entry the first left');
    });
  });

  group('Smartschool uid uniqueness for created accounts (#72)', () {
    test(
        'suffixes a colliding login and stays unique across sequential creates',
        () async {
      // The snapshot already holds "jan.peeters"; two new Jan Peeters students
      // are created back-to-back.
      final harness = _Harness(
        smartschool: _sSnap(accounts: [_ssAccount(uid: 'jan.peeters')]),
      );

      core.LinkedAccount fresh(String id, String wisaId) => _linkedStudent(
            id: id,
            wisa: _wStudent(wisaId: wisaId),
            azure: _azUser(id: 'az-$id', upn: '$id@student.school.example'),
          );

      final first = await harness.applier.applyStudent(
        AddStudentToSmartschool(
            fresh('p1', 'W101'), harness.applier.studentConfig),
      );
      final second = await harness.applier.applyStudent(
        AddStudentToSmartschool(
            fresh('p2', 'W102'), harness.applier.studentConfig),
      );

      expect(first.result.smartschool?.uid, 'jan.peeters1',
          reason: 'base login taken → first free counter');
      expect(second.result.smartschool?.uid, 'jan.peeters2',
          reason: 'reads the snapshot the first create was spliced into');
      expect(
        harness.app.smartschool.snapshot!.accounts.map((a) => a.uid),
        containsAll(['jan.peeters', 'jan.peeters1', 'jan.peeters2']),
      );
    });
  });

  group('Office 365 class groups (#228)', () {
    /// A WISA class with one enrolled student who already has an Office 365
    /// account — the state that raises the class-group create.
    _Harness classHarness({List<az.AzureGroup> groups = const []}) => _Harness(
          wisa: _wSnap(
            students: [_wStudent(wisaId: 'W1', classGroup: '2A')],
            classGroups: [
              const wapi.WisaClassGroup(
                name: '2A',
                groupName: '00',
                description: 'Klas 2A',
                adminCode: '',
                schoolCode: '123',
                schoolId: 1,
              ),
            ],
          ),
          azure: _aSnap(
            users: [_azUser(id: 'az-1', employeeId: 'W1')],
            groups: groups,
          ),
        );

    test('a create patches the Azure snapshot, so the relink sees the group',
        () async {
      final harness = classHarness();
      final before = await harness.applier.link();
      final create = before.groupActions.whereType<CreateAzureClassGroup>();
      expect(create, hasLength(1),
          reason: 'the class has students and no Office 365 group yet');

      final applied = await harness.applier.applyGroup(create.single);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.refreshed, isTrue);
      expect(
        harness.app.azure.snapshot!.groups.map((g) => g.displayName),
        ['SSM-2A'],
        reason: 'no re-sync — the created group is spliced in (#72)',
      );
      expect(harness.counts, [0, 0, 0], reason: 'nothing was re-pulled');
      // The relinked view no longer offers the create; the class is provisioned.
      expect(applied.linked!.groupActions.whereType<CreateAzureClassGroup>(),
          isEmpty);
    });

    test('a membership sync patches the members in place', () async {
      final harness = classHarness(groups: [
        az.AzureGroup(
          id: 'az-2A',
          displayName: 'SSM-2A',
          mail: 'SSM-2A@student.school.example',
          mailNickname: 'SSM-2A',
        ),
      ]);
      final before = await harness.applier.link();
      final sync =
          before.groupActions.whereType<SyncAzureClassGroupMembers>().single;
      expect(sync.plan.membersToAdd, ['az-1']);

      final applied = await harness.applier.applyGroup(sync);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(
        (harness.app.azure.snapshot!.groups.single).memberIds,
        ['az-1'],
      );
      expect(
        applied.linked!.groupActions.whereType<SyncAzureClassGroupMembers>(),
        isEmpty,
        reason: 'the class reads as in sync straight after the write',
      );
    });

    test('deleting a stale class group drops it from the snapshot (#271)',
        () async {
      // `SSM-9Z` is the group of a class that no longer runs anywhere, so the
      // relink offers the stale-group either/or on it. Applying the delete has
      // to remove the *group* — not a user — from the Azure snapshot, or the
      // relink re-raises the very pair the operator just resolved.
      final harness = classHarness(groups: [
        az.AzureGroup(
          id: 'az-2A',
          displayName: 'SSM-2A',
          mail: 'SSM-2A@student.school.example',
          mailNickname: 'SSM-2A',
          memberIds: const ['az-1'],
        ),
        az.AzureGroup(
          id: 'az-9Z',
          displayName: 'SSM-9Z',
          mail: 'SSM-9Z@student.school.example',
          mailNickname: 'SSM-9Z',
        ),
      ]);
      final before = await harness.applier.link();
      final delete =
          before.groupActions.whereType<DeleteAzureClassGroup>().single;

      final applied = await harness.applier.applyGroup(delete);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.refreshed, isTrue);
      expect(
        harness.app.azure.snapshot!.groups.map((g) => g.id),
        ['az-2A'],
        reason: 'only the stale group goes — no re-sync (#72)',
      );
      expect(
        harness.app.azure.snapshot!.users.map((u) => u.id),
        ['az-1'],
        reason: 'deleting a group removes nobody\'s account',
      );
      expect(applied.followUps, isEmpty, reason: 'nothing follows a delete');
      expect(
        applied.linked!.groupActions.whereType<DeleteAzureClassGroup>(),
        isEmpty,
        reason: 'the stale class is gone from the relinked view',
      );
      expect(harness.counts, [0, 0, 0], reason: 'nothing was re-pulled');
    });

    test('a dry run writes nothing and patches nothing', () async {
      final harness = classHarness();
      final before = await harness.applier.link();
      final create =
          before.groupActions.whereType<CreateAzureClassGroup>().single;

      final applied = await harness.applier.applyGroup(
        create,
        options: const ApplyOptions(dryRun: true),
      );

      expect(applied.result.outcome, ActionOutcome.dryRun);
      expect(applied.refreshed, isFalse);
      expect(harness.app.azure.snapshot!.groups, isEmpty);
      expect(
        harness.graph.requests.where((r) => r.method == 'POST'),
        isEmpty,
      );
    });

    group('provisioning a class group is one apply, not two (#245)', () {
      test('the create chains the roster sync it unlocked', () async {
        // Graph creates a group empty, so #228 left `SSM-2A` with nobody in it
        // and the enrolment waited for the operator's second click. The chain
        // runs the roster against the **relinked** record — the only place the
        // id Graph just minted exists.
        final harness = classHarness();
        final before = await harness.applier.link();
        final create =
            before.groupActions.whereType<CreateAzureClassGroup>().single;

        final applied = await harness.applier.applyGroup(create);

        expect(applied.result.outcome, ActionOutcome.applied);
        expect(applied.followUps, hasLength(1));
        expect(applied.followUps.single.outcome, ActionOutcome.applied);
        expect(
          applied.followUps.single.changes.summary,
          contains('Werk het ledenbestand van SSM-2A bij'),
        );
        expect(
          harness.app.azure.snapshot!.groups.single.memberIds,
          ['az-1'],
          reason: 'the created group holds the class straight away',
        );
        expect(harness.counts, [0, 0, 0], reason: 'nothing was re-pulled');
        expect(
          applied.linked!.groupActions.whereType<CreateAzureClassGroup>(),
          isEmpty,
        );
        expect(
          applied.linked!.groupActions.whereType<SyncAzureClassGroupMembers>(),
          isEmpty,
          reason: 'the class is provisioned and in sync after the one apply',
        );
      });

      test('a dry run projects the create and chains nothing', () async {
        final harness = classHarness();
        final before = await harness.applier.link();
        final create =
            before.groupActions.whereType<CreateAzureClassGroup>().single;

        final applied = await harness.applier.applyGroup(
          create,
          options: const ApplyOptions(dryRun: true),
        );

        expect(applied.result.outcome, ActionOutcome.dryRun);
        expect(applied.followUps, isEmpty,
            reason: 'nothing was written, so nothing was unlocked');
      });

      test('a class whose students have no Office 365 account chains nothing',
          () async {
        // The follow-up's own evaluate() still decides: there is no roster to
        // add, so the created group is simply left empty.
        final harness = _Harness(
          wisa: _wSnap(
            students: [_wStudent(wisaId: 'W1', classGroup: '2A')],
            classGroups: [
              const wapi.WisaClassGroup(
                name: '2A',
                groupName: '00',
                description: 'Klas 2A',
                adminCode: '',
                schoolCode: '123',
                schoolId: 1,
              ),
            ],
          ),
        );
        final before = await harness.applier.link();
        final create =
            before.groupActions.whereType<CreateAzureClassGroup>().single;

        final applied = await harness.applier.applyGroup(create);

        expect(applied.result.outcome, ActionOutcome.applied);
        expect(applied.followUps, isEmpty);
        expect(harness.app.azure.snapshot!.groups.single.memberIds, isEmpty);
      });

      test('an informational group action is never chained', () async {
        // The orphan notice throws on apply; the walk must skip it whatever a
        // future `unlocks` declaration says. Since #327 that notice is raised
        // only where the delete beside it cannot fire — here, a stale group the
        // tenant gave no object id to address a DELETE to.
        final harness = classHarness(groups: [
          az.AzureGroup(
            id: '',
            displayName: 'SSM-9Z',
            mail: 'SSM-9Z@student.school.example',
            mailNickname: 'SSM-9Z',
          ),
        ]);
        final before = await harness.applier.link();
        expect(
          before.groupActions.whereType<AzureClassGroupWithoutClass>(),
          hasLength(1),
        );
        final create =
            before.groupActions.whereType<CreateAzureClassGroup>().single;

        final applied = await harness.applier.applyGroup(create);

        expect(
          applied.followUps.map((r) => r.changes.summary),
          everyElement(contains('ledenbestand')),
        );
      });
    });
  });

  group('Smartschool classes WISA does not have (#313)', () {
    /// Two official Smartschool classes and a WISA snapshot that only knows one
    /// of them: `9Z` is the leftover, and the relink raises the
    /// leave-it/delete-it pair on it.
    _Harness leftoverHarness() => _Harness(
          wisa: _wSnap(
            students: [_wStudent(wisaId: 'W1', classGroup: '2A')],
            classGroups: [
              const wapi.WisaClassGroup(
                name: '2A',
                groupName: '00',
                description: 'Klas 2A',
                adminCode: '',
                schoolCode: '123',
                schoolId: 1,
              ),
            ],
          ),
          smartschool: _sSnap(
            groups: [_ssClass('2A'), _ssClass('9Z', code: 'C9Z')],
          ),
        );

    test('deleting a leftover class drops it from the snapshot', () async {
      // The Smartschool twin of the #271 delete: applying it has to remove the
      // *group* from the Smartschool snapshot, or the relink re-raises the very
      // pair the operator just resolved.
      final harness = leftoverHarness();
      final before = await harness.applier.link();
      final delete =
          before.groupActions.whereType<DeleteSmartschoolClass>().single;

      final applied = await harness.applier.applyGroup(delete);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(applied.refreshed, isTrue);
      expect(harness.soap.soapActions.single, contains('delClass'));
      expect(
        harness.app.smartschool.snapshot!.groups.map((g) => g.id.value),
        ['2A'],
        reason: 'only the leftover goes — no re-sync (#72)',
      );
      expect(applied.followUps, isEmpty, reason: 'nothing follows a delete');
      expect(
        applied.linked!.groupActions.whereType<DeleteSmartschoolClass>(),
        isEmpty,
        reason: 'the leftover is gone from the relinked view',
      );
      expect(
        applied.linked!.groupActions.whereType<DoNotImportFromSmartschool>(),
        isEmpty,
        reason: 'and the relink raises no notice in its place — the record is '
            'gone, not merely undeletable (#328)',
      );
      expect(harness.counts, [0, 0, 0], reason: 'nothing was re-pulled');
    });

    test('a dry run writes nothing and patches nothing', () async {
      final harness = leftoverHarness();
      final before = await harness.applier.link();
      final delete =
          before.groupActions.whereType<DeleteSmartschoolClass>().single;

      final applied = await harness.applier.applyGroup(
        delete,
        options: const ApplyOptions(dryRun: true),
      );

      expect(applied.result.outcome, ActionOutcome.dryRun);
      expect(applied.refreshed, isFalse);
      expect(harness.soap.soapActions, isEmpty);
      expect(harness.app.smartschool.snapshot!.groups, hasLength(2));
    });
  });

  group('a class write names the school year it was read at (#339)', () {
    /// A class whose Smartschool institute number has drifted from WISA's — the
    /// state that raises [ModifySmartschoolData], the action whose whole job is
    /// to write an institute number.
    _Harness driftHarness({DateTime? workDate}) => _Harness(
          wisa: _wSnap(
            workDate: workDate,
            classGroups: [
              const wapi.WisaClassGroup(
                name: '2A',
                groupName: '00',
                description: 'Klas 2A',
                adminCode: '',
                // Next year this class belongs to the group's other school.
                schoolCode: '125252',
                schoolId: 1,
              ),
            ],
          ),
          smartschool: _sSnap(groups: [_ssClass('2A')]),
        );

    /// The `$schoolYearDate` of the last `saveClass` envelope, or null when no
    /// class was saved. Read off the wire: `''` is Smartschool's "the current
    /// school year", which is exactly the value #339 is about.
    String? savedSchoolYearDate(_Harness harness) {
      for (var i = harness.soap.soapActions.length - 1; i >= 0; i--) {
        if (!harness.soap.soapActions[i].endsWith('#saveClass')) continue;
        return RegExp(r'<schoolYearDate[^>]*>([^<]*)</schoolYearDate>')
                .firstMatch(harness.soap.envelopes[i])
                ?.group(1) ??
            '';
      }
      return null;
    }

    test("the applier stamps the WISA snapshot's werkdatum onto the write",
        () async {
      // The operator has moved the werkdatum into next school year to prepare
      // it; Smartschool is still in the running one. Without the stamp the new
      // institute number overwrites the running year's.
      final harness = driftHarness(workDate: DateTime(2026, 9, 1));
      final before = await harness.applier.link();
      final sync =
          before.groupActions.whereType<ModifySmartschoolData>().single;

      final applied = await harness.applier.applyGroup(sync);

      expect(applied.result.outcome, ActionOutcome.applied);
      expect(savedSchoolYearDate(harness), '2026-9-1');
    });

    test('an unstamped snapshot leaves the API default alone', () async {
      // A pull from before #247 carries no werkdatum, so there is nothing
      // truthful to name and the write behaves as it always did.
      final harness = driftHarness();
      final before = await harness.applier.link();
      final sync =
          before.groupActions.whereType<ModifySmartschoolData>().single;

      await harness.applier.applyGroup(sync);

      expect(savedSchoolYearDate(harness), '');
    });

    test('a caller that named a werkdatum keeps it', () async {
      final harness = driftHarness(workDate: DateTime(2026, 9, 1));
      final before = await harness.applier.link();
      final sync =
          before.groupActions.whereType<ModifySmartschoolData>().single;

      await harness.applier.applyGroup(
        sync,
        options: ApplyOptions(workDate: DateTime(2025, 9, 1)),
      );

      expect(savedSchoolYearDate(harness), '2025-9-1');
    });
  });

  group('settings are read live, never captured (#246)', () {
    /// An applier over one Azure-only orphan carrying `companyName: SSM`, with
    /// the settings-derived inputs coming from a mutable [ApplierSettings] the
    /// test rewrites between links — the shape `bootstrapReconcile` wires over
    /// `LiveSettings`.
    (StateApplier, void Function(ApplierSettings)) build() {
      var current = ApplierSettings(
        studentConfig: _studentConfig(),
        staffConfig: _staffConfig(),
      );
      final applier = StateApplier(
        app: ApplicationState(
          wisa: SystemState<wapi.WisaSnapshot>(
            system: core.Origin.wisa,
            initial: _wSnap(),
            syncer: (_, {bool fullRead = false}) async => _wSnap(),
          ),
          smartschool: SystemState<ss.SmartschoolSnapshot>(
            system: core.Origin.smartschool,
            initial: _sSnap(),
            syncer: (_, {bool fullRead = false}) async => _sSnap(),
          ),
          azure: SystemState<az.AzureSnapshot>(
            system: core.Origin.azure,
            initial: _aSnap(users: [_azUser(id: 'az-orphan')]),
            syncer: (_, {bool fullRead = false}) async => _aSnap(),
          ),
        ),
        connectors:
            Connectors(smartschool: _ssConn(_RecordingSoap()), azure: null),
        resolver: _SeqResolver(),
        wisaRules: WisaImportRules(),
        settings: () => current,
      );
      return (applier, (next) => current = next);
    }

    test('a school prefix saved after bootstrap scopes the very next link()',
        () async {
      // INV-22: an Azure-only user stamped with our `companyName` is a former
      // student we keep so the engine can flag it. Whether this orphan is ours
      // is therefore a pure function of the prefix — which used to be frozen
      // into the applier when bootstrap built it.
      final (applier, publish) = build();

      final before = await applier.link();
      expect(before.snapshot.accounts, hasLength(1),
          reason: 'companyName SSM matches the prefix in force');

      publish(ApplierSettings(
        studentConfig: StudentActionConfig(
          schoolPrefix: 'OTHER',
          azureDomain: 'school.example',
        ),
        staffConfig: StaffActionConfig(
          schoolPrefix: 'OTHER',
          azureDomain: 'school.example',
        ),
      ));

      final after = await applier.link();
      expect(after.snapshot.accounts, isEmpty,
          reason: 'the relink honoured the new prefix without a relaunch');
    });

    test('the class tree and managed-school set are re-read on every access',
        () {
      final (applier, publish) = build();
      expect(applier.classTree.path, '');
      expect(applier.ourSchoolIds, isNull);

      publish(ApplierSettings(
        studentConfig: _studentConfig(),
        staffConfig: _staffConfig(),
        classTree: const SmartschoolClassTree(path: 'SCHOOL'),
        ourSchoolIds: const {1, 2},
      ));

      expect(applier.classTree.path, 'SCHOOL');
      expect(applier.ourSchoolIds, const {1, 2});
    });

    test('the uid-uniqueness wrapping survives the change', () async {
      // The wrapping used to happen once, in the constructor. Rebuilding the
      // config per read must not lose it, or a created login could collide with
      // an account an earlier apply spliced into the snapshot (#72).
      final (applier, publish) = build();
      expect(applier.studentConfig.smartschoolUid('Jan', 'Peeters'),
          'jan.peeters');

      publish(ApplierSettings(
        studentConfig: StudentActionConfig(
          schoolPrefix: 'OTHER',
          azureDomain: 'other.example',
        ),
        staffConfig: StaffActionConfig(
          schoolPrefix: 'OTHER',
          azureDomain: 'other.example',
        ),
      ));

      expect(applier.studentConfig.azureDomain, 'other.example');
      expect(applier.studentConfig.studentDomain, 'student.other.example');
      expect(applier.staffConfig.schoolPrefix, 'OTHER');
      expect(
          applier.studentConfig.smartschoolUid('Jan', 'Peeters'), 'jan.peeters',
          reason: 'still uniqueness-aware against the current snapshot');
    });

    test('StateApplier.fixed keeps answering with the one config it was given',
        () {
      final applier = StateApplier.fixed(
        app: _Harness().app,
        connectors:
            Connectors(smartschool: _ssConn(_RecordingSoap()), azure: null),
        resolver: _SeqResolver(),
        wisaRules: WisaImportRules(),
        studentConfig: _studentConfig(),
        staffConfig: _staffConfig(),
        classTree: const SmartschoolClassTree(path: 'ROOT'),
        ourSchoolIds: const {7},
      );
      expect(applier.studentConfig.schoolPrefix, 'SSM');
      expect(applier.classTree.path, 'ROOT');
      expect(applier.ourSchoolIds, const {7});
    });
  });
}
