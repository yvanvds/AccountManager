import 'azure_sql_config.dart';
import 'aad_token_provider.dart';

/// One row of a query result: column name to value.
typedef SqlRow = Map<String, Object?>;

/// An open, authenticated connection to the centralized Azure SQL database.
///
/// The seam the four Phase B adapters plug into (issue #74): the Azure-backed
/// `SettingsStore`, `SecretProvider` companion, `PersonIdResolver`, and
/// `PasswordQueueStore` all read and write through this surface instead of
/// touching a driver directly, exactly as they hide disk behind their existing
/// file-backed defaults. Keeping the surface this small means the adapters are
/// unit-testable against a hand-written fake and only one class binds the real
/// driver.
///
/// [transaction] is not a convenience: the DB-backed PersonId resolver (#85)
/// mints one id per natural key under a unique constraint, and needs the
/// insert-or-fetch to run atomically so two operators converge on the same id.
///
/// The concrete implementation is FFI over the Microsoft ODBC Driver 18 for SQL
/// Server (`msodbcsql18`), authenticated with the [AadTokenProvider] token —
/// see the connectivity decision in `docs/port-plan.md`. It is built in the
/// first adapter slice (#83) so it lands with a real consumer; there is no
/// pure-Dart TDS driver to use instead.
abstract interface class SqlConnection {
  /// Runs [sql] and returns the result rows. Parameters are passed positionally
  /// as [params] and bound by the driver (never string-interpolated), so a
  /// value can never be read as SQL.
  Future<List<SqlRow>> query(String sql, [List<Object?> params]);

  /// Runs [sql] as a statement and returns the number of affected rows.
  Future<int> execute(String sql, [List<Object?> params]);

  /// Runs [action] inside a single database transaction, passing a connection
  /// scoped to it. Commits when [action] completes, rolls back if it throws.
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action);

  /// Releases the underlying connection. A no-op if already closed.
  Future<void> close();
}

/// Opens [SqlConnection]s to a configured Azure SQL database.
///
/// Injected wherever the adapters are constructed, the same way `azure_api`
/// takes an `AuthProvider`: production wires the ODBC/FFI factory, tests wire a
/// fake that returns a scripted [SqlConnection]. [open] reads a fresh token
/// from [tokens] each call, so a connection never outlives its bearer token.
abstract interface class SqlConnectionFactory {
  /// Opens a connection to [config], authenticating with a token read from
  /// [tokens]. The caller owns the returned connection and must [
  /// SqlConnection.close] it (directly or via the orchestration layer).
  Future<SqlConnection> open(AzureSqlConfig config, AadTokenProvider tokens);
}
