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

import 'dart:async';

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
  int schoolId = 1,
  core.Address address = _addr,
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
      address: address,
      classChange: kFixtureDate,
      schoolId: schoolId,
    );

/// A WISA school, optionally flagged [ours] (the managed-school signal the
/// linker joins student `schoolId` against, #133/#134).
wapi.WisaSchool wisaSchool(int id, {bool ours = false}) =>
    wapi.WisaSchool(id: id, name: 'School $id', description: '', isOurs: ours);

/// A WISA staff record — the personeel counterpart of [wisaStudent]. A staff
/// member present only in WISA (no Smartschool / Azure counterpart) links as a
/// [core.LinkedStaff] and materializes into the synthetic "Personeel" school
/// rollup the Actions Personeel tab drills into (#179).
wapi.WisaStaff wisaStaff({
  String code = 'SMIT',
  String wisaId = '42',
  String firstName = 'Anna',
  String lastName = 'Smit',
}) =>
    wapi.WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: core.WisaId(wisaId),
      firstName: firstName,
      lastName: lastName,
    );

ss.SmartschoolAccount ssAccount({
  String uid = 'jane',
  String accountId = '1',
  String mail = 'jane.doe@student.school.example',
  core.Address address = _addr,
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
      address: address,
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
  List<wapi.WisaStaff> staff = const [],
  List<wapi.WisaSchool> schools = const [],
}) =>
    wapi.WisaSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      students: students ?? [wisaStudent()],
      staff: staff,
      classGroups: const [],
      schools: schools,
    );

ss.SmartschoolSnapshot ssSnap({
  DateTime? fetchedAt,
  List<core.Group>? groups,
  List<ss.SmartschoolAccount>? accounts,
  List<ss.SmartschoolMembership>? memberships,
}) =>
    ss.SmartschoolSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
      groups: groups ??
          [ssGroup('2B', code: '2B_ss'), ssGroup('3C', code: '3C_ss')],
      accounts: accounts ?? [ssAccount()],
      memberships: memberships ?? [member('jane', '2B_ss')],
    );

/// A Smartschool snapshot whose [uids] accounts all share one [mail] — the
/// INV-23 duplicate-mail collision the reconcile screen surfaces (#109). No
/// WISA or Azure counterpart, so the linker keeps every colliding account and
/// raises exactly one [core.ResolveDuplicateMail] warning over them.
ss.SmartschoolSnapshot dupMailSnap({
  List<String> uids = const ['admin', 'user'],
  String mail = 'shared@school.example',
}) =>
    ssSnap(
      groups: const [],
      accounts: [
        for (final u in uids) ssAccount(uid: u, accountId: u, mail: mail),
      ],
      memberships: const [],
    );

/// A reconcile harness over the [dupMailSnap] collision: a WISA-/Azure-empty
/// scenario so the only linked artifact is the shared-mail warning (#109).
ReconcileHarness dupMailHarness({
  List<String> uids = const ['admin', 'user'],
  InMemoryLinkedStore? linkedStore,
  String syncedBy = 'operator@school.example',
}) =>
    ReconcileHarness(
      wisa: wisaSnap(students: const []),
      smartschool: dupMailSnap(uids: uids),
      azure: azSnap(users: const []),
      linkedStore: linkedStore,
      syncedBy: syncedBy,
    );

/// A reconcile harness over [count] WISA-departed, Smartschool-only active
/// accounts (no WISA, no Azure): each raises the mutually-exclusive
/// unregister/delete choice (#110), so the pending list holds [count] entries in
/// one "same situation" subset — a large set to exercise list virtualization
/// (#111).
ReconcileHarness manyDepartedHarness({int count = 2000}) => ReconcileHarness(
      wisa: wisaSnap(students: const []),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          for (var i = 0; i < count; i++)
            ssAccount(
              uid: 'user$i',
              accountId: '$i',
              mail: 'user$i@student.school.example',
            ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

/// A reconcile harness for the group-wide-leave keep-Azure case (#134): one
/// student still in *our* Smartschool and Azure, but whose WISA record now sits
/// only in a sibling group school (id 2) we don't manage — school 1 is flagged
/// ours. The dispatcher must raise the Smartschool departure (unregister/delete)
/// while **keeping** Azure (no `RemoveStudentFromAzure`).
ReconcileHarness movedToSiblingHarness() => ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 2)],
        schools: [wisaSchool(1, ours: true), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
    );

/// A harness for the managed-schools-only Actions filter (#178). One student is
/// enrolled in school 2 and fully present in *our* Smartschool + Azure. The WISA
/// schools carry **no** `MarkAsOurs` flag, so the managed set comes solely from
/// [ourSchoolIds] (the persisted Settings path). Managing only school 1 leaves
/// the student `groupOnly` — kept out of the school tree (re-bucketed to "Niet
/// toegewezen"); adding school 2 to the managed set surfaces it under School 2.
ReconcileHarness managedSchoolsHarness({required Set<int> ourSchoolIds}) =>
    ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 2)],
        schools: [wisaSchool(1), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: ourSchoolIds,
    );

az.AzureSnapshot azSnap({DateTime? fetchedAt, List<az.AzureUser>? users}) =>
    az.AzureSnapshot(
      fetchedAt: fetchedAt ?? kFixtureDate,
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

/// An in-memory [SnapshotStore] shared across two "sessions" of a test, so a
/// second [ReconcileHarness] can seed from what the first persisted (#107). The
/// Cosmos+Blob overflow behaviour is covered by `account_state`'s unit tests;
/// here only the seed/reuse/drift wiring matters.
class InMemorySnapshotStore implements SnapshotStore {
  final Map<core.Origin, StoredSnapshot> _byOrigin = {};

  /// Which systems currently have a stored snapshot — for test assertions.
  Iterable<core.Origin> get storedSystems => _byOrigin.keys;

  StoredSnapshot? peek(core.Origin system) => _byOrigin[system];

  @override
  Future<StoredSnapshot?> load(core.Origin system) async => _byOrigin[system];

  @override
  Future<void> save(
    core.Origin system, {
    required Map<String, dynamic> payload,
    required DateTime fetchedAt,
    required String syncedBy,
    String? deltaToken,
  }) async {
    _byOrigin[system] = StoredSnapshot(
      payload: payload,
      fetchedAt: fetchedAt,
      syncedBy: syncedBy,
      deltaToken: deltaToken,
    );
  }
}

/// A [LinkedStore] whose [writeMaterialized] never completes (a hung Cosmos
/// write) or throws, while every read delegates to an inner [InMemoryLinkedStore]
/// — the persist-stall the reconcile controller must survive (#168).
class StallingLinkedStore implements LinkedStore {
  StallingLinkedStore({InMemoryLinkedStore? inner, this.failWith})
      : _in = inner ?? InMemoryLinkedStore();

  final InMemoryLinkedStore _in;

  /// When set, [writeMaterialized] throws this instead of hanging.
  final Object? failWith;

  /// True once a write was attempted — proves the controller reached persist.
  bool writeAttempted = false;

  @override
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
    void Function(String message)? onProgress,
  }) {
    writeAttempted = true;
    final fail = failWith;
    if (fail != null) return Future<void>.error(fail);
    // Never completes: models a wedged store write the controller must time out.
    return Completer<void>().future;
  }

  @override
  Future<SyncState> readSyncState() => _in.readSyncState();
  @override
  Future<List<Rollup>> readRollups() => _in.readRollups();
  @override
  Future<List<MaterializedAccount>> readClassroom({
    required String school,
    required String classroom,
  }) =>
      _in.readClassroom(school: school, classroom: classroom);
  @override
  Future<List<MaterializedGroup>> readGroups() => _in.readGroups();
  @override
  Future<List<AccountDecision>> readDecisions() => _in.readDecisions();
  @override
  Future<void> putDecision(AccountDecision decision) =>
      _in.putDecision(decision);
  @override
  Future<void> deleteDecision(AccountDecision decision) =>
      _in.deleteDecision(decision);
  @override
  Future<void> recordSystemSync(Map<core.Origin, SystemSyncMeta> systemSyncs) =>
      _in.recordSystemSync(systemSyncs);
  @override
  Future<SyncLease?> readLease(DateTime now) => _in.readLease(now);
  @override
  Future<LeaseOutcome> acquireLease({
    required String owner,
    required DateTime now,
  }) =>
      _in.acquireLease(owner: owner, now: now);
  @override
  Future<LeaseOutcome> renewLease({
    required String owner,
    required DateTime now,
  }) =>
      _in.renewLease(owner: owner, now: now);
  @override
  Future<void> releaseLease({required String owner}) =>
      _in.releaseLease(owner: owner);
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
    this.store,
    InMemoryLinkedStore? linkedStore,
    this.controllerStore,
    this.persistTimeout,
    this.hub,
    SignalPublisher? publisher,
    SignalSubscriber? subscriber,
    wapi.WisaSnapshot? wisaInitial,
    ss.SmartschoolSnapshot? ssInitial,
    az.AzureSnapshot? azureInitial,
    this.azureGate,
    this.syncedBy = 'operator@school.example',
    Set<int>? ourSchoolIds,
  })  : wisaResult = (wisa ?? wisaSnap()),
        ssResult = (smartschool ?? ssSnap()),
        azResult = (azure ?? azSnap()),
        linkedStore = linkedStore ?? InMemoryLinkedStore() {
    log = LogBuffer(clock: () => kFixtureDate);
    final wisaRules = WisaImportRules();

    // The scripted per-system pulls (with call counters). When a [store] is
    // wired, each is wrapped so a successful pull persists — mirroring how
    // bootstrap composes persistence over the real syncers (#107).
    Syncer<wapi.WisaSnapshot> wisaSync = (_) async {
      wisaSyncs++;
      final error = wisaError;
      if (error != null) throw error;
      return wisaResult;
    };
    Syncer<ss.SmartschoolSnapshot> ssSync = (_) async {
      ssSyncs++;
      return ssResult;
    };
    Syncer<az.AzureSnapshot> azSync = (_) async {
      azSyncs++;
      // When a test wires a gate, the Azure pull parks here until released, so
      // a widget test can hold a sync mid-flight and observe the busy progress
      // bar the earlier stages have already advanced (#176).
      final gate = azureGate;
      if (gate != null) await gate.future;
      return azResult;
    };

    final s = store;
    if (s != null) {
      wisaSync = persistingSyncer<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        inner: wisaSync,
      );
      ssSync = persistingSyncer<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        inner: ssSync,
      );
      azSync = persistingSyncer<az.AzureSnapshot>(
        system: core.Origin.azure,
        store: s,
        syncedBy: syncedBy,
        payloadOf: (snap) => snap.toJson(),
        deltaTokenOf: (snap) => snap.deltaToken,
        inner: azSync,
      );
    }

    app = ApplicationState(
      wisa: SystemState<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        initial: wisaInitial,
        syncer: wisaSync,
      ),
      smartschool: SystemState<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        initial: ssInitial,
        syncer: ssSync,
      ),
      azure: SystemState<az.AzureSnapshot>(
        system: core.Origin.azure,
        initial: azureInitial,
        syncer: azSync,
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
      passwordQueue: passwordQueue,
      // The operator's managed-school set from Settings (#178). When unset, the
      // linker falls back to the WISA snapshot's MarkAsOurs flags, as bootstrap
      // does for a not-yet-configured group.
      ourSchoolIds: ourSchoolIds,
    );

    final signalHub = hub;
    controller = ReconcileController(
      app: app,
      applier: applier,
      log: log,
      store: controllerStore ?? this.linkedStore,
      syncedBy: syncedBy,
      publisher: publisher ?? signalHub?.publisher(),
      subscriber: subscriber ?? signalHub?.subscriber(),
      persistTimeout: persistTimeout ?? const Duration(minutes: 10),
      clock: () => kFixtureDate,
    );
  }

  /// An alternate [LinkedStore] handed to the controller instead of the plain
  /// [linkedStore] — used to inject a stalling/failing `writeMaterialized` for
  /// the persist-resilience tests (#168). Reads still resolve through it, so it
  /// normally wraps an [InMemoryLinkedStore].
  final LinkedStore? controllerStore;

  /// The controller's persist-step timeout (#168); defaults to 10 minutes when
  /// unset, and the stall tests inject a tiny value.
  final Duration? persistTimeout;

  /// The shared materialized-view store (#115): a sync writes the derived
  /// per-account docs + rollups here, and a resumed session reads the overview
  /// back with no pull. Shared across sessions via [resume].
  final InMemoryLinkedStore linkedStore;

  /// The shared cold-snapshot store, when this harness models the persistence
  /// wiring (#107). `null` for the plain in-memory scenarios.
  final SnapshotStore? store;

  /// The shared realtime fan-out (#116): when set, this session's controller
  /// publishes change signals to it and subscribes for others'. Share one hub
  /// across sessions to model operators nudging each other in real time.
  final InMemorySignalHub? hub;

  /// The operator (UPN) this session syncs as — the lease owner and the
  /// per-system sync-metadata author (#108). Vary it to model a second operator
  /// sharing the same [linkedStore].
  final String syncedBy;

  /// When set, the Azure syncer parks on this completer until a test releases
  /// it — a seam to freeze a sync mid-pass (WISA + Smartschool already pulled)
  /// so a widget test can observe the busy progress bar (#176).
  final Completer<void>? azureGate;

  /// Builds a "second session" seeded from [store] — a fresh controller over
  /// the state another harness already persisted, the way bootstrap seeds each
  /// [SystemState] from the store on app open (#107).
  static Future<ReconcileHarness> resume({
    required SnapshotStore store,
    InMemoryLinkedStore? linkedStore,
    InMemorySignalHub? hub,
    SignalSubscriber? subscriber,
    wapi.WisaSnapshot? wisa,
    ss.SmartschoolSnapshot? smartschool,
    az.AzureSnapshot? azure,
  }) async {
    final wisaSeed = await seedSnapshot<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      store: store,
      fromPayload: wapi.WisaSnapshot.fromJson,
    );
    final ssSeed = await seedSnapshot<ss.SmartschoolSnapshot>(
      system: core.Origin.smartschool,
      store: store,
      fromPayload: ss.SmartschoolSnapshot.fromJson,
    );
    final azSeed = await seedSnapshot<az.AzureSnapshot>(
      system: core.Origin.azure,
      store: store,
      fromPayload: az.AzureSnapshot.fromJson,
    );
    return ReconcileHarness(
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      store: store,
      linkedStore: linkedStore,
      hub: hub,
      subscriber: subscriber,
      wisaInitial: wisaSeed,
      ssInitial: ssSeed,
      azureInitial: azSeed,
    );
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

  /// The shared password-distribution queue (#105): the applier appends to it on
  /// every account-creating apply, and the Passwords view reads and drains it.
  final InMemoryPasswordQueueStore passwordQueue = InMemoryPasswordQueueStore();

  /// The bundle the screen's bootstrap seam expects.
  ReconcileServices get services => ReconcileServices(
        settings: const AppSettings(),
        app: app,
        applier: applier,
        controller: controller,
        log: log,
        passwordQueue: passwordQueue,
      );

  /// A ready-made bootstrap closure for [ReconcileScreen]/[AccountManagerApp].
  Future<ReconcileServices> Function() get bootstrap => () async => services;
}
