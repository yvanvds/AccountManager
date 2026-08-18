/// Formatting helpers for the freshness stamps the operator reads before
/// deciding whether the shared state is current enough to act on.
library;

/// Renders [at] as the "when was this last touched" stamp shown on the
/// Reconcile last-sync box and the Actions overview header (#192).
///
/// Time-only would make a sync from three days ago read exactly like one from
/// this morning, which is the one case those stamps exist to surface. So the
/// date is included as soon as the stamp leaves today, while today's — the
/// common case — stays as short as it was:
///
/// * today             → `09:14`
/// * yesterday         → `gisteren 09:14`
/// * earlier this year → `15/08 09:14`
/// * an earlier year   → `15/08/2025 09:14`
///
/// Both [at] and [now] are converted to local time before being compared, so a
/// UTC stamp is bucketed against the operator's own calendar day. [now]
/// defaults to the current time; tests pass a fixed clock.
String formatFreshnessStamp(DateTime at, {DateTime? now}) {
  final DateTime t = at.toLocal();
  final DateTime n = (now ?? DateTime.now()).toLocal();

  final String hhmm = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  // Compare calendar days, not elapsed hours: 23:50 and 00:10 are a different
  // day to the operator even though they are twenty minutes apart. Building the
  // neighbouring day through the DateTime constructor (rather than subtracting
  // a Duration) keeps it at local midnight across a DST shift.
  final DateTime day = DateTime(t.year, t.month, t.day);
  final DateTime today = DateTime(n.year, n.month, n.day);
  if (day == today) return hhmm;
  if (day == DateTime(n.year, n.month, n.day - 1)) return 'gisteren $hhmm';

  final String dm = '${t.day.toString().padLeft(2, '0')}/'
      '${t.month.toString().padLeft(2, '0')}';
  // The year is only worth the width once the stamp leaves the current one.
  final String date = t.year == n.year ? dm : '$dm/${t.year}';
  return '$date $hhmm';
}
