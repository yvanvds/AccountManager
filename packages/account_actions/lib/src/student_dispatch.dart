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
/// student (#245), the per-account half of #228. It feeds a single action,
/// [AzureClassGroupMembership], and it is consulted for exactly two populations:
///
/// - a student present in **our** WISA, as it has been since #245 — the target
///   group is named after their WISA class, so there has to be one. The action
///   lands in the modify branch beside [MoveToSmartschoolClassGroup]: the two
///   answer the same question ("is this student in the right class group?") for
///   the two systems that have one, so they belong in the same branch;
/// - a student who has **left** us and still has an Office 365 account (#385).
///   That account keeps its memberships until an operator decides otherwise, so
///   until then they are sitting in last year's class group — the very
///   membership the class-level `SyncAzureClassGroupMembers` now proposes to
///   undo. They have no class of ours to be a target, so all their placement can
///   report is the stray, and it reports the same one the class row does: the
///   two views are built by one resolver precisely so they cannot disagree about
///   a student, and fixing only the class plan is what would have made them.
///   Their reading lands in the **lifecycle** branch, beside the departures.
///
/// So the branch rule is untouched: a record present in our WISA but incomplete
/// still gets no class-group reading, because its class placement is the modify
/// branch's business and it is not in it. When [azurePlacementFor] is omitted,
/// the dispatch is exactly as it shipped before #245, because a [LinkedAccount]
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

  // The same view for the one population the modify branch cannot reach (#385):
  // a student who has left the schools we manage and whose Office 365 account is
  // still a member of a class group of ours. Kept as a second name rather than
  // widening [azurePlacement], so the modify branch's condition — and every
  // record that already flows through it — stays exactly what #245 shipped.
  // Without an Azure account there is nothing that could be a member of
  // anything, so nothing is asked.
  final departurePlacement = (azurePlacementFor != null &&
          account.hasLeftOurSchool &&
          account.azure != null)
      ? azurePlacementFor(account)
      : null;

  final candidates = complete
      ? <StudentAction>[
          ModifyAzureStudentEmail(account, config),
          ModifyAzureName(account, config),
          ModifyAzureSchool(account, config),
          // The other half of the licensing rule, beside the half that stamps
          // the school (#358). It lives here — the modify branch — on purpose:
          // the branch is only reached for a student present in *our* WISA, so
          // the job title is derived from what WISA says they are and never from
          // an Azure-only orphan's `companyName`.
          ModifyAzureJobTitle(account, config),
          // The class the Azure profile advertises (#359), beside the school and
          // the job title. Same reason for living here: `department` may only
          // ever be *written* from what WISA says, and this branch is the one
          // that has a WISA row of ours to say it. It is also why the staff
          // meaning of the field (#237) is out of reach — that population never
          // passes through this dispatch at all. The placement rides along for
          // the ours-classes guard alone (#333): a class our WISA does not have
          // is not written into Office 365 either.
          ModifyAzureDepartment(account, config, placement: placement),
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
          // The per-account reading of the stray class-group membership a
          // departed student leaves behind (#385) — informational, as it is in
          // the modify branch, so it competes with none of the departures above
          // and the single write still lives on the class row. It stands down by
          // itself for a leaver who is in no class group of ours: with no target
          // class there is nothing else its placement could report.
          if (departurePlacement != null)
            AzureClassGroupMembership(account, config, departurePlacement),
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
