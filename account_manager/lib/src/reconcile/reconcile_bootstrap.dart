import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../auth/aad_app_config.dart';
import '../auth/sign_in_session.dart';
import 'log_buffer.dart';
import 'reconcile_controller.dart';

/// Where the centralized stores live. These are deployment constants of the
/// provisioned infrastructure (docs/port-plan.md, Phase B) — not secrets and
/// not per-school config, so they default to the real resources and can be
/// overridden per environment with `--dart-define`.
class StoreEndpoints {
  const StoreEndpoints({
    required this.cosmosEndpoint,
    required this.cosmosDatabase,
    required this.vaultUri,
    required this.blobEndpoint,
    required this.blobContainer,
  });

  factory StoreEndpoints.fromEnvironment() => const StoreEndpoints(
        cosmosEndpoint: String.fromEnvironment(
          'COSMOS_ENDPOINT',
          defaultValue:
              'https://accountmanager-cosmos-arcadia.documents.azure.com:443/',
        ),
        cosmosDatabase: String.fromEnvironment(
          'COSMOS_DATABASE',
          defaultValue: 'accountmanager',
        ),
        vaultUri: String.fromEnvironment(
          'KEY_VAULT_URI',
          defaultValue: 'https://accountmanager-kv.vault.azure.net/',
        ),
        blobEndpoint: String.fromEnvironment(
          'BLOB_ENDPOINT',
          defaultValue: 'https://accountmanagerarcadia.blob.core.windows.net',
        ),
        blobContainer: String.fromEnvironment(
          'BLOB_SNAPSHOTS_CONTAINER',
          defaultValue: 'snapshots',
        ),
      );

  final String cosmosEndpoint;
  final String cosmosDatabase;
  final String vaultUri;

  /// The Blob Storage account endpoint holding cold-snapshot overflow payloads
  /// (#107).
  final String blobEndpoint;

  /// The container within [blobEndpoint] the snapshot overflow blobs live in.
  final String blobContainer;
}

/// The assembled reconcile stack for one signed-in session: settings loaded
/// from the Azure SQL [SettingsStore], secrets resolved from Key Vault, the
/// three connectors wired into an [ApplicationState], and the
/// [ReconcileController] the screen binds to.
class ReconcileServices {
  const ReconcileServices({
    required this.settings,
    required this.app,
    required this.applier,
    required this.controller,
    required this.log,
  });

  final AppSettings settings;
  final ApplicationState app;
  final StateApplier applier;
  final ReconcileController controller;
  final LogBuffer log;
}

/// A configuration problem the operator can act on (missing secret, malformed
/// profile). Rendered as the reconcile screen's error panel, distinct from a
/// transient sync failure.
class ReconcileConfigException implements Exception {
  const ReconcileConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the real reconcile stack (#114): loads [AppSettings] from the Cosmos
/// settings container using the operator's Cosmos data-plane token, resolves the
/// WISA password and Smartschool passphrase from Key Vault, constructs the three
/// connectors (Graph calls carry the session token from #98), and assembles
/// `ApplicationState` → `StateApplier` → [ReconcileController].
///
/// The optional parameters are test seams; production callers pass only
/// [session] and [aad]. The Cosmos containers are provisioned out of band (see
/// `docs/port-plan.md`) — data-plane RBAC cannot create them — so bootstrap only
/// reads and writes items.
Future<ReconcileServices> bootstrapReconcile({
  required SignInSession session,
  required AadAppConfig aad,
  StoreEndpoints? endpoints,
  SettingsStore? settingsStore,
  SecretProvider? secretProvider,
  CosmosClient? cosmosClient,
  BlobStore? blobStore,
  SnapshotStore? snapshotStore,
  LinkedStore? linkedStore,
  LogBuffer? log,
  DateTime Function()? clock,
}) async {
  final ends = endpoints ?? StoreEndpoints.fromEnvironment();
  final logBuffer = log ?? LogBuffer();
  final now = clock ?? DateTime.now;

  final client = cosmosClient ??
      HttpCosmosClient(
        config: CosmosConfig(
          endpoint: ends.cosmosEndpoint,
          database: ends.cosmosDatabase,
        ),
        transport: HttpCosmosTransport(),
        tokens: CosmosSessionTokenProvider(session),
      );

  final store = settingsStore ?? CosmosSettingsStore(client);
  final settings = await store.load();

  // The cold snapshot store (#107): a fresh session seeds its SystemStates from
  // here instead of pulling, and every successful sync writes the fresh
  // snapshot back. Only the sync/drift process reads or writes it.
  final blobs = blobStore ??
      HttpBlobStore(
        config: BlobConfig(
          endpoint: ends.blobEndpoint,
          container: ends.blobContainer,
        ),
        transport: HttpBlobTransport(),
        tokens: BlobSessionTokenProvider(session),
      );
  final snapshots = snapshotStore ?? CosmosSnapshotStore(client, blobs);
  // The materialized-view store (#115): a sync writes the derived per-account
  // docs + rollups here, and every passive session reads the overview back with
  // no pull and no link().
  final linked = linkedStore ?? CosmosLinkedStore(client);
  final syncedBy = session.account ?? '';
  void logSnapshotIssue(core.Origin system, Object error) =>
      logBuffer.addError(system, 'Snapshot store: $error');

  final secrets = secretProvider ??
      KeyVaultSecretProvider(
        config: KeyVaultConfig(vaultUri: ends.vaultUri),
        tokens: VaultSessionTokenProvider(session),
      );

  final wisaPassword = await secrets.read(settings.wisa.passwordRef);
  if (wisaPassword == null) {
    throw ReconcileConfigException(
      'The WISA password (secret "${settings.wisa.passwordRef.name}") is not '
      'set in the Key Vault.',
    );
  }
  final passphrase = await secrets.read(settings.smartschool.passphraseRef);
  if (passphrase == null) {
    throw ReconcileConfigException(
      'The Smartschool passphrase (secret '
      '"${settings.smartschool.passphraseRef.name}") is not set in the '
      'Key Vault.',
    );
  }

  final wisaPort = int.tryParse(settings.wisa.port.trim());
  if (settings.wisa.server.trim().isEmpty || wisaPort == null) {
    throw ReconcileConfigException(
      'The WISA connection profile is incomplete '
      '(server: "${settings.wisa.server}", port: "${settings.wisa.port}").',
    );
  }
  final site = smartschoolSiteFrom(settings.smartschool.uri);
  if (site.isEmpty) {
    throw ReconcileConfigException(
      'The Smartschool connection profile has no site/URI configured.',
    );
  }

  final wisaConnector = wapi.WisaConnector.fromParts(
    server: settings.wisa.server.trim(),
    port: wisaPort,
    database: settings.wisa.database,
    username: settings.wisa.username,
    password: wisaPassword,
    log: logBuffer,
  );
  final ssConnector = ss.SmartschoolConnector.fromParts(
    site: site,
    accessCode: passphrase,
    log: logBuffer,
  );

  // Per-school values prefer the persisted settings and fall back to the
  // dart-define sign-in config, so a not-yet-filled settings row still runs.
  final schoolPrefix = _firstNonEmpty(settings.schoolPrefix, aad.schoolPrefix);
  final azureDomain = _firstNonEmpty(settings.azure.domain, aad.azureDomain);
  final azConnector = az.AzureConnector(
    credentials: az.AzureCredentials(
      clientId: aad.clientId,
      tenantId: aad.tenantId,
      azureDomain: azureDomain,
      schoolPrefix: schoolPrefix,
    ),
    authProvider: GraphSessionAuthProvider(session, aad.graph),
    log: logBuffer,
  );

  final wisaRules = WisaImportRules(initial: settings.wisaRules);

  // Seed each SystemState from the stored cold snapshot so a fresh session
  // trusts the persisted state (#107): WISA seeds the smart-diff baseline,
  // Smartschool/Azure are reused rather than re-pulled, and the Azure seed
  // restores the delta token so the next sync resumes `/users/delta`.
  final wisaSeed = await seedSnapshot<wapi.WisaSnapshot>(
    system: core.Origin.wisa,
    store: snapshots,
    fromPayload: wapi.WisaSnapshot.fromJson,
    onError: (e) => logSnapshotIssue(core.Origin.wisa, e),
  );
  final ssSeed = await seedSnapshot<ss.SmartschoolSnapshot>(
    system: core.Origin.smartschool,
    store: snapshots,
    fromPayload: ss.SmartschoolSnapshot.fromJson,
    onError: (e) => logSnapshotIssue(core.Origin.smartschool, e),
  );
  final azureSeed = await seedSnapshot<az.AzureSnapshot>(
    system: core.Origin.azure,
    store: snapshots,
    fromPayload: az.AzureSnapshot.fromJson,
    onError: (e) => logSnapshotIssue(core.Origin.azure, e),
  );

  final app = ApplicationState(
    wisa: SystemState<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      initial: wisaSeed,
      // Schools are re-read per sync so a WISA-side school change is picked
      // up; MarkAsVirtual rules are applied to them before the row pulls, the
      // other rules at snapshot construction. Rules are read live from the
      // shared holder so a DontImportFromWisa apply affects the re-sync (#72).
      // The pull is wrapped so each fresh snapshot is persisted (#107).
      syncer: persistingSyncer<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        store: snapshots,
        syncedBy: syncedBy,
        payloadOf: (s) => s.toJson(),
        onError: (e) => logSnapshotIssue(core.Origin.wisa, e),
        inner: (_) async {
          final schools = wapi.WisaConnector.applySchoolRules(
            await wisaConnector.loadSchools(),
            wisaRules.rules,
          );
          final at = now();
          return wisaConnector.sync(
            schools: schools,
            workDate: settings.wisa.workDate.resolve(at),
            virtualWorkDate: settings.wisa.virtualWorkDate.resolve(at),
            rules: wisaRules.rules,
          );
        },
      ),
    ),
    smartschool: SystemState<ss.SmartschoolSnapshot>(
      system: core.Origin.smartschool,
      initial: ssSeed,
      syncer: persistingSyncer<ss.SmartschoolSnapshot>(
        system: core.Origin.smartschool,
        store: snapshots,
        syncedBy: syncedBy,
        payloadOf: (s) => s.toJson(),
        onError: (e) => logSnapshotIssue(core.Origin.smartschool, e),
        inner: (_) => ssConnector.sync(rules: settings.smartschoolRules),
      ),
    ),
    azure: SystemState<az.AzureSnapshot>(
      system: core.Origin.azure,
      initial: azureSeed,
      syncer: persistingSyncer<az.AzureSnapshot>(
        system: core.Origin.azure,
        store: snapshots,
        syncedBy: syncedBy,
        payloadOf: (s) => s.toJson(),
        deltaTokenOf: (s) => s.deltaToken,
        onError: (e) => logSnapshotIssue(core.Origin.azure, e),
        inner: azureSyncer(azConnector),
      ),
    ),
  );

  final applier = StateApplier(
    app: app,
    connectors: actions.Connectors(
      smartschool: ssConnector,
      azure: azConnector,
    ),
    resolver: CosmosPersonIdResolver(client: client),
    wisaRules: wisaRules,
    studentConfig: actions.StudentActionConfig(
      schoolPrefix: schoolPrefix,
      azureDomain: azureDomain,
    ),
    staffConfig: actions.StaffActionConfig(
      schoolPrefix: schoolPrefix,
      azureDomain: azureDomain,
    ),
    classTree: classTreeFrom(settings.smartschool),
  );

  return ReconcileServices(
    settings: settings,
    app: app,
    applier: applier,
    controller: ReconcileController(
      app: app,
      applier: applier,
      log: logBuffer,
      store: linked,
      syncedBy: syncedBy,
      clock: now,
    ),
    log: logBuffer,
  );
}

/// The Smartschool class-tree live-config, derived from the persisted
/// connection profile: the year or grade group codes (whichever the school
/// uses) with the student-group root as the flat fallback path.
SmartschoolClassTree classTreeFrom(SmartschoolConnection smartschool) =>
    SmartschoolClassTree(
      years: smartschool.useYears ? smartschool.years : const [],
      grades: smartschool.useGrades ? smartschool.grades : const [],
      path: smartschool.studentGroup,
    );

/// Extracts the tenant subdomain the SOAP connector needs from the persisted
/// Smartschool URI, which operators have entered as a full URL
/// (`https://school.smartschool.be/...`), a bare host, or just the site name.
String smartschoolSiteFrom(String uri) {
  final trimmed = uri.trim();
  if (trimmed.isEmpty) return '';
  final parsed =
      Uri.tryParse(trimmed.contains('://') ? trimmed : 'https://$trimmed');
  final host = parsed?.host ?? '';
  const suffix = '.smartschool.be';
  if (host.endsWith(suffix)) {
    return host.substring(0, host.length - suffix.length);
  }
  if (host.isNotEmpty) return host.split('.').first;
  return trimmed;
}

String _firstNonEmpty(String preferred, String fallback) =>
    preferred.trim().isNotEmpty ? preferred.trim() : fallback;
