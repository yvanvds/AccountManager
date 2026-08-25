import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../link/linked_state.dart';
import '../settings/wisa_school_label.dart';
import 'materialized_state.dart';

/// Turns a transient [LinkedState] into the persistable [MaterializedView]
/// (#115): one [MaterializedAccount] per linked account and staff member, plus
/// the school / grade-year / classroom [Rollup] aggregates that drive the
/// drill-down.
///
/// Pure — no I/O. The sync process calls this after `link()`, then hands the
/// result (with decisions merged in) to the `LinkedStore`. A class group is a
/// `LinkedGroup`, not an account, so it does not fit the per-account/classroom
/// shape: every linked class becomes its own [MaterializedGroup] in the
/// [groupsPartition] — one document per class since #227, not one per class with
/// work — and a single group [Rollup] ("Klasgroepen") aggregates them for the
/// Klasgroepen tab (#119). The account, staff, and group families — everything
/// the views render — are covered.
///
/// [schoolLabels] maps a WISA school id to its human label — the long name
/// with its short code, built by [wisaSchoolLabels] from the operator's
/// persisted school profiles merged with the WISA snapshot's schools list. A
/// student's school partition falls back to `School <id>` only for an id that
/// matches no known school (#204). [generation] is stamped onto the view for
/// the store to write.
MaterializedView materialize(
  LinkedState linked, {
  required int generation,
  Map<int, String> schoolLabels = const {},
}) {
  // Group the dispatched actions by the account/staff they target.
  final byAccount = <String, List<CandidateAction>>{};
  for (final a in linked.studentActions) {
    // Since #245 the student family has an informational member too
    // (`AzureClassGroupMembership`), so the flag is read off the action rather
    // than assumed — a diagnosis must not count as pending work or offer an
    // apply the action would throw on. The alternative-group keys ride along
    // since #251 so the persisted view can tell one either/or from two to-dos.
    (byAccount[a.target.id.value] ??= <CandidateAction>[]).add(_candidate(
      'student',
      a,
      a.describeChanges(),
      canApply: a.canApply,
      alternativeGroup: a.alternativeGroup,
      isDefaultAlternative: a.isDefaultAlternative,
      noticeFor: a.noticeFor,
    ));
  }
  final byStaff = <String, List<CandidateAction>>{};
  for (final a in linked.staffActions) {
    // Read off the action like the other two families since #240: every staff
    // action is applyable today, but nothing here should assume it.
    (byStaff[a.target.id.value] ??= <CandidateAction>[]).add(_candidate(
      'staff',
      a,
      a.describeChanges(),
      canApply: a.canApply,
      alternativeGroup: a.alternativeGroup,
      isDefaultAlternative: a.isDefaultAlternative,
      noticeFor: a.noticeFor,
    ));
  }

  // Account-scoped warnings, keyed by the Smartschool uid they name.
  final warningsByUid = _warningsByUid(linked.snapshot.warnings);

  final accounts = <MaterializedAccount>[];
  var skippedUnmanagedStudents = 0;
  for (final account in linked.snapshot.accounts) {
    // #178: keep the Actions view to schools we manage. A student present only
    // in a sibling school we do not manage ([WisaPresence.groupOnly]) with no
    // account of ours is purely a sibling-school student — never surface them.
    // A groupOnly student who still has one of *our* accounts is a departed
    // student whose Smartschool/Azure cleanup we keep (#134); [_placeAccount]
    // re-buckets them to "Niet toegewezen" so no non-managed school node shows.
    //
    // The drop is counted (#230): silently vanishing is indistinguishable from
    // a student the pull never returned, which is exactly how an unflagged
    // school in Instellingen used to read — no node, no count, no log line, and
    // an operator hunting a missing intake with nothing to go on.
    if (account.wisaPresence == core.WisaPresence.groupOnly &&
        account.smartschool == null &&
        account.azure == null) {
      skippedUnmanagedStudents++;
      continue;
    }
    final place = _placeAccount(account, schoolLabels);
    accounts.add(MaterializedAccount(
      id: account.id,
      school: place.school,
      schoolLabel: place.schoolLabel,
      gradeYear: place.gradeYear,
      classroom: place.classroom,
      role: account.role,
      isStaff: false,
      confidence: account.confidence,
      label: _accountLabel(account),
      inWisa: account.wisa != null,
      inSmartschool: account.smartschool != null,
      inAzure: account.azure != null,
      otherEnrolments: _otherEnrolments(account, schoolLabels),
      warnings: _warningsFor(account.smartschool, warningsByUid),
      candidates: byAccount[account.id.value] ?? const [],
    ));
  }
  var skippedUnmanagedStaff = 0;
  for (final staff in linked.snapshot.staff) {
    // #340: keep the Personeel list to our own school. The shared WISA
    // credentials walk every school of the group, so `linked.snapshot.staff`
    // holds the group's entire personeel — 2574 rows where our own school has a
    // couple of hundred — and every one of them used to become a row here.
    //
    // The filter belongs *here* and nowhere upstream. A teacher who left us for
    // a sibling group school must keep arriving in the WISA snapshot and must
    // keep a non-null `wisa` on their record, because that is the sole reason
    // `RemoveStaffFromAzure` and `RemoveStaffFromSmartschool` do not fire on
    // them; narrowing the pull, or the linker's staff pass, would start
    // proposing the deletion of Office 365 accounts of people the group still
    // employs. So the record stays, in full, and only the *view* leaves it out.
    //
    // Counted like its student twin (#230) so the drop is never silent: a
    // personeelslid an operator cannot find should read as "filtered by the
    // managed-school flags in Instellingen", not as "the pull never returned
    // them".
    if (!staff.belongsToOurSchool) {
      skippedUnmanagedStaff++;
      continue;
    }
    accounts.add(MaterializedAccount(
      id: staff.id,
      school: _staffSchool,
      schoolLabel: _staffLabel,
      gradeYear: _staffLabel,
      classroom: _staffLabel,
      role: staff.role,
      isStaff: true,
      confidence: staff.confidence,
      label: _staffMemberLabel(staff),
      inWisa: staff.wisa != null,
      inSmartschool: staff.smartschool != null,
      inAzure: staff.azure != null,
      departmentSchools: _departmentSchools(staff),
      warnings: _warningsFor(staff.smartschool, warningsByUid),
      candidates: byStaff[staff.id.value] ?? const [],
    ));
  }

  final groups =
      _materializeGroups(linked.snapshot.groups, linked.groupActions);

  final rollups = buildRollups(accounts);
  final groupsRollup = _buildGroupsRollup(groups);

  return MaterializedView(
    generation: generation,
    accounts: accounts,
    groups: groups,
    rollups: [...rollups, if (groupsRollup != null) groupsRollup],
    skippedUnmanagedStudents: skippedUnmanagedStudents,
    skippedUnmanagedStaff: skippedUnmanagedStaff,
  );
}

/// Turns the **linked class groups** into one [MaterializedGroup] each, in
/// snapshot order, with the dispatched group actions joined on.
///
/// The input used to be the actions alone (#119), so a class with nothing wrong
/// had no document at all: the persisted group partition held "the classes with
/// work", never the class inventory. That is what #227 needed — an operator
/// cannot tell a correct proposal from a wrong one without seeing what is
/// already in place — so the linked group list drives it now and the actions are
/// joined on by key. A class with no candidates is the healthy, normal case.
///
/// Each group still carries every candidate raised against it, including the
/// informational ones (`canApply == false`) that surface an orphan/empty-class
/// notice or a class Smartschool already has (#225/#250).
///
/// An action whose target is somehow not in [groups] still gets a document, so a
/// dispatched action can never be dropped on the floor by the join.
List<MaterializedGroup> _materializeGroups(
  List<core.LinkedGroup> groups,
  List<actions.GroupAction> groupActions,
) {
  final byGroup = <String, List<CandidateAction>>{};
  final targets = <String, core.LinkedGroup>{
    for (final g in groups) _groupKey(g): g,
  };
  for (final a in groupActions) {
    final key = _groupKey(a.target);
    (byGroup[key] ??= <CandidateAction>[]).add(_candidate(
      'group',
      a,
      a.describeChanges(),
      canApply: a.canApply,
      alternativeGroup: a.alternativeGroup,
      isDefaultAlternative: a.isDefaultAlternative,
      // The group family is the only one with notices today (#329) — the
      // namesake and empty-class instructions, which are context on the
      // blacklist beside them rather than decisions of their own.
      noticeFor: a.noticeFor,
    ));
    targets.putIfAbsent(key, () => a.target);
  }
  return [
    for (final entry in targets.entries)
      MaterializedGroup(
        id: core.LinkedAccountId(entry.key),
        label: _groupLabel(entry.value),
        confidence: entry.value.confidence,
        inWisa: entry.value.wisa != null,
        inSmartschool: entry.value.smartschool != null,
        inAzure: entry.value.azure != null,
        description: _groupDescription(entry.value),
        className: entry.value.className,
        // The Office 365 group is per *class*, so every sub-group record of a
        // split class names the one group its parent owns (#228).
        azureGroupName: entry.value.azure?.displayName,
        candidates: byGroup[entry.key] ?? const [],
      ),
  ];
}

/// The single "Klasgroepen" [Rollup] over every [MaterializedGroup], or `null`
/// when there is no class at all. Since #227 [accountCount] is the size of the
/// whole class inventory (it used to be "classes with work"); [pendingCount] is
/// the **decisions** they carry ([pendingDecisionCount], #251) — since #244
/// every new class of the school year is one create-or-ignore either/or, which
/// counted as two.
Rollup? _buildGroupsRollup(List<MaterializedGroup> groups) {
  if (groups.isEmpty) return null;
  var pending = 0;
  for (final g in groups) {
    pending += pendingDecisionCount(g.candidates);
  }
  return Rollup(
    level: RollupLevel.groups,
    key: groupsPartition,
    parentKey: null,
    school: groupsPartition,
    label: _groupsLabel,
    gradeYear: '',
    classroom: '',
    accountCount: groups.length,
    pendingCount: pending,
  );
}

/// Derives the school / grade-year / classroom [Rollup] tree from the
/// materialized [accounts]. Exposed for direct testing: each node's
/// [Rollup.accountCount] is the number of accounts beneath it and
/// [Rollup.pendingCount] the total pending **decisions** they carry — one per
/// either/or, not one per alternative ([pendingDecisionCount], #251).
List<Rollup> buildRollups(List<MaterializedAccount> accounts) {
  // classroomKey -> aggregate; grade/school keys accumulate from these.
  final classrooms = <String, _Agg>{};
  final grades = <String, _Agg>{};
  final schools = <String, _Agg>{};

  for (final a in accounts) {
    final pending = pendingDecisionCount(a.candidates);
    final schoolKey = _schoolKey(a.school);
    final gradeKey = _gradeKey(a.school, a.gradeYear);
    final classKey = _classroomKey(a.school, a.gradeYear, a.classroom);
    (schools[schoolKey] ??= _Agg(
      level: RollupLevel.school,
      key: schoolKey,
      parentKey: null,
      school: a.school,
      label: a.schoolLabel,
      gradeYear: '',
      classroom: '',
    ))
        .add(pending);
    (grades[gradeKey] ??= _Agg(
      level: RollupLevel.gradeYear,
      key: gradeKey,
      parentKey: schoolKey,
      school: a.school,
      label: a.gradeYear,
      gradeYear: a.gradeYear,
      classroom: '',
    ))
        .add(pending);
    (classrooms[classKey] ??= _Agg(
      level: RollupLevel.classroom,
      key: classKey,
      parentKey: gradeKey,
      school: a.school,
      label: a.classroom,
      gradeYear: a.gradeYear,
      classroom: a.classroom,
    ))
        .add(pending);
  }

  return [
    for (final a in schools.values) a.toRollup(),
    for (final a in grades.values) a.toRollup(),
    for (final a in classrooms.values) a.toRollup(),
  ];
}

/// One rollup node's share of what a **real apply** changed, expressed as a
/// *delta* rather than as a recomputed count (#254).
///
/// An apply's session only ever holds its own link, which is a snapshot of the
/// three systems as they stood when it last synced. Writing rollups derived from
/// that snapshot back into the shared view would publish this session's whole
/// picture of a node — resurrecting the work another operator applied and wrote
/// in the meantime. A delta cannot: two operators each subtract only what their
/// own pass cleared, and the store folds both into whatever it currently holds.
///
/// [applyTo] is the fold, so the arithmetic lives in one place and both the
/// in-memory and the Cosmos store run exactly the same rule.
class RollupChange {
  RollupChange._({
    required this.level,
    required this.key,
    required this.parentKey,
    required this.school,
    required this.label,
    required this.gradeYear,
    required this.classroom,
  });

  final RollupLevel level;

  /// The node's stable key — the [Rollup.key] this change applies to.
  final String key;
  final String? parentKey;
  final String school;

  /// The label to give the node when the store has none yet; an existing node
  /// keeps the label the sync path gave it (see [applyTo]).
  final String label;

  final String gradeYear;
  final String classroom;

  int _accounts = 0;
  int _pending = 0;

  /// How many documents this node gained (positive) or lost (negative).
  int get accountDelta => _accounts;

  /// How far this node's pending-decision total moved.
  int get pendingDelta => _pending;

  void _add({required int accounts, required int pending}) {
    _accounts += accounts;
    _pending += pending;
  }

  /// This node as it must be stored once the delta is folded into [current] —
  /// the node the store holds right now, or `null` when it has none yet — or
  /// `null` when the node is left with no documents at all and its record should
  /// be deleted (an empty node is one the sync path would not emit either).
  ///
  /// The label, not being a count, is **not** ours to move: an apply changes who
  /// is pending, never what a school is called, so an existing node keeps the
  /// label the last materialize gave it.
  Rollup? applyTo(Rollup? current) {
    final accounts = (current?.accountCount ?? 0) + _accounts;
    if (accounts <= 0) return null;
    final pending = (current?.pendingCount ?? 0) + _pending;
    return Rollup(
      level: level,
      key: key,
      parentKey: parentKey,
      school: school,
      label: current?.label ?? label,
      gradeYear: gradeYear,
      classroom: classroom,
      accountCount: accounts,
      // A delta computed against a document another writer had already
      // corrected can only ever over-subtract; never advertise a negative badge.
      pendingCount: pending < 0 ? 0 : pending,
    );
  }
}

/// The rollup-node deltas one real apply makes, from the documents the **store**
/// held for the ids the pass touched ([storedAccounts] / [storedGroups]) and the
/// ones the refreshed link produced for them ([freshAccounts] / [freshGroups]).
///
/// Pure and total: a document present only in the stored set counts as removed,
/// one present only in the fresh set as added, and one in both contributes the
/// difference of its [pendingDecisionCount]. Every node above a touched document
/// — its classroom, its grade-year and its school, or the single Klasgroepen
/// node for a class group — gets its share, so the badges above a drill-down
/// stay the sum of what is under them.
///
/// Nodes whose counts do not move at all are left out, so a pass that wrote
/// nothing of consequence touches no rollup document.
List<RollupChange> rollupChangesFor({
  Iterable<MaterializedAccount> storedAccounts = const [],
  Iterable<MaterializedAccount> freshAccounts = const [],
  Iterable<MaterializedGroup> storedGroups = const [],
  Iterable<MaterializedGroup> freshGroups = const [],
}) {
  final changes = <String, RollupChange>{};

  void foldAccount(MaterializedAccount a, int sign) {
    final pending = pendingDecisionCount(a.candidates) * sign;
    final schoolKey = _schoolKey(a.school);
    final gradeKey = _gradeKey(a.school, a.gradeYear);
    final classKey = _classroomKey(a.school, a.gradeYear, a.classroom);
    (changes[schoolKey] ??= RollupChange._(
      level: RollupLevel.school,
      key: schoolKey,
      parentKey: null,
      school: a.school,
      label: a.schoolLabel,
      gradeYear: '',
      classroom: '',
    ))
        ._add(accounts: sign, pending: pending);
    (changes[gradeKey] ??= RollupChange._(
      level: RollupLevel.gradeYear,
      key: gradeKey,
      parentKey: schoolKey,
      school: a.school,
      label: a.gradeYear,
      gradeYear: a.gradeYear,
      classroom: '',
    ))
        ._add(accounts: sign, pending: pending);
    (changes[classKey] ??= RollupChange._(
      level: RollupLevel.classroom,
      key: classKey,
      parentKey: gradeKey,
      school: a.school,
      label: a.classroom,
      gradeYear: a.gradeYear,
      classroom: a.classroom,
    ))
        ._add(accounts: sign, pending: pending);
  }

  void foldGroup(MaterializedGroup g, int sign) {
    (changes[groupsPartition] ??= RollupChange._(
      level: RollupLevel.groups,
      key: groupsPartition,
      parentKey: null,
      school: groupsPartition,
      label: _groupsLabel,
      gradeYear: '',
      classroom: '',
    ))
        ._add(
      accounts: sign,
      pending: pendingDecisionCount(g.candidates) * sign,
    );
  }

  for (final a in storedAccounts) {
    foldAccount(a, -1);
  }
  for (final a in freshAccounts) {
    foldAccount(a, 1);
  }
  for (final g in storedGroups) {
    foldGroup(g, -1);
  }
  for (final g in freshGroups) {
    foldGroup(g, 1);
  }

  return [
    for (final c in changes.values)
      if (c.accountDelta != 0 || c.pendingDelta != 0) c,
  ];
}

// ---------------------------------------------------------------------------
// Placement.
// ---------------------------------------------------------------------------

const String _staffSchool = staffPartition;
const String _staffLabel = 'Personeel';
const String _unassignedSchool = unassignedPartition;
const String _unassignedLabel = 'Niet toegewezen';
const String _noGrade = 'Overig';
const String _noClassroom = 'Zonder klas';
const String _groupsLabel = 'Klasgroepen';

class _Placement {
  const _Placement({
    required this.school,
    required this.schoolLabel,
    required this.gradeYear,
    required this.classroom,
  });
  final String school;
  final String schoolLabel;
  final String gradeYear;
  final String classroom;
}

/// A student's location comes from its WISA record (school id + class group),
/// but only when they are present in a school we **manage**
/// ([LinkedAccount.isInOurWisa]). A student who left our school — gone from the
/// group ([WisaPresence.absent]) or moved to a sibling school we don't manage
/// ([WisaPresence.groupOnly], #178) — has no class *of ours*, so it lands in the
/// `unassigned` bucket rather than surfacing a non-managed school node. There is
/// no "alumni" state; a departed student is an incomplete account (per #47).
_Placement _placeAccount(
  core.LinkedAccount account,
  Map<int, String> schoolLabels,
) {
  final wisa = account.wisa;
  if (wisa is wapi.WisaStudent && account.isInOurWisa) {
    final school = wisa.schoolId.toString();
    return _Placement(
      school: school,
      schoolLabel: schoolLabels[wisa.schoolId] ??
          wisaSchoolLabel(schoolId: wisa.schoolId),
      gradeYear: gradeYearOf(wisa.classGroup),
      classroom: wisa.classGroup.trim().isEmpty
          ? _noClassroom
          : wisa.classGroup.trim(),
    );
  }
  return const _Placement(
    school: _unassignedSchool,
    schoolLabel: _unassignedLabel,
    gradeYear: _noGrade,
    classroom: _noClassroom,
  );
}

/// The group schools this person is enrolled in **besides** the one the card's
/// own class facts come from (#334) — empty for the ordinary single-school
/// account, which is every account but a handful.
///
/// Only a person the aggregated pull returned from more than one school has any:
/// with a single row there is nothing to say, so a single-school card renders
/// exactly as it did before this existed. The row left out is the one
/// [_placeAccount] already placed the card in — our school's, the authoritative
/// one (INV-25). When the placement fell through to `unassigned` no row was
/// shown, so every school is named: a departed dual-enrolled student's card
/// carries no class of ours to contradict, and where she went is the whole
/// answer it can give.
///
/// School names come from [schoolLabels] — the WISA school list merged with the
/// operator's persisted profiles — degrading to `wisaSchoolLabel`'s last-resort
/// `School <id>` for an id no list knows. Never a name invented from an id
/// (#204/#208). Ordered by school id so one enrolment reads the same way twice.
List<OtherEnrolment> _otherEnrolments(
  core.LinkedAccount account,
  Map<int, String> schoolLabels,
) {
  if (account.wisaClassGroups.length < 2) return const [];
  final wisa = account.wisa;
  final int? placed =
      wisa is wapi.WisaStudent && account.isInOurWisa ? wisa.schoolId : null;
  final ids = account.wisaClassGroups.keys.where((id) => id != placed).toList()
    ..sort();
  return <OtherEnrolment>[
    for (final id in ids)
      OtherEnrolment(
        schoolLabel: schoolLabels[id] ?? wisaSchoolLabel(schoolId: id),
        classroom: account.wisaClassGroups[id]!.trim(),
      ),
  ];
}

/// The schools a staff member's Azure `department` lists, in the field's own
/// order and casing (#352) — empty for a record with no Office 365 account, and
/// for one whose `department` is blank.
///
/// The whole list, ours included: "nobody but us claims this account" is the
/// condition under which a departure *deletes* rather than releases, so it is
/// precisely the thing an operator needs confirmed before pressing. Filtering
/// our own prefix out (as [core.departmentSchoolsExcept] does for the *write*)
/// would withhold exactly that.
///
/// Read through the concrete [az.AzureUser] because [core.LinkedStaff.azure] is
/// the narrow interface, which carries no `department` — the same reason the
/// linker evaluates `azureNamesOurSchool` off the record rather than the link
/// (#340), and the same narrowing [_otherEnrolments] does for a WISA row's
/// school id. A record built from some other implementation of the interface
/// simply has nothing to say here.
///
/// Never a value to write: `department` is maintained by other software and is
/// not ours to touch (#237). This states it and stops.
List<String> _departmentSchools(core.LinkedStaff staff) {
  final azure = staff.azure;
  if (azure is! az.AzureUser) return const [];
  return core.departmentSchools(azure.department);
}

/// The grade-year bucket for a WISA class group: its leading run of digits
/// (`3C` → `3`, `1A` → `1`), or [_noGrade] when the group is non-numeric
/// (`OKAN`, `Zonder klas`).
String gradeYearOf(String classGroup) {
  final match = RegExp(r'^\s*(\d+)').firstMatch(classGroup);
  return match == null ? _noGrade : match.group(1)!;
}

// ---------------------------------------------------------------------------
// Warnings.
// ---------------------------------------------------------------------------

Map<String, List<String>> _warningsByUid(List<core.LinkWarning> warnings) {
  final byUid = <String, List<String>>{};
  for (final w in warnings) {
    switch (w) {
      case core.ResolveDuplicateMail(:final mail, :final accounts):
        final message =
            'Dubbele mail "$mail" op ${accounts.length} Smartschool-accounts.';
        for (final a in accounts) {
          (byUid[a.uid] ??= <String>[]).add(message);
        }
      case core.SmartschoolNamesakeSkipped():
        // Names a *class*, not an account, so it has no uid to hang on. The
        // class itself carries the situation as the informational
        // `ClassExistsAsSmartschoolGroup` candidate on its group document, and
        // the sync log names every skipped namesake (#225).
        break;
      case core.DuplicateLinkedId():
        // Names an *id*, not an account (#319). Deliberately not hung on a uid,
        // for two reasons. The colliding records materialize onto the same
        // document, so the card a per-uid string would land on is itself the
        // symptom — the thing the operator cannot trust. And `decisions_merge`
        // reads `MaterializedAccount.warnings` type-blind: any warning string
        // there is taken as evidence that an accepted duplicate-*mail*
        // collision still exists, so hanging an unrelated warning on an account
        // would quietly keep a stale acceptance alive.
        //
        // It is surfaced snapshot-wide instead: the sync log names every
        // collision and the Synchronisatie overview lists what each colliding
        // record holds. Both are reachable with no Smartschool account at all,
        // which a uid-keyed message would not be.
        break;
      case core.DuplicateAzureEmployeeId():
        // Names an *Office 365 identity*, not a Smartschool account (INV-26,
        // #360) — and the abandoned twin is precisely the account with no
        // Smartschool side to hang a uid message on, so a per-uid string would
        // report the pair on whichever half happens to have one, or on neither.
        // The `decisions_merge` hazard above applies here too: warning strings
        // on a `MaterializedAccount` are read type-blind as a live
        // duplicate-*mail* collision, so an unrelated one would keep a stale
        // acceptance alive.
        //
        // Surfaced snapshot-wide instead, like the collision above: the sync log
        // names every shared employeeId and the Synchronisatie overview lists
        // each claiming account with the facts an operator picks by. The record
        // itself still carries the ambiguity, on
        // `LinkedAccount.azureDuplicates`.
        break;
    }
  }
  return byUid;
}

List<String> _warningsFor(
  core.SmartschoolAccount? smartschool,
  Map<String, List<String>> byUid,
) {
  final uid = smartschool?.uid;
  if (uid == null) return const [];
  return byUid[uid] ?? const [];
}

// ---------------------------------------------------------------------------
// Candidate + label helpers.
// ---------------------------------------------------------------------------

CandidateAction _candidate(
  String family,
  Object action,
  actions.ChangeSet changes, {
  required bool canApply,
  required String? alternativeGroup,
  required bool isDefaultAlternative,
  String? noticeFor,
}) =>
    CandidateAction(
      family: family,
      kind: action.runtimeType.toString(),
      system: changes.system,
      summary: changes.summary,
      fields: changes.fields,
      canApply: canApply,
      alternativeGroup: alternativeGroup,
      isDefaultAlternative: isDefaultAlternative,
      noticeFor: noticeFor,
    );

// The core linked records carry only linking keys; human names live on the
// concrete connector records — mirror the reconcile controller's label logic.

String _accountLabel(core.LinkedAccount a) {
  final wisa = a.wisa;
  if (wisa is wapi.WisaStudent) {
    return _nonEmpty('${wisa.firstName} ${wisa.name}') ?? wisa.wisaId.value;
  }
  return _personLabel(a.smartschool, a.azure) ??
      wisa?.wisaId.value ??
      '(account)';
}

String _staffMemberLabel(core.LinkedStaff s) {
  final wisa = s.wisa;
  if (wisa is wapi.WisaStaff) {
    return _nonEmpty('${wisa.firstName} ${wisa.lastName}') ?? wisa.code.value;
  }
  return _personLabel(s.smartschool, s.azure) ??
      wisa?.code.value ??
      '(personeelslid)';
}

/// The stable cross-system key for a group document (#119): its name (the
/// linker's cross-system match key), namespaced so it never collides with an
/// account id. A group always carries at least one system record.
String _groupKey(core.LinkedGroup g) =>
    materializedGroupId(_groupName(g) ?? '?');

/// The [MaterializedGroup.id] of the class group displayed as [name].
///
/// Exposed because the reconcile controller keys its pending group entries by
/// the group's *display name* (that is what the operator sees and what the
/// widget keys use), while the stored document is keyed by this namespaced form
/// — so a post-apply write-back (#254) has to cross from one to the other, and
/// must do it through the very expression the materializer itself uses.
String materializedGroupId(String name) => 'group|$name';

/// Display label for a group — its WISA / Smartschool / Azure name.
String _groupLabel(core.LinkedGroup g) => _groupName(g) ?? '(groep)';

/// The class's human description — WISA's wording first (it is the system of
/// record for a class), Smartschool's as a fallback for an orphan (#227).
String _groupDescription(core.LinkedGroup g) =>
    _nonEmpty(g.wisa?.description ?? '') ??
    _nonEmpty(g.smartschool?.description ?? '') ??
    '';

String? _groupName(core.LinkedGroup g) =>
    _nonEmpty(g.wisa?.name ?? '') ??
    _nonEmpty(g.smartschool?.name ?? '') ??
    _nonEmpty(g.azure?.displayName ?? '');

String? _personLabel(
    core.SmartschoolAccount? smartschool, core.AzureUser? azure) {
  if (smartschool is ss.SmartschoolAccount) {
    return _nonEmpty('${smartschool.givenName} ${smartschool.surname}') ??
        smartschool.uid;
  }
  if (smartschool != null) return smartschool.uid;
  return azure?.upn;
}

String? _nonEmpty(String s) {
  final trimmed = s.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ---------------------------------------------------------------------------
// Rollup keys + accumulation.
// ---------------------------------------------------------------------------

String _schoolKey(String school) => 'school|$school';
String _gradeKey(String school, String gradeYear) => 'grade|$school|$gradeYear';
String _classroomKey(String school, String gradeYear, String classroom) =>
    'class|$school|$gradeYear|$classroom';

class _Agg {
  _Agg({
    required this.level,
    required this.key,
    required this.parentKey,
    required this.school,
    required this.label,
    required this.gradeYear,
    required this.classroom,
  });

  final RollupLevel level;
  final String key;
  final String? parentKey;
  final String school;
  final String label;
  final String gradeYear;
  final String classroom;

  int accountCount = 0;
  int pendingCount = 0;

  void add(int pending) {
    accountCount++;
    pendingCount += pending;
  }

  Rollup toRollup() => Rollup(
        level: level,
        key: key,
        parentKey: parentKey,
        school: school,
        label: label,
        gradeYear: gradeYear,
        classroom: classroom,
        accountCount: accountCount,
        pendingCount: pendingCount,
      );
}
