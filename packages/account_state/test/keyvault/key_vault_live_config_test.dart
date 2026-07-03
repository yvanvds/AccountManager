import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

void main() {
  group('KeyVaultLiveConfig.fromEnvironment', () {
    test('returns null with no environment', () {
      expect(KeyVaultLiveConfig.fromEnvironment(const {}), isNull);
    });

    test('returns null when the access token is blank', () {
      expect(
        KeyVaultLiveConfig.fromEnvironment(
            const {'KEY_VAULT_ACCESS_TOKEN': ' '}),
        isNull,
      );
    });

    test('reads all fields when fully configured', () {
      final config = KeyVaultLiveConfig.fromEnvironment(const {
        'KEY_VAULT_URI': 'https://accountmanager-kv.vault.azure.net/',
        'KEY_VAULT_ACCESS_TOKEN': 'tok',
        'KEY_VAULT_PROBE_REF': 'wisa.password',
        'KEY_VAULT_PROBE_VALUE': 'hunter2',
      });

      expect(config, isNotNull);
      expect(config!.vaultUri, 'https://accountmanager-kv.vault.azure.net/');
      expect(config.accessToken, 'tok');
      expect(config.probeRef, 'wisa.password');
      expect(config.expectedValue, 'hunter2');
    });

    test('leaves the expected value null when the probe value is unset', () {
      final config = KeyVaultLiveConfig.fromEnvironment(const {
        'KEY_VAULT_URI': 'https://x.vault.azure.net/',
        'KEY_VAULT_ACCESS_TOKEN': 'tok',
        'KEY_VAULT_PROBE_REF': 'wisa.password',
      });

      expect(config!.expectedValue, isNull);
    });

    test('throws when the token is set but a required field is missing', () {
      expect(
        () => KeyVaultLiveConfig.fromEnvironment(const {
          'KEY_VAULT_ACCESS_TOKEN': 'tok',
          'KEY_VAULT_URI': 'https://x.vault.azure.net/',
          // KEY_VAULT_PROBE_REF missing
        }),
        throwsArgumentError,
      );
    });

    test('exposes its variable names in canonical order', () {
      expect(KeyVaultLiveConfig.envVarNames, [
        'KEY_VAULT_URI',
        'KEY_VAULT_ACCESS_TOKEN',
        'KEY_VAULT_PROBE_REF',
        'KEY_VAULT_PROBE_VALUE',
      ]);
    });
  });
}
