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
import 'dart:convert';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/passwords/password_backends.dart';
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

/// A recording [PasswordBackends] for the on-demand Passwords screen (#180):
/// captures every live push a generation/reset would make and reports success,
/// so the reworked Passwords screen can be driven end-to-end with zero network.
/// A username in [failSmartschool] / mail in [failAzure] makes that push report
/// failure, exercising the controller's per-target failure handling.
class RecordingPasswordBackends implements PasswordBackends {
  RecordingPasswordBackends({
    this.failSmartschool = const <String>{},
    this.failAzure = const <String>{},
  });

  /// Smartschool usernames whose push should fail.
  final Set<String> failSmartschool;

  /// Azure mails/UPNs whose push should fail (models "no Azure account").
  final Set<String> failAzure;

  /// Every Smartschool push: `(uid, slot, password)`.
  final List<(String, core.AccountType, String)> smartschoolPushes =
      <(String, core.AccountType, String)>[];

  /// Every Azure push: `(mailOrUpn, password)`.
  final List<(String, String)> azurePushes = <(String, String)>[];

  @override
  Future<bool> setSmartschoolPassword(
    String uid,
    core.AccountType slot,
    String password,
  ) async {
    if (failSmartschool.contains(uid)) return false;
    smartschoolPushes.add((uid, slot, password));
    return true;
  }

  @override
  Future<bool> setAzurePassword(String mailOrUpn, String password) async {
    if (failAzure.contains(mailOrUpn)) return false;
    azurePushes.add((mailOrUpn, password));
    return true;
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
  String givenName = 'Jane',
  String surname = 'Doe',
  core.Address address = _addr,
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: givenName,
      surname: surname,
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

/// A Smartschool snapshot shaped for the reworked Passwords screen (#180): a
/// "Leerlingen" root holding one class (3C) with two students, and a
/// "Personeel" group with one staff member. Drives the on-demand generation /
/// reset flows end-to-end.
ss.SmartschoolSnapshot passwordsSnap() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        const core.Group(
          id: core.GroupId('leerlingen'),
          name: 'Leerlingen',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
        const core.Group(
          id: core.GroupId('3C'),
          name: '3C',
          description: '',
          type: core.GroupType.classGroup,
          official: true,
          origin: core.Origin.smartschool,
          parentId: core.GroupId('leerlingen'),
        ),
        const core.Group(
          id: core.GroupId('personeel'),
          name: 'Personeel',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(uid: 'jane', accountId: '1', mail: 'jane@student.school'),
        ssAccount(uid: 'bob', accountId: '2', mail: 'bob@student.school'),
        ssAccount(uid: 'anna.smit', accountId: '3', mail: 'anna@school'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('jane', '3C'),
        member('bob', '3C'),
        member('anna.smit', 'personeel'),
      ],
    );

/// A Smartschool snapshot with a "Personeel" group holding three staff members
/// seeded **out of alphabetical order** and across mixed casing (Charlie/alice/
/// Bob) — the fixture for the Passwords personeel default-filter + sort rework
/// (#186). The controller must expose them sorted by the displayed "Voornaam
/// Naam" name (alice, Bob, Charlie) with voornaam as the default filter field.
ss.SmartschoolSnapshot staffOrderSnap() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        ssGroup('Personeel', code: 'personeel', type: core.GroupType.group),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(
            uid: 'charlie',
            accountId: '1',
            givenName: 'Charlie',
            surname: 'Zulu'),
        ssAccount(
            uid: 'alice', accountId: '2', givenName: 'alice', surname: 'Bravo'),
        ssAccount(
            uid: 'bob', accountId: '3', givenName: 'Bob', surname: 'Alpha'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('charlie', 'personeel'),
        member('alice', 'personeel'),
        member('bob', 'personeel'),
      ],
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
ReconcileHarness manyDepartedHarness({
  int count = 2000,
  LinkedStore? controllerStore,
}) =>
    ReconcileHarness(
      controllerStore: controllerStore,
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

// ---------------------------------------------------------------------------
// Passive-session materialized-view fixtures for the Actions filter tests
// (#187): hand-built account docs so one classroom can hold a controlled mix of
// accounts with and without applyable actions and with distinct names, then
// seeded straight into an [InMemoryLinkedStore] a passive session reads back.
// ---------------------------------------------------------------------------

/// One [MaterializedAccount] for a passive-session classroom, placed in
/// [school]/[gradeYear]/[classroom]. [withAction] decides whether it carries an
/// applyable candidate — i.e. whether [MaterializedAccount.hasPending] is true,
/// the "has actions" predicate the toggle filters on.
MaterializedAccount matAccount({
  required String id,
  required String label,
  String school = '1',
  String schoolLabel = 'School 1',
  String gradeYear = '3',
  String classroom = '3C',
  bool isStaff = false,
  bool withAction = false,
}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: schoolLabel,
      gradeYear: gradeYear,
      classroom: classroom,
      role: isStaff ? core.PersonRole.teacher : core.PersonRole.student,
      isStaff: isStaff,
      confidence: core.LinkConfidence.high,
      label: label,
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      candidates: withAction
          ? <CandidateAction>[
              CandidateAction(
                family: isStaff ? 'staff' : 'student',
                kind: 'MoveToSmartschoolClassGroup',
                system: core.Origin.smartschool,
                summary: 'Wijzig de klas in Smartschool',
              ),
            ]
          : const <CandidateAction>[],
    );

/// A staff [MaterializedAccount] in the synthetic "Personeel" school/class the
/// Personeel tab drills into (all staff share one bucket).
MaterializedAccount matStaff({
  required String id,
  required String label,
  bool withAction = false,
}) =>
    matAccount(
      id: id,
      label: label,
      school: staffPartition,
      schoolLabel: 'Personeel',
      gradeYear: 'Personeel',
      classroom: 'Personeel',
      isStaff: true,
      withAction: withAction,
    );

/// An [InMemoryLinkedStore] seeded with [accounts] and their derived rollups —
/// the shared materialized view a passive Actions session reads with no pull and
/// no `link()` (#187).
Future<InMemoryLinkedStore> seededLinkedStore(
  List<MaterializedAccount> accounts, {
  String syncedBy = 'operator@school.example',
}) async {
  final store = InMemoryLinkedStore();
  await store.writeMaterialized(
    MaterializedView(
      generation: 1,
      accounts: accounts,
      rollups: buildRollups(accounts),
    ),
    syncedBy: syncedBy,
    at: kFixtureDate,
  );
  return store;
}

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

/// A [CosmosTransport] serving a tiny in-memory Cosmos data plane that answers
/// a stretch of the write burst with **429 TooManyRequests** — the shared-store
/// persist of #196 without an account.
///
/// Enough of the wire is modelled for the real [HttpCosmosClient] and
/// [CosmosLinkedStore] to run against it unchanged (point reads, upserts,
/// atomic creates, deletes, and the `SELECT`s the store issues), so a test can
/// drive the *production* persist path end-to-end and watch a throttled write
/// burst either survive or leave the containers half-written.
class ThrottlingCosmosWire implements CosmosTransport {
  ThrottlingCosmosWire({
    this.throttleFrom = 30,
    this.throttleUntil = 120,
    this.retryAfterMs = 5,
  });

  /// Write attempt (1-based) from which the account starts throttling, and the
  /// one after which it stops. Every attempt — retries included — advances the
  /// counter, so the burst drains the window the way a real recovery does.
  final int throttleFrom;
  final int throttleUntil;

  /// What the 429 puts in `x-ms-retry-after-ms`. Tiny, because the client's
  /// sleep is collapsed to nothing in tests anyway.
  final int retryAfterMs;

  final Map<String, Map<String, Map<String, dynamic>>> _docs = {};

  /// Every document write the client attempted, retries included.
  int writeAttempts = 0;

  /// Accepted document writes per container (retries and 429s excluded) — what
  /// the account was actually asked to store, so a test can tell a pass that
  /// rewrote the world from one that wrote only what changed (#200).
  final Map<String, int> writesByContainer = {};

  int writesTo(String container) => writesByContainer[container] ?? 0;

  /// How many of those were answered with a 429.
  int throttledResponses = 0;

  int _etag = 0;

  /// How many documents the container holds — what the shared state actually
  /// ended up with.
  int docCount(String container) => _docs[container]?.length ?? 0;

  Map<String, Map<String, dynamic>> _c(String name) =>
      _docs.putIfAbsent(name, () => {});

  @override
  Future<CosmosResponse> send(CosmosRequest request) async {
    // A real round trip is async, so writes genuinely overlap and the bounded
    // fan-out is exercised rather than collapsing to a serial loop.
    await Future<void>.delayed(Duration.zero);
    final segments = request.url.pathSegments;
    final container = segments.length > 3 ? segments[3] : '';
    final isQuery = request.headers['x-ms-documentdb-isquery'] == 'true';
    switch (request.method) {
      case 'POST' when isQuery:
        return _query(container, request);
      case 'POST' when segments.length >= 5:
        return _write(container, request);
      case 'POST':
        return const CosmosResponse(statusCode: 201, body: '{}');
      case 'GET' when segments.length >= 6:
        final doc = _c(container)[segments[5]];
        return doc == null
            ? const CosmosResponse(statusCode: 404)
            : CosmosResponse(statusCode: 200, body: jsonEncode(doc));
      case 'GET':
        return const CosmosResponse(statusCode: 200, body: '{}');
      case 'DELETE' when segments.length >= 6:
        final gone = _c(container).remove(segments[5]);
        return CosmosResponse(statusCode: gone == null ? 404 : 204);
    }
    return const CosmosResponse(statusCode: 400);
  }

  CosmosResponse _write(String container, CosmosRequest request) {
    writeAttempts++;
    if (writeAttempts >= throttleFrom && writeAttempts <= throttleUntil) {
      throttledResponses++;
      return CosmosResponse(
        statusCode: 429,
        headers: {'x-ms-retry-after-ms': '$retryAfterMs'},
        body: '{"code":"TooManyRequests","message":"The request rate is too '
            'large. Please retry after sometime."}',
      );
    }
    final decoded = jsonDecode(request.body ?? '{}');
    final doc = Map<String, dynamic>.from(decoded as Map);
    final id = doc['id'] as String;
    final store = _c(container);
    final isUpsert = request.headers['x-ms-documentdb-is-upsert'] == 'true';
    // An atomic create loses to whoever got there first — what the sync lease
    // relies on.
    if (!isUpsert && store.containsKey(id)) {
      return const CosmosResponse(
        statusCode: 409,
        body: '{"code":"Conflict","message":"id already exists"}',
      );
    }
    final etag = 'etag-${++_etag}';
    writesByContainer[container] = writesTo(container) + 1;
    store[id] = {...doc, '_etag': etag};
    return CosmosResponse(
      statusCode: isUpsert ? 200 : 201,
      headers: {'etag': etag},
      body: jsonEncode(store[id]),
    );
  }

  CosmosResponse _query(String container, CosmosRequest request) {
    final body = Map<String, dynamic>.from(
      jsonDecode(request.body ?? '{}') as Map,
    );
    final query = body['query'] as String? ?? '';
    final parameters = <String, Object?>{
      for (final p in (body['parameters'] as List? ?? const []))
        (p as Map)['name'] as String: p['value'],
    };
    final pkHeader = request.headers['x-ms-documentdb-partitionkey'];
    final pk = pkHeader == null
        ? null
        : (jsonDecode(pkHeader) as List).first as String;
    var rows = <Map<String, dynamic>>[
      for (final d in _c(container).values)
        if (pk == null || d['pk'] == pk) Map<String, dynamic>.from(d),
    ];
    if (query.contains('c.classroom = @classroom')) {
      final want = parameters['@classroom'];
      rows = [
        for (final d in rows)
          if (d['classroom'] == want) d
      ];
    }
    if (query.contains('SELECT c.id, c.pk')) {
      // A projection returns the named fields only — including the content hash
      // the store compares against (#200), absent where the document has none.
      rows = [
        for (final d in rows)
          {
            'id': d['id'],
            'pk': d['pk'],
            if (query.contains('c.$contentHashField') &&
                d.containsKey(contentHashField))
              contentHashField: d[contentHashField],
          },
      ];
    }
    return CosmosResponse(
      statusCode: 200,
      body: jsonEncode({'Documents': rows}),
    );
  }
}

/// The *production* shared-store write path over [wire]: a real
/// [CosmosLinkedStore] on a real [HttpCosmosClient], sharing [governor] exactly
/// as `bootstrapReconcile` wires them (#196). The retry sleep is collapsed to
/// nothing so a throttled persist is exercised with no wall-clock waiting.
CosmosLinkedStore cosmosLinkedStoreOver(
  ThrottlingCosmosWire wire, {
  required CosmosThrottleGovernor governor,
}) =>
    CosmosLinkedStore(
      HttpCosmosClient(
        config: const CosmosConfig(
          endpoint: 'https://fake.documents.azure.com:443/',
          database: 'accountmanager',
        ),
        transport: wire,
        tokens: const StaticCosmosTokenProvider('fake-token'),
        governor: governor,
        sleep: (_) async {},
      ),
      governor: governor,
    );

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

  /// The recording live-write seam for the on-demand Passwords screen (#180):
  /// captures every Smartschool/Azure push a generation or reset performs.
  final RecordingPasswordBackends passwordBackends =
      RecordingPasswordBackends();

  /// Every password export the screen wrote (#195), as
  /// `(suggestedName, bytes)`. Recorded instead of written so driving the
  /// export button never drops cleartext password sheets on the test machine.
  final List<(String, List<int>)> passwordWrites = <(String, List<int>)>[];

  /// Every path the screen asked the platform to open after an export (#195).
  final List<String> passwordOpens = <String>[];

  /// When set, the recording opener throws it — the "the viewer would not
  /// launch" case, which must not cost the operator the written file.
  Object? passwordOpenError;

  /// The bundle the screen's bootstrap seam expects.
  ReconcileServices get services => ReconcileServices(
        settings: const AppSettings(),
        app: app,
        applier: applier,
        controller: controller,
        log: log,
        passwordQueue: passwordQueue,
        passwordBackends: passwordBackends,
        passwordFileWriter: (name, bytes) async {
          passwordWrites.add((name, List<int>.of(bytes)));
          return 'C:/exports/$name';
        },
        passwordFileOpener: (path) async {
          final error = passwordOpenError;
          if (error != null) throw error;
          passwordOpens.add(path);
        },
      );

  /// A ready-made bootstrap closure for [ReconcileScreen]/[AccountManagerApp].
  Future<ReconcileServices> Function() get bootstrap => () async => services;
}
