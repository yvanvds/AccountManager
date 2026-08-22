/// WISA import rules.
///
/// Spec: `docs/domain-model.md` §3.11. Rules are applied **at snapshot
/// construction time** — by the time a [WisaSnapshot] reaches the linker,
/// every dropped class group, dropped staff member and rewritten institute
/// number has already been resolved.
///
/// Legacy reference: `legacy-wpf/AccountApi/Rules/`. Each legacy rule's
/// behaviour is preserved verbatim; only the shape changes (sealed
/// hierarchy instead of `IRule` + `object obj` casts).
library;

import '../models/wisa_class_group.dart';
import '../models/wisa_staff.dart';

/// Base sealed type for the three WISA import rules. Each subtype knows
/// only how to test and modify its own target model — no `instanceof`
/// dispatch on a generic `object`, unlike the legacy `IRule`.
///
/// Neither legacy school-marking rule is ported any more, and for the same
/// reason: the operator's WISA-scholen grid in Instellingen marks a school by
/// **id** and a rule could only match its short code, so the two surfaces could
/// disagree about one flag.
///
/// - `WI_MarkAsOurs` was dropped in #286. It flipped a `WisaSchool.isOurs` flag
///   nothing read, the managed-school set coming from the grid (#178).
/// - `WI_MarkAsVirtual` was dropped in #277. It flipped `WisaSchool.isVirtual`,
///   which *is* read — the connector pulls a virtual school with the separate
///   virtual werkdatum — but the grid sets the same flag through
///   `AppSettings.virtualWisaSchoolIds`, and that mark is ticked in spring and
///   cleared in autumn, which is a checkbox next to a school's name rather than
///   an entry in a rules list. A persisted rule is migrated onto the grid's
///   per-school flag when the settings document loads.
sealed class WisaImportRule {
  const WisaImportRule();
}

/// Discards class groups whose [WisaClassGroup.name] equals [className].
/// Mirrors legacy `DontImportClass` (`RuleAction.Discard`).
class DontImportClass extends WisaImportRule {
  final String className;
  const DontImportClass(this.className);

  bool matches(WisaClassGroup g) => g.name == className;
}

/// Discards staff records whose [WisaStaff.code] equals [userCode].
/// Mirrors legacy `DontImportUserFromWisa`.
class DontImportUserFromWisa extends WisaImportRule {
  final String userCode;
  const DontImportUserFromWisa(this.userCode);

  bool matches(WisaStaff s) => s.code.value == userCode;
}

/// Rewrites [WisaClassGroup.schoolCode] from [original] to [replacement]
/// at snapshot construction. Mirrors legacy `ReplaceInstitute`
/// (`RuleAction.Modify`).
class ReplaceInstitute extends WisaImportRule {
  final String original;
  final String replacement;
  const ReplaceInstitute({required this.original, required this.replacement});

  bool matches(WisaClassGroup g) => g.schoolCode == original;
  WisaClassGroup apply(WisaClassGroup g) =>
      matches(g) ? g.copyWith(schoolCode: replacement) : g;
}

/// Applies all rules in [rules] to [groups], in order. Returns a new list;
/// the input is not mutated.
///
/// Behaviour:
///   - [DontImportClass] removes the matching class group.
///   - [ReplaceInstitute] rewrites `schoolCode`.
///   - Other rule types are no-ops for class groups.
///
/// Order matches legacy `ClassGroupManager.ApplyImportRules`: per-group,
/// rules are tried in list order; the first matching `Discard` rule
/// removes the group, otherwise modifications accumulate.
List<WisaClassGroup> applyRulesToClassGroups(
  Iterable<WisaClassGroup> groups,
  Iterable<WisaImportRule> rules,
) {
  final result = <WisaClassGroup>[];
  outer:
  for (var g in groups) {
    for (final r in rules) {
      switch (r) {
        case DontImportClass():
          if (r.matches(g)) continue outer;
        case ReplaceInstitute():
          g = r.apply(g);
        case DontImportUserFromWisa():
          break;
      }
    }
    result.add(g);
  }
  return result;
}

/// Applies all [DontImportUserFromWisa] rules in [rules] to [staff].
/// Returns a new list; the input is not mutated.
List<WisaStaff> applyRulesToStaff(
  Iterable<WisaStaff> staff,
  Iterable<WisaImportRule> rules,
) {
  final result = <WisaStaff>[];
  outer:
  for (final s in staff) {
    for (final r in rules) {
      if (r is DontImportUserFromWisa && r.matches(s)) continue outer;
    }
    result.add(s);
  }
  return result;
}
