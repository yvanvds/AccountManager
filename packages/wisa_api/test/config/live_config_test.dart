import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

const Map<String, String> _completeEnv = {
  'WISA_SERVER': '  wisa.example.be  ',
  'WISA_PORT': ' 443 ',
  'WISA_DATABASE': ' SCHOOLDB ',
  'WISA_USERNAME': ' user ',
  'WISA_PASSWORD': ' secret ',
  'WISA_SCHOOL_ID': ' 42 ',
};

void main() {
  group('WisaLiveConfig.fromEnvironment', () {
    test('returns null when the username is empty or missing', () {
      expect(WisaLiveConfig.fromEnvironment(const {}), isNull);
      expect(
        WisaLiveConfig.fromEnvironment(
          {..._completeEnv, 'WISA_USERNAME': '  '},
        ),
        isNull,
      );
    });

    test('throws when the username is set but another variable is missing', () {
      expect(
        () => WisaLiveConfig.fromEnvironment(const {
          'WISA_USERNAME': 'user',
        }),
        throwsArgumentError,
      );
    });

    test('throws when a numeric variable cannot be parsed', () {
      expect(
        () => WisaLiveConfig.fromEnvironment(
          {..._completeEnv, 'WISA_PORT': 'not-a-number'},
        ),
        throwsArgumentError,
      );
      expect(
        () => WisaLiveConfig.fromEnvironment(
          {..._completeEnv, 'WISA_SCHOOL_ID': 'not-a-number'},
        ),
        throwsArgumentError,
      );
    });

    test('parses and trims a complete environment', () {
      final config = WisaLiveConfig.fromEnvironment(_completeEnv);
      expect(config, isNotNull);
      expect(config!.server, 'wisa.example.be');
      expect(config.port, 443);
      expect(config.database, 'SCHOOLDB');
      expect(config.username, 'user');
      expect(config.password, 'secret');
      expect(config.schoolId, 42);
      expect(config.workDate, isNull);
    });

    test('parses WISA_WERKDATUM as an ISO date', () {
      final config = WisaLiveConfig.fromEnvironment(
        {..._completeEnv, 'WISA_WERKDATUM': ' 2026-01-15 '},
      );
      expect(config!.workDate, DateTime(2026, 1, 15));
    });

    test('treats a blank WISA_WERKDATUM as unset', () {
      final config = WisaLiveConfig.fromEnvironment(
        {..._completeEnv, 'WISA_WERKDATUM': '   '},
      );
      expect(config!.workDate, isNull);
    });

    test('throws when WISA_WERKDATUM is not an ISO date', () {
      expect(
        () => WisaLiveConfig.fromEnvironment(
          {..._completeEnv, 'WISA_WERKDATUM': '30/06/2026'},
        ),
        throwsArgumentError,
      );
    });

    test('exposes the canonical env var names', () {
      expect(WisaLiveConfig.envVarNames, [
        'WISA_SERVER',
        'WISA_PORT',
        'WISA_DATABASE',
        'WISA_USERNAME',
        'WISA_PASSWORD',
        'WISA_SCHOOL_ID',
      ]);
    });
  });

  group('WisaLiveConfig.resolveWorkDate', () {
    const base = WisaLiveConfig(
      server: 's',
      port: 1,
      database: 'd',
      username: 'u',
      password: 'p',
      schoolId: 1,
    );

    test('returns the explicit workDate when WISA_WERKDATUM was set', () {
      final config = WisaLiveConfig(
        server: 's',
        port: 1,
        database: 'd',
        username: 'u',
        password: 'p',
        schoolId: 1,
        workDate: DateTime(2025, 10, 1),
      );
      expect(
        config.resolveWorkDate(DateTime(2026, 7, 15)),
        DateTime(2025, 10, 1),
      );
    });

    test('defaults to 30 June of the current year in the summer holiday', () {
      expect(
        base.resolveWorkDate(DateTime(2026, 8, 3)),
        DateTime(2026, 6, 30),
      );
    });

    test('defaults to 30 June of the current year during the school year', () {
      expect(
        base.resolveWorkDate(DateTime(2026, 2, 10)),
        DateTime(2026, 6, 30),
      );
    });
  });

  group('WisaLiveConfig.connector', () {
    test('builds a connector from the config', () {
      const config = WisaLiveConfig(
        server: 's',
        port: 1,
        database: 'd',
        username: 'u',
        password: 'p',
        schoolId: 1,
      );
      expect(config.connector(), isA<WisaConnector>());
    });
  });
}
