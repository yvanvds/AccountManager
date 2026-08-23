import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Builds the [AzureClassGroupPlan] the Office 365 class-group actions need
/// (#228), from the linked snapshot the pure `link()` just produced.
///
/// The Azure counterpart of [PlacementResolver]: it walks the linked records
/// **once** in its constructor and exposes two tear-offs — [planFor], which the
/// State layer hands to the group dispatcher as its `azurePlanFor` callback, and
/// [placementFor] (#245), which it hands to the *student* dispatcher as its
/// `azurePlacementFor` callback. Keeping the walk here is what lets
/// `account_actions` stay a pure function of its inputs.
///
/// One resolver serving both is the point: the per-class roster diff and the
/// per-account "are you in your class's group?" are the same fact read two ways,
/// so they are derived from the same indexes rather than computed twice.
///
/// Three questions live here that no single [LinkedGroup] can answer:
///
/// - **Which class is this?** A record is keyed and named by the WISA
///   `fullName`, so `2F ECO` must be resolved back to the parent class `2F`
///   — the name the one shared group `<PREFIX>-2F` is built from.
///   [LinkedGroup.className] carries that, stamped by the linker.
/// - **Who raises the proposals?** Every sub-group record of `2F` maps to the
///   same group, so exactly one of them is nominated
///   ([AzureClassGroupPlan.owner]). The class's *own* record wins when it
///   exists; otherwise the first record of that class in snapshot order does,
///   because a sub-grouped class often has no parent record at all (its `00`
///   row is deduped away, #221).
/// - **What is the roster?** The class's students as **Azure object ids** — the
///   union over its sub-groups, since a student's [wapi.WisaStudent.classGroup]
///   is the bare class name. Only students present in a school we manage
///   ([LinkedAccount.isInOurWisa]) count, mirroring how the linker seeds class
///   groups (#205) and how the placement resolver tallies `containsStudents`
///   (#222).
///
/// Removals are computed narrowly on purpose: a member is only ever proposed for
/// removal when it is one of *our* students' Azure accounts and that student is
/// no longer in this class. Staff, titulars, and anything else in the group are
/// left alone — they are out of the issue's scope, and a class group that has
/// been shared with a teacher must not quietly lose them.
class AzureClassGroupResolver {
  AzureClassGroupResolver({
    required LinkedSnapshot linked,
    required this.schoolPrefix,
    required this.studentDomain,
  }) {
    // 1. Roster per bare class name, as Azure object ids, plus the set of every
    //    Azure id we can account for as one of our students (the removal
    //    safety net) and which classes hold students at all.
    for (final account in linked.accounts) {
      if (!account.isInOurWisa) continue;
      final wisa = account.wisa;
      if (wisa is! wapi.WisaStudent) continue;
      final className = normalizeGroupName(wisa.classGroup);
      if (className == null) continue;
      _classesWithStudents.add(className);
      final azureId = account.azure?.id.trim();
      if (azureId == null || azureId.isEmpty) continue;
      _ourStudentAzureIds.add(azureId);
      (_rosterByClass[className] ??= <String>{}).add(azureId);
    }

    // 2. Nominate the record that raises each class's Office 365 proposals.
    //    Two passes so the class's own record always wins over a sub-group's,
    //    regardless of snapshot order.
    for (final group in linked.groups) {
      final key = _ownerKeyOf(group);
      final className = normalizeGroupName(group.className);
      if (key == null || className == null || group.wisa == null) continue;
      if (normalizeGroupName(group.wisa!.name) == className) {
        _ownerKeyByClass[className] = key;
      }
    }
    for (final group in linked.groups) {
      final key = _ownerKeyOf(group);
      final className = normalizeGroupName(group.className);
      if (key == null || className == null || group.wisa == null) continue;
      _ownerKeyByClass.putIfAbsent(className, () => key);
    }

    // 3. The per-student view of the same facts (#245): which classes have a
    //    group today, and which of those groups each Azure account sits in.
    //
    //    Only a class that still exists is indexed (`wisa != null`), which is
    //    exactly the set the class-level `SyncAzureClassGroupMembers` can act
    //    on — so every membership this reports has a remedy. A sub-grouped
    //    class contributes several records that all carry the one group, and
    //    they collapse onto the single bare-name key.
    for (final group in linked.groups) {
      final className = normalizeGroupName(group.className);
      final azure = group.azure;
      if (className == null || group.wisa == null || azure == null) continue;
      _groupNameByClass.putIfAbsent(className, () => azure.displayName);
      // Whose membership Graph will not write (#331). Read here, where the
      // concrete connector record is in hand, so the per-student row can say
      // what the class row says instead of pointing at a write that is no
      // longer offered.
      if (azure is az.AzureGroup && !azure.canManageMembership) {
        _unmanagedGroupNames.add(azure.displayName);
      }
      for (final memberId in _memberIdsOf(azure)) {
        (_classesByMemberId[memberId] ??= <String>{}).add(className);
      }
    }
  }

  /// The Azure `companyName`/group-name prefix the school stamps on its own
  /// objects — the `<PREFIX>` half of `<PREFIX>-<KLAS>`.
  final String schoolPrefix;

  /// The student mail domain, e.g. `student.arcadiascholen.be`. Only used to
  /// render the address the created group will answer on.
  final String studentDomain;

  /// Normalized bare class name -> the Azure object ids of its students.
  final Map<String, Set<String>> _rosterByClass = {};

  /// Every Azure object id belonging to a student of ours — the only ids a
  /// membership removal may ever name.
  final Set<String> _ourStudentAzureIds = {};

  /// Normalized bare class names that hold at least one student of ours,
  /// whether or not that student already has an Azure account.
  final Set<String> _classesWithStudents = {};

  /// Normalized bare class name -> the [_ownerKeyOf] of the record that raises
  /// that class's Office 365 actions.
  final Map<String, String> _ownerKeyByClass = {};

  /// Normalized bare class name -> the display name of the Office 365 group
  /// that class **has today**, for the classes that still exist (#245). In
  /// linked-snapshot order, so the per-student report is deterministic.
  final Map<String, String> _groupNameByClass = {};

  /// Azure object id -> the normalized bare class names of the class groups it
  /// is currently a member of (#245). Built from the very same `memberIds`
  /// [planFor] diffs the roster against, so the per-account and per-class views
  /// of one student cannot disagree.
  final Map<String, Set<String>> _classesByMemberId = {};

  /// The display names of the class groups Exchange Online masters, so Graph
  /// refuses every membership write on them (#331). Empty in a healthy tenant:
  /// the app only ever creates Microsoft 365 groups, and the legacy WPF app only
  /// ever created plain security groups. A hand-made mail-enabled security group
  /// inside the school namespace — `SSM-1A` — is what puts a name here.
  final Set<String> _unmanagedGroupNames = {};

  /// The plan for one linked class, or `null` when the record names no Office
  /// 365 class group: it carries no WISA class (an orphan), the school prefix
  /// is unconfigured, or the resulting name would not survive as a Graph
  /// `mailNickname` (a class name with a space or a diacritic — see
  /// [isValidMailNickname]). Returning `null` is what keeps a create from being
  /// proposed that Graph would reject.
  AzureClassGroupPlan? planFor(LinkedGroup group) {
    if (group.wisa == null) return null;
    final rawName = group.className?.trim();
    final className = normalizeGroupName(rawName);
    if (rawName == null || className == null) return null;

    final displayName = azureClassGroupName(schoolPrefix, rawName);
    if (displayName == null || !isValidMailNickname(displayName)) return null;

    final owner = _ownerKeyByClass[className] == _ownerKeyOf(group);
    final roster = _rosterByClass[className] ?? const <String>{};
    final current = _memberIdsOf(group.azure);
    final currentSet = current.toSet();

    return AzureClassGroupPlan(
      className: rawName,
      displayName: displayName,
      mailNickname: displayName,
      mail: '$displayName@$studentDomain',
      owner: owner,
      containsStudents: _classesWithStudents.contains(className),
      membersToAdd: group.azure == null
          ? const <String>[]
          : <String>[
              for (final id in roster)
                if (!currentSet.contains(id)) id,
            ],
      membersToRemove: <String>[
        for (final id in current)
          if (_ourStudentAzureIds.contains(id) && !roster.contains(id)) id,
      ],
    );
  }

  /// The Office 365 class-group placement of one student (#245) — the
  /// per-account view of the membership [planFor] reports per class.
  ///
  /// The State layer hands this to the student dispatcher as its
  /// `azurePlacementFor` callback, exactly as [planFor] is handed to the group
  /// dispatcher. Both read the same two indexes, so a student the class plan
  /// wants added is the same student this reports as missing.
  ///
  /// A record with no WISA student, no class, or no Azure account yields an
  /// inert placement: their class group is not their account's problem yet —
  /// `AddStudentToAzure` is.
  AzureClassPlacement placementFor(LinkedAccount account) {
    final wisa = account.wisa;
    final rawName = wisa is wapi.WisaStudent ? wisa.classGroup.trim() : '';
    final className = normalizeGroupName(rawName);
    final groupName = _groupNameByClass[className] ??
        azureClassGroupName(schoolPrefix, rawName);

    final azureId = account.azure?.id.trim();
    final memberOf = (azureId == null || azureId.isEmpty)
        ? const <String>{}
        : (_classesByMemberId[azureId] ?? const <String>{});

    final strayGroupNames = <String>[
      for (final entry in _groupNameByClass.entries)
        if (entry.key != className && memberOf.contains(entry.key)) entry.value,
    ];

    return AzureClassPlacement(
      className: rawName,
      groupName: groupName,
      groupExists:
          className != null && _groupNameByClass.containsKey(className),
      isMember: className != null && memberOf.contains(className),
      strayGroupNames: strayGroupNames,
      // Only the groups this placement actually names: an unmanaged group
      // somewhere else in the school is not this student's problem (#331).
      unmanagedGroupNames: <String>[
        if (groupName != null && _unmanagedGroupNames.contains(groupName))
          groupName,
        ...strayGroupNames.where(_unmanagedGroupNames.contains),
      ],
    );
  }

  /// The stable identity of a linked class record, used to nominate one owner
  /// per class. The WISA `fullName` is exactly that: the linker keys records by
  /// it and collapses duplicates to the first (INV-20), so no two records of one
  /// snapshot share it.
  static String? _ownerKeyOf(LinkedGroup group) => group.wisa?.id.value;

  /// A group's current members. `account_core`'s [AzureGroup] interface carries
  /// only the linking keys, so the member list is read off the concrete
  /// connector record — the same downcast the State layer makes elsewhere.
  /// `listGroups` loads them with the group, so this needs no extra Graph call.
  static List<String> _memberIdsOf(AzureGroup? group) =>
      group is az.AzureGroup ? group.memberIds.toList() : const <String>[];
}
