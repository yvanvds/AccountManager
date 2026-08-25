/// Root scoping for the Smartschool pull (#351).
///
/// The connector used to walk the **entire** group forest
/// `getAllGroupsAndClasses` returns and ask `getAllAccountsExtended` about
/// every node in it, so every enabled account sitting in at least one group of
/// the platform entered the snapshot: beheerders, externen, and whatever else
/// the tree carries beside the two populations this app manages. The
/// student/staff split happens far downstream, in the linker, and only on
/// `Basisrol` — at which point a beheerder account carrying a teacher role is
/// indistinguishable from a real staff member, joins the staff population, and
/// (having no WISA counterpart) reads as a *departed* one.
///
/// Scoping the walk to named roots — `Leerlingen` and `Personeel` at this
/// school, but the tree is tenant-specific, so the names are configured in
/// Instellingen — keeps those accounts out of the snapshot in the first place.
/// It also cuts one SOAP call per pruned node.
///
/// Applied **after** the import rules, on the tree they leave behind: a root
/// a [DiscardSmartschoolGroup] removed is genuinely not there any more, and is
/// reported as missing rather than silently resurrected.
library;

import 'package:account_core/account_core.dart' show normalizeGroupName;

import '../models/smartschool_group.dart';

/// The subtrees of [forest] the pull is scoped to: the **outermost** groups
/// whose name matches one of [rootNames], in tree order.
///
/// Names are matched on [normalizeGroupName], the key the rest of the port
/// joins group names on (#241) — both sides are operator-typed, the roots in
/// Instellingen and the groups in Smartschool, so `leerlingen` names the same
/// root as `Leerlingen` and a name carrying a double or non-breaking space is
/// the same as the one without. A blank entry names nothing and is ignored.
///
/// Only the outermost match is taken: a group nested inside an already-selected
/// root is walked as part of that root's subtree, so a namesake deeper down
/// cannot be visited (and its members counted) twice.
///
/// Two cases return [forest] **unscoped**, and both are deliberate:
///
///  - [rootNames] names no root at all — scoping is off, which is what an
///    install that has not configured it means;
///  - one of the names matches no group anywhere in [forest]
///    ([unmatchedRootNames] is non-empty).
///
/// The second is the fail-safe. Scoping to whatever happened to match would let
/// a typo — or a root renamed in Smartschool — silently empty a whole
/// population out of the snapshot, and a population that is absent from the
/// snapshot does not read as "not pulled": it reads as *gone*, which is exactly
/// the departure the #349 family acts on. Pulling the whole tree is at worst
/// what the connector did before this scoping existed, and the connector says
/// so in the log.
List<SmartschoolGroup> scopeToRoots(
  List<SmartschoolGroup> forest,
  Iterable<String> rootNames,
) {
  final keys = _rootKeys(rootNames);
  if (keys.isEmpty) return forest;
  if (unmatchedRootNames(forest, rootNames).isNotEmpty) return forest;

  final roots = <SmartschoolGroup>[];
  void walk(List<SmartschoolGroup> groups) {
    for (final g in groups) {
      final key = normalizeGroupName(g.name);
      if (key != null && keys.contains(key)) {
        roots.add(g);
        // Outermost wins: everything below is already inside this subtree.
        continue;
      }
      walk(g.children);
    }
  }

  walk(forest);
  return roots;
}

/// The entries of [rootNames] that match no group anywhere in [forest] — the
/// roots this pull cannot scope to.
///
/// Returned as the operator spelled them, in the order given, so the connector
/// can name the one to correct in Instellingen. Blank entries are ignored
/// rather than reported: they name nothing on purpose (an empty field), and
/// reporting them would keep the pull permanently unscoped.
List<String> unmatchedRootNames(
  List<SmartschoolGroup> forest,
  Iterable<String> rootNames,
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

  final unmatched = <String>[];
  for (final name in rootNames) {
    final key = normalizeGroupName(name);
    if (key == null) continue;
    if (!present.contains(key)) unmatched.add(name);
  }
  return unmatched;
}

Set<String> _rootKeys(Iterable<String> names) {
  final keys = <String>{};
  for (final name in names) {
    final key = normalizeGroupName(name);
    if (key != null) keys.add(key);
  }
  return keys;
}
