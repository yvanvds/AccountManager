/// The Azure SQL schema backing [AzureSqlPasswordQueueStore].
///
/// Phase B moves the pending-password queue off each operator's per-machine
/// `Passwords.json` / `CoPasswords.json` ([FilePasswordQueueStore]) into one
/// centralized Azure SQL table (epic #74, slice #86). Centralizing it is the
/// point of the slice: one operator generates the passwords, another prints the
/// sheets, so the queue must be **shared** rather than sitting on the generating
/// machine's disk.
///
/// The queue is a single flat table carrying **both** [PasswordAccountKind]s —
/// the `Kind` column is the discriminator the model already uses
/// ([PasswordEntry.kind]), exactly as the legacy split between `Passwords.json`
/// and `CoPasswords.json` collapses to one seam here. Every [PasswordEntry]
/// field is a typed column; the optional fields are nullable, matching the
/// model's `String?`s.
///
/// **Sensitive and short-lived.** Unlike the settings and identity tables, this
/// one holds live plaintext passwords by design — they exist only long enough to
/// be printed and handed out. The queue is therefore **cleared as a whole** by a
/// [save] with the remaining entries after distribution (the legacy behaviour:
/// the list is emptied once the sheets are exported), so rows never linger. It
/// deliberately stores the password itself rather than a Key Vault `SecretRef`:
/// a one-shot distribution secret has no identity to resolve later and would
/// only clutter the vault. Access is guarded by the same AAD-only,
/// per-operator-token path as every other Phase B table.
///
/// The statement is idempotent (`IF OBJECT_ID(...) IS NULL`), so provisioning
/// can re-run it safely. It is exposed as data rather than executed here because
/// the concrete ODBC/FFI driver that would run it is deferred to #89; the opt-in
/// live round-trip test provisions the schema through the seam.
library;

/// The pending-password queue table: one row per queued [PasswordEntry],
/// ordered by insertion so the queue round-trips in the order it was saved.
/// `Kind` discriminates own-account from co-account entries.
const String passwordQueueTableName = 'dbo.PasswordQueue';

/// The ordered DDL that provisions the queue schema. Idempotent: the statement
/// is a no-op when the table already exists, so a deploy can re-run it.
const List<String> passwordQueueSchemaStatements = [
  '''
IF OBJECT_ID(N'dbo.PasswordQueue', N'U') IS NULL
CREATE TABLE dbo.PasswordQueue (
  Id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  PersonId NVARCHAR(64) NOT NULL,
  Kind NVARCHAR(16) NOT NULL CHECK (Kind IN (N'account', N'coAccount')),
  AccountName NVARCHAR(256) NOT NULL,
  DisplayName NVARCHAR(256) NOT NULL,
  Mail NVARCHAR(256) NULL,
  ClassGroup NVARCHAR(256) NULL,
  SmartschoolPassword NVARCHAR(256) NULL,
  AzurePassword NVARCHAR(256) NULL
);''',
];
