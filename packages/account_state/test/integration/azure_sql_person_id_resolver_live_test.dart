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
/// It cannot run yet: the concrete ODBC/FFI [SqlConnectionFactory] is deferred
/// to #89 (Windows-only, needs `msodbcsql18` + a live DB, not unit-testable
/// headlessly). The body below is the ready-made round-trip that slice will
/// enable by wiring [_liveFactory] to the real driver and dropping the `skip`.
/// Until then the resolver is fully covered by the seam-fake unit tests in
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

        // #89 will provision the schema through the factory before this runs;
        // documented here as the precondition rather than executed blind.
        //   for (final ddl in personIdentitySchemaStatements) { ... }

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
    // Two gates: offline by default (no token), and blocked on the real driver.
    skip: 'Requires the concrete ODBC/FFI SqlConnectionFactory (#89); '
        'the resolver is covered by the seam-fake unit tests. '
        'Set AZURE_SQL_ACCESS_TOKEN and wire _liveFactory to run.',
  );
}

/// The production [SqlConnectionFactory] the live round-trip needs. Deferred to
/// #89 — throws until the real ODBC/FFI driver is wired, which is why the group
/// above is skipped.
SqlConnectionFactory _liveFactory() => throw UnimplementedError(
      'Concrete ODBC/FFI SqlConnectionFactory is deferred to #89.',
    );
