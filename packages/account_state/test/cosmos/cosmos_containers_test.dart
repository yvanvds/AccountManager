import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

import 'fake_cosmos_client.dart';

void main() {
  group('ensureContainers', () {
    test('provisions every materialized-view container with its key path',
        () async {
      final client = FakeCosmosClient();

      await ensureContainers(client);

      expect(client.ensuredContainers, {
        linkedAccountsContainer: '/pk',
        linkedGroupsContainer: '/pk',
        rollupsContainer: '/pk',
        decisionsContainer: '/pk',
        syncStateContainer: '/id',
      });
    });

    test(
        'includes the decisions container the accept-duplicate write needs '
        '(#150)', () async {
      final client = FakeCosmosClient();
      await ensureContainers(client);
      expect(client.ensuredContainers.containsKey(decisionsContainer), isTrue);
    });

    test('is idempotent: a second run does not throw', () async {
      final client = FakeCosmosClient();
      await ensureContainers(client);
      await ensureContainers(client);
      expect(client.ensuredContainers.containsKey(decisionsContainer), isTrue);
    });

    test('honours a custom spec list', () async {
      final client = FakeCosmosClient();
      await ensureContainers(
        client,
        specs: const [CosmosContainerSpec(decisionsContainer, '/pk')],
      );
      expect(client.ensuredContainers, {decisionsContainer: '/pk'});
    });

    test(
        'the bootstrap set provisions the snapshots container the snapshot '
        'store needs (#151)', () async {
      final client = FakeCosmosClient();

      await ensureContainers(client, specs: bootstrapContainers);

      // The snapshot-store write path (CosmosSnapshotStore -> snapshots)
      // 404'd mid-sync because the container was never ensured; the bootstrap
      // set now provisions it, keyed by /id like its singleton documents.
      expect(client.ensuredContainers[snapshotsContainer], '/id');
      // Still covers the sync-lock renewal container (already ensured by #150's
      // linked-store set) so a regression can't silently drop it.
      expect(client.ensuredContainers[syncStateContainer], '/id');
    });

    test('the bootstrap set is the linked-store set plus the snapshot set',
        () async {
      final client = FakeCosmosClient();

      await ensureContainers(client, specs: bootstrapContainers);

      expect(client.ensuredContainers, {
        linkedAccountsContainer: '/pk',
        linkedGroupsContainer: '/pk',
        rollupsContainer: '/pk',
        decisionsContainer: '/pk',
        syncStateContainer: '/id',
        snapshotsContainer: '/id',
      });
    });
  });
}
