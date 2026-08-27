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

/// An Office 365 account this app owns as one of its **students**: INV-22's
/// student half is the `companyName` stamp, so an account carrying it and
/// nothing else is a former pupil of ours, not an unknown (#385).
az.AzureUser _azUser(String id, {required String employeeId}) => az.AzureUser(
      id: id,
      upn: '$id@$_domain',
      employeeId: employeeId,
      companyName: _prefix,
    );

/// An Office 365 account this app owns as one of its **staff**: the school
/// prefix sits in `department`, the comma-separated list other software
/// maintains, and `companyName` is somebody else's business (INV-22's staff
/// half). The linker keeps it as a [core.LinkedStaff], which is what puts it
/// out of every class-group removal's reach (#385).
az.AzureUser _azStaff(String id, {String? employeeId}) => az.AzureUser(
      id: id,
      upn: '$id@school.example',
      employeeId: employeeId,
      department: _prefix,
    );

wapi.WisaSchool _school(int id) =>
    wapi.WisaSchool(id: id, name: 'School $id', code: '');

wapi.WisaStaff _wStaff({String code = 'SMIT', String wisaId = 's1'}) =>
    wapi.WisaStaff(
      code: core.WisaStaffCode(code),
      wisaId: core.WisaId(wisaId),
      firstName: 'Anna',
      lastName: 'Smit',
      schoolIds: const {1},
    );

az.AzureGroup _classGroup(String className,
        {List<String> memberIds = const []}) =>
    az.AzureGroup(
      id: 'az-$_prefix-$className',
      displayName: '$_prefix-$className',
      mail: '$_prefix-$className@$_domain',
      mailNickname: '$_prefix-$className',
      mailEnabled: true,
      groupTypes: const ['Unified'],
      memberIds: memberIds,
    );

/// The same class group, hand-made as a **mail-enabled security group** (#331):
/// indistinguishable by name or address, and the one shape Graph will not write
/// the membership of.
az.AzureGroup _mailEnabledSecurityClassGroup(String className,
        {List<String> memberIds = const []}) =>
    az.AzureGroup(
      id: 'az-$_prefix-$className',
      displayName: '$_prefix-$className',
      mail: '$_prefix-$className@$_domain',
      mailNickname: '$_prefix-$className',
      mailEnabled: true,
      securityEnabled: true,
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
  List<wapi.WisaStaff> staff = const [],
  List<wapi.WisaClassGroup> classGroups = const [],
  List<wapi.WisaSchool> schools = const [],
  List<az.AzureUser> azureUsers = const [],
  List<az.AzureGroup> azureGroups = const [],
  List<core.Group> ssGroups = const [],
  List<ss.SmartschoolAccount> ssAccounts = const [],
  // Which WISA schools we manage (#133). Left unset by default so every
  // WISA-present student reads as ours, exactly as the pre-#134 fixtures
  // assume; a test about a student who moved to a *sibling* group school
  // (WisaPresence.groupOnly) has to name it.
  Set<int>? ourSchoolIds,
}) =>
    LinkedState.recompute(
      wisa: wapi.WisaSnapshot(
        fetchedAt: _d,
        students: students,
        staff: staff,
        classGroups: classGroups,
        schools: schools,
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
      ourSchoolIds: ourSchoolIds,
    );

List<T> _actionsOfType<T>(LinkedState linked) =>
    linked.groupActions.whereType<T>().toList();

/// The class-level roster plans of a linked view, keyed by bare class name.
Map<String, actions.AzureClassGroupPlan> _plansByClass(LinkedState linked) => {
      for (final s
          in _actionsOfType<actions.SyncAzureClassGroupMembers>(linked))
        s.plan.className: s.plan,
    };

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

  group('a class group Graph will not manage (#331)', () {
    // End to end through the real linker + resolver + dispatch: `GBS-1A` is a
    // mail-enabled security group, so the roster diff the resolver computes is
    // perfectly real and there is no write that can land it.
    LinkedState stuckClass() => _recompute(
          classGroups: [_wClass('1A')],
          students: [
            _student(wisaId: 'w1', classGroup: '1A'),
            _student(wisaId: 'w2', classGroup: '1A'),
          ],
          azureUsers: [
            _azUser('az-1', employeeId: 'w1'),
            _azUser('az-2', employeeId: 'w2'),
          ],
          ssAccounts: [
            _ssAccount('jane', accountId: 'w1'),
            _ssAccount('joe', accountId: 'w2'),
          ],
          azureGroups: [
            _mailEnabledSecurityClassGroup('1A', memberIds: const ['az-1']),
          ],
        );

    test('the class raises the notice instead of the roster sync', () {
      final linked = stuckClass();
      expect(
        _actionsOfType<actions.SyncAzureClassGroupMembers>(linked),
        isEmpty,
        reason: 'every add and remove on this group is refused',
      );
      final notice =
          _actionsOfType<actions.AzureClassGroupNotManageable>(linked).single;
      expect(notice.canApply, isFalse);
      expect(
        notice.describeChanges().summary,
        contains('GBS-1A is een mail-enabled beveiligingsgroep'),
      );
    });

    test('the identical class on a Microsoft 365 group still syncs', () {
      // The control: only the group's shape differs between the two.
      final linked = _recompute(
        classGroups: [_wClass('1A')],
        students: [
          _student(wisaId: 'w1', classGroup: '1A'),
          _student(wisaId: 'w2', classGroup: '1A'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-2', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('1A', memberIds: const ['az-1'])
        ],
      );
      expect(
        _actionsOfType<actions.SyncAzureClassGroupMembers>(linked)
            .single
            .plan
            .membersToAdd,
        ['az-2'],
      );
      expect(
        _actionsOfType<actions.AzureClassGroupNotManageable>(linked),
        isEmpty,
      );
    });

    test('the student\'s own row points at Exchange, not at the class card',
        () {
      // The per-account half (#245) reads the same fact from the same resolver,
      // so the two views cannot disagree about where the remedy lives.
      final membership = stuckClass()
          .studentActions
          .whereType<actions.AzureClassGroupMembership>()
          .single;
      expect(membership.placement.unmanagedGroupNames, ['GBS-1A']);
      expect(
        membership.describeChanges().summary,
        contains('Die groep wordt in Exchange Online beheerd'),
      );
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
      // neither the class plan nor the per-account view names them. Their
      // account is stamped the way a staff account is — the prefix in
      // `department`, never in the student `companyName` (INV-22) — which is
      // what makes them a member this app cannot account for as a pupil rather
      // than an unstamped stranger.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        ssAccounts: [_ssAccount('jane', accountId: 'w1')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azStaff('az-teacher', employeeId: 'staff'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-teacher']),
        ],
      );

      expect(memberships(linked), isEmpty);
      expect(
        _actionsOfType<actions.SyncAzureClassGroupMembers>(linked),
        isEmpty,
        reason: 'and the class row proposes nothing either — the titular is '
            'not a roster difference',
      );
    });
  });

  group('a student who left our school (#385)', () {
    /// The per-student class-group actions of a linked view, keyed by the Azure
    /// object id of the account they target — the id the class-level plan
    /// speaks in, so the two views can be compared directly.
    Map<String, actions.AzureClassGroupMembership> membershipsByAzureId(
      LinkedState linked,
    ) =>
        {
          for (final a in linked.studentActions
              .whereType<actions.AzureClassGroupMembership>())
            a.target.azure!.id: a,
        };

    test('a leaver is removed from the class group they still sit in', () {
      // The bug: `w2` is gone from WISA altogether, so their record is the
      // incomplete, Azure-only one flagged for deletion — and the removal net
      // used to be built from students *currently* in our WISA, a set they can
      // never be in. They sat in GBS-2A for ever.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-gone', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-gone']),
        ],
      );

      final plan = _plansByClass(linked)['2A'];
      expect(plan, isNotNull, reason: 'the class has a roster difference now');
      expect(plan!.membersToRemove, ['az-gone']);
      expect(plan.membersToAdd, isEmpty);
    });

    test('a student who moved to a sibling group school is removed too', () {
      // WisaPresence.groupOnly: still somewhere in the scholengroep, no longer
      // ours. Their Office 365 account is deliberately kept (#134) — which is
      // exactly why their membership of *our* class group has to go.
      final linked = _recompute(
        schools: [_school(1), _school(2)],
        classGroups: [_wClass('2A')],
        students: [
          _student(wisaId: 'w1', classGroup: '2A'),
          _student(wisaId: 'w2', classGroup: '3B', schoolId: 2),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-moved', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-moved']),
        ],
        ourSchoolIds: const {1},
      );

      expect(_plansByClass(linked)['2A']!.membersToRemove, ['az-moved']);
    });

    test("a sibling school's class never becomes a target group (INV-25)", () {
      // The other half of the same record: `3B` is the class the *other* school
      // holds them in, and it is presence and nothing else. Deriving a target
      // from it would send this app looking for GBS-3B in our own tenant.
      final linked = _recompute(
        schools: [_school(1), _school(2)],
        classGroups: [_wClass('2A'), _wClass('3B')],
        students: [
          _student(wisaId: 'w1', classGroup: '2A'),
          _student(wisaId: 'w2', classGroup: '3B', schoolId: 2),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-moved', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-moved']),
          _classGroup('3B'),
        ],
        ourSchoolIds: const {1},
      );

      final placement = membershipsByAzureId(linked)['az-moved']!.placement;
      expect(placement.className, isEmpty);
      expect(placement.groupName, isNull);
      expect(placement.missingFromOwnGroup, isFalse,
          reason: 'they are not missing from a group that is not theirs');
      expect(placement.strayGroupNames, ['GBS-2A']);
      expect(_plansByClass(linked).containsKey('3B'), isFalse,
          reason: 'and our own 3B proposes nothing — a sibling school\'s pupil '
              'never lands on its roster');
    });

    test('a teacher in the class group is never removed, bulk included', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        staff: [_wStaff()],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azStaff('az-titular', employeeId: 's1'),
          _azUser('az-gone', employeeId: 'w9'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-titular', 'az-gone']),
        ],
      );

      final sync =
          _actionsOfType<actions.SyncAzureClassGroupMembers>(linked).single;
      expect(sync.canApplyToAll, isTrue,
          reason: 'the September rollover applies this to every class at once, '
              'so the guarantee has to hold under the bulk flag itself');
      expect(sync.plan.membersToRemove, ['az-gone']);
    });

    test(
        'a teacher whose account also carries the student stamp is still never '
        'removed', () {
      // The collision the guard exists for: `companyName` says which school an
      // account belongs to, never what its holder is (#358). A teacher stamped
      // with it answers to a LinkedStaff record *and* looks, to the linker's
      // student pass, exactly like an Azure-only former pupil. Staff is the
      // reading that decides.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        staff: [_wStaff()],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          const az.AzureUser(
            id: 'az-titular',
            upn: 'anna.smit@school.example',
            employeeId: 's1',
            companyName: _prefix,
            department: _prefix,
          ),
          _azUser('az-gone', employeeId: 'w9'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-titular', 'az-gone']),
        ],
      );

      expect(_plansByClass(linked)['2A']!.membersToRemove, ['az-gone']);
    });

    test(
        'a bulk pass over a mixed group removes the mover and the leaver and '
        'nothing else', () {
      // Everything a September class group really holds, in one pass: a student
      // who stayed, one who moved to 2B, one who left the school, the titular,
      // and a member with no record of any kind — a guest, a shared mailbox.
      final linked = _recompute(
        classGroups: [_wClass('2A'), _wClass('2B')],
        staff: [_wStaff()],
        students: [
          _student(wisaId: 'w1', classGroup: '2A'),
          _student(wisaId: 'w2', classGroup: '2B'),
        ],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-mover', employeeId: 'w2'),
          _azUser('az-gone', employeeId: 'w9'),
          _azStaff('az-titular', employeeId: 's1'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const [
            'az-1',
            'az-mover',
            'az-gone',
            'az-titular',
            'az-stranger',
          ]),
          _classGroup('2B'),
        ],
      );

      final plans = _plansByClass(linked);
      expect(plans['2A']!.membersToRemove, ['az-mover', 'az-gone'],
          reason: 'the mover behaves exactly as it did before #385, and the '
              'leaver joins it — the titular and the stranger do not');
      expect(plans['2A']!.membersToAdd, isEmpty);
      expect(plans['2B']!.membersToAdd, ['az-mover']);
      expect(plans['2B']!.membersToRemove, isEmpty);
    });

    test(
        "the leaver's own card names the group the class row removes them "
        'from', () {
      // The two views are built by one resolver so they cannot disagree about a
      // student; fixing only the class plan is what would have made them.
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-gone', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1', 'az-gone']),
        ],
      );

      final byAzureId = membershipsByAzureId(linked);
      expect(byAzureId.keys, ['az-gone'],
          reason: 'nobody else has a class-group problem to report');
      final action = byAzureId['az-gone']!;
      expect(action.placement.strayGroupNames, ['GBS-2A']);
      expect(action.canApply, isFalse,
          reason: 'the class-level sync still performs the one write');
      expect(
        action.describeChanges().summary,
        contains('Staat nog in de Office 365-klasgroep GBS-2A'),
      );
      expect(_plansByClass(linked)['2A']!.membersToRemove, ['az-gone'],
          reason: 'the same student, the same group, read the other way');
    });

    test('a leaver who is in no class group of ours reports nothing', () {
      final linked = _recompute(
        classGroups: [_wClass('2A')],
        students: [_student(wisaId: 'w1', classGroup: '2A')],
        azureUsers: [
          _azUser('az-1', employeeId: 'w1'),
          _azUser('az-gone', employeeId: 'w2'),
        ],
        azureGroups: [
          _classGroup('2A', memberIds: const ['az-1']),
        ],
      );

      expect(membershipsByAzureId(linked), isEmpty);
      expect(
          _actionsOfType<actions.SyncAzureClassGroupMembers>(linked), isEmpty);
    });
  });
}
