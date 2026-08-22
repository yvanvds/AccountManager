/// WISA import rules.
///
/// Spec: `docs/domain-model.md` §3.11. Rules are applied **at snapshot
/// construction time** — by the time a [WisaSnapshot] reaches the linker,
/// every dropped class group, dropped staff member, rewritten institute
/// number, and virtual-school flag has already been resolved.
///
/// Legacy reference: `legacy-wpf/AccountApi/Rules/`. Each legacy rule's
/// behaviour is preserved verbatim; only the shape changes (sealed
/// hierarchy instead of `IRule` + `object obj` casts).
library;

import '../models/wisa_class_group.dart';
import '../models/wisa_school.dart';
import '../models/wisa_staff.dart';

/// Base sealed type for the four WISA import rules. Each subtype knows
/// only how to test and modify its own target model — no `instanceof`
/// dispatch on a generic `object`, unlike the legacy `IRule`.
///
/// Legacy `WI_MarkAsOurs` has **no** port (#286). It flipped a
/// `WisaSchool.isOurs` flag nothing read: the managed-school set comes from the
/// operator's WISA-scholen grid in Instellingen (#178), which is authoritative
/// the moment it holds a single school — so the rule could be saved and then
/// silently do nothing.
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

/// Flags schools whose [WisaSchool.code] equals [schoolCode] as virtual.
/// The connector then syncs those schools with the virtual workdate
/// instead of the real one. Mirrors legacy `MarkAsVirtual`
/// (`RuleAction.WorkDate`).
///
/// Matches on the **short code** (`ISMV`), as it always did — before #208 that
/// half was misfiled on `WisaSchool.name`, so this read `s.name`.
class MarkAsVirtual extends WisaImportRule {
  final String schoolCode;
  const MarkAsVirtual(this.schoolCode);

  bool matches(WisaSchool s) => s.code == schoolCode;
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
        case MarkAsVirtual():
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

/// Applies the school-marking rule [MarkAsVirtual] in [rules] to [schools].
/// Returns a new list with `isVirtual` flipped on matching schools; the input
/// is not mutated.
///
/// The pass is additive — a school already flagged stays flagged — so unioning
/// the operator's per-school virtual marks in (`markVirtualSchools`) can never
/// un-virtualise a school a rule covers.
List<WisaSchool> applyRulesToSchools(
  Iterable<WisaSchool> schools,
  Iterable<WisaImportRule> rules,
) {
  return [
    for (final s in schools)
      s.copyWith(
        isVirtual:
            s.isVirtual || rules.any((r) => r is MarkAsVirtual && r.matches(s)),
      ),
  ];
}
