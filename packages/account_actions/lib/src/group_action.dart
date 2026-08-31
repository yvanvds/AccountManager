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
/// class-group quartet [CreateAzureClassGroup] / [SyncAzureClassGroupMembers] /
/// [AzureClassGroupWithoutClass] / [DeleteAzureClassGroup] (#228/#271).
/// [DoNotImportFromWisa],
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

  /// Whether this action may be written to **many** classes in one pass (#293)
  /// — the group half of [StudentAction.canApplyToAll]. Defaults to `false`;
  /// see [StudentAction.canApplyToAll] for why the flag lives on the action.
  ///
  /// **No legacy answer to port.** `canBeAppliedToAll` existed only on the two
  /// account families; the legacy Klassen view offered no bulk apply at all, so
  /// every member of this family is a decision made here rather than inherited.
  /// The same line is drawn: the mechanical class syncs and the class-group
  /// provisioning are granted ([AddToSmartschool], [ModifySmartschoolData],
  /// [CreateAzureClassGroup], [SyncAzureClassGroupMembers]); the blacklist
  /// ([DoNotImportFromWisa]) and the two deletes ([DeleteAzureClassGroup],
  /// [DeleteSmartschoolClass]) are withheld, and the informational members
  /// cannot have it at all.
  bool get canApplyToAll => false;

  /// Whether this action's write is stamped with [ApplyOptions.deletionDate]
  /// (#394) — see [StudentAction.usesDeletionDate].
  ///
  /// **No group action carries one, and the member exists so that stays a
  /// statement rather than an omission.** A class is not a person: deleting a
  /// Smartschool class ends a container, and Smartschool records no official
  /// departure date for it the way it does for a pupil's uitschrijving. The
  /// declaration lives here anyway so the UI can ask *any* pending action the
  /// same question instead of knowing which families happen to have dated
  /// writes today.
  bool get usesDeletionDate => false;

  /// The key shared by mutually-exclusive alternatives resolving the same
  /// situation (#110). `null` (the default) means the action stands on its own.
  /// The group family has two: [classImportAlternative] for a class Smartschool
  /// does not have (#244) and [namesakeClassAlternative] for one it already
  /// carries under a group the linker could not adopt (#250). See
  /// [StudentAction.alternativeGroup].
  ///
  /// **Every member of a group writes** (#329). The rule the whole mechanism
  /// rests on: an informational action is *context*, not an alternative. It
  /// declares [noticeFor] and rides along beside the decision it explains,
  /// instead of standing in it as an answer that resolves nothing.
  ///
  /// This family is where the rule was learned, at four sites in a row:
  /// - the two **leftovers** — an Office 365 group whose class is gone, and a
  ///   Smartschool class WISA does not have — each had a key of their own until
  ///   #327 and #328. Both lost it because their conservative half was a no-op:
  ///   "laat de groep staan" / "laat deze klas staan" and "doe niets" are the
  ///   same act, which the operator performs by not pressing **Toepassen**.
  ///   [DeleteAzureClassGroup] and [DeleteSmartschoolClass] now stand alone
  ///   where they can fire, and [AzureClassGroupWithoutClass] /
  ///   [DoNotImportFromSmartschool] alone where they cannot;
  /// - the two **notices** — [ClassExistsAsSmartschoolGroup] and
  ///   [CreateInSmartschool] — were paired with [DoNotImportFromWisa] until
  ///   #329. Their content is not a no-op but genuine instruction ("go make
  ///   this group official", "delete this empty WISA class by hand"), so they
  ///   survive as [noticeFor] context on the very decision they used to be one
  ///   radio of.
  ///
  /// What kept the blacklist and the two deletes off a bulk pass was, until
  /// then, the *polarity* of those pairs — the informational half is the
  /// pre-selected default, so nothing counted. A guard that holds only while a
  /// default holds is not a guard; it is [canApplyToAll], honoured by every bulk
  /// path since #326.
  String? get alternativeGroup => null;

  /// Whether this action is the default alternative within its
  /// [alternativeGroup]. Ignored when [alternativeGroup] is `null`.
  bool get isDefaultAlternative => false;

  /// The situation this **informational** action is context for (#329) — the
  /// [alternativeGroup] key of the decision it belongs beside, or `null` (the
  /// default) when this action is not a notice. See [StudentAction.noticeFor]
  /// for the mechanism.
  ///
  /// Two members carry one, and they are the reason it exists:
  /// [ClassExistsAsSmartschoolGroup] on [namesakeClassAlternative] and
  /// [CreateInSmartschool] on [classImportAlternative]. In both the app can do
  /// exactly one thing — stop importing the class — and the notice says what
  /// the operator should do *instead*, by hand, in the other system.
  ///
  /// The family's other two informational members
  /// ([DoNotImportFromSmartschool] and [AzureClassGroupWithoutClass]) declare
  /// nothing here: each fires exactly where its delete cannot, so there is no
  /// decision beside it to be context for and the row *is* the notice.
  String? get noticeFor => null;

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

  /// The systems the [unlocks] chain would write to, beyond the one
  /// [describeChanges] already names (#234) — the group half of
  /// [StudentAction.unlockedSystems], which documents why the UI cannot derive
  /// this from a pending action.
  Set<Origin> get unlockedSystems => const {};

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

/// The situation key for a WISA class Smartschool does not have (#244): import
/// the class ([AddToSmartschool]) *or* stop offering it
/// ([DoNotImportFromWisa]).
///
/// They are opposite decisions, so they are one choice and never two to-dos.
/// Applying both created the Smartschool class and then wrote a
/// [wapi.DontImportClass] rule on the very name it had just created —
/// blacklisting the class, which then vanished from the next WISA snapshot
/// while the group survived downstream, unmanaged. "Apply to all" did that to
/// every new class of the year at once.
///
/// **The default is the create action, deliberately the opposite polarity from
/// [smartschoolDepartureAlternative]**, where the conservative "keep the
/// account" option leads. Adding new classes is the normal start-of-year bulk
/// operation; a mis-defaulted bulk apply that silently blacklists a year's
/// worth of classes is far worse than one that creates them.
///
/// **An empty class has no create to weigh the blacklist against** — there is
/// nothing to create yet — so the decision there is a lone
/// [DoNotImportFromWisa], with [CreateInSmartschool]'s wait-or-delete notice
/// beside it as [GroupAction.noticeFor] context (#329). It stood *in* this
/// group as its pre-selected default until then, which made a bulk apply write
/// nothing for an empty class by polarity alone. That job is
/// [GroupAction.canApplyToAll]'s — the blacklist withholds it (#293) and every
/// bulk path has honoured it since #326 — while the notice's actual content
/// ("delete the WISA class by hand, or wait until it has students") is
/// instruction the operator still has to read, and reads on the card.
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

/// The situation key for a WISA class Smartschool **already carries**, on a
/// group the linker could not adopt (#225/#250): the app can do exactly one
/// thing about it — stop offering the class ([DoNotImportFromWisa]) — while
/// [ClassExistsAsSmartschoolGroup] states the repair the operator makes by hand
/// instead, as [GroupAction.noticeFor] context on that decision.
///
/// **Why a second key and not a third member of [classImportAlternative].** The
/// pending list keys a "same situation" bulk-apply subset on this very string
/// (`PendingChoice.situationId`), so pooling the namesake classes with the
/// genuinely new ones would file both under one header naming both readings and
/// one **Apply to all**. They are different situations — "create this class" and
/// "this class is already there, go fix its flag" — so they get different keys
/// and each keeps its own bulk pass.
///
/// **The notice was the pre-selected half of a radio pair here from #250 to
/// #329.** That was never a resolution: an operator cannot "apply" *go and make
/// the group official in Smartschool*, so the pair asked them to choose between
/// a diagnosis and the one write the app has. What being the default did do was
/// keep the blacklist off a bulk pass — and that is [GroupAction.canApplyToAll],
/// which [DoNotImportFromWisa] withholds (#293) and which every bulk path reads
/// since #326.
///
/// The original bug is worth keeping in view, because this key is what fixed it
/// and the polarity was only ever half the fix: before #250 the create actions
/// refused a namesake class (they would ask Smartschool for a duplicate name)
/// while [DoNotImportFromWisa] still declared [classImportAlternative], so the
/// choice collapsed to a single member — and a lone option is always the
/// selected one. "Apply to all" therefore wrote a [wapi.DontImportClass] rule on
/// the very class the notice beside it had just told the operator to align by
/// hand: the class dropped out of the next WISA snapshot while the Smartschool
/// group stayed, which is exactly the failure mode #244 fixed for the create
/// case. The blacklist is a lone decision again today, deliberately — and it is
/// the sanction, not the polarity, that keeps a bulk pass off it.
const String namesakeClassAlternative = 'class-namesake';

/// Stop importing a class from WISA. Ported from `Action\Group\DoNotImportFromWisa`:
/// the class exists in WISA but not Smartschool, and the operator judges it need
/// not exist downstream, so a [wapi.DontImportClass] rule is added keyed on the
/// group name.
///
/// Like the staff [DontImportStaffFromWisa] this writes nothing: WISA is
/// read-only, so [apply] returns the rule via [ActionResult.wisaRule] for the
/// State layer to add to its import-rule set and filter its snapshot by (which
/// drops the class on the spot, with no re-pull — #345).
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

  /// Blacklisting the class is never a to-do beside the reading it contradicts.
  /// *Which* situation it resolves depends on what Smartschool already holds:
  /// - **no namesake** (#244): the class is genuinely absent downstream, so the
  ///   situation is [classImportAlternative]. On a class **with students** that
  ///   is a real either/or — create it ([AddToSmartschool]) or stop offering it
  ///   — and it keeps its radios. On an **empty** class there is nothing to
  ///   create, so this is the lone decision and [CreateInSmartschool]'s
  ///   wait-or-delete instruction rides beside it as context (#329);
  /// - **a namesake** ([LinkedGroup.smartschoolNamesake], #250): the class is
  ///   already there under a group the linker could not adopt, so the situation
  ///   is [namesakeClassAlternative]. The repair is a hand edit in Smartschool,
  ///   which no API call here can make, so this is again the lone decision with
  ///   [ClassExistsAsSmartschoolGroup] as its context.
  ///
  /// The two keys are deliberately distinct: they are different situations, and
  /// the pending list bulk-applies per situation key. A key held by this action
  /// alone is not the #250 bug returning — that was a *bulk* pass writing the
  /// rule off a lone-and-therefore-selected option, and what refuses it now is
  /// [canApplyToAll], read by every bulk path since #326.
  @override
  String? get alternativeGroup => group.smartschoolNamesake != null
      ? namesakeClassAlternative
      : classImportAlternative;

  /// **Never in bulk** (#293). Blacklisting a class is a judgement about one
  /// class, and the failure it causes is silent and hard to undo: the class
  /// drops out of the next WISA snapshot while whatever exists downstream
  /// survives, unmanaged. That is precisely what #244 and #250 were filed for
  /// after "Alles toepassen" did it to a year's worth of classes at once.
  ///
  /// Since #329 this flag is the **whole** of that guard. It used to have the
  /// polarity of an alternative group in front of it — an informational default
  /// meant nothing counted until an operator flipped a radio — and a guard that
  /// holds only while a default holds is not a guard: flipping two of them armed
  /// the header. Both notices are context now rather than pre-selected halves,
  /// so this blacklist is the selected resolution of every namesake and every
  /// empty class from the moment the tab opens, and the sanction is what stands
  /// between them and one press. Per-card **Toepassen** still writes it, on the
  /// card that shows exactly what the rule would do.
  @override
  bool get canApplyToAll => false;

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

  /// **In bulk** (#293). Importing the new classes is the start-of-year
  /// operation this family exists for, and the created class is derived
  /// mechanically from the WISA one — nothing here asks the operator to judge a
  /// single class. It is also the half of [classImportAlternative] that a bulk
  /// pass is *meant* to write; the blacklist beside it withholds the flag.
  @override
  bool get canApplyToAll => true;

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
        // The institute and admin numbers came out of WISA as of the werkdatum
        // this pass read, so they are written for that school year and not for
        // whichever one Smartschool is in today (#339).
        schoolYearDate: options.workDate,
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

  /// **Context on the import decision, not one of its answers** (#329). It
  /// stood *inside* [classImportAlternative] as its pre-selected default from
  /// #244 until then, standing in for [AddToSmartschool] on a class with no
  /// students — so the card offered "wait, or delete the WISA class by hand"
  /// beside "never import this class" and asked the operator to pick one. Only
  /// the second is something this app can do; the first is an instruction to go
  /// elsewhere, and an instruction is not a resolution.
  ///
  /// It is instruction worth keeping, though — which is why this is a
  /// [noticeFor] rather than the outright removal #327/#328 gave the two no-op
  /// halves. "Delete it by hand if it is not needed, or wait until it holds
  /// students" is what the operator does about an empty class in nearly every
  /// case, and they read it above the one write the card proposes.
  ///
  /// The job being the default *also* did — making a bulk apply write nothing
  /// for an empty class — is [DoNotImportFromWisa.canApplyToAll]'s, withheld
  /// since #293 and honoured by every bulk path since #326.
  @override
  String? get noticeFor => classImportAlternative;

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

  /// **Context on the namesake decision, not one of its answers** (#329). It
  /// was the pre-selected half of a radio pair with [DoNotImportFromWisa] from
  /// #250 until then — but "go and make this group official in Smartschool" is
  /// not something an apply can run, so the card asked the operator to choose
  /// between a diagnosis and the single write the app has for the situation.
  ///
  /// The instruction is the whole value of this action and survives intact: it
  /// is stated above [DoNotImportFromWisa]'s own proposal on the card, marked
  /// "(manueel)", with the namesake group's code and official flag beside it so
  /// the operator can go and find it. What it no longer does is claim to be a
  /// resolution.
  ///
  /// Keeping the blacklist out of a bulk pass was the pair's other job, and it
  /// belongs to [DoNotImportFromWisa.canApplyToAll] — withheld since #293,
  /// honoured by every bulk path since #326. That is what holds #250 fixed now
  /// that the polarity is gone.
  @override
  String? get noticeFor => namesakeClassAlternative;

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
          // A fact, not a transition (#306): the code is how the operator
          // finds the group in Smartschool, and this notice writes nothing at
          // all. As a transition it read `code: G2G → ∅` — the code being
          // cleared. Its neighbours here *are* transitions: the rename and the
          // make-it-official are the repair being asked for.
          FieldChange.statement('code', _namesake.id.value),
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

/// An orphan Smartschool class with no matching WISA class **that this app
/// cannot delete for you** — the lone informational row such a class is left
/// with (#328).
///
/// Ported from `Action\Group\DoNotImportFromSmartschool`, whose legacy `Apply`
/// throws `NotImplementedException` — it is **informational only** (legacy
/// `CanBeApplied == false`), so [canApply] is `false` and [apply] throws. Until
/// #313 it was the *only* reading, and its whole content was an instruction to
/// go and delete the class by hand in Smartschool: the dead end #271 removed on
/// the Office 365 side, and a screenful of it at a September changeover. From
/// #313 to #328 it was the pre-selected half of a radio pair whose other half
/// was [DeleteSmartschoolClass].
///
/// **It is neither any more**, exactly as [AzureClassGroupWithoutClass] stopped
/// being either at #327. "Laat deze klas staan" and "doe niets" are the same
/// act, and the operator performs the second one by not pressing **Toepassen**;
/// offering it as a radio asked them to record a non-decision, and made a card
/// proposing exactly one thing read as a question with two answers.
///
/// **The job the polarity did carry is not lost.** Being the default is what
/// kept the delete out of a bulk pass, and that job belongs to
/// [GroupAction.canApplyToAll], which [DeleteSmartschoolClass] withholds (#293)
/// and every bulk affordance honours since #326. The *other* thing the default
/// said — that leaving the class alone is usually right, because early in a
/// school year the WISA snapshot lags the real world and a class the school
/// maintains only in Smartschool reads as a leftover forever — is a fact about
/// the situation, not a resolution to choose. It survives as the line
/// [_wisaMayBeLagging] states on the delete's own card, where the operator
/// reads it before pressing rather than after picking.
///
/// So this now fires **exactly where the delete cannot** — see
/// [_deletableSmartschoolClass] — which in practice means a record naming no
/// class code to address a `delClass` to, or a group that is not an official
/// class. There is then genuinely nothing to offer, and saying so *is* the
/// whole content of the row, marked "(manueel)" like every other informational
/// action.
class DoNotImportFromSmartschool extends GroupAction {
  const DoNotImportFromSmartschool(super.group);

  @override
  bool evaluate() =>
      _smartschoolOnlyClass(group) && !_deletableSmartschoolClass(group);

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Laat deze klas staan — ze bestaat in Smartschool maar niet '
            'in WISA',
        // Nothing is written here, so nothing moves: these lines describe the
        // class the operator is being told about (#305), and are how they find
        // it in Smartschool if they decide to look.
        fields: _smartschoolClassFacts(group.smartschool),
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'DoNotImportFromSmartschool is informational and cannot be applied '
        '(canApply is false)',
      );
}

/// Delete a Smartschool class WISA no longer has (#313) — since #328 the
/// **only** thing such a leftover proposes, not one radio of two.
///
/// Genuinely destructive: `delClass` takes the class, the membership of every
/// student in it, and whatever hangs under it. The same three things hold it in
/// place that hold [DeleteAzureClassGroup] in place, and each of them is
/// tested:
///
/// - **It proposes on exactly the record [_deletableSmartschoolClass]
///   describes** — no WISA class, a Smartschool one — plus a restatement of the
///   linker's own orphan rule: only an **official** Smartschool class ever
///   seeds an orphan record, so an organisational group is already out of scope
///   and must stay out. The restatement is belt-and-braces and deliberately
///   redundant: a delete must not inherit its whole scope from a filter one
///   layer away.
/// - **No bulk affordance may offer it**, because [canApplyToAll] is false and,
///   since #326, both bulk paths read it. This is now the *whole* of that
///   guard: until #328 it leaned on the polarity of a radio pair, which meant
///   two flipped radios could arm a header the flag had already refused.
/// - **The linked record must actually name a class to delete** — a blank
///   Smartschool class code yields no proposal rather than a `delClass` with an
///   empty `code`, and [DoNotImportFromSmartschool] states the situation
///   instead.
///
/// **The card proposes; it does not interrogate.** Losing the pair must not
/// lose the reading the pair's default carried — that a WISA snapshot lagging
/// early in a school year, or a class the school deliberately keeps only in
/// Smartschool, is the *common* cause of a row landing here. That is context on
/// the situation rather than a resolution to pick, so [describeChanges] states
/// it ([_wisaMayBeLagging]) beside the class's own facts. Nothing is written
/// until the operator presses **Dry-run** or **Toepassen** behind the ordinary
/// confirmation, and ignoring the card is a complete answer.
///
/// Deliberately no `unlocks`: nothing follows a delete.
///
/// **What this is not.** Legacy's neighbour here was `Klas Negeren` — a
/// persistent "do not import this class" decision. That is a genuine second
/// resolution rather than the no-op #328 removed: if such a blacklist ever
/// comes back it belongs beside this delete under an alternative key of their
/// own, and it would be the first thing this row ever had to choose *between*.
class DeleteSmartschoolClass extends GroupAction {
  const DeleteSmartschoolClass(super.group);

  @override
  bool evaluate() => _deletableSmartschoolClass(group);

  /// **Never in bulk** (#293), for the reason [DeleteAzureClassGroup] is not:
  /// `delClass` takes the class and everything in it, and a WISA snapshot that
  /// merely lags makes a perfectly live class look like a leftover. Since #328
  /// removed the pair this used to sit in, this flag is the only thing keeping
  /// the delete off every bulk path — and #326 is what makes every one of them
  /// ask.
  @override
  bool get canApplyToAll => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.smartschool,
        summary: 'Verwijder de klas ${_ss.name} uit Smartschool — ze bestaat '
            'niet in WISA',
        // What the delete takes with it, stated (#305). The summary already
        // says the class goes; these lines are the inventory of it, and an
        // arrow on each would claim three separate fields were being cleared.
        // The caution sits with the class's own facts rather than with that
        // inventory: it is why the operator might not press at all (#328).
        fields: [
          ..._smartschoolClassFacts(group.smartschool),
          _wisaMayBeLagging,
          const FieldChange.statement(
            'lidmaatschappen en subgroepen',
            'verdwijnen mee',
          ),
        ],
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
        system: Origin.smartschool,
        removed: true,
      );
    }

    try {
      // The same code `saveClass` writes and `ModifySmartschoolData` addresses
      // its rewrite to — the class's own Smartschool code, not its name.
      final ok =
          await _requireSmartschool(connectors).deleteClass(_ss.id.value);
      if (!ok) {
        return _failed(
          changes,
          Origin.smartschool,
          StateError('Smartschool delClass returned failure'),
        );
      }
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.smartschool,
        removed: true,
      );
    } on ss.SmartschoolSoapFault catch (e) {
      // `delClass` currently dies inside Smartschool on a PHP fatal error
      // (`Undefined constant "Smsc\Legacy\Core\_THE_OFFICIAL_CLASS"`, #361),
      // which comes back as a server-side SOAP Fault on a 500. Their defect,
      // not ours: the request is the documented two-argument call, so the same
      // press tomorrow fails identically. Saying so — and naming the one thing
      // that does clear the class — is the difference between a failure an
      // operator can act on and one they retry every pass. Reporting it to
      // Smartschool is #364; nothing here changes when they fix it.
      //
      // Only a *server* fault earns this. A `Client` fault says Smartschool
      // read our request and refused it, which is ours to fix and not
      // something to send anybody into the web UI over.
      if (!e.isServerFault) return _failed(changes, Origin.smartschool, e);
      return _failed(
        changes,
        Origin.smartschool,
        StateError(
          'Smartschool kon de klas ${_ss.name} niet verwijderen: '
          // Redacted for the same reason the fault's own `toString` is: this
          // is server-authored text and it may quote what we sent.
          '"${ss.redactAccessCode(e.faultString)}". Dat is een fout aan de '
          'kant van Smartschool, niet in wat wij verstuurden — opnieuw '
          'toepassen lost ze niet op. Verwijder de klas voorlopig manueel in '
          'Smartschool.',
        ),
      );
    } on Object catch (e) {
      return _failed(changes, Origin.smartschool, e);
    }
  }
}

/// Whether [group] is a Smartschool class WISA does not have (#52/#313) — the
/// one condition [DoNotImportFromSmartschool] and [DeleteSmartschoolClass]
/// share.
///
/// One definition rather than two copies, because the two readings partition
/// it: [_deletableSmartschoolClass] is the half the delete proposes on and the
/// notice is exactly the remainder, so a leftover class raises one row and
/// never none or two.
///
/// It asks the linker's own question and no stricter one, exactly as
/// [_staleClassGroup] does on the Azure side: the record is on screen because
/// `link()` seeded an orphan for an official Smartschool class it could match to
/// nothing in WISA, and this restates that and nothing else.
bool _smartschoolOnlyClass(LinkedGroup group) =>
    group.wisa == null && group.smartschool != null;

/// Whether [group] is a Smartschool leftover this app can actually **delete**
/// (#328) — [_smartschoolOnlyClass] plus the two things a `delClass` needs: an
/// official class rather than an organisational group, and a code to address
/// the call to.
///
/// Written out as a predicate of its own rather than folded into
/// [DeleteSmartschoolClass.evaluate], for the reason [_deletableStaleClassGroup]
/// is: it is the line the two readings of a leftover class are drawn on. The
/// delete proposes exactly where this holds, and [DoNotImportFromSmartschool]
/// states its "(manueel)" notice exactly where it does not. Expressed once,
/// "the notice fires when the delete cannot" cannot drift into a second,
/// differently-worded copy of this guard.
///
/// The official-class test restates the linker's own orphan rule deliberately:
/// a delete must not inherit its whole scope from a filter one layer away.
bool _deletableSmartschoolClass(LinkedGroup group) {
  final smartschool = group.smartschool;
  return _smartschoolOnlyClass(group) &&
      smartschool!.official &&
      smartschool.id.value.trim().isNotEmpty;
}

/// Why a class can sit in Smartschool with no WISA counterpart and still be
/// perfectly live (#328) — stated on [DeleteSmartschoolClass]'s card, never
/// offered as a resolution.
///
/// This is the reading the pre-selected "laat deze klas staan" used to carry,
/// and the whole reason the Smartschool leftovers were weighed separately from
/// the Office 365 ones: early in a school year the WISA snapshot lags the real
/// world, so a legitimately new class reads as Smartschool-only until WISA
/// catches up, and a class the school deliberately maintains only in
/// Smartschool reads that way forever. The operator needs it *before* pressing,
/// which is a sentence on the card — not a radio recording that they chose not
/// to act.
const FieldChange _wisaMayBeLagging = FieldChange.statement(
  'WISA',
  'kent deze klas (nog) niet — vroeg in het schooljaar loopt WISA achter, '
      'controleer daar of ze bestaat voor je ze verwijdert',
);

/// The facts both readings of a Smartschool leftover class state about the
/// class they are describing (#305) — stated, never diffed.
///
/// Each is stated only when the class carries it: an empty statement renders as
/// a bare `code: ` under the heading, a label for a fact that is not there.
List<FieldChange> _smartschoolClassFacts(Group? smartschool) {
  final code = smartschool?.id.value.trim() ?? '';
  final description = smartschool?.description.trim() ?? '';
  return <FieldChange>[
    // How the operator finds the class in Smartschool, and what a `delClass`
    // is addressed to.
    if (code.isNotEmpty) FieldChange.statement('code', code),
    if (description.isNotEmpty)
      FieldChange.statement('omschrijving', description),
  ];
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

  /// **In bulk** (#293). Three mechanical field copies — institute number and
  /// description down from WISA, Untis converged to the class name — with no
  /// judgement in any of them, and Untis drift in particular tends to show up
  /// across a whole year's classes at once.
  @override
  bool get canApplyToAll => true;

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
        // Same as [AddToSmartschool]: the institute number this action syncs is
        // WISA's answer for the werkdatum, so it is written for that school
        // year (#339). Without it the one action whose whole job is to correct
        // an institute number corrects the *wrong year's*.
        schoolYearDate: options.workDate,
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

  /// The roster write lands in Office 365 too, so the chain reaches no system
  /// this action does not already name — the confirmation dialog has nothing
  /// extra to announce for it (#234).
  @override
  Set<Origin> get unlockedSystems => const {Origin.azure};

  /// **In bulk** (#293). Provisioning, and provisioning that arrives a year at a
  /// time: every new class needs its Office 365 group, and both the name and
  /// the membership are derived — the [AzureClassGroupPlan] answers each of
  /// them, and a class whose name would not survive as a `mailNickname` yields
  /// no proposal to bulk-apply in the first place.
  @override
  bool get canApplyToAll => true;

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
        // Advice the operator can act on, since #280: the Azure pull now looks
        // the expected `<PREFIX>-<KLAS>` addresses up directly, so the next
        // synchronisation really does adopt this group. Before that back-fill
        // existed, a group whose display name had been renamed by hand was
        // invisible to every pull, and this message sent the operator around a
        // loop that could not end. In Dutch, because #272 put it on the class
        // card where an operator reads it.
        return _failed(
          changes,
          Origin.azure,
          StateError(
            'Office 365 heeft al een groep op het adres ${plan.mailNickname} '
            '("${existing.displayName}"). Synchroniseer Azure opnieuw: die '
            'groep wordt dan overgenomen in plaats van dat er een dubbele '
            'wordt aangemaakt.',
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
/// **The class roster decides membership outright** (#389): every current
/// member WISA does not put in this class is removed, whatever is stamped on the
/// account. That reaches the cases a narrower rule structurally could not — a
/// sibling group school's pupil, or an account with no school stamp at all —
/// because those are never in the prefix-scoped Azure read and so could never be
/// *named*. See [AzureClassGroupPlan.membersToRemove].
///
/// Teachers are kept out of this by **which groups get a plan at all**, not by
/// filtering members: class groups hold students only by policy, a teacher who
/// needs access is an *owner* rather than a member, and a plan is built only for
/// a group whose `<PREFIX>-<KLAS>` name is a real WISA class — never for the
/// subject groups (`SSM-1C-Wiskunde-2526`) that do hold staff.
///
/// **It never proposes on a group Graph will not manage** (#331). A group
/// mastered by Exchange Online — a mail-enabled security group, or a
/// distribution list — refuses every add and every remove, so a diff on one is
/// not work: it is a proposal that fails wholesale, is re-offered on the next
/// pass, and can never be got rid of. [AzureClassGroupNotManageable] states the
/// situation there instead, and the two partition the same condition, so a class
/// raises one row and never none or two.
class SyncAzureClassGroupMembers extends GroupAction {
  /// The Office 365 naming + roster context, injected by the dispatch.
  final AzureClassGroupPlan plan;

  const SyncAzureClassGroupMembers(super.group, this.plan);

  az.AzureGroup get _azure => group.azure! as az.AzureGroup;

  @override
  bool evaluate() =>
      _classGroupMembershipDiffers(group, plan) &&
      _canManageClassGroupMembership(group);

  /// **In bulk — the group family's headline grant** (#293), and the one this
  /// flag was decided on explicitly rather than by analogy.
  ///
  /// At the September rollover every class's Office 365 roster is wrong at once,
  /// for the same reason every student's Smartschool class is: the classes
  /// turned over. Applying this one action across the school in a single pass is
  /// exactly the operation the rollover needs, and it is safe to do so on three
  /// counts — the diff is computed per class from the roster the app already
  /// holds, it is idempotent (a class already in sync does not
  /// [evaluate] true, and re-running writes the same membership), and its
  /// the groups it can reach are only those whose `<PREFIX>-<KLAS>` name is a
  /// real WISA class, so a bulk pass never opens a subject or staff group at
  /// all. That last count is what carries the safety since #389 turned removals
  /// into the plain roster comparison: the protection is which groups are
  /// planned for, not which members are spared inside them. A class whose
  /// students have no Azure accounts yet withholds its removals rather than
  /// proposing to empty the group — see [AzureClassGroupPlan.membersToRemove].
  ///
  /// The counterpart per-account view, `AzureClassGroupMembership`, stays
  /// informational precisely so this class-level write is the single place the
  /// membership is repaired — bulk or not.
  @override
  bool get canApplyToAll => true;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Werk het ledenbestand van ${plan.displayName} bij '
            '(${plan.membersToAdd.length} toevoegen, '
            '${plan.membersToRemove.length} verwijderen)',
        // Counts, not transitions (#300): "21 members will be added" is a
        // quantity this write acts on, and describing it as a field whose old
        // value was empty and whose new value is 21 describes nothing that
        // happens to this group.
        fields: [
          if (plan.membersToAdd.isNotEmpty)
            FieldChange.count('leden toevoegen', plan.membersToAdd.length),
          if (plan.membersToRemove.isNotEmpty)
            FieldChange.count('leden verwijderen', plan.membersToRemove.length),
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
      // What Graph said, not merely how often it said no (#330). A count alone
      // is unactionable — it was the whole of what the operator got when
      // `SSM-1A` turned out to be a group Graph will not manage the membership
      // of (#331) — so the first refusal's status and error code ride along,
      // and a batch that failed for *mixed* reasons says how many other kinds
      // there were rather than pretending the first explains all of them.
      final report = az.BatchReport(results);
      if (report.hasFailures) {
        final reasons = report.reasons;
        final extra = reasons.length > 1
            ? ' (+${reasons.length - 1} other error(s))'
            : '';
        return _failed(
          changes,
          Origin.azure,
          StateError(
            '${report.failureCount} of ${report.total} membership change(s) on '
            '${plan.displayName} failed — ${reasons.first}$extra',
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

/// A class whose Office 365 group **Graph will not manage the membership of**
/// (#331) — the lone informational row such a class is left with, where
/// [SyncAzureClassGroupMembers] used to propose a write that could never land.
///
/// The reported bug, and the shape of it: `SSM-1A` in the live tenant is a
/// **mail-enabled security group** — `mailEnabled: true`, `securityEnabled:
/// true`, `groupTypes: []` — the one such group among the school's 372. Its
/// membership is Exchange Online's, not the directory's, so all 38 additions and
/// removals came back refused, the class card reported *"38 of 38 membership
/// change(s) failed"*, and the identical proposal returned on the next pass,
/// forever. The other 371 groups are Microsoft 365 groups (255) or plain
/// security groups (116), both of which Graph manages, which is why exactly one
/// class in the school misbehaved.
///
/// The app could not see the difference until #331: `graphSelectFields`
/// requested neither `mailEnabled` nor `groupTypes`, and `isUnified` was
/// inferred from `securityEnabled` + `mail`. Reading the two fields Graph
/// actually answers with is what makes this row possible
/// ([az.AzureGroup.canManageMembership]).
///
/// **Informational** (`canApply == false`), like every other row whose remedy
/// lives in another system: there is no automated write, and inventing one would
/// mean the app doing in Exchange what the operator must decide. The two ways
/// out are stated on the card — manage the members in Exchange Online, or
/// replace the group with a Microsoft 365 one, after which the app takes the
/// class over again (a mail-enabled security group cannot be *converted*, so
/// "replace" means freeing the address and letting [CreateAzureClassGroup] make
/// the group it would have made).
///
/// It fires **exactly where the sync cannot**, on the same
/// [_classGroupMembershipDiffers] condition: a class whose roster already
/// matches has nothing to say, however the group is mastered.
class AzureClassGroupNotManageable extends GroupAction {
  /// The Office 365 naming + roster context, injected by the dispatch.
  final AzureClassGroupPlan plan;

  const AzureClassGroupNotManageable(super.group, this.plan);

  az.AzureGroup get _azure => group.azure! as az.AzureGroup;

  @override
  bool evaluate() =>
      _classGroupMembershipDiffers(group, plan) &&
      !_canManageClassGroupMembership(group);

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'De Office 365-groep ${plan.displayName} is een '
            '${_exchangeGroupKind(_azure)}. Graph kan haar ledenlijst niet '
            'beheren. Beheer de leden in Exchange Online, of vervang de groep '
            'door een Microsoft 365-groep, dan neemt de app de klas weer over.',
        // Nothing is written here, so nothing moves (#305/#306): these lines
        // describe the group the operator is being sent to Exchange Online for,
        // and how far its roster has drifted while nobody could write to it.
        fields: [
          FieldChange.statement('type', _exchangeGroupKind(_azure)),
          if ((_azure.mail ?? '').trim().isNotEmpty)
            FieldChange.statement('mail', _azure.mail!.trim()),
          FieldChange.statement(
            'niet gesynchroniseerd',
            '${plan.membersToAdd.length} toe te voegen, '
                '${plan.membersToRemove.length} te verwijderen',
          ),
        ],
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'AzureClassGroupNotManageable is informational and cannot be applied '
        '(canApply is false) — Graph refuses every membership write on an '
        'Exchange-mastered group',
      );
}

/// An Office 365 class group whose class no longer exists in WISA or
/// Smartschool (#228) **and that this app cannot delete for you** — the lone
/// informational row such a group is left with (#327).
///
/// Informational (`canApply == false`), so it is the reading under which
/// nothing is written: it is the Azure analogue of the Smartschool orphan notice
/// [DoNotImportFromSmartschool]. Until #271 it was the *only* reading — it told
/// the operator to delete the group by hand — which left the class inventory
/// carrying rows whose whole content was an instruction to go elsewhere. From
/// #271 to #327 it was the pre-selected half of a radio pair whose other half
/// was [DeleteAzureClassGroup].
///
/// **It is neither any more.** "Laat de Office 365-groep staan" and "doe niets"
/// are the same act, and the operator performs the second one by not pressing
/// **Toepassen**; offering it as a radio asked them to record a non-decision,
/// and made a card proposing exactly one thing read as a question with two
/// answers — two sentences to read per stale group to discover that one of them
/// means "nothing happens". Being the pair's default did carry a second job,
/// keeping the delete out of a bulk pass, but that job belongs to
/// [GroupAction.canApplyToAll]: [DeleteAzureClassGroup] withholds the sanction
/// (#293) and since #326 every bulk affordance honours it, so the polarity
/// trick is redundant and the guard is stated where it is enforced.
///
/// So this now fires **exactly where the delete cannot** — see
/// [_deletableStaleClassGroup] — which means a linked record naming no Azure
/// object id to address a `DELETE /groups/` to, or (since #331) a group
/// Exchange Online masters rather than the directory. There is then genuinely
/// nothing to offer, and saying so *is* the whole content of the row, marked
/// "(manueel)" like every other informational action. In the Exchange case the
/// row also says *why* and where to go instead — [_staleGroupFacts] states the
/// group's shape beside its address.
///
/// It is narrow, but no narrower than the linker's own orphan rule: an
/// unmatched Azure group is reported when the name it answers on inside the
/// school's `<PREFIX>-` namespace is *shaped like a class* — the one signal
/// #228 made available and the only one [_staleClassGroup] reads (#312).
/// Anything outside the namespace, and anything prefixed that is not
/// class-shaped (`SSM-GOK`, `SSM-Personeel`), is left unmentioned by *both*
/// readings rather than filling the Klasgroepen list with rows nobody will act
/// on (the clutter #209/#225/#271 fixed).
class AzureClassGroupWithoutClass extends GroupAction {
  const AzureClassGroupWithoutClass(super.group);

  az.AzureGroup? get _azure => group.azure as az.AzureGroup?;

  @override
  bool evaluate() =>
      _staleClassGroup(group) && !_deletableStaleClassGroup(group);

  @override
  bool get canApply => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Laat de Office 365-groep ${_azure?.displayName} staan — '
            'klas ${group.className} bestaat niet meer in WISA of Smartschool',
        // Nothing is written here, so nothing moves: these lines describe the
        // group the operator is being told about (#305). Put through the
        // before → after template they read `mail: GBS-9Z@… → ∅` and
        // `leden: 21 → ∅` — the address and the members going away, which is
        // what the *other* half of this either/or does.
        fields: _staleGroupFacts(_azure),
      );

  @override
  Future<ActionResult> apply(Connectors connectors, ApplyOptions options) =>
      throw UnsupportedError(
        'AzureClassGroupWithoutClass is informational and cannot be applied '
        '(canApply is false)',
      );
}

/// Delete the Office 365 group of a class that no longer runs (#271) — since
/// #327 the **only** thing a stale class group proposes, not one radio of two.
///
/// Genuinely destructive, and the only group action that is: Graph deletes the
/// group together with its mailbox and history, its Team, and its SharePoint
/// files. Three things therefore hold it in place, and each of them is tested:
///
/// - **It proposes on exactly the record [_deletableStaleClassGroup]
///   describes** — Azure-only, carrying a class name the linker recovered from
///   inside the school's `<PREFIX>-` namespace, plus a restatement of that
///   predicate's own shape guard ([looksLikeClassName]). The restatement is
///   belt-and-braces and deliberately redundant: a delete must not inherit its
///   whole scope from a predicate it does not spell out.
/// - **No bulk affordance may offer it**, because [canApplyToAll] is false and,
///   since #326, both bulk paths read it. This is now the *whole* of that
///   guard: until #327 it leaned on the polarity of a radio pair, which meant
///   two flipped radios could arm a header the flag had already refused.
/// - **The linked record must actually name a group to delete** — a blank Azure
///   object id yields no proposal rather than a `DELETE /groups/`, and
///   [AzureClassGroupWithoutClass] states the situation instead.
///
/// Nothing is written until the operator presses **Dry-run** or **Toepassen**
/// on this card, behind the ordinary confirmation — which is why
/// [describeChanges] carries the inventory of what goes with the group rather
/// than the summary alone.
///
/// Deliberately no `unlocks`: nothing follows a delete.
class DeleteAzureClassGroup extends GroupAction {
  const DeleteAzureClassGroup(super.group);

  az.AzureGroup? get _azure => group.azure as az.AzureGroup?;

  @override
  bool evaluate() => _deletableStaleClassGroup(group);

  /// **Never in bulk** (#293), and the clearest case in the whole port: Graph
  /// takes the group's mailbox, its Team and its SharePoint files with it, and
  /// none of that comes back. Since #327 removed the pair this used to sit in,
  /// this flag is the only thing keeping the delete off every bulk path — and
  /// #326 is what makes every one of them ask.
  @override
  bool get canApplyToAll => false;

  @override
  ChangeSet describeChanges() => ChangeSet(
        system: Origin.azure,
        summary: 'Verwijder de Office 365-groep ${_azure?.displayName} van de '
            'verdwenen klas ${group.className}',
        // What the delete takes with it, stated (#305). The summary above
        // already says the group goes; these lines are the inventory of it, and
        // an arrow on each one claimed three separate fields were being
        // cleared — least of all `postvak, Teams en bestanden: verdwijnen
        // mee → ∅`, which was never a value in the first place.
        fields: [
          ..._staleGroupFacts(_azure),
          const FieldChange.statement(
            'postvak, Teams en bestanden',
            'verdwijnen mee',
          ),
        ],
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
        removed: true,
      );
    }

    try {
      await _requireAzure(connectors).groups.deleteGroup(_azure!.id);
      return ActionResult(
        outcome: ActionOutcome.applied,
        changes: changes,
        system: Origin.azure,
        removed: true,
      );
    } on Object catch (e) {
      return _failed(changes, Origin.azure, e);
    }
  }
}

/// Whether the class's Office 365 group has a roster to reconcile at all
/// (#228) — the one condition [SyncAzureClassGroupMembers] and
/// [AzureClassGroupNotManageable] share.
///
/// One definition rather than two copies, because the two readings partition
/// it: [_canManageClassGroupMembership] is the half the write proposes on and
/// the notice is exactly the remainder, so a class raises one row and never
/// none or two — the same shape the stale-group and leftover-class pairs are
/// drawn in.
bool _classGroupMembershipDiffers(
  LinkedGroup group,
  AzureClassGroupPlan plan,
) =>
    plan.owner && group.azure != null && plan.membershipDiffers;

/// Whether Graph will manage the membership of [group]'s Office 365 group
/// (#331) — false for the Exchange-mastered shapes, which refuse every add and
/// every remove.
///
/// A record carrying no concrete connector group answers `true`: there is
/// nothing to refuse, and the linked-record model is not where a missing group
/// is diagnosed.
bool _canManageClassGroupMembership(LinkedGroup group) {
  final azure = group.azure;
  return azure is! az.AzureGroup || azure.canManageMembership;
}

/// What to call an Exchange-mastered group on a card (#331). The two shapes read
/// very differently to an operator looking for the group in Exchange Online, and
/// `securityEnabled` is what tells them apart.
String _exchangeGroupKind(az.AzureGroup azure) => azure.securityEnabled
    ? 'mail-enabled beveiligingsgroep'
    : 'distributielijst';

/// Whether [group] is an Office 365 class group left behind by a class that no
/// longer exists anywhere (#228/#271) — the one condition
/// [AzureClassGroupWithoutClass] and [DeleteAzureClassGroup] share.
///
/// One definition rather than two copies, because the two readings partition
/// it: [_deletableStaleClassGroup] is the half the delete proposes on and the
/// notice is exactly the remainder, so a stale group raises one row and never
/// none or two.
///
/// **It reads the linker's own orphan rule, not a second, stricter one**
/// (#312). [LinkedGroup.className] on an Azure-only record is exactly the bare
/// name `azureClassNameOf` recovered from the group's `displayName` *or* its
/// `mailNickname` (#280), stamped by the linker only when that name is
/// class-shaped. Testing that same name here is therefore the whole condition:
/// the record is on screen because the linker judged it a stale class group,
/// and this asks the identical question rather than a narrower one.
///
/// Two guards used to sit on top of it, and between them they silenced the
/// delete on every group the operator most wanted it for:
///
/// - `azure.isUnified` — the class groups the **legacy WPF app** created are
///   plain security groups with no address at all (`SSM-3ECO`, `SSM-3MRP`,
///   `SSM-3MWW`, … are `securityEnabled: true, mail: null` in the live tenant),
///   so the port refused to name any group it had not created itself. The
///   `<PREFIX>-` namespace plus the class-name shape is what makes a group
///   ours, not its mail-enablement — and `SSM-Personeel`, the security/plain
///   pair the guard was worried about, fails the name shape on its own.
/// - `mailNickname == displayName` — a group renamed by hand in the portal
///   fails it, which re-derives the opposite of #280's conclusion that the
///   address is the identity signal and the display name is not to be trusted.
bool _staleClassGroup(LinkedGroup group) {
  final azure = group.azure;
  return group.wisa == null &&
      group.smartschool == null &&
      azure is az.AzureGroup &&
      looksLikeClassName(group.className);
}

/// Whether [group] is a stale class group this app can actually **delete**
/// (#327) — [_staleClassGroup] plus the two things a `DELETE /groups/{id}`
/// needs: a class-shaped name, and an object id to address the request to.
///
/// Written out as a predicate of its own rather than folded into
/// [DeleteAzureClassGroup.evaluate], because it is the line the two readings of
/// a stale group are drawn on: the delete proposes exactly where this holds,
/// and [AzureClassGroupWithoutClass] states its "(manueel)" notice exactly
/// where it does not. Expressed once, "the notice fires when the delete cannot"
/// cannot drift into a second, differently-worded copy of this guard.
///
/// The name-shape test is a restatement of one [_staleClassGroup] already
/// makes, deliberately: a delete must not inherit its whole scope from a
/// predicate it does not spell out. So the cases this genuinely separates off
/// are the blank object id and, since #331, the **Exchange-mastered** group: a
/// mail-enabled security group or a distribution list is not the directory's to
/// delete either, so proposing `DELETE /groups/{id}` on one is the same doomed
/// write the membership sync used to offer. The notice states it instead — see
/// [_staleGroupFacts], which names the reason there.
bool _deletableStaleClassGroup(LinkedGroup group) {
  final azure = group.azure as az.AzureGroup?;
  return _staleClassGroup(group) &&
      looksLikeClassName(group.className) &&
      (azure?.id.trim().isNotEmpty ?? false) &&
      !(azure?.isExchangeManaged ?? false);
}

/// The facts both readings of a stale Office 365 class group state about the
/// group they are describing (#305) — stated, never diffed.
///
/// The address is stated only when there is one: a legacy class group is a
/// security group carrying no `mail` (#312), and an empty statement renders as
/// a bare `mail: ` under the heading — a label for a fact the group does not
/// have.
///
/// The management line is the same kind of conditional fact (#331). It appears
/// only on an Exchange-mastered group, which is exactly where the delete cannot
/// fire — so in practice only [AzureClassGroupWithoutClass] ever shows it, and
/// it is the difference between "nothing can be done here" and knowing *why*
/// and *where* to go and do it.
List<FieldChange> _staleGroupFacts(az.AzureGroup? azure) {
  final mail = azure?.mail?.trim() ?? '';
  return <FieldChange>[
    if (mail.isNotEmpty) FieldChange.statement('mail', mail),
    if (azure != null && azure.isExchangeManaged)
      FieldChange.statement(
        'beheer',
        '${_exchangeGroupKind(azure)} — Graph beheert deze groep niet; '
            'verwijder ze in Exchange Online',
      ),
    FieldChange.statement('leden', '${azure?.memberIds.length ?? 0}'),
  ];
}
