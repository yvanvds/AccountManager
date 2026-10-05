import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

/// Resolving our school's Office 365 staff group, `<PREFIX>-Personeel`, from
/// the Azure snapshot and wiring it into the staff dispatch (#444).
///
/// The action-level behaviour — who is offered what, and what an apply writes —
/// is covered in `account_actions/test/azure_staff_group_test.dart`. This file
/// is about the State layer's half: finding the group(s) by name, answering per
/// staff member whether their account is in them, and threading that through
/// `LinkedState.recompute` so the real dispatch sees it.
void main() {
  final d = DateTime.utc(2026);

  az.AzureGroup azGroup(
    String displayName, {
    String? id,
    List<String> members = const [],
    bool unified = true,
  }) =>
      az.AzureGroup(
        id: id ?? 'az-$displayName',
        displayName: displayName,
        mailEnabled: unified,
        groupTypes: unified ? const ['Unified'] : const [],
        securityEnabled: !unified,
        memberIds: members,
      );

  az.AzureSnapshot azure({
    List<az.AzureUser> users = const [],
    List<az.AzureGroup> groups = const [],
  }) =>
      az.AzureSnapshot(fetchedAt: d, users: users, groups: groups);

  wapi.WisaStaff wisaStaff({String code = 'SMIT', String wisaId = '42'}) =>
      wapi.WisaStaff(
        code: core.WisaStaffCode(code),
        wisaId: core.WisaId(wisaId),
        firstName: 'Anna',
        lastName: 'Smit',
      );

  /// In sync with [wisaStaff] and [azStaff] down to the copy code, so a record
  /// built from the three raises nothing but what a test is about.
  ss.SmartschoolAccount ssStaff() => const ss.SmartschoolAccount(
        uid: 'anna.smit',
        accountId: 'SMIT',
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
        address: core.Address(
          street: '',
          houseNumber: '',
          postalCode: '',
          city: '',
          country: '',
        ),
        mobilePhone: '',
        homePhone: '',
        fax: '0042',
        untisId: '',
        status: 'actief',
      );

  az.AzureUser azStaff({String id = 'az-s1'}) => az.AzureUser(
        id: id,
        upn: 'anna.smit@school.example',
        employeeId: '42',
        displayName: 'Anna Smit',
        givenName: 'Anna',
        surname: 'Smit',
        department: 'SSM',
      );

  core.LinkedStaff linkedStaff({az.AzureUser? azure}) => core.LinkedStaff(
        id: const core.LinkedAccountId('s0'),
        role: core.PersonRole.teacher,
        wisa: wisaStaff(),
        smartschool: ssStaff(),
        azure: azure,
        confidence: core.LinkConfidence.high,
      );

  group('AzureStaffGroupResolver', () {
    test('finds every group named exactly <PREFIX>-Personeel, and only those',
        () {
      final resolver = AzureStaffGroupResolver(
        azure: azure(groups: [
          azGroup('SSM-1A'),
          azGroup('SSM-Personeel', id: 'team'),
          azGroup('SSM-Personeel-Extra'),
          azGroup('ssm-personeel ', id: 'sec', unified: false),
          azGroup('SSM-Personeel 2526'),
          azGroup('GBS-Personeel'),
        ]),
        schoolPrefix: 'SSM',
      );

      expect(resolver.groupName, 'SSM-Personeel');
      expect(resolver.groups.map((g) => g.id), ['team', 'sec'],
          reason: 'case and stray whitespace aside, the name must match whole; '
              'a sibling school\'s staff group is never ours');
      expect(resolver.groupMissing, isFalse);
    });

    test('the name follows the school prefix, never a hard-coded SSM', () {
      final snapshot = azure(groups: [
        azGroup('SSM-Personeel', id: 'ssm'),
        azGroup('GBS-Personeel', id: 'gbs'),
      ]);
      expect(
        AzureStaffGroupResolver(azure: snapshot, schoolPrefix: 'GBS')
            .groups
            .map((g) => g.id),
        ['gbs'],
      );
    });

    test('answers per staff member which of the groups their account is in',
        () {
      final resolver = AzureStaffGroupResolver(
        azure: azure(groups: [
          azGroup('SSM-Personeel', id: 'team', members: ['az-s1']),
          azGroup('SSM-Personeel', id: 'sec', unified: false),
        ]),
        schoolPrefix: 'SSM',
      );

      final placement = resolver.placementFor(linkedStaff(azure: azStaff()));
      expect(placement.groupName, 'SSM-Personeel');
      expect(placement.memberOfGroupIds, {'team'});
      expect(placement.joinableGroups.map((g) => g.id), ['sec']);
      expect(placement.isMember, isFalse);

      // No account yet: a member of nothing, which is what the create joins.
      final none = resolver.placementFor(linkedStaff());
      expect(none.memberOfGroupIds, isEmpty);
      expect(none.joinableGroups.map((g) => g.id), ['team', 'sec']);
    });

    test('a missing group is reported once, as a fact about the tenant', () {
      final resolver = AzureStaffGroupResolver(
        azure: azure(groups: [azGroup('SSM-1A')]),
        schoolPrefix: 'SSM',
      );
      expect(resolver.groupMissing, isTrue);
      expect(resolver.placementFor(linkedStaff(azure: azStaff())).groupExists,
          isFalse);
    });

    test('a blank prefix names no group, and nothing is missing', () {
      final resolver = AzureStaffGroupResolver(
        azure: azure(groups: [azGroup('-Personeel'), azGroup('SSM-Personeel')]),
        schoolPrefix: '  ',
      );
      expect(resolver.groupName, isNull);
      expect(resolver.groups, isEmpty);
      expect(resolver.groupMissing, isFalse,
          reason: 'with no school to scope by there is nothing to look for');
    });
  });

  group('LinkedState wires the staff group into the dispatch', () {
    LinkedState recompute(az.AzureSnapshot azureSnapshot,
            {List<ss.SmartschoolAccount>? accounts}) =>
        LinkedState.recompute(
          wisa: wapi.WisaSnapshot(
            fetchedAt: d,
            students: const [],
            staff: [wisaStaff()],
            classGroups: const [],
            schools: const [],
          ),
          smartschool: ss.SmartschoolSnapshot(
            fetchedAt: d,
            groups: const [],
            accounts: accounts ?? [ssStaff()],
            memberships: const [],
          ),
          azure: azureSnapshot,
          resolver: _SeqResolver(),
          studentConfig: StudentActionConfig(
            schoolPrefix: 'SSM',
            azureDomain: 'school.example',
          ),
          staffConfig: StaffActionConfig(
            schoolPrefix: 'SSM',
            azureDomain: 'school.example',
          ),
        );

    test('a colleague outside the group is offered the join', () {
      final state = recompute(azure(
        users: [azStaff()],
        groups: [azGroup('SSM-Personeel', id: 'team')],
      ));
      final join =
          state.staffActions.whereType<AddStaffToAzureStaffGroup>().single;
      expect(join.placement.joinableGroups.map((g) => g.id), ['team']);
      expect(state.missingAzureStaffGroup, isNull);
    });

    test('a colleague in the group is offered nothing', () {
      final state = recompute(azure(
        users: [azStaff()],
        groups: [
          azGroup('SSM-Personeel', id: 'team', members: ['az-s1']),
        ],
      ));
      expect(state.staffActions, isEmpty);
    });

    test('no group: no action, and the name is handed up to be logged once',
        () {
      final state = recompute(azure(users: [azStaff()]));
      expect(state.staffActions, isEmpty);
      expect(state.missingAzureStaffGroup, 'SSM-Personeel');
    });

    test('a new hire\'s create carries the group it will join', () {
      final state = recompute(
        azure(groups: [azGroup('SSM-Personeel', id: 'team')]),
        accounts: const [],
      );
      final create = state.staffActions.whereType<AddStaffToAzure>().single;
      expect(
        create.azureGroupPlacement?.joinableGroups.map((g) => g.id),
        ['team'],
      );
    });
  });
}

/// Deterministic in-memory [core.PersonIdResolver] (mirrors the linker fixture).
class _SeqResolver implements core.PersonIdResolver {
  final Map<String, String> _seen = {};

  @override
  core.PersonId resolve(String naturalKey) =>
      core.PersonId(_seen.putIfAbsent(naturalKey, () => 'p${_seen.length}'));
}
