import 'package:account_core/account_core.dart';

import '../passwords/password_entry.dart';
import '../passwords/password_queue_store.dart';
import 'aad_token_provider.dart';
import 'azure_sql_config.dart';
import 'password_queue_schema.dart';
import 'sql_connection.dart';

/// A [PasswordQueueStore] backed by the centralized Azure SQL database.
///
/// The Phase B replacement for [FilePasswordQueueStore] (issue #86): the same
/// [PasswordEntry] queue, but shared by the whole team instead of living in the
/// generating operator's `Passwords.json` / `CoPasswords.json`. That sharing is
/// the point — one operator generates the passwords and another prints the
/// sheets, which only works if both see the one queue (see
/// `password_queue_schema.dart`).
///
/// Both [PasswordAccountKind]s live in one [passwordQueueTableName] table, the
/// `Kind` column discriminating them, so the seam stays the single injectable
/// interface it already is. Every entry field maps to a typed column; the
/// optional fields are nullable.
///
/// Because the database is AAD-only with short-lived per-operator tokens, each
/// [load] / [save] opens a fresh connection through the injected
/// [SqlConnectionFactory] (which reads a new token per open) and closes it when
/// done. A [save] runs inside a single transaction — clear the whole table, then
/// re-insert — so the queue faithfully "replaces the whole queue" and a
/// partially written queue can never be read back. The whole-replace is also how
/// the queue stays **short-lived**: after distribution the operator saves the
/// remaining (usually empty) list and the printed rows are gone.
///
/// The concrete ODBC/FFI [SqlConnectionFactory] this plugs into is deferred to
/// #89; unit tests drive a scripted fake and the opt-in live round-trip test
/// (skipped by default) exercises the real driver once it lands.
class AzureSqlPasswordQueueStore implements PasswordQueueStore {
  AzureSqlPasswordQueueStore({
    required SqlConnectionFactory factory,
    required AzureSqlConfig config,
    required AadTokenProvider tokens,
  })  : _factory = factory,
        _config = config,
        _tokens = tokens;

  final SqlConnectionFactory _factory;
  final AzureSqlConfig _config;
  final AadTokenProvider _tokens;

  @override
  Future<List<PasswordEntry>> load() async {
    final connection = await _factory.open(_config, _tokens);
    try {
      final rows = await connection.query(_selectSql);
      return [for (final row in rows) _entryFromRow(row)];
    } finally {
      await connection.close();
    }
  }

  @override
  Future<void> save(List<PasswordEntry> entries) async {
    final connection = await _factory.open(_config, _tokens);
    try {
      await connection.transaction((tx) async {
        // Whole-queue replace: clear then re-insert in order. The queue is small
        // and short-lived, so this is both simpler than a per-entry diff and how
        // the queue is drained after distribution (save the remaining list).
        await tx.execute('DELETE FROM $passwordQueueTableName');
        for (final entry in entries) {
          await tx.execute(_insertSql, _entryParams(entry));
        }
      });
    } finally {
      await connection.close();
    }
  }

  PasswordEntry _entryFromRow(SqlRow row) => PasswordEntry(
        personId: PersonId(_string(row['PersonId'])),
        kind: _kind(_string(row['Kind'])),
        accountName: _string(row['AccountName']),
        displayName: _string(row['DisplayName']),
        mail: row['Mail'] as String?,
        classGroup: row['ClassGroup'] as String?,
        smartschoolPassword: row['SmartschoolPassword'] as String?,
        azurePassword: row['AzurePassword'] as String?,
      );

  List<Object?> _entryParams(PasswordEntry e) => [
        e.personId.value,
        e.kind.name,
        e.accountName,
        e.displayName,
        e.mail,
        e.classGroup,
        e.smartschoolPassword,
        e.azurePassword,
      ];
}

/// The queue columns, in the order [AzureSqlPasswordQueueStore._entryParams]
/// binds them. Shared by the INSERT and SELECT so the two can never drift. `Id`
/// is omitted: it is an identity column the driver fills, and the SELECT orders
/// by it to preserve insertion order.
const List<String> _entryColumns = [
  'PersonId',
  'Kind',
  'AccountName',
  'DisplayName',
  'Mail',
  'ClassGroup',
  'SmartschoolPassword',
  'AzurePassword',
];

final String _insertSql = 'INSERT INTO $passwordQueueTableName '
    '(${_entryColumns.join(', ')}) '
    'VALUES (${List.filled(_entryColumns.length, '?').join(', ')})';

/// Reads the queue in insertion order so a saved list round-trips unchanged.
final String _selectSql =
    'SELECT ${_entryColumns.join(', ')} FROM $passwordQueueTableName '
    'ORDER BY Id';

/// Reads a driver value as a non-null string. The columns coerced here are
/// declared `NOT NULL`, so a null would be a schema violation; coercing keeps
/// the mapping total and driver-agnostic.
String _string(Object? value) => (value as String?) ?? '';

/// Parses the `Kind` discriminator back into a [PasswordAccountKind], throwing
/// on an unknown tag exactly as [PasswordEntry.fromJson] does — a `CHECK`
/// constraint bounds the column, so this only fires on a schema mismatch.
PasswordAccountKind _kind(String name) => PasswordAccountKind.values.firstWhere(
      (k) => k.name == name,
      orElse: () => throw FormatException('Unknown PasswordAccountKind: $name'),
    );
