import 'package:account_core/account_core.dart' show Origin;

/// Which of the three things a [FieldChange] is saying.
///
/// A `ChangeSet` field used to be able to say only one of them, so the other
/// two were written as transitions and read as claims about nothing that
/// happens (#300, #305).
enum FieldChangeShape {
  /// A value moving: `mail: ∅ → GBS-1A@student.school.example`.
  transition,

  /// A quantity the action acts on: `leden toevoegen: 21` (#300).
  count,

  /// A fact about the record as it stands: `mail: GBS-9Z@…` (#305).
  statement,
}

/// One field-level detail of an action's description, in one of three
/// [FieldChangeShape]s.
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
/// becoming 21, which is not what happened to anything (#300).
///
/// **A statement** — [FieldChange.statement]. An informational notice does not
/// propose anything; it describes the record it is telling the operator about.
/// The "leave this Office 365 group standing" half of the stale-group either/or
/// names the group's address and its member count, and through the transition
/// template those read `mail: GBS-9Z@… → ∅` and `leden: 21 → ∅` — the address
/// and the 21 members being cleared, the exact opposite of the option's own
/// heading (#305).
///
/// [shape] is how a description says which of the three it is, so a renderer
/// can state a quantity or a fact instead of diffing it.
class FieldChange {
  final String field;

  /// The current value — the left half of a transition, or the value a
  /// [FieldChange.statement] states. Always null for a count.
  final String? before;

  /// The proposed value, or — for a [FieldChange.count] — the quantity itself.
  /// Always null for a statement, which has nothing it moves to.
  final String? after;

  /// Which of the three things this field is saying (#300, #305).
  final FieldChangeShape shape;

  const FieldChange(
    this.field, {
    this.before,
    this.after,
    this.shape = FieldChangeShape.transition,
  })  : assert(
          shape != FieldChangeShape.count || before == null,
          'a count states one number; it has no "before" half',
        ),
        assert(
          shape != FieldChangeShape.statement || after == null,
          'a statement says what is; it has nothing it moves to',
        );

  /// [amount] things this action will act on — members added, members removed.
  ///
  /// The number lands in [after] so every consumer that reads a field's value
  /// keeps working; [shape] is what stops it being read as a transition.
  FieldChange.count(String field, int amount)
      : this(field, after: '$amount', shape: FieldChangeShape.count);

  /// [value] is what the record holds, stated rather than diffed (#305).
  ///
  /// It lands in [before] — the slot that has always meant "what is there now",
  /// which is precisely what a statement is about.
  const FieldChange.statement(String field, String value)
      : this(field, before: value, shape: FieldChangeShape.statement);

  @override
  String toString() => switch (shape) {
        FieldChangeShape.count => 'FieldChange($field: $after)',
        FieldChangeShape.statement => 'FieldChange($field: $before)',
        FieldChangeShape.transition =>
          'FieldChange($field: ${before ?? '∅'} → ${after ?? '∅'})',
      };
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
