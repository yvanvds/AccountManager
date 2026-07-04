import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' show DontImportClass;

import 'fake_cosmos_client.dart';

void main() {
  group('CosmosSettingsStore', () {
    test('an empty container loads a default AppSettings', () async {
      final store = CosmosSettingsStore(FakeCosmosClient());
      expect(await store.load(), const AppSettings());
    });

    test('save then load round-trips the whole config incl. import rules',
        () async {
      final client = FakeCosmosClient();
      final store = CosmosSettingsStore(client);
      final settings = AppSettings(
        schoolPrefix: 'GBS',
        debugMode: true,
        wisa: const WisaConnection(
          server: 'wisa.local',
          port: '9000',
          database: 'wisadb',
          username: 'operator',
          passwordRef: SecretRef('wisa.password'),
        ),
        smartschool: SmartschoolConnection(
          uri: 'https://demo.smartschool.be',
          passphraseRef: const SecretRef('smartschool.passphrase'),
        ),
        azure: const AzureConnection(domain: 'school.example'),
        wisaRules: const [DontImportClass('1A')],
      );

      await store.save(settings);
      final loaded = await store.load();

      expect(loaded.schoolPrefix, 'GBS');
      expect(loaded.debugMode, isTrue);
      expect(loaded.wisa.server, 'wisa.local');
      expect(loaded.wisa.passwordRef, const SecretRef('wisa.password'));
      expect(loaded.smartschool.uri, 'https://demo.smartschool.be');
      expect(loaded.azure.domain, 'school.example');
      expect(loaded.wisaRules, hasLength(1));
      expect(loaded.wisaRules.single, isA<DontImportClass>());
    });

    test('save is a whole-config replace (a later save wins)', () async {
      final store = CosmosSettingsStore(FakeCosmosClient());
      await store.save(const AppSettings(schoolPrefix: 'OLD'));
      await store.save(const AppSettings(schoolPrefix: 'NEW'));
      expect((await store.load()).schoolPrefix, 'NEW');
    });

    test('the settings document lands in the settings container', () async {
      final client = FakeCosmosClient();
      await CosmosSettingsStore(client).save(const AppSettings());
      final doc = await client.readDocument(
        container: settingsContainer,
        id: settingsDocumentId,
        partitionKey: settingsDocumentId,
      );
      expect(doc, isNotNull);
      expect(doc!['settings'], isA<Map<String, dynamic>>());
    });
  });

  group('CosmosPasswordQueueStore', () {
    test('a never-persisted queue loads empty', () async {
      final store = CosmosPasswordQueueStore(FakeCosmosClient());
      expect(await store.load(), isEmpty);
    });

    test('save then load round-trips entries in order', () async {
      final store = CosmosPasswordQueueStore(FakeCosmosClient());
      final entries = [
        const PasswordEntry(
          personId: PersonId('p1'),
          kind: PasswordAccountKind.account,
          accountName: 'jan.jansen',
          displayName: 'Jan Jansen',
          mail: 'jan@school.example',
          classGroup: '3A',
          smartschoolPassword: 'ss-pw',
          azurePassword: 'az-pw',
        ),
        const PasswordEntry(
          personId: PersonId('p2'),
          kind: PasswordAccountKind.coAccount,
          accountName: 'ouder.jansen',
          displayName: 'Ouder Jansen',
        ),
      ];

      await store.save(entries);
      final loaded = await store.load();

      expect(loaded, hasLength(2));
      expect(loaded[0].accountName, 'jan.jansen');
      expect(loaded[0].kind, PasswordAccountKind.account);
      expect(loaded[0].smartschoolPassword, 'ss-pw');
      expect(loaded[1].accountName, 'ouder.jansen');
      expect(loaded[1].kind, PasswordAccountKind.coAccount);
      expect(loaded[1].mail, isNull);
    });

    test('saving an empty list drains the queue', () async {
      final store = CosmosPasswordQueueStore(FakeCosmosClient());
      await store.save(const [
        PasswordEntry(
          personId: PersonId('p1'),
          kind: PasswordAccountKind.account,
          accountName: 'a',
          displayName: 'A',
        ),
      ]);
      await store.save(const []);
      expect(await store.load(), isEmpty);
    });

    test('two operators saving the shared queue serialize via the ETag (#121)',
        () async {
      // One centralized queue, two operators with their own store instances —
      // one generated passwords, the other prints and drains.
      final client = FakeCosmosClient();
      final generator = CosmosPasswordQueueStore(client);
      final printer = CosmosPasswordQueueStore(client);

      // Seed the queue so both operators load a concrete version (ETag).
      const seeded = [
        PasswordEntry(
          personId: PersonId('p1'),
          kind: PasswordAccountKind.account,
          accountName: 'seed',
          displayName: 'Seed',
        ),
      ];
      await CosmosPasswordQueueStore(client).save(seeded);

      // Both load the same version, then race to write off it.
      await generator.load();
      await printer.load();

      const appended = [
        ...seeded,
        PasswordEntry(
          personId: PersonId('p2'),
          kind: PasswordAccountKind.account,
          accountName: 'fresh',
          displayName: 'Fresh',
        ),
      ];
      await Future.wait([
        generator.save(appended), // appended a newly generated password
        printer.save(const []), // drained after printing
      ]);

      // The later writer's If-Match was stale; it reloaded and retried, so its
      // write landed against the winner's version rather than clobbering blind.
      expect(client.staleCount, greaterThanOrEqualTo(1),
          reason: 'the same queue doc under two writers must race');
      // Exactly one of the two intended states survives — not a torn mix.
      final finalQueue = await CosmosPasswordQueueStore(client).load();
      expect(
        finalQueue.map((e) => e.accountName).toList(),
        anyOf(isEmpty, equals(['seed', 'fresh'])),
      );
    });
  });
}
