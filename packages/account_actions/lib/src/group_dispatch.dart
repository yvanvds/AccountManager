import 'package:account_core/account_core.dart';

import 'group_action.dart';

/// Derives the applicable [GroupAction]s for one [LinkedGroup], ported from the
/// legacy `GroupActionParser.AddActions` dispatch (§6.3).
///
/// The two action sets are **mutually exclusive**, exactly as in legacy, but
/// the split is on the WISA/Smartschool pair rather than all three systems
/// (there is no Azure group action):
/// - If the class is missing from WISA **or** Smartschool, the lifecycle-style
///   actions ([DoNotImportFromWisa], [DoNotImportFromSmartschool]) are
///   considered.
/// - If it is present in both, only [ModifySmartschoolData] is considered.
///
/// The legacy `AddToSmartschool` / `CreateInSmartschool` actions are **not**
/// dispatched here: they need WISA class membership (`ContainsStudents`) and the
/// Smartschool group tree, which a [LinkedGroup] does not carry (see the package
/// README). An Azure-only orphan group (`wisa == null && smartschool == null`,
/// #52) yields no action.
///
/// Each candidate is constructed bound to [group] and kept only when its pure
/// [GroupAction.evaluate] returns true. Pure and deterministic (INV-40): same
/// group ⇒ same list.
List<GroupAction> groupActionsFor(LinkedGroup group) {
  final both = group.wisa != null && group.smartschool != null;

  final candidates = both
      ? <GroupAction>[
          ModifySmartschoolData(group),
        ]
      : <GroupAction>[
          DoNotImportFromWisa(group),
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
/// by their own families.
List<GroupAction> groupActions(LinkedSnapshot snapshot) => [
      for (final group in snapshot.groups) ...groupActionsFor(group),
    ];
