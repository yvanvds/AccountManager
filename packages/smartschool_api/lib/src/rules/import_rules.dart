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

import 'package:account_core/account_core.dart' show normalizeGroupName;

import '../models/smartschool_group.dart';

/// Base sealed type for the two Smartschool import rules.
sealed class SmartschoolImportRule {
  const SmartschoolImportRule();

  /// The Smartschool group this rule applies to, spelled the way the operator
  /// typed it in Instellingen (#202).
  ///
  /// Never compared raw: it is matched on [normalizeGroupName], the key the
  /// rest of the port joins group names on (#241).
  String get groupName;
}

/// Removes the group named [groupName] **and its entire subtree** from the
/// snapshot. Mirrors legacy `DiscardSmartschoolGroup` (`RuleAction.Discard`).
class DiscardSmartschoolGroup extends SmartschoolImportRule {
  @override
  final String groupName;
  const DiscardSmartschoolGroup(this.groupName);
}

/// Keeps the group named [groupName] but prunes its descendants — the group
/// becomes a leaf. Mirrors the legacy `Connector.DiscardSubgroups` behaviour,
/// where `Find`, `GetTreeAsList`, account loading, and counting all stop
/// descending into a named group's children.
class NoSmartschoolSubgroups extends SmartschoolImportRule {
  @override
  final String groupName;
  const NoSmartschoolSubgroups(this.groupName);
}

/// The match key of [rule]'s group name, or `null` when the rule names nothing
/// (a blank name, which can never match a group).
String? _ruleKey(SmartschoolImportRule rule) =>
    normalizeGroupName(rule.groupName);

/// Applies all [rules] to [forest], returning a new top-level list.
///
/// For each group, in tree order:
///   - a matching [DiscardSmartschoolGroup] drops the group (and subtree);
///   - otherwise a matching [NoSmartschoolSubgroups] prunes its children;
///   - surviving groups recurse.
///
/// A rule matches a group when their names share a [normalizeGroupName] key
/// (#241): both sides are operator-typed — the rule in Instellingen, the group
/// in Smartschool — so `leerlingen` is the same rule target as `Leerlingen`,
/// and a name carrying a double or non-breaking space is the same as the one
/// without. Matching them raw made a rule that read as correct do nothing at
/// all. A rule whose name is blank matches nothing.
///
/// The node objects are reused; their `children` lists are rebuilt. Callers
/// pass a freshly parsed forest, so in-place reuse is safe.
List<SmartschoolGroup> applyImportRules(
  List<SmartschoolGroup> forest,
  Iterable<SmartschoolImportRule> rules,
) {
  final discardNames = <String>{};
  final noSubgroupNames = <String>{};
  for (final rule in rules) {
    final key = _ruleKey(rule);
    if (key == null) continue;
    switch (rule) {
      case DiscardSmartschoolGroup():
        discardNames.add(key);
      case NoSmartschoolSubgroups():
        noSubgroupNames.add(key);
    }
  }

  List<SmartschoolGroup> walk(List<SmartschoolGroup> groups) {
    final kept = <SmartschoolGroup>[];
    for (final g in groups) {
      final key = normalizeGroupName(g.name);
      if (key != null && discardNames.contains(key)) continue;
      final children = key != null && noSubgroupNames.contains(key)
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

/// The [rules] that match no group anywhere in [forest] — the rules this pull
/// will do nothing for (#241).
///
/// Since [applyImportRules] matches on the normalized name, a rule still
/// matching nothing means Smartschool carries no group by that name at all: a
/// typo, or a group renamed since the rule was written. Reporting these is what
/// lets an operator tell such a rule apart from one that matched a subtree
/// which was already empty — the two used to be equally silent.
///
/// Membership is decided over the **whole** parsed forest, not the pruned
/// result, so a rule shadowed by another rule's discard is not reported as a
/// typo: its group does exist. Call this *before* [applyImportRules], which
/// rebuilds the nodes' `children` lists in place.
///
/// Rules are returned in the order given, one entry per rule — two rules naming
/// the same missing group are two findings, because they are two mistakes.
List<SmartschoolImportRule> unmatchedImportRules(
  List<SmartschoolGroup> forest,
  Iterable<SmartschoolImportRule> rules,
) {
  final present = <String>{};
  void collect(List<SmartschoolGroup> groups) {
    for (final g in groups) {
      final key = normalizeGroupName(g.name);
      if (key != null) present.add(key);
      collect(g.children);
    }
  }

  collect(forest);

  final unmatched = <SmartschoolImportRule>[];
  for (final rule in rules) {
    final key = _ruleKey(rule);
    if (key == null || !present.contains(key)) unmatched.add(rule);
  }
  return unmatched;
}
