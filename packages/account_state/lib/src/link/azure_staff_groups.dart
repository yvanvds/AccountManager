import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;

/// Resolves our school's Office 365 staff group, `<PREFIX>-Personeel`, once per
/// link and hands the staff dispatch a per-record [AzureStaffGroupPlacement]
/// (#444).
///
/// The staff counterpart of [AzureClassGroupResolver] and [PlacementResolver]:
/// it walks the snapshot **once** in its constructor and exposes a tear-off,
/// [placementFor], that the State layer passes as the staff dispatch's
/// `azureGroupPlacementFor` callback. Keeping the walk here is what lets
/// `account_actions` stay a pure function of its inputs.
///
/// **Read off the Azure snapshot, not the linked view.** The class-group
/// resolver works from linked records because a class group *is* one; the staff
/// group is not — the linker keeps an unmatched Azure group only when its name
/// is shaped like a class (#271), so `SSM-Personeel` never becomes a
/// [LinkedGroup] and the Klasgroepen lists rightly leave it out. It is in the
/// snapshot all the same: [az.GroupManager.listGroups] reads every group whose
/// display name starts with the school prefix, member ids included, so no extra
/// Graph read is needed to know who is in it.
///
/// **Every group of that name.** The display name is matched exactly — modulo
/// case and surrounding or repeated whitespace, through the same
/// [normalizeGroupName] the class groups are keyed by (INV-12) — so
/// `SSM-Personeel-Extra` or `SSM-Personeel 2526` are never taken for it. The
/// tenant may hold two such groups (a security group and the Microsoft 365 group
/// behind the staff Team, both of which legacy joined); every one is carried, in
/// snapshot order, and the actions decide per group whether Graph can write to
/// it (#331).
class AzureStaffGroupResolver {
  AzureStaffGroupResolver({
    required az.AzureSnapshot azure,
    required String schoolPrefix,
  }) : groupName = azureStaffGroupName(schoolPrefix) {
    final key = normalizeGroupName(groupName);
    if (key == null) return;
    for (final group in azure.groups) {
      if (normalizeGroupName(group.displayName) == key) _groups.add(group);
    }
  }

  /// `<PREFIX>-Personeel`, built from the school prefix the link was run with —
  /// never hard-coded — or `null` when no prefix is configured.
  final String? groupName;

  final List<az.AzureGroup> _groups = <az.AzureGroup>[];

  /// Every Office 365 group named [groupName], in snapshot order. Built once and
  /// shared by every placement, since every staff member reads the same groups.
  late final List<az.AzureGroup> groups =
      List<az.AzureGroup>.unmodifiable(_groups);

  /// Whether a staff group can be named but the tenant holds none by that name
  /// — the one fact the State layer reports **once** per sync instead of letting
  /// every staff member raise an action about it.
  bool get groupMissing => groupName != null && _groups.isEmpty;

  /// The staff-group placement of one staff member: every group named
  /// [groupName], and which of them their Azure account is a member of.
  ///
  /// A record with no Azure account (or a blank object id) is a member of
  /// nothing — which is what the create's join reads — and it is the actions,
  /// not this, that decide who the membership applies to at all
  /// ([LinkedStaff.isInOurWisa]).
  AzureStaffGroupPlacement placementFor(LinkedStaff staff) {
    final azureId = staff.azure?.id.trim() ?? '';
    return AzureStaffGroupPlacement(
      groupName: groupName,
      groups: groups,
      memberOfGroupIds: <String>{
        if (azureId.isNotEmpty)
          for (final group in _groups)
            if (group.hasMember(azureId)) group.id,
      },
    );
  }
}
