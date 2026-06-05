import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

void main() {
  group('AzureLiveConfig.fromEnvironment', () {
    test('returns null when AZURE_ACCESS_TOKEN is absent (offline default)',
        () {
      expect(AzureLiveConfig.fromEnvironment(const {}), isNull);
    });

    test('returns null when the token is blank', () {
      expect(
        AzureLiveConfig.fromEnvironment(const {'AZURE_ACCESS_TOKEN': '  '}),
        isNull,
      );
    });

    test('parses a complete environment', () {
      final config = AzureLiveConfig.fromEnvironment(const {
        'AZURE_ACCESS_TOKEN': 'tok',
        'AZURE_CLIENT_ID': 'cid',
        'AZURE_TENANT_ID': 'tid',
        'AZURE_DOMAIN': 'school.example',
        'AZURE_SCHOOL_PREFIX': 'GBS',
      });
      expect(config, isNotNull);
      expect(config!.accessToken, 'tok');
      expect(config.clientId, 'cid');
      expect(config.tenantId, 'tid');
      expect(config.azureDomain, 'school.example');
      expect(config.schoolPrefix, 'GBS');
    });

    test('throws when the token is set but a required field is missing', () {
      expect(
        () => AzureLiveConfig.fromEnvironment(const {
          'AZURE_ACCESS_TOKEN': 'tok',
          'AZURE_CLIENT_ID': 'cid',
        }),
        throwsArgumentError,
      );
    });
  });
}
