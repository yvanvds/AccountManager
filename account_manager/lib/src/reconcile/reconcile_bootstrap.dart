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
    required this.liveSettings,
    required this.app,
    required this.applier,
    required this.controller,
    required this.log,
    required this.passwordQueue,
    required this.passwordBackends,
    this.passwordFileWriter = writePasswordExport,
    this.passwordFileOpener = openPasswordExport,
  });

  /// The settings document as it stood when the stack was assembled. A
  /// point-in-time copy, kept only for what genuinely froze with it — the
  /// connection profiles the three connectors were constructed from. Everything
  /// the running stack acts on is read from [liveSettings] instead (#238/#246).
  final AppSettings settings;

  /// The shared settings holder every settings-derived value in this stack is
  /// read from, and the Settings view publishes into on every load and save.
  ///
  /// #238 wired the WISA pull inputs (werkdatum, virtuele werkdatum, virtual
  /// marks) through it; #246 the rest — the managed-school set, the school
  /// prefix, the Azure domain, the Smartschool class tree and import rules, and
  /// the curated school profiles. So a save reaches the next pass rather than
  /// the next launch. What it cannot reach is the connectors' own endpoints and
  /// credential refs; `ReconcileController.relaunchRequiredReason` says so.
  final LiveSettings liveSettings;

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
/// [liveSettings] is the process-wide settings holder the Settings view
/// publishes into (#238). Everything this stack derives from the settings
/// document is read back from it **at use time** rather than captured here —
/// the WISA pull's werkdatum pair and virtual marks (#238), and the
/// managed-school set, school prefix, Azure domain, Smartschool class tree and
/// import rules, and curated school profiles (#246) — so a save reaches the next
/// pass instead of the next launch. Production wires the same instance into
/// [bootstrapSettings]; omitting it gives this stack a private holder that only
/// bootstrap writes.
///
/// The one residue is the connection profiles: the WISA server/port/database/
/// login, the Smartschool site, and the two secret refs are resolved here, once,
/// into live connections and Key Vault reads. Changing one needs a relaunch, and
/// `ReconcileController.relaunchRequiredReason` puts that on screen rather than
/// letting the session quietly keep talking to the previous endpoints.
///
/// The optional parameters are test seams; production callers pass only
/// [session], [aad] and [liveSettings]. The Cosmos containers are provisioned
/// out of band (see `docs/port-plan.md`); bootstrap additionally runs an
/// idempotent [ensureContainers] preflight (a metadata read that creates nothing
/// on the provisioned account) so a never-stood-up container surfaces at startup
/// rather than as a silent item-write 404 mid-session (#150).
Future<ReconcileServices> bootstrapReconcile({
  required SignInSession session,
  required AadAppConfig aad,
  LiveSettings? liveSettings,
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
  // Adopt what we just loaded as the live document (#238). Everything that has
  // to honour a later save — the WISA pull's werkdatum pair and virtual marks,
  // and the drift gate that refuses to reconcile against a roster the change
  // never reached — reads `live.current`, never this local.
  final live = liveSettings ?? LiveSettings();
  live.publish(settings);

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
      logBuffer.addError(system, 'Snapshotopslag: $error');

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
  // Both are read from the **live** document at every use (#246): the operator
  // can change either in Instellingen, and before #246 the value captured here
  // was the only one the session ever saw. The credentials below still carry the
  // bootstrap-time prefix, but only as the connector's default — every pull
  // passes the current one explicitly.
  String schoolPrefixNow() =>
      _firstNonEmpty(live.current.schoolPrefix, aad.schoolPrefix);
  String azureDomainNow() =>
      _firstNonEmpty(live.current.azure.domain, aad.azureDomain);
  final azConnector = az.AzureConnector(
    credentials: az.AzureCredentials(
      clientId: aad.clientId,
      tenantId: aad.tenantId,
      azureDomain: azureDomainNow(),
      schoolPrefix: schoolPrefixNow(),
    ),
    authProvider: GraphSessionAuthProvider(session, aad.graph),
    log: logBuffer,
  );

  // Only the rules *this session* earns — the `DontImportFromWisa` applies.
  // The operator's persisted rules are deliberately not seeded in here (#263):
  // nothing ever republished a saved document into this holder, so seeding it
  // froze `settings.wisaRules` for the life of the process. The pull reads them
  // from the live document instead, so a rule saved (or removed) in the settings
  // document reaches the very next pull rather than the next launch.
  final wisaRules = WisaImportRules();

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
  // schools. Empty when no school is flagged, which every reader treats as
  // "ownership unconfigured" and counts every school.
  //
  // Read from the live document at every use (#246) — flipping a school's
  // **beheerd** mark in Instellingen must reach the next relink, not the next
  // launch. Both readers below call this, so the linker and the Azure back-fill
  // can never end up scoping to different school sets.
  Set<int> ourSchoolIdsNow() => managedSchoolIdsOf(live.current);

  // Assigned immediately below; the Azure syncer closes over it so it can read
  // the WISA snapshot *this* pass just pulled (WISA always syncs first).
  late final ApplicationState app;
  app = ApplicationState(
    wisa: SystemState<wapi.WisaSnapshot>(
      system: core.Origin.wisa,
      initial: wisaSeed,
      // The pull is wrapped so each fresh snapshot is persisted (#107); what it
      // asks WISA for is composed by [wisaSyncer], which reads the settings and
      // the rules live.
      syncer: persistingSyncer<wapi.WisaSnapshot>(
        system: core.Origin.wisa,
        store: snapshots,
        syncedBy: syncedBy,
        payloadOf: (s) => s.toJson(),
        onError: (e) => logSnapshotIssue(core.Origin.wisa, e),
        inner: wisaSyncer(
          wisaConnector,
          settings: live,
          rules: wisaRules,
          log: logBuffer,
          clock: now,
        ),
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
        // The operator's import rules, read from the live document at pull time
        // (#241 authored them, #246 unfroze them): authoring a
        // `DiscardSmartschoolGroup` in Instellingen reaches the very next
        // Smartschool pull rather than the next launch. Since #259 that is
        // whichever pass the operator runs next: a moved
        // `smartschoolPullFingerprint` makes the smart sync re-pull this system
        // instead of leaving the snapshot it already holds alone.
        // `fullRead` is ignored here and everywhere Smartschool is pulled: the
        // connector reads the whole site every pass, so there is no resume
        // point a drift check could be asked to drop (#316).
        inner: (_, {bool fullRead = false}) =>
            ssConnector.sync(rules: live.current.smartschoolRules),
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
        // The prefix-scoped pull is blind to anyone who transferred in from a
        // sibling group school — a student's account carries neither our
        // `companyName` nor our `department`, a staff member's `department`
        // still names the school they came from — so the app proposed creating
        // a duplicate. Hand the connector the WISA ids this pass expects, both
        // populations, and it looks the unaccounted-for ones up by `employeeId`
        // (#224 students, #231 staff).
        inner: azureSyncer(
          azConnector,
          expectedEmployeeIds: () => <String>{
            ...managedStudentEmployeeIds(
              app.wisa.snapshot,
              ourSchoolIds: ourSchoolIdsNow(),
            ),
            ...managedStaffEmployeeIds(app.wisa.snapshot),
          },
          // The same blindness on the group side (#280): `listGroups` is
          // `startswith(displayName,'<PREFIX>')`, so an Office 365 class group
          // somebody renamed by hand is invisible to every pull even though it
          // still answers on our `<PREFIX>-<KLAS>` address — and the create the
          // linker kept proposing then died on its own pre-create guard. Hand
          // the connector the addresses this pass expects and it adopts them.
          expectedGroupMailNicknames: (prefix) =>
              managedClassGroupMailNicknames(
            app.wisa.snapshot,
            schoolPrefix: prefix,
            ourSchoolIds: ourSchoolIdsNow(),
          ),
          // The prefix scopes the whole Azure pull, and it is operator-editable
          // (#246). Changing it makes this pass re-read in full rather than
          // layering the new school's changes over the old school's users — and
          // since #259 it is also what makes the next Synchroniseer re-pull
          // Azure at all, rather than leaving the snapshot in hand alone.
          schoolPrefix: schoolPrefixNow,
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
    passwordQueue: passwordQueue,
    // Every settings-derived input the applier needs, sampled from the live
    // document on each link and each apply (#246). Before this the four values
    // were captured here once, so the school prefix, the Azure domain, the
    // Smartschool class tree and the managed-school set — the last of which
    // drives which schools the Actions view surfaces at all (#178) — were
    // relaunch-only.
    settings: () {
      final prefix = schoolPrefixNow();
      final domain = azureDomainNow();
      return ApplierSettings(
        studentConfig: actions.StudentActionConfig(
          schoolPrefix: prefix,
          azureDomain: domain,
        ),
        staffConfig: actions.StaffActionConfig(
          schoolPrefix: prefix,
          azureDomain: domain,
        ),
        classTree: classTreeFrom(live.current.smartschool),
        ourSchoolIds: ourSchoolIdsNow(),
      );
    },
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
    // The same cold store the syncers persist through, so an apply pass can
    // write back the snapshots it patched locally instead of leaving the stored
    // copy carrying the record it just dropped (#347).
    snapshotStore: snapshots,
    // The live document, so the drift gate can tell that the WISA pull inputs
    // moved since the installed snapshot was pulled (#238).
    liveSettings: live,
    publisher: signalPublisher,
    subscriber: signalSubscriber,
    clock: now,
  );

  return ReconcileServices(
    settings: settings,
    liveSettings: live,
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

/// The WISA school ids the operator manages, as the linker and the Azure
/// back-fill both want them: the `ours`-flagged ids of the WISA-scholen grid in
/// Instellingen (#178/#246).
///
/// This is the whole of ownership since #286. It used to answer `null` for an
/// install whose grid was empty, so `link()` and [PlacementResolver] would fall
/// back to the snapshot's own `MarkAsOurs` flags — a fallback no install ever
/// reached once **Scholen ophalen** had been pressed, and which the rule that
/// fed it has now been deleted with.
///
/// An **empty** set is therefore the answer for a not-yet-configured install,
/// and it is the right one: every reader treats an empty managed set as
/// "ownership unconfigured" and counts every school, never as "no school is
/// ours". It stays a named function so both readers below share one definition
/// and can never scope to different school sets.
Set<int> managedSchoolIdsOf(AppSettings settings) =>
    settings.managedWisaSchoolIds;

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

/// The WISA pull, composed the way the app runs it — the counterpart of
/// `account_state`'s [azureSyncer], so a test can drive the *production* pull
/// over a fake SOAP transport instead of re-deriving it.
///
/// Two things are read **live**, at pull time, rather than captured when the
/// stack is wired:
///
/// - the import [rules], so a `DontImportFromWisa` apply reaches the re-sync it
///   triggers (#72);
/// - the operator's [settings] — the werkdatum, the virtuele werkdatum, the
///   per-school virtual marks (#203), and the persisted WISA import rules
///   (#263). Before #238 these were closed over as an immutable `AppSettings`
///   read once at bootstrap, so saving a new werkdatum in Instellingen changed
///   nothing until the app was relaunched.
///
/// The two rule sources are unioned here, per pull, rather than merged once at
/// wiring time (#263): [rules] holds what this session accumulated, the live
/// document holds what the operator persisted, and only reading both at call
/// time lets either move under a running session.
///
/// Schools are re-read per sync so a WISA-side school change is picked up; the
/// operator's virtual marks are stamped onto them before the row pulls (no rule
/// touches a school since #277), the rest at snapshot construction.
///
/// Because this is the one place a pass's work dates are resolved, it is also
/// the one place that can say what they were: [log] gets a single
/// [wisaPullMessage] line naming them, written before the row queries go out so
/// even a pull that then fails has said what it asked for (#239).
Syncer<wapi.WisaSnapshot> wisaSyncer(
  wapi.WisaConnector connector, {
  required LiveSettings settings,
  required WisaImportRules rules,
  core.ILog? log,
  DateTime Function() clock = DateTime.now,
}) =>
    // `fullRead` is ignored: WISA is read whole on every pass, so a drift check
    // asking for a re-read is asking for what it already gets (#316).
    (_, {bool fullRead = false}) async {
      // One consistent read for the whole pull: a save landing mid-pull must not
      // split the school list and the work dates across two documents.
      final current = settings.current;
      final importRules = rules.unionWith(current.wisaRules);
      final schools = markVirtualSchools(
        await connector.loadSchools(),
        current.virtualWisaSchoolIds,
      );
      final at = clock();
      final workDate = current.wisa.workDate.resolve(at);
      final virtualWorkDate = current.wisa.virtualWorkDate.resolve(at);
      log?.addMessage(
        core.Origin.wisa,
        wisaPullMessage(
          schools: schools,
          workDate: workDate,
          virtualWorkDate: virtualWorkDate,
        ),
      );
      return connector.sync(
        schools: schools,
        workDate: workDate,
        virtualWorkDate: virtualWorkDate,
        rules: importRules,
      );
    };

/// The single line a WISA pull writes to name the dates it asked WISA for
/// (#239).
///
/// The werkdatum is a per-pass input the whole materialized view depends on:
/// WISA returns enrolments *as of* that date, so a pass run on the wrong side of
/// the school-year rollover simply has none of the new intake in it — which on
/// the Acties screen reads exactly like a class that went missing. Nothing else
/// in the app names the school year the current view describes, so an operator
/// could only tell the two apart by opening Instellingen and reasoning about the
/// boundary themselves.
///
/// Both dates are rendered with the connector's own [wapi.formatWerkdatum], so
/// the line reads exactly as the `Werkdatum` SOAP parameter went out. The
/// virtuele werkdatum is named only when a school in *this* pull actually used
/// it — reporting a second date no query carried would be its own kind of lie.
String wisaPullMessage({
  required Iterable<wapi.WisaSchool> schools,
  required DateTime workDate,
  required DateTime virtualWorkDate,
}) {
  final virtual = <String>[
    for (final s in schools)
      if (s.isVirtual) _schoolLabel(s),
  ];
  final head = 'WISA ophalen met werkdatum ${wapi.formatWerkdatum(workDate)}';
  if (virtual.isEmpty) return '$head.';
  return '$head; virtuele werkdatum '
      '${wapi.formatWerkdatum(virtualWorkDate)} voor ${virtual.join(', ')}.';
}

/// How a school is named in the pull line: the short code the rest of the WISA
/// sync log uses ("Loading classgroups from ISMAA succeeded."), falling back to
/// the long name and finally the id, so a school whose `SMAGetInst` row carries
/// no DESCRIPTION is still identifiable rather than an empty gap.
String _schoolLabel(wapi.WisaSchool school) {
  if (school.code.trim().isNotEmpty) return school.code.trim();
  if (school.name.trim().isNotEmpty) return school.name.trim();
  return 'school ${school.id}';
}

/// Flags the operator's virtual WISA schools on a freshly loaded school list.
///
/// The virtual marks live in the settings document keyed by school **id**
/// ([AppSettings.virtualWisaSchoolIds], #203), and since #277 this is the only
/// thing that ever sets `WisaSchool.isVirtual`: the snapshot-time `MarkAsVirtual`
/// import rule matched by school **code** and fed the same flag, so the pull had
/// to union two surfaces that could disagree. Ownership made the same move one
/// issue earlier (#286) — the operator-editable record is authoritative and no
/// rule has to be synthesised for it.
///
/// [virtualIds] is therefore the whole answer, and this pass *sets* the flag
/// rather than only adding to it: a school outside the set pulls with the
/// ordinary werkdatum, full stop. Until #277 it was deliberately additive, so
/// that wiring the grid in could not silently un-virtualise a school a rule
/// covered; with no rule left to defer to, that additive step could only keep a
/// stale flag alive against what the grid says. Returns a new list; the input is
/// not mutated.
List<wapi.WisaSchool> markVirtualSchools(
  Iterable<wapi.WisaSchool> schools,
  Set<int> virtualIds,
) =>
    <wapi.WisaSchool>[
      for (final s in schools) s.copyWith(isVirtual: virtualIds.contains(s.id)),
    ];

String _firstNonEmpty(String preferred, String fallback) =>
    preferred.trim().isNotEmpty ? preferred.trim() : fallback;
