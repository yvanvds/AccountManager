import 'package:account_core/account_core.dart';

import 'class_placement.dart';
import 'student_action.dart';
import 'student_action_config.dart';

/// Derives the applicable [StudentAction]s for one [LinkedAccount], ported from
/// the legacy `AccountActionParser.AddActions` dispatch (§6.3).
///
/// The two action sets are **mutually exclusive**, exactly as in legacy:
/// - If *any* of the three systems is missing the record, only the **lifecycle**
///   actions (add / unregister / delete / remove) are considered.
/// - If all three are present, only the **modify / sync** actions are
///   considered.
///
/// [placementFor] wires the membership-dependent class-placement actions (#55).
/// When supplied it is called for each WISA-bearing account to build its
/// [ClassPlacement]: the class placement flows into [AddStudentToSmartschool]
/// (so a newly created account lands in its class) and enables
/// [MoveToSmartschoolClassGroup] in the modify branch. When omitted, the
/// dispatch is exactly as it shipped in #46 — no placement, no class move —
/// because a [LinkedAccount] alone cannot answer either. It is only called for
/// `account.wisa != null` records (the placement's target class comes from the
/// WISA record); WISA-less lifecycle accounts never need it.
///
/// Each candidate is constructed bound to [account] and kept only when its
/// pure [StudentAction.evaluate] returns true. Pure and deterministic
/// (INV-40): same account + same [config] (+ same [placementFor]) ⇒ same list.
List<StudentAction> studentActionsFor(
  LinkedAccount account,
  StudentActionConfig config, {
  ClassPlacement Function(LinkedAccount account)? placementFor,
}) {
  final complete = account.wisa != null &&
      account.smartschool != null &&
      account.azure != null;

  final placement = (placementFor != null && account.wisa != null)
      ? placementFor(account)
      : null;

  final candidates = complete
      ? <StudentAction>[
          ModifyAzureStudentEmail(account, config),
          ModifyAzureName(account, config),
          ModifyAzureSchool(account, config),
          ModifySmartschoolStudentAddress(account, config),
          ModifyAccountId(account, config),
          ModifySmartschoolStemId(account, config),
          ModifySmartschoolBirthPlace(account, config),
          if (placement != null)
            MoveToSmartschoolClassGroup(account, config, placement),
          ModifySmartschoolStudentEmail(account, config),
          ModifySmartschoolName(account, config),
        ]
      : <StudentAction>[
          AddStudentToAzure(account, config),
          AddStudentToSmartschool(account, config, placement: placement),
          UnregisterStudentFromSmartschool(account, config),
          DeleteStudentFromSmartschool(account, config),
          RemoveStudentFromAzure(account, config),
        ];

  return [
    for (final action in candidates)
      if (action.evaluate()) action,
  ];
}

/// Derives every applicable [StudentAction] across a [LinkedSnapshot]'s
/// student records, in snapshot order (§6.3). Pure and deterministic.
///
/// Only [LinkedSnapshot.accounts] (students) are considered; staff and groups
/// are handled by their own families (tracked as follow-ups to #46).
List<StudentAction> studentActions(
  LinkedSnapshot snapshot,
  StudentActionConfig config, {
  ClassPlacement Function(LinkedAccount account)? placementFor,
}) =>
    [
      for (final account in snapshot.accounts)
        ...studentActionsFor(account, config, placementFor: placementFor),
    ];
