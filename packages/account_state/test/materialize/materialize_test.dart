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

core.Group _ssGroup(String name, {String? code}) => core.Group(
      id: core.GroupId(code ?? name),
      name: name,
      description: '',
      type: core.GroupType.classGroup,
      official: true,
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

      expect(await store.readRollups(), hasLength(3));

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
