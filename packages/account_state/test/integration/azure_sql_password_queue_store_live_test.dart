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
/// Enabled by #89, which wired [_liveFactory] to the concrete ODBC/FFI driver.
/// It is Windows-only (needs `msodbcsql18` + a live AAD-authenticated DB + a
/// fresh token), so it stays offline-by-default: the group runs only when
/// `AZURE_SQL_ACCESS_TOKEN` (+ server/database) is set, and is skipped
/// otherwise. The adapter also stays covered by the seam-fake unit tests in
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

        // Provision the schema through the real driver before the round-trip;
        // the DDL is idempotent, so a re-run is a no-op.
        await _provision(sqlConfig, tokens, passwordQueueSchemaStatements);

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
