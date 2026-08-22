import 'dart:convert';

/// Translates Smartschool integer result codes into human messages.
///
/// Smartschool publishes its error table via the `returnJsonErrorCodes`
/// operation (a JSON object mapping `"code"` → message). The connector loads
/// it once and reuses it. Ports `legacy-wpf/AccountApi/Smartschool/Error.cs`.
///
/// Code `0` always means success and is never an error.
class SmartschoolErrorCodes {
  final Map<String, String> _codes;

  const SmartschoolErrorCodes(this._codes);

  /// An empty table — used before the codes are loaded, or when loading
  /// failed. [translate] then falls back to a generic message.
  static const SmartschoolErrorCodes empty =
      SmartschoolErrorCodes(<String, String>{});

  /// Parses the `returnJsonErrorCodes` payload (a JSON object of
  /// `code → message`). Values are coerced to strings. Throws
  /// [FormatException] when [jsonText] is not a JSON object.
  factory SmartschoolErrorCodes.fromJson(String jsonText) {
    final decoded = json.decode(jsonText);
    if (decoded is! Map) {
      throw FormatException(
        'Expected a JSON object of error codes, got ${decoded.runtimeType}',
      );
    }
    return SmartschoolErrorCodes({
      for (final entry in decoded.entries)
        entry.key.toString(): entry.value.toString(),
    });
  }

  /// `true` once a non-empty table has been loaded.
  bool get isLoaded => _codes.isNotEmpty;

  /// Returns the message for [code], or a generic
  /// `Smartschool-fout <code>` when the code is unknown or the table is
  /// not loaded.
  ///
  /// The fallback is Dutch because it is written straight into the operator's
  /// Log panel by the connector's `_message` (#266). The table's own values are
  /// Smartschool's, quoted as it sends them.
  String translate(int code) =>
      _codes[code.toString()] ?? 'Smartschool-fout $code';
}
