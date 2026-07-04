import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

import '../blob/fake_blob_store.dart';
import 'fake_cosmos_client.dart';

void main() {
  group('CosmosSnapshotStore', () {
    late FakeCosmosClient cosmos;
    late FakeBlobStore blobs;
    late CosmosSnapshotStore store;

    setUp(() {
      cosmos = FakeCosmosClient();
      blobs = FakeBlobStore();
      store = CosmosSnapshotStore(cosmos, blobs);
    });

    test('load returns null before anything is saved (first run)', () async {
      expect(await store.load(core.Origin.wisa), isNull);
    });

    test('inline save/load round-trips payload and metadata', () async {
      await store.save(
        core.Origin.smartschool,
        payload: {'accounts': 2, 'note': 'inline'},
        fetchedAt: DateTime.utc(2026, 7, 4, 10),
        syncedBy: 'op@school.example',
      );

      final loaded = await store.load(core.Origin.smartschool);
      expect(loaded, isNotNull);
      expect(loaded!.payload, {'accounts': 2, 'note': 'inline'});
      expect(loaded.fetchedAt, DateTime.utc(2026, 7, 4, 10));
      expect(loaded.syncedBy, 'op@school.example');
      expect(loaded.deltaToken, isNull);
      // Small payload stays inline — Blob is untouched.
      expect(blobs.writes, 0);
    });

    test('Azure delta token round-trips through the metadata', () async {
      await store.save(
        core.Origin.azure,
        payload: {'users': 1, 'deltaToken': 'TOK-1'},
        fetchedAt: DateTime.utc(2026, 7, 4, 11),
        syncedBy: 'op@school.example',
        deltaToken: 'TOK-1',
      );

      final loaded = await store.load(core.Origin.azure);
      expect(loaded!.deltaToken, 'TOK-1');

      // The metadata document carries the token so the sync process can resume
      // /users/delta without fetching the payload.
      final doc = await cosmos.readDocument(
        container: snapshotsContainer,
        id: 'azure',
        partitionKey: 'azure',
      );
      expect(doc!['deltaToken'], 'TOK-1');
    });

    test('a payload over the inline limit overflows to Blob', () async {
      // A 1-byte inline ceiling forces every payload to Blob.
      final tiny = CosmosSnapshotStore(cosmos, blobs, inlineLimitBytes: 1);
      await tiny.save(
        core.Origin.wisa,
        payload: {'students': List.generate(50, (i) => 'student-$i')},
        fetchedAt: DateTime.utc(2026, 7, 4, 12),
        syncedBy: 'op@school.example',
      );

      expect(blobs.writes, 1);
      final doc = await cosmos.readDocument(
        container: snapshotsContainer,
        id: 'wisa',
        partitionKey: 'wisa',
      );
      // The document holds a blobRef, not the payload.
      expect(doc!.containsKey('blobRef'), isTrue);
      expect(doc.containsKey('payload'), isFalse);

      // Load transparently fetches the payload back from Blob.
      final loaded = await tiny.load(core.Origin.wisa);
      expect(loaded!.payload['students'], hasLength(50));
      expect(blobs.reads, 1);
    });

    test('overflow blob name is deterministic (re-sync overwrites)', () async {
      final tiny = CosmosSnapshotStore(cosmos, blobs, inlineLimitBytes: 1);
      await tiny.save(
        core.Origin.wisa,
        payload: {'v': 1},
        fetchedAt: DateTime.utc(2026, 7, 4, 12),
        syncedBy: 'op',
      );
      await tiny.save(
        core.Origin.wisa,
        payload: {'v': 2},
        fetchedAt: DateTime.utc(2026, 7, 4, 13),
        syncedBy: 'op',
      );
      // Two writes, but a single blob (same name overwritten) — no leak.
      expect(blobs.writes, 2);
      expect(blobs.count, 1);
      expect((await tiny.load(core.Origin.wisa))!.payload, {'v': 2});
    });

    test('load returns null when a blobRef points at a vanished blob',
        () async {
      final tiny = CosmosSnapshotStore(cosmos, blobs, inlineLimitBytes: 1);
      await tiny.save(
        core.Origin.azure,
        payload: {'users': 1},
        fetchedAt: DateTime.utc(2026, 7, 4, 12),
        syncedBy: 'op',
      );
      // Simulate the blob being gone while the metadata survives.
      await blobs.delete('snapshot-azure.json');

      expect(await tiny.load(core.Origin.azure), isNull);
    });

    test('re-save replaces the stored snapshot (drift)', () async {
      await store.save(
        core.Origin.smartschool,
        payload: {'v': 1},
        fetchedAt: DateTime.utc(2026, 7, 4, 9),
        syncedBy: 'op',
      );
      await store.save(
        core.Origin.smartschool,
        payload: {'v': 2},
        fetchedAt: DateTime.utc(2026, 7, 4, 15),
        syncedBy: 'op2',
      );

      final loaded = await store.load(core.Origin.smartschool);
      expect(loaded!.payload, {'v': 2});
      expect(loaded.fetchedAt, DateTime.utc(2026, 7, 4, 15));
      expect(loaded.syncedBy, 'op2');
    });

    test('the wildcard origins are not storable', () async {
      expect(
        () => store.save(
          core.Origin.all,
          payload: const {},
          fetchedAt: DateTime.utc(2026),
          syncedBy: 'op',
        ),
        throwsArgumentError,
      );
      expect(() => store.load(core.Origin.other), throwsArgumentError);
    });
  });
}
