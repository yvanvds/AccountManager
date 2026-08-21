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
/// [ModifyStaffAzureSchool] has no legacy counterpart at all — the staff family
/// never had a `department` repair (#233). Like the student `ModifyAzureSchool`
/// it sits in the modify branch, so an adopted account is stamped on the pass
/// *after* its Smartschool side is built and the record is complete.
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
  final complete =
      staff.wisa != null && staff.smartschool != null && staff.azure != null;

  final candidates = complete
      ? <StaffAction>[
          ModifyStaffAzureSchool(staff, config),
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
          RemoveStaffFromSmartschool(staff, config),
          DontImportStaffFromWisa(staff, config),
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
