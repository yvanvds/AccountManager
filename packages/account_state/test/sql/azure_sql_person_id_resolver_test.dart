import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A semantic in-memory fake of the identity-map table shared by every resolver
/// opened against it — the way one Azure SQL database is shared by every
/// operator. It models `INSERT ... WHERE NOT EXISTS` (guarded insert) so the
/// unique-key arbitration the resolver relies on is exercised for real, and can
/// optionally hide its rows from the full-map load to simulate the window where
/// one operator has committed a row the other hasn't seen yet.
class _FakePersonIdDb implements SqlConnection {
  _FakePersonIdDb({this.hideOnLoad = false});

  /// The persisted map — the singular source of truth all connections share.
  final Map<String, String> table = {};

  /// When true, the full-map load reports an empty table even though [table]
  /// may hold rows: the "stale load" a concurrent minter races against.
  final bool hideOnLoad;

  final List<String> statements = [];
  final List<List<Object?>> params = [];
  int opens = 0;
  int closes = 0;
  int transactions = 0;

  @override
  Future<List<SqlRow>> query(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    // Full-map load: SELECT NaturalKey, PersonId FROM ...
    if (sql.contains('SELECT NaturalKey, PersonId')) {
      if (hideOnLoad) return [];
      return [
        for (final e in table.entries)
          {'NaturalKey': e.key, 'PersonId': e.value},
      ];
    }
    // Read-back of one row: SELECT PersonId FROM ... WHERE NaturalKey = ?
    if (sql.contains('SELECT PersonId FROM')) {
      final key = p.single as String;
      final id = table[key];
      return id == null
          ? []
          : [
              {'PersonId': id},
            ];
    }
    throw StateError('unexpected query: $sql');
  }

  @override
  Future<int> execute(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    // Guarded insert: params are [naturalKey, personId, naturalKey].
    if (sql.contains('INSERT INTO') && sql.contains('WHERE NOT EXISTS')) {
      final key = p[0] as String;
      final id = p[1] as String;
      if (table.containsKey(key)) return 0; // key present ⇒ insert nothing
      table[key] = id;
      return 1;
    }
    throw StateError('unexpected execute: $sql');
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) async {
    transactions++;
    final snapshot = Map<String, String>.of(table);
    try {
      return await action(this);
    } catch (_) {
      table
        ..clear()
        ..addAll(snapshot);
      rethrow;
    }
  }

  @override
  Future<void> close() async => closes++;
}

/// Opens the shared [_FakePersonIdDb], recording each open so a test can assert
/// a fresh token is read per connection (the DB is AAD-only).
class _FakeFactory implements SqlConnectionFactory {
  _FakeFactory(this._db);
  final _FakePersonIdDb _db;

  AzureSqlConfig? lastConfig;
  final List<String> tokensRead = [];

  @override
  Future<SqlConnection> open(
      AzureSqlConfig config, AadTokenProvider tokens) async {
    _db.opens++;
    lastConfig = config;
    tokensRead.add(await tokens.databaseAccessToken());
    return _db;
  }
}

/// A counter-based mint so a test can predict the ids and prove which operator
/// won a race. [prefix] distinguishes two competing resolvers.
String Function() _mint(String prefix) {
  var n = 0;
  return () => '$prefix-${n++}';
}

void main() {
  const config = AzureSqlConfig(
    server: 'accountmanager-sql-arcadia.database.windows.net',
    database: 'accountmanager',
  );

  AzureSqlPersonIdResolver resolverOver(
    _FakePersonIdDb db, {
    String mintPrefix = 'id',
    String token = 'bearer-xyz',
  }) =>
      AzureSqlPersonIdResolver(
        factory: _FakeFactory(db),
        config: config,
        tokens: StaticAadTokenProvider(token),
        mintId: _mint(mintPrefix),
      );

  group('AzureSqlPersonIdResolver (PersonIdResolver contract)', () {
    test('resolve before prepare is a StateError, not a silent miss', () {
      final resolver = resolverOver(_FakePersonIdDb());
      expect(() => resolver.resolve('wisa:1'), throwsStateError);
    });

    test('prepare mints a stable id for each new key; resolve returns it',
        () async {
      final resolver = resolverOver(_FakePersonIdDb());
      await resolver.prepare(['wisa:1', 'wisa:2']);

      final a = resolver.resolve('wisa:1');
      final b = resolver.resolve('wisa:2');
      expect(a.value, isNotEmpty);
      expect(a, isNot(equals(b)));
      // Stable within the session.
      expect(resolver.resolve('wisa:1'), equals(a));
    });

    test('prepare reuses an id already persisted by an earlier run', () async {
      final db = _FakePersonIdDb()..table['wisa:1'] = 'persisted-uuid';
      final resolver = resolverOver(db, mintPrefix: 'fresh');

      await resolver.prepare(['wisa:1']);
      expect(resolver.resolve('wisa:1'), const PersonId('persisted-uuid'));
    });

    test('prepare is idempotent: a re-prepare of cached keys opens nothing',
        () async {
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);

      await resolver.prepare(['wisa:1']);
      final opensAfterFirst = db.opens;
      await resolver.prepare(['wisa:1']); // all cached ⇒ no work
      expect(db.opens, opensAfterFirst);
    });

    test('mints only the keys not already loaded from the map', () async {
      final db = _FakePersonIdDb()..table['wisa:1'] = 'existing';
      final resolver = resolverOver(db, mintPrefix: 'minted');

      await resolver.prepare(['wisa:1', 'wisa:2']);
      expect(resolver.resolve('wisa:1'), const PersonId('existing'));
      expect(resolver.resolve('wisa:2'), const PersonId('minted-0'));
    });
  });

  group('convergence under concurrency (#85)', () {
    test('a second operator fetches the first operator\'s committed id',
        () async {
      final db = _FakePersonIdDb(); // shared central table
      final a = resolverOver(db, mintPrefix: 'A');
      final b = resolverOver(db, mintPrefix: 'B');

      await a.prepare(['wisa:1']); // A mints A-0 and commits
      await b.prepare(['wisa:1']); // B loads the map, sees A-0, adopts it

      expect(a.resolve('wisa:1'), const PersonId('A-0'));
      expect(b.resolve('wisa:1'), equals(a.resolve('wisa:1')));
    });

    test('a stale-load minter loses the unique-key race and adopts the winner',
        () async {
      // Both operators load an empty map (B's load misses A's freshly committed
      // row — the real concurrency window). The guarded insert arbitrates: B's
      // INSERT finds the key present and writes nothing, then reads back A's id.
      final db = _FakePersonIdDb(hideOnLoad: true);
      final a = resolverOver(db, mintPrefix: 'A');
      final b = resolverOver(db, mintPrefix: 'B');

      await a.prepare(['wisa:1']); // loads empty, inserts A-0
      await b.prepare(['wisa:1']); // loads empty, insert no-ops, reads back A-0

      expect(db.table['wisa:1'], 'A-0', reason: 'only the first mint persists');
      expect(a.resolve('wisa:1'), const PersonId('A-0'));
      expect(b.resolve('wisa:1'), const PersonId('A-0'),
          reason: 'the loser adopts the winner rather than its own B-0');
    });
  });

  group('connection + statement discipline', () {
    test('prepare opens with the config, reads a fresh token, and closes',
        () async {
      final db = _FakePersonIdDb();
      final factory = _FakeFactory(db);
      final resolver = AzureSqlPersonIdResolver(
        factory: factory,
        config: config,
        tokens: const StaticAadTokenProvider('bearer-xyz'),
        mintId: _mint('id'),
      );

      await resolver.prepare(['wisa:1']);
      expect(factory.lastConfig, config);
      expect(factory.tokensRead, ['bearer-xyz']);
      expect(db.closes, 1);
    });

    test('mints run inside a single transaction', () async {
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);
      await resolver.prepare(['wisa:1', 'wisa:2']);
      expect(db.transactions, 1);
    });

    test('keys and ids are bound as parameters, never interpolated', () async {
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);
      await resolver.prepare(['wisa:1']);

      final insert = db.statements
          .firstWhere((s) => s.contains('INSERT INTO') && s.contains('?'));
      expect(insert, isNot(contains('wisa:1')));
    });
  });

  group('personIdentitySchemaStatements', () {
    test('provisions the identity map idempotently with the key as PK', () {
      final ddl = personIdentitySchemaStatements.join('\n');
      expect(ddl, contains('CREATE TABLE dbo.PersonIdentity'));
      expect(ddl, contains('IF OBJECT_ID'));
      // The natural key is the primary key — that is the unique constraint the
      // concurrent mint-or-fetch converges on.
      expect(ddl, contains('NaturalKey NVARCHAR(450) NOT NULL PRIMARY KEY'));
    });
  });
}
