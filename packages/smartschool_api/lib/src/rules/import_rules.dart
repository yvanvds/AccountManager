/// Smartschool import rules.
///
/// Spec: `docs/domain-model.md` §3.11. Applied at snapshot construction —
/// by the time a [SmartschoolSnapshot] reaches the linker, discarded groups
/// and pruned subtrees are already gone.
///
/// Legacy reference: the `Connector.DiscardSubgroups` list and
/// `Group.ApplyImportRules` (`legacy-wpf/AccountApi/Smartschool/`). The
/// legacy code interleaves "discard group" (remove node) and "discard
/// subgroups" (skip descending) checks throughout traversal; we resolve both
/// once, up front.
library;

import '../models/smartschool_group.dart';

/// Base sealed type for the two Smartschool import rules.
sealed class SmartschoolImportRule {
  const SmartschoolImportRule();
}

/// Removes the group named [groupName] **and its entire subtree** from the
/// snapshot. Mirrors legacy `DiscardSmartschoolGroup` (`RuleAction.Discard`).
class DiscardSmartschoolGroup extends SmartschoolImportRule {
  final String groupName;
  const DiscardSmartschoolGroup(this.groupName);
}

/// Keeps the group named [groupName] but prunes its descendants — the group
/// becomes a leaf. Mirrors the legacy `Connector.DiscardSubgroups` behaviour,
/// where `Find`, `GetTreeAsList`, account loading, and counting all stop
/// descending into a named group's children.
class NoSmartschoolSubgroups extends SmartschoolImportRule {
  final String groupName;
  const NoSmartschoolSubgroups(this.groupName);
}

/// Applies all [rules] to [forest], returning a new top-level list.
///
/// For each group, in tree order:
///   - a matching [DiscardSmartschoolGroup] drops the group (and subtree);
///   - otherwise a matching [NoSmartschoolSubgroups] prunes its children;
///   - surviving groups recurse.
///
/// The node objects are reused; their `children` lists are rebuilt. Callers
/// pass a freshly parsed forest, so in-place reuse is safe.
List<SmartschoolGroup> applyImportRules(
  List<SmartschoolGroup> forest,
  Iterable<SmartschoolImportRule> rules,
) {
  final discardNames = <String>{
    for (final r in rules)
      if (r is DiscardSmartschoolGroup) r.groupName,
  };
  final noSubgroupNames = <String>{
    for (final r in rules)
      if (r is NoSmartschoolSubgroups) r.groupName,
  };

  List<SmartschoolGroup> walk(List<SmartschoolGroup> groups) {
    final kept = <SmartschoolGroup>[];
    for (final g in groups) {
      if (discardNames.contains(g.name)) continue;
      final children = noSubgroupNames.contains(g.name)
          ? const <SmartschoolGroup>[]
          : walk(g.children);
      g.children
        ..clear()
        ..addAll(children);
      kept.add(g);
    }
    return kept;
  }

  return walk(forest);
}
