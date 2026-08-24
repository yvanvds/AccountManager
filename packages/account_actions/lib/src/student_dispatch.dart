import 'package:account_core/account_core.dart';

import 'azure_class_placement.dart';
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
/// [MoveToSmartschoolClassGroup] in the modify branch. Since #338 it also
/// reaches [ModifySmartschoolStemId], which reads it only to stand down while
/// that move is still pending. When omitted, the dispatch is exactly as it
/// shipped in #46 — no placement, no class move — because a [LinkedAccount]
/// alone cannot answer either. It is only called for `account.wisa != null`
/// records (the placement's target class comes from the WISA record); WISA-less
/// lifecycle accounts never need it.
///
/// [azurePlacementFor] wires the **Office 365 class-group** view of the same
/// student (#245), the per-account half of #228. Like [placementFor] it is only
/// called for `account.isInOurWisa` records — the target group is named after
/// their WISA class — and it feeds a single action, [AzureClassGroupMembership],
/// in the modify branch beside [MoveToSmartschoolClassGroup]: the two answer the
/// same question ("is this student in the right class group?") for the two
/// systems that have one, so they belong in the same branch. When omitted, the
/// dispatch is exactly as it shipped before #245, because a [LinkedAccount]
/// carries neither the group's membership nor the roster it should equal.
///
/// Each candidate is constructed bound to [account] and kept only when its
/// pure [StudentAction.evaluate] returns true. Pure and deterministic
/// (INV-40): same account + same [config] (+ same [placementFor] /
/// [azurePlacementFor]) ⇒ same list.
List<StudentAction> studentActionsFor(
  LinkedAccount account,
  StudentActionConfig config, {
  ClassPlacement Function(LinkedAccount account)? placementFor,
  AzureClassPlacement Function(LinkedAccount account)? azurePlacementFor,
}) {
  // "Complete" (modify branch) requires presence in *our* WISA, not merely
  // anywhere in the group (#134): a student who moved to a sibling group school
  // still carries a WISA record but must fall to the lifecycle branch so the
  // Smartschool departure fires (while their Azure account is kept).
  final complete = account.isInOurWisa &&
      account.smartschool != null &&
      account.azure != null;

  final placement = (placementFor != null && account.isInOurWisa)
      ? placementFor(account)
      : null;
  final azurePlacement = (azurePlacementFor != null && account.isInOurWisa)
      ? azurePlacementFor(account)
      : null;

  final candidates = complete
      ? <StudentAction>[
          ModifyAzureStudentEmail(account, config),
          ModifyAzureName(account, config),
          ModifyAzureSchool(account, config),
          ModifySmartschoolStudentAddress(account, config),
          ModifyAccountId(account, config),
          // The class move sits **before** the stamboeknummer write (#338), and
          // the stem write is handed the same placement so it can stand down
          // while the move is still pending. Smartschool stores one stamnummer
          // per schoolloopbaan row and `saveUser` writes it to the last one, so
          // the move has to create next year's row first — otherwise the number
          // lands on the row of the year the student is still sitting in.
          if (placement != null)
            MoveToSmartschoolClassGroup(account, config, placement),
          ModifySmartschoolStemId(account, config, placement: placement),
          ModifySmartschoolBirthPlace(account, config),
          if (azurePlacement != null)
            AzureClassGroupMembership(account, config, azurePlacement),
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
  AzureClassPlacement Function(LinkedAccount account)? azurePlacementFor,
}) =>
    [
      for (final account in snapshot.accounts)
        ...studentActionsFor(
          account,
          config,
          placementFor: placementFor,
          azurePlacementFor: azurePlacementFor,
        ),
    ];
