import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolLiveConfig.fromEnvironment', () {
    test('returns null when the accesscode is empty or missing', () {
      expect(SmartschoolLiveConfig.fromEnvironment(const {}), isNull);
      expect(
        SmartschoolLiveConfig.fromEnvironment(const {
          'SMARTSCHOOL_ACCESSCODE': '  ',
          'SMARTSCHOOL_SITE': 'demo',
        }),
        isNull,
      );
    });

    test('throws when the accesscode is set but the site is missing', () {
      expect(
        () => SmartschoolLiveConfig.fromEnvironment(const {
          'SMARTSCHOOL_ACCESSCODE': 'secret',
        }),
        throwsArgumentError,
      );
    });

    test('parses and trims a complete environment', () {
      final config = SmartschoolLiveConfig.fromEnvironment(const {
        'SMARTSCHOOL_SITE': '  demo  ',
        'SMARTSCHOOL_ACCESSCODE': '  secret  ',
      });
      expect(config, isNotNull);
      expect(config!.site, 'demo');
      expect(config.accessCode, 'secret');
    });

    test('connector() builds a connector from the config', () {
      const config = SmartschoolLiveConfig(site: 'demo', accessCode: 'x');
      expect(config.connector(), isA<SmartschoolConnector>());
    });

    test('exposes the canonical env var names', () {
      expect(SmartschoolLiveConfig.envVarNames, [
        'SMARTSCHOOL_SITE',
        'SMARTSCHOOL_ACCESSCODE',
      ]);
    });
  });
}
