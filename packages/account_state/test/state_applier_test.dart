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
  _RecordingSoap({this.resultCode = 0});

  final List<String> soapActions = [];

  /// The integer result every write returns; non-zero is Smartschool's way of
  /// saying the call failed.
  final int resultCode;

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>$resultCode</return></response>'
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
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '00',
      name: name,
      firstName: firstName,
      preferredName: '',
      birthDate: _d,
      stemId: '',
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
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
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
}) =>
    wapi.WisaSnapshot(
      fetchedAt: _d,
      students: students,
      staff: staff,
      classGroups: classGroups,
      schools: const [],
    );

ss.SmartschoolSnapshot _sSnap(
        {List<ss.SmartschoolAccount> accounts = const []}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: _d,
      groups: const [],
      accounts: accounts,
      memberships: const [],
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
  }) : soap = _RecordingSoap(resultCode: soapResultCode) {
    final ssSnap = smartschool ?? _sSnap();
    final azSnap = azure ?? _aSnap();
    rules = WisaImportRules();

    final wisaState = SystemState<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      initial: wisa ?? _wSnap(),
      // A re-sync re-reads the base rows filtered by the current rule set —
      // exactly what the real WISA connector does at snapshot construction.
      syncer: (_) async {
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
      syncer: (_) async {
        counts[1]++;
        return ssSnap;
      },
    );
    final azState = SystemState<az.AzureSnapshot>(
      system: core.Origin.azure,
      initial: azSnap,
      syncer: (_) async {
        counts[2]++;
        return azSnap;
      },
    );

    app =
        ApplicationState(wisa: wisaState, smartschool: ssState, azure: azState);
    applier = StateApplier(
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

  group('DontImportFromWisa re-sync path', () {
    test('accumulates the rule and re-syncs WISA to drop the record', () async {
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

      final applied = await harness.applier.applyStaff(action);

      expect(applied.result.wrote, isTrue);
      expect(harness.soap.soapActions, isEmpty,
          reason: 'WISA is read-only — the action writes nothing itself');
      expect(
          harness.rules.rules
              .whereType<wapi.DontImportUserFromWisa>()
              .single
              .userCode,
          'SMIT');
      expect(harness.counts[0], 1, reason: 'WISA was re-synced exactly once');
      expect(harness.counts[1], 0);
      expect(harness.counts[2], 0);
      // The re-sync applied the rule: SMIT is gone, KEEP remains.
      expect(
        harness.app.wisa.snapshot!.staff.map((s) => s.code.value),
        ['KEEP'],
      );
      expect(applied.refreshed, isTrue);
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
      final applier = StateApplier(
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
      final applier = StateApplier(
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
        // future `unlocks` declaration says.
        final harness = classHarness(groups: [
          az.AzureGroup(
            id: 'az-9Z',
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
}
