import 'package:account_core/account_core.dart' show Origin;

/// One field-level detail of an action's diff, in one of two shapes.
///
/// **A transition** — the default constructor. [before] and [after] are the
/// human-readable current and proposed values; either may be null (a field
/// being set for the first time, or cleared).
///
/// **A quantity** — [FieldChange.count]. Some actions describe themselves with
/// a number rather than with a value moving from one thing to another: a class
/// group's roster write adds 21 members and removes 17, and neither number is
/// the new value of a field. Rendered through the transition template that read
/// `leden toevoegen: ∅ → 21` — a claim that a field used to be empty and is
/// becoming 21, which is not what happened to anything (#300). [isCount] is how
/// a description says which of the two it is, so the UI can state a quantity
/// instead of diffing it.
class FieldChange {
  final String field;

  /// The current value — always null for a count, which has no "before" half.
  final String? before;

  /// The proposed value, or — when [isCount] — the quantity itself.
  final String? after;

  /// Whether [after] is a quantity this action acts on rather than the value
  /// the field is moving to (#300).
  final bool isCount;

  const FieldChange(
    this.field, {
    this.before,
    this.after,
    this.isCount = false,
  }) : assert(
          !isCount || before == null,
          'a count states one number; it has no "before" half',
        );

  /// [amount] things this action will act on — members added, members removed.
  ///
  /// The number lands in [after] so every consumer that reads a field's value
  /// keeps working; [isCount] is what stops it being read as a transition.
  FieldChange.count(String field, int amount)
      : this(field, after: '$amount', isCount: true);

  @override
  String toString() => isCount
      ? 'FieldChange($field: $after)'
      : 'FieldChange($field: ${before ?? '∅'} → ${after ?? '∅'})';
}

/// A pure description of what an action would change, produced by
/// `Action.describeChanges()` (spec `docs/domain-model.md` §3.10). Drives the
/// action-detail diff dialog and the dry-run path (PAIN-3): the same
/// description is shown whether or not the change is actually applied.
class ChangeSet {
  /// The system the change targets.
  final Origin system;

  /// A short, human-facing summary (Dutch, ported from the legacy action
  /// `Header`/`Description`).
  final String summary;

  /// The field-level diff. Empty for pure lifecycle actions (create/delete)
  /// where a per-field table is not meaningful.
  final List<FieldChange> fields;

  const ChangeSet({
    required this.system,
    required this.summary,
    this.fields = const [],
  });

  @override
  String toString() => 'ChangeSet(${system.name}: $summary, '
      '${fields.length} field(s))';
}
