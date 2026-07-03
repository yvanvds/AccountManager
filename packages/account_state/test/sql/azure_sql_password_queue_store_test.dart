import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A semantic in-memory fake of the [SqlConnection] seam: it models the single
/// queue table as an ordered list of rows, so the adapter can be driven through
/// a real save/load round-trip with no database. It actually stores what `save`
/// writes and returns it to `load` (keeping the mapping honest), assigns each
/// insert a growing `Id` so insertion order survives the `ORDER BY Id` read, and
/// stays independent of column order by zipping each INSERT's explicit column
/// list with its positional parameters.
class _FakeQueueDb implements SqlConnection {
  final List<Map<String, Object?>> _rows = [];
  int _nextId = 1;

  final List<String> statements = [];
  final List<List<Object?>> params = [];
  int transactions = 0;
  int closes = 0;

  @override
  Future<List<SqlRow>> query(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    if (sql.contains('FROM $passwordQueueTableName')) {
      final rows = [for (final r in _rows) Map<String, Object?>.of(r)];
      rows.sort((a, b) => (a['Id'] as int).compareTo(b['Id'] as int));
      return rows;
    }
    throw StateError('unexpected query: $sql');
  }

  @override
  Future<int> execute(String sql, [List<Object?> p = const []]) async {
    statements.add(sql);
    params.add(p);
    if (sql.contains('DELETE FROM $passwordQueueTableName')) {
      final n = _rows.length;
      _rows.clear();
      return n;
    }
    if (sql.contains('INSERT INTO $passwordQueueTableName')) {
      _rows.add(_zip(sql, p)..['Id'] = _nextId++);
      return 1;
    }
    throw StateError('unexpected execute: $sql');
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) async {
    transactions++;
    // Faithful rollback: snapshot and restore if the action throws, so a failed
    // save can never leave a half-written queue to be read back.
    final snapshot = [for (final r in _rows) Map<String, Object?>.of(r)];
    final idSnapshot = _nextId;
    try {
      return await action(this);
    } catch (_) {
      _rows
        ..clear()
        ..addAll(snapshot);
      _nextId = idSnapshot;
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
  final _FakeQueueDb _db;

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

PasswordEntry _accountEntry() => const PasswordEntry(
      personId: PersonId('p-1'),
      kind: PasswordAccountKind.account,
      accountName: 'jan.jansen',
      displayName: 'Jan Jansen',
      mail: 'jan.jansen@example.org',
      classGroup: '1A',
      smartschoolPassword: 'Sa2b!x',
      azurePassword: 'Ku9d?y',
    );

PasswordEntry _coAccountEntry() => const PasswordEntry(
      personId: PersonId('p-2'),
      kind: PasswordAccountKind.coAccount,
      accountName: 'els.peeters',
      displayName: 'Els Peeters',
    );

void expectSameEntry(PasswordEntry a, PasswordEntry b) =>
    expect(a.toJson(), equals(b.toJson()));

void main() {
  const config = AzureSqlConfig(
    server: 'accountmanager-sql-arcadia.database.windows.net',
    database: 'accountmanager',
  );

  ({AzureSqlPasswordQueueStore store, _FakeQueueDb db, _FakeFactory factory})
      storeOver({_FakeQueueDb? over, String token = 'bearer-xyz'}) {
    final db = over ?? _FakeQueueDb();
    final factory = _FakeFactory(db);
    return (
      store: AzureSqlPasswordQueueStore(
        factory: factory,
        config: config,
        tokens: StaticAadTokenProvider(token),
      ),
      db: db,
      factory: factory,
    );
  }

  group('AzureSqlPasswordQueueStore (PasswordQueueStore contract)', () {
    test('load returns an empty queue when nothing is saved', () async {
      expect(await storeOver().store.load(), isEmpty);
    });

    test('save then load round-trips both kinds through the shared table',
        () async {
      // One db shared across save and load, the way one central table is shared
      // by the generating and printing operators.
      final db = _FakeQueueDb();
      await storeOver(over: db)
          .store
          .save([_accountEntry(), _coAccountEntry()]);
      final loaded = await storeOver(over: db).store.load();

      expect(loaded, hasLength(2));
      expectSameEntry(loaded[0], _accountEntry());
      expectSameEntry(loaded[1], _coAccountEntry());
    });

    test('a co-account entry round-trips its null optionals as NULL', () async {
      final db = _FakeQueueDb();
      await storeOver(over: db).store.save([_coAccountEntry()]);
      final loaded = (await storeOver(over: db).store.load()).single;

      expect(loaded.kind, PasswordAccountKind.coAccount);
      expect(loaded.mail, isNull);
      expect(loaded.classGroup, isNull);
      expect(loaded.smartschoolPassword, isNull);
      expect(loaded.azurePassword, isNull);
    });

    test('save replaces the whole queue', () async {
      final db = _FakeQueueDb();
      await storeOver(over: db).store.save([_accountEntry()]);
      await storeOver(over: db).store.save([_coAccountEntry()]);
      final loaded = await storeOver(over: db).store.load();

      expect(loaded, hasLength(1));
      expect(loaded.single.personId, const PersonId('p-2'));
    });

    test('saving an empty list drains the queue (post-distribution)', () async {
      final db = _FakeQueueDb();
      await storeOver(over: db)
          .store
          .save([_accountEntry(), _coAccountEntry()]);
      await storeOver(over: db).store.save([]);
      expect(await storeOver(over: db).store.load(), isEmpty);
    });

    test('load preserves the saved order', () async {
      final db = _FakeQueueDb();
      final ordered = [
        _coAccountEntry(),
        _accountEntry(),
        _coAccountEntry(),
      ];
      await storeOver(over: db).store.save(ordered);
      final loaded = await storeOver(over: db).store.load();

      expect(
        [for (final e in loaded) e.personId.value],
        ['p-2', 'p-1', 'p-2'],
      );
    });
  });

  group('connection + statement discipline', () {
    test('save opens with the config, reads a fresh token, and closes',
        () async {
      final ctx = storeOver();
      await ctx.store.save([_accountEntry()]);
      expect(ctx.factory.lastConfig, config);
      expect(ctx.factory.tokensRead, ['bearer-xyz']);
      expect(ctx.db.closes, 1);
    });

    test('load opens, reads a fresh token, and closes', () async {
      final ctx = storeOver();
      await ctx.store.load();
      expect(ctx.factory.tokensRead, ['bearer-xyz']);
      expect(ctx.db.closes, 1);
    });

    test('save runs the clear-and-insert inside a single transaction',
        () async {
      final ctx = storeOver();
      await ctx.store.save([_accountEntry(), _coAccountEntry()]);
      expect(ctx.db.transactions, 1);
    });

    test('entry fields are bound as parameters, never interpolated', () async {
      final ctx = storeOver();
      await ctx.store.save([_accountEntry()]);
      final insert = ctx.db.statements
          .firstWhere((s) => s.contains('INSERT INTO') && s.contains('?'));
      expect(insert, isNot(contains('jan.jansen')));
      expect(insert, isNot(contains('Sa2b!x')));
    });

    test('a save that throws mid-transaction leaves the prior queue intact',
        () async {
      // Seed a good queue, then fail a later save: the rollback must restore it,
      // so a partially written queue is never read back.
      final db = _FakeQueueDb();
      await storeOver(over: db).store.save([_accountEntry()]);

      final failing = AzureSqlPasswordQueueStore(
        factory: _ThrowingFactory(db),
        config: config,
        tokens: const StaticAadTokenProvider('t'),
      );
      await expectLater(
        failing.save([_coAccountEntry()]),
        throwsA(isA<StateError>()),
      );

      final loaded = await storeOver(over: db).store.load();
      expect(loaded, hasLength(1));
      expectSameEntry(loaded.single, _accountEntry());
    });
  });

  group('passwordQueueSchemaStatements', () {
    test('provisions the queue table idempotently, discriminating both kinds',
        () {
      final ddl = passwordQueueSchemaStatements.join('\n');
      expect(ddl, contains('CREATE TABLE dbo.PasswordQueue'));
      expect(ddl, contains('IF OBJECT_ID'));
      // The Kind column carries both PasswordAccountKinds in one table.
      expect(ddl, contains("Kind IN (N'account', N'coAccount')"));
    });
  });
}

/// A factory that returns a connection whose insert throws, to exercise the
/// transaction rollback path. The DELETE succeeds, then the first INSERT fails,
/// so the fake's snapshot restore is what protects the prior queue.
class _ThrowingFactory implements SqlConnectionFactory {
  _ThrowingFactory(this._db);
  final _FakeQueueDb _db;

  @override
  Future<SqlConnection> open(
          AzureSqlConfig config, AadTokenProvider tokens) async =>
      _ThrowOnInsert(_db);
}

/// Wraps the real fake but throws on INSERT, so DELETE has already emptied the
/// table when the failure hits — proving the rollback restores it.
class _ThrowOnInsert implements SqlConnection {
  _ThrowOnInsert(this._inner);
  final _FakeQueueDb _inner;

  @override
  Future<List<SqlRow>> query(String sql, [List<Object?> p = const []]) =>
      _inner.query(sql, p);

  @override
  Future<int> execute(String sql, [List<Object?> p = const []]) {
    if (sql.contains('INSERT INTO')) {
      throw StateError('insert boom');
    }
    return _inner.execute(sql, p);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) =>
      _inner.transaction((_) => action(this));

  @override
  Future<void> close() => _inner.close();
}
