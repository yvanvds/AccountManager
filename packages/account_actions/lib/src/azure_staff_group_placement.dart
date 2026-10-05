import 'package:azure_api/azure_api.dart' as az;

/// The part of the Office 365 staff group's name after the school prefix
/// (#444): every staff member of our school belongs in `<PREFIX>-Personeel`.
///
/// Legacy hard-coded the whole name once (`AddToStaffGroup`: `SSM-Personeel`)
/// and built it from the prefix setting twice (`AddToAzure`,
/// `AddToAzureStaffGroup`). The port only ever builds it — see
/// [azureStaffGroupName] — so the group follows the school prefix in
/// Instellingen and a sibling school's `GBS-Personeel` can never be mistaken
/// for ours.
const String azureStaffGroupSuffix = 'Personeel';

/// The display name of our school's Office 365 staff group,
/// `<PREFIX>-Personeel` (#444), or `null` when no prefix is configured.
///
/// A blank prefix names no group at all rather than `-Personeel`: with no
/// school to scope by, no group can be ours, and the staff dispatch then raises
/// nothing about it.
String? azureStaffGroupName(String? schoolPrefix) {
  final prefix = schoolPrefix?.trim() ?? '';
  if (prefix.isEmpty) return null;
  return '$prefix-$azureStaffGroupSuffix';
}

/// One staff member's Office 365 staff-group placement (#444): which groups are
/// named `<PREFIX>-Personeel`, and which of them the account already sits in.
///
/// The Azure staff twin of [AzureClassPlacement], and injected the same way:
/// the State layer resolves it once per link from the Azure snapshot (see
/// `AzureStaffGroupResolver` in `account_state`) and the actions only ever
/// *read* it. A [LinkedStaff] carries no group membership, which is why the
/// legacy `AddToStaffGroup` / `AddToAzureStaffGroup` and the `-Personeel` seat
/// inside `AddToAzure` were left out of the port until this value existed.
///
/// **Every group of that name, not one.** The tenant can hold two groups called
/// `SSM-Personeel` — legacy checked a security group *and* the Microsoft 365
/// group behind the staff Team, and joined the account to both — so this
/// carries a list. Membership is enforced in each one whose membership Graph
/// can manage ([joinableGroups]); a group Exchange Online masters (#331) is
/// still diagnosed ([unmanagedMissingGroups]) but never written to, because
/// Graph refuses every membership write on it.
class AzureStaffGroupPlacement {
  const AzureStaffGroupPlacement({
    required this.groupName,
    this.groups = const <az.AzureGroup>[],
    this.memberOfGroupIds = const <String>{},
  });

  /// `<PREFIX>-Personeel`, or `null` when no school prefix is configured — then
  /// [groups] is empty too, and nothing is raised.
  final String? groupName;

  /// Every Office 365 group whose display name is [groupName], in snapshot
  /// order. Empty when the tenant has none — the State layer logs that once per
  /// sync rather than every staff member raising an action about it.
  final List<az.AzureGroup> groups;

  /// The object ids of the [groups] the staff member's Azure account is a
  /// member of. Empty for a staff member with no Azure account yet.
  final Set<String> memberOfGroupIds;

  /// Whether the tenant holds at least one group named [groupName].
  bool get groupExists => groups.isNotEmpty;

  /// The [groups] the account is **not** a member of.
  List<az.AzureGroup> get missingFromGroups => <az.AzureGroup>[
        for (final group in groups)
          if (!memberOfGroupIds.contains(group.id)) group,
      ];

  /// The [missingFromGroups] whose membership Graph will write — the ones an
  /// apply adds the account to.
  List<az.AzureGroup> get joinableGroups => <az.AzureGroup>[
        for (final group in missingFromGroups)
          if (group.canManageMembership) group,
      ];

  /// The [missingFromGroups] Exchange Online masters (#331): the membership is
  /// missing, but only Exchange Online can add it.
  List<az.AzureGroup> get unmanagedMissingGroups => <az.AzureGroup>[
        for (final group in missingFromGroups)
          if (!group.canManageMembership) group,
      ];

  /// Whether the account is a member of every group named [groupName]. False
  /// when no such group exists: there is nothing to be a member of.
  bool get isMember => groupExists && missingFromGroups.isEmpty;
}
