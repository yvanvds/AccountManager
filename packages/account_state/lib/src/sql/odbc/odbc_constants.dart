/// ODBC API constants used by the concrete [SqlConnection] driver (issue #89).
///
/// These are the numeric codes from the ODBC headers (`sql.h`, `sqlext.h`,
/// `msodbcsql.h`) the FFI binding passes to `odbc32.dll`. They are plain `int`s
/// with no `dart:ffi` dependency so the marshalling logic that consumes them
/// (`odbc_marshalling.dart`) stays unit-testable off a live driver.
library;

// --- Return codes (SQLRETURN) ------------------------------------------------

/// The call succeeded with no diagnostic.
const int sqlSuccess = 0;

/// The call succeeded but posted an informational diagnostic (e.g. a truncated
/// `SQLGetData` chunk). Treated as success by the driver's error check.
const int sqlSuccessWithInfo = 1;

/// A `SQLFetch` / `SQLGetData` returned no (more) data — the fetch loop's stop
/// signal, not an error.
const int sqlNoData = 100;

/// The call failed; the diagnostic record carries the reason.
const int sqlError = -1;

/// The handle passed to the call was invalid.
const int sqlInvalidHandle = -2;

// --- Handle types ------------------------------------------------------------

const int sqlHandleEnv = 1;
const int sqlHandleDbc = 2;
const int sqlHandleStmt = 3;

// --- Environment / connection attributes -------------------------------------

/// `SQL_ATTR_ODBC_VERSION` — must be set to [sqlOvOdbc3] on the environment
/// before allocating a connection.
const int sqlAttrOdbcVersion = 200;
const int sqlOvOdbc3 = 3;

/// `SQL_ATTR_AUTOCOMMIT` — toggled off for the span of a [SqlConnection.transaction].
const int sqlAttrAutocommit = 102;
const int sqlAutocommitOff = 0;
const int sqlAutocommitOn = 1;

/// `SQL_COPT_SS_ACCESS_TOKEN` — the SQL-Server-specific connection attribute
/// that carries the AAD bearer token (packed by
/// [packAccessToken]); this is how the AAD-only database is authenticated with
/// no stored credential.
const int sqlCoptSsAccessToken = 1256;

/// `SQL_IS_POINTER` — the `StringLength` sentinel for an attribute whose value
/// is a pointer (the access-token struct).
const int sqlIsPointer = -4;

/// `SQL_IS_INTEGER` — the `StringLength` sentinel for an attribute whose value
/// is a fixed-size integer passed in the pointer slot.
const int sqlIsInteger = -6;

// --- Transaction completion --------------------------------------------------

const int sqlCommit = 0;
const int sqlRollback = 1;

// --- DriverConnect completion ------------------------------------------------

/// `SQL_DRIVER_NOPROMPT` — never pop a driver dialog; a headless connect.
const int sqlDriverNoprompt = 0;

// --- Length / indicator sentinels --------------------------------------------

/// `SQL_NTS` — "null-terminated string": lets the driver measure a wide string
/// itself rather than being handed a length.
const int sqlNts = -3;

/// `SQL_NULL_DATA` — a column read back as SQL `NULL`, or a bound parameter to
/// send as `NULL`.
const int sqlNullData = -1;

/// `SQL_NO_TOTAL` — `SQLGetData` could not report the total remaining length of
/// a streamed value up front.
const int sqlNoTotal = -4;

// --- Parameter direction -----------------------------------------------------

const int sqlParamInput = 1;

// --- C data types (SQL_C_*) --------------------------------------------------

/// `SQL_C_WCHAR` — UTF-16 buffer; used for every text value and for values
/// (dates) sent/received as their string form.
const int sqlCWchar = -8;

/// `SQL_C_SBIGINT` — signed 64-bit integer.
const int sqlCSbigint = -25;

/// `SQL_C_BIT` — a single 0/1 byte.
const int sqlCBit = -7;

// --- SQL data types (SQL_*) --------------------------------------------------

const int sqlBit = -7;
const int sqlTinyint = -6;
const int sqlSmallint = 5;
const int sqlInteger = 4;
const int sqlBigint = -5;

/// `SQL_WVARCHAR` — the parameter type strings (and stringified dates) bind as.
const int sqlWvarchar = -9;
