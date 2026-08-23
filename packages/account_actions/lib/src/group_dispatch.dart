import 'package:account_core/account_core.dart';

import 'azure_class_group.dart';
import 'group_action.dart';
import 'group_placement.dart';

/// Derives the applicable [GroupAction]s for one [LinkedGroup], ported from the
/// legacy `GroupActionParser.AddActions` dispatch (§6.3).
///
/// The two action sets are **mutually exclusive**, exactly as in legacy, but
/// the split is on the WISA/Smartschool pair rather than all three systems
/// (there is no Azure group action):
/// - If the class is missing from WISA **or** Smartschool, the lifecycle-style
///   actions ([ClassExistsAsSmartschoolGroup], [AddToSmartschool],
///   [CreateInSmartschool], [DoNotImportFromWisa],
///   [DoNotImportFromSmartschool], [DeleteSmartschoolClass]) are considered, so
///   a WISA-only class raises [DoNotImportFromWisa] *and* exactly one of
///   [AddToSmartschool] / [CreateInSmartschool]. Those two are not two to-dos:
///   they share the [classImportAlternative] key, so the pending list renders
///   them as one either/or choice and an apply runs only the picked one (#244).
///   Legacy ordered [DoNotImportFromWisa] first; it now trails the create it is
///   an alternative to, so the create leads the radio pair. A **Smartschool-only**
///   class is the mirror image: it yields [DeleteSmartschoolClass] (#313) —
///   **one action, no radio pair** since #328 — where the class is official and
///   names a code, and the informational [DoNotImportFromSmartschool] as a lone
///   "(manueel)" row where it is not.
/// - If it is present in both, only [ModifySmartschoolData] is considered.
///
/// [ClassExistsAsSmartschoolGroup] (#225) sits where the two create actions
/// would: it fires exactly when the class already exists in Smartschool under a
/// group the linker could not adopt ([LinkedGroup.smartschoolNamesake]), which
/// is the same condition those two now refuse on. Unlike them it needs no
/// placement — the situation is a property of the record alone — so it is
/// raised whether or not [placementFor] is wired, and a WISA-only class is
/// never left with a create proposal as its only reading.
///
/// Taking the create's place means taking its side of the either/or too (#250):
/// the notice and [DoNotImportFromWisa] share [namesakeClassAlternative], a key
/// of their own so the namesake classes are not bulk-applied together with the
/// genuinely new ones. Without it the blacklist was the *lone* member of
/// [classImportAlternative] on such a class, hence always selected, and "Apply
/// to all" wrote a `DontImportClass` rule on the class the notice beside it had
/// just said to fix by hand.
///
/// [placementFor] wires the membership-dependent creation actions (#65). When
/// supplied it is called for each WISA-only class (`wisa != null &&
/// smartschool == null`) to build its [GroupPlacement]: the membership signal
/// selects [AddToSmartschool] (class has students) or [CreateInSmartschool]
/// (empty), and the resolved parent lets [AddToSmartschool] place the new class.
/// When omitted, the dispatch is exactly as it shipped in #54 — no create
/// actions — because a [LinkedGroup] alone cannot answer "does the WISA class
/// have students?". It is only called for WISA-only classes; a both-present or
/// Smartschool-only class never needs it.
///
/// [azurePlanFor] wires the **Office 365 class-group** actions (#228). Unlike
/// [placementFor] it is consulted for *every* record, not only the WISA-only
/// ones: a class that is perfectly in sync between WISA and Smartschool still
/// needs its `<PREFIX>-<KLAS>` group created and its membership kept equal to
/// the roster, so [CreateAzureClassGroup] and [SyncAzureClassGroupMembers] are
/// candidates in both branches. The builder returns `null` for a record that
/// names no Office 365 class group (an orphan with no WISA class, or a class
/// name that cannot form a mail nickname), and marks exactly one record per
/// distinct bare class name as the [AzureClassGroupPlan.owner] so a sub-grouped
/// class raises one proposal rather than one per sub-group. When omitted, the
/// dispatch is exactly as it shipped before #228.
///
/// An Azure-only orphan group (`wisa == null && smartschool == null`, #52)
/// yields [DeleteAzureClassGroup] (#271) — **one action, no radio pair** since
/// #327 — and only when it is shaped like a group this app created; anything
/// else still yields nothing. Where the delete cannot fire because the record
/// names no Azure object id, the informational
/// [AzureClassGroupWithoutClass] states that instead, as a lone "(manueel)"
/// row. The two are mutually exclusive rather than alternatives: what keeps a
/// delete (which takes the group's mailbox, Team and files with it) out of
/// every bulk pass is [GroupAction.canApplyToAll] (#293/#326), not the polarity
/// of a pair.
///
/// Each candidate is constructed bound to [group] and kept only when its pure
/// [GroupAction.evaluate] returns true. Pure and deterministic (INV-40): same
/// group (+ same [placementFor] / [azurePlanFor]) ⇒ same list.
List<GroupAction> groupActionsFor(
  LinkedGroup group, {
  GroupPlacement Function(LinkedGroup group)? placementFor,
  AzureClassGroupPlan? Function(LinkedGroup group)? azurePlanFor,
}) {
  final both = group.wisa != null && group.smartschool != null;
  final wisaOnly = group.wisa != null && group.smartschool == null;

  final placement =
      (placementFor != null && wisaOnly) ? placementFor(group) : null;
  final azurePlan = azurePlanFor?.call(group);

  final candidates = <GroupAction>[
    if (both)
      ModifySmartschoolData(group)
    else ...[
      // Whichever reading of the class fires — the namesake notice (#250) or a
      // create (#244) — it leads the [DoNotImportFromWisa] it is mutually
      // exclusive with: the order is the order the operator reads the radio
      // pair in, and the fallback the grouping uses if a default is ever
      // forgotten, so the blacklist is never first.
      ClassExistsAsSmartschoolGroup(group),
      if (placement != null) AddToSmartschool(group, placement),
      if (placement != null) CreateInSmartschool(group, placement),
      DoNotImportFromWisa(group),
      // The Smartschool-leftover readings (#313/#328). Not an either/or: their
      // predicates partition the leftovers, so at most one of the two ever
      // survives `evaluate` for a given record — the delete where it can act,
      // the "(manueel)" notice where it cannot. The delete leads because it is
      // the ordinary case; the order carries no other meaning here, since these
      // two never appear on one card together.
      DeleteSmartschoolClass(group),
      DoNotImportFromSmartschool(group),
    ],
    // The Office 365 group of a class is orthogonal to its Smartschool state,
    // so these ride alongside both branches (#228).
    if (azurePlan != null) ...[
      CreateAzureClassGroup(group, azurePlan),
      SyncAzureClassGroupMembers(group, azurePlan),
    ],
    // The stale-group readings (#271/#327). Not an either/or: their predicates
    // partition the stale groups, so at most one of the two ever survives
    // `evaluate` for a given record — the delete where it can act, the
    // "(manueel)" notice where it cannot. The delete leads because it is the
    // ordinary case; the order carries no other meaning here, since these two
    // never appear on one card together.
    DeleteAzureClassGroup(group),
    AzureClassGroupWithoutClass(group),
  ];

  return [
    for (final action in candidates)
      if (action.evaluate()) action,
  ];
}

/// Derives every applicable [GroupAction] across a [LinkedSnapshot]'s class
/// groups, in snapshot order (§6.3). Pure and deterministic.
///
/// Only [LinkedSnapshot.groups] are considered; students and staff are handled
/// by their own families. [placementFor] is threaded through to
/// [groupActionsFor] to enable the membership-dependent creation actions (#65),
/// and [azurePlanFor] to enable the Office 365 class-group actions (#228).
List<GroupAction> groupActions(
  LinkedSnapshot snapshot, {
  GroupPlacement Function(LinkedGroup group)? placementFor,
  AzureClassGroupPlan? Function(LinkedGroup group)? azurePlanFor,
}) =>
    [
      for (final group in snapshot.groups)
        ...groupActionsFor(
          group,
          placementFor: placementFor,
          azurePlanFor: azurePlanFor,
        ),
    ];
