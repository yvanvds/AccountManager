import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A semantic in-memory fake of the [SqlConnection] seam: it models the two
/// settings tables as a singleton row plus a rule list, so the adapter can be
/// driven through a real save/load round-trip with no database. Unlike the
/// scripted `_RecordingConnection` in `sql_seam_test.dart`, this one actually
/// stores what `save` writes and returns it to `load`, keeping the mapping code
/// honest. It stays independent of column order by zipping each INSERT's
/// explicit column list with its positional parameters.
class _FakeSqlDatabase implements SqlConnection {
  Map<String, Object?>? _settingsRow;
  final List<Map<String, Object?>> _rules = [];

  final List<String> statements = [];
  final List<List<Object?>> params = [];
  int transactions = 0;
  int closes = 0;

  @override
  Future<List<SqlRow>> query(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    if (sql.contains('FROM $settingsTableName')) {
      return _settingsRow == null ? [] : [Map.of(_settingsRow!)];
    }
    if (sql.contains('FROM $importRulesTableName')) {
      final rows = [for (final r in _rules) Map<String, Object?>.of(r)];
      rows.sort((a, b) {
        final bySystem =
            (a['SystemKey'] as String).compareTo(b['SystemKey'] as String);
        return bySystem != 0
            ? bySystem
            : (a['Ordinal'] as int).compareTo(b['Ordinal'] as int);
      });
      return rows;
    }
    throw StateError('unexpected query: $sql');
  }

  @override
  Future<int> execute(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    if (sql.contains('DELETE FROM $settingsTableName')) {
      final had = _settingsRow != null;
      _settingsRow = null;
      return had ? 1 : 0;
    }
    if (sql.contains('DELETE FROM $importRulesTableName')) {
      final n = _rules.length;
      _rules.clear();
      return n;
    }
    if (sql.contains('INSERT INTO $settingsTableName')) {
      _settingsRow = _zip(sql, p);
      return 1;
    }
    if (sql.contains('INSERT INTO $importRulesTableName')) {
      _rules.add(_zip(sql, p));
      return 1;
    }
    throw StateError('unexpected execute: $sql');
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) async {
    transactions++;
    // Faithful rollback: snapshot and restore if the action throws, so a failed
    // save can never leave a half-written config to be read back.
    final settingsSnapshot =
        _settingsRow == null ? null : Map.of(_settingsRow!);
    final rulesSnapshot = [for (final r in _rules) Map<String, Object?>.of(r)];
    try {
      return await action(this);
    } catch (_) {
      _settingsRow = settingsSnapshot;
      _rules
        ..clear()
        ..addAll(rulesSnapshot);
      rethrow;
    }
  }

  @override
  Future<void> close() async => closes++;

  /// Builds a column→value row by zipping an INSERT's explicit column list with
  /// its positional parameters, so the fake never hard-codes column order.
  Map<String, Object?> _zip(String insertSql, List<Object?> p) {
    final match = RegExp(r'\(([^)]*)\)\s*VALUES', caseSensitive: false)
        .firstMatch(insertSql);
    if (match == null) {
      throw StateError('cannot parse columns from: $insertSql');
    }
    final columns = match.group(1)!.split(',').map((c) => c.trim()).toList();
    if (columns.length != p.length) {
      throw StateError(
          'column/param mismatch: ${columns.length} cols, ${p.length} params');
    }
    return {for (var i = 0; i < columns.length; i++) columns[i]: p[i]};
  }
}

/// Records how it was opened so tests can assert a fresh token is read per open
/// and the injected config is passed through.
class _FakeFactory implements SqlConnectionFactory {
  _FakeFactory(this._db);
  final _FakeSqlDatabase _db;

  int opens = 0;
  AzureSqlConfig? lastConfig;
  final List<String> tokensRead = [];

  @override
  Future<SqlConnection> open(
      AzureSqlConfig config, AadTokenProvider tokens) async {
    opens++;
    lastConfig = config;
    tokensRead.add(await tokens.databaseAccessToken());
    return _db;
  }
}

/// A representative config exercising the flags, all three profiles (including
/// the work-date pair and the grade/year vocabulary), and every rule variant.
AppSettings _sample() => AppSettings(
      schoolPrefix: 'SMA',
      debugMode: true,
      wisa: WisaConnection(
        server: 'db.example',
        port: '1521',
        database: 'WISA',
        username: 'svc',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 6, 30)),
        virtualWorkDate:
            WorkDateSetting(isNow: false, date: DateTime(2027, 9, 1)),
      ),
      smartschool: SmartschoolConnection(
        uri: 'https://school.smartschool.be',
        testUser: 'test.user',
        studentGroup: 'Leerlingen',
        staffGroup: 'Personeel',
        useGrades: true,
        useYears: true,
        grades: const ['graad 1', 'graad 2', 'graad 3'],
        years: const ['1', '2', '3', '4', '5', '6', '7'],
      ),
      azure: const AzureConnection(
        clientId: 'client-123',
        tenantId: 'tenant-456',
        domain: 'sma.onmicrosoft.com',
      ),
      wisaRules: const [
        DontImportClass('1A'),
        DontImportUserFromWisa('U42'),
        ReplaceInstitute(original: '001', replacement: '002'),
        MarkAsVirtual('VIRT'),
      ],
      smartschoolRules: const [
        DiscardSmartschoolGroup('Archief'),
        NoSmartschoolSubgroups('Klassen'),
      ],
    );

void _expectSame(AppSettings a, AppSettings b) {
  expect(a.schoolPrefix, b.schoolPrefix);
  expect(a.debugMode, b.debugMode);
  expect(a.wisa, b.wisa);
  expect(a.smartschool, b.smartschool);
  expect(a.azure, b.azure);
  expect(a.wisaRules.map(encodeWisaRule), b.wisaRules.map(encodeWisaRule));
  expect(a.smartschoolRules.map(encodeSmartschoolRule),
      b.smartschoolRules.map(encodeSmartschoolRule));
}

void main() {
  late _FakeSqlDatabase db;
  late _FakeFactory factory;
  late AzureSqlSettingsStore store;

  const config = AzureSqlConfig(
    server: 'accountmanager-sql-arcadia.database.windows.net',
    database: 'accountmanager',
  );

  setUp(() {
    db = _FakeSqlDatabase();
    factory = _FakeFactory(db);
    store = AzureSqlSettingsStore(
      factory: factory,
      config: config,
      tokens: const StaticAadTokenProvider('bearer-xyz'),
    );
  });

  group('AzureSqlSettingsStore (SettingsStore contract)', () {
    test('load returns defaults when nothing has been saved', () async {
      final settings = await store.load();
      expect(settings.schoolPrefix, isEmpty);
      expect(settings.debugMode, isFalse);
      expect(settings.wisa, const WisaConnection());
      expect(settings.smartschool, SmartschoolConnection());
      expect(settings.azure, const AzureConnection());
      expect(settings.wisaRules, isEmpty);
      expect(settings.smartschoolRules, isEmpty);
    });

    test('save then load round-trips every field and rule variant', () async {
      await store.save(_sample());
      _expectSame(await store.load(), _sample());
    });

    test('save replaces the previously stored value (singleton row)', () async {
      await store.save(const AppSettings(schoolPrefix: 'first'));
      await store.save(const AppSettings(schoolPrefix: 'second'));
      expect((await store.load()).schoolPrefix, 'second');
      // The singleton is genuinely replaced, not appended to.
      expect(db.transactions, 2);
    });

    test('a live-now / unpinned work date round-trips as a NULL date',
        () async {
      // The default WISA profile tracks "now" with no pinned date; the DATETIME2
      // column must round-trip that null rather than materialize a date.
      await store.save(const AppSettings());
      final loaded = await store.load();
      expect(loaded.wisa.workDate.isNow, isTrue);
      expect(loaded.wisa.workDate.date, isNull);
      expect(loaded.wisa.virtualWorkDate.date, isNull);
    });
  });

  group('import rules', () {
    test('persist as their ImportRuleCodec tagged JSON, in order', () async {
      await store.save(_sample());
      final wisaPayloads = [
        for (final r in db._rules)
          if (r['SystemKey'] == 'wisa')
            (r['Ordinal'] as int, r['Payload'] as String)
      ]..sort((a, b) => a.$1.compareTo(b.$1));

      expect(
        wisaPayloads.map((e) => e.$2),
        _sample().wisaRules.map((r) => jsonEncode(encodeWisaRule(r))),
      );
    });

    test('a corrupt SystemKey surfaces as a FormatException on load', () async {
      await store.save(const AppSettings(schoolPrefix: 'x'));
      db._rules.add({'SystemKey': 'bogus', 'Ordinal': 0, 'Payload': '{}'});
      expect(store.load(), throwsA(isA<FormatException>()));
    });
  });

  group('connection handling', () {
    test('save opens with the config, reads a fresh token, and closes',
        () async {
      await store.save(_sample());
      expect(factory.opens, 1);
      expect(factory.lastConfig, config);
      expect(factory.tokensRead, ['bearer-xyz']);
      expect(db.closes, 1);
    });

    test('load opens and closes its own connection', () async {
      await store.load();
      expect(factory.opens, 1);
      expect(db.closes, 1);
    });

    test('save runs its writes inside a single transaction', () async {
      await store.save(_sample());
      expect(db.transactions, 1);
    });

    test('values are bound as parameters, never interpolated into the SQL',
        () async {
      await store.save(_sample());
      final insert = db.statements
          .firstWhere((s) => s.contains('INSERT INTO $settingsTableName'));
      // The secret-free but still-sensitive-shaped values live in params, not
      // in the statement text — so a value can never be read as SQL.
      expect(insert, contains('?'));
      expect(insert, isNot(contains('SMA')));
      expect(insert, isNot(contains('sma.onmicrosoft.com')));
    });
  });

  group('settingsSchemaStatements', () {
    test('provisions both tables idempotently', () {
      final ddl = settingsSchemaStatements.join('\n');
      expect(ddl, contains('CREATE TABLE dbo.AppSettings'));
      expect(ddl, contains('CREATE TABLE dbo.ImportRules'));
      // Idempotent guards so a re-deploy is a no-op.
      expect(
        RegExp(r'IF OBJECT_ID').allMatches(ddl).length,
        greaterThanOrEqualTo(2),
      );
      // The singleton is enforced at the schema level.
      expect(ddl, contains('CHECK (Id = 1)'));
    });
  });
}
