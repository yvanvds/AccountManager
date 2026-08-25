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

/// A WISA staff member, found in [schoolIds] (#340). `code` bridges to
/// Smartschool's `accountId`, `wisaId` to Azure's `employeeId`.
wapi.WisaStaff _wStaff({Set<int> schoolIds = const {1}}) => wapi.WisaStaff(
      code: const core.WisaStaffCode('SMITA'),
      wisaId: const core.WisaId('42'),
      firstName: 'Anna',
      lastName: 'Smit',
      schoolIds: schoolIds,
    );

/// The Smartschool staff account matching [_wStaff] — teacher role, so the
/// linker routes it to the staff population, with `fax` already holding the
/// zero-padded copy code so no modify action fires.
ss.SmartschoolAccount _ssStaffAccount() => const ss.SmartschoolAccount(
      uid: 'anna.smit',
      accountId: 'SMITA',
      mail: 'anna.smit@school.example',
      registerId: '',
      stemId: 0,
      role: core.PersonRole.teacher,
      givenName: 'Anna',
      surname: 'Smit',
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
      fax: '0042',
      untisId: '',
      status: 'actief',
    );

/// The Azure account matching [_wStaff]. Staff carry no `companyName`; their
/// school lives in [department], the comma list other software maintains (#237).
az.AzureUser _azStaffUser({String department = 'GBS'}) => az.AzureUser(
      id: 'az-staff',
      upn: 'anna.smit@school.example',
      employeeId: '42',
      displayName: 'Smit Anna',
      givenName: 'Anna',
      surname: 'Smit',
      department: department,
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

/// Hands every natural key one id, to construct the INV-24 collision (#319).
class _CollidingResolver implements core.PersonIdResolver {
  @override
  core.PersonId resolve(String naturalKey) => const core.PersonId('p-shared');
}

/// Two unrelated students on **one** `LinkedAccountId` — the id collision
/// INV-24 reports (#319). Constructed through the resolver rather than through
/// the data: #318 removed the one known way a snapshot produced this.
LinkedState _idCollisionLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: [
          _wStudent(wisaId: '1', classGroup: '3C'),
          _wStudent(wisaId: '2', classGroup: '3C'),
        ],
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
      azure: az.AzureSnapshot(fetchedAt: _d, users: const [], groups: const []),
      resolver: _CollidingResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
    );

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

/// A student the aggregated pull returned **twice** (#334): one `wisaId`, a row
/// in school 1 — ours, `3MWW1` — and one in the sibling group school 2, `3HWa`.
///
/// The sibling row arrives *first*, as it does when that school is configured
/// first: which row the pull reads first must decide nothing (INV-21/INV-25).
/// [ourSchoolIds] moves the ownership line, so the same person can be read as
/// ours-plus-elsewhere or as departed-but-still-in-the-group.
LinkedState _dualEnrolledLinked({Set<int>? ourSchoolIds = const {1}}) =>
    LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: [
          _wStudent(classGroup: '3HWa', schoolId: 2),
          _wStudent(classGroup: '3MWW1'),
        ],
        staff: const [],
        classGroups: const [],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: [_ssGroup('3MWW1', code: '3MWW1_ss')],
        accounts: [_ssAccount()],
        memberships: const [
          ss.SmartschoolMembership(
              uid: 'jane', groupId: core.GroupId('3MWW1_ss')),
        ],
      ),
      azure:
          az.AzureSnapshot(fetchedAt: _d, users: [_azUser()], groups: const []),
      resolver: _SeqResolver(),
      studentConfig: _studentConfig,
      staffConfig: _staffConfig,
      ourSchoolIds: ourSchoolIds,
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

/// A Smartschool-only class the app **cannot** delete: the group carries no
/// class code, so there is nothing to address a `delClass` to and the dispatch
/// falls back to the lone informational `DoNotImportFromSmartschool` (#328).
///
/// The one shape a class group still has manual-only work in, which is what the
/// "attention, not pending" claim of #225/#250 is about. It used to be every
/// Smartschool leftover, back when the notice was the pre-selected half of a
/// radio pair.
LinkedState _leftoverNoticeLinked() => LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: const [],
        staff: const [],
        classGroups: const [],
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: [_ssGroup('2B', code: ' ')],
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

    group('a LinkedAccountId claimed twice (INV-24, #319)', () {
      test('the linker reports it rather than the materializer swallowing it',
          () {
        final linked = _idCollisionLinked();
        final warning =
            linked.snapshot.warnings.whereType<core.DuplicateLinkedId>().single;
        expect(warning.id.value, 'p-shared');
        expect(warning.holdings.map((h) => h.wisa), ['1', '2']);
      });

      test('the collision does not become an account warning string', () {
        // Deliberate. `decisions_merge._situationExists` reads
        // `MaterializedAccount.warnings` type-blind: for an
        // `acceptedDuplicate` decision, *any* warning string there is taken as
        // proof the duplicate-mail collision still exists. Hanging an
        // unrelated warning on an account would quietly keep a stale
        // acceptance alive, so this one is reported snapshot-wide instead.
        final view = materialize(_idCollisionLinked(), generation: 1);
        expect(view.accounts.every((a) => a.warnings.isEmpty), isTrue);
      });

      test('both records still materialize, onto the one document id', () {
        // Documents the damage the warning exists to make visible: the store
        // keeps one document per id, so one of these two is what every other
        // operator inherits.
        final view = materialize(_idCollisionLinked(), generation: 1);
        expect(view.accounts, hasLength(2));
        expect(view.accounts.map((a) => a.id.value).toSet(), {'p-shared'});
      });
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

    group('the other group schools a person is enrolled in (#334)', () {
      // The persisted school profiles the operator curates — the same pair the
      // Settings grid shows, and the only place a school *name* may come from
      // (#204/#208). School 1 is ours; school 2 is a sibling of the group.
      final labels = wisaSchoolLabels(profiles: const [
        WisaSchoolProfile(
          schoolId: 1,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
        ),
        WisaSchoolProfile(
          schoolId: 2,
          code: 'ISMAB',
          name: 'Instituut Sancta Maria-B',
        ),
      ]);

      test('the card names the other school and the class it holds', () {
        final view = materialize(
          _dualEnrolledLinked(),
          generation: 1,
          schoolLabels: labels,
        );
        final account = view.accounts.single;
        expect(
          account.otherEnrolments,
          [
            const OtherEnrolment(
              schoolLabel: 'Instituut Sancta Maria-B (ISMAB)',
              classroom: '3HWa',
            ),
          ],
        );
        // …while every fact the card leads with is still our school's row: the
        // partition, the label, the grade-year and the class (INV-25).
        expect(account.school, '1');
        expect(account.schoolLabel, 'Instituut Sancta Maria-A (ISMAA)');
        expect(account.gradeYear, '3');
        expect(account.classroom, '3MWW1');
      });

      test('a single-school account carries none, and stores none', () {
        final view = materialize(
          _movePendingLinked(),
          generation: 1,
          schoolLabels: labels,
        );
        expect(view.accounts.single.otherEnrolments, isEmpty);
        // The ordinary document — every document but a handful — keeps exactly
        // the shape it had before this existed.
        expect(view.accounts.single.toJson().containsKey('otherEnrolments'),
            isFalse);
      });

      test('an unknown school degrades to the documented last resort', () {
        // `School <id>` is the fallback for an id no list knows, never a name
        // invented from an id (#204/#208).
        final view = materialize(
          _dualEnrolledLinked(),
          generation: 1,
          schoolLabels: const {1: 'Instituut Sancta Maria-A (ISMAA)'},
        );
        expect(view.accounts.single.otherEnrolments.single.schoolLabel,
            'School 2');
      });

      test('a departed dual-enrolled student is told where she went', () {
        // Neither school is ours any more, so the card has no class of ours to
        // qualify — it reads "Niet toegewezen". Where she is instead is the
        // whole of what it can still say, and it gates keeping Azure (#134).
        final view = materialize(
          _dualEnrolledLinked(ourSchoolIds: const {9}),
          generation: 1,
          schoolLabels: labels,
        );
        final account = view.accounts.single;
        expect(account.school, unassignedPartition);
        expect(
          account.otherEnrolments.map((e) => e.classroom),
          ['3MWW1', '3HWa'],
          reason: 'ordered by school id, so one enrolment reads the same twice',
        );
      });

      test('it survives the round-trip through a stored document', () {
        // A passive session reads the store and never links, so the line has to
        // come back out of the document exactly as it went in.
        final account = materialize(
          _dualEnrolledLinked(),
          generation: 1,
          schoolLabels: labels,
        ).accounts.single;
        final back = MaterializedAccount.fromJson(account.toJson());
        expect(back.otherEnrolments, account.otherEnrolments);
      });
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
      // The Smartschool-only 2B class names a code, so since #328 its one
      // reading is the applyable `DeleteSmartschoolClass` — the informational
      // notice it used to be pre-selected beside is gone. See
      // `_leftoverNoticeLinked` for the leftover that still has no write.
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
      expect(group.hasPending, isTrue);

      final rollup =
          view.rollups.firstWhere((r) => r.level == RollupLevel.groups);
      expect(rollup.key, groupsPartition);
      expect(rollup.school, groupsPartition);
      expect(rollup.label, 'Klasgroepen');
      expect(rollup.accountCount, 1);
      expect(rollup.pendingCount, 1,
          reason: 'the leftover proposes a delete the operator may apply');
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
      // #225/#250: a class carrying manual work with no automated write must
      // not be filtered away with the pending count. Since #328 the shape that
      // still does is the Smartschool leftover naming no class code — the one
      // the delete cannot address.
      final group =
          materialize(_leftoverNoticeLinked(), generation: 1).groups.single;
      expect(
        group.candidates.map((c) => c.kind),
        ['DoNotImportFromSmartschool'],
      );
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

  group('the Personeel list is our own school only (#340)', () {
    // One WISA staff member found in [schoolIds], linked against [ourSchoolIds]
    // with whichever of our own systems [smartschool] / [azureDepartment] give
    // them. `department` is what other software maintains as the comma list of
    // schools a teacher is active at (#237), so `null` is "Azure says nothing".
    LinkedState staffLinked({
      Set<int> schoolIds = const {1},
      Set<int>? ourSchoolIds = const {1},
      bool smartschool = false,
      String? azureDepartment,
      bool wisa = true,
    }) =>
        LinkedState.recompute(
          wisa: wapi.WisaSnapshot(
            fetchedAt: _d,
            students: const [],
            staff: [if (wisa) _wStaff(schoolIds: schoolIds)],
            classGroups: const [],
            schools: const [],
          ),
          smartschool: ss.SmartschoolSnapshot(
            fetchedAt: _d,
            groups: const [],
            accounts: smartschool ? [_ssStaffAccount()] : const [],
            memberships: const [],
          ),
          azure: az.AzureSnapshot(
            fetchedAt: _d,
            users: azureDepartment == null
                ? const []
                : [_azStaffUser(department: azureDepartment)],
            groups: const [],
          ),
          resolver: _SeqResolver(),
          studentConfig: _studentConfig,
          staffConfig: _staffConfig,
          ourSchoolIds: ourSchoolIds,
        );

    test('a staff member of a school we manage is listed', () {
      final view = materialize(staffLinked(), generation: 1);

      expect(view.accounts, hasLength(1));
      expect(view.accounts.single.isStaff, isTrue);
      expect(view.skippedUnmanagedStaff, 0);
    });

    test('a sibling group school\'s teacher is left out of the list', () {
      // The bug as reported: the shared WISA credentials pull the group's whole
      // personeel — 2574 rows — and every one of them used to become a row here.
      final view = materialize(
        staffLinked(schoolIds: const {7}),
        generation: 1,
      );

      expect(view.accounts, isEmpty);
      expect(view.rollups.where((r) => r.school == staffPartition), isEmpty,
          reason:
              'no Personeel rollup, so the Synchronisatie tile is empty too');
    });

    test('the left-out staff are counted, not silently dropped', () {
      final view = materialize(
        staffLinked(schoolIds: const {7}),
        generation: 1,
      );

      expect(view.skippedUnmanagedStaff, 1);
    });

    test(
        'a sibling-school teacher who kept an account of ours is still listed, '
        'and her departure is proposed (#349)', () {
      // The load-bearing case. She left us for a group school that still employs
      // her; our Smartschool account is the tie that keeps her visible in the
      // Personeel list, which is what #340 secured and is unchanged.
      //
      // What she is *offered* changed in #349. The removals used to stand down
      // purely because `wisa != null`, so an account on our platform belonging
      // to somebody who no longer works here could never be cleaned up. They now
      // key on `hasLeftOurSchool`, exactly as the student departure has since
      // #134 — and she is precisely that: WISA places her in school 7 alone.
      final linked = staffLinked(schoolIds: const {7}, smartschool: true);
      final view = materialize(linked, generation: 1);

      expect(view.accounts, hasLength(1), reason: 'still listed (#340)');
      expect(view.skippedUnmanagedStaff, 0);
      expect(linked.staffActions.whereType<DeactivateStaffInSmartschool>(),
          hasLength(1));
      expect(linked.staffActions.whereType<RemoveStaffFromSmartschool>(),
          hasLength(1));
      // Nothing to do in Office 365: she has no account there in this fixture.
      expect(linked.staffActions.whereType<RemoveStaffFromAzure>(), isEmpty);
      expect(linked.staffActions.whereType<ReleaseStaffFromAzureSchool>(),
          isEmpty);
    });

    test(
        "a sibling school's claim on her Office 365 account is released, never "
        'deleted (#349)', () {
      // The guard the whole Azure split exists for. She is departed as far as we
      // are concerned, but `department` still names the school that employs her,
      // so deleting the account would destroy a sibling school's.
      final linked = staffLinked(
        schoolIds: const {7},
        smartschool: true,
        azureDepartment: 'OTHER,GBS',
      );
      final view = materialize(linked, generation: 1);

      expect(view.accounts, hasLength(1));
      final release =
          linked.staffActions.whereType<ReleaseStaffFromAzureSchool>().single;
      expect(release.describeChanges().fields.single.after, 'OTHER');
      expect(linked.staffActions.whereType<RemoveStaffFromAzure>(), isEmpty);
    });

    test('Azure\'s department is consulted, and only ever to keep a record',
        () {
      // Azure's `employeeId` back-fill (#231) asks about every staff member the
      // *group-wide* WISA pull returned, so a sibling school's teacher very often
      // does have an Azure row here. Whose it is comes off `department`.
      final theirs = materialize(
        staffLinked(schoolIds: const {7}, azureDepartment: 'OTHER'),
        generation: 1,
      );
      expect(theirs.accounts, isEmpty);
      expect(theirs.skippedUnmanagedStaff, 1);

      final ours = materialize(
        staffLinked(schoolIds: const {7}, azureDepartment: 'OTHER,GBS'),
        generation: 1,
      );
      expect(ours.accounts, hasLength(1));
      expect(ours.skippedUnmanagedStaff, 0);
    });

    test('a former staff member WISA no longer lists at all is kept', () {
      // Nothing but Azure left, which is precisely what RemoveStaffFromAzure
      // exists to clean up — the filter must not swallow it.
      final linked = staffLinked(wisa: false, azureDepartment: 'GBS');
      final view = materialize(linked, generation: 1);

      expect(view.accounts, hasLength(1));
      expect(view.skippedUnmanagedStaff, 0);
      expect(
          linked.staffActions.whereType<RemoveStaffFromAzure>(), hasLength(1));
    });

    test('ownership unconfigured lists every staff member, as before', () {
      final view = materialize(
        staffLinked(schoolIds: const {7}, ourSchoolIds: null),
        generation: 1,
      );

      expect(view.accounts, hasLength(1));
      expect(view.skippedUnmanagedStaff, 0);
    });

    test('a WISA row with no school at all is listed, not filtered away', () {
      // What a cold snapshot written before #340 restores to. Reading "school
      // unknown" as "not ours" would empty the Personeel tab on the first launch
      // after the upgrade.
      final view = materialize(
        staffLinked(schoolIds: const {}),
        generation: 1,
      );

      expect(view.accounts, hasLength(1));
      expect(view.skippedUnmanagedStaff, 0);
    });

    group('the Azure department schools ride on the document (#352)', () {
      test('every school the list names, in its order and its casing', () {
        // A quotation of the field, not a reading of it: no re-sorting, no
        // case-folding, no label invented for a prefix nothing here knows.
        final view = materialize(
          staffLinked(azureDepartment: ' ismab , GBS ,, sbe '),
          generation: 1,
        );

        expect(
          view.accounts.single.departmentSchools,
          ['ismab', 'GBS', 'sbe'],
          reason: 'departmentSchools trims and drops blanks, nothing else',
        );
      });

      test('our own school alone is still listed', () {
        // The case that decides a deletion: `departmentSchoolsExcept` comes back
        // empty here, so `RemoveStaffFromAzure` is what a departure would raise.
        // That is precisely what the operator needs confirmed, so the reading
        // must not filter our prefix out the way the *write* does.
        final view = materialize(
          staffLinked(azureDepartment: 'GBS'),
          generation: 1,
        );

        expect(view.accounts.single.departmentSchools, ['GBS']);
      });

      test(
          'a staff member with no Office 365 account carries none, and stores '
          'none', () {
        final account =
            materialize(staffLinked(), generation: 1).accounts.single;

        expect(account.inAzure, isFalse);
        expect(account.departmentSchools, isEmpty);
        // An absent key reads as "nothing recorded", never as "recorded, and
        // empty" — which is what keeps a document written before #352 from
        // being reported as a blank list.
        expect(account.toJson().containsKey('departmentSchools'), isFalse);
      });

      test('a blank department stores nothing either', () {
        final account = materialize(
          staffLinked(azureDepartment: '  '),
          generation: 1,
        ).accounts.single;

        expect(account.inAzure, isTrue);
        expect(account.departmentSchools, isEmpty);
        expect(account.toJson().containsKey('departmentSchools'), isFalse);
      });

      test('a student is untouched: their school is companyName (INV-22)', () {
        // One exact value, not a list — there is nothing here to print, and the
        // student document keeps exactly the shape it had.
        final account =
            materialize(_movePendingLinked(), generation: 1).accounts.single;

        expect(account.isStaff, isFalse);
        expect(account.departmentSchools, isEmpty);
        expect(account.toJson().containsKey('departmentSchools'), isFalse);
      });

      test('it survives the round-trip through a stored document', () {
        // A passive session reads the store and never links, so the list has to
        // come back out of the document exactly as it went in — and the record
        // it came from does not survive at all: `LinkedStaff.azure` is the
        // narrow interface, which carries no `department`.
        final account = materialize(
          staffLinked(azureDepartment: 'OTHER,GBS'),
          generation: 1,
        ).accounts.single;
        final back = MaterializedAccount.fromJson(account.toJson());

        expect(back.departmentSchools, ['OTHER', 'GBS']);
        expect(back.withDecisions(const []).departmentSchools,
            account.departmentSchools,
            reason: 'the decisions merge rewrites the doc every sync');
      });
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
      String? noticeFor,
    }) =>
        CandidateAction(
          family: 'group',
          kind: kind,
          system: core.Origin.smartschool,
          summary: kind,
          canApply: canApply,
          alternativeGroup: group,
          isDefaultAlternative: isDefault,
          noticeFor: noticeFor,
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

    test('a choice whose selected half is informational counts nothing', () {
      // The generic property, and the only shape that still produces it since
      // #329: a lone informational candidate. (An either/or can no longer be in
      // this state — every alternative writes — and the empty-class reading of
      // #244 that used to be the example is the test below.)
      expect(
        pendingDecisionCount(
            [candidate('DoNotImportFromSmartschool', canApply: false)]),
        0,
      );
    });

    test('a notice is not a decision, and the write beside it is (#329)', () {
      // The empty-class reading of #244, as it stands now. The notice used to
      // be the pre-selected half of this pair, so the badge read zero: nothing
      // would be written unless the operator flipped a radio. It is context on
      // the blacklist now, so the badge counts the blacklist — which genuinely
      // is a write the operator can press. Keeping it off a *bulk* pass is
      // `canApplyToAll`'s job (#293/#326), not the badge's.
      final candidates = [
        candidate('CreateInSmartschool',
            canApply: false, noticeFor: 'class-import'),
        candidate('DoNotImportFromWisa', group: 'class-import'),
      ];

      final choices = candidateChoices(candidates);
      expect(choices, hasLength(1));
      expect(choices.single.isChoice, isFalse,
          reason:
              'a diagnosis and a write are not two answers to one question');
      expect(choices.single.selected.kind, 'DoNotImportFromWisa');
      expect(
        choices.single.notices.map((c) => c.kind),
        <String>['CreateInSmartschool'],
        reason: 'the instruction is still on the card, as context',
      );
      expect(pendingDecisionCount(candidates), 1);
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
      expect(restored.noticeFor, isNull);
    });

    test('the notice key survives a candidate JSON round-trip (#329)', () {
      // Dropped on the way through Cosmos, the namesake instruction reads back
      // as a decision of its own in a passive session — a second bullet the
      // operator is asked to resolve and a badge counting work nobody can do,
      // which is the very #251 split this key exists to close.
      final original = candidate('ClassExistsAsSmartschoolGroup',
          canApply: false, noticeFor: 'class-namesake');
      final restored = CandidateAction.fromJson(original.toJson());

      expect(restored.noticeFor, 'class-namesake');
      expect(restored.alternativeGroup, isNull);
      expect(restored.canApply, isFalse);
    });

    test('a candidate written before #329 carries no notice key', () {
      final restored = CandidateAction.fromJson(<String, dynamic>{
        'family': 'group',
        'kind': 'ClassExistsAsSmartschoolGroup',
        'system': core.Origin.smartschool.toJson(),
        'summary': 'Deze klas bestaat in Smartschool',
        'canApply': false,
        'alternativeGroup': 'class-namesake',
        'isDefaultAlternative': true,
      });
      // It reads back exactly as it was written — the pre-#329 pair, which the
      // next sync replaces wholesale.
      expect(restored.noticeFor, isNull);
      expect(restored.alternativeGroup, 'class-namesake');
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
      expect(restored.fields.first.shape, FieldChangeShape.count);
      expect(restored.fields.first.after, '21');
      expect(restored.fields.first.before, isNull);
      expect(restored.fields.last.shape, FieldChangeShape.transition,
          reason: 'an ordinary transition is unaffected');
    });

    test('a statement field survives a candidate JSON round-trip (#305)', () {
      // Same reasoning as the count above, for the other non-transition shape:
      // dropped on the way through Cosmos, the "laat de groep staan" notice
      // reads "mail: GBS-9Z@… → ∅" in a passive session — an address being
      // cleared by the option that writes nothing.
      const original = CandidateAction(
        family: 'group',
        kind: 'AzureClassGroupWithoutClass',
        system: core.Origin.azure,
        summary: 'Laat de Office 365-groep GBS-9Z staan',
        canApply: false,
        fields: [
          FieldChange.statement('mail', 'GBS-9Z@student.school.example'),
          FieldChange.statement('leden', '21'),
        ],
      );
      final restored = CandidateAction.fromJson(original.toJson());
      expect(
        restored.fields.map((f) => f.shape),
        everyElement(FieldChangeShape.statement),
      );
      expect(restored.fields.map((f) => f.before),
          ['GBS-9Z@student.school.example', '21']);
      expect(restored.fields.every((f) => f.after == null), isTrue);
    });

    test('a field written before #300/#305 reads back as a transition', () {
      final restored = CandidateAction.fromJson(<String, dynamic>{
        'family': 'group',
        'kind': 'SyncAzureClassGroupMembers',
        'system': core.Origin.azure.toJson(),
        'summary': 'Werk het ledenbestand bij',
        'fields': [
          {'field': 'leden toevoegen', 'after': '21'},
        ],
      });
      expect(restored.fields.single.shape, FieldChangeShape.transition);
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
