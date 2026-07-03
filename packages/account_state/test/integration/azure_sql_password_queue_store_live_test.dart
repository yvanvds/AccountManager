@Timeout(Duration(minutes: 1))
library;

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in, **write-capable** live round-trip of [AzureSqlPasswordQueueStore]
/// against the real Azure SQL database (issue #86).
///
/// Provisions the queue table, saves a queue carrying both
/// [PasswordAccountKind]s, reads it back through a *second* store over the same
/// database (the way one operator generates and another prints), and asserts it
/// survived the relational mapping — then drains it. Because it writes live
/// plaintext passwords, it is **manual/opt-in** per the repo live-testing policy
/// — never part of the read-only CI live set — and needs a fresh AAD token (see
/// `AzureSqlLiveConfig`).
///
/// It cannot run yet: the concrete ODBC/FFI [SqlConnectionFactory] is deferred
/// to #89 (Windows-only, needs `msodbcsql18` + a live DB, not unit-testable
/// headlessly). The body below is the ready-made round-trip that slice will
/// enable by wiring [_liveFactory] to the real driver and dropping the `skip`.
/// Until then the adapter is fully covered by the seam-fake unit tests in
/// `test/sql/azure_sql_password_queue_store_test.dart`.
void main() {
  final config = AzureSqlLiveConfig.fromEnvironment();

  group(
    'AzureSqlPasswordQueueStore live round-trip',
    () {
      test('save then load round-trips the shared queue through real Azure SQL',
          () async {
        final sqlConfig = AzureSqlConfig(
          server: config!.server,
          database: config.database,
        );
        final tokens = StaticAadTokenProvider(config.accessToken);

        // #89 will provision the schema through the factory before this runs;
        // documented here as the precondition rather than executed blind.
        //   for (final ddl in passwordQueueSchemaStatements) { ... }

        final generator = AzureSqlPasswordQueueStore(
          factory: _liveFactory(),
          config: sqlConfig,
          tokens: tokens,
        );
        const queue = [
          PasswordEntry(
            personId: PersonId('live-1'),
            kind: PasswordAccountKind.account,
            accountName: 'live.jansen',
            displayName: 'Live Jansen',
            mail: 'live.jansen@example.org',
            classGroup: '1A',
            smartschoolPassword: 'Sa2b!x',
            azurePassword: 'Ku9d?y',
          ),
          PasswordEntry(
            personId: PersonId('live-2'),
            kind: PasswordAccountKind.coAccount,
            accountName: 'live.peeters',
            displayName: 'Live Peeters',
          ),
        ];
        await generator.save(queue);

        final printer = AzureSqlPasswordQueueStore(
          factory: _liveFactory(),
          config: sqlConfig,
          tokens: tokens,
        );
        final loaded = await printer.load();
        expect(loaded, hasLength(2));
        expect(loaded[0].personId, const PersonId('live-1'));
        expect(loaded[0].smartschoolPassword, 'Sa2b!x');
        expect(loaded[1].kind, PasswordAccountKind.coAccount);
        expect(loaded[1].mail, isNull);

        // Short-lived by design: drain the queue after "printing".
        await printer.save(const []);
        expect(await printer.load(), isEmpty);
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
