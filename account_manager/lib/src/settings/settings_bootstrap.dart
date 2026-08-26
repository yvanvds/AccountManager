import 'package:account_state/account_state.dart';
import 'package:wisa_api/wisa_api.dart';

import '../auth/sign_in_session.dart';
import '../reconcile/reconcile_bootstrap.dart' show StoreEndpoints;

/// Fetches the selectable WISA schools (id + name) for a connection profile,
/// with the password resolved out of band (#142). The Settings view calls this
/// once the WISA config is valid so the operator can pick schools from the live
/// list instead of typing ids by hand.
typedef WisaSchoolFetcher = Future<List<WisaSchool>> Function(
  WisaConnection connection,
  String password,
);

/// A WISA school-list fetch that could not even be attempted because the
/// connection profile is incomplete — distinct from a transport/SOAP failure,
/// which surfaces from the connector itself.
class WisaSchoolFetchException implements Exception {
  const WisaSchoolFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The production [WisaSchoolFetcher]: builds a one-shot [WisaConnector] from
/// the connection profile plus the resolved [password] and pulls the school
/// list via the `SMAGetInst` query (legacy `SchoolManager.Load`). This is a
/// read against WISA, safe to run from the settings screen.
///
/// [transport] is a test seam; production callers omit it and get the real HTTP
/// SOAP transport.
Future<List<WisaSchool>> fetchWisaSchoolsLive(
  WisaConnection connection,
  String password, {
  WisaSoapTransport? transport,
}) async {
  final port = int.tryParse(connection.port.trim());
  if (connection.server.trim().isEmpty || port == null) {
    throw const WisaSchoolFetchException(
      'De WISA-verbinding is onvolledig: vul een geldige server en poort in.',
    );
  }
  final connector = WisaConnector.fromParts(
    server: connection.server.trim(),
    port: port,
    database: connection.database.trim(),
    username: connection.username.trim(),
    password: password,
    transport: transport,
  );
  return connector.loadSchools();
}

/// The two seams the Settings view edits against: the [SettingsStore] holding
/// the [AppSettings] config document and the [SecretProvider] the WISA password
/// and Smartschool passphrase are written through.
///
/// Deliberately much lighter than [ReconcileServices]: the Settings view exists
/// to *fix* an incomplete config, so it must reach the store and the vault
/// without first standing up the connectors — which [bootstrapReconcile] refuses
/// to do (it throws [ReconcileConfigException]) precisely when a secret or a
/// profile field is still missing.
class SettingsServices {
  const SettingsServices({
    required this.store,
    required this.secrets,
    this.fetchWisaSchools,
    this.liveSettings,
    this.operatorName = '',
  });

  /// The persistence seam for the [AppSettings] document (#114: Cosmos-backed).
  final SettingsStore store;

  /// The write-only secret seam (Key Vault in production) the Settings view
  /// persists an operator-typed credential through — never read back into the UI.
  final SecretProvider secrets;

  /// Pulls the selectable WISA schools (id + name) so the operator can pick
  /// which schools to use instead of typing ids (#142). Null when the build
  /// cannot fetch (no fetcher wired); the screen then keeps the manual-entry
  /// path only.
  final WisaSchoolFetcher? fetchWisaSchools;

  /// The process-wide settings holder the reconcile stack reads at pull time
  /// (#238). The screen publishes every document it loads or saves into it, so
  /// a saved werkdatum reaches the next Synchroniseer instead of waiting for a
  /// relaunch. Null when the build wires no reconcile stack (the settings-only
  /// harnesses), which simply skips the hand-off.
  final LiveSettings? liveSettings;

  /// The signed-in operator, as the shared settings document should name them
  /// (#285). Stamped onto every WISA import rule authored here, so a colleague
  /// reading the rule next month knows whom to ask about it.
  ///
  /// This is the same string the rest of the app already shows as the operator
  /// (`ReconcileController.syncedBy`, the "· door …" on the sync stamps) — the
  /// broker's account, which is a UPN. #98's sign-in path is what would upgrade
  /// it to a proper display name; until it does, one readable identifier used
  /// consistently everywhere beats two half-known ones. Empty when the session
  /// has no identity yet, which records as `onbekend` rather than as a blank.
  final String operatorName;
}

/// Wires the Settings view's two seams for one signed-in session: a
/// [CosmosSettingsStore] over the operator's Cosmos data-plane token and a
/// [KeyVaultSecretProvider] over their Key Vault token (#114). Both are built
/// from [StoreEndpoints], which `main()` resolves per call from this machine's
/// `connection.json` over `--dart-define` over the compiled defaults (#370).
///
/// The optional parameters are test seams; production callers pass only
/// [session] and [endpoints]. This never *loads* the settings — the screen does
/// that itself, so a reload affordance can re-read without re-bootstrapping, and
/// so a store this assembles against unreachable coordinates still lets the
/// Settings screen open (the load is where that failure lands, not here).
Future<SettingsServices> bootstrapSettings({
  required SignInSession session,
  LiveSettings? liveSettings,
  StoreEndpoints? endpoints,
  SettingsStore? settingsStore,
  SecretProvider? secretProvider,
  CosmosClient? cosmosClient,
  WisaSchoolFetcher? fetchWisaSchools,
}) async {
  final ends = endpoints ?? StoreEndpoints.fromEnvironment();
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
  final secrets = secretProvider ??
      KeyVaultSecretProvider(
        config: KeyVaultConfig(vaultUri: ends.vaultUri),
        tokens: VaultSessionTokenProvider(session),
      );
  return SettingsServices(
    store: store,
    secrets: secrets,
    fetchWisaSchools: fetchWisaSchools ?? fetchWisaSchoolsLive,
    liveSettings: liveSettings,
    // The same identity `bootstrapReconcile` syncs as, so a rule this operator
    // types and a rule this operator's apply earns are attributed alike (#285).
    operatorName: session.account ?? '',
  );
}
