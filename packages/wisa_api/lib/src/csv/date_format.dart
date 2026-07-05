/// Parses a Belgian-format date string (`d/M/yyyy` — day and month may be
/// one or two digits, year is four digits), or returns `null` if [input] is
/// not a well-formed date in that format.
///
/// Non-throwing companion to [parseBelgianDate]. Used to locate the date
/// columns (GEBOORTEDATUM, KLASWIJZIGING) when anchoring the student-row
/// parser on typed landmarks (issue #148): only a genuine date matches, so
/// name/place/street free-text columns never register as one.
DateTime? tryParseBelgianDate(String input) {
  final parts = input.trim().split('/');
  if (parts.length != 3) return null;
  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) return null;
  if (parts[2].length != 4) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// Parses a Belgian-format date string (`d/M/yyyy` — day and month may be
/// one or two digits, year is four digits).
///
/// Mirrors the legacy `DateTime.ParseExact(value, "d/M/yyyy", ...)` calls
/// in `legacy-wpf/AccountApi/Wisa/Student.cs`. Throws [FormatException] on
/// any malformed input — same contract as the legacy code, which raises.
DateTime parseBelgianDate(String input) {
  final parsed = tryParseBelgianDate(input);
  if (parsed == null) {
    throw FormatException('Expected d/M/yyyy, got "$input"');
  }
  return parsed;
}

/// Formats a [DateTime] as `dd/MM/yyyy` for use as a SOAP parameter
/// (`Werkdatum`). Mirrors the legacy `date.ToString("dd/MM/yyyy", ...)`
/// in all `*Manager.cs` files.
String formatWerkdatum(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}
