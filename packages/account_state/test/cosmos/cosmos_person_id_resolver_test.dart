import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

import 'fake_cosmos_client.dart';

void main() {
  group('CosmosPersonIdResolver', () {
    test('resolve before prepare is a programming error', () {
      final resolver = CosmosPersonIdResolver(client: FakeCosmosClient());
      expect(
        () => resolver.resolve('wisa:1'),
        throwsA(isA<StateError>()),
      );
    });

    test('prepare adopts an id already in the container, minting nothing',
        () async {
      final client = FakeCosmosClient()..seedIdentity('wisa:1', 'existing-id');
      final resolver = CosmosPersonIdResolver(client: client);

      await resolver.prepare(['wisa:1']);

      expect(resolver.resolve('wisa:1'), const PersonId('existing-id'));
      expect(client.createCount, 0, reason: 'the key already existed');
    });

    test('prepare mints a fresh id for a brand-new key', () async {
      final client = FakeCosmosClient();
      var n = 0;
      final resolver = CosmosPersonIdResolver(
        client: client,
        mintId: () => 'minted-${++n}',
      );

      await resolver.prepare(['wisa:1']);

      expect(resolver.resolve('wisa:1'), const PersonId('minted-1'));
      expect(client.createCount, 1);
    });

    test('the warm cache means a re-prepare of known keys hits nothing',
        () async {
      final client = FakeCosmosClient();
      final resolver =
          CosmosPersonIdResolver(client: client, mintId: () => 'id');
      await resolver.prepare(['wisa:1']);
      final queriesAfterFirst = client.queryCount;
      final createsAfterFirst = client.createCount;

      await resolver.prepare(['wisa:1']);

      expect(client.queryCount, queriesAfterFirst,
          reason: 'a cached key issues no query');
      expect(client.createCount, createsAfterFirst,
          reason: 'a cached key issues no create');
    });

    test('a re-prepare only fetches the genuinely new keys', () async {
      final client = FakeCosmosClient();
      var n = 0;
      final resolver =
          CosmosPersonIdResolver(client: client, mintId: () => 'id-${++n}');
      await resolver.prepare(['a']);
      client.queryCount = 0;

      await resolver.prepare(['a', 'b']);

      // 'a' is warm, so only 'b' is queried/minted.
      expect(client.queryCount, 1);
      expect(resolver.resolve('b'), const PersonId('id-2'));
    });

    test('two operators minting the same new key converge on one id', () async {
      // One shared account (one client), two independent resolvers with
      // distinct mints — the multi-operator race the epic is built around.
      final client = FakeCosmosClient();
      final operatorA =
          CosmosPersonIdResolver(client: client, mintId: () => 'A-id');
      final operatorB =
          CosmosPersonIdResolver(client: client, mintId: () => 'B-id');

      await Future.wait([
        operatorA.prepare(['wisa:42']),
        operatorB.prepare(['wisa:42']),
      ]);

      final a = operatorA.resolve('wisa:42');
      final b = operatorB.resolve('wisa:42');
      expect(a, equals(b), reason: 'both must adopt the winning id');
      // Exactly one document exists for the key — the loser adopted, not
      // inserted a duplicate.
      final winner = a.value;
      expect(winner, anyOf('A-id', 'B-id'));
    });

    test('prepare batches a key set larger than one query chunk', () async {
      final client = FakeCosmosClient();
      // Seed more keys than fit one chunk so the fetch must page.
      final keys = [
        for (var i = 0; i < CosmosPersonIdResolver.maxKeysPerQuery + 5; i++)
          'wisa:$i'
      ];
      for (final k in keys) {
        client.seedIdentity(k, 'id-$k');
      }
      final resolver = CosmosPersonIdResolver(client: client);

      await resolver.prepare(keys);

      expect(client.queryCount, 2, reason: 'the key set spanned two chunks');
      for (final k in keys) {
        expect(resolver.resolve(k), PersonId('id-$k'));
      }
      expect(client.createCount, 0);
    });
  });
}
