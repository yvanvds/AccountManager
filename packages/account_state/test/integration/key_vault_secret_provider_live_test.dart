@Timeout(Duration(minutes: 1))
library;

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in, **read-only** live check of [KeyVaultSecretProvider] against the real
/// Azure Key Vault (`accountmanager-kv`, issue #84).
///
/// Reads one existing secret out of the vault and asserts it came back, proving
/// the auth + `package:http` transport + ref-mapping path end to end. Because it
/// only reads it honours the repo live-testing policy and is CI-eligible — no
/// write-capable placeholder, and no deferred driver (unlike the SQL adapters,
/// the vault data-plane is plain HTTPS and works today).
///
/// Offline by default: with no `KEY_VAULT_ACCESS_TOKEN` the config is null and
/// the group is skipped, so `dart test` stays hermetic. Point it at an existing
/// secret via `.keyvault.env` (see `.keyvault.env.example`) to run it.
void main() {
  final config = KeyVaultLiveConfig.fromEnvironment();

  group(
    'KeyVaultSecretProvider live read',
    () {
      late KeyVaultSecretProvider provider;

      setUp(() {
        provider = KeyVaultSecretProvider(
          config: KeyVaultConfig(vaultUri: config!.vaultUri),
          tokens: StaticKeyVaultTokenProvider(config.accessToken),
        );
      });

      tearDown(() => provider.close());

      test('reads the probe secret out of the real vault', () async {
        final cfg = config!; // non-null: the group is skipped otherwise.
        final value = await provider.read(SecretRef(cfg.probeRef));

        expect(value, isNotNull,
            reason: 'probe secret ${cfg.probeRef} should exist in the vault');
        if (cfg.expectedValue != null) {
          expect(value, cfg.expectedValue);
        }
      });

      test('reads null for a secret that does not exist', () async {
        // Exercises the 404 -> null path against the live vault without writing.
        final value = await provider.read(
          const SecretRef('account-manager.live-test.definitely-absent'),
        );
        expect(value, isNull);
      });
    },
    skip: config == null
        ? 'Set KEY_VAULT_ACCESS_TOKEN (+ KEY_VAULT_URI, KEY_VAULT_PROBE_REF) to '
            'run the live Key Vault read; see .keyvault.env.example.'
        : false,
  );
}
