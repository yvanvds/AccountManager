import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

/// The Office 365 class-group slice of the derived view (#228), driven through
/// the real `LinkedState.recompute` so the linker's prefix-aware group match,
/// the [AzureClassGroupResolver], and the group dispatch are exercised the way
/// the app wires them.
const String _prefix = 'GBS';
const String _domain = 'student.school.example';
final DateTime _d = DateTime.utc(2026);

const core.Address _addr = core.Address(
  street: '',
  houseNumber: '',
  postalCode: '',
  city: '',
  country: '',
);

wapi.WisaStudent _student({
  required String wisaId,
  required String classGroup,
  String classSubGroup = '00',
  int schoolId = 1,
}) =>
    wapi.WisaStudent(
      wisaId: core.WisaId(wisaId),
      classGroup: classGroup,
      classSubGroup: classSubGroup,
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

wapi.WisaClassGroup _wClass(
  String name, {
  String groupName = '00',
  String adminCode = '',
  int schoolId = 1,
}) =>
    wapi.WisaClassGroup(
      name: name,
      groupName: groupName,
      description: 'Klas $name',
      adminCode: adminCode,
      schoolCode: '123',
      schoolId: schoolId,
    );

az.AzureUser _azUser(String id, {required String employeeId}) => az.AzureUser(
      id: id,
      upn: '$id@$_domain',
      employeeId: employeeId,
      companyName: _prefix,
    );

az.AzureGroup _classGroup(String className,
        {List<String> memberIds = const []}) =>
    az.AzureGroup(
      id: 'az-$_prefix-$className',
      displayName: '$_prefix-$className',
      mail: '$_prefix-$className@$_domain',
      mailNickname: '$_prefix-$className',
      memberIds: memberIds,
    );

/// A Smartschool account bridged to a WISA student by `accountId ≡ wisaId`, so
/// the linked record is complete and the student dispatch takes its modify
/// branch — where the per-account class-group view lives (#245).
ss.SmartschoolAccount _ssAccount(String uid, {required String accountId}) =>
    ss.SmartschoolAccount(
      uid: uid,
      accountId: accountId,
      mail: '$uid@$_domain',
      registerId: '',
      stemId: 0,
      role: core.PersonRole.student,
      givenName: 'Jane',
      surname: 'Doe',
      extraNames: '',
      initials: '',
      preferredName: '',
      gender: core.Gender.female,
      birthDate: _d,
      birthPlace: '',
      birthCountry: '',
      address: _addr,
      mobilePhone: '',
      homePhone: '',
      fax: '',
      untisId: '',
      status: 'actief',
    );

class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}

LinkedState _recompute({
  List<wapi.WisaStudent> students = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
  List<az.AzureUser> azureUsers = const [],
  List<az.AzureGroup> azureGroups = const [],
  List<core.Group> ssGroups = const [],
  List<ss.SmartschoolAccount> ssAccounts = const [],
}) =>
    LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: students,
        staff: const [],
        classGroups: classGroups,
        schools: const [],
      ),
      smartschool: ss.SmartschoolSnapshot(
        fetchedAt: _d,
        groups: ssGroups,
        accounts: ssAccounts,
        memberships: const [],
      ),
      azure: az.AzureSnapshot(
        fetchedAt: _d,
        users: azureUsers,
        groups: azureGroups,
      ),
      resolver: _SeqResolver(),
      studentConfig: actions.StudentActionConfig(
        schoolPrefix: _prefix,
        azureDomain: 'school.example',
        studentDomain: _domain,
      ),
      staffConfig: actions.StaffActionConfig(
        schoolPrefix: _prefix,
        azureDomain: 'school.example',
      ),
    );

List<T> _actionsOfType<T>(LinkedState linked) =>
    linked.groupActions.whereType<T>().toList();

void main() {
  group('creating the class group (#228)', () {
    test('a populated class with no group raises exactly one create', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
      );

      final creates = _actionsOfType<actions.CreateAzureClassGroup>(linked);
      expect(creates, hasLength(1));
      expect(creates.single.plan.displayName, 'GBS-2A');
      expect(creates.single.plan.mail, 'GBS-2A@$_domain');
      expect(creates.single.plan.className, '2A');
    });

    test(
        'a sub-grouped class raises one create for the parent, not one per '
        'sub-group', () {
      final linked = _recompute(
        classGroups: [
          _wClass('2F', groupName: 'ECO', adminCode: 'a'),
          _wClass('2F', groupName: 'MAW', adminCode: 'b'),
          _wClass('2F', groupName: 'MOW', adminCode: 'c'),
          _wClass('2F', groupName: 'STEMW', adminCode: 'd'),
        ],
        students: [
          _student(wisaId: 'w1', classGroup: '2F', classSubGroup: 'ECO'),
          _student(wisaId: 'w2', classGroup: '2F', classSubGroup: 'MAW'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
      );

      // Four linked groups (one per sub-group) but one Office 365 proposal.
      expect(linked.snapshot.groups, hasLength(4));
      final creates = _actionsOfType<actions.CreateAzureClassGroup>(linked);
      expect(creates, hasLength(1));
      expect(creates.single.plan.displayName, 'GBS-2F');
      expect(creates.single.target.wisa!.name, '2F ECO',
          reason: 'the parent class has no record of its own, so the first '
              'sub-group carries the proposal');
    });

    test("the parent class's own record owns the proposal when it exists", () {
      final linked = _recompute(
        classGroups: [
          _wClass('2F', groupName: 'ECO', adminCode: 'a'),
          _wClass('2F', adminCode: 'b'),
        ],
        students: [_student(wisaId: 'w1', classGroup: '2F')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
      );

      final creates = _actionsOfType<actions.CreateAzureClassGroup>(linked);
      expect(creates, hasLength(1));
      expect(creates.single.target.wisa!.name, '2F');
    });

    test('an empty class gets no group', () {
      final linked = _recompute(classGroups: [_wClass('2A')]);
      expect(_actionsOfType<actions.CreateAzureClassGroup>(linked), isEmpty);
    });

    test('a class whose students have no Office 365 account yet still counts',
        () {
      // `containsStudents` is a WISA fact: the class is real and populated even
      // though nobody has an account to put in the group yet.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
      );
      final creates = _actionsOfType<actions.CreateAzureClassGroup>(linked);
      expect(creates, hasLength(1));
      expect(creates.single.plan.containsStudents, isTrue);
    });

    test('an existing group is adopted, not created again', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1'])
        ],
      );

      expect(_actionsOfType<actions.CreateAzureClassGroup>(linked), isEmpty);
      expect(linked.snapshot.groups.single.azure!.displayName, 'GBS-2A');
    });

    test(
        'a class name that cannot form a mail nickname is never proposed '
        '(#228)', () {
      // Bare class names carry no spaces; if one ever does, Graph would refuse
      // the create — so nothing is offered rather than something that fails.
      final linked = _recompute(
        classGroups: [_wClass('2 F')],
        students: [_student(wisaId: 'w1', classGroup: '2 F')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
      );
      expect(_actionsOfType<actions.CreateAzureClassGroup>(linked), isEmpty);
    });
  });

  group('membership follows the roster (#228)', () {
    test('a student missing from their own class group is added', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [
          _student(wisaId: 'w1', classGroup: '2A'),
          _student(wisaId: 'w2', classGroup: '2A'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1'])
        ],
      );

      final sync =
          _actionsOfType<actions.SyncAzureClassGroupMembers>(linked).single;
      expect(sync.plan.membersToAdd, ['az-2']);
      expect(sync.plan.membersToRemove, isEmpty);
    });

    test('a student who moved to another class is removed from the old group',
        () {
      final linked = _recompute(
        classGroups: [_wClass('2A'), _wClass('2B')],
        students: [
          _student(wisaId: 'w1', classGroup: '2B'),
        ],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
          _classGroup('2B'),
        ],
      );

      final syncs = {
        for (final s
            in _actionsOfType<actions.SyncAzureClassGroupMembers>(linked))
          s.plan.className: s.plan,
      };
      expect(syncs['2A']!.membersToRemove, ['az-1']);
      expect(syncs['2B']!.membersToAdd, ['az-1']);
    });

    test('a member this app cannot account for is never removed', () {
      // The class titular, a shared mailbox, a guest — all out of scope, and
      // all indistinguishable from each other here: not one of our students.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-teacher']),
        ],
      );

      expect(
        _actionsOfType<actions.SyncAzureClassGroupMembers>(linked),
        isEmpty,
        reason: 'membership already matches the roster; the teacher stays',
      );
    });

    test("membership is the union of a sub-grouped class's rosters", () {
      final linked = _recompute(
        classGroups: [
          _wClass('2F', groupName: 'ECO', adminCode: 'a'),
          _wClass('2F', groupName: 'MAW', adminCode: 'b'),
        ],
        students: [
          _student(wisaId: 'w1', classGroup: '2F', classSubGroup: 'ECO'),
          _student(wisaId: 'w2', classGroup: '2F', classSubGroup: 'MAW'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
        azureGroups: [_classGroup('2F')],
      );

      final syncs = _actionsOfType<actions.SyncAzureClassGroupMembers>(linked);
      expect(syncs, hasLength(1), reason: 'one group, one membership action');
      expect(syncs.single.plan.membersToAdd, ['az-1', 'az-2']);
    });

    test('membership already in sync raises nothing', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1'])
        ],
      );
      // The Smartschool side of this fixture still has work to do; the Office
      // 365 side has none.
      expect(
          _actionsOfType<actions.SyncAzureClassGroupMembers>(linked), isEmpty);
      expect(_actionsOfType<actions.CreateAzureClassGroup>(linked), isEmpty);
    });
  });

  group('a vanished class (#228)', () {
    test('its group is offered for deletion, and nothing is deleted for you',
        () {
      // Since #327 the row proposes exactly one thing — the delete — instead of
      // pairing it with a "laat de groep staan" radio that wrote nothing. What
      // keeps it from running on its own is `canApplyToAll` plus the operator's
      // own press, not the polarity of a pair.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
          _classGroup('9Z'),
        ],
      );

      final deletes = _actionsOfType<actions.DeleteAzureClassGroup>(linked);
      expect(deletes, hasLength(1));
      expect(deletes.single.target.className, '9Z');
      expect(deletes.single.canApplyToAll, isFalse,
          reason: 'no bulk affordance may offer it (#293/#326)');
      expect(
        _actionsOfType<actions.AzureClassGroupWithoutClass>(linked),
        isEmpty,
        reason: 'the notice is only for a group the delete cannot address',
      );
    });
  });

  group('the same membership, read per account (#245)', () {
    /// The per-student class-group actions of a linked view, keyed by the
    /// account they target.
    Map<String, actions.AzureClassGroupMembership> memberships(
      LinkedState linked,
    ) =>
        {
          for (final a in linked.studentActions
              .whereType<actions.AzureClassGroupMembership>())
            a.target.id.value: a,
        };

    test('a student missing from their own class group says so on the account',
        () {
      // The very state the class row reports as "1 toevoegen": w2 is on the
      // roster of 2A but not in GBS-2A.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [
          _student(wisaId: 'w1', classGroup: '2A'),
          _student(wisaId: 'w2', classGroup: '2A'),
        ],
        ssAccounts: [
          _ssAccount('jane', accountId: 'w1'),
          _ssAccount('joe', accountId: 'w2'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1'])
        ],
      );

      final sync =
          _actionsOfType<actions.SyncAzureClassGroupMembers>(linked).single;
      expect(sync.plan.membersToAdd, ['az-2'],
          reason: 'the class row still reports the same one student');

      final byAccount = memberships(linked);
      expect(byAccount, hasLength(1),
          reason: 'only the student the class row would add reports anything');
      final action = byAccount.values.single;
      expect(action.placement.className, '2A');
      expect(action.placement.groupName, 'GBS-2A');
      expect(action.placement.missingFromOwnGroup, isTrue);
      expect(action.placement.strayGroupNames, isEmpty);
      expect(action.canApply, isFalse,
          reason: 'the class-level sync performs the one write');
      expect(action.describeChanges().summary, contains('GBS-2A'));
    });

    test('a student left in their old class group names that group', () {
      final linked = _recompute(
        classGroups: [_wClass('2A'), _wClass('2B')],
        students: [_student(wisaId: 'w1', classGroup: '2B')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
          _classGroup('2B', memberIds: const ['az-1']),
        ],
      );

      final action = memberships(linked).values.single;
      expect(action.placement.isMember, isTrue,
          reason: 'they are already in their own 2B group');
      expect(action.placement.missingFromOwnGroup, isFalse);
      expect(action.placement.strayGroupNames, ['GBS-2A']);
      expect(action.describeChanges().summary, contains('GBS-2A'));
    });

    test('the wrong class group is reported once, in both directions', () {
      final linked = _recompute(
        classGroups: [_wClass('2A'), _wClass('2B')],
        students: [_student(wisaId: 'w1', classGroup: '2B')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
          _classGroup('2B'),
        ],
      );

      final action = memberships(linked).values.single;
      expect(action.placement.missingFromOwnGroup, isTrue);
      expect(action.placement.strayGroupNames, ['GBS-2A']);
      final summary = action.describeChanges().summary;
      expect(summary, contains('GBS-2A in plaats van GBS-2B'));

      // And it is the same fact the two class rows report, not a third one.
      final syncs = {
        for (final s
            in _actionsOfType<actions.SyncAzureClassGroupMembers>(linked))
          s.plan.className: s.plan,
      };
      expect(syncs['2A']!.membersToRemove, ['az-1']);
      expect(syncs['2B']!.membersToAdd, ['az-1']);
    });

    test('a sub-grouped class reports the parent group, not the sub-group', () {
      final linked = _recompute(
        classGroups: [
          _wClass('2F', groupName: 'ECO', adminCode: 'a'),
          _wClass('2F', groupName: 'MAW', adminCode: 'b'),
        ],
        students: [
          _student(wisaId: 'w1', classGroup: '2F', classSubGroup: 'ECO'),
          _student(wisaId: 'w2', classGroup: '2F', classSubGroup: 'MAW'),
        ],
        ssAccounts: [
          _ssAccount('jane', accountId: 'w1'),
          _ssAccount('joe', accountId: 'w2'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2F', memberIds: const ['az-1'])
        ],
      );

      final byAccount = memberships(linked);
      expect(byAccount, hasLength(1));
      final action = byAccount.values.single;
      expect(action.placement.groupName, 'GBS-2F',
          reason: 'sub-groups share the parent class\'s one group');
      expect(action.placement.strayGroupNames, isEmpty,
          reason: 'their own group is not a stray one');
    });

    test('a class with no group yet reports nothing per student', () {
      // CreateAzureClassGroup is the work, and it chains the roster (#245);
      // repeating it on every student of the class would be pure noise.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
      );

      expect(
          _actionsOfType<actions.CreateAzureClassGroup>(linked), hasLength(1));
      expect(memberships(linked), isEmpty);
    });

    test('the group of a vanished class is never reported as a stray', () {
      // Nothing removes a member from it — the whole group either goes or stays
      // (DeleteAzureClassGroup) — so naming it per student would be work nobody
      // can do.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [_azUser('az-1', employeeId: 'w1')],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
          _classGroup('9Z', memberIds: const ['az-1']),
        ],
      );

      expect(
          _actionsOfType<actions.DeleteAzureClassGroup>(linked), hasLength(1));
      expect(memberships(linked), isEmpty);
    });

    test('a member this app cannot account for gets no per-account report', () {
      // The class titular sitting in GBS-2A is not one of our students, so
      // neither the class plan nor the per-account view names them.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-teacher', employeeId: 'staff'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-teacher']),
        ],
      );

      expect(memberships(linked), isEmpty);
    });
  });
}
