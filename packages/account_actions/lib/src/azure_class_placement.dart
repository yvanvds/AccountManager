/// One student's Office 365 class-group placement — where their Azure account
/// *should* sit (`<PREFIX>-<KLAS>`) and where it actually sits today (#245).
///
/// The Azure counterpart of [ClassPlacement], and injected the same way: the
/// State layer builds one per student from the linked view, and the action only
/// ever *reads* it. That keeps `account_actions` a pure function of its inputs —
/// no snapshot walking inside an action.
///
/// Everything here is derived from the **same** source as the class-level
/// [AzureClassGroupPlan] — the linked groups' `memberIds` and the class rosters
/// the linker's `wisaId ≡ employeeId` bridge produces — so the per-account view
/// and the per-class view can never disagree about the same student. See
/// `AzureClassGroupResolver` in `account_state`, which builds both.
class AzureClassPlacement {
  const AzureClassPlacement({
    required this.className,
    this.groupName,
    this.groupExists = false,
    this.isMember = false,
    this.strayGroupNames = const [],
  });

  /// The **bare** WISA class the student belongs to — `2F`, never the
  /// sub-grouped `2F ECO`, because sub-groups get no group of their own (#228).
  /// Empty when the student carries no class at all.
  final String className;

  /// The display name of the class's Office 365 group, `<PREFIX>-<KLAS>`, or
  /// `null` when no group can be named (no class, no configured prefix).
  final String? groupName;

  /// Whether that group actually exists in Azure today. When it does not, the
  /// class-level `CreateAzureClassGroup` is the work — and since #245 it chains
  /// straight into the roster sync — so nothing is reported per student.
  final bool groupExists;

  /// Whether the student's Azure account is already a member of [groupName].
  final bool isMember;

  /// The display names of **our** class groups the student is a member of but
  /// should not be — the class group of a class they left.
  ///
  /// Deliberately limited to groups whose class still exists, which is exactly
  /// the set the class-level `SyncAzureClassGroupMembers` can remove them from
  /// (`AzureClassGroupPlan.membersToRemove`). The group of a class that vanished
  /// is never touched automatically — that is `AzureClassGroupWithoutClass`'s
  /// story, a manual cleanup — so naming it here would report work nobody can do.
  final List<String> strayGroupNames;

  /// Whether the student is missing from their own class's existing group.
  bool get missingFromOwnGroup => groupExists && !isMember;

  /// Whether the placement differs from the roster in either direction.
  bool get differs => missingFromOwnGroup || strayGroupNames.isNotEmpty;
}
