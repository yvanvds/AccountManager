/// One entry in the shared late-arrival reason list (#405): the label the
/// operator presses at the desk, and the flag saying whether it counts as a
/// *valid* ("geldige") reason.
///
/// The flag belongs to the reason rather than to a second operator action, and
/// that is the whole design. Oversleeping is not a delayed bus, but asking for
/// an extra click to say so would slow down exactly the moment that has to be
/// fast — a queue of students waiting at reception. To the operator it is one
/// more button in the same flat row; only the Presence call underneath differs
/// ([withoutValidReason] is what #404's write carries).
///
/// The [label] is also the text that goes into the motivation string, in the
/// fixed `HH:mm – reden` format `composeMotivation` pins. It is copied onto the
/// [LateArrivalRecord] at scan time rather than referenced, so a registration
/// still says what was chosen after somebody renames or removes the entry here.
final class LateArrivalReason {
  const LateArrivalReason(this.label, {this.isValid = true});

  /// What the button says, and what the motivation quotes.
  final String label;

  /// Whether picking this reason means the absence counts as excused.
  ///
  /// Defaults to `true`: an operator adding "Treinvertraging" is adding a valid
  /// reason, and the exceptional case is the one worth typing out.
  final bool isValid;

  /// The flag the Smartschool Presence write carries (#404) — the negation of
  /// [isValid], named as the API names it so the call site reads straight.
  bool get withoutValidReason => !isValid;

  /// The identity two entries are considered the same reason under: the trimmed
  /// label, case-folded.
  ///
  /// Case- and whitespace-insensitive on purpose. The list exists so that
  /// Smartschool does not end up with "bus", "Bus" and "bus " side by side —
  /// distinguishing them here would defeat the point of sharing it at all.
  String get key => label.trim().toLowerCase();

  /// Whether this entry can be shown at all. A blank label would render as an
  /// unlabelled button and write a motivation of nothing but a clock time.
  bool get isUsable => label.trim().isNotEmpty;

  LateArrivalReason copyWith({String? label, bool? isValid}) =>
      LateArrivalReason(label ?? this.label, isValid: isValid ?? this.isValid);

  Map<String, Object?> toJson() => <String, Object?>{
        'label': label,
        'valid': isValid,
      };

  /// Reads one entry back. `null` — never an exception — when the label is
  /// missing or of the wrong type, so one damaged entry costs one button and
  /// not the shared settings document.
  ///
  /// A missing `valid` reads as **true**, matching the constructor default: a
  /// document that lost the flag is far likelier to be describing an ordinary
  /// reason than to be silently marking every arrival unexcused.
  static LateArrivalReason? tryFromJson(Map<String, Object?> json) {
    final Object? label = json['label'];
    if (label is! String || label.trim().isEmpty) return null;
    return LateArrivalReason(label.trim(), isValid: json['valid'] != false);
  }

  @override
  bool operator ==(Object other) =>
      other is LateArrivalReason &&
      other.label == label &&
      other.isValid == isValid;

  @override
  int get hashCode => Object.hash(label, isValid);

  @override
  String toString() =>
      'LateArrivalReason($label${isValid ? '' : ', zonder geldige reden'})';
}

/// The list an install starts with, so the desk works before anybody has opened
/// Instellingen (#405).
///
/// Dutch, because the operators and the students are: this is a Belgian
/// secondary school. Short labels because they are read off a button at a
/// glance and then copied verbatim into a Smartschool motivation, where a
/// sentence would be noise.
///
/// The last two are the "zonder geldige reden" half. Two rather than one
/// deliberately: whether that end of the row is one entry or several is the
/// operators' call, and shipping both shapes at once shows that the list
/// supports either — "Verslapen" is the recurring case worth naming, "Geen
/// reden opgegeven" the catch-all for a student who offers nothing.
const List<LateArrivalReason> defaultLateArrivalReasons = <LateArrivalReason>[
  LateArrivalReason('Bus of trein te laat'),
  LateArrivalReason('Verkeer'),
  LateArrivalReason('Doktersbezoek'),
  LateArrivalReason('Verslapen', isValid: false),
  LateArrivalReason('Geen reden opgegeven', isValid: false),
];

/// Cleans a reason list the way the shared document should hold it: labels
/// trimmed, blank entries dropped, and duplicates collapsed on
/// [LateArrivalReason.key] — **order preserved**, first occurrence winning.
///
/// Order is load-bearing rather than incidental: it is the order the scan tab's
/// button row renders in (#407), so the reasons an operator reaches for most
/// can be put first. That is why this de-duplicates in place instead of sorting
/// or re-grouping the invalid entries to the end.
///
/// First-wins on a duplicate, flag included. The alternative — last wins —
/// would let a careless second "Verkeer" silently flip the standing entry's
/// valid flag for every desk at once.
List<LateArrivalReason> normalizeLateArrivalReasons(
  Iterable<LateArrivalReason> reasons,
) {
  final List<LateArrivalReason> out = <LateArrivalReason>[];
  final Set<String> seen = <String>{};
  for (final LateArrivalReason reason in reasons) {
    final LateArrivalReason trimmed =
        reason.copyWith(label: reason.label.trim());
    if (!trimmed.isUsable) continue;
    if (!seen.add(trimmed.key)) continue;
    out.add(trimmed);
  }
  return out;
}

/// Decodes the reason list out of a settings document, falling back to
/// [defaultLateArrivalReasons] when the document has nothing usable to say.
///
/// **Absent and empty are treated alike**, which is the one place this differs
/// from the settings document's other lists (an emptied `smartschoolRoots` is
/// honoured as "walk the whole tree"). There is no reading of "no reasons at
/// all" that an operator could want: it leaves the desk with no button to press
/// and no way to register the student standing in front of them. So a document
/// that has been emptied — by an older build, a bad hand-edit, or a list whose
/// every entry was blank — falls back to the shipped list rather than to a dead
/// screen. The Settings editor refuses to remove the last entry for the same
/// reason.
List<LateArrivalReason> decodeLateArrivalReasons(Object? raw) {
  if (raw is! List) return defaultLateArrivalReasons;
  final List<LateArrivalReason> decoded = <LateArrivalReason>[];
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final LateArrivalReason? reason = LateArrivalReason.tryFromJson(
      entry.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
    );
    if (reason != null) decoded.add(reason);
  }
  final List<LateArrivalReason> normalized =
      normalizeLateArrivalReasons(decoded);
  return normalized.isEmpty ? defaultLateArrivalReasons : normalized;
}
