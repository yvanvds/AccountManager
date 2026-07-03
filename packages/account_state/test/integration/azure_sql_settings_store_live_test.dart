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
/// It cannot run yet: the concrete ODBC/FFI [SqlConnectionFactory] is deferred
/// to #89 (it is Windows-only, needs `msodbcsql18` + a live DB, and can't be
/// unit-tested headlessly). The body below is the ready-made round-trip that
/// slice will enable by wiring [_liveFactory] to the real driver and dropping
/// the group `skip`. Until then the adapter is fully covered by the seam-fake
/// unit tests in `test/sql/azure_sql_settings_store_test.dart`.
void main() {
  final config = AzureSqlLiveConfig.fromEnvironment();

  group(
    'AzureSqlSettingsStore live round-trip',
    () {
      test('save then load round-trips through real Azure SQL', () async {
        final store = AzureSqlSettingsStore(
          factory: _liveFactory(),
          config: AzureSqlConfig(
            server: config!.server,
            database: config.database,
          ),
          tokens: StaticAadTokenProvider(config.accessToken),
        );

        // #89 will provision the schema through the factory before this runs;
        // documented here as the precondition rather than executed blind.
        //   for (final ddl in settingsSchemaStatements) { ... }

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
    // Two gates: offline by default (no token), and blocked on the real driver.
    skip: 'Requires the concrete ODBC/FFI SqlConnectionFactory (#89); '
        'the adapter is covered by the seam-fake unit tests. '
        'Set AZURE_SQL_ACCESS_TOKEN and wire _liveFactory to run.',
  );
}

/// The production [SqlConnectionFactory] the live round-trip needs. Deferred to
/// #89 — throws until the real ODBC/FFI driver is wired, which is why the group
/// above is skipped.
SqlConnectionFactory _liveFactory() => throw UnimplementedError(
      'Concrete ODBC/FFI SqlConnectionFactory is deferred to #89.',
    );
