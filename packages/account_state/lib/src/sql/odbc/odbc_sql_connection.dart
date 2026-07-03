/// The concrete, production [SqlConnectionFactory] / [SqlConnection] for the
/// centralized Azure SQL database (issue #89).
///
/// This is the "real consumer" driver the four Phase B adapters plug into: FFI
/// over the Microsoft **ODBC Driver 18 for SQL Server** (`msodbcsql18`),
/// authenticated with the AAD bearer token from [AadTokenProvider] via
/// `SQL_COPT_SS_ACCESS_TOKEN` — no stored database credential — per the
/// connectivity decision in `docs/port-plan.md`.
///
/// It is **Windows-only** and cannot be unit-tested headlessly: it needs the
/// driver, a live AAD-authenticated Azure SQL database, and a fresh token. The
/// driver-free decisions (connection string, token packing, column-type
/// mapping) are factored into `odbc_marshalling.dart` and covered by offline
/// tests; this file is the thin FFI caller and is exercised only by the opt-in
/// live round-trip tests under `test/integration/`.
///
/// ODBC's `SQL*` calls are synchronous and blocking. The Phase B workloads —
/// loading config, priming the identity map, draining the password queue — are
/// small and infrequent, so the work runs inline and each method simply returns
/// a resolved [Future] to satisfy the async seam; no isolate offload is
/// warranted at this volume.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../aad_token_provider.dart';
import '../azure_sql_config.dart';
import '../sql_connection.dart';
import 'odbc_bindings.dart';
import 'odbc_constants.dart';
import 'odbc_marshalling.dart';

/// Opens real [SqlConnection]s to Azure SQL over ODBC Driver 18.
///
/// Production wires this where the adapters are constructed; tests keep using
/// the scripted fake. The native library (`odbc32.dll`) is loaded once, lazily,
/// on the first [open] and shared by every connection it hands out.
class OdbcSqlConnectionFactory implements SqlConnectionFactory {
  OdbcSqlConnectionFactory();

  OdbcBindings? _bindings;

  OdbcBindings get _lib => _bindings ??= OdbcBindings.open();

  @override
  Future<SqlConnection> open(
    AzureSqlConfig config,
    AadTokenProvider tokens,
  ) async {
    // Read a fresh token per open so a connection never outlives its bearer.
    final token = await tokens.databaseAccessToken();
    final b = _lib;

    final env = _allocHandle(b, sqlHandleEnv, nullptr);
    _check(
      b,
      b.setEnvAttr(env, sqlAttrOdbcVersion,
          Pointer<Void>.fromAddress(sqlOvOdbc3), sqlIsInteger),
      'SQLSetEnvAttr(ODBC_VERSION)',
      sqlHandleEnv,
      env,
    );

    final dbc = _allocHandle(b, sqlHandleDbc, env);

    // Pack the AAD token into the SQL_COPT_SS_ACCESS_TOKEN struct and hand the
    // driver a pointer to it. The bytes must stay live until the connection is
    // established, so this buffer is freed only after SQLDriverConnect returns.
    final tokenBytes = packAccessToken(token);
    final tokenPtr = malloc<Uint8>(tokenBytes.length);
    tokenPtr.asTypedList(tokenBytes.length).setAll(0, tokenBytes);
    try {
      _check(
        b,
        b.setConnectAttr(
            dbc, sqlCoptSsAccessToken, tokenPtr.cast(), sqlIsPointer),
        'SQLSetConnectAttr(ACCESS_TOKEN)',
        sqlHandleDbc,
        dbc,
      );

      final connStr = buildOdbcConnectionString(
        server: config.server,
        database: config.database,
      );
      final connW = connStr.toNativeUtf16();
      try {
        _check(
          b,
          b.driverConnect(dbc, nullptr, connW.cast(), sqlNts, nullptr, 0,
              nullptr, sqlDriverNoprompt),
          'SQLDriverConnect',
          sqlHandleDbc,
          dbc,
        );
      } finally {
        malloc.free(connW);
      }
    } catch (_) {
      // Connect failed: don't leak the handles we already allocated.
      b.freeHandle(sqlHandleDbc, dbc);
      b.freeHandle(sqlHandleEnv, env);
      rethrow;
    } finally {
      malloc.free(tokenPtr);
    }

    return _OdbcSqlConnection(b, env, dbc);
  }
}

/// A live ODBC connection wrapping the environment + connection handles.
class _OdbcSqlConnection implements SqlConnection {
  _OdbcSqlConnection(this._b, this._env, this._dbc);

  final OdbcBindings _b;
  final Pointer<Void> _env;
  final Pointer<Void> _dbc;

  bool _closed = false;
  bool _inTransaction = false;

  @override
  Future<List<SqlRow>> query(String sql,
      [List<Object?> params = const []]) async {
    _ensureOpen();
    final stmt = _allocHandle(_b, sqlHandleStmt, _dbc);
    final allocations = <Pointer<NativeType>>[];
    try {
      _prepare(stmt, sql);
      _bindParams(stmt, params, allocations);
      final ret = _b.execute(stmt);
      // SQL_NO_DATA is success-with-nothing (a searched UPDATE/DELETE that
      // matched zero rows), not a failure — there is no result to read.
      if (ret == sqlNoData) return const [];
      _check(_b, ret, 'SQLExecute', sqlHandleStmt, stmt);
      return _readRows(stmt);
    } finally {
      for (final p in allocations) {
        malloc.free(p);
      }
      _b.freeHandle(sqlHandleStmt, stmt);
    }
  }

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    _ensureOpen();
    final stmt = _allocHandle(_b, sqlHandleStmt, _dbc);
    final allocations = <Pointer<NativeType>>[];
    try {
      _prepare(stmt, sql);
      _bindParams(stmt, params, allocations);
      final ret = _b.execute(stmt);
      // SQL_NO_DATA is success-with-nothing (a searched UPDATE/DELETE that
      // matched zero rows, e.g. clearing an already-empty table), not a
      // failure. The settings store's whole-config replace and the PersonId
      // resolver's insert-if-absent both hit this legitimately.
      if (ret == sqlNoData) return 0;
      _check(_b, ret, 'SQLExecute', sqlHandleStmt, stmt);

      final rowsPtr = malloc<IntPtr>();
      try {
        _check(
            _b, _b.rowCount(stmt, rowsPtr), 'SQLRowCount', sqlHandleStmt, stmt);
        final affected = rowsPtr.value;
        // A DDL / no-count statement reports -1; normalize to 0 affected rows.
        return affected < 0 ? 0 : affected;
      } finally {
        malloc.free(rowsPtr);
      }
    } finally {
      for (final p in allocations) {
        malloc.free(p);
      }
      _b.freeHandle(sqlHandleStmt, stmt);
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqlConnection tx) action) async {
    _ensureOpen();
    // The adapters never nest; a nested call joins the outer transaction so the
    // whole unit still commits or rolls back once.
    if (_inTransaction) return action(this);

    _setAutocommit(false);
    _inTransaction = true;
    try {
      final result = await action(this);
      _check(_b, _b.endTran(sqlHandleDbc, _dbc, sqlCommit),
          'SQLEndTran(COMMIT)', sqlHandleDbc, _dbc);
      return result;
    } catch (_) {
      // Best-effort rollback; surface the original failure, not a rollback one.
      _b.endTran(sqlHandleDbc, _dbc, sqlRollback);
      rethrow;
    } finally {
      _inTransaction = false;
      _setAutocommit(true);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _b.disconnect(_dbc);
    _b.freeHandle(sqlHandleDbc, _dbc);
    _b.freeHandle(sqlHandleEnv, _env);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('operation on a closed OdbcSqlConnection');
    }
  }

  void _setAutocommit(bool on) {
    _check(
      _b,
      _b.setConnectAttr(
        _dbc,
        sqlAttrAutocommit,
        Pointer<Void>.fromAddress(on ? sqlAutocommitOn : sqlAutocommitOff),
        sqlIsInteger,
      ),
      'SQLSetConnectAttr(AUTOCOMMIT)',
      sqlHandleDbc,
      _dbc,
    );
  }

  void _prepare(Pointer<Void> stmt, String sql) {
    final text = sql.toNativeUtf16();
    try {
      // SQL_NTS: the driver measures the null-terminated statement and copies
      // it during prepare, so the buffer is safe to free right after.
      _check(_b, _b.prepare(stmt, text.cast(), sqlNts), 'SQLPrepare',
          sqlHandleStmt, stmt);
    } finally {
      malloc.free(text);
    }
  }

  /// Binds [params] positionally (`?`), collecting every native buffer into
  /// [allocations] so they stay live through `SQLExecute` and are freed by the
  /// caller afterward. Values are bound by the driver, never interpolated.
  void _bindParams(
    Pointer<Void> stmt,
    List<Object?> params,
    List<Pointer<NativeType>> allocations,
  ) {
    for (var i = 0; i < params.length; i++) {
      final value = params[i];
      final paramNum = i + 1;
      final ind = malloc<IntPtr>();
      allocations.add(ind);

      if (value == null) {
        ind.value = sqlNullData;
        // A NULL carries no value, but keep a valid (unused) pointer for it.
        final dummy = malloc<Uint16>();
        dummy.value = 0;
        allocations.add(dummy);
        _bind(stmt, paramNum, sqlCWchar, sqlWvarchar, 1, dummy.cast(), 0, ind);
      } else if (value is bool) {
        final buf = malloc<Uint8>();
        buf.value = value ? 1 : 0;
        allocations.add(buf);
        ind.value = 1;
        _bind(stmt, paramNum, sqlCBit, sqlBit, 0, buf.cast(), 0, ind);
      } else if (value is int) {
        final buf = malloc<Int64>();
        buf.value = value;
        allocations.add(buf);
        ind.value = 8;
        _bind(stmt, paramNum, sqlCSbigint, sqlBigint, 0, buf.cast(), 0, ind);
      } else {
        // String, and DateTime as its ISO-8601 text (SQL Server converts the
        // nvarchar to DATETIME2 on the way in; the adapters read it back as a
        // string and parse it).
        final text = value is DateTime ? value.toIso8601String() : '$value';
        final buf = text.toNativeUtf16();
        allocations.add(buf);
        ind.value = sqlNts;
        final columnSize = text.isEmpty ? 1 : text.length;
        final byteLength = (text.length + 1) * 2;
        _bind(stmt, paramNum, sqlCWchar, sqlWvarchar, columnSize, buf.cast(),
            byteLength, ind);
      }
    }
  }

  void _bind(
    Pointer<Void> stmt,
    int paramNum,
    int valueType,
    int paramType,
    int columnSize,
    Pointer<Void> value,
    int bufferLength,
    Pointer<IntPtr> ind,
  ) {
    _check(
      _b,
      _b.bindParameter(stmt, paramNum, sqlParamInput, valueType, paramType,
          columnSize, 0, value, bufferLength, ind),
      'SQLBindParameter($paramNum)',
      sqlHandleStmt,
      stmt,
    );
  }

  List<SqlRow> _readRows(Pointer<Void> stmt) {
    final countPtr = malloc<Int16>();
    final int columnCount;
    try {
      _check(_b, _b.numResultCols(stmt, countPtr), 'SQLNumResultCols',
          sqlHandleStmt, stmt);
      columnCount = countPtr.value;
    } finally {
      malloc.free(countPtr);
    }
    if (columnCount == 0) return const [];

    final columns = [
      for (var c = 1; c <= columnCount; c++) _describeColumn(stmt, c),
    ];

    final rows = <SqlRow>[];
    while (true) {
      final ret = _b.fetch(stmt);
      if (ret == sqlNoData) break;
      _check(_b, ret, 'SQLFetch', sqlHandleStmt, stmt);
      final row = <String, Object?>{};
      for (var c = 1; c <= columnCount; c++) {
        row[columns[c - 1].name] = _getValue(stmt, c, columns[c - 1].category);
      }
      rows.add(row);
    }
    return rows;
  }

  _Column _describeColumn(Pointer<Void> stmt, int col) {
    const nameCap = 256;
    final nameBuf = malloc<Uint16>(nameCap);
    final nameLen = malloc<Int16>();
    final dataType = malloc<Int16>();
    final colSize = malloc<UintPtr>();
    final decimals = malloc<Int16>();
    final nullable = malloc<Int16>();
    try {
      _check(
        _b,
        _b.describeCol(stmt, col, nameBuf, nameCap, nameLen, dataType, colSize,
            decimals, nullable),
        'SQLDescribeCol($col)',
        sqlHandleStmt,
        stmt,
      );
      final name = String.fromCharCodes(nameBuf.asTypedList(nameLen.value));
      return _Column(name, categoryForSqlType(dataType.value));
    } finally {
      malloc.free(nameBuf);
      malloc.free(nameLen);
      malloc.free(dataType);
      malloc.free(colSize);
      malloc.free(decimals);
      malloc.free(nullable);
    }
  }

  Object? _getValue(Pointer<Void> stmt, int col, OdbcColumnCategory category) {
    final ind = malloc<IntPtr>();
    try {
      switch (category) {
        case OdbcColumnCategory.integer:
          final buf = malloc<Int64>();
          try {
            final ret = _b.getData(stmt, col, sqlCSbigint, buf.cast(), 8, ind);
            if (ret == sqlNoData) return null;
            _check(_b, ret, 'SQLGetData($col)', sqlHandleStmt, stmt);
            return ind.value == sqlNullData ? null : buf.value;
          } finally {
            malloc.free(buf);
          }
        case OdbcColumnCategory.boolean:
          final buf = malloc<Uint8>();
          try {
            final ret = _b.getData(stmt, col, sqlCBit, buf.cast(), 1, ind);
            if (ret == sqlNoData) return null;
            _check(_b, ret, 'SQLGetData($col)', sqlHandleStmt, stmt);
            return ind.value == sqlNullData ? null : buf.value != 0;
          } finally {
            malloc.free(buf);
          }
        case OdbcColumnCategory.text:
          return _getString(stmt, col, ind);
      }
    } finally {
      malloc.free(ind);
    }
  }

  /// Reads a text column, looping over `SQLGetData` chunks so an oversized
  /// value (e.g. an import-rule `NVARCHAR(MAX)` payload) is reassembled whole.
  String? _getString(Pointer<Void> stmt, int col, Pointer<IntPtr> ind) {
    const capChars = 2048; // 4 KiB per chunk
    const capBytes = capChars * 2;
    final buf = malloc<Uint16>(capChars);
    final out = StringBuffer();
    try {
      while (true) {
        final ret = _b.getData(stmt, col, sqlCWchar, buf.cast(), capBytes, ind);
        if (ret == sqlNoData) break;
        _check(_b, ret, 'SQLGetData($col)', sqlHandleStmt, stmt);
        if (ind.value == sqlNullData) return null;
        if (ret == sqlSuccessWithInfo) {
          // Truncated: the buffer is full bar the null terminator; take the
          // full run of chars and go round again for the rest.
          out.write(String.fromCharCodes(buf.asTypedList(capChars - 1)));
          continue;
        }
        // Final chunk: the indicator is the remaining byte count.
        final remainingBytes = ind.value;
        final chars = remainingBytes == sqlNoTotal
            ? _scanForNull(buf, capChars)
            : remainingBytes ~/ 2;
        out.write(String.fromCharCodes(buf.asTypedList(chars)));
        break;
      }
      return out.toString();
    } finally {
      malloc.free(buf);
    }
  }

  int _scanForNull(Pointer<Uint16> buf, int cap) {
    final units = buf.asTypedList(cap);
    final zero = units.indexOf(0);
    return zero < 0 ? cap : zero;
  }
}

/// A described result column: its name and how its value is marshalled.
class _Column {
  _Column(this.name, this.category);
  final String name;
  final OdbcColumnCategory category;
}

/// Allocates an ODBC handle of [type] under [input] and returns it.
Pointer<Void> _allocHandle(OdbcBindings b, int type, Pointer<Void> input) {
  final out = malloc<Pointer<Void>>();
  try {
    final ret = b.allocHandle(type, input, out);
    if (ret != sqlSuccess && ret != sqlSuccessWithInfo) {
      // The output handle is unset on failure, so there is nothing to read
      // diagnostics from; report the raw code.
      throw OdbcException('SQLAllocHandle($type)', 'return code $ret');
    }
    return out.value;
  } finally {
    malloc.free(out);
  }
}

/// Throws an [OdbcException] with the driver's diagnostics when [ret] signals a
/// failure. `SQL_SUCCESS_WITH_INFO` is treated as success (info-only).
void _check(
  OdbcBindings b,
  int ret,
  String operation,
  int handleType,
  Pointer<Void> handle,
) {
  if (ret == sqlSuccess || ret == sqlSuccessWithInfo) return;
  throw OdbcException(operation, _diagnostics(b, handleType, handle));
}

/// Concatenates the diagnostic records (`SQLSTATE: message`) the driver posted
/// for the last failing call on [handle].
String _diagnostics(OdbcBindings b, int handleType, Pointer<Void> handle) {
  const stateCap = 6; // 5 chars + null
  const msgCap = 1024;
  final state = malloc<Uint16>(stateCap);
  final nativeError = malloc<Int32>();
  final message = malloc<Uint16>(msgCap);
  final msgLen = malloc<Int16>();
  final records = <String>[];
  try {
    var record = 1;
    while (true) {
      final ret = b.getDiagRec(handleType, handle, record, state, nativeError,
          message, msgCap, msgLen);
      if (ret != sqlSuccess && ret != sqlSuccessWithInfo) break;
      final sqlState = String.fromCharCodes(state.asTypedList(5));
      final text = String.fromCharCodes(message.asTypedList(msgLen.value));
      records.add('[$sqlState] $text');
      record++;
    }
  } finally {
    malloc.free(state);
    malloc.free(nativeError);
    malloc.free(message);
    malloc.free(msgLen);
  }
  return records.isEmpty ? '(no diagnostic record)' : records.join('; ');
}
