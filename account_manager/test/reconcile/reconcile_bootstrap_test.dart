import 'package:account_manager/src/auth/aad_app_config.dart';
import 'package:account_manager/src/auth/auth.dart' show AadResource;
import 'package:account_manager/src/auth/sign_in_session.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../auth/fake_broker.dart';

const _aad = AadAppConfig(
  clientId: 'client-123',
  tenantId: 'tenant-abc',
  azureDomain: 'school.example',
  schoolPrefix: 'GBS',
);

/// A settings store whose [load] throws — models a broken store path.
class _ThrowingStore implements SettingsStore {
  const _ThrowingStore(this.error);

  final Object error;

  @override
  Future<AppSettings> load() async => throw error;

  @override
  Future<void> save(AppSettings settings) async {}
}

/// A Cosmos client backed by an empty account: every container reads as absent,
/// so the real `CosmosSettingsStore` path yields a default `AppSettings`. Writes
/// and queries are inert. Used to prove the bootstrap wires Cosmos without a
/// live account.
class _EmptyCosmosClient implements CosmosClient {
  const _EmptyCosmosClient();

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async =>
      null;

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async =>
      true;

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async =>
      const WriteOutcome.applied(null);

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async =>
      const [];

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      false;
}

/// A Cosmos client that records the containers bootstrap ensures, so a test can
/// prove the materialized-view containers (the operator `decisions` container
/// among them, #150) are provisioned at startup. Reads/writes are inert.
class _RecordingCosmosClient implements CosmosClient {
  final Map<String, String> ensured = {};

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async {
    ensured[container] = partitionKeyPath;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async =>
      null;

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async =>
      true;

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async =>
      const WriteOutcome.applied(null);

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async =>
      const [];
}

AppSettings _settings({
  String server = 'wisa.local',
  String port = '9000',
  String smartschoolUri = 'https://demo.smartschool.be',
}) =>
    AppSettings(
      schoolPrefix: 'GBS',
      wisa: WisaConnection(
        server: server,
        port: port,
        database: 'wisadb',
        username: 'operator',
      ),
      smartschool: SmartschoolConnection(uri: smartschoolUri),
      azure: const AzureConnection(domain: 'school.example'),
    );

InMemorySecretProvider _secrets({bool wisa = true, bool smartschool = true}) =>
    InMemorySecretProvider({
      if (wisa) const SecretRef('wisa.password'): 'geheim',
      if (smartschool) const SecretRef('smartschool.passphrase'): 'zin',
    });

StoreEndpoints _endpoints({String signalrEndpoint = ''}) => StoreEndpoints(
      cosmosEndpoint: 'https://cosmos.example/',
      cosmosDatabase: 'db',
      vaultUri: 'https://vault.example/',
      blobEndpoint: 'https://blob.example',
      blobContainer: 'snapshots',
      signalrEndpoint: signalrEndpoint,
    );

Future<ReconcileServices> _bootstrap({
  SettingsStore? store,
  SecretProvider? secrets,
  StoreEndpoints? endpoints,
  SignalSubscriber? subscriber,
}) =>
    bootstrapReconcile(
      session: SignInSession(FakeBroker()),
      aad: _aad,
      endpoints: endpoints,
      settingsStore: store ?? InMemorySettingsStore(_settings()),
      secretProvider: secrets ?? _secrets(),
      cosmosClient: const _EmptyCosmosClient(),
      subscriber: subscriber,
    );

void main() {
  group('bootstrapReconcile', () {
    test('assembles the full stack from settings + secrets', () async {
      final services = await _bootstrap();

      expect(services.settings.schoolPrefix, 'GBS');
      expect(services.app.wisa.snapshot, isNull,
          reason: 'nothing synced yet at bootstrap');
      expect(services.controller.linked, isNull);
      expect(identical(services.controller.log, services.log), isTrue);
    });

    test('wires no realtime publisher or subscriber without a SignalR endpoint',
        () async {
      // The default endpoints leave SIGNALR_ENDPOINT empty, so the realtime
      // seam stays unwired and sync falls back to the generation marker (#124).
      final services = await _bootstrap();
      expect(services.controller.publisher, isNull);
      expect(services.controller.subscriber, isNull);
    });

    test('wires the SignalR publisher + subscriber when an endpoint is set',
        () async {
      final services = await _bootstrap(
        endpoints: _endpoints(
          signalrEndpoint: 'https://demo.service.signalr.net',
        ),
      );
      addTearDown(() => services.controller.subscriber?.close());
      expect(services.controller.publisher, isA<SignalRPublisher>());
      expect(services.controller.subscriber, isA<SignalRSubscriber>());
    });

    test('passes an injected subscriber through to the controller', () async {
      final hub = InMemorySignalHub();
      final injected = hub.subscriber();
      final services = await _bootstrap(subscriber: injected);
      addTearDown(injected.close);
      expect(identical(services.controller.subscriber, injected), isTrue);
    });

    test('a missing WISA password is an actionable config error', () {
      expect(
        () => _bootstrap(secrets: _secrets(wisa: false)),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('wisa.password'),
        )),
      );
    });

    test('a missing Smartschool passphrase is an actionable config error', () {
      expect(
        () => _bootstrap(secrets: _secrets(smartschool: false)),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('smartschool.passphrase'),
        )),
      );
    });

    test('an incomplete WISA profile is an actionable config error', () {
      expect(
        () => _bootstrap(store: InMemorySettingsStore(_settings(port: 'nan'))),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('WISA connection profile'),
        )),
      );
    });

    test('settings-store failures propagate unmapped', () {
      expect(
        () => _bootstrap(store: const _ThrowingStore('login timed out')),
        throwsA('login timed out'),
      );
    });

    test(
        'provisions every sync container: view docs, decisions (#150), '
        'syncState + snapshots (#151)', () async {
      // Drive the real bootstrap assembly with a recording client to prove the
      // ensure-containers preflight is wired for every container a sync writes:
      // the operator `decisions` container (whose absence made "accept
      // duplicate mail" 404, #150), and the `syncState` / `snapshots`
      // containers whose absence 404'd the sync-lock renewal and the snapshot
      // save between the Smartschool and Azure passes (#151).
      final client = _RecordingCosmosClient();
      await bootstrapReconcile(
        session: SignInSession(FakeBroker()),
        aad: _aad,
        settingsStore: InMemorySettingsStore(_settings()),
        secretProvider: _secrets(),
        cosmosClient: client,
      );

      expect(client.ensured, containsPair('decisions', '/pk'));
      expect(
        client.ensured.keys,
        containsAll(['linkedAccounts', 'linkedGroups', 'rollups', 'decisions']),
      );
      expect(client.ensured['syncState'], '/id');
      // The snapshot store's container — the missing piece #151 adds.
      expect(client.ensured['snapshots'], '/id');
    });

    test('threads the signed-in operator UPN into the sync author (#169)',
        () async {
      // The session is signed in as an operator whose broker token carries the
      // UPN (the loopback broker now decodes it from the JWT). Warm it first —
      // in production the Cosmos-container preflight acquires a token before
      // bootstrap reads session.account; here the injected client skips that, so
      // acquire once by hand to model a signed-in session.
      final session = SignInSession(
        FakeBroker(
            silent: (_) => fakeToken('AT', account: 'yvan@school.example')),
      );
      await session.tokenFor(AadResource.cosmos);

      final services = await bootstrapReconcile(
        session: session,
        aad: _aad,
        settingsStore: InMemorySettingsStore(_settings()),
        secretProvider: _secrets(),
        cosmosClient: const _EmptyCosmosClient(),
      );

      expect(services.controller.syncedBy, 'yvan@school.example',
          reason: 'so each pull is stamped and the freshness line names them');
    });

    test('an unsigned session leaves the sync author empty (graceful) (#169)',
        () async {
      // No token was ever acquired, so session.account is null and syncedBy
      // degrades to '' — the freshness line then shows no dangling "by ".
      final services = await _bootstrap();
      expect(services.controller.syncedBy, '');
    });

    test('the real Cosmos path reads settings from the container', () async {
      // No injected settings store → the real CosmosSettingsStore over the
      // (empty) fake client. An empty container yields a default AppSettings,
      // whose blank WISA profile then fails validation — proving the settings
      // load went through the Cosmos seam rather than a stub.
      await expectLater(
        bootstrapReconcile(
          session: SignInSession(FakeBroker()),
          aad: _aad,
          secretProvider: _secrets(),
          cosmosClient: const _EmptyCosmosClient(),
        ),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('WISA connection profile'),
        )),
      );
    });
  });

  group('smartschoolSiteFrom', () {
    test('extracts the site from a full smartschool.be URL', () {
      expect(
        smartschoolSiteFrom('https://demo.smartschool.be/Webservices/V3'),
        'demo',
      );
    });

    test('extracts the site from a bare smartschool.be host', () {
      expect(smartschoolSiteFrom('demo.smartschool.be'), 'demo');
    });

    test('accepts a bare site name as-is', () {
      expect(smartschoolSiteFrom('demo'), 'demo');
    });

    test('is empty for an empty setting', () {
      expect(smartschoolSiteFrom('  '), '');
    });
  });

  group('classTreeFrom', () {
    test('uses years only when the school enables them', () {
      final on = classTreeFrom(SmartschoolConnection(
        useYears: true,
        years: ['Y1', 'Y2', 'Y3', 'Y4', 'Y5', 'Y6', 'Y7'],
        studentGroup: 'LLN',
      ));
      expect(on.years, isNotEmpty);
      expect(on.grades, isEmpty);
      expect(on.path, 'LLN');

      final off = classTreeFrom(SmartschoolConnection(
        years: ['Y1', 'Y2', 'Y3', 'Y4', 'Y5', 'Y6', 'Y7'],
      ));
      expect(off.years, isEmpty);
    });

    test('uses grades only when the school enables them', () {
      final tree = classTreeFrom(SmartschoolConnection(
        useGrades: true,
        grades: ['G1', 'G2', 'G3'],
      ));
      expect(tree.grades, isNotEmpty);
      expect(tree.years, isEmpty);
    });
  });
}
