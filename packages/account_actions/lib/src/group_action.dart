import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'change_set.dart';
import 'connectors.dart';

/// The group action family (spec `docs/domain-model.md` §3.10). One subclass
/// per legacy `Action\Group\*` class, mirroring [StudentAction]/[StaffAction].
///
/// **Target binding.** Each action is bound to the [LinkedGroup] it acts on at
/// construction; [evaluate]/[describeChanges] read the bound [group] (exposed
/// as [target]) and stay pure, while [apply] carries no target of its own.
///
/// **Purity boundary (INV-40/41/42).** [evaluate] and [describeChanges] are
/// pure and deterministic — no I/O, no globals. [apply] is the only impure
/// operation; it is retry-safe (a transient failure returns
/// [ActionOutcome.failed] without corrupting state) and never mutates the bound
/// [group] or its snapshot records.
///
/// **Group vs account families.** Three differences shape this family:
/// - **No config.** Unlike [StudentAction]/[StaffAction], the shippable group
///   actions derive everything from the WISA/Smartschool group pair — there is
///   no domain, password, or uid to inject — so there is no `GroupActionConfig`.
/// - **No Azure and no date.** Legacy has no Azure group action, and the group
///   `Apply` takes no date; [LinkedGroup.azure] is ignored here.
/// - **Group record, not account.** A written group flows back through
///   [ActionResult.group] (a [Group]), not [ActionResult.smartschool] (a
///   `SmartschoolAccount`).
///
/// **Scope (issue #54, "fitting subset").** Only the actions the [LinkedGroup]
/// model can express ship here: [DoNotImportFromWisa], [DoNotImportFromSmartschool]
/// (informational), and [ModifySmartschoolData]. The legacy `AddToSmartschool` /
/// `CreateInSmartschool` actions, and standalone Untis-drift detection, need
/// data the canonical [Group] does not carry — WISA class membership
/// (`ContainsStudents`), the Smartschool group tree for parent placement, and a
/// `untis` field — and are tracked as a follow-up (see the package README),
/// mirroring how the student/staff slices deferred their class-group placement.
sealed class GroupAction {
  /// The linked class group this action targets, bound at construction.
  final LinkedGroup group;

  const GroupAction(this.group);

  /// Alias for the bound [group] — the "target" the spec's `evaluate(target)`
  /// refers to.
  LinkedGroup get target => group;

  /// Whether this action applies to [group]. Pure and deterministic (INV-40).
  bool evaluate();

  /// The field-level diff this action would make. Pure (INV-40).
  ChangeSet describeChanges();

  /// Whether [apply] can perform a change. `false` for informational actions
  /// (the legacy `CanBeApplied == false` case): they surface a diagnosis to the
  /// operator but have no automated write, so calling [apply] throws. Callers
  /// (UI / State layer) gate the "apply" affordance on this.
  bool get canApply => true;

  /// Performs the change on the target system. Impure. With
  /// [ApplyOptions.dryRun] set, performs **no** writes and returns the
  /// projected [ActionResult] (PAIN-3). Throws [UnsupportedError] when
  /// [canApply] is `false`.
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options);

  // --- shared helpers -------------------------------------------------------

  Group get _wisa => group.wisa!;
  Group get _ss => group.smartschool!;

  ss.SmartschoolConnector _requireSmartschool(Connectors c) =>
      c.smartschool ??
      (throw StateError('$runtimeType.apply needs a Smartschool connector'));

  ActionResult _failed(ChangeSet changes, Origin system, Object error) =>
      ActionResult(
        outcome: ActionOutcome.failed,
        changes: changes,
        system: system,
        error: error,
      );
}

// ---------------------------------------------------------------------------
// Actions for when the group is missing from one system (§6.3).
// ---------------------------------------------------------------------------

/// Stop importing a class from WISA. Ported from `Action\Group\DoNotImportFromWisa`:
/// the class exists in WISA but not Smartschool, and the operator judges it need
/// not exist downstream, so a [wapi.DontImportClass] rule is added keyed on the
/// group name.
///
/// Like the staff [DontImportStaffFromWisa] this writes nothing: WISA is
/// read-only, so [apply] returns the rule via [ActionResult.wisaRule] for the
/// State layer to add to its import-rule set and re-sync (which drops the class
/// next snapshot).
///
/// **Key divergence.** Legacy keys the rule on the raw WISA `Group.Name`; the
/// canonical [LinkedGroup.wisa] carries only the `fullName` (the cross-system
/// match key), so the rule is keyed on that. For a single-group class
/// (`groupName == "00"`) the two are identical; for a subgrouped class they
/// differ, a limitation of the linked-record model rather than this action.
class DoNotImportFromWisa extends GroupAction {
  const DoNotImportFromWisa(super.group);

  @override
  bool evaluate() => group.wisa != null && group.smartschool == null;

  wapi.DontImportClass _rule() => wapi.DontImportClass(_wisa.name);

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.wisa,
        summary: 'Negeer deze klas bij het importeren uit WISA',
        fields: [FieldChange('DontImportClass', after: _wisa.name)],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    return ActionResult(
      outcome: options.dryRun ? ActionOutcome.dryRun : ActionOutcome.applied,
      changes: changes,
      system: Origin.wisa,
      wisaRule: _rule(),
    );
  }
}

/// An orphan Smartschool class with no matching WISA class. Ported from
/// `Action\Group\DoNotImportFromSmartschool`, whose legacy `Apply` throws
/// `NotImplementedException` — it is **informational only** (legacy
/// `CanBeApplied == false`): it tells the operator the class exists in
/// Smartschool but not WISA, and the resolution (keep it, or delete it by hand)
/// is theirs. There is no automated write, so [canApply] is `false` and [apply]
/// throws.
class DoNotImportFromSmartschool extends GroupAction {
  const DoNotImportFromSmartschool(super.group);

  @override
  bool evaluate() => group.wisa == null && group.smartschool != null;

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => const ChangeSet(
        system: Origin.smartschool,
        summary: 'Deze klas bestaat in Smartschool maar niet in WISA. '
            'Verwijder ze manueel als ze niet meer nodig is.',
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'DoNotImportFromSmartschool is informational and cannot be applied '
        '(canApply is false)',
      );
}

// ---------------------------------------------------------------------------
// Actions for when the group is present in both systems (§6.3).
// ---------------------------------------------------------------------------

/// Sync a Smartschool class's data down from its WISA counterpart. Ported from
/// `Action\Group\ModifySmartschoolData`, evaluated only when both systems carry
/// the class.
///
/// Legacy syncs three fields — institute number, Untis id, and description.
/// The canonical [Group] does not carry `untis`, so **standalone Untis-drift
/// detection is deferred** (a follow-up adds `Group.untis`); this action
/// evaluates on the two representable fields:
/// - **institute number** (`Group.instituteNumber`): WISA `schoolCode` → Smartschool.
/// - **description** (`Group.description`): WISA → Smartschool.
///
/// **Untis on write.** Smartschool's `saveClass` rewrites the whole class, so
/// [apply] must supply a `untis` value. Legacy's remediation target is always
/// `Untis == Name`, so the write passes the class name — the write stays
/// correct (it converges Untis to its desired value) even though drift on Untis
/// alone can't yet *trigger* the action.
class ModifySmartschoolData extends GroupAction {
  const ModifySmartschoolData(super.group);

  bool get _instituteDiffers => _ss.instituteNumber != _wisa.instituteNumber;
  bool get _descriptionDiffers => _ss.description != _wisa.description;

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool != null &&
      (_instituteDiffers || _descriptionDiffers);

  /// The Smartschool group as it will look once synced. The two drifting fields
  /// are pulled from WISA; everything else (id/name/type/official/parent/admin
  /// number) is preserved. Idempotent for a field that already agrees.
  Group _synced() => Group(
        id: _ss.id,
        name: _ss.name,
        description: _wisa.description,
        type: _ss.type,
        official: _ss.official,
        parentId: _ss.parentId,
        instituteNumber: _wisa.instituteNumber,
        adminNumber: _ss.adminNumber,
        origin: _ss.origin,
      );

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Werk de klasgegevens bij in Smartschool',
        fields: [
          if (_instituteDiffers)
            FieldChange(
              'instituteNumber',
              before: _ss.instituteNumber,
              after: _wisa.instituteNumber,
            ),
          if (_descriptionDiffers)
            FieldChange(
              'description',
              before: _ss.description,
              after: _wisa.description,
            ),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final updated = _synced();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        group: updated,
      );
    }

    try {
      final ok = await _requireSmartschool(connectors).saveClass(
        name: updated.name,
        description: updated.description,
        code: updated.id.value,
        parentCode: updated.parentId?.value ?? '',
        // Legacy's remediation target for Untis is always the class name.
        untis: updated.name,
        instituteNumber: updated.instituteNumber ?? '',
        adminNumber: updated.adminNumber ?? 0,
      );
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool saveClass returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        group: updated,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}
