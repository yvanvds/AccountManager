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

  /// The WISA **werkdatum** the records this pass writes were read as of — the
  /// same stamp `WisaSnapshot.workDate` carries (#247).
  ///
  /// WISA answers *as of* a work date, so an operator preparing next year reads
  /// next year's institute and admin numbers. Smartschool, meanwhile, is still
  /// in the running year, and a write that names no year lands there (#339). So
  /// a write whose payload is year-bound must say which year it came from; this
  /// is that year. `null` means nothing stamped one (a snapshot from before
  /// #247, or a harness that models no sync), and every write then behaves
  /// exactly as it did before — the target system's own current year.
  ///
  /// Ignored by actions whose payload is not year-bound.
  final DateTime? workDate;

  const ApplyOptions({
    this.dryRun = false,
    this.deletionDate,
    this.workDate,
  });

  /// A dry-run with no deletion date — the common "just describe it" case.
  static const ApplyOptions dry = ApplyOptions(dryRun: true);

  /// These options stamped with the werkdatum the roster in hand was pulled at.
  /// The State layer owns the snapshots, so it is the layer that knows this;
  /// the actions only read it back off [workDate].
  ApplyOptions asOf(DateTime? workDate) => ApplyOptions(
        dryRun: dryRun,
        deletionDate: deletionDate,
        workDate: workDate,
      );
}
