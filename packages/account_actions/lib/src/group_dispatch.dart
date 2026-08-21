import 'package:account_core/account_core.dart';

import 'group_action.dart';
import 'group_placement.dart';

/// Derives the applicable [GroupAction]s for one [LinkedGroup], ported from the
/// legacy `GroupActionParser.AddActions` dispatch (§6.3).
///
/// The two action sets are **mutually exclusive**, exactly as in legacy, but
/// the split is on the WISA/Smartschool pair rather than all three systems
/// (there is no Azure group action):
/// - If the class is missing from WISA **or** Smartschool, the lifecycle-style
///   actions ([DoNotImportFromWisa], [ClassExistsAsSmartschoolGroup],
///   [AddToSmartschool], [CreateInSmartschool], [DoNotImportFromSmartschool])
///   are considered — in that legacy order, so a WISA-only class raises both
///   [DoNotImportFromWisa] and exactly one of [AddToSmartschool] /
///   [CreateInSmartschool].
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
/// An Azure-only orphan group (`wisa == null && smartschool == null`, #52)
/// yields no action.
///
/// Each candidate is constructed bound to [group] and kept only when its pure
/// [GroupAction.evaluate] returns true. Pure and deterministic (INV-40): same
/// group (+ same [placementFor]) ⇒ same list.
List<GroupAction> groupActionsFor(
  LinkedGroup group, {
  GroupPlacement Function(LinkedGroup group)? placementFor,
}) {
  final both = group.wisa != null && group.smartschool != null;
  final wisaOnly = group.wisa != null && group.smartschool == null;

  final placement =
      (placementFor != null && wisaOnly) ? placementFor(group) : null;

  final candidates = both
      ? <GroupAction>[
          ModifySmartschoolData(group),
        ]
      : <GroupAction>[
          DoNotImportFromWisa(group),
          ClassExistsAsSmartschoolGroup(group),
          if (placement != null) AddToSmartschool(group, placement),
          if (placement != null) CreateInSmartschool(group, placement),
          DoNotImportFromSmartschool(group),
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
/// [groupActionsFor] to enable the membership-dependent creation actions (#65).
List<GroupAction> groupActions(
  LinkedSnapshot snapshot, {
  GroupPlacement Function(LinkedGroup group)? placementFor,
}) =>
    [
      for (final group in snapshot.groups)
        ...groupActionsFor(group, placementFor: placementFor),
    ];
