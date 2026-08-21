import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'action_result.dart';
import 'apply_options.dart';
import 'azure_class_group.dart';
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
/// - **No config.** Unlike [StudentAction]/[StaffAction], the group actions
///   derive everything from the linked record plus an injected placement —
///   there is no domain, password, or uid to inject — so there is no
///   `GroupActionConfig`. The Office 365 naming (`<PREFIX>-<KLAS>@<domein>`)
///   that *would* need one arrives fully resolved on [AzureClassGroupPlan].
/// - **No date.** The group `Apply` takes no date.
/// - **Group record, not account.** A written group flows back through
///   [ActionResult.group] (a Smartschool [Group]) or [ActionResult.azureGroup]
///   (an Azure group), not [ActionResult.smartschool] (a
///   `SmartschoolAccount`).
///
/// **Scope.** The whole legacy family ships here, plus the actions legacy never
/// had: [ClassExistsAsSmartschoolGroup] (informational, #225) and the Office 365
/// class-group trio [CreateAzureClassGroup] / [SyncAzureClassGroupMembers] /
/// [AzureClassGroupWithoutClass] (#228). [DoNotImportFromWisa],
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

  /// The key shared by mutually-exclusive alternatives resolving the same
  /// situation (#110). `null` (the default) means the action stands on its own.
  /// The group family's one key is [classImportAlternative] (#244). See
  /// [StudentAction.alternativeGroup].
  String? get alternativeGroup => null;

  /// Whether this action is the default alternative within its
  /// [alternativeGroup]. Ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// The action types this one **unlocks** on the same target (#245) — the
  /// group family's half of the chaining [StudentAction.unlocks] introduced for
  /// students (#230), and deliberately the same mechanism rather than a second
  /// one.
  ///
  /// Provisioning a class group is a chain, not a single action:
  /// [CreateAzureClassGroup] leaves an **empty** group, because Graph creates
  /// the group and its membership in separate writes, so the roster only lands
  /// once [SyncAzureClassGroupMembers] runs. The dispatch (§6.3) is a pure
  /// function of the *current* record and can only offer the first link, which
  /// is why creating `SSM-2F` used to need the operator's second click.
  ///
  /// Declaring the follow-up here lets the State layer run it immediately
  /// against the **relinked** record — the created group with the id Graph
  /// minted, spliced into the snapshot — and never against a projection.
  ///
  /// Pure and constant: it names what *may* follow, never what must. The
  /// follow-up's own [evaluate] still decides (a class whose students have no
  /// Office 365 account yet has nothing to add), and an informational follow-up
  /// is never run.
  Set<Type> get unlocks => const {};

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

  az.AzureConnector _requireAzure(Connectors c) =>
      c.azure ??
      (throw StateError('$runtimeType.apply needs an Azure connector'));

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

/// The [GroupAction.alternativeGroup] key shared by the mutually exclusive
/// readings of a WISA class Smartschool does not have (#244): import the class
/// ([AddToSmartschool] when it holds students, [CreateInSmartschool]'s
/// wait-or-delete notice when it does not) *or* stop offering it
/// ([DoNotImportFromWisa]).
///
/// They are opposite decisions, so they are one choice and never two to-dos.
/// Applying both created the Smartschool class and then wrote a
/// [wapi.DontImportClass] rule on the very name it had just created —
/// blacklisting the class, which then vanished from the next WISA snapshot
/// while the group survived downstream, unmanaged. "Apply to all" did that to
/// every new class of the year at once.
///
/// The two create actions never fire together (the [GroupPlacement] membership
/// signal picks exactly one), so all three can share the single key and exactly
/// one default is ever offered.
///
/// **The default is the create action, deliberately the opposite polarity from
/// [smartschoolDepartureAlternative]**, where the conservative "keep the
/// account" option leads. Adding new classes is the normal start-of-year bulk
/// operation; a mis-defaulted bulk apply that silently blacklists a year's
/// worth of classes is far worse than one that creates them. For an empty class
/// the default is the informational [CreateInSmartschool], so the bulk apply
/// writes nothing at all and the operator has to pick "ignore this class"
/// deliberately.
///
/// The mechanism itself is family-agnostic: the pending-list grouping reads
/// [alternativeGroup] / [isDefaultAlternative] off whatever action it is given,
/// so a family with the same "provision it *or* stop importing it" pair — the
/// staff [AddStaffToAzure] versus [DontImportStaffFromWisa] of #248 — declares
/// its own key the same way and needs no further plumbing. Keep the
/// provisioning action ahead of the "do not import" one in its dispatch, so it
/// leads the radio list and is also what the grouping falls back to if a
/// default is ever forgotten.
const String classImportAlternative = 'class-import';

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

  /// Blacklisting the class is one half of the [classImportAlternative] choice
  /// (#244) — never a to-do beside the create it contradicts. It is not the
  /// default: an operator has to pick it.
  @override
  String? get alternativeGroup => classImportAlternative;

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
/// One guard legacy has no notion of: a class whose name Smartschool already
/// carries in some form ([LinkedGroup.smartschoolNamesake], #225) is never
/// offered for creation — the write would ask for a duplicate name, which
/// Smartschool either rejects or ends up holding twice.
/// [ClassExistsAsSmartschoolGroup] takes over for that shape.
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
      group.smartschoolNamesake == null &&
      placement.containsStudents;

  /// Creating the class is the leading half of the [classImportAlternative]
  /// choice (#244), and its **default**: importing a new class is the normal
  /// start-of-year operation, so a bulk apply provisions rather than blacklists.
  @override
  String? get alternativeGroup => classImportAlternative;

  @override
  bool get isDefaultAlternative => true;

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
/// membership signal: same WISA-only shape, but `!containsStudents`. It carries
/// the same #225 guard: a class Smartschool already has under this name is
/// [ClassExistsAsSmartschoolGroup]'s business, not an "empty class" notice —
/// telling the operator to delete a WISA class that *is* provisioned downstream
/// is the wrong advice.
class CreateInSmartschool extends GroupAction {
  /// The membership context, injected by the dispatch. Only
  /// [GroupPlacement.containsStudents] matters here (it must be `false`).
  final GroupPlacement placement;

  const CreateInSmartschool(super.group, this.placement);

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool == null &&
      group.smartschoolNamesake == null &&
      !placement.containsStudents;

  /// The empty-class reading stands in for [AddToSmartschool] inside the
  /// [classImportAlternative] choice (#244), and is the default in its place —
  /// the two never fire together, so exactly one default is ever offered. Being
  /// informational, that default makes a bulk apply write **nothing** for an
  /// empty class: blacklisting it stays a deliberate pick.
  @override
  String? get alternativeGroup => classImportAlternative;

  @override
  bool get isDefaultAlternative => true;

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

/// A WISA class whose name Smartschool **already carries**, on a group the
/// linker could not adopt as the class's counterpart (#225). Informational only
/// (`canApply == false`): the resolution is a hand edit in Smartschool, which
/// no API call here should guess at.
///
/// It has no legacy counterpart — legacy had no way to see the situation. The
/// class exists downstream in one of two shapes, both readable off
/// [LinkedGroup.smartschoolNamesake]:
/// - the group is **not flagged as an official class**, so it holds no students
///   and never links (the real `2G` of #225). The operator makes it official in
///   Smartschool, and the next sync links it;
/// - the group *is* an official class but spells its name differently enough
///   that the match key does not join them (`2 G` vs `2G`). The operator aligns
///   the two names.
///
/// Either way the important part is what this action *replaces*:
/// [AddToSmartschool] / [CreateInSmartschool], which would have proposed
/// creating a class that is already there.
class ClassExistsAsSmartschoolGroup extends GroupAction {
  const ClassExistsAsSmartschoolGroup(super.group);

  @override
  bool evaluate() =>
      group.wisa != null &&
      group.smartschool == null &&
      group.smartschoolNamesake != null;

  @override
  bool get canApply => false;

  Group get _namesake => group.smartschoolNamesake!;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: _namesake.official
            ? 'Deze klas bestaat in Smartschool als "${_namesake.name}", met '
                'een andere schrijfwijze. Stem beide namen op elkaar af, dan '
                'wordt ze gekoppeld.'
            : 'Deze klas bestaat in Smartschool maar is geen officiële klas. '
                'Maak ze in Smartschool officieel (of hernoem ze), dan wordt '
                'ze gekoppeld.',
        fields: [
          FieldChange(
            'name',
            before: _namesake.name,
            after: _wisa.name,
          ),
          FieldChange('code', before: _namesake.id.value),
          FieldChange(
            'officiële klas',
            before: _namesake.official ? 'ja' : 'nee',
            after: 'ja',
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'ClassExistsAsSmartschoolGroup is informational and cannot be applied '
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
  /// (id/name/type/official/parent/admin number, and the Smartschool-internal
  /// [Group.sourceId] this write does not touch) is preserved. Idempotent for
  /// a field that already agrees.
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
        sourceId: _ss.sourceId,
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

// ---------------------------------------------------------------------------
// Office 365 class groups (#228). Named `<PREFIX>-<KLAS>` after the **bare**
// class name, so one group serves a class and all of its sub-groups. Everything
// a [LinkedGroup] cannot answer — the bare name, which record owns the class's
// proposals, and the roster diff — arrives on the injected
// [AzureClassGroupPlan].
// ---------------------------------------------------------------------------

/// Create the Office 365 group for a class: `<PREFIX>-<KLAS>`, addressable at
/// `<PREFIX>-<KLAS>@<studentdomein>` (#228).
///
/// Genuinely new — legacy never created a class group, only the handful of named
/// staff groups. It is raised **once per distinct class**, on the record the
/// plan marks as [AzureClassGroupPlan.owner], so a class split into sub-groups
/// yields one proposal rather than one per sub-group.
///
/// Two guards keep it from proposing something that cannot land:
/// - the class must currently hold students, mirroring how an empty WISA class
///   is not created in Smartschool either ([CreateInSmartschool]);
/// - a class name that would not survive as a Graph `mailNickname` yields no
///   plan at all, so no create is offered rather than one Graph rejects.
///
/// [apply] re-asks Graph for the nickname before writing — the same "guard
/// before create" the Azure account creates gained in #224. Graph does not
/// reject a duplicate display name, so without the guard a stale snapshot (or a
/// second operator) silently produces a second group.
class CreateAzureClassGroup extends GroupAction {
  /// The Office 365 naming + roster context, injected by the dispatch.
  final AzureClassGroupPlan plan;

  const CreateAzureClassGroup(super.group, this.plan);

  @override
  bool evaluate() =>
      plan.owner &&
      group.wisa != null &&
      group.azure == null &&
      plan.containsStudents;

  /// Creating the group unlocks the roster write that fills it (#245): Graph
  /// creates a group empty, so without the chain the operator's click left an
  /// `SSM-2F` with nobody in it and the enrolment waited for a second click.
  @override
  Set<Type> get unlocks => const {SyncAzureClassGroupMembers};

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Maak de Office 365-groep ${plan.displayName} '
            'voor klas ${plan.className}',
        fields: [
          FieldChange('displayName', after: plan.displayName),
          FieldChange('mailNickname', after: plan.mailNickname),
          FieldChange('mail', after: plan.mail),
          const FieldChange('groupTypes', after: 'Unified'),
        ],
      );

  /// The group as it will exist once created. Members are added by
  /// [SyncAzureClassGroupMembers] on the next pass, so the projection is empty.
  az.AzureGroup _created() => az.AzureGroup(
        id: '',
        displayName: plan.displayName,
        mailNickname: plan.mailNickname,
        mail: plan.mail,
      );

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azureGroup: _created(),
      );
    }

    try {
      final groups = _requireAzure(connectors).groups;
      // Guard before create (#224's rule, applied to groups): the nickname is
      // what makes the address unique, and Graph creates a second group under
      // the same display name without complaint.
      final existing = await groups.findByMailNickname(plan.mailNickname);
      if (existing != null) {
        return _failed(
          changes,
          Origin.azure,
          StateError(
            'Office 365 already has a group with mailNickname '
            '${plan.mailNickname} (${existing.displayName}). Sync Azure again '
            'so the existing group is linked instead of creating a duplicate.',
          ),
        );
      }
      final created = await groups.createGroup(
        displayName: plan.displayName,
        mailNickname: plan.mailNickname,
        description: _wisa.description,
      );
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azureGroup: created,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// Bring an existing class group's membership in line with the class roster
/// (#228): every student of the class is a member, and a student who left it is
/// removed.
///
/// The diff arrives precomputed on the [AzureClassGroupPlan] because it is the
/// union of the class's sub-group rosters expressed as Azure object ids —
/// neither the roster nor the id mapping is on a [LinkedGroup]. The evaluation
/// itself is offline: `listGroups` already loaded the members onto
/// [LinkedGroup.azure], so no extra Graph read is needed to know a class is out
/// of sync.
///
/// **Removals are limited to our own students.** Staff and titular membership of
/// class groups are out of scope, so a member this app cannot account for as one
/// of its students is never touched — see
/// [AzureClassGroupPlan.membersToRemove].
class SyncAzureClassGroupMembers extends GroupAction {
  /// The Office 365 naming + roster context, injected by the dispatch.
  final AzureClassGroupPlan plan;

  const SyncAzureClassGroupMembers(super.group, this.plan);

  az.AzureGroup get _azure => group.azure! as az.AzureGroup;

  @override
  bool evaluate() =>
      plan.owner && group.azure != null && plan.membershipDiffers;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Werk het ledenbestand van ${plan.displayName} bij '
            '(${plan.membersToAdd.length} toevoegen, '
            '${plan.membersToRemove.length} verwijderen)',
        fields: [
          if (plan.membersToAdd.isNotEmpty)
            FieldChange('leden toevoegen',
                after: '${plan.membersToAdd.length}'),
          if (plan.membersToRemove.isNotEmpty)
            FieldChange('leden verwijderen',
                after: '${plan.membersToRemove.length}'),
        ],
      );

  /// The group record as it will read once both writes have landed — what the
  /// State layer splices into its Azure snapshot so the next relink sees the
  /// class in sync without a re-pull.
  az.AzureGroup _synced() {
    final removed = plan.membersToRemove.toSet();
    return _azure.withMembers(<String>[
      for (final id in _azure.memberIds)
        if (!removed.contains(id)) id,
      ...plan.membersToAdd,
    ]);
  }

  @override
  Future<ActionResult> apply(
    Connectors connectors,
    ApplyOptions options,
  ) async {
    final changes = describeChanges();

    if (options.dryRun) {
      return ActionResult(
        outcome: ActionOutcome.dryRun,
        changes: changes,
        system: Origin.azure,
        azureGroup: _synced(),
      );
    }

    try {
      final groups = _requireAzure(connectors).groups;
      final results = <az.BatchResponse>[
        ...await groups.addMembers(_azure.id, plan.membersToAdd),
        ...await groups.removeMembers(_azure.id, plan.membersToRemove),
      ];
      final failures = results.where((r) => !r.isSuccess).length;
      if (failures > 0) {
        return _failed(
          changes,
          Origin.azure,
          StateError(
            '$failures of ${results.length} membership change(s) on '
            '${plan.displayName} failed',
          ),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        azureGroup: _synced(),
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// An Office 365 class group whose class no longer exists in WISA or
/// Smartschool (#228). **Informational only** (`canApply == false`): groups are
/// never deleted automatically — the mailbox and whatever is shared with it
/// outlive the class — so this is the Azure analogue of the Smartschool orphan
/// notice [DoNotImportFromSmartschool], and the cleanup stays a hand decision.
///
/// It is deliberately narrow. An unmatched Azure group is only reported when it
/// is shaped exactly like one this app creates: inside the school's `<PREFIX>-`
/// namespace, a mail-enabled Microsoft 365 group, and answering on a nickname
/// equal to its display name. A security group, a hand-made Team, or anything
/// outside the namespace is left unmentioned rather than filling the Klasgroepen
/// list with rows nobody will act on (the clutter #209/#225 fixed).
class AzureClassGroupWithoutClass extends GroupAction {
  const AzureClassGroupWithoutClass(super.group);

  az.AzureGroup? get _azure => group.azure as az.AzureGroup?;

  @override
  bool evaluate() {
    final azure = _azure;
    return group.wisa == null &&
        group.smartschool == null &&
        azure != null &&
        group.className != null &&
        azure.isUnified &&
        _sameName(azure.mailNickname, azure.displayName);
  }

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'De klas ${group.className} bestaat niet meer, maar de '
            'Office 365-groep ${_azure?.displayName} nog wel. Verwijder ze '
            'manueel als ze niet meer nodig is.',
        fields: [
          FieldChange('mail', before: _azure?.mail ?? ''),
          FieldChange('leden', before: '${_azure?.memberIds.length ?? 0}'),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'AzureClassGroupWithoutClass is informational and cannot be applied '
        '(canApply is false)',
      );

  static bool _sameName(String? a, String? b) =>
      a != null &&
      b != null &&
      a.trim().toLowerCase() == b.trim().toLowerCase();
}
