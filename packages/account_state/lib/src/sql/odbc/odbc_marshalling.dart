/// Pure, driver-free marshalling helpers for the ODBC/FFI [SqlConnection]
/// (issue #89).
///
/// The FFI binding in `odbc_sql_connection.dart` is Windows-only and can only
/// be exercised against a live `msodbcsql18` + Azure SQL database, so the
/// decisions that don't *need* the driver — how the connection string is built,
/// how the AAD token is packed into the `SQL_COPT_SS_ACCESS_TOKEN` struct, and
/// which Dart shape a given SQL column type maps to — live here as plain
/// functions with offline unit tests. The FFI layer is then a thin caller.
library;

import 'dart:typed_data';

import 'odbc_constants.dart';

/// The default ODBC driver name. The Microsoft **ODBC Driver 18 for SQL
/// Server** redistributable (`msodbcsql18`) is bundled with the Windows
/// installer, per the connectivity decision in `docs/port-plan.md`.
const String defaultOdbcDriver = 'ODBC Driver 18 for SQL Server';

/// Builds the ODBC connection string for [server]/[database].
///
/// It carries **no credential**: the database is AAD-only, so authentication is
/// the AAD bearer token set separately through `SQL_COPT_SS_ACCESS_TOKEN`
/// ([packAccessToken]). `Encrypt=yes` is mandatory for Azure SQL and, with
/// Driver 18's default of not trusting arbitrary certificates, the server
/// certificate is validated against the public CA chain. Only the target and
/// transport appear here, so the string is safe to log.
String buildOdbcConnectionString({
  required String server,
  required String database,
  String driver = defaultOdbcDriver,
}) =>
    'Driver={$driver};'
    'Server=tcp:$server,1433;'
    'Database=$database;'
    'Encrypt=yes;';

/// Packs [accessToken] into the byte layout the `SQL_COPT_SS_ACCESS_TOKEN`
/// connection attribute expects.
///
/// The driver reads an `ACCESSTOKEN { DWORD dataSize; BYTE data[]; }` struct: a
/// little-endian `uint32` byte count followed by the token encoded as
/// **UTF-16LE**. AAD access tokens are base64url JWTs (ASCII), so each character
/// becomes a byte followed by `0x00`. Returned as a [Uint8List] the FFI layer
/// copies verbatim into native memory before `SQLSetConnectAttr`.
Uint8List packAccessToken(String accessToken) {
  final units = accessToken.codeUnits;
  final out = Uint8List(4 + units.length * 2);
  final view = ByteData.view(out.buffer);
  view.setUint32(0, units.length * 2, Endian.little);
  for (var i = 0; i < units.length; i++) {
    view.setUint16(4 + i * 2, units[i], Endian.little);
  }
  return out;
}

/// How a result column is retrieved from the driver and surfaced as a Dart
/// value in a [SqlRow].
enum OdbcColumnCategory {
  /// `SQL_C_SBIGINT` → Dart `int`. For `INT`/`BIGINT`/`SMALLINT`/`TINYINT`.
  integer,

  /// `SQL_C_BIT` → Dart `bool`. For `BIT`.
  boolean,

  /// `SQL_C_WCHAR` → Dart `String` (or `null`). For everything else —
  /// `NVARCHAR`, `NVARCHAR(MAX)`, and `DATETIME2` (read back as its ISO-8601
  /// string, which the adapters' `_date` parses). Keeping dates as text avoids
  /// binding the `SQL_TIMESTAMP_STRUCT` and matches what the adapters already
  /// tolerate.
  text,
}

/// Maps an ODBC SQL type code (as reported by `SQLDescribeCol`) to the retrieval
/// [OdbcColumnCategory]. Only the types the Phase B schema actually uses get a
/// dedicated numeric mapping; everything else — text and dates — is read as a
/// string, which the four adapters accept.
OdbcColumnCategory categoryForSqlType(int sqlType) {
  switch (sqlType) {
    case sqlBit:
      return OdbcColumnCategory.boolean;
    case sqlTinyint:
    case sqlSmallint:
    case sqlInteger:
    case sqlBigint:
      return OdbcColumnCategory.integer;
    default:
      return OdbcColumnCategory.text;
  }
}
