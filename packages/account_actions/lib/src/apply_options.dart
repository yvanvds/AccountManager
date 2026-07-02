/// Options passed to `Action.apply()`.
///
/// Spec `docs/domain-model.md` §3.10, §6.4. [dryRun] is the PAIN-3 fix: when
/// set, `apply` produces the same [ChangeSet] and projected result record but
/// performs **no writes**.
class ApplyOptions {
  /// When true, `apply` performs no side effects — it returns the projected
  /// outcome only (PAIN-3).
  final bool dryRun;

  /// The official change date used by the Smartschool lifecycle writes
  /// (`unregisterStudent`, `deleteUser`); Smartschool records evaluation
  /// history against it. Ported from the legacy `deletionDate` parameter on
  /// the student `Apply`. Ignored by actions that don't need a date.
  final DateTime? deletionDate;

  const ApplyOptions({this.dryRun = false, this.deletionDate});

  /// A dry-run with no deletion date — the common "just describe it" case.
  static const ApplyOptions dry = ApplyOptions(dryRun: true);
}
