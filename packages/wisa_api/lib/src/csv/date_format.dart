/// Parses a Belgian-format date string (`d/M/yyyy` — day and month may be
/// one or two digits, year is four digits).
///
/// Mirrors the legacy `DateTime.ParseExact(value, "d/M/yyyy", ...)` calls
/// in `legacy-wpf/AccountApi/Wisa/Student.cs`. Throws [FormatException] on
/// any malformed input — same contract as the legacy code, which raises.
DateTime parseBelgianDate(String input) {
  final s = input.trim();
  final parts = s.split('/');
  if (parts.length != 3) {
    throw FormatException('Expected d/M/yyyy, got "$input"');
  }
  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) {
    throw FormatException('Non-numeric date component in "$input"');
  }
  if (parts[2].length != 4) {
    throw FormatException('Year must be 4 digits in "$input"');
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    throw FormatException('Out-of-range date in "$input"');
  }
  return DateTime(year, month, day);
}

/// Formats a [DateTime] as `dd/MM/yyyy` for use as a SOAP parameter
/// (`Werkdatum`). Mirrors the legacy `date.ToString("dd/MM/yyyy", ...)`
/// in all `*Manager.cs` files.
String formatWerkdatum(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}
