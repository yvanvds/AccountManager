import 'dart:io';

/// Configuration for the opt-in, **read-only** Key Vault live check
/// (`test/integration/key_vault_secret_provider_live_test.dart`, issue #84).
///
/// The check reads one existing secret out of the real vault through
/// [KeyVaultSecretProvider] and asserts it came back, proving the auth +
/// transport + ref-mapping path end to end against `accountmanager-kv`. It only
/// reads — honouring the repo live-testing policy — so it is CI-eligible, unlike
/// the write-capable adapter round-trips that stay manual.
///
/// Offline unit tests never read this. See `.keyvault.env.example` at the
/// repository root for the variable names.
class KeyVaultLiveConfig {
  const KeyVaultLiveConfig({
    required this.vaultUri,
    required this.accessToken,
    required this.probeRef,
    this.expectedValue,
  });

  /// The vault data-plane base URI under test, e.g.
  /// `https://accountmanager-kv.vault.azure.net/`.
  final String vaultUri;

  /// A pre-acquired bearer token for `https://vault.azure.net/`. Expires in
  /// ~1 hour, so it is minted fresh per run rather than stored (e.g.
  /// `az account get-access-token --resource https://vault.azure.net/`).
  final String accessToken;

  /// The `SecretRef.name` to read — must name a secret that already exists in
  /// the vault (the check never writes one). Escaping to the vault secret name
  /// is [KeyVaultSecretProvider.secretNameFor]'s job.
  final String probeRef;

  /// The value the probe secret is expected to hold. When set, the check
  /// asserts equality; when null it only asserts the read returned non-null, so
  /// a secret's value need not be committed to the environment.
  final String? expectedValue;

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'KEY_VAULT_URI',
    'KEY_VAULT_ACCESS_TOKEN',
    'KEY_VAULT_PROBE_REF',
    'KEY_VAULT_PROBE_VALUE',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `KEY_VAULT_ACCESS_TOKEN` is
  /// empty or missing — the integration test uses this as its skip signal, so
  /// `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `KEY_VAULT_ACCESS_TOKEN` is set but
  /// `KEY_VAULT_URI` or `KEY_VAULT_PROBE_REF` is missing. `KEY_VAULT_PROBE_VALUE`
  /// stays optional.
  static KeyVaultLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessToken = (source['KEY_VAULT_ACCESS_TOKEN'] ?? '').trim();
    if (accessToken.isEmpty) return null;

    String required(String name) {
      final value = (source[name] ?? '').trim();
      if (value.isEmpty) {
        throw ArgumentError(
          'KEY_VAULT_ACCESS_TOKEN is set but $name is missing or empty.',
        );
      }
      return value;
    }

    final expected = source['KEY_VAULT_PROBE_VALUE'];
    return KeyVaultLiveConfig(
      vaultUri: required('KEY_VAULT_URI'),
      accessToken: accessToken,
      probeRef: required('KEY_VAULT_PROBE_REF'),
      expectedValue: (expected == null || expected.isEmpty) ? null : expected,
    );
  }
}
