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
  });
}
