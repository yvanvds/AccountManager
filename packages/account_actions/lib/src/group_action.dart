import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'change_set.dart';
import 'connectors.dart';
import 'group_placement.dart';

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
/// **Scope.** The whole family ships here. [DoNotImportFromWisa],
/// [DoNotImportFromSmartschool] (informational), and [ModifySmartschoolData]
/// derive everything from the WISA/Smartschool group pair (#54). The remaining
/// three — [AddToSmartschool], [CreateInSmartschool] (informational), and
/// standalone Untis-drift inside [ModifySmartschoolData] — need data the
/// canonical [Group] does not carry on its own: WISA class membership
/// (`ContainsStudents`), the Smartschool group tree for parent placement, and a
/// `untis` field (#65). The `untis` field now lives on [Group]; the membership
/// and parent-tree inputs arrive through an injected [GroupPlacement], exactly
/// as the student/staff class placements arrive through [ClassPlacement].
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

/// Create an official Smartschool class from a populated WISA class. Ported from
/// `Action\Group\AddToSmartschool`: the class exists in WISA (with students)
/// but not Smartschool, so it is created under its logical parent in the
/// Smartschool group tree.
///
/// The membership signal and the resolved parent come from the injected
/// [GroupPlacement] — a [LinkedGroup] carries neither. [evaluate] mirrors legacy
/// (`Wisa.Linked && !Smartschool.Linked && ContainsStudents()`); it does not
/// gate on the parent, matching legacy, which offers the action regardless and
/// only checks the parent at apply time.
///
/// **Key divergence.** Legacy builds the class `Code`/`Name`/`Untis` from the
/// raw WISA `Group.Name`; the canonical [LinkedGroup.wisa] carries only the
/// `fullName` (the cross-system match key), so the created class is keyed on
/// that. Identical for a single-group class (`groupName == "00"`); for a
/// subgrouped class the two differ — a limitation of the linked-record model,
/// shared with [DoNotImportFromWisa].
class AddToSmartschool extends GroupAction {
  /// The membership + resolved-parent context, injected by the dispatch.
  final GroupPlacement placement;

  const AddToSmartschool(super.group, this.placement);

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool == null &&
      placement.containsStudents;

  /// The official Smartschool class to create, derived from the WISA class and
  /// the resolved parent. Untis is set to the class name (legacy
  /// `group.Untis = wisa.Name`); the institute and admin numbers ride in on the
  /// WISA-projected [Group].
  Group _created() => Group(
        id: _wisa.id,
        name: _wisa.name,
        description: _wisa.description,
        type: GroupType.classGroup,
        official: true,
        parentId: placement.parent?.id,
        instituteNumber: _wisa.instituteNumber,
        adminNumber: _wisa.adminNumber,
        untis: _wisa.name,
        origin: Origin.smartschool,
      );

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Voeg deze klas toe aan Smartschool',
        fields: [
          FieldChange('name', after: _wisa.name),
          FieldChange('description', after: _wisa.description),
          FieldChange('parent', after: placement.parent?.id.value ?? ''),
        ],
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();
    final created = _created();

    // Legacy silently does nothing when the logical parent can't be resolved;
    // we surface it as a failure instead (retry-safe, INV-41).
    if (placement.parent == null) {
      return _failed(
        changes,
        Origin.smartschool,
        StateError(
          'cannot resolve a Smartschool parent for class ${_wisa.name}',
        ),
      );
    }

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.smartschool,
        group: created,
      );
    }

    try {
      final ok = await _requireSmartschool(connectors).saveClass(
        name: created.name,
        description: created.description,
        code: created.id.value,
        parentCode: created.parentId!.value,
        untis: created.untis,
        instituteNumber: created.instituteNumber ?? '',
        adminNumber: created.adminNumber ?? 0,
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
        group: created,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// An empty WISA class with no Smartschool counterpart. Ported from
/// `Action\Group\CreateInSmartschool`, whose legacy `Apply` throws
/// `NotImplementedException` — it is **informational only** (legacy
/// `CanBeApplied == false`): the WISA class holds no students yet, so there is
/// nothing to create downstream. It tells the operator they may delete the WISA
/// class by hand or wait until it is populated, at which point
/// [AddToSmartschool] takes over. There is no automated write, so [canApply] is
/// `false` and [apply] throws.
///
/// Distinguished from [AddToSmartschool] purely by the [GroupPlacement]
/// membership signal: same WISA-only shape, but `!containsStudents`.
class CreateInSmartschool extends GroupAction {
  /// The membership context, injected by the dispatch. Only
  /// [GroupPlacement.containsStudents] matters here (it must be `false`).
  final GroupPlacement placement;

  const CreateInSmartschool(super.group, this.placement);

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool == null &&
      !placement.containsStudents;

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => const ChangeSet(
        system: Origin.smartschool,
        summary: 'Deze WISA-klas bevat nog geen leerlingen. Verwijder ze '
            'manueel als ze niet meer nodig is, of wacht tot ze leerlingen '
            'bevat.',
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'CreateInSmartschool is informational and cannot be applied '
        '(canApply is false)',
      );
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
/// Legacy syncs three fields, and now so does this action:
/// - **institute number** (`Group.instituteNumber`): WISA `schoolCode` → Smartschool.
/// - **Untis code** (`Group.untis`): converged to the class `name`.
/// - **description** (`Group.description`): WISA → Smartschool.
///
/// **Untis drift is Smartschool-local.** Legacy triggers on
/// `Smartschool.Untis != Smartschool.Name` and remediates by setting
/// `Untis = Name` — it never reads a WISA Untis (WISA has none). Now that
/// [Group.untis] exists, this action detects that drift directly, so a class
/// whose only problem is a stale Untis code raises the action on its own.
/// (Smartschool's `saveClass` rewrites the whole class, so [apply] has always
/// passed `untis = name`; the change here is that Untis can now *trigger* the
/// action too.)
class ModifySmartschoolData extends GroupAction {
  const ModifySmartschoolData(super.group);

  bool get _instituteDiffers => _ss.instituteNumber != _wisa.instituteNumber;
  bool get _descriptionDiffers => _ss.description != _wisa.description;

  /// Legacy `Smartschool.Untis != Smartschool.Name`: the class's stored Untis
  /// code has drifted from its name. Purely a Smartschool-side comparison.
  bool get _untisDiffers => _ss.untis != _ss.name;

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool != null &&
      (_instituteDiffers || _untisDiffers || _descriptionDiffers);

  /// The Smartschool group as it will look once synced. Institute number and
  /// description are pulled from WISA; Untis is converged to the class name
  /// (legacy's fixed remediation target); everything else
  /// (id/name/type/official/parent/admin number) is preserved. Idempotent for a
  /// field that already agrees.
  Group _synced() => Group(
        id: _ss.id,
        name: _ss.name,
        description: _wisa.description,
        type: _ss.type,
        official: _ss.official,
        parentId: _ss.parentId,
        instituteNumber: _wisa.instituteNumber,
        adminNumber: _ss.adminNumber,
        untis: _ss.name,
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
          if (_untisDiffers)
            FieldChange('untis', before: _ss.untis, after: _ss.name),
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
