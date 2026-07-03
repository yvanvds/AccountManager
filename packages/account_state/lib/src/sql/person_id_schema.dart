/// The Azure SQL schema backing [AzureSqlPersonIdResolver].
///
/// Phase B moves the shared PersonId identity map off each operator's
/// per-machine `FilePersonIdResolver` JSON into one centralized Azure SQL table
/// (epic #74, slice #85). This is the correctness fix at the heart of the epic
/// (#76): a per-machine map mints a *different* [PersonId] for the same human on
/// each operator, so the map must centralize.
///
/// The table is the whole design: a single `NaturalKey → PersonId` mapping with
/// the natural key as the **primary key**. That primary key is the unique
/// constraint the resolver relies on — when two operators both mint an id for a
/// brand-new key, the second `INSERT` finds the key present (the first
/// operator's row) and takes that id instead of its own, so both converge on one
/// [PersonId]. No id is a secret, so nothing here goes through Key Vault.
///
/// The statement is idempotent (`IF OBJECT_ID(...) IS NULL`), so provisioning
/// can re-run it safely. It is exposed as data rather than executed here because
/// the concrete ODBC/FFI driver that would run it is deferred to #89; the opt-in
/// live round-trip test provisions the schema through the seam.
library;

/// The identity-map table: one row per person, keyed by the linker's natural
/// key. [naturalKeyMaxLength] bounds the key so it fits a clustered primary-key
/// index (SQL Server caps a key column at 900 bytes; `NVARCHAR(450)` is the
/// widest that always fits).
const String personIdentityTableName = 'dbo.PersonIdentity';

/// The maximum natural-key length the [personIdentityTableName] primary key
/// admits. Natural keys are short, namespaced strings (`wisa:123`,
/// `staff:code:abc`, `mail:<address>`); 450 leaves ample headroom while staying
/// within the 900-byte index-key limit.
const int naturalKeyMaxLength = 450;

/// The ordered DDL that provisions the identity-map schema. Idempotent: the
/// statement is a no-op when the table already exists, so a deploy can re-run it.
const List<String> personIdentitySchemaStatements = [
  '''
IF OBJECT_ID(N'dbo.PersonIdentity', N'U') IS NULL
CREATE TABLE dbo.PersonIdentity (
  NaturalKey NVARCHAR(450) NOT NULL PRIMARY KEY,
  PersonId NVARCHAR(64) NOT NULL
);''',
];
