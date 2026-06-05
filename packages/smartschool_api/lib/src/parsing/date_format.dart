/// Smartschool date (de)serialisation.
///
/// Smartschool exchanges dates as `Y-M-D` with **no zero-padding**
/// (e.g. `2010-3-5`, not `2010-03-05`). This matches the legacy
/// `AccountApi.Utils.DateToString`/`StringToDate` pair verbatim — note it
/// differs from the WISA connector's `dd/MM/yyyy` "Werkdatum" format.
library;

/// Formats [date] as `Y-M-D` without zero-padding. Returns `''` when [date]
/// is null (legacy returned `""` for a null `DateTime`).
String formatSmartschoolDate(DateTime? date) {
  if (date == null) return '';
  return '${date.year}-${date.month}-${date.day}';
}

/// Parses a `Y-M-D` Smartschool date. Returns `null` when [value] does not
/// have exactly three dash-separated integer parts (legacy returned
/// `DateTime.MinValue`; we use `null` so callers keep an explicit absent
/// value).
DateTime? parseSmartschoolDate(String value) {
  final parts = value.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}
