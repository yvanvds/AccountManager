/// The calendar day a late arrival belongs to — the unit the journal is
/// partitioned by (#402).
///
/// A date and nothing else, on purpose. The journal answers "which day was this
/// student late" and "which day's file may be rolled off", and both questions
/// are about a school day, not a moment. Carrying a `DateTime` for that invites
/// exactly the bug the local-preferences store already had to guard against: a
/// stored midnight-plus-nine-hours that compares unequal to the same day.
final class SchoolDay implements Comparable<SchoolDay> {
  const SchoolDay(this.year, this.month, this.day);

  /// The day [moment] falls on, in [moment]'s own zone. A scan at 08:14 local
  /// belongs to that local day; converting to UTC first would file an early
  /// morning scan under the day before in some zones.
  factory SchoolDay.of(DateTime moment) =>
      SchoolDay(moment.year, moment.month, moment.day);

  /// Reads back an `YYYY-MM-DD` [id]. `null` — never an exception — for
  /// anything else, because this parses file names found on disk and a stray
  /// file in the journal directory must not take a launch down.
  static SchoolDay? tryParse(String text) {
    final String trimmed = text.trim();
    if (trimmed.length != 10) return null;
    if (trimmed[4] != '-' || trimmed[7] != '-') return null;
    final int? year = int.tryParse(trimmed.substring(0, 4));
    final int? month = int.tryParse(trimmed.substring(5, 7));
    final int? day = int.tryParse(trimmed.substring(8, 10));
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    // Reject a date that does not exist (2026-02-30 normalises to March).
    final DateTime probe = DateTime.utc(year, month, day);
    if (probe.month != month || probe.day != day) return null;
    return SchoolDay(year, month, day);
  }

  final int year;
  final int month;
  final int day;

  /// `YYYY-MM-DD` — what the file name and every record carries.
  String get id => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// How many whole days [this] lies before [other]; negative when it lies
  /// after. Computed in UTC so a daylight-saving boundary cannot make two
  /// adjacent days 0 or 2 apart.
  int daysBefore(SchoolDay other) =>
      DateTime.utc(other.year, other.month, other.day)
          .difference(DateTime.utc(year, month, day))
          .inDays;

  @override
  int compareTo(SchoolDay other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is SchoolDay &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => id;
}
