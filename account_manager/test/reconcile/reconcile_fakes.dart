/// Shared offline fixtures for the reconcile widget and integration tests:
/// record/snapshot builders, recording transports (so a real action `apply`
/// runs with zero network), and a [ReconcileHarness] that assembles the real
/// State layer over scripted syncers.
///
/// The fixture scenario mirrors `account_state`'s `linked_state_test`: one
/// student fully linked across the three systems whose WISA class (3C)
/// differs from her Smartschool membership (2B), so the dispatchers derive
/// exactly one deterministic pending action (`MoveToSmartschoolClassGroup`).
library;

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime kFixtureDate = DateTime.utc(2026, 7, 1);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

// ---------------------------------------------------------------------------
// Recording fake transports: a real action `apply()` runs offline while the
// test asserts exactly what was written (a dry run must record nothing).
// ---------------------------------------------------------------------------

class RecordingSoap implements ss.SmartschoolSoapTransport {
  final List<String> soapActions = <String>[];

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

class RecordingGraph implements az.GraphTransport {
  final List<az.GraphRequest> requests = <az.GraphRequest>[];

  @override
  Future<az.GraphResponse> send(az.GraphRequest request) async {
    requests.add(request);
    return const az.GraphResponse(statusCode: 204);
  }
}

// ---------------------------------------------------------------------------
// Record + snapshot builders.
// ---------------------------------------------------------------------------

wapi.WisaStudent wisaStudent({
  String wisaId = '1',
  String classGroup = '3C',
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '',
      name: 'Doe',
      firstName: 'Jane',
      preferredName: '',
      birthDate: kFixtureDate,
      stemId: '',
      gender: core.Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: kFixtureDate,
      schoolId: 1,
    );

ss.SmartschoolAccount ssAccount({
  String uid = 'jane',
  String accountId = '1',
  String mail = 'jane.doe@student.school.example',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
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

az.AzureUser azUser({
  String id = 'az1',
  String upn = 'jane.doe@student.school.example',
  String? employeeId = '1',
}) =>
    az.AzureUser(
      id: id,
      upn: upn,
      employeeId: employeeId,
      companyName: 'GBS',
    );

core.Group ssGroup(
  String name, {
  String? code,
  bool official = true,
  core.GroupType type = core.GroupType.classGroup,
}) =>
    core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: '',
      type: type,
      official: official,
      origin: core.Origin.smartschool,
    );

ss.SmartschoolMembership member(String uid, String groupCode) =>
    ss.SmartschoolMembership(uid: uid, groupId: core.GroupId(groupCode));

wapi.WisaSnapshot wisaSnap({
  DateTime? fetchedAt,
  List<wapi.WisaStudent>? students,
}) =>
    wapi.WisaSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      students: students ?? [wisaStudent()],
      staff: const [],
      classGroups: const [],
      schools: const [],
    );

ss.SmartschoolSnapshot ssSnap({
  List<core.Group>? groups,
  List<ss.SmartschoolAccount>? accounts,
  List<ss.SmartschoolMembership>? memberships,
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: groups ??
          [ssGroup('2B', code: '2B_ss'), ssGroup('3C', code: '3C_ss')],
      accounts: accounts ?? [ssAccount()],
      memberships: memberships ?? [member('jane', '2B_ss')],
    );

az.AzureSnapshot azSnap({List<az.AzureUser>? users}) => az.AzureSnapshot(
      fetchedAt: kFixtureDate,
      users: users ?? [azUser()],
      groups: const [],
    );

/// Deterministic in-memory resolver (mirrors the linker's test fixture).
class SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = <String, String>{};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

// ---------------------------------------------------------------------------
// The harness: the real State layer over scripted syncers.
// ---------------------------------------------------------------------------

/// One assembled reconcile stack against fakes: scripted per-system syncers
/// (with call counters), a [StateApplier] wired to recording connectors, and
/// the [ReconcileController] under test.
class ReconcileHarness {
  ReconcileHarness({
    wapi.WisaSnapshot? wisa,
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
  })  : wisaResult = (wisa ?? wisaSnap()),
        ssResult = (smartschool ?? ssSnap()),
        azResult = (azure ?? azSnap()) {
    log = LogBuffer(clock: () => kFixtureDate);
    final wisaRules = WisaImportRules();

    app = ApplicationState(
      wisa: SystemState<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        syncer: (_) async {
          wisaSyncs++;
          final error = wisaError;
          if (error != null) throw error;
          return wisaResult;
        },
      ),
      smartschool: SystemState<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        syncer: (_) async {
          ssSyncs++;
          return ssResult;
        },
      ),
      azure: SystemState<az.AzureSnapshot>(
        system: core.Origin.azure,
        syncer: (_) async {
          azSyncs++;
          return azResult;
        },
      ),
    );

    applier = StateApplier(
      app: app,
      connectors: actions.Connectors(
        smartschool: ss.SmartschoolConnector.fromParts(
          site: 'demo',
          accessCode: 'secret',
          transport: soap,
        ),
        azure: az.AzureConnector(
          credentials: az.AzureCredentials(
            clientId: 'c',
            tenantId: 't',
            azureDomain: 'school.example',
            schoolPrefix: 'GBS',
          ),
          authProvider: const az.StaticAuthProvider('token'),
          transport: graph,
        ),
      ),
      resolver: SeqResolver(),
      wisaRules: wisaRules,
      studentConfig: actions.StudentActionConfig(
        schoolPrefix: 'GBS',
        azureDomain: 'school.example',
      ),
      staffConfig: actions.StaffActionConfig(
        schoolPrefix: 'GBS',
        azureDomain: 'school.example',
      ),
    );

    controller = ReconcileController(app: app, applier: applier, log: log);
  }

  /// What the next sync of each system returns. Mutate to simulate a change
  /// between syncs; [wisaError] (when set) makes the next WISA sync throw.
  wapi.WisaSnapshot wisaResult;
  ss.SmartschoolSnapshot ssResult;
  az.AzureSnapshot azResult;
  Object? wisaError;

  int wisaSyncs = 0;
  int ssSyncs = 0;
  int azSyncs = 0;

  final RecordingSoap soap = RecordingSoap();
  final RecordingGraph graph = RecordingGraph();

  late final LogBuffer log;
  late final ApplicationState app;
  late final StateApplier applier;
  late final ReconcileController controller;

  /// The bundle the screen's bootstrap seam expects.
  ReconcileServices get services => ReconcileServices(
        settings: const AppSettings(),
        app: app,
        applier: applier,
        controller: controller,
        log: log,
      );

  /// A ready-made bootstrap closure for [ReconcileScreen]/[AccountManagerApp].
  Future<ReconcileServices> Function() get bootstrap => () async => services;
}
