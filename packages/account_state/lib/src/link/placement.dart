import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

/// The Smartschool class-tree configuration used to resolve a new class's
/// *logical parent* — the group a freshly created official class hangs under.
///
/// Ported from legacy `Connector.StudentYear` / `StudentGrade` / `StudentPath`
/// and the `GroupManager.GetLogicalParent` switch on them
/// (`legacy-wpf/AccountApi/Smartschool/GroupManager.cs`). A school configures
/// **one** of two schemes:
/// - [years]: seven group codes, one per school year (`1..7`); or
/// - [grades]: three group codes, one per grade (years 1–2, 3–4, 5–7).
///
/// [path] is the fallback root code used when neither scheme is fully
/// configured. All three default to empty, matching a not-yet-configured
/// Smartschool tenant.
///
/// This is Smartschool live-config, deferred out of `AppSettings` like the
/// connection credentials; the State layer injects it into [PlacementResolver]
/// when it recomputes derived state, so the placement builder never reaches
/// into connector config itself.
class SmartschoolClassTree {
  const SmartschoolClassTree({
    this.years = const [],
    this.grades = const [],
    this.path = '',
  });

  /// Seven group codes, one per school year, or empty when the school
  /// configures grades instead. Legacy `Connector.StudentYear`.
  final List<String> years;

  /// Three group codes, one per grade, or empty when the school configures
  /// years instead. Legacy `Connector.StudentGrade`.
  final List<String> grades;

  /// Fallback root group code used when neither [years] nor [grades] is fully
  /// configured. Legacy `Connector.StudentPath`.
  final String path;

  /// The logical-parent group *code* for a class whose name starts with
  /// [year] (the class's first digit, `1..7`). Mirrors legacy
  /// `GetLogicalParent`: prefer the per-year code, then the per-grade code,
  /// then the flat [path].
  ///
  /// Returns `null` when [year] is out of the `1..7` range — legacy returned an
  /// empty string there, which `FindByCode` never resolved; `null` makes the
  /// "no parent" outcome explicit so [GroupPlacement.parent] is left unset.
  String? parentCodeForYear(int year) {
    if (year < 1 || year > 7) return null;
    if (years.length == 7) return years[year - 1];
    if (grades.length == 3) {
      switch (year) {
        case 1:
        case 2:
          return grades[0];
        case 3:
        case 4:
          return grades[1];
        default:
          return grades[2];
      }
    }
    return path;
  }
}

/// Builds the [ClassPlacement] / [GroupPlacement] inputs the action engine's
/// membership- and tree-dependent actions need, from the WISA and Smartschool
/// snapshots (spec `docs/domain-model.md` §3.7, PAIN-1).
///
/// A [LinkedAccount] / [LinkedGroup] alone cannot answer "which official class
/// is this student currently in?" or "does this WISA class hold students, and
/// what Smartschool parent does it hang under?" — those live in the
/// Smartschool memberships / group tree and the WISA class roster, which the
/// linker does not project onto a linked record (which is why #55 / #65
/// deferred the actions that need them). This resolver walks those snapshots
/// **once** in its constructor and exposes two tear-off-friendly methods,
/// [classPlacementFor] and [groupPlacementFor], that the State layer passes as
/// the dispatchers' `placementFor` callbacks.
///
/// Keeping the walk here preserves `account_actions`' pure-function boundary:
/// an action reads the placement it is handed, it never touches a snapshot.
///
/// `ourSchoolIds` is the set of WISA school ids the operator manages, the same
/// Settings-derived set `LinkedState` threads into `link()` (#178/#205). The
/// snapshots pool every school the shared WISA credentials reach, so the
/// resolver needs it to keep a sibling school's rows from answering questions
/// about *our* classes (#221/#222). When omitted it falls back to the
/// snapshot's own `WisaSchool.isOurs` flags, exactly like `link()`.
class PlacementResolver {
  PlacementResolver({
    required wapi.WisaSnapshot wisa,
    required ss.SmartschoolSnapshot smartschool,
    this.classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
  }) : _ourSchoolIds = ourSchoolIds ??
            <int>{
              for (final school in wisa.schools)
                if (school.isOurs) school.id,
            } {
    // Index the Smartschool tree by name (for resolveClass) and by code (for
    // the current-class and logical-parent lookups). First wins on a
    // collision, keeping the result a deterministic function of snapshot order.
    for (final group in smartschool.groups) {
      final name = normalizeGroupName(group.name);
      if (name != null) _groupsByName.putIfAbsent(name, () => group);
      _groupsByCode.putIfAbsent(group.id.value, () => group);
    }

    // A student's current official class, keyed by Smartschool uid. Legacy
    // `Smartschool.Account.Group` held a single class name; with first-class
    // memberships (INV-30) we take the first membership that resolves to an
    // official class group.
    for (final membership in smartschool.memberships) {
      final uid = _norm(membership.uid);
      if (uid == null) continue;
      final group = _groupsByCode[membership.groupId.value];
      if (group == null ||
          !group.official ||
          group.type != GroupType.classGroup) {
        continue;
      }
      _currentClassByUid.putIfAbsent(uid, () => group);
    }

    // WISA students, indexed by wisaId so [classPlacementFor] can recover the
    // concrete record (class group / sub-group) from a [LinkedAccount], which
    // only carries the `wisaId` linking key. Also collect the class names that
    // currently hold a student — legacy `WisaClassGroup.ContainsStudents`
    // (`student.ClassGroup == Name`).
    //
    // Only students of a school we manage are tallied (#222). The snapshot
    // pools every school the shared WISA credentials reach, so a sibling
    // school's populated `1A` used to make *our* empty `1A` read as populated —
    // and [groupPlacementFor] then raised `AddToSmartschool` (which also enrols
    // students) instead of the informational `CreateInSmartschool`. Filtering at
    // the tally rather than at the lookup is deliberate: a [LinkedGroup] carries
    // no school, so [groupPlacementFor] has nothing to scope by (see there).
    // The index itself stays unfiltered — a `groupOnly` student still gets their
    // own class placement.
    for (final student in wisa.students) {
      final wisaId = _norm(student.wisaId.value);
      if (wisaId != null) {
        _wisaStudentByWisaId.putIfAbsent(wisaId, () => student);
      }
      final classGroup = normalizeGroupName(student.classGroup);
      if (classGroup != null && _isOurSchool(student.schoolId)) {
        _classGroupsWithStudents.add(classGroup);
      }
    }

    // Classes that use sub-groups: legacy `ClassGroupManager.UseSubGroups` —
    // a class whose rows carry more than one distinct admin code.
    //
    // The tally is keyed on `(schoolId, name)`, **not** on the name alone
    // (#221). `ADMINGROEP` is only unique *within* a school, and this snapshot
    // pools every school the shared WISA credentials reach — including sibling
    // schools we do not manage. Two schools that each have their own
    // single-group `1C` therefore contribute two distinct admin codes for the
    // name `1C`, and a name-keyed tally reads that as "1C uses sub-groups" for
    // both, which appended each student's `KLASGROEP` to their class name.
    //
    // Also index WISA classes by fullName so [groupPlacementFor] can recover
    // the source class (bare name / year) from a [LinkedGroup] keyed by
    // fullName. That index stays name-keyed and first-wins on purpose: a
    // [LinkedGroup] carries no school, and the linker itself collapses
    // duplicate fullNames to the first record (INV-20), so this mirrors it.
    final adminCodesByClass = <(int, String), Set<String>>{};
    for (final group in wisa.classGroups) {
      final name = normalizeGroupName(group.name);
      if (name != null) {
        adminCodesByClass.putIfAbsent(
            (group.schoolId, name), () => <String>{}).add(group.adminCode);
      }
      final fullName = normalizeGroupName(group.fullName);
      if (fullName != null) _wisaByFullName.putIfAbsent(fullName, () => group);
    }
    for (final entry in adminCodesByClass.entries) {
      if (entry.value.length > 1) _subGroupClasses.add(entry.key);
    }
  }

  /// The class-tree config driving [GroupPlacement.parent] resolution.
  final SmartschoolClassTree classTree;

  /// The WISA school ids the operator actually manages (#222), from the
  /// persisted Settings ownership flags the State layer threads in — the same
  /// set the linker scopes group seeding by (#205). When the caller passes
  /// none it is derived from the snapshot's own `WisaSchool.isOurs` flags,
  /// exactly as `link()` derives its own fallback, so the two layers always
  /// agree on which classes exist and which students populate them.
  ///
  /// An **empty** set means ownership is unconfigured, in which case every
  /// school counts as ours — mirroring the linker's `_isOurWisaSchool` and
  /// preserving the pre-#222 pooled behaviour for an unconfigured install.
  final Set<int> _ourSchoolIds;

  final Map<String, Group> _groupsByName = {};
  final Map<String, Group> _groupsByCode = {};
  final Map<String, Group> _currentClassByUid = {};
  final Map<String, wapi.WisaStudent> _wisaStudentByWisaId = {};

  /// The `(schoolId, normalized class name)` pairs whose class carries more
  /// than one admin code — i.e. the classes that really are split into
  /// sub-groups, within the one school that says so.
  final Set<(int, String)> _subGroupClasses = {};
  final Map<String, wapi.WisaClassGroup> _wisaByFullName = {};

  /// Normalized class names that hold at least one student **of a school we
  /// manage** (#222) — legacy `WisaClassGroup.ContainsStudents`, scoped.
  final Set<String> _classGroupsWithStudents = {};

  /// Whether [schoolId] is one of the schools we manage. Mirrors the linker's
  /// `_isOurWisaSchool`: an empty [_ourSchoolIds] means ownership is
  /// unconfigured, so every school counts as ours.
  bool _isOurSchool(int schoolId) =>
      _ourSchoolIds.isEmpty || _ourSchoolIds.contains(schoolId);

  /// Builds the [ClassPlacement] for one student (the dispatcher only calls
  /// this for `account.wisa != null` records; a WISA-less lifecycle account
  /// never needs a placement).
  ///
  /// - [ClassPlacement.className] is the WISA `classGroup`, plus the
  ///   `classSubGroup` when the class uses sub-groups (legacy
  ///   `Student.ClassName`) — see [_classNameFor] for the sub-group rules.
  /// - [ClassPlacement.currentClass] is the student's current official
  ///   Smartschool class, sourced from the memberships, or `null` when the
  ///   student has no Smartschool account or no official class membership.
  /// - [ClassPlacement.resolveClass] resolves a class name against the whole
  ///   Smartschool tree (legacy `GroupManager.Root.Find`).
  ClassPlacement classPlacementFor(LinkedAccount account) {
    final wisaId = _norm(account.wisa?.wisaId.value);
    final student = wisaId == null ? null : _wisaStudentByWisaId[wisaId];
    final className = _classNameFor(student);

    final uid = _norm(account.smartschool?.uid);
    final currentClass = uid == null ? null : _currentClassByUid[uid];

    return ClassPlacement(
      className: className,
      currentClass: currentClass,
      resolveClass: (name) => _groupsByName[normalizeGroupName(name)],
    );
  }

  /// The official class name for [student] (legacy `Student.ClassName`): the
  /// bare `classGroup`, widened to `'classGroup subGroup'` only when the
  /// student's own school splits that class into sub-groups.
  ///
  /// Two guards sit in front of that widening (#221):
  /// - the sub-group test is scoped to the student's `schoolId`, so a
  ///   same-named class in another school can never make this one look split;
  /// - a `classSubGroup` that is blank or the [_noSubGroupSentinel] names no
  ///   real group, so it is never appended. This mirrors the guard
  ///   [wapi.WisaClassGroup.fullName] applies on the class-group side, without
  ///   which a student's `KLASGROEP` of `00` produced the class `'1C 00'` and
  ///   proposed moving their whole class into it.
  String _classNameFor(wapi.WisaStudent? student) {
    if (student == null) return '';
    final classGroup = student.classGroup;
    final subGroup = student.classSubGroup.trim();
    if (subGroup.isEmpty || subGroup == _noSubGroupSentinel) return classGroup;
    final name = normalizeGroupName(classGroup);
    if (name == null) return classGroup;
    return _subGroupClasses.contains((student.schoolId, name))
        ? '$classGroup $subGroup'
        : classGroup;
  }

  /// Builds the [GroupPlacement] for one WISA-only class (the dispatcher only
  /// calls this for `wisa != null && smartschool == null` groups).
  ///
  /// - [GroupPlacement.containsStudents] is whether the WISA class currently
  ///   holds students (legacy `WisaClassGroup.ContainsStudents`), which selects
  ///   `AddToSmartschool` (populated) over `CreateInSmartschool` (empty). Only
  ///   students of a school we manage count (#222): a [LinkedGroup] is only ever
  ///   seeded from a managed school's class (#205), so a sibling school's
  ///   same-named class must not decide ours. The scoping happens where the
  ///   tally is built, not here — see the constructor.
  /// - [GroupPlacement.parent] is the resolved Smartschool parent group
  ///   (legacy `GetLogicalParent` → `Root.FindByCode`), or `null` when the
  ///   class year is out of range or the parent node is absent from the tree.
  GroupPlacement groupPlacementFor(LinkedGroup group) {
    // [LinkedGroup.wisa] is keyed by fullName; recover the source WISA class to
    // read its bare name and year.
    final wisaClass = _wisaByFullName[normalizeGroupName(group.wisa?.name)];
    final containsStudents = wisaClass != null &&
        _classGroupsWithStudents.contains(normalizeGroupName(wisaClass.name));
    final parentCode = classTree.parentCodeForYear(wisaClass?.year ?? -1);
    final parent = parentCode == null ? null : _groupsByCode[parentCode];

    return GroupPlacement(
      containsStudents: containsStudents,
      parent: parent,
    );
  }
}

/// WISA's `KLASGROEP` value for "this class has no sub-groups". It is a
/// sentinel, not a group code, so it must never surface in a class name —
/// see [wapi.WisaClassGroup.fullName], which guards the class-group side.
const String _noSubGroupSentinel = '00';

/// Trims and lower-cases [value] for case-insensitive, whitespace-tolerant
/// matching (INV-12), returning `null` for a null or blank input so an empty
/// key never indexes or matches anything. Mirrors the linker's `_norm`.
///
/// For identifiers only (a Smartschool `uid`). Every group *name* key here goes
/// through [normalizeGroupName] instead — the same function the linker keys its
/// own group records by (#225), so the two layers cannot disagree about which
/// class a name refers to.
String? _norm(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed.toLowerCase();
}
