import 'package:account_core/account_core.dart';

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
/// Each candidate is constructed bound to [account] and kept only when its
/// pure [StudentAction.evaluate] returns true. Pure and deterministic
/// (INV-40): same account + same [config] ⇒ same list.
List<StudentAction> studentActionsFor(
  LinkedAccount account,
  StudentActionConfig config,
) {
  final complete = account.wisa != null &&
      account.smartschool != null &&
      account.azure != null;

  final candidates = complete
      ? <StudentAction>[
          ModifyAzureStudentEmail(account, config),
          ModifyAzureName(account, config),
          ModifyAzureSchool(account, config),
          ModifySmartschoolStudentAddress(account, config),
          ModifyAccountId(account, config),
          ModifySmartschoolStemId(account, config),
          ModifySmartschoolBirthPlace(account, config),
          ModifySmartschoolStudentEmail(account, config),
          ModifySmartschoolName(account, config),
        ]
      : <StudentAction>[
          AddStudentToAzure(account, config),
          AddStudentToSmartschool(account, config),
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
  StudentActionConfig config,
) =>
    [
      for (final account in snapshot.accounts)
        ...studentActionsFor(account, config),
    ];
