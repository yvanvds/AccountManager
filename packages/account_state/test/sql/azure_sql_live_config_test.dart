import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

void main() {
  group('AzureSqlLiveConfig.fromEnvironment', () {
    test('returns null with no environment', () {
      expect(AzureSqlLiveConfig.fromEnvironment(const {}), isNull);
    });

    test('returns null when the access token is blank', () {
      expect(
        AzureSqlLiveConfig.fromEnvironment(
            const {'AZURE_SQL_ACCESS_TOKEN': '  '}),
        isNull,
      );
    });

    test('reads all fields when fully configured', () {
      final config = AzureSqlLiveConfig.fromEnvironment(const {
        'AZURE_SQL_SERVER': 'srv.database.windows.net',
        'AZURE_SQL_DATABASE': 'accountmanager',
        'AZURE_SQL_ACCESS_TOKEN': 'tok',
      });

      expect(config, isNotNull);
      expect(config!.server, 'srv.database.windows.net');
      expect(config.database, 'accountmanager');
      expect(config.accessToken, 'tok');
    });

    test('throws when the token is set but another field is missing', () {
      expect(
        () => AzureSqlLiveConfig.fromEnvironment(const {
          'AZURE_SQL_ACCESS_TOKEN': 'tok',
          'AZURE_SQL_SERVER': 'srv.database.windows.net',
          // AZURE_SQL_DATABASE missing
        }),
        throwsArgumentError,
      );
    });

    test('exposes its variable names in canonical order', () {
      expect(AzureSqlLiveConfig.envVarNames, [
        'AZURE_SQL_SERVER',
        'AZURE_SQL_DATABASE',
        'AZURE_SQL_ACCESS_TOKEN',
      ]);
    });
  });
}
