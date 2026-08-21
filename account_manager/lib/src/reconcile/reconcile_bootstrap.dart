import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../auth/aad_app_config.dart';
import '../auth/sign_in_session.dart';
import '../passwords/password_backends.dart';
import '../passwords/password_export.dart';
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
    this.signalrEndpoint = '',
    this.signalrHub = 'reconcile',
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
        signalrEndpoint: String.fromEnvironment('SIGNALR_ENDPOINT'),
        signalrHub: String.fromEnvironment(
          'SIGNALR_HUB',
          defaultValue: 'reconcile',
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

  /// The Azure SignalR service endpoint change signals are broadcast to (#116),
  /// e.g. `https://accountmanager-signalr.service.signalr.net`. Empty until the
  /// service is provisioned and `SIGNALR_ENDPOINT` is set — bootstrap then wires
  /// no publisher and sync behaves exactly as before (the generation marker still
  /// carries staleness), so the app runs unchanged in environments without it.
  final String signalrEndpoint;

  /// The SignalR hub operators connect to and writers broadcast on (#116).
  final String signalrHub;
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
    required this.passwordQueue,
    required this.passwordBackends,
    this.passwordFileWriter = writePasswordExport,
    this.passwordFileOpener = openPasswordExport,
  });

  final AppSettings settings;
  final ApplicationState app;
  final StateApplier applier;
  final ReconcileController controller;
  final LogBuffer log;

  /// The shared password-distribution queue (#105) the [applier] appends to
  /// when an apply creates an account, and the Passwords view reads and drains.
  /// The same instance is wired into [applier], so an apply and the view see the
  /// one queue.
  final PasswordQueueStore passwordQueue;

  /// The live write seam for the reworked Passwords view (#180): on-demand
  /// student/staff password generation pushes fresh passwords straight through
  /// the Smartschool and Azure connectors. Wired to [ConnectorPasswordBackends]
  /// in production; the offline harness substitutes a recording fake.
  final PasswordBackends passwordBackends;

  /// Where an exported password sheet is written (#195). Defaults to the real
  /// file writer; a headless test substitutes a recorder so driving the export
  /// button never puts cleartext passwords on the test machine's disk.
  final PasswordFileWriter passwordFileWriter;

  /// How a written sheet is opened for printing (#195). Defaults to the
  /// platform PDF viewer; a headless test records the call instead.
  final PasswordFileOpener passwordFileOpener;
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
/// `docs/port-plan.md`); bootstrap additionally runs an idempotent
/// [ensureContainers] preflight (a metadata read that creates nothing on the
/// provisioned account) so a never-stood-up container surfaces at startup rather
/// than as a silent item-write 404 mid-session (#150).
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
  PasswordQueueStore? passwordQueueStore,
  SignalPublisher? publisher,
  SignalSubscriber? subscriber,
  LogBuffer? log,
  DateTime Function()? clock,
}) async {
  final ends = endpoints ?? StoreEndpoints.fromEnvironment();
  final logBuffer = log ?? LogBuffer();
  final now = clock ?? DateTime.now;

  // Shared throttling state for this session's Cosmos account (#196): the
  // client reports every 429 here (retrying it rather than failing the persist)
  // and the linked store's write fan-out reads it, so a full-volume write
  // narrows while the account is under pressure and widens again as it eases.
  // Throttling is reported into the operator log, so a slow persist reads as
  // slow rather than hung.
  final throttle = CosmosThrottleGovernor(
    onReport: (m) => logBuffer.addMessage(core.Origin.all, m),
  );
  final client = cosmosClient ??
      HttpCosmosClient(
        config: CosmosConfig(
          endpoint: ends.cosmosEndpoint,
          database: ends.cosmosDatabase,
        ),
        transport: HttpCosmosTransport(),
        tokens: CosmosSessionTokenProvider(session),
        governor: throttle,
      );

  // Ensure the Cosmos containers a sync reads or writes exist before anything
  // touches them: the materialized-view containers (per-account/group docs,
  // rollups, the operator decisions container, and the sync-state container)
  // plus the cold-snapshot container. On the correctly-provisioned shared
  // account this is a cheap metadata read that creates nothing; it closes the
  // gap where a never-provisioned container surfaced only as a first-write 404
  // mid-session — `decisions` for "accept duplicate mail" (#150), and
  // `syncState` / `snapshots` for the sync-lock renewal and snapshot save that
  // 404'd between the Smartschool and Azure passes (#151).
  await ensureContainers(client, specs: bootstrapContainers);

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
  final linked = linkedStore ?? CosmosLinkedStore(client, governor: throttle);

  // The shared password-distribution queue (#105): the whole team's pending
  // password sheets in one Cosmos document, so one operator can generate and
  // another print. The same instance is wired into the applier (which appends on
  // every account-creating apply) and handed to the Passwords view (which reads
  // and drains it).
  final passwordQueue = passwordQueueStore ?? CosmosPasswordQueueStore(client);

  // The realtime seam (#116 publish, #124 subscribe): a sync/apply broadcasts a
  // small change signal so other operators refetch just the changed shard, and
  // this session holds a persistent SignalR WebSocket that receives theirs.
  // Both are wired only when a SignalR endpoint is configured — until the
  // service is provisioned, neither is set and the pass falls back to the
  // store's `generation` marker, so the app runs unchanged.
  final signalConfig = ends.signalrEndpoint.isEmpty
      ? null
      : SignalRConfig(endpoint: ends.signalrEndpoint, hub: ends.signalrHub);
  final signalPublisher = publisher ??
      (signalConfig == null
          ? null
          : SignalRPublisher(
              config: signalConfig,
              tokens: SignalRSessionTokenProvider(session),
              transport: HttpSignalRTransport(),
            ));

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

  // The operator's managed-school set from Settings, shared by the linker
  // (#178) and by the Azure back-fill below (#224) so both scope to the same
  // schools. Null when no school is flagged, so a not-yet-configured group
  // falls back to the snapshot's own `MarkAsOurs` flags.
  final Set<int>? ourSchoolIds =
      settings.wisaSchools.isEmpty ? null : settings.managedWisaSchoolIds;

  // Assigned immediately below; the Azure syncer closes over it so it can read
  // the WISA snapshot *this* pass just pulled (WISA always syncs first).
  late final ApplicationState app;
  app = ApplicationState(
    wisa: SystemState<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      initial: wisaSeed,
      // Schools are re-read per sync so a WISA-side school change is picked
      // up; MarkAsVirtual rules and the operator's per-school virtual marks
      // (#203) are applied to them before the row pulls, the other rules at
      // snapshot construction. Rules are read live from the shared holder so a
      // DontImportFromWisa apply affects the re-sync (#72).
      // The pull is wrapped so each fresh snapshot is persisted (#107).
      syncer: persistingSyncer<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        store: snapshots,
        syncedBy: syncedBy,
        payloadOf: (s) => s.toJson(),
        onError: (e) => logSnapshotIssue(core.Origin.wisa, e),
        inner: (_) async {
          final schools = markVirtualSchools(
            wapi.WisaConnector.applySchoolRules(
              await wisaConnector.loadSchools(),
              wisaRules.rules,
            ),
            settings.virtualWisaSchoolIds,
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
        // The prefix-scoped pull is blind to a student who transferred in from
        // a sibling group school — their account carries neither our
        // `companyName` nor our `department` — so the app proposed creating a
        // duplicate. Hand the connector the WISA ids this pass expects, and it
        // looks the unaccounted-for ones up by `employeeId` (#224).
        inner: azureSyncer(
          azConnector,
          expectedEmployeeIds: () => managedStudentEmployeeIds(
            app.wisa.snapshot,
            ourSchoolIds: ourSchoolIds,
          ),
        ),
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
    passwordQueue: passwordQueue,
    // Wire the operator's managed-school choice into the linker (#178): the
    // `ours`-flagged WISA schools from Settings drive `wisaPresence`, so the
    // Actions view only surfaces schools we manage. Null when no school is
    // flagged, so a not-yet-configured group falls back to the snapshot's
    // `MarkAsOurs` flags rather than treating an empty managed set as "none".
    ourSchoolIds: ourSchoolIds,
  );

  // The live SignalR subscriber (#124): on every (re)connect it re-reads the
  // shared store so a session that missed a nudge while disconnected catches up.
  // The catch-up hook closes over [controller] (assigned just below) — safe
  // because the socket opens asynchronously, well after this returns.
  late final ReconcileController controller;
  final signalSubscriber = subscriber ??
      (signalConfig == null
          ? null
          : SignalRSubscriber(
              config: signalConfig,
              tokens: SignalRSessionTokenProvider(session),
              transport: HttpSignalRTransport(),
              connector: const WebSocketSignalRConnector(),
              onReconnect: () => controller.resyncFromStore(),
              log: logBuffer,
            ));

  controller = ReconcileController(
    app: app,
    applier: applier,
    log: logBuffer,
    store: linked,
    syncedBy: syncedBy,
    // The operator's curated school list names every school in the Actions
    // drill-down, so it reads "Instituut Sancta Maria-A (ISMAA)" exactly as the
    // Settings grid does rather than "School 25" (#204).
    schoolProfiles: settings.wisaSchools,
    // …and every sync writes the names it pulled back into that same document
    // (#207), so a profile stored before the two halves existed stops rendering
    // as "School 25" in the Settings grid, which consults no snapshot.
    settingsStore: store,
    publisher: signalPublisher,
    subscriber: signalSubscriber,
    clock: now,
  );

  return ReconcileServices(
    settings: settings,
    app: app,
    applier: applier,
    controller: controller,
    log: logBuffer,
    passwordQueue: passwordQueue,
    // On-demand password generation (#180) writes through the same connectors
    // the applier uses, behind the [PasswordBackends] seam so the screen can be
    // driven headlessly.
    passwordBackends: ConnectorPasswordBackends(
      smartschool: ssConnector,
      azure: azConnector,
      log: logBuffer,
    ),
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

/// Flags the operator's virtual WISA schools on a freshly loaded school list.
///
/// The virtual marks live in the settings document keyed by school **id**
/// ([AppSettings.virtualWisaSchoolIds], #203), while the snapshot-time
/// `MarkAsVirtual` import rule matches by school **name**. Setting
/// `WisaSchool.isVirtual` straight from settings mirrors how `ourSchoolIds`
/// bypasses `MarkAsOurs`: the operator-editable record is authoritative and no
/// rule has to be synthesised for it.
///
/// The pass is additive — a school the rules already flagged stays flagged even
/// when it is not in [virtualIds] — so wiring settings in can never silently
/// un-virtualise a school an existing `MarkAsVirtual` rule covers. Returns a new
/// list; the input is not mutated.
List<wapi.WisaSchool> markVirtualSchools(
  Iterable<wapi.WisaSchool> schools,
  Set<int> virtualIds,
) =>
    <wapi.WisaSchool>[
      for (final s in schools)
        virtualIds.contains(s.id) ? s.copyWith(isVirtual: true) : s,
    ];

String _firstNonEmpty(String preferred, String fallback) =>
    preferred.trim().isNotEmpty ? preferred.trim() : fallback;
