import 'dart:convert';
import 'dart:typed_data';

import 'package:account_state/src/sql/odbc/odbc_constants.dart';
import 'package:account_state/src/sql/odbc/odbc_marshalling.dart';
import 'package:test/test.dart';

/// Offline coverage for the driver-free half of the ODBC connection (issue #89).
///
/// The FFI binding itself is Windows-only and only exercised by the opt-in live
/// round-trips, but its *decisions* — the connection string, the access-token
/// packing, and the column-type mapping — are plain functions and are asserted
/// here without a driver.
void main() {
  group('buildOdbcConnectionString', () {
    test('names Driver 18, the tcp server and database, and forces encryption',
        () {
      final connStr = buildOdbcConnectionString(
        server: 'accountmanager-sql-arcadia.database.windows.net',
        database: 'accountmanager',
      );

      expect(connStr, contains('Driver={ODBC Driver 18 for SQL Server}'));
      expect(
        connStr,
        contains(
            'Server=tcp:accountmanager-sql-arcadia.database.windows.net,1433'),
      );
      expect(connStr, contains('Database=accountmanager'));
      expect(connStr, contains('Encrypt=yes'));
    });

    test('carries no credential — safe to log', () {
      final connStr = buildOdbcConnectionString(server: 'srv', database: 'db');
      expect(connStr.toLowerCase(), isNot(contains('pwd')));
      expect(connStr.toLowerCase(), isNot(contains('uid')));
      expect(connStr.toLowerCase(), isNot(contains('password')));
    });
  });

  group('packAccessToken', () {
    test('lays out [uint32 byteLength][UTF-16LE token]', () {
      final packed = packAccessToken('AbC1');
      // 4-byte length prefix + 2 bytes per ASCII char.
      expect(packed, hasLength(4 + 4 * 2));

      final view = ByteData.view(packed.buffer);
      expect(view.getUint32(0, Endian.little), 8);

      // Each ASCII code unit is a low byte followed by 0x00 (UTF-16LE).
      expect(packed.sublist(4), [0x41, 0, 0x62, 0, 0x43, 0, 0x31, 0]);
    });

    test('length prefix counts bytes, not characters', () {
      final token = 'x' * 100;
      final packed = packAccessToken(token);
      final view = ByteData.view(packed.buffer);
      expect(view.getUint32(0, Endian.little), 200);
      expect(packed, hasLength(4 + 200));
    });

    test('handles a realistic base64url JWT shape', () {
      // A JWT is dot-separated base64url — all ASCII, so it round-trips through
      // the low byte of each UTF-16LE unit.
      final jwt =
          '${base64Url.encode(utf8.encode('{"alg":"none"}'))}.payload.sig';
      final packed = packAccessToken(jwt);

      final data = packed.sublist(4);
      final recovered = <int>[];
      for (var i = 0; i < data.length; i += 2) {
        expect(data[i + 1], 0, reason: 'high byte of an ASCII unit is zero');
        recovered.add(data[i]);
      }
      expect(String.fromCharCodes(recovered), jwt);
    });

    test('empty token packs to a bare zero-length prefix', () {
      final packed = packAccessToken('');
      expect(packed, [0, 0, 0, 0]);
    });
  });

  group('categoryForSqlType', () {
    test('BIT reads back as a bool', () {
      expect(categoryForSqlType(sqlBit), OdbcColumnCategory.boolean);
    });

    test('the integer family reads back as int', () {
      for (final type in [sqlTinyint, sqlSmallint, sqlInteger, sqlBigint]) {
        expect(categoryForSqlType(type), OdbcColumnCategory.integer,
            reason: 'SQL type $type should map to integer');
      }
    });

    test('NVARCHAR / DATETIME2 and anything unrecognized read back as text',
        () {
      // -9 = SQL_WVARCHAR, 93 = SQL_TYPE_TIMESTAMP (DATETIME2), plus an
      // arbitrary unmapped code.
      for (final type in [-9, 93, 12, 9999]) {
        expect(categoryForSqlType(type), OdbcColumnCategory.text,
            reason: 'SQL type $type should fall through to text');
      }
    });
  });
}
