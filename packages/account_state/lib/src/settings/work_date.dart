/// The WISA export "Werkdatum" setting.
///
/// WISA reads enrolments *as of* a work date (Dutch "Werkdatum"): the snapshot
/// it returns depends on which school year that date falls in. The operator
/// either tracks the live date ([isNow] `true`) or pins a fixed [date] to pull
/// a past or future year's roster.
///
/// The legacy `WisaState` kept two of these — a real one and a "virtual" one —
/// each as a `WorkDate` + `WorkDateIsNow` pair (PROJECT_OVERVIEW §6.2), and on
/// load overwrote the stored date with `DateTime.Now` whenever the flag was
/// set. This models the same pair as one immutable value and keeps the "now"
/// resolution out of the stored data: [resolve] takes the current time as an
/// argument (the same discipline as `WisaLiveConfig.resolveWorkDate`), so the
/// model has no hidden clock and stays trivially testable.
class WorkDateSetting {
  const WorkDateSetting({this.isNow = true, this.date});

  /// When `true`, the effective work date tracks the current time and [date] is
  /// ignored. Legacy `WorkDateIsNow` / `WorkDateVirtualIsNow` (default `true`).
  final bool isNow;

  /// The pinned work date, used only when [isNow] is `false`. `null` leaves the
  /// pinned value unset — [resolve] then falls back to the supplied `now` so a
  /// half-configured setting never yields a null date.
  final DateTime? date;

  /// The work date to hand WISA: [date] when pinned, otherwise [now].
  DateTime resolve(DateTime now) => isNow ? now : (date ?? now);

  /// Returns a copy with the given fields replaced. Passing [date] explicitly
  /// sets the pinned date; omit it to keep the current one.
  WorkDateSetting copyWith({bool? isNow, DateTime? date}) => WorkDateSetting(
        isNow: isNow ?? this.isNow,
        date: date ?? this.date,
      );

  /// Serializes to a JSON-encodable map. The pinned [date] is written as an
  /// ISO-8601 string (or `null`); the live "now" is never frozen into the blob.
  Map<String, dynamic> toJson() => {
        'isNow': isNow,
        'date': date?.toIso8601String(),
      };

  /// Reconstructs a [WorkDateSetting] from a map produced by [toJson]. Missing
  /// keys fall back to the constructor defaults (live "now", no pinned date).
  factory WorkDateSetting.fromJson(Map<String, dynamic> json) {
    final rawDate = json['date'] as String?;
    return WorkDateSetting(
      isNow: (json['isNow'] as bool?) ?? true,
      date: rawDate == null ? null : DateTime.parse(rawDate),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkDateSetting && other.isNow == isNow && other.date == date;

  @override
  int get hashCode => Object.hash(isNow, date);
}
