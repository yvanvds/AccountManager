import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  group('AzureUser', () {
    test('implements core.AzureUser linking interface', () {
      const core.AzureUser user =
          AzureUser(id: 'i', upn: 'a@b', employeeId: 'W1');
      expect(user.id, 'i');
      expect(user.upn, 'a@b');
      expect(user.employeeId, 'W1');
    });

    test('fromGraphJson maps Graph fields ⇒ model fields', () {
      final json = readJsonFixture('user_single.json');
      final user = AzureUser.fromGraphJson(json);
      expect(user.id, '00000000-0000-0000-0000-000000000001');
      expect(user.upn, 'ann.peeters@student.school.example');
      expect(user.employeeId, 'W1001');
      expect(user.displayName, 'Ann Peeters');
      expect(user.givenName, 'Ann');
      expect(user.surname, 'Peeters');
      expect(user.companyName, 'GBS');
      expect(user.department, '3A');
      expect(user.accountEnabled, isTrue);
    });

    test('fromGraphJson treats empty/absent employeeId & companyName as null',
        () {
      final user = AzureUser.fromGraphJson({
        'id': 'x',
        'userPrincipalName': 'u@d',
        'employeeId': '',
      });
      expect(user.employeeId, isNull);
      expect(user.companyName, isNull);
      expect(user.department, isNull);
      expect(user.displayName, '');
    });

    test('isRemoved detects @removed delta entries', () {
      expect(
        AzureUser.isRemoved({
          'id': 'x',
          '@removed': {'reason': 'deleted'},
        }),
        isTrue,
      );
      expect(AzureUser.isRemoved({'id': 'x'}), isFalse);
    });

    test('graphSelectFields holds exactly the fields the port reads', () {
      expect(AzureUser.graphSelectFields, [
        'id',
        'userPrincipalName',
        'employeeId',
        'displayName',
        'givenName',
        'surname',
        'companyName',
        'department',
        'accountEnabled',
      ]);
    });

    test('toJson/fromJson round-trip', () {
      const user = AzureUser(
        id: 'i',
        upn: 'a@b',
        employeeId: 'W1',
        displayName: 'A B',
        givenName: 'A',
        surname: 'B',
        companyName: 'GBS',
        department: '3A',
        accountEnabled: false,
      );
      expect(AzureUser.fromJson(user.toJson()), user);
    });

    test('copyWith replaces only named fields', () {
      const user = AzureUser(id: 'i', upn: 'a@b', department: '3A');
      final moved = user.copyWith(department: '4A');
      expect(moved.department, '4A');
      expect(moved.id, 'i');
      expect(moved.upn, 'a@b');
    });

    test('equality is value-based', () {
      const a = AzureUser(id: 'i', upn: 'a@b');
      const b = AzureUser(id: 'i', upn: 'a@b');
      const c = AzureUser(id: 'i', upn: 'x@y');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('AzureGroup', () {
    test('implements core.AzureGroup and carries members + securityEnabled',
        () {
      final json = readJsonFixture('groups.json');
      final row = (json['value'] as List).first as Map<String, dynamic>;
      final group = AzureGroup.fromGraphJson(
        row,
        members: const ['m1', 'm2'],
      );
      expect(group, isA<core.AzureGroup>());
      expect(group.id, 'g0000000-0000-0000-0000-0000000000a1');
      expect(group.displayName, 'GBS-3A');
      expect(group.securityEnabled, isTrue);
      expect(group.memberIds, ['m1', 'm2']);
      expect(group.hasMember('m1'), isTrue);
      expect(group.hasMember('zzz'), isFalse);
    });

    test('memberIds is unmodifiable', () {
      final group = AzureGroup(id: 'g', displayName: 'n', memberIds: ['a']);
      expect(() => group.memberIds.add('b'), throwsUnsupportedError);
    });

    test('toJson/fromJson round-trip', () {
      final group = AzureGroup(
        id: 'g',
        displayName: 'GBS-3A',
        securityEnabled: true,
        memberIds: const ['m1', 'm2'],
      );
      expect(AzureGroup.fromJson(group.toJson()), group);
    });

    test('carries the address a class group is identified by (#228)', () {
      final group = AzureGroup.fromGraphJson(const <String, dynamic>{
        'id': 'g1',
        'displayName': 'GBS-2A',
        'securityEnabled': false,
        'mail': 'GBS-2A@student.school.example',
        'mailNickname': 'GBS-2A',
      });
      expect(group.mail, 'GBS-2A@student.school.example');
      expect(group.mailNickname, 'GBS-2A');
      expect(group.isUnified, isTrue);
      expect(AzureGroup.fromJson(group.toJson()), group);
      expect(group.withMembers(const ['m1']).mail, group.mail);
    });

    test('a security group is not unified, whatever it is named (#228)', () {
      final group = AzureGroup(
        id: 'g',
        displayName: 'GBS-Personeel',
        securityEnabled: true,
      );
      expect(group.isUnified, isFalse);
      // Nor is a mail-less group that merely is not security-enabled.
      expect(AzureGroup(id: 'g2', displayName: 'GBS-2A').isUnified, isFalse);
    });

    test('two groups differing only in address are not equal (#228)', () {
      final a = AzureGroup(
        id: 'g',
        displayName: 'GBS-2A',
        mail: 'GBS-2A@student.school.example',
      );
      final b = AzureGroup(
        id: 'g',
        displayName: 'GBS-2A',
        mail: 'GBS-2A@other.example',
      );
      expect(a, isNot(b));
    });
  });
}
