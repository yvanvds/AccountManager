import 'package:account_core/account_core.dart';

import 'staff_action.dart';
import 'staff_action_config.dart';

/// Derives the applicable [StaffAction]s for one [LinkedStaff], ported from the
/// legacy `StaffMemberActionParser.AddActions` dispatch (§6.3).
///
/// The two action sets are **mutually exclusive**, exactly as in legacy: the
/// parser writes the "modify" branch as `if (OK)` rather than `else`, but it
/// sets `OK = false` inside the "missing" branch, so the semantics are the same
/// as the student parser — lifecycle actions when a system is missing, modify
/// actions only when all three are present.
///
/// Each candidate is constructed bound to [staff] and kept only when its pure
/// [StaffAction.evaluate] returns true. Pure and deterministic (INV-40): same
/// staff + same [config] ⇒ same list.
///
/// The legacy `AddToAzureStaffGroup` / `AddToStaffGroup` actions are **not**
/// dispatched here: they evaluate against Office 365 group membership, which a
/// [LinkedStaff] does not carry (see the package README).
///
/// The modify branch has **no** Azure `department` repair, and must not grow one
/// (#237): a staff member's `department` is owned by other software and holds a
/// comma-separated list of the school prefixes they are active at, so the only
/// correct thing to do with it is read it. The `ModifyStaffAzureSchool` this
/// branch briefly carried (#233) fired for every teacher our prefix did not lead
/// the list for, and rewrote `GBS,SSM` to a bare `SSM`.
///
/// [RetireStaffMember] is **deliberately absent** (#349). Dispatch is a pure
/// function of the record as it stands, and "this teacher is not coming back" is
/// not in the record — WISA reports them employed, because HR never closed the
/// dienstverband. Returning it here would give every staff member on the payroll
/// a standing destructive to-do, inflate the Personeel badge by the size of the
/// staff room, and put a retirement inside reach of a cohort apply. It is an
/// operator command instead: the UI constructs it for the one record on screen
/// and hands it to the applier, which is also why nothing in this file can
/// bulk-apply it.
///
/// A staff member with no Smartschool account raises [DontImportStaffFromWisa]
/// *and* exactly one of [AddStaffToAzure] / [AddStaffToSmartschool]. Those are
/// not two to-dos: they share the [staffImportAlternative] key, so the pending
/// list renders them as one either/or choice and an apply runs only the picked
/// one (#248). The creates lead the list on purpose — that is the order the
/// operator reads the radio pair in, and the fallback the grouping uses if a
/// default is ever forgotten, so the provisioning half comes first and never
/// the blacklist.
List<StaffAction> staffActionsFor(
  LinkedStaff staff,
  StaffActionConfig config,
) {
  // "Complete" (modify branch) requires presence in *our* WISA, not merely
  // anywhere in the group — the staff half of the same rule the student dispatch
  // has followed since #134, adopted here in #349. A teacher who moved to a
  // sibling group school still carries a WISA record, so the old
  // `staff.wisa != null` test called them complete and offered nothing but field
  // repairs; they have to fall to the lifecycle branch for the departure actions
  // to fire at all.
  final complete =
      staff.isInOurWisa && staff.smartschool != null && staff.azure != null;

  final candidates = complete
      ? <StaffAction>[
          UpdateStaffWisaName(staff, config),
          ModifySmartschoolStaffEmail(staff, config),
          SetStaffCopyCode(staff, config),
        ]
      : <StaffAction>[
          // The creates lead [DontImportStaffFromWisa], which they are mutually
          // exclusive with (#248): the order is the order the operator reads the
          // radio pair in, and the fallback the grouping uses if a default is
          // ever forgotten — so the provisioning half comes first, never the
          // blacklist.
          AddStaffToAzure(staff, config),
          AddStaffToSmartschool(staff, config),
          // The departure pair (#349), conservative half first: that is the
          // order the operator reads the radio pair in, and the order
          // `_chainFollowUps` walks, so a retirement keeps the account by
          // default and deleting it stays a deliberate pick.
          DeactivateStaffInSmartschool(staff, config),
          RemoveStaffFromSmartschool(staff, config),
          DontImportStaffFromWisa(staff, config),
          // Release before delete: the two are decided by the `department` list
          // and are mutually exclusive by construction, so the order only fixes
          // which one a follow-up walk meets first.
          ReleaseStaffFromAzureSchool(staff, config),
          RemoveStaffFromAzure(staff, config),
        ];

  return [
    for (final action in candidates)
      if (action.evaluate()) action,
  ];
}

/// Derives every applicable [StaffAction] across a [LinkedSnapshot]'s staff
/// records, in snapshot order (§6.3). Pure and deterministic.
///
/// Only [LinkedSnapshot.staff] are considered; students and groups are handled
/// by their own families.
List<StaffAction> staffActions(
  LinkedSnapshot snapshot,
  StaffActionConfig config,
) =>
    [
      for (final staff in snapshot.staff) ...staffActionsFor(staff, config),
    ];
