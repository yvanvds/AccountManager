import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A scripted [SqlConnection] for headless adapter tests: it records every
/// statement it is handed and replays canned rows, so an adapter can be driven
/// with no database. The real ODBC/FFI connection lands with the first adapter
/// slice (#83); until then this proves the seam's contract composes.
class _RecordingConnection implements SqlConnection {
  _RecordingConnection([this._rows = const []]);

  final List<SqlRow> _rows;
  final List<String> statements = [];
  bool closed = false;

  @override
  Future<List<SqlRow>> query(String sql,
      [List<Object?> params = const []]) async {
    statements.add(sql);
    return _rows;
  }

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    statements.add(sql);
    return 1;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) =>
      action(this);

  @override
  Future<void> close() async => closed = true;
}

class _FakeFactory implements SqlConnectionFactory {
  _FakeFactory(this._connection);
  final _RecordingConnection _connection;

  AzureSqlConfig? openedWith;
  String? tokenUsed;

  @override
  Future<SqlConnection> open(
    AzureSqlConfig config,
    AadTokenProvider tokens,
  ) async {
    openedWith = config;
    tokenUsed = await tokens.databaseAccessToken();
    return _connection;
  }
}

void main() {
  group('AzureSqlConfig', () {
    const config = AzureSqlConfig(
      server: 'accountmanager-sql-arcadia.database.windows.net',
      database: 'accountmanager',
    );

    test('round-trips through JSON', () {
      final restored = AzureSqlConfig.fromJson(config.toJson());
      expect(restored, equals(config));
    });

    test('value equality distinguishes server and database', () {
      expect(
        config,
        isNot(equals(const AzureSqlConfig(
          server: 'other.database.windows.net',
          database: 'accountmanager',
        ))),
      );
      expect(
        config,
        isNot(equals(const AzureSqlConfig(
          server: 'accountmanager-sql-arcadia.database.windows.net',
          database: 'other',
        ))),
      );
    });

    test('toString names the target without a credential', () {
      expect(config.toString(), contains('accountmanager'));
    });
  });

  group('StaticAadTokenProvider', () {
    test('returns the injected token verbatim', () async {
      const provider = StaticAadTokenProvider('bearer-xyz');
      expect(await provider.databaseAccessToken(), 'bearer-xyz');
    });
  });

  group('SqlConnection seam', () {
    test('factory opens with the config and a freshly read token', () async {
      final connection = _RecordingConnection();
      final factory = _FakeFactory(connection);
      const config = AzureSqlConfig(server: 'srv', database: 'db');

      final opened = await factory.open(
        config,
        const StaticAadTokenProvider('tok-1'),
      );

      expect(identical(opened, connection), isTrue);
      expect(factory.openedWith, equals(config));
      expect(factory.tokenUsed, 'tok-1');
    });

    test('query and execute forward their statements', () async {
      final connection = _RecordingConnection([
        {'note': 'roundtrip-ok'},
      ]);

      final rows = await connection.query('SELECT note FROM probe');
      final affected =
          await connection.execute('INSERT INTO probe VALUES (?)', ['x']);

      expect(rows.single['note'], 'roundtrip-ok');
      expect(affected, 1);
      expect(connection.statements, [
        'SELECT note FROM probe',
        'INSERT INTO probe VALUES (?)',
      ]);
    });

    test('transaction passes a connection scoped to it', () async {
      final connection = _RecordingConnection();

      final result = await connection.transaction((tx) async {
        await tx.execute('INSERT INTO ids VALUES (?)', ['wisa:123']);
        return 'committed';
      });

      expect(result, 'committed');
      expect(connection.statements, ['INSERT INTO ids VALUES (?)']);
    });

    test('close is idempotent-safe and marks the connection closed', () async {
      final connection = _RecordingConnection();
      await connection.close();
      await connection.close();
      expect(connection.closed, isTrue);
    });
  });
}
