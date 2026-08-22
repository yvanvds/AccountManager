/// Provenance for a persisted import rule: who added it, when, and for whom
/// (#285).
///
/// This is metadata *about* a rule, never part of one. The rule types live in
/// the connector packages and exist to be applied at snapshot construction;
/// which operator typed one and when has no bearing on that, and `wisa_api` has
/// no business knowing the tenant has operators at all. So the rule classes stay
/// untouched and this rides beside the encoded rule in the settings document
/// (`import_rule_codec`).
///
/// ## Why the record has exactly these three fields
///
/// The settings document is shared across operators on purpose — otherwise every
/// staff member would have to recreate the same rule set — so a colleague's rule
/// shows up in your panel as a bare WISA code with no indication of what it is.
/// Deliberately **no free-text reason field**: an optional reason in a tool
/// people use quickly either gets skipped or gets "n/a", and a half-filled
/// reason column is worse than no column, because the blanks start implying
/// those rules had no reason.
///
/// That shifts the weight onto the three fields that are here:
///
/// - [addedBy] is load-bearing — the record is a *pointer to the person who
///   remembers*, not the explanation itself, so it holds a readable name rather
///   than an object id;
/// - [addedAt] does more work than it looks like: with no "why", the date is
///   what lets someone reconstruct the context ("that was the June retirement
///   round");
/// - [subject] is a **snapshot**, never refreshed against a later pull. The
///   people these rules are about are exactly the ones who eventually disappear
///   from WISA, so resolving the code against the current staff list would give
///   a blank precisely when the name is needed most.
///
/// Every field is optional. A rule persisted before #285 carries none of them at
/// all — [decodeWisaRuleProvenance] answers `null` for it — and the view says so
/// (`onbekend`) rather than rendering a blank that reads like nobody did it.
class RuleProvenance {
  /// [addedAt] is normalized to UTC: the document is read by operators who may
  /// not share a timezone, and the view converts back to local for display.
  RuleProvenance({this.subject = '', this.addedBy = '', DateTime? addedAt})
      : addedAt = addedAt?.toUtc();

  /// The subject's name as it read when the rule was created — the staff member
  /// or class the rule is about. Empty when the authoring surface knew no name
  /// (the Instellingen editor holds no WISA snapshot to resolve a code against).
  final String subject;

  /// The operator who added the rule, as a readable display name. Empty when the
  /// session had no signed-in identity to attribute it to.
  final String addedBy;

  /// When the rule was added, in UTC. Null on a rule persisted before #285.
  final DateTime? addedAt;

  /// Whether this record says nothing at all — the case that is stored as *no*
  /// provenance rather than as an empty object.
  bool get isEmpty => subject.isEmpty && addedBy.isEmpty && addedAt == null;

  /// Whether this record carries at least one field.
  bool get isNotEmpty => !isEmpty;

  /// The fields that are actually known, for merging into the rule's own JSON
  /// object. An unknown field is **absent** rather than empty-stringed, so a
  /// document never claims to record something it does not.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (subject.isNotEmpty) 'subject': subject,
        if (addedBy.isNotEmpty) 'addedBy': addedBy,
        if (addedAt != null) 'addedAt': addedAt!.toIso8601String(),
      };

  /// Reads provenance out of a rule's JSON object, or `null` when the object
  /// carries none — which is every rule written before #285.
  ///
  /// An unparseable `addedAt` degrades to "no timestamp" rather than throwing:
  /// the rule itself is still perfectly applicable, and refusing to load the
  /// whole settings document over a bad metadata string would take the tenant's
  /// configuration down for a cosmetic field.
  static RuleProvenance? fromJson(Map<String, dynamic> json) {
    final raw = json['addedAt'];
    final record = RuleProvenance(
      subject: (json['subject'] as String?) ?? '',
      addedBy: (json['addedBy'] as String?) ?? '',
      addedAt: raw is String ? DateTime.tryParse(raw) : null,
    );
    return record.isEmpty ? null : record;
  }

  @override
  bool operator ==(Object other) =>
      other is RuleProvenance &&
      other.subject == subject &&
      other.addedBy == addedBy &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(subject, addedBy, addedAt);

  @override
  String toString() =>
      'RuleProvenance(subject: $subject, addedBy: $addedBy, addedAt: $addedAt)';
}
