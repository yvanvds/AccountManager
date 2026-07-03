/// The raw `dart:ffi` binding over the ODBC Driver Manager (`odbc32.dll`) used
/// by the concrete [SqlConnection] driver (issue #89).
///
/// This is the Windows-only, un-unit-testable half: a thin set of `SQL*`
/// function lookups plus [OdbcException]. It resolves the ODBC entry points from
/// `odbc32.dll`, which in turn dispatches to `msodbcsql18` named in the
/// connection string. Everything above it (marshalling, the [SqlConnection]
/// contract) is driver-free and covered offline.
library;

import 'dart:ffi';

/// Thrown when an ODBC call returns `SQL_ERROR` / `SQL_INVALID_HANDLE`. Carries
/// the driver's own diagnostic text (SQLSTATE + message) so a live failure —
/// an expired token, a firewall block, a bad statement — is legible.
class OdbcException implements Exception {
  OdbcException(this.operation, this.diagnostics);

  /// The ODBC call that failed, e.g. `SQLDriverConnect`.
  final String operation;

  /// The concatenated diagnostic records read via `SQLGetDiagRec`.
  final String diagnostics;

  @override
  String toString() => 'OdbcException($operation): $diagnostics';
}

// SQLHANDLE and friends are opaque pointers; SQLLEN/SQLULEN are pointer-sized on
// 64-bit Windows, so IntPtr/UintPtr keep the binding architecture-correct.

typedef _SQLAllocHandleNative = Int16 Function(
    Int16 handleType, Pointer<Void> input, Pointer<Pointer<Void>> output);
typedef SqlAllocHandle = int Function(
    int handleType, Pointer<Void> input, Pointer<Pointer<Void>> output);

typedef _SQLSetEnvAttrNative = Int16 Function(
    Pointer<Void> env, Int32 attr, Pointer<Void> value, Int32 stringLength);
typedef SqlSetEnvAttr = int Function(
    Pointer<Void> env, int attr, Pointer<Void> value, int stringLength);

typedef _SQLSetConnectAttrWNative = Int16 Function(
    Pointer<Void> dbc, Int32 attr, Pointer<Void> value, Int32 stringLength);
typedef SqlSetConnectAttrW = int Function(
    Pointer<Void> dbc, int attr, Pointer<Void> value, int stringLength);

typedef _SQLDriverConnectWNative = Int16 Function(
    Pointer<Void> dbc,
    Pointer<Void> windowHandle,
    Pointer<Uint16> inConnStr,
    Int16 inLen,
    Pointer<Uint16> outConnStr,
    Int16 outMax,
    Pointer<Int16> outLen,
    Uint16 completion);
typedef SqlDriverConnectW = int Function(
    Pointer<Void> dbc,
    Pointer<Void> windowHandle,
    Pointer<Uint16> inConnStr,
    int inLen,
    Pointer<Uint16> outConnStr,
    int outMax,
    Pointer<Int16> outLen,
    int completion);

typedef _SQLPrepareWNative = Int16 Function(
    Pointer<Void> stmt, Pointer<Uint16> text, Int32 textLen);
typedef SqlPrepareW = int Function(
    Pointer<Void> stmt, Pointer<Uint16> text, int textLen);

typedef _SQLBindParameterNative = Int16 Function(
    Pointer<Void> stmt,
    Uint16 paramNum,
    Int16 ioType,
    Int16 valueType,
    Int16 paramType,
    UintPtr columnSize,
    Int16 decimalDigits,
    Pointer<Void> value,
    IntPtr bufferLength,
    Pointer<IntPtr> strLenOrInd);
typedef SqlBindParameter = int Function(
    Pointer<Void> stmt,
    int paramNum,
    int ioType,
    int valueType,
    int paramType,
    int columnSize,
    int decimalDigits,
    Pointer<Void> value,
    int bufferLength,
    Pointer<IntPtr> strLenOrInd);

typedef _SQLExecuteNative = Int16 Function(Pointer<Void> stmt);
typedef SqlExecute = int Function(Pointer<Void> stmt);

typedef _SQLNumResultColsNative = Int16 Function(
    Pointer<Void> stmt, Pointer<Int16> count);
typedef SqlNumResultCols = int Function(
    Pointer<Void> stmt, Pointer<Int16> count);

typedef _SQLDescribeColWNative = Int16 Function(
    Pointer<Void> stmt,
    Uint16 col,
    Pointer<Uint16> colName,
    Int16 nameMax,
    Pointer<Int16> nameLen,
    Pointer<Int16> dataType,
    Pointer<UintPtr> colSize,
    Pointer<Int16> decimalDigits,
    Pointer<Int16> nullable);
typedef SqlDescribeColW = int Function(
    Pointer<Void> stmt,
    int col,
    Pointer<Uint16> colName,
    int nameMax,
    Pointer<Int16> nameLen,
    Pointer<Int16> dataType,
    Pointer<UintPtr> colSize,
    Pointer<Int16> decimalDigits,
    Pointer<Int16> nullable);

typedef _SQLFetchNative = Int16 Function(Pointer<Void> stmt);
typedef SqlFetch = int Function(Pointer<Void> stmt);

typedef _SQLGetDataNative = Int16 Function(
    Pointer<Void> stmt,
    Uint16 col,
    Int16 targetType,
    Pointer<Void> target,
    IntPtr bufferLength,
    Pointer<IntPtr> strLenOrInd);
typedef SqlGetData = int Function(Pointer<Void> stmt, int col, int targetType,
    Pointer<Void> target, int bufferLength, Pointer<IntPtr> strLenOrInd);

typedef _SQLRowCountNative = Int16 Function(
    Pointer<Void> stmt, Pointer<IntPtr> rowCount);
typedef SqlRowCount = int Function(
    Pointer<Void> stmt, Pointer<IntPtr> rowCount);

typedef _SQLEndTranNative = Int16 Function(
    Int16 handleType, Pointer<Void> handle, Int16 completionType);
typedef SqlEndTran = int Function(
    int handleType, Pointer<Void> handle, int completionType);

typedef _SQLGetDiagRecWNative = Int16 Function(
    Int16 handleType,
    Pointer<Void> handle,
    Int16 recNumber,
    Pointer<Uint16> state,
    Pointer<Int32> nativeError,
    Pointer<Uint16> message,
    Int16 messageMax,
    Pointer<Int16> messageLen);
typedef SqlGetDiagRecW = int Function(
    int handleType,
    Pointer<Void> handle,
    int recNumber,
    Pointer<Uint16> state,
    Pointer<Int32> nativeError,
    Pointer<Uint16> message,
    int messageMax,
    Pointer<Int16> messageLen);

typedef _SQLFreeHandleNative = Int16 Function(
    Int16 handleType, Pointer<Void> handle);
typedef SqlFreeHandle = int Function(int handleType, Pointer<Void> handle);

typedef _SQLDisconnectNative = Int16 Function(Pointer<Void> dbc);
typedef SqlDisconnect = int Function(Pointer<Void> dbc);

/// The bound `SQL*` entry points, looked up once from `odbc32.dll`.
///
/// A value type holding the resolved function pointers so the connection code
/// reads as ordinary Dart calls. Constructed by [OdbcBindings.open], which is
/// the single place the native library is loaded.
class OdbcBindings {
  OdbcBindings._(this._lib)
      : allocHandle =
            _lib.lookupFunction<_SQLAllocHandleNative, SqlAllocHandle>(
                'SQLAllocHandle'),
        setEnvAttr = _lib.lookupFunction<_SQLSetEnvAttrNative, SqlSetEnvAttr>(
            'SQLSetEnvAttr'),
        setConnectAttr =
            _lib.lookupFunction<_SQLSetConnectAttrWNative, SqlSetConnectAttrW>(
                'SQLSetConnectAttrW'),
        driverConnect =
            _lib.lookupFunction<_SQLDriverConnectWNative, SqlDriverConnectW>(
                'SQLDriverConnectW'),
        prepare =
            _lib.lookupFunction<_SQLPrepareWNative, SqlPrepareW>('SQLPrepareW'),
        bindParameter =
            _lib.lookupFunction<_SQLBindParameterNative, SqlBindParameter>(
                'SQLBindParameter'),
        execute =
            _lib.lookupFunction<_SQLExecuteNative, SqlExecute>('SQLExecute'),
        numResultCols =
            _lib.lookupFunction<_SQLNumResultColsNative, SqlNumResultCols>(
                'SQLNumResultCols'),
        describeCol =
            _lib.lookupFunction<_SQLDescribeColWNative, SqlDescribeColW>(
                'SQLDescribeColW'),
        fetch = _lib.lookupFunction<_SQLFetchNative, SqlFetch>('SQLFetch'),
        getData =
            _lib.lookupFunction<_SQLGetDataNative, SqlGetData>('SQLGetData'),
        rowCount =
            _lib.lookupFunction<_SQLRowCountNative, SqlRowCount>('SQLRowCount'),
        endTran =
            _lib.lookupFunction<_SQLEndTranNative, SqlEndTran>('SQLEndTran'),
        getDiagRec = _lib.lookupFunction<_SQLGetDiagRecWNative, SqlGetDiagRecW>(
            'SQLGetDiagRecW'),
        freeHandle = _lib.lookupFunction<_SQLFreeHandleNative, SqlFreeHandle>(
            'SQLFreeHandle'),
        disconnect = _lib.lookupFunction<_SQLDisconnectNative, SqlDisconnect>(
            'SQLDisconnect');

  /// Loads the ODBC Driver Manager and binds its entry points. On Windows this
  /// is `odbc32.dll`, always present alongside the `msodbcsql18` driver the
  /// connection string names.
  factory OdbcBindings.open() =>
      OdbcBindings._(DynamicLibrary.open('odbc32.dll'));

  // ignore: unused_field
  final DynamicLibrary _lib;

  final SqlAllocHandle allocHandle;
  final SqlSetEnvAttr setEnvAttr;
  final SqlSetConnectAttrW setConnectAttr;
  final SqlDriverConnectW driverConnect;
  final SqlPrepareW prepare;
  final SqlBindParameter bindParameter;
  final SqlExecute execute;
  final SqlNumResultCols numResultCols;
  final SqlDescribeColW describeCol;
  final SqlFetch fetch;
  final SqlGetData getData;
  final SqlRowCount rowCount;
  final SqlEndTran endTran;
  final SqlGetDiagRecW getDiagRec;
  final SqlFreeHandle freeHandle;
  final SqlDisconnect disconnect;
}
