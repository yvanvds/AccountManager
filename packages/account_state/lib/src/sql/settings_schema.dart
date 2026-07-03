/// The Azure SQL schema backing [AzureSqlSettingsStore].
///
/// Phase B moves the shared config off per-operator `config.json`
/// ([FileSettingsStore]) into one centralized Azure SQL database (epic #74) so
/// the tool can move to team maintenance. This is the *settings* slice (#83):
/// the [AppSettings] model laid out **fully relationally** — one typed column
/// per scalar field (including the WISA work-date pair and each Smartschool
/// grade/year label), plus a child table for the per-connector import-rule
/// sets. Nothing sensitive is stored: the WISA password and Smartschool
/// passphrase live behind a `SecretRef` and are resolved through the Key Vault
/// adapter (#84), so only the (non-secret) ref names reach these tables.
///
/// The statements are idempotent (`IF OBJECT_ID(...) IS NULL`), so provisioning
/// can re-run them safely. They are exposed as data rather than executed here
/// because the concrete ODBC/FFI driver that would run them is deferred to #89;
/// the opt-in live round-trip test provisions the schema through the seam.
library;

/// Singleton settings row. A `CHECK (Id = 1)` constraint enforces exactly one
/// row: the config is loaded and saved whole, never queried per-operator.
const String settingsTableName = 'dbo.AppSettings';

/// Child table holding one row per import rule, ordered within its connector by
/// [ordinal]. Each rule's [payload] is the tagged JSON produced by
/// `encodeWisaRule` / `encodeSmartschoolRule` — the codec round-trips unchanged,
/// so the sealed rule hierarchy stays free of any persistence concern.
const String importRulesTableName = 'dbo.ImportRules';

/// The ordered DDL that provisions the settings schema. Idempotent: each
/// statement is a no-op when its table already exists, so a deploy can re-run
/// the whole list.
const List<String> settingsSchemaStatements = [
  '''
IF OBJECT_ID(N'dbo.AppSettings', N'U') IS NULL
CREATE TABLE dbo.AppSettings (
  Id INT NOT NULL PRIMARY KEY CHECK (Id = 1),
  SchoolPrefix NVARCHAR(64) NOT NULL,
  DebugMode BIT NOT NULL,
  WisaServer NVARCHAR(256) NOT NULL,
  WisaPort NVARCHAR(16) NOT NULL,
  WisaDatabase NVARCHAR(256) NOT NULL,
  WisaUsername NVARCHAR(256) NOT NULL,
  WisaPasswordRef NVARCHAR(256) NOT NULL,
  WisaWorkDateIsNow BIT NOT NULL,
  WisaWorkDate DATETIME2 NULL,
  WisaVirtualWorkDateIsNow BIT NOT NULL,
  WisaVirtualWorkDate DATETIME2 NULL,
  SmartschoolUri NVARCHAR(512) NOT NULL,
  SmartschoolPassphraseRef NVARCHAR(256) NOT NULL,
  SmartschoolTestUser NVARCHAR(256) NOT NULL,
  SmartschoolStudentGroup NVARCHAR(256) NOT NULL,
  SmartschoolStaffGroup NVARCHAR(256) NOT NULL,
  SmartschoolUseGrades BIT NOT NULL,
  SmartschoolUseYears BIT NOT NULL,
  SmartschoolGrade1 NVARCHAR(128) NOT NULL,
  SmartschoolGrade2 NVARCHAR(128) NOT NULL,
  SmartschoolGrade3 NVARCHAR(128) NOT NULL,
  SmartschoolYear1 NVARCHAR(128) NOT NULL,
  SmartschoolYear2 NVARCHAR(128) NOT NULL,
  SmartschoolYear3 NVARCHAR(128) NOT NULL,
  SmartschoolYear4 NVARCHAR(128) NOT NULL,
  SmartschoolYear5 NVARCHAR(128) NOT NULL,
  SmartschoolYear6 NVARCHAR(128) NOT NULL,
  SmartschoolYear7 NVARCHAR(128) NOT NULL,
  AzureClientId NVARCHAR(256) NOT NULL,
  AzureTenantId NVARCHAR(256) NOT NULL,
  AzureDomain NVARCHAR(256) NOT NULL
);''',
  '''
IF OBJECT_ID(N'dbo.ImportRules', N'U') IS NULL
CREATE TABLE dbo.ImportRules (
  Id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  SystemKey NVARCHAR(16) NOT NULL CHECK (SystemKey IN (N'wisa', N'smartschool')),
  Ordinal INT NOT NULL,
  Payload NVARCHAR(MAX) NOT NULL
);''',
  '''
IF NOT EXISTS (
  SELECT 1 FROM sys.indexes
  WHERE name = N'IX_ImportRules_SystemKey_Ordinal'
    AND object_id = OBJECT_ID(N'dbo.ImportRules', N'U')
)
CREATE INDEX IX_ImportRules_SystemKey_Ordinal
  ON dbo.ImportRules (SystemKey, Ordinal);''',
];
