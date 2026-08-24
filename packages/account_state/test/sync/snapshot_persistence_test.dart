import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// An in-memory [SnapshotStore] that records saves, for testing the
/// seed/persist wiring without Cosmos or Blob.
class _MemorySnapshotStore implements SnapshotStore {
  final Map<core.Origin, StoredSnapshot> _byOrigin = {};
  int saves = 0;
  Object? failWith;

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
    if (failWith != null) throw failWith!;
    saves++;
    _byOrigin[system] = StoredSnapshot(
      payload: payload,
      fetchedAt: fetchedAt,
      syncedBy: syncedBy,
      deltaToken: deltaToken,
    );
  }
}

AzureSnapshot _azSnap({String? deltaToken}) => AzureSnapshot(
      fetchedAt: DateTime.utc(2026, 7, 4, 10),
      deltaToken: deltaToken,
      users: const [AzureUser(id: 'i1', upn: 'a@b', employeeId: 'W1')],
      groups: const [],
    );

WisaSnapshot _wisaSnap({List<WisaStaff> staff = const []}) => WisaSnapshot(
      fetchedAt: DateTime.utc(2026, 7, 4, 9),
      students: const [],
      staff: staff,
      classGroups: const [],
      schools: const [],
    );

WisaStaff _staff(String code) => WisaStaff(
      code: core.WisaStaffCode(code),
      firstName: 'Jan',
      lastName: 'Smit',
      schoolIds: const {1},
    );

SmartschoolSnapshot _ssSnap() => SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026, 7, 4, 9),
      groups: const [],
      accounts: const [],
      memberships: const [],
    );

/// An [ApplicationState] over three snapshots that no syncer ever replaces —
/// every pull throws, so a test that expects a write-back can only be seeing
/// the patched copy.
ApplicationState _app({
  WisaSnapshot? wisa,
  SmartschoolSnapshot? smartschool,
  AzureSnapshot? azure,
}) {
  SystemState<S> state<S extends core.Snapshot>(
          core.Origin system, S initial) =>
      SystemState<S>(
        system: system,
        initial: initial,
        syncer: (_, {bool fullRead = false}) async =>
            throw StateError('no pull expected for $system'),
      );
  return ApplicationState(
    wisa: state(core.Origin.wisa, wisa ?? _wisaSnap()),
    smartschool: state(core.Origin.smartschool, smartschool ?? _ssSnap()),
    azure: state(core.Origin.azure, azure ?? _azSnap()),
  );
}

void main() {
  group('persistingSyncer', () {
    test('persists the fresh snapshot after a successful pull', () async {
      final store = _MemorySnapshotStore();
      final syncer = persistingSyncer<AzureSnapshot>(
        system: core.Origin.azure,
        store: store,
        syncedBy: 'op@school.example',
        payloadOf: (s) => s.toJson(),
        deltaTokenOf: (s) => s.deltaToken,
        inner: (_, {bool fullRead = false}) async =>
            _azSnap(deltaToken: 'TOK-9'),
      );

      final fresh = await syncer(null);

      expect(fresh.deltaToken, 'TOK-9');
      expect(store.saves, 1);
      final stored = await store.load(core.Origin.azure);
      expect(stored!.syncedBy, 'op@school.example');
      expect(stored.deltaToken, 'TOK-9');
      // The payload reconstructs the snapshot (token included).
      expect(AzureSnapshot.fromJson(stored.payload).deltaToken, 'TOK-9');
    });

    test('a store write failure is best-effort: pull still succeeds', () async {
      final store = _MemorySnapshotStore()
        ..failWith = StateError('cosmos down');
      Object? reported;
      final syncer = persistingSyncer<AzureSnapshot>(
        system: core.Origin.azure,
        store: store,
        syncedBy: 'op',
        payloadOf: (s) => s.toJson(),
        onError: (e) => reported = e,
        inner: (_, {bool fullRead = false}) async => _azSnap(),
      );

      final fresh = await syncer(null);

      // The operator still gets the fresh snapshot this session…
      expect(fresh, isA<AzureSnapshot>());
      // …the failure is surfaced, not swallowed silently…
      expect(reported, isA<StateError>());
      // …and nothing was persisted.
      expect(store.saves, 0);
    });

    test('a failing inner pull is not persisted and propagates', () async {
      final store = _MemorySnapshotStore();
      final syncer = persistingSyncer<AzureSnapshot>(
        system: core.Origin.azure,
        store: store,
        syncedBy: 'op',
        payloadOf: (s) => s.toJson(),
        inner: (_, {bool fullRead = false}) async => throw Exception('network'),
      );

      await expectLater(syncer(null), throwsException);
      expect(store.saves, 0);
    });
  });

  group('persistPatchedSnapshots', () {
    test('writes back a patched snapshot so a cold seed sees the drop',
        () async {
      final store = _MemorySnapshotStore();
      final app = _app(wisa: _wisaSnap(staff: [_staff('SMIT')]));
      // What #345 does after a `DontImportFromWisa` apply: the ignored row is
      // filtered out locally, with no pull.
      app.wisa.patch(_wisaSnap());

      await persistPatchedSnapshots(app, store: store, syncedBy: 'op@school');

      expect(store.saves, 1);
      final stored = await store.load(core.Origin.wisa);
      // The next session seeds from this, so the drop has to be in it.
      expect(WisaSnapshot.fromJson(stored!.payload).staff, isEmpty);
      expect(stored.syncedBy, 'op@school');
      // The patch is not a fetch (#345), so the stored freshness is the one the
      // pull left behind — a cold seed must not look newer than it is.
      expect(stored.fetchedAt, DateTime.utc(2026, 7, 4, 9));
    });

    test('leaves the systems this pass never patched alone', () async {
      final store = _MemorySnapshotStore();
      final app = _app();
      app.wisa.patch(_wisaSnap());

      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');

      expect(store.saves, 1);
      expect(await store.load(core.Origin.smartschool), isNull);
      expect(await store.load(core.Origin.azure), isNull);
    });

    test("carries Azure's delta token through the write-back", () async {
      final store = _MemorySnapshotStore();
      final app = _app(azure: _azSnap(deltaToken: 'TOK-9'));
      app.azure.patch(_azSnap(deltaToken: 'TOK-9'));

      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');

      final stored = await store.load(core.Origin.azure);
      // Dropping it here would force the next session into a full tenant read.
      expect(stored!.deltaToken, 'TOK-9');
      expect(AzureSnapshot.fromJson(stored.payload).deltaToken, 'TOK-9');
    });

    test('writes each patched system once, however many patches it took',
        () async {
      final store = _MemorySnapshotStore();
      final app = _app();
      // A pass applying three actions against one system patches three times.
      app.smartschool
        ..patch(_ssSnap())
        ..patch(_ssSnap())
        ..patch(_ssSnap());

      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');
      // …and the second pass, with nothing patched since, writes nothing.
      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');

      expect(store.saves, 1);
    });

    test('a successful pull clears the debt — the syncer already persisted it',
        () async {
      final store = _MemorySnapshotStore();
      final pulled = _wisaSnap(staff: [_staff('JANS')]);
      final wisa = SystemState<WisaSnapshot>(
        system: core.Origin.wisa,
        initial: _wisaSnap(staff: [_staff('SMIT')]),
        syncer: (_, {bool fullRead = false}) async => pulled,
      );
      final app = ApplicationState(
        wisa: wisa,
        smartschool: _app().smartschool,
        azure: _app().azure,
      );

      wisa.patch(_wisaSnap());
      expect(wisa.hasUnpersistedPatch, isTrue);
      await wisa.sync();
      expect(wisa.hasUnpersistedPatch, isFalse);

      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');
      expect(store.saves, 0);
    });

    test('a failed write is reported, swallowed, and retried next pass',
        () async {
      final store = _MemorySnapshotStore()
        ..failWith = StateError('cosmos down');
      final app = _app();
      app.wisa.patch(_wisaSnap());
      final reported = <core.Origin>[];

      await persistPatchedSnapshots(
        app,
        store: store,
        syncedBy: 'op',
        onError: (system, _) => reported.add(system),
      );

      // The pass survives it: the writes to Smartschool and Office 365 really
      // happened, and a cold-store hiccup must not turn a good pass into a
      // failed one.
      expect(reported, [core.Origin.wisa]);
      expect(app.wisa.hasUnpersistedPatch, isTrue);

      store.failWith = null;
      await persistPatchedSnapshots(app, store: store, syncedBy: 'op');
      expect(store.saves, 1);
      expect(app.wisa.hasUnpersistedPatch, isFalse);
    });
  });

  group('seedSnapshot', () {
    test('reconstructs the stored snapshot for a fresh session', () async {
      final store = _MemorySnapshotStore();
      await store.save(
        core.Origin.azure,
        payload: _azSnap(deltaToken: 'TOK-SEED').toJson(),
        fetchedAt: DateTime.utc(2026, 7, 4, 10),
        syncedBy: 'op',
        deltaToken: 'TOK-SEED',
      );

      final seed = await seedSnapshot<AzureSnapshot>(
        system: core.Origin.azure,
        store: store,
        fromPayload: AzureSnapshot.fromJson,
      );

      expect(seed, isNotNull);
      // The delta token is restored, so the next sync resumes /users/delta.
      expect(seed!.deltaToken, 'TOK-SEED');
      expect(seed.users, hasLength(1));
    });

    test('returns null when nothing is stored (first ever run)', () async {
      final seed = await seedSnapshot<AzureSnapshot>(
        system: core.Origin.azure,
        store: _MemorySnapshotStore(),
        fromPayload: AzureSnapshot.fromJson,
      );
      expect(seed, isNull);
    });

    test('a corrupt stored payload degrades to null (re-pull), not a crash',
        () async {
      final store = _MemorySnapshotStore();
      await store.save(
        core.Origin.azure,
        payload: const {'unexpected': 'shape'},
        fetchedAt: DateTime.utc(2026, 7, 4),
        syncedBy: 'op',
      );
      Object? reported;

      final seed = await seedSnapshot<AzureSnapshot>(
        system: core.Origin.azure,
        store: store,
        fromPayload: AzureSnapshot.fromJson,
        onError: (e) => reported = e,
      );

      expect(seed, isNull);
      expect(reported, isNotNull);
    });
  });
}
