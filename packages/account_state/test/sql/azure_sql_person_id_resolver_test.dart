import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A semantic in-memory fake of the identity-map table shared by every resolver
/// opened against it — the way one Azure SQL database is shared by every
/// operator. It models `INSERT ... WHERE NOT EXISTS` (guarded insert) so the
/// unique-key arbitration the resolver relies on is exercised for real, and can
/// optionally hide its rows from the keyed lookup to simulate the window where
/// one operator has committed a row the other hasn't seen yet.
class _FakePersonIdDb implements SqlConnection {
  _FakePersonIdDb({this.hideOnLoad = false});

  /// The persisted map — the singular source of truth all connections share.
  final Map<String, String> table = {};

  /// When true, the keyed lookup **outside a transaction** reports no rows even
  /// though [table] may hold them: the "stale load" a concurrent minter races
  /// against. The read-back inside the mint transaction always sees committed
  /// rows — that is exactly the visibility the guarded insert relies on.
  final bool hideOnLoad;

  /// The parameter list of each warm-cache `WHERE NaturalKey IN (...)` lookup
  /// (outside the mint transaction), in order — so a test can assert the warm
  /// cache only fetches uncached keys and that a large key set is chunked under
  /// the parameter limit.
  final List<List<Object?>> lookups = [];

  final List<String> statements = [];
  final List<List<Object?>> params = [];
  int opens = 0;
  int closes = 0;
  int transactions = 0;
  bool _inTransaction = false;

  @override
  Future<List<SqlRow>> query(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    // Keyed lookup: SELECT NaturalKey, PersonId FROM ... WHERE NaturalKey IN (?, ...)
    if (sql.contains('SELECT NaturalKey, PersonId')) {
      if (!_inTransaction) {
        lookups.add(p);
        if (hideOnLoad) return [];
      }
      final keys = p.cast<String>();
      return [
        for (final key in keys)
          if (table.containsKey(key))
            {'NaturalKey': key, 'PersonId': table[key]!},
      ];
    }
    throw StateError('unexpected query: $sql');
  }

  @override
  Future<int> execute(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    // Multi-row guarded insert: params are [key1, id1, key2, id2, …]; a row
    // is written only when its key is still absent.
    if (sql.contains('INSERT INTO') && sql.contains('WHERE NOT EXISTS')) {
      var inserted = 0;
      for (var i = 0; i < p.length; i += 2) {
        final key = p[i] as String;
        final id = p[i + 1] as String;
        if (table.containsKey(key)) continue; // key present ⇒ insert nothing
        table[key] = id;
        inserted++;
      }
      return inserted;
    }
    throw StateError('unexpected execute: $sql');
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) async {
    transactions++;
    _inTransaction = true;
    final snapshot = Map<String, String>.of(table);
    try {
      return await action(this);
    } catch (_) {
      table
        ..clear()
        ..addAll(snapshot);
      rethrow;
    } finally {
      _inTransaction = false;
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

  group('warm cache across prepare() calls (#93)', () {
    test('a re-prepare fetches only the keys not already cached', () async {
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);

      await resolver.prepare(['wisa:1']);
      // A second pass over a superset must fetch only the new key — the warm
      // cache already holds wisa:1, so it is never looked up again.
      await resolver.prepare(['wisa:1', 'wisa:2']);

      expect(db.lookups, [
        ['wisa:1'],
        ['wisa:2'],
      ]);
    });

    test('never reloads the whole table: an uncached key is not fetched',
        () async {
      // Another operator minted wisa:other; we never ask for it, so the narrow
      // lookup must not pull it into our cache (the old SELECT * would have).
      final db = _FakePersonIdDb()..table['wisa:other'] = 'someone-else';
      final resolver = resolverOver(db);

      await resolver.prepare(['wisa:1']);

      expect(db.lookups, [
        ['wisa:1'],
      ]);
      expect(() => resolver.resolve('wisa:other'), throwsStateError);
    });

    test('a large key set is chunked under the parameter limit', () async {
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);
      const limit = AzureSqlPersonIdResolver.maxKeysPerLookup;
      final keys = [for (var i = 0; i < limit + 500; i++) 'wisa:$i'];

      await resolver.prepare(keys);

      // Split into bounded lookups, none exceeding the limit, covering every key.
      expect(db.lookups.length, 2);
      expect(db.lookups.every((p) => p.length <= limit), isTrue);
      expect(db.lookups.expand((p) => p).toSet(), keys.toSet());
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

    test('minting is set-based: a few statements, never two per key (#99)',
        () async {
      // A first run over a real school mints ~1500 fresh keys; the per-key
      // loop cost two network round-trips each and froze the UI. The batch
      // shape is the fix, so pin it: 2500 fresh keys must produce two
      // warm-cache lookups (2000-key limit), then per 1000-row insert chunk
      // one INSERT and one read-back — 8 statements, not 5000.
      final db = _FakePersonIdDb();
      final resolver = resolverOver(db);
      const rows = AzureSqlPersonIdResolver.maxRowsPerInsert;
      final keys = [for (var i = 0; i < rows * 2 + 500; i++) 'wisa:$i'];

      await resolver.prepare(keys);

      final inserts =
          db.statements.where((s) => s.contains('INSERT INTO')).length;
      expect(inserts, 3, reason: '2500 keys in 1000-row insert chunks');
      expect(db.statements, hasLength(2 + 3 + 3),
          reason: 'lookups + inserts + read-backs, all batched');
      // Every key resolved, all ids persisted.
      expect(db.table, hasLength(keys.length));
      expect(resolver.resolve('wisa:0').value, isNotEmpty);
      expect(resolver.resolve('wisa:${keys.length - 1}').value, isNotEmpty);
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
