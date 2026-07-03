@Timeout(Duration(minutes: 1))
library;

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// Opt-in, **write-capable** live round-trip of [AzureSqlSettingsStore] against
/// the real Azure SQL database (issue #83).
///
/// This is the DB half of the foundation the connectivity spike proved
/// (`docs/port-plan.md`): provision the settings schema, save an [AppSettings],
/// read it back, and assert it survived the relational mapping. Because it
/// writes, it is **manual/opt-in** per the repo live-testing policy — never part
/// of the read-only CI live set — and needs a fresh AAD token (see
/// `AzureSqlLiveConfig`).
///
/// Enabled by #89, which wired [_liveFactory] to the concrete ODBC/FFI driver.
/// It is Windows-only (needs `msodbcsql18` + a live AAD-authenticated DB + a
/// fresh token), so it stays offline-by-default: the group runs only when
/// `AZURE_SQL_ACCESS_TOKEN` (+ server/database) is set, and is skipped
/// otherwise. The adapter also stays covered by the seam-fake unit tests in
/// `test/sql/azure_sql_settings_store_test.dart`.
void main() {
  final config = AzureSqlLiveConfig.fromEnvironment();

  group(
    'AzureSqlSettingsStore live round-trip',
    () {
      test('save then load round-trips through real Azure SQL', () async {
        final sqlConfig = AzureSqlConfig(
          server: config!.server,
          database: config.database,
        );
        final tokens = StaticAadTokenProvider(config.accessToken);
        final store = AzureSqlSettingsStore(
          factory: _liveFactory(),
          config: sqlConfig,
          tokens: tokens,
        );

        // Provision the schema through the real driver before the round-trip;
        // the DDL is idempotent, so a re-run is a no-op.
        await _provision(sqlConfig, tokens, settingsSchemaStatements);

        final probe = AppSettings(
          schoolPrefix: 'LIVE',
          debugMode: true,
          wisa: WisaConnection(
            server: 'db.example',
            workDate:
                WorkDateSetting(isNow: false, date: DateTime(2026, 6, 30)),
          ),
          wisaRules: const [DontImportClass('1A')],
        );

        await store.save(probe);
        final loaded = await store.load();

        expect(loaded.schoolPrefix, 'LIVE');
        expect(loaded.debugMode, isTrue);
        expect(loaded.wisa.server, 'db.example');
        expect(loaded.wisa.workDate.date, DateTime(2026, 6, 30));
        expect(loaded.wisaRules, hasLength(1));
      });
    },
    // Offline by default: skipped unless a live token (+ server/database) is set.
    skip: config == null
        ? 'Set AZURE_SQL_ACCESS_TOKEN (+ AZURE_SQL_SERVER/DATABASE) to run.'
        : false,
  );
}

/// The production [SqlConnectionFactory] the live round-trip runs against: the
/// concrete ODBC/FFI driver wired in #89.
SqlConnectionFactory _liveFactory() => OdbcSqlConnectionFactory();

/// Runs the schema [ddl] through the real driver so the round-trip has its
/// tables. Opens a fresh connection (a new token per open) and closes it.
Future<void> _provision(
  AzureSqlConfig config,
  AadTokenProvider tokens,
  List<String> ddl,
) async {
  final connection = await _liveFactory().open(config, tokens);
  try {
    for (final statement in ddl) {
      await connection.execute(statement);
    }
  } finally {
    await connection.close();
  }
}
