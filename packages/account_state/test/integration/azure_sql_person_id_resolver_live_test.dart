@Timeout(Duration(minutes: 1))
library;

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in, **write-capable** live round-trip of [AzureSqlPersonIdResolver]
/// against the real Azure SQL identity map (issue #85).
///
/// Provisions the identity table, primes two keys, and asserts a second
/// resolver over the same database adopts the ids the first minted — the
/// centralized-map convergence the epic exists for (#76), proven end-to-end
/// through the real driver. Because it writes, it is **manual/opt-in** per the
/// repo live-testing policy — never part of the read-only CI live set — and
/// needs a fresh AAD token (see `AzureSqlLiveConfig`).
///
/// Enabled by #89, which wired [_liveFactory] to the concrete ODBC/FFI driver.
/// It is Windows-only (needs `msodbcsql18` + a live AAD-authenticated DB + a
/// fresh token), so it stays offline-by-default: the group runs only when
/// `AZURE_SQL_ACCESS_TOKEN` (+ server/database) is set, and is skipped
/// otherwise. The resolver also stays covered by the seam-fake unit tests in
/// `test/sql/azure_sql_person_id_resolver_test.dart`.
void main() {
  final config = AzureSqlLiveConfig.fromEnvironment();

  group(
    'AzureSqlPersonIdResolver live convergence',
    () {
      test('two resolvers over one DB converge on a single PersonId', () async {
        final sqlConfig = AzureSqlConfig(
          server: config!.server,
          database: config.database,
        );
        final tokens = StaticAadTokenProvider(config.accessToken);

        // Provision the schema through the real driver before the round-trip;
        // the DDL is idempotent, so a re-run is a no-op.
        await _provision(sqlConfig, tokens, personIdentitySchemaStatements);

        final key = 'wisa:live-${config.accessToken.hashCode}';

        final first = AzureSqlPersonIdResolver(
          factory: _liveFactory(),
          config: sqlConfig,
          tokens: tokens,
        );
        await first.prepare([key]);
        final minted = first.resolve(key);

        final second = AzureSqlPersonIdResolver(
          factory: _liveFactory(),
          config: sqlConfig,
          tokens: tokens,
        );
        await second.prepare([key]);

        expect(second.resolve(key), equals(minted),
            reason: 'the shared map yields one id per natural key');
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
