import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Unit coverage for the multi-operator coordination the [InMemoryLinkedStore]
/// models (#108): the sync/drift lease (acquire / renew / expire / block) and
/// the per-system last-sync metadata merge. The Cosmos wire shape is covered
/// separately by `cosmos_linked_store_test`.
void main() {
  final t0 = DateTime.utc(2026, 7, 4, 9, 0);
  MaterializedView view({int generation = 1}) => MaterializedView(
        generation: generation,
        accounts: const [],
        rollups: const [],
      );

  group('sync/drift lease', () {
    test('acquire succeeds when free and readLease returns the live lease',
        () async {
      final store = InMemoryLinkedStore();

      final out = await store.acquireLease(owner: 'jan@school', now: t0);
      expect(out.acquired, isTrue);
      expect(out.lease.owner, 'jan@school');
      expect(out.lease.expiresAt, t0.add(syncLeaseTtl));

      expect((await store.readLease(t0))?.owner, 'jan@school');
    });

    test('a second operator is blocked while a live lease is held', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      final out = await store.acquireLease(owner: 'mieke@school', now: t0);
      expect(out.acquired, isFalse);
      expect(out.heldByOther, isTrue);
      expect(out.lease.owner, 'jan@school',
          reason: 'names the blocking holder');
    });

    test('re-acquiring your own live lease succeeds (idempotent)', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      final out = await store.acquireLease(
        owner: 'jan@school',
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(out.acquired, isTrue);
    });

    test('an expired lease frees for another operator to take over', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);
      final afterExpiry = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));

      // The lease reads as gone once expired…
      expect(await store.readLease(afterExpiry), isNull);
      // …and another operator can take it.
      final out =
          await store.acquireLease(owner: 'mieke@school', now: afterExpiry);
      expect(out.acquired, isTrue);
      expect(out.lease.owner, 'mieke@school');
    });

    test('renew pushes the expiry so the lease is not lost mid-work', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      // Heartbeat just before expiry.
      final beat = t0.add(syncLeaseTtl).subtract(const Duration(seconds: 5));
      final renewed = await store.renewLease(owner: 'jan@school', now: beat);
      expect(renewed.acquired, isTrue);

      // A moment after the *original* expiry the lease is still live.
      final pastOriginal = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));
      expect((await store.readLease(pastOriginal))?.owner, 'jan@school');
    });

    test('renew reports the lease was lost after expiry + takeover', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);
      final afterExpiry = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));
      await store.acquireLease(owner: 'mieke@school', now: afterExpiry);

      final lost =
          await store.renewLease(owner: 'jan@school', now: afterExpiry);
      expect(lost.acquired, isFalse);
      expect(lost.lease.owner, 'mieke@school');
    });

    test('release frees the lease immediately for the next operator', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      await store.releaseLease(owner: 'jan@school');
      expect(await store.readLease(t0), isNull);

      final out = await store.acquireLease(owner: 'mieke@school', now: t0);
      expect(out.acquired, isTrue);
    });

    test('release by a non-owner is a no-op (cannot free a taken lease)',
        () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      await store.releaseLease(owner: 'mieke@school');
      expect((await store.readLease(t0))?.owner, 'jan@school');
    });
  });

  group('per-system sync metadata', () {
    test('writeMaterialized records the systems pulled this pass', () async {
      final store = InMemoryLinkedStore();

      await store.writeMaterialized(
        view(),
        syncedBy: 'jan@school',
        at: t0,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t0),
        },
      );

      final state = await store.readSyncState();
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school');
      expect(state.systems[core.Origin.wisa]?.at, t0);
    });

    test('a system not pulled this pass keeps its earlier stamp', () async {
      final store = InMemoryLinkedStore();
      // Pass 1 pulls WISA.
      await store.writeMaterialized(
        view(),
        syncedBy: 'jan@school',
        at: t0,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t0),
        },
      );
      // Pass 2 (drift) pulls only Azure, by a different operator.
      final t1 = t0.add(const Duration(hours: 1));
      await store.writeMaterialized(
        view(generation: 2),
        syncedBy: 'mieke@school',
        at: t1,
        systemSyncs: {
          core.Origin.azure: SystemSyncMeta(syncedBy: 'mieke@school', at: t1),
        },
      );

      final state = await store.readSyncState();
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school',
          reason: 'WISA keeps pass 1');
      expect(state.systems[core.Origin.azure]?.syncedBy, 'mieke@school');
    });

    test('recordSystemSync merges without bumping the generation', () async {
      final store = InMemoryLinkedStore();
      await store.writeMaterialized(view(), syncedBy: 'jan@school', at: t0);
      expect((await store.readSyncState()).generation, 1);

      final t1 = t0.add(const Duration(hours: 1));
      await store.recordSystemSync({
        core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t1),
      });

      final state = await store.readSyncState();
      expect(state.generation, 1, reason: 'a metadata touch is not a new view');
      expect(state.systems[core.Origin.wisa]?.at, t1);
    });
  });

  group('SyncState / SystemSyncMeta round-trip', () {
    test('json survives with per-system metadata', () {
      final state = SyncState(
        generation: 3,
        updatedAt: t0,
        updatedBy: 'jan@school',
        systems: {
          core.Origin.smartschool:
              SystemSyncMeta(syncedBy: 'mieke@school', at: t0),
        },
      );

      final back = SyncState.fromJson(state.toJson());
      expect(back.generation, 3);
      expect(back.systems[core.Origin.smartschool]?.syncedBy, 'mieke@school');
      expect(back.systems[core.Origin.smartschool]?.at, t0);
    });
  });
}
