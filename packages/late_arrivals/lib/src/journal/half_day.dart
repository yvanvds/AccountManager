/// The half of the school day a late arrival is written against (#428).
///
/// Smartschool's Presence module does not know clock times: a day has a
/// morning cell and an afternoon cell, and a late arrival goes in one of them.
/// Which one is decided by the scan, not by the operator — the desk scans a
/// student who turns up at 13:20 exactly as it scans one at 08:14, and the
/// registration has to land on the half-day the student was actually late for.
///
/// `#399` originally assumed nobody would be scanned after noon, so the drain
/// wrote every presence to the morning. The desk proved otherwise, hence this.
enum HalfDay {
  /// Before [noonHour] local time — Smartschool's `am`.
  morning,

  /// From [noonHour] local time onwards — Smartschool's `pm`.
  afternoon;

  /// The hour at which the afternoon starts, on the operator's wall clock.
  ///
  /// Noon rather than a per-school timetable boundary. A student scanned at
  /// 12:30 during the lunch break is late for the afternoon whichever minute
  /// the last morning period ended, and a student scanned at 11:50 is late for
  /// the morning however early the timetable calls it a day.
  static const int noonHour = 12;

  /// The half-day [moment] falls in, read in [moment]'s own zone — the same
  /// rule `SchoolDay.of` follows, and for the same reason: the operator's wall
  /// clock is what the student and the teacher read.
  static HalfDay of(DateTime moment) =>
      moment.hour < noonHour ? HalfDay.morning : HalfDay.afternoon;
}
