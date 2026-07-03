import 'dart:io';

/// Configuration for the opt-in, **read-only** Azure SQL live check
/// (`test/integration/azure_sql_live_test.dart`).
///
/// The check verifies the *authentication foundation* from Dart: that an
/// operator can mint a bearer token scoped to the SQL resource
/// (`https://database.windows.net/`) against the real tenant. It does not write
/// to the database — honouring the repo live-testing policy — and does not need
/// a driver, so it runs before the ODBC adapter exists. The full DB round-trip
/// was proven by the connectivity spike (see `docs/port-plan.md`) and is
/// re-exercised in Dart once the adapter lands (#83).
///
/// Offline unit tests never read this. See `.azuresql.env.example` at the
/// repository root for the variable names.
class AzureSqlLiveConfig {
  const AzureSqlLiveConfig({
    required this.server,
    required this.database,
    required this.accessToken,
  });

  /// The fully-qualified server host under test.
  final String server;

  /// The database (catalog) name under test.
  final String database;

  /// A pre-acquired bearer token for `https://database.windows.net/`. Expires
  /// in ~1 hour, so it is minted fresh per run rather than stored (e.g.
  /// `az account get-access-token --resource https://database.windows.net/`).
  final String accessToken;

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'AZURE_SQL_SERVER',
    'AZURE_SQL_DATABASE',
    'AZURE_SQL_ACCESS_TOKEN',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `AZURE_SQL_ACCESS_TOKEN` is
  /// empty or missing — the integration test uses this as its skip signal, so
  /// `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `AZURE_SQL_ACCESS_TOKEN` is set but one of the
  /// other required variables is missing.
  static AzureSqlLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessToken = (source['AZURE_SQL_ACCESS_TOKEN'] ?? '').trim();
    if (accessToken.isEmpty) return null;

    String required(String name) {
      final value = (source[name] ?? '').trim();
      if (value.isEmpty) {
        throw ArgumentError(
          'AZURE_SQL_ACCESS_TOKEN is set but $name is missing or empty.',
        );
      }
      return value;
    }

    return AzureSqlLiveConfig(
      server: required('AZURE_SQL_SERVER'),
      database: required('AZURE_SQL_DATABASE'),
      accessToken: accessToken,
    );
  }
}
