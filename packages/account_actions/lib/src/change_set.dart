import 'package:account_core/account_core.dart' show Origin;

/// One field-level change an action would make, for the diff UI.
///
/// [before] and [after] are the human-readable current and proposed values;
/// either may be null (a field being set for the first time, or cleared).
class FieldChange {
  final String field;
  final String? before;
  final String? after;

  const FieldChange(this.field, {this.before, this.after});

  @override
  String toString() =>
      'FieldChange($field: ${before ?? '∅'} → ${after ?? '∅'})';
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
