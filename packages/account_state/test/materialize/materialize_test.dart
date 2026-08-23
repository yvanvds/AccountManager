import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

final DateTime _d = DateTime.utc(2026, 7, 1);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

wapi.WisaStudent _wStudent({
  String wisaId = '1',
  String classGroup = '3C',
  int schoolId = 1,
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: '',
      name: 'Doe',
      firstName: 'Jane',
      preferredName: '',
      birthDate: _d,
      stemId: '',
      gender: core.Gender.female,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: _addr,
      classChange: _d,
      schoolId: schoolId,
    );

ss.SmartschoolAccount _ssAccount({
  String uid = 'jane',
  String accountId = '1',
  String mail = 'jane@school.example',
}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: mail,
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
      birthDate: null,
      birthPlace: '',
      birthCountry: '',
      address: _addr,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

az.AzureUser _azUser({String id = 'az1', String? employeeId = '1'}) =>
    az.AzureUser(
      id: id,
      upn: 'jane@school.example',
      employeeId: employeeId,
      companyName: 'GBS',
    );

core.Group _ssGroup(
  String name, {
  String? code,
  String description = '',
  String? instituteNumber,
  String untis = '',
}) =>
    core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: description,
      type: core.GroupType.classGroup,
      official: true,
      instituteNumber: instituteNumber,
      untis: untis,
      origin: core.Origin.smartschool,
    );

final _studentConfig =
    StudentActionConfig(schoolPrefix: 'GBS', azureDomain: 'school.example');
final _staffConfig =
    StaffActionConfig(schoolPrefix: 'GBS', azureDomain: 'school.example');

class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

/// A fully-linked student whose WISA class (3C) differs from her Smartschool
/// membership (2B), so the dispatch yields exactly one pending action
/// (`MoveToSmartschoolClassGroup`) — the shared fixture scenario.
LinkedState _movePendingLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: [_wStudent(classGroup: '3C')],
        staff: const [],
        classGroups: const [],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: [_ssGroup('2B', code: '2B_ss')],
        accounts: [_ssAccount()],
        memberships: const [
          ss.SmartschoolMembership(uid: 'jane', groupId: core.GroupId('2B_ss')),
        ],
      ),
      azure:
          az.AzureSnapshot(fetchedAt: _d, users: [_azUser()], groups: const []),
      resolver: _SeqResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
    );

/// A class present in **both** WISA and Smartschool whose institute number
/// drifts, so the group dispatch yields exactly one *applyable*
/// `ModifySmartschoolData` — used to prove the group rollup counts pending.
LinkedState _modifyPendingLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: const [],
        staff: const [],
        classGroups: [
          const wapi.WisaClassGroup(
            name: '3C',
            groupName: '00',
            description: '',
            adminCode: '',
            schoolCode: '123',
            schoolId: 1,
          ),
        ],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: [_ssGroup('3C', code: '3C_ss')],
        accounts: const [],
        memberships: const [],
      ),
      azure: az.AzureSnapshot(fetchedAt: _d, users: const [], groups: const []),
      resolver: _SeqResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
    );

/// A class that is **entirely in order**: present in WISA, in Smartschool with
/// matching institute number / untis / description, and in Office 365 as
/// `GBS-3C` with its one student already in it. So the group dispatch raises
/// nothing at all for it — the shape that used to have no document whatsoever
/// (#227), which is why the class inventory could not be verified.
LinkedState _cleanClassLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: [_wStudent()],
        staff: const [],
        classGroups: [
          const wapi.WisaClassGroup(
            name: '3C',
            groupName: '00',
            description: 'Derde jaar C',
            adminCode: '',
            schoolCode: '123',
            schoolId: 1,
          ),
        ],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: [
          _ssGroup(
            '3C',
            code: '3C_ss',
            description: 'Derde jaar C',
            instituteNumber: '123',
            untis: '3C',
          ),
        ],
        accounts: [_ssAccount()],
        memberships: const [
          ss.SmartschoolMembership(uid: 'jane', groupId: core.GroupId('3C_ss')),
        ],
      ),
      azure: az.AzureSnapshot(
        fetchedAt: _d,
        users: [_azUser()],
        groups: [
          az.AzureGroup(
            id: 'az-GBS-3C',
            displayName: 'GBS-3C',
            mail: 'GBS-3C@school.example',
            mailNickname: 'GBS-3C',
            memberIds: const ['az1'],
          ),
        ],
      ),
      resolver: _SeqResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
    );

/// A linked view with no class groups at all (empty on both sides), so the
/// materializer emits no group docs and no group rollup.
LinkedState _noGroupsLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: [_wStudent()],
        staff: const [],
        classGroups: const [],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: const [],
        accounts: [_ssAccount()],
        memberships: const [],
      ),
      azure:
          az.AzureSnapshot(fetchedAt: _d, users: [_azUser()], groups: const []),
      resolver: _SeqResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
    );

MaterializedAccount _account({
  String id = 'p0',
  String school = '1',
  String classroom = '3C',
  List<CandidateAction> candidates = const [],
  List<String> warnings = const [],
}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: 'School $school',
      gradeYear: '3',
      classroom: classroom,
      role: core.PersonRole.student,
      isStaff: false,
      confidence: core.LinkConfidence.high,
      label: 'Jane Doe',
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      warnings: warnings,
      candidates: candidates,
    );

const _moveCandidate = CandidateAction(
  family: 'student',
  kind: 'MoveToSmartschoolClassGroup',
  system: core.Origin.smartschool,
  summary: 'Move to class',
);

void main() {
  group('materialize', () {
    test('one pending student → one account doc with its candidate + placement',
        () {
      final view = materialize(_movePendingLinked(), generation: 3);

      expect(view.generation, 3);
      expect(view.accounts, hasLength(1));
      final account = view.accounts.single;
      expect(account.id.value, 'p0');
      expect(account.school, '1', reason: 'partition = WISA school id');
      expect(account.schoolLabel, 'School 1');
      expect(account.gradeYear, '3');
      expect(account.classroom, '3C');
      expect(
          account.inWisa && account.inSmartschool && account.inAzure, isTrue);
      expect(
        account.candidates.map((c) => c.kind),
        contains('MoveToSmartschoolClassGroup'),
      );
      expect(account.candidates.every((c) => c.canApply), isTrue);
      expect(account.hasPending, isTrue);
    });

    test('rollup counts match the accounts beneath them', () {
      final view = materialize(_movePendingLinked(), generation: 1);
      final pending =
          view.accounts.single.candidates.where((c) => c.canApply).length;

      final school =
          view.rollups.firstWhere((r) => r.level == RollupLevel.school);
      final grade =
          view.rollups.firstWhere((r) => r.level == RollupLevel.gradeYear);
      final classroom =
          view.rollups.firstWhere((r) => r.level == RollupLevel.classroom);

      for (final r in [school, grade, classroom]) {
        expect(r.accountCount, 1, reason: '${r.level} account count');
        expect(r.pendingCount, pending, reason: '${r.level} pending count');
      }
      expect(school.key, 'school|1');
      expect(grade.parentKey, school.key);
      expect(classroom.parentKey, grade.key);
      expect(classroom.classroom, '3C');
    });

    test('school labels come from the provided map', () {
      final view = materialize(
        _movePendingLinked(),
        generation: 1,
        schoolLabels: {1: 'GBS Centrum'},
      );
      expect(view.accounts.single.schoolLabel, 'GBS Centrum');
    });

    test('a school-id label reaches the school rollup too (#204)', () {
      // What the Actions drill-down actually renders is the rollup's label, so
      // the pair has to survive the aggregation, not just the account doc.
      final view = materialize(
        _movePendingLinked(),
        generation: 1,
        schoolLabels: wisaSchoolLabels(profiles: const [
          WisaSchoolProfile(
            schoolId: 1,
            code: 'ISMAA',
            name: 'Instituut Sancta Maria-A',
          ),
        ]),
      );
      final school =
          view.rollups.firstWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('School <id> is the last resort for an unlabelled school', () {
      final view = materialize(
        _movePendingLinked(),
        generation: 1,
        schoolLabels: const {99: 'Ergens anders'},
      );
      expect(view.accounts.single.schoolLabel, 'School 1');
    });

    test('an Azure-only leaver lands in the unassigned bucket', () {
      final linked = LinkedState.recompute(
        wisa: wapi.WisaSnapshot(
          fetchedAt: _d,
          students: const [],
          staff: const [],
          classGroups: const [],
          schools: const [],
        ),
        smartschool: ss.SmartschoolSnapshot(
          fetchedAt: _d,
          groups: const [],
          accounts: const [],
          memberships: const [],
        ),
        azure: az.AzureSnapshot(
          fetchedAt: _d,
          users: [_azUser(employeeId: '999')],
          groups: const [],
        ),
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      final view = materialize(linked, generation: 1);
      expect(view.accounts, hasLength(1));
      final leaver = view.accounts.single;
      expect(leaver.school, 'unassigned');
      expect(leaver.inWisa, isFalse);
      expect(leaver.inAzure, isTrue);
    });

    test('every account doc round-trips through JSON', () {
      final account =
          materialize(_movePendingLinked(), generation: 1).accounts.single;
      final restored = MaterializedAccount.fromJson(account.toJson());
      expect(restored.id, account.id);
      expect(restored.classroom, account.classroom);
      expect(restored.candidates, hasLength(account.candidates.length));
      expect(
        restored.candidates.map((c) => c.kind),
        contains('MoveToSmartschoolClassGroup'),
      );
    });
  });

  group('materialize groups (#119)', () {
    test('a group action → a group doc in the groups partition + rollup', () {
      // The Smartschool-only 2B class raises the informational orphan notice.
      final view = materialize(_movePendingLinked(), generation: 2);

      expect(view.groups, hasLength(1));
      final group = view.groups.single;
      expect(group.id.value, 'group|2B');
      expect(group.label, '2B');
      expect(group.school, groupsPartition,
          reason: 'partition = groups bucket');
      expect(group.inSmartschool, isTrue);
      expect(group.inWisa, isFalse);
      expect(group.candidates, isNotEmpty);
      expect(group.candidates.every((c) => c.family == 'group'), isTrue);
      // The orphan notice is informational — nothing to apply.
      expect(group.hasPending, isFalse);

      final rollup =
          view.rollups.firstWhere((r) => r.level == RollupLevel.groups);
      expect(rollup.key, groupsPartition);
      expect(rollup.school, groupsPartition);
      expect(rollup.label, 'Klasgroepen');
      expect(rollup.accountCount, 1);
      expect(rollup.pendingCount, 0,
          reason: 'the orphan notice is informational');
    });

    test('an applyable group action counts toward the group rollup pending',
        () {
      final view = materialize(_modifyPendingLinked(), generation: 1);

      final group = view.groups.single;
      expect(group.inWisa && group.inSmartschool, isTrue);
      expect(group.candidates.map((c) => c.kind),
          contains('ModifySmartschoolData'));
      expect(group.hasPending, isTrue);

      final rollup =
          view.rollups.firstWhere((r) => r.level == RollupLevel.groups);
      expect(rollup.pendingCount, greaterThan(0));
    });

    test('no class groups at all → no group docs and no group rollup', () {
      final view = materialize(_noGroupsLinked(), generation: 1);
      expect(view.groups, isEmpty);
      expect(view.rollups.where((r) => r.level == RollupLevel.groups), isEmpty);
    });

    test('every group doc round-trips through JSON', () {
      final group =
          materialize(_movePendingLinked(), generation: 1).groups.single;
      final restored = MaterializedGroup.fromJson(group.toJson());
      expect(restored.id, group.id);
      expect(restored.label, group.label);
      expect(restored.inSmartschool, isTrue);
      expect(restored.candidates, hasLength(group.candidates.length));
    });
  });

  group('the class inventory covers every class (#227)', () {
    test('a class with nothing wrong still gets a document', () {
      // The whole point of the tab: the documents come from the linked class
      // list, not from the dispatched actions, so a healthy class is on the
      // inventory — with a tick in all three columns and no candidate at all.
      final view = materialize(_cleanClassLinked(), generation: 1);

      expect(view.groups, hasLength(1));
      final group = view.groups.single;
      expect(group.label, '3C');
      expect(group.candidates, isEmpty,
          reason: 'nothing is wrong with this class');
      expect(group.hasPending, isFalse);
      expect(group.needsAttention, isFalse);
      expect(group.inWisa, isTrue);
      expect(group.inSmartschool, isTrue);
      expect(group.inAzure, isTrue);
    });

    test('the row carries its description, bare class name and O365 group', () {
      final group =
          materialize(_cleanClassLinked(), generation: 1).groups.single;
      expect(group.description, 'Derde jaar C');
      expect(group.className, '3C');
      expect(group.azureGroupName, 'GBS-3C',
          reason: 'the Office 365 column names the group, not just a tick');

      final restored = MaterializedGroup.fromJson(group.toJson());
      expect(restored.description, 'Derde jaar C');
      expect(restored.className, '3C');
      expect(restored.azureGroupName, 'GBS-3C');
    });

    test('the Klasgroepen rollup counts every class, pending only the work',
        () {
      // accountCount used to mean "classes with work"; it is the inventory size
      // now, while pendingCount still counts decisions (#251).
      final view = materialize(_cleanClassLinked(), generation: 1);
      final rollup =
          view.rollups.firstWhere((r) => r.level == RollupLevel.groups);
      expect(rollup.accountCount, 1);
      expect(rollup.pendingCount, 0);
    });

    test('an informational-only notice is attention, not pending work', () {
      // #225/#250: a class Smartschool already holds carries manual work with no
      // automated write, so it must not be filtered away with the pending count.
      final group =
          materialize(_movePendingLinked(), generation: 1).groups.single;
      expect(group.hasPending, isFalse);
      expect(group.needsAttention, isTrue);
    });
  });

  group('managed schools only (#178)', () {
    // A fully-linked student (WISA + our Smartschool + our Azure) whose WISA
    // record sits in [schoolId]. [ourSchoolIds] is the operator's managed set;
    // when it omits [schoolId] the student is classified groupOnly.
    LinkedState linkedInSchool({
      required int schoolId,
      Set<int>? ourSchoolIds,
      bool withOurAccounts = true,
    }) =>
        LinkedState.recompute(
          wisa: wapi.WisaSnapshot(
            fetchedAt: _d,
            students: [_wStudent(schoolId: schoolId)],
            staff: const [],
            classGroups: const [],
            schools: const [],
          ),
          smartschool: ss.SmartschoolSnapshot(
            fetchedAt: _d,
            groups: const [],
            accounts: withOurAccounts ? [_ssAccount()] : const [],
            memberships: const [],
          ),
          azure: az.AzureSnapshot(
            fetchedAt: _d,
            users: withOurAccounts ? [_azUser()] : const [],
            groups: const [],
          ),
          resolver: _SeqResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
          ourSchoolIds: ourSchoolIds,
        );

    test('a student in a managed school is placed under that school node', () {
      final view = materialize(linkedInSchool(schoolId: 1, ourSchoolIds: {1}),
          generation: 1);

      expect(view.accounts, hasLength(1));
      expect(view.accounts.single.school, '1');
      expect(
        view.rollups.any((r) => r.school == '1'),
        isTrue,
        reason: 'the managed school shows a rollup node',
      );
    });

    test(
        'a student in a non-managed sibling school (groupOnly) but still in our '
        'systems is re-bucketed to unassigned — no non-managed school node',
        () {
      // School 1 is ours; the student sits in school 2 → groupOnly, yet keeps a
      // Smartschool + Azure account we must clean up (#134).
      final view = materialize(linkedInSchool(schoolId: 2, ourSchoolIds: {1}),
          generation: 1);

      expect(view.accounts, hasLength(1),
          reason:
              'the departed student is kept (its cleanup stays actionable)');
      expect(view.accounts.single.school, 'unassigned',
          reason: 'not under the non-managed school 2');
      expect(
        view.rollups.any((r) => r.school == '2'),
        isFalse,
        reason: 'no rollup node for a school we do not manage',
      );
    });

    test(
        'a WISA-only student present only in a non-managed school is suppressed '
        'entirely', () {
      // No account of ours anywhere — a pure sibling-school student we never
      // touch. They must not surface in the Actions view at all.
      final view = materialize(
        linkedInSchool(schoolId: 2, ourSchoolIds: {1}, withOurAccounts: false),
        generation: 1,
      );

      expect(view.accounts, isEmpty);
      expect(view.rollups.where((r) => r.level == RollupLevel.school), isEmpty);
    });

    test('the suppressed student is counted, not silently dropped (#230)', () {
      // Suppressing them is right (#178), vanishing without trace is not: an
      // unflagged school in Instellingen then looks exactly like a WISA pull
      // that never returned the class, which is what the operator hit.
      final view = materialize(
        linkedInSchool(schoolId: 2, ourSchoolIds: {1}, withOurAccounts: false),
        generation: 1,
      );

      expect(view.skippedUnmanagedStudents, 1);
    });

    test('nothing is counted when every student is placed (#230)', () {
      final managed = materialize(
        linkedInSchool(schoolId: 1, ourSchoolIds: {1}),
        generation: 1,
      );
      expect(managed.skippedUnmanagedStudents, 0);

      // A groupOnly student who still owns one of our accounts is *kept* (#134)
      // — re-bucketed, not skipped, so counting them would be a false alarm.
      final departed = materialize(
        linkedInSchool(schoolId: 2, ourSchoolIds: {1}),
        generation: 1,
      );
      expect(departed.accounts, hasLength(1));
      expect(departed.skippedUnmanagedStudents, 0);
    });

    test('toggling the managed set flips which schools appear', () {
      // Same student in school 2. Not managing school 2 → suppressed from the
      // school tree (re-bucketed to unassigned); managing it → it shows.
      final unmanaged = materialize(
          linkedInSchool(schoolId: 2, ourSchoolIds: {1}),
          generation: 1);
      expect(unmanaged.rollups.any((r) => r.school == '2'), isFalse);

      final managed = materialize(
          linkedInSchool(schoolId: 2, ourSchoolIds: {1, 2}),
          generation: 1);
      expect(managed.accounts.single.school, '2');
      expect(managed.rollups.any((r) => r.school == '2'), isTrue);
    });

    test('with no managed set every school is ours, so nobody is re-bucketed',
        () {
      // ourSchoolIds null → ownership is unconfigured (#286), which counts every
      // school, so a school-1 student is placed normally.
      final linked = LinkedState.recompute(
        wisa: wapi.WisaSnapshot(
          fetchedAt: _d,
          students: [_wStudent(schoolId: 1)],
          staff: const [],
          classGroups: const [],
          schools: const [
            wapi.WisaSchool(id: 1, name: 'One', code: ''),
          ],
        ),
        smartschool: ss.SmartschoolSnapshot(
          fetchedAt: _d,
          groups: const [],
          accounts: [_ssAccount()],
          memberships: const [],
        ),
        azure: az.AzureSnapshot(
            fetchedAt: _d, users: [_azUser()], groups: const []),
        resolver: _SeqResolver(),
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
      );

      final view = materialize(linked, generation: 1);
      expect(view.accounts.single.school, '1');
    });
  });

  group('pending counts are decisions, not actions (#251)', () {
    /// A WISA-departed, Smartschool-only student: the dispatch raises the
    /// mutually-exclusive unregister/delete pair (#110) on one account.
    LinkedState departedLinked() => LinkedState.recompute(
          wisa: wapi.WisaSnapshot(
            fetchedAt: _d,
            students: const [],
            staff: const [],
            classGroups: const [],
            schools: const [],
          ),
          smartschool: ss.SmartschoolSnapshot(
            fetchedAt: _d,
            groups: const [],
            accounts: [_ssAccount()],
            memberships: const [],
          ),
          azure: az.AzureSnapshot(
              fetchedAt: _d, users: const [], groups: const []),
          resolver: _SeqResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
        );

    CandidateAction candidate(
      String kind, {
      String? group,
      bool isDefault = false,
      bool canApply = true,
    }) =>
        CandidateAction(
          family: 'group',
          kind: kind,
          system: core.Origin.smartschool,
          summary: kind,
          canApply: canApply,
          alternativeGroup: group,
          isDefaultAlternative: isDefault,
        );

    test('two alternatives of one choice count once', () {
      // The heart of the bug: an operator resolves this situation once and
      // exactly one of the two ever runs, so it is one pending item.
      final candidates = [
        candidate('UnregisterStudentFromSmartschool',
            group: 'smartschool-departure', isDefault: true),
        candidate('DeleteStudentFromSmartschool',
            group: 'smartschool-departure'),
      ];
      expect(candidateChoices(candidates), hasLength(1));
      expect(candidateChoices(candidates).single.isChoice, isTrue);
      expect(pendingDecisionCount(candidates), 1);
    });

    test('a choice whose default is informational counts nothing', () {
      // The empty-class reading of #244: the pre-selected half has no write, so
      // a bulk apply writes nothing here — blacklisting stays a deliberate pick.
      final candidates = [
        candidate('CreateInSmartschool',
            group: 'class-import', isDefault: true, canApply: false),
        candidate('DoNotImportFromWisa', group: 'class-import'),
      ];
      expect(pendingDecisionCount(candidates), 0);
    });

    test('independent actions still count one each, informational ones zero',
        () {
      expect(
        pendingDecisionCount([
          candidate('ModifySmartschoolData'),
          candidate('CreateAzureClassGroup'),
          candidate('AzureClassGroupMembership', canApply: false),
        ]),
        2,
        reason: 'no alternative keys ⇒ nothing collapses; #245 never counts',
      );
    });

    test('a candidate written before #251 reads back as a lone action', () {
      // Older documents carry no alternative keys at all, which is the pre-#110
      // shape and correct for every candidate that has no alternative.
      final restored = CandidateAction.fromJson(<String, dynamic>{
        'family': 'student',
        'kind': 'MoveToSmartschoolClassGroup',
        'system': core.Origin.smartschool.toJson(),
        'summary': 'Move to class',
      });
      expect(restored.alternativeGroup, isNull);
      expect(restored.isDefaultAlternative, isFalse);
      expect(pendingDecisionCount([restored]), 1);
    });

    test('the alternative keys survive a candidate JSON round-trip', () {
      final original = candidate('UnregisterStudentFromSmartschool',
          group: 'smartschool-departure', isDefault: true);
      final restored = CandidateAction.fromJson(original.toJson());
      expect(restored.alternativeGroup, 'smartschool-departure');
      expect(restored.isDefaultAlternative, isTrue);
    });

    test('a count field survives a candidate JSON round-trip (#300)', () {
      // A stored candidate is what a passive session renders. If the count
      // shape is dropped on the way through Cosmos, that session shows
      // "leden toevoegen: ∅ → 21" again while the live one no longer does.
      final original = CandidateAction(
        family: 'group',
        kind: 'SyncAzureClassGroupMembers',
        system: core.Origin.azure,
        summary: 'Werk het ledenbestand van GBS-1A bij',
        fields: [
          FieldChange.count('leden toevoegen', 21),
          const FieldChange('mail', after: 'GBS-1A@student.school.example'),
        ],
      );
      final restored = CandidateAction.fromJson(original.toJson());
      expect(restored.fields.first.isCount, isTrue);
      expect(restored.fields.first.after, '21');
      expect(restored.fields.first.before, isNull);
      expect(restored.fields.last.isCount, isFalse,
          reason: 'an ordinary transition is unaffected');
    });

    test('a field written before #300 reads back as a transition', () {
      final restored = CandidateAction.fromJson(<String, dynamic>{
        'family': 'group',
        'kind': 'SyncAzureClassGroupMembers',
        'system': core.Origin.azure.toJson(),
        'summary': 'Werk het ledenbestand bij',
        'fields': [
          {'field': 'leden toevoegen', 'after': '21'},
        ],
      });
      expect(restored.fields.single.isCount, isFalse);
    });

    test('buildRollups counts the choice once at every level', () {
      final account = _account(candidates: [
        candidate('UnregisterStudentFromSmartschool',
            group: 'smartschool-departure', isDefault: true),
        candidate('DeleteStudentFromSmartschool',
            group: 'smartschool-departure'),
      ]);
      for (final r in buildRollups([account])) {
        expect(r.pendingCount, 1, reason: '${r.level} badge');
      }
    });

    test(
        'a departed student materializes as one pending item on every badge, '
        'carrying both alternatives', () {
      final view = materialize(departedLinked(), generation: 1);

      final account = view.accounts.single;
      expect(
        account.candidates.map((c) => c.kind),
        containsAll(<String>[
          'UnregisterStudentFromSmartschool',
          'DeleteStudentFromSmartschool',
        ]),
        reason: 'both readings are still offered — only the count collapses',
      );
      expect(
        account.candidates.map((c) => c.alternativeGroup).toSet(),
        <String>{smartschoolDepartureAlternative},
        reason: 'the key the dispatch declares is persisted (#251)',
      );
      expect(
        account.candidates.where((c) => c.isDefaultAlternative),
        hasLength(1),
      );
      expect(account.hasPending, isTrue);

      for (final r in view.rollups) {
        expect(r.pendingCount, 1, reason: '${r.level} badge counted twice');
      }
    });
  });

  group('gradeYearOf', () {
    test('takes the leading digits of the class group', () {
      expect(gradeYearOf('3C'), '3');
      expect(gradeYearOf('1A'), '1');
      expect(gradeYearOf('12'), '12');
    });

    test('falls back for a non-numeric class group', () {
      expect(gradeYearOf('OKAN'), 'Overig');
      expect(gradeYearOf(''), 'Overig');
    });
  });

  group('mergeDecisions', () {
    core.LinkedAccountId id(String v) => core.LinkedAccountId(v);
    AccountDecision decision(String account, String targetKind,
            {DecisionKind kind = DecisionKind.chosenAlternative}) =>
        AccountDecision(
          accountId: id(account),
          kind: kind,
          targetKind: targetKind,
          decidedBy: 'op@school.example',
          decidedAt: _d,
        );

    test('re-attaches a decision whose situation still exists', () {
      final accounts = [
        _account(id: 'p0', candidates: const [_moveCandidate]),
      ];
      final merge = mergeDecisions(
        accounts: accounts,
        existing: [decision('p0', 'MoveToSmartschoolClassGroup')],
      );

      expect(merge.surviving, hasLength(1));
      expect(merge.dropped, isEmpty);
      expect(merge.accounts.single.decisions, hasLength(1));
    });

    test('drops a decision whose candidate is gone', () {
      final accounts = [
        _account(id: 'p0', candidates: const [_moveCandidate]),
      ];
      final merge = mergeDecisions(
        accounts: accounts,
        existing: [decision('p0', 'DeleteStudentFromSmartschool')],
      );

      expect(merge.surviving, isEmpty);
      expect(merge.dropped, hasLength(1));
      expect(merge.accounts.single.decisions, isEmpty);
    });

    test('drops a decision whose account vanished entirely', () {
      final merge = mergeDecisions(
        accounts: [
          _account(id: 'p0', candidates: const [_moveCandidate])
        ],
        existing: [decision('gone', 'MoveToSmartschoolClassGroup')],
      );
      expect(merge.dropped, hasLength(1));
      expect(merge.surviving, isEmpty);
    });

    MaterializedGroup group(String key,
            {List<CandidateAction> candidates = const []}) =>
        MaterializedGroup(
          id: id(key),
          label: key,
          confidence: core.LinkConfidence.high,
          inWisa: true,
          inSmartschool: true,
          inAzure: false,
          candidates: candidates,
        );

    const modifyGroupCandidate = CandidateAction(
      family: 'group',
      kind: 'ModifySmartschoolData',
      system: core.Origin.smartschool,
      summary: 'Werk de klasgegevens bij in Smartschool',
    );

    test('re-attaches a group decision whose situation still exists (#119)',
        () {
      final merge = mergeDecisions(
        accounts: const [],
        groups: [
          group('group|3C', candidates: const [modifyGroupCandidate]),
        ],
        existing: [
          decision('group|3C', 'ModifySmartschoolData',
              kind: DecisionKind.appliedStatus),
        ],
      );

      expect(merge.surviving, hasLength(1));
      expect(merge.dropped, isEmpty);
      expect(merge.groups.single.decisions, hasLength(1));
    });

    test('drops a group decision whose candidate is gone (#119)', () {
      final merge = mergeDecisions(
        accounts: const [],
        groups: [
          group('group|3C', candidates: const [modifyGroupCandidate]),
        ],
        existing: [
          decision('group|3C', 'AddToSmartschool',
              kind: DecisionKind.appliedStatus),
        ],
      );

      expect(merge.surviving, isEmpty);
      expect(merge.dropped, hasLength(1));
      expect(merge.groups.single.decisions, isEmpty);
    });

    test('a group decision is not dropped by the account pass (#119)', () {
      // Accounts and groups share one decisions container; the merge must
      // consider groups so a group decision is not wrongly dropped for lacking
      // a matching account.
      final merge = mergeDecisions(
        accounts: [
          _account(id: 'p0', candidates: const [_moveCandidate])
        ],
        groups: [
          group('group|3C', candidates: const [modifyGroupCandidate]),
        ],
        existing: [
          decision('group|3C', 'ModifySmartschoolData',
              kind: DecisionKind.appliedStatus),
        ],
      );

      expect(merge.dropped, isEmpty);
      expect(merge.surviving, hasLength(1));
    });

    test('an accepted-duplicate survives while the warning is present', () {
      final withWarning = [
        _account(id: 'p0', warnings: const ['Dubbele mail']),
      ];
      final kept = mergeDecisions(
        accounts: withWarning,
        existing: [
          decision('p0', 'x', kind: DecisionKind.acceptedDuplicate),
        ],
      );
      expect(kept.surviving, hasLength(1));

      final noWarning = [_account(id: 'p0')];
      final dropped = mergeDecisions(
        accounts: noWarning,
        existing: [
          decision('p0', 'x', kind: DecisionKind.acceptedDuplicate),
        ],
      );
      expect(dropped.dropped, hasLength(1));
    });
  });

  group('rollupChangesFor — the post-apply deltas (#254)', () {
    MaterializedGroup mGroup(
      String name, {
      List<CandidateAction> candidates = const [],
    }) =>
        MaterializedGroup(
          id: core.LinkedAccountId(materializedGroupId(name)),
          label: name,
          confidence: core.LinkConfidence.high,
          inWisa: true,
          inSmartschool: true,
          inAzure: true,
          candidates: candidates,
        );

    RollupChange changeAt(List<RollupChange> changes, String key) =>
        changes.singleWhere((c) => c.key == key);

    test('a cleared candidate subtracts one from the class, grade and school',
        () {
      // The whole point of a delta: it says "one fewer pending here", not "here
      // is my session's picture of this class".
      final changes = rollupChangesFor(
        storedAccounts: [
          _account(candidates: const [_moveCandidate])
        ],
        freshAccounts: [_account()],
      );

      expect(changes.map((c) => c.key), <String>{
        'school|1',
        'grade|1|3',
        'class|1|3|3C',
      });
      for (final change in changes) {
        expect(change.pendingDelta, -1);
        expect(change.accountDelta, 0,
            reason: 'the account is still there — only its work is gone');
      }
    });

    test('an account that stayed exactly as it was moves nothing', () {
      // A refused write leaves the document identical, and a node nothing
      // changed at must not be written at all.
      final changes = rollupChangesFor(
        storedAccounts: [
          _account(candidates: const [_moveCandidate])
        ],
        freshAccounts: [
          _account(candidates: const [_moveCandidate])
        ],
      );
      expect(changes, isEmpty);
    });

    test('a document that vanished takes its account count with it', () {
      final changes = rollupChangesFor(
        storedAccounts: [
          _account(candidates: const [_moveCandidate])
        ],
      );

      final klas = changeAt(changes, 'class|1|3|3C');
      expect(klas.accountDelta, -1);
      expect(klas.pendingDelta, -1);
    });

    test('applyTo folds the delta into whatever the store currently holds', () {
      // Two operators clearing different work in the same class: each subtracts
      // only its own, and the second folds onto the first's result rather than
      // replacing it.
      final change = changeAt(
        rollupChangesFor(
          storedAccounts: [
            _account(candidates: const [_moveCandidate])
          ],
          freshAccounts: [_account()],
        ),
        'class|1|3|3C',
      );
      const stored = Rollup(
        level: RollupLevel.classroom,
        key: 'class|1|3|3C',
        parentKey: 'grade|1|3',
        school: '1',
        label: '3C',
        gradeYear: '3',
        classroom: '3C',
        accountCount: 20,
        pendingCount: 5,
      );

      final next = change.applyTo(stored)!;
      expect(next.pendingCount, 4);
      expect(next.accountCount, 20);
      expect(next.label, '3C');
    });

    test('applyTo deletes a node its last document just left', () {
      final change = changeAt(
        rollupChangesFor(storedAccounts: [_account()]),
        'class|1|3|3C',
      );
      const stored = Rollup(
        level: RollupLevel.classroom,
        key: 'class|1|3|3C',
        parentKey: 'grade|1|3',
        school: '1',
        label: '3C',
        gradeYear: '3',
        classroom: '3C',
        accountCount: 1,
        pendingCount: 0,
      );

      expect(change.applyTo(stored), isNull,
          reason: 'an empty node is one the sync path would not emit either');
    });

    test('applyTo never advertises a negative badge', () {
      // The one way the arithmetic can drift: another operator already cleared
      // this work and wrote it, so our subtraction lands on a count that no
      // longer carries it. Under-counting is survivable; a negative badge is not.
      final change = changeAt(
        rollupChangesFor(
          storedAccounts: [
            _account(candidates: const [_moveCandidate])
          ],
          freshAccounts: [_account()],
        ),
        'class|1|3|3C',
      );
      const alreadyCleared = Rollup(
        level: RollupLevel.classroom,
        key: 'class|1|3|3C',
        parentKey: 'grade|1|3',
        school: '1',
        label: '3C',
        gradeYear: '3',
        classroom: '3C',
        accountCount: 3,
        pendingCount: 0,
      );

      expect(change.applyTo(alreadyCleared)!.pendingCount, 0);
    });

    test('a node the store has never seen is created from the fresh document',
        () {
      final change = changeAt(
        rollupChangesFor(
          freshAccounts: [
            _account(candidates: const [_moveCandidate])
          ],
        ),
        'class|1|3|3C',
      );

      final created = change.applyTo(null)!;
      expect(created.level, RollupLevel.classroom);
      expect(created.parentKey, 'grade|1|3');
      expect(created.school, '1');
      expect(created.label, '3C');
      expect(created.accountCount, 1);
      expect(created.pendingCount, 1);
    });

    test("a class group's cleared work moves only the Klasgroepen node", () {
      // Since #227 the group half of the view is one document per *class*, not
      // per class with work — so applying a class's work leaves the inventory
      // size alone and only the pending total moves.
      const modify = CandidateAction(
        family: 'group',
        kind: 'ModifySmartschoolData',
        system: core.Origin.smartschool,
        summary: 'Fix the class data',
      );
      final changes = rollupChangesFor(
        storedGroups: [
          mGroup('3C', candidates: const [modify])
        ],
        freshGroups: [mGroup('3C')],
      );

      final node = changes.single;
      expect(node.key, groupsPartition);
      expect(node.level, RollupLevel.groups);
      expect(node.pendingDelta, -1);
      expect(node.accountDelta, 0,
          reason: 'the class is still on the inventory (#227)');
    });
  });

  group('InMemoryLinkedStore', () {
    test('write then read: sync state, rollups, and a classroom drill-down',
        () async {
      final store = InMemoryLinkedStore();
      final view = materialize(_movePendingLinked(), generation: 1);

      await store.writeMaterialized(view,
          syncedBy: 'op@school.example', at: _d);

      final state = await store.readSyncState();
      expect(state.generation, 1);
      expect(state.updatedBy, 'op@school.example');

      // Three account rollups (school / grade / classroom) plus the single
      // group rollup (#119).
      final rollups = await store.readRollups();
      expect(rollups.where((r) => r.level != RollupLevel.groups), hasLength(3));
      expect(rollups.where((r) => r.level == RollupLevel.groups), hasLength(1));

      final classroom = await store.readClassroom(school: '1', classroom: '3C');
      expect(classroom, hasLength(1));
      expect(
        classroom.single.candidates.map((c) => c.kind),
        contains('MoveToSmartschoolClassGroup'),
      );

      final empty = await store.readClassroom(school: '1', classroom: '9Z');
      expect(empty, isEmpty);
    });

    test('a re-sync replaces the previous accounts', () async {
      final store = InMemoryLinkedStore();
      await store.writeMaterialized(
        materialize(_movePendingLinked(), generation: 1),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(store.accountCount, 1);

      // A view with no accounts (everyone left) must clear the store.
      await store.writeMaterialized(
        const MaterializedView(generation: 2, accounts: [], rollups: []),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(store.accountCount, 0);
      expect((await store.readSyncState()).generation, 2);
    });

    test('write then read: group docs, cleared on a groupless re-sync (#119)',
        () async {
      final store = InMemoryLinkedStore();
      final view = materialize(_movePendingLinked(), generation: 1);
      expect(view.groups, isNotEmpty);

      await store.writeMaterialized(view,
          syncedBy: 'op@school.example', at: _d);

      final groups = await store.readGroups();
      expect(groups.map((g) => g.label), contains('2B'));
      expect(store.groupCount, view.groups.length);

      // A re-sync whose view has no groups clears the stored group docs.
      await store.writeMaterialized(
        const MaterializedView(
            generation: 2, accounts: [], rollups: [], groups: []),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(store.groupCount, 0);
      expect(await store.readGroups(), isEmpty);
    });

    test('putDecision persists; writeMaterialized drops the ones passed',
        () async {
      final store = InMemoryLinkedStore();
      final d = AccountDecision(
        accountId: const core.LinkedAccountId('p0'),
        kind: DecisionKind.chosenAlternative,
        targetKind: 'MoveToSmartschoolClassGroup',
        decidedBy: 'op@school.example',
        decidedAt: _d,
      );
      await store.putDecision(d);
      expect(await store.readDecisions(), hasLength(1));

      await store.writeMaterialized(
        const MaterializedView(generation: 1, accounts: [], rollups: []),
        syncedBy: 'op@school.example',
        at: _d,
        droppedDecisions: [d],
      );
      expect(await store.readDecisions(), isEmpty);
    });
  });
}
