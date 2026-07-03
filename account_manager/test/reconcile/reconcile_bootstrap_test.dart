import 'package:account_manager/src/auth/aad_app_config.dart';
import 'package:account_manager/src/auth/sign_in_session.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../auth/fake_broker.dart';

const _aad = AadAppConfig(
  clientId: 'client-123',
  tenantId: 'tenant-abc',
  azureDomain: 'school.example',
  schoolPrefix: 'GBS',
);

/// A settings store whose [load] throws — models a broken SQL path.
class _ThrowingStore implements SettingsStore {
  const _ThrowingStore(this.error);

  final Object error;

  @override
  Future<AppSettings> load() async => throw error;

  @override
  Future<void> save(AppSettings settings) async {}
}

/// The bootstrap never opens a SQL connection itself when the settings store
/// is injected, so any [open] call is a wiring regression.
class _UnreachableFactory implements SqlConnectionFactory {
  @override
  Future<SqlConnection> open(AzureSqlConfig config, AadTokenProvider tokens) =>
      throw StateError('bootstrap must not open a SQL connection');
}

AppSettings _settings({
  String server = 'wisa.local',
  String port = '9000',
  String smartschoolUri = 'https://demo.smartschool.be',
}) =>
    AppSettings(
      schoolPrefix: 'GBS',
      wisa: WisaConnection(
        server: server,
        port: port,
        database: 'wisadb',
        username: 'operator',
      ),
      smartschool: SmartschoolConnection(uri: smartschoolUri),
      azure: const AzureConnection(domain: 'school.example'),
    );

InMemorySecretProvider _secrets({bool wisa = true, bool smartschool = true}) =>
    InMemorySecretProvider({
      if (wisa) const SecretRef('wisa.password'): 'geheim',
      if (smartschool) const SecretRef('smartschool.passphrase'): 'zin',
    });

Future<ReconcileServices> _bootstrap({
  SettingsStore? store,
  SecretProvider? secrets,
}) =>
    bootstrapReconcile(
      session: SignInSession(FakeBroker()),
      aad: _aad,
      settingsStore: store ?? InMemorySettingsStore(_settings()),
      secretProvider: secrets ?? _secrets(),
      sqlFactory: _UnreachableFactory(),
    );

void main() {
  group('bootstrapReconcile', () {
    test('assembles the full stack from settings + secrets', () async {
      final services = await _bootstrap();

      expect(services.settings.schoolPrefix, 'GBS');
      expect(services.app.wisa.snapshot, isNull,
          reason: 'nothing synced yet at bootstrap');
      expect(services.controller.linked, isNull);
      expect(identical(services.controller.log, services.log), isTrue);
    });

    test('a missing WISA password is an actionable config error', () {
      expect(
        () => _bootstrap(secrets: _secrets(wisa: false)),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('wisa.password'),
        )),
      );
    });

    test('a missing Smartschool passphrase is an actionable config error', () {
      expect(
        () => _bootstrap(secrets: _secrets(smartschool: false)),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('smartschool.passphrase'),
        )),
      );
    });

    test('an incomplete WISA profile is an actionable config error', () {
      expect(
        () => _bootstrap(store: InMemorySettingsStore(_settings(port: 'nan'))),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('WISA connection profile'),
        )),
      );
    });

    test('a missing ODBC driver (IM002) names the msodbcsql18 prerequisite',
        () {
      expect(
        () => _bootstrap(
          store: const _ThrowingStore(
            'OdbcException(SQLDriverConnect): [IM002] [Microsoft]'
            '[ODBC Driver Manager] Data source name not found and no '
            'default driver specified',
          ),
        ),
        throwsA(isA<ReconcileConfigException>().having(
          (e) => e.message,
          'message',
          contains('ODBC Driver 18'),
        )),
      );
    });

    test('other settings-store failures propagate unmapped', () {
      expect(
        () => _bootstrap(store: const _ThrowingStore('login timed out')),
        throwsA('login timed out'),
      );
    });
  });

  group('smartschoolSiteFrom', () {
    test('extracts the site from a full smartschool.be URL', () {
      expect(
        smartschoolSiteFrom('https://demo.smartschool.be/Webservices/V3'),
        'demo',
      );
    });

    test('extracts the site from a bare smartschool.be host', () {
      expect(smartschoolSiteFrom('demo.smartschool.be'), 'demo');
    });

    test('accepts a bare site name as-is', () {
      expect(smartschoolSiteFrom('demo'), 'demo');
    });

    test('is empty for an empty setting', () {
      expect(smartschoolSiteFrom('  '), '');
    });
  });

  group('classTreeFrom', () {
    test('uses years only when the school enables them', () {
      final on = classTreeFrom(SmartschoolConnection(
        useYears: true,
        years: ['Y1', 'Y2', 'Y3', 'Y4', 'Y5', 'Y6', 'Y7'],
        studentGroup: 'LLN',
      ));
      expect(on.years, isNotEmpty);
      expect(on.grades, isEmpty);
      expect(on.path, 'LLN');

      final off = classTreeFrom(SmartschoolConnection(
        years: ['Y1', 'Y2', 'Y3', 'Y4', 'Y5', 'Y6', 'Y7'],
      ));
      expect(off.years, isEmpty);
    });

    test('uses grades only when the school enables them', () {
      final tree = classTreeFrom(SmartschoolConnection(
        useGrades: true,
        grades: ['G1', 'G2', 'G3'],
      ));
      expect(tree.grades, isNotEmpty);
      expect(tree.years, isEmpty);
    });
  });
}
