import 'package:account_state/account_state.dart';

import '../auth/sign_in_session.dart';
import '../reconcile/reconcile_bootstrap.dart' show StoreEndpoints;

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
  const SettingsServices({required this.store, required this.secrets});

  /// The persistence seam for the [AppSettings] document (#114: Cosmos-backed).
  final SettingsStore store;

  /// The write-only secret seam (Key Vault in production) the Settings view
  /// persists an operator-typed credential through — never read back into the UI.
  final SecretProvider secrets;
}

/// Wires the Settings view's two seams for one signed-in session: a
/// [CosmosSettingsStore] over the operator's Cosmos data-plane token and a
/// [KeyVaultSecretProvider] over their Key Vault token (#114). Both default to
/// the provisioned infrastructure in [StoreEndpoints] and can be overridden per
/// environment with `--dart-define`.
///
/// The optional parameters are test seams; production callers pass only
/// [session]. This never *loads* the settings — the screen does that itself, so
/// a reload affordance can re-read without re-bootstrapping.
Future<SettingsServices> bootstrapSettings({
  required SignInSession session,
  StoreEndpoints? endpoints,
  SettingsStore? settingsStore,
  SecretProvider? secretProvider,
  CosmosClient? cosmosClient,
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
  return SettingsServices(store: store, secrets: secrets);
}
