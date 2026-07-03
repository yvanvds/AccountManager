import 'dart:convert';

import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import '../settings/app_settings.dart';
import '../settings/connection.dart';
import '../settings/import_rule_codec.dart';
import '../settings/secret_provider.dart';
import '../settings/settings_store.dart';
import '../settings/work_date.dart';
import 'aad_token_provider.dart';
import 'azure_sql_config.dart';
import 'settings_schema.dart';
import 'sql_connection.dart';

/// A [SettingsStore] backed by the centralized Azure SQL database.
///
/// The Phase B replacement for [FileSettingsStore] (issue #83): the same
/// [AppSettings] model, persisted once for the whole team instead of in each
/// operator's `config.json`. Nothing above the seam changes — the orchestration
/// layer still loads once at startup and saves on operator edits — but the
/// bytes now live in the shared [settingsTableName] / [importRulesTableName]
/// tables (see `settings_schema.dart`).
///
/// The config maps **fully relationally**: every scalar is a typed column and
/// the two import-rule sets are child rows whose `Payload` is the codec's
/// tagged JSON, round-tripped through [encodeWisaRule] / [decodeWisaRule] et al.
/// unchanged. No secret is written — a profile contributes only its
/// [SecretRef] name, resolved out of band through the Key Vault [SecretProvider]
/// (#84).
///
/// Because the database is AAD-only with short-lived per-operator tokens, each
/// [load] / [save] opens a fresh connection through the injected
/// [SqlConnectionFactory] (which reads a new token per open) and closes it when
/// done; the config is read and written infrequently enough that connection
/// reuse would buy nothing but a stale-token risk. A [save] runs inside a single
/// transaction so a partially written config can never be read back.
///
/// The concrete ODBC/FFI [SqlConnectionFactory] this plugs into is deferred to
/// #89; unit tests drive a scripted fake and the opt-in live round-trip test
/// (skipped by default) exercises the real driver once it lands.
class AzureSqlSettingsStore implements SettingsStore {
  AzureSqlSettingsStore({
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
  Future<AppSettings> load() async {
    final connection = await _factory.open(_config, _tokens);
    try {
      final rows = await connection.query(_selectSettingsSql);
      // No row yet is first-run, not an error: mirror the file/in-memory stores
      // and hand back a default config so the caller has no special case.
      if (rows.isEmpty) return const AppSettings();
      final ruleRows = await connection.query(_selectRulesSql);
      return _settingsFromRows(rows.first, ruleRows);
    } finally {
      await connection.close();
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    final connection = await _factory.open(_config, _tokens);
    try {
      await connection.transaction((tx) async {
        // Whole-config replace: the settings row is a singleton and the rule
        // sets are small, so clearing and re-inserting is simpler than a
        // per-field diff and keeps `save` faithful to "replaces the previous
        // value". Rules go first so the FK-free child table is never orphaned
        // mid-transaction.
        await tx.execute('DELETE FROM $importRulesTableName');
        await tx.execute('DELETE FROM $settingsTableName');
        await tx.execute(_insertSettingsSql, _settingsParams(settings));
        await _insertRules(
          tx,
          'wisa',
          settings.wisaRules.map((r) => jsonEncode(encodeWisaRule(r))),
        );
        await _insertRules(
          tx,
          'smartschool',
          settings.smartschoolRules
              .map((r) => jsonEncode(encodeSmartschoolRule(r))),
        );
      });
    } finally {
      await connection.close();
    }
  }

  Future<void> _insertRules(
    SqlConnection tx,
    String system,
    Iterable<String> payloads,
  ) async {
    var ordinal = 0;
    for (final payload in payloads) {
      await tx.execute(_insertRuleSql, [system, ordinal, payload]);
      ordinal++;
    }
  }

  AppSettings _settingsFromRows(SqlRow row, List<SqlRow> ruleRows) {
    final wisaRules = <WisaImportRule>[];
    final smartschoolRules = <SmartschoolImportRule>[];
    for (final r in ruleRows) {
      final system = _string(r['SystemKey']);
      final payload = jsonDecode(_string(r['Payload'])) as Map<String, dynamic>;
      switch (system) {
        case 'wisa':
          wisaRules.add(decodeWisaRule(payload));
        case 'smartschool':
          smartschoolRules.add(decodeSmartschoolRule(payload));
        default:
          throw FormatException('Unknown import-rule system: $system');
      }
    }

    return AppSettings(
      schoolPrefix: _string(row['SchoolPrefix']),
      debugMode: _bool(row['DebugMode']),
      wisa: WisaConnection(
        server: _string(row['WisaServer']),
        port: _string(row['WisaPort']),
        database: _string(row['WisaDatabase']),
        username: _string(row['WisaUsername']),
        passwordRef: SecretRef(_string(row['WisaPasswordRef'])),
        workDate: WorkDateSetting(
          isNow: _bool(row['WisaWorkDateIsNow']),
          date: _date(row['WisaWorkDate']),
        ),
        virtualWorkDate: WorkDateSetting(
          isNow: _bool(row['WisaVirtualWorkDateIsNow']),
          date: _date(row['WisaVirtualWorkDate']),
        ),
      ),
      smartschool: SmartschoolConnection(
        uri: _string(row['SmartschoolUri']),
        passphraseRef: SecretRef(_string(row['SmartschoolPassphraseRef'])),
        testUser: _string(row['SmartschoolTestUser']),
        studentGroup: _string(row['SmartschoolStudentGroup']),
        staffGroup: _string(row['SmartschoolStaffGroup']),
        useGrades: _bool(row['SmartschoolUseGrades']),
        useYears: _bool(row['SmartschoolUseYears']),
        grades: [
          _string(row['SmartschoolGrade1']),
          _string(row['SmartschoolGrade2']),
          _string(row['SmartschoolGrade3']),
        ],
        years: [
          for (var i = 1; i <= SmartschoolConnection.yearCount; i++)
            _string(row['SmartschoolYear$i']),
        ],
      ),
      azure: AzureConnection(
        clientId: _string(row['AzureClientId']),
        tenantId: _string(row['AzureTenantId']),
        domain: _string(row['AzureDomain']),
      ),
      wisaRules: wisaRules,
      smartschoolRules: smartschoolRules,
    );
  }

  List<Object?> _settingsParams(AppSettings s) => [
        1, // Id — the singleton key
        s.schoolPrefix,
        s.debugMode,
        s.wisa.server,
        s.wisa.port,
        s.wisa.database,
        s.wisa.username,
        s.wisa.passwordRef.name,
        s.wisa.workDate.isNow,
        s.wisa.workDate.date,
        s.wisa.virtualWorkDate.isNow,
        s.wisa.virtualWorkDate.date,
        s.smartschool.uri,
        s.smartschool.passphraseRef.name,
        s.smartschool.testUser,
        s.smartschool.studentGroup,
        s.smartschool.staffGroup,
        s.smartschool.useGrades,
        s.smartschool.useYears,
        s.smartschool.grades[0],
        s.smartschool.grades[1],
        s.smartschool.grades[2],
        s.smartschool.years[0],
        s.smartschool.years[1],
        s.smartschool.years[2],
        s.smartschool.years[3],
        s.smartschool.years[4],
        s.smartschool.years[5],
        s.smartschool.years[6],
        s.azure.clientId,
        s.azure.tenantId,
        s.azure.domain,
      ];
}

/// The settings-row columns, in the order [AzureSqlSettingsStore._settingsParams]
/// binds them. Shared by the INSERT and SELECT so the two can never drift.
const List<String> _settingsColumns = [
  'Id',
  'SchoolPrefix',
  'DebugMode',
  'WisaServer',
  'WisaPort',
  'WisaDatabase',
  'WisaUsername',
  'WisaPasswordRef',
  'WisaWorkDateIsNow',
  'WisaWorkDate',
  'WisaVirtualWorkDateIsNow',
  'WisaVirtualWorkDate',
  'SmartschoolUri',
  'SmartschoolPassphraseRef',
  'SmartschoolTestUser',
  'SmartschoolStudentGroup',
  'SmartschoolStaffGroup',
  'SmartschoolUseGrades',
  'SmartschoolUseYears',
  'SmartschoolGrade1',
  'SmartschoolGrade2',
  'SmartschoolGrade3',
  'SmartschoolYear1',
  'SmartschoolYear2',
  'SmartschoolYear3',
  'SmartschoolYear4',
  'SmartschoolYear5',
  'SmartschoolYear6',
  'SmartschoolYear7',
  'AzureClientId',
  'AzureTenantId',
  'AzureDomain',
];

final String _insertSettingsSql = 'INSERT INTO $settingsTableName '
    '(${_settingsColumns.join(', ')}) '
    'VALUES (${List.filled(_settingsColumns.length, '?').join(', ')})';

final String _selectSettingsSql =
    'SELECT ${_settingsColumns.join(', ')} FROM $settingsTableName WHERE Id = 1';

const String _selectRulesSql =
    'SELECT SystemKey, Ordinal, Payload FROM dbo.ImportRules '
    'ORDER BY SystemKey, Ordinal';

const String _insertRuleSql =
    'INSERT INTO dbo.ImportRules (SystemKey, Ordinal, Payload) '
    'VALUES (?, ?, ?)';

/// Reads a driver value as a non-null string, treating SQL `NULL` as empty so a
/// blank column and an absent one look the same to the model (matching the
/// file store, where a missing key falls back to `''`).
String _string(Object? value) => (value as String?) ?? '';

/// Reads a `BIT` column as a bool. Drivers may surface it as a real `bool` or as
/// `0`/`1`; both are accepted so the adapter is not coupled to one driver's
/// marshalling.
bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  throw FormatException('expected a BIT value, got: $value');
}

/// Reads a nullable `DATETIME2` column. Accepts a native `DateTime` or an
/// ISO-8601 string (again, to stay driver-agnostic); `NULL` stays `null` so a
/// pinned-but-unset work date round-trips faithfully.
DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : DateTime.parse(trimmed);
  }
  throw FormatException('expected a DATETIME2 value, got: $value');
}
