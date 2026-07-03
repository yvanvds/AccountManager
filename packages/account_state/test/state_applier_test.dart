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
  final List<String> soapActions = [];

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    soapActions.add(soapAction);
    // Every recorded write succeeds (return code 0).
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope '
        'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><response><return>0</return></response>'
        '</soap:Body></soap:Envelope>';
  }
}

class _RecordingGraph implements az.GraphTransport {
  final List<az.GraphRequest> requests = [];

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    return const az.GraphResponse(statusCode: 204);
  }
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
}) =>
    wapi.WisaSnapshot(
      fetchedAt: _d,
      students: students,
      staff: staff,
      classGroups: const [],
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

az.AzureSnapshot _aSnap({List<az.AzureUser> users = const []}) =>
    az.AzureSnapshot(fetchedAt: _d, users: users, groups: const []);

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
  }) {
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

  final soap = _RecordingSoap();
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
}
