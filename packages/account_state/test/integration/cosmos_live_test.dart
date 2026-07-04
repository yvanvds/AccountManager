@Timeout(Duration(minutes: 2))
library;

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in live round-trip of the Cosmos adapters against the real account
/// (`accountmanager-cosmos-arcadia`, issue #114).
///
/// Exercises [HttpCosmosClient] + the three adapters end to end: the AAD auth
/// header, the partition-key headers, the `/naturalKey` unique-key convergence,
/// and query paging — none of which a fake transport can prove. It is
/// **write-capable**, so per the repo live-testing policy it is manual/opt-in
/// only (not CI): each test restores or deletes what it wrote (the settings and
/// queue tests read-modify-restore their singleton documents; the identity test
/// mints a disposable namespaced key and deletes it).
///
/// Offline by default: with no `COSMOS_ACCESS_TOKEN` the config is null and the
/// group is skipped, so `dart test` stays hermetic. Run it via `/live-tests
/// cosmos` (see `.cosmos.env.example`), which mints a fresh token for
/// `https://cosmos.azure.com`.
void main() {
  final config = CosmosLiveConfig.fromEnvironment();

  group(
    'Cosmos adapters live round-trip',
    () {
      late HttpCosmosTransport transport;
      late CosmosClient client;

      setUp(() {
        transport = HttpCosmosTransport();
        client = HttpCosmosClient(
          config: CosmosConfig(
            endpoint: config!.endpoint,
            database: config.database,
          ),
          transport: transport,
          tokens: StaticCosmosTokenProvider(config.accessToken),
        );
      });

      tearDown(() => transport.close());

      test('settings store round-trips (read-modify-restore)', () async {
        final store = CosmosSettingsStore(client);
        final original = await store.load();
        try {
          await store.save(const AppSettings(schoolPrefix: 'LIVE-PROBE'));
          final loaded = await store.load();
          expect(loaded.schoolPrefix, 'LIVE-PROBE');
        } finally {
          await store.save(original); // leave the container as we found it
        }
      });

      test('password queue round-trips (read-modify-restore)', () async {
        final store = CosmosPasswordQueueStore(client);
        final original = await store.load();
        try {
          await store.save(const [
            PasswordEntry(
              personId: PersonId('live-probe'),
              kind: PasswordAccountKind.account,
              accountName: 'live.probe',
              displayName: 'Live Probe',
            ),
          ]);
          final loaded = await store.load();
          expect(loaded.single.accountName, 'live.probe');
        } finally {
          await store.save(original);
        }
      });

      test('two resolvers minting the same disposable key converge', () async {
        // Namespaced so it can never collide with a real natural key, and
        // deleted afterwards so the identity container is left untouched.
        final key = 'live-test:cosmos-probe-${config!.database}';
        await _deleteLeftover(client, key); // clean any leftover from a crash

        final a = CosmosPersonIdResolver(client: client);
        final b = CosmosPersonIdResolver(client: client);
        await Future.wait([
          a.prepare([key]),
          b.prepare([key]),
        ]);

        final idA = a.resolve(key);
        expect(idA, equals(b.resolve(key)), reason: 'both adopt the winner');

        // Cleanup: the document id equals the winning personId.
        await client.deleteDocument(
          container: identityContainer,
          id: idA.value,
          partitionKey: identityPartitionKeyValue,
        );
      });
    },
    skip: config == null
        ? 'Set COSMOS_ACCESS_TOKEN (+ COSMOS_ENDPOINT, COSMOS_DATABASE) to run '
            'the live Cosmos round-trip; see .cosmos.env.example.'
        : false,
  );
}

/// Best-effort delete of any leftover identity document for [naturalKey] from a
/// prior aborted run, so the convergence test starts clean.
Future<void> _deleteLeftover(CosmosClient client, String naturalKey) async {
  final rows = await client.queryDocuments(
    container: identityContainer,
    partitionKey: identityPartitionKeyValue,
    query: 'SELECT c.id FROM c WHERE c.naturalKey = @k',
    parameters: {'@k': naturalKey},
  );
  for (final row in rows) {
    await client.deleteDocument(
      container: identityContainer,
      id: row['id'] as String,
      partitionKey: identityPartitionKeyValue,
    );
  }
}
