import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

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
