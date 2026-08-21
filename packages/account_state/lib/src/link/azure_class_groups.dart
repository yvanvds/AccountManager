import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Builds the [AzureClassGroupPlan] the Office 365 class-group actions need
/// (#228), from the linked snapshot the pure `link()` just produced.
///
/// The Azure counterpart of [PlacementResolver]: it walks the linked records
/// **once** in its constructor and exposes one tear-off, [planFor], that the
/// State layer hands to the group dispatcher as its `azurePlanFor` callback.
/// Keeping the walk here is what lets `account_actions` stay a pure function of
/// its inputs.
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
