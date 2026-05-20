/// Thrown when a CSV payload's header line does not match the expected
/// columns for the query that produced it.
class CsvHeaderMismatch implements Exception {
  final String expected;
  final String actual;
  CsvHeaderMismatch({required this.expected, required this.actual});

  @override
  String toString() =>
      'CsvHeaderMismatch(expected: "$expected", actual: "$actual")';
}

/// Thrown when a CSV row cannot be parsed into its target model.
class CsvRowParseException implements Exception {
  final String line;
  final String message;
  CsvRowParseException(this.line, this.message);

  @override
  String toString() => 'CsvRowParseException: $message — line: "$line"';
}

/// Splits one CSV line into its fields, supporting double-quoted fields that
/// may contain embedded commas. Trailing whitespace inside fields is
/// preserved by the splitter; callers `trim()` per-column where the legacy
/// code does (uniformly, in this connector).
///
/// Rules (RFC 4180-ish, scoped to what WISA actually emits):
///   - Commas separate fields.
///   - A field that starts with `"` is quoted; commas inside are literal
///     until the closing `"`.
///   - Inside a quoted field, `""` is a literal `"`.
///   - Unquoted fields take their content verbatim up to the next comma.
List<String> splitCsvLine(String line) {
  final result = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  var fieldStartedQuoted = false;
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      buf.write(c);
      i++;
      continue;
    }
    if (c == ',') {
      result.add(buf.toString());
      buf.clear();
      fieldStartedQuoted = false;
      i++;
      continue;
    }
    if (c == '"' && buf.isEmpty && !fieldStartedQuoted) {
      inQuotes = true;
      fieldStartedQuoted = true;
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  result.add(buf.toString());
  return result;
}

/// Splits a CSV blob into a header line and the data lines beneath it.
///
/// Validates that `header` matches [expectedHeader] verbatim; the legacy
/// code does the same equality check before parsing rows.
({String header, List<String> rows}) splitCsvWithHeader(
  String csv,
  String expectedHeader,
) {
  final lines = const LineSplitter().convert(csv);
  if (lines.isEmpty) {
    throw CsvHeaderMismatch(expected: expectedHeader, actual: '');
  }
  final header = lines.first;
  if (header != expectedHeader) {
    throw CsvHeaderMismatch(expected: expectedHeader, actual: header);
  }
  return (header: header, rows: lines.skip(1).toList());
}

/// Minimal line splitter: splits on `\n` and trims a trailing `\r` per line.
/// Empty trailing line (from a final `\n`) is dropped.
class LineSplitter {
  const LineSplitter();

  List<String> convert(String s) {
    if (s.isEmpty) return const <String>[];
    final parts = s.split('\n');
    final out = <String>[];
    for (var p in parts) {
      if (p.isNotEmpty && p.codeUnitAt(p.length - 1) == 0x0D) {
        p = p.substring(0, p.length - 1);
      }
      out.add(p);
    }
    if (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out;
  }
}
