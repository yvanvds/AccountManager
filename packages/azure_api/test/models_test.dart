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
      // Both halves of the licensing rule are read, not just the school (#358).
      expect(user.jobTitle, 'LeerlingSec');
      expect(user.accountEnabled, isTrue);
    });

    test('fromGraphJson treats empty/absent employeeId & companyName as null',
        () {
      final user = AzureUser.fromGraphJson({
        'id': 'x',
        'userPrincipalName': 'u@d',
        'employeeId': '',
        'jobTitle': '',
      });
      expect(user.employeeId, isNull);
      expect(user.companyName, isNull);
      expect(user.department, isNull);
      // A blank `jobTitle` is exactly what this port's own creates left behind
      // (#358), so it must read as absent rather than as the empty string.
      expect(user.jobTitle, isNull);
      expect(user.displayName, '');
    });

    group('mergeGraphJson (#288)', () {
      const stored = AzureUser(
        id: 'az1',
        upn: 'jane.doe@student.school.example',
        employeeId: 'W1',
        displayName: 'Jane Doe',
        givenName: 'Jane',
        surname: 'Doe',
        companyName: 'GBS',
        department: '3C',
        jobTitle: 'LeerlingSec',
      );

      test('a property the row omits keeps its current value', () {
        final merged = stored.mergeGraphJson(<String, dynamic>{
          'id': 'az1',
          'displayName': 'Janneke Doe',
        });
        expect(merged, stored.copyWith(displayName: 'Janneke Doe'));
      });

      test('a property the row sends as null is cleared', () {
        final merged = stored.mergeGraphJson(<String, dynamic>{
          'id': 'az1',
          'employeeId': null,
          'department': null,
        });
        expect(merged.employeeId, isNull);
        expect(merged.department, isNull);
        expect(merged.companyName, 'GBS', reason: 'unmentioned, so untouched');
        expect(merged.jobTitle, 'LeerlingSec',
            reason: 'unmentioned, so untouched');
      });

      test('a cleared jobTitle arrives as a null the row does send (#358)', () {
        // Somebody stripping the field by hand is how an account silently drops
        // out of the licensing group, so the delta walk has to be able to carry
        // that away — the same presence-not-emptiness rule the other optional
        // strings follow.
        final merged = stored.mergeGraphJson(<String, dynamic>{
          'id': 'az1',
          'jobTitle': null,
        });
        expect(merged.jobTitle, isNull);
        expect(merged.companyName, 'GBS');
      });

      test('accountEnabled follows presence, not truthiness', () {
        expect(
            stored
                .mergeGraphJson(<String, dynamic>{'id': 'az1'}).accountEnabled,
            isTrue);
        expect(
          stored.mergeGraphJson(<String, dynamic>{
            'id': 'az1',
            'accountEnabled': false
          }).accountEnabled,
          isFalse,
        );
      });

      test('an empty incoming id never replaces the one we are keyed by', () {
        expect(stored.mergeGraphJson(<String, dynamic>{'id': ''}).id, 'az1');
        expect(stored.mergeGraphJson(const <String, dynamic>{}).id, 'az1');
      });
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
        // #358: the second half of the licensing rule. Without it in the
        // `$select` no pull can read the field, so nothing could compare or
        // repair it.
        'jobTitle',
        'accountEnabled',
        // #363: the creation date rides along on the bulk read because it needs
        // no permission the pull does not already hold. `signInActivity` is
        // deliberately *not* here — it needs AuditLog.Read.All, so in this list
        // it would fail every pull instead of one extra targeted read.
        'createdDateTime',
      ]);
      expect(AzureUser.graphSelectFields, isNot(contains('signInActivity')));
    });

    group('createdDateTime and signInActivity (#363)', () {
      test('a Graph row carries the creation date through as UTC', () {
        final user = AzureUser.fromGraphJson(<String, dynamic>{
          'id': 'az1',
          'userPrincipalName': 'a@b',
          'createdDateTime': '2025-09-01T12:00:00Z',
        });
        expect(user.createdAt, DateTime.utc(2025, 9, 1, 12));
        // Not selected on any bulk read, so a plain row leaves it unknown.
        expect(user.lastSignIn, isNull);
      });

      test('a row with no creation date leaves it unknown, not epoch', () {
        final user = AzureUser.fromGraphJson(
          <String, dynamic>{'id': 'az1', 'userPrincipalName': 'a@b'},
        );
        expect(user.createdAt, isNull);
      });

      test('signInActivity takes the later of the two timestamps', () {
        // A student who only ever meets the account through a signed-in Outlook
        // produces nothing but non-interactive refreshes; calling that "last
        // used in February" would be exactly the wrong answer.
        expect(
          AzureUser.parseSignInActivity(<String, dynamic>{
            'lastSignInDateTime': '2026-02-02T09:00:00Z',
            'lastNonInteractiveSignInDateTime': '2026-08-20T07:30:00Z',
          }),
          DateTime.utc(2026, 8, 20, 7, 30),
        );
        expect(
          AzureUser.parseSignInActivity(<String, dynamic>{
            'lastSignInDateTime': '2026-08-20T07:30:00Z',
            'lastNonInteractiveSignInDateTime': '2026-02-02T09:00:00Z',
          }),
          DateTime.utc(2026, 8, 20, 7, 30),
        );
      });

      test('signInActivity survives either half being absent or null', () {
        expect(
          AzureUser.parseSignInActivity(<String, dynamic>{
            'lastSignInDateTime': '2026-02-02T09:00:00Z',
            'lastNonInteractiveSignInDateTime': null,
          }),
          DateTime.utc(2026, 2, 2, 9),
        );
        expect(
          AzureUser.parseSignInActivity(<String, dynamic>{
            'lastNonInteractiveSignInDateTime': '2026-02-02T09:00:00Z',
          }),
          DateTime.utc(2026, 2, 2, 9),
        );
        // An account that has never signed in: Graph sends the object with
        // every timestamp null.
        expect(
          AzureUser.parseSignInActivity(<String, dynamic>{
            'lastSignInDateTime': null,
            'lastNonInteractiveSignInDateTime': null,
          }),
          isNull,
        );
        expect(AzureUser.parseSignInActivity(null), isNull);
      });

      test('a delta row that never mentions them keeps both (#288)', () {
        // `signInActivity` cannot be in a delta `$select` at all, so a resumed
        // row that blanked it would throw away the targeted read of the pass
        // that fetched it.
        final stored = AzureUser(
          id: 'az1',
          upn: 'a@b',
          createdAt: DateTime.utc(2025, 9, 1, 12),
          lastSignIn: DateTime.utc(2026, 8, 20, 7, 30),
        );
        final merged = stored.mergeGraphJson(
          <String, dynamic>{'id': 'az1', 'displayName': 'A B'},
        );
        expect(merged.createdAt, DateTime.utc(2025, 9, 1, 12));
        expect(merged.lastSignIn, DateTime.utc(2026, 8, 20, 7, 30));
      });

      test('both round-trip through the cache shape', () {
        final user = AzureUser(
          id: 'az1',
          upn: 'a@b',
          createdAt: DateTime.utc(2025, 9, 1, 12),
          lastSignIn: DateTime.utc(2026, 8, 20, 7, 30),
        );
        expect(AzureUser.fromJson(user.toJson()), user);
        // Value-based equality covers them, so a snapshot restored from the
        // cache cannot silently forget which twin was signed into.
        expect(
          AzureUser.fromJson(
            user.copyWith(lastSignIn: DateTime.utc(2026, 8, 21)).toJson(),
          ),
          isNot(user),
        );
      });
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
        jobTitle: 'LeerlingSec',
        accountEnabled: false,
      );
      expect(AzureUser.fromJson(user.toJson()), user);
      // Value-based equality covers it too, so a snapshot restored from the
      // cache cannot silently forget which pupils are licensed (#358).
      expect(
        AzureUser.fromJson(user.copyWith(jobTitle: 'LeerlingBas').toJson()),
        isNot(user),
      );
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
        'mailEnabled': true,
        'groupTypes': ['Unified'],
        'mail': 'GBS-2A@student.school.example',
        'mailNickname': 'GBS-2A',
      });
      expect(group.mail, 'GBS-2A@student.school.example');
      expect(group.mailNickname, 'GBS-2A');
      expect(group.isUnified, isTrue);
      expect(group.canManageMembership, isTrue);
      expect(AzureGroup.fromJson(group.toJson()), group);
      expect(group.withMembers(const ['m1']).mail, group.mail);
      expect(group.withMembers(const ['m1']).isUnified, isTrue,
          reason: 'the shape survives a local membership patch');
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

    group('the four group shapes Graph distinguishes (#331)', () {
      // The reported bug: `SSM-1A` is a mail-enabled security group, the one
      // shape among the school's 372 `SSM-` groups whose membership Graph will
      // not manage — and the app could not see it, because `graphSelectFields`
      // asked for neither `mailEnabled` nor `groupTypes` and `isUnified` was
      // inferred from `securityEnabled` + `mail`.
      AzureGroup shape({
        required bool mailEnabled,
        required bool securityEnabled,
        List<String> groupTypes = const [],
        String? mail = 'SSM-1A@arcadiascholen.be',
      }) =>
          AzureGroup(
            id: 'g',
            displayName: 'SSM-1A',
            securityEnabled: securityEnabled,
            mailEnabled: mailEnabled,
            groupTypes: groupTypes,
            mail: mail,
          );

      test('a Microsoft 365 group is managed', () {
        final group = shape(
          mailEnabled: true,
          securityEnabled: false,
          groupTypes: const ['Unified'],
        );
        expect(group.isUnified, isTrue);
        expect(group.isExchangeManaged, isFalse);
        expect(group.canManageMembership, isTrue);
      });

      test('a plain security group is managed — the legacy class groups', () {
        // `SSM-3ECO` and its 115 siblings: made by the WPF app, no address at
        // all, and Graph writes their membership perfectly well (#312).
        final group =
            shape(mailEnabled: false, securityEnabled: true, mail: null);
        expect(group.isUnified, isFalse);
        expect(group.canManageMembership, isTrue);
      });

      test('a mail-enabled security group is not — the reported bug', () {
        final group = shape(mailEnabled: true, securityEnabled: true);
        expect(group.isUnified, isFalse);
        expect(group.isExchangeManaged, isTrue);
        expect(group.canManageMembership, isFalse);
      });

      test('nor is a distribution list, which used to read as unified', () {
        // The other half of what the old inference got wrong: not
        // security-enabled and carrying an address made a plain distribution
        // list indistinguishable from a Microsoft 365 group.
        final group = shape(mailEnabled: true, securityEnabled: false);
        expect(group.isUnified, isFalse);
        expect(group.canManageMembership, isFalse);
      });

      test('the shape round-trips through the stored snapshot', () {
        final group = shape(mailEnabled: true, securityEnabled: true);
        final restored = AzureGroup.fromJson(group.toJson());
        expect(restored, group);
        expect(restored.canManageMembership, isFalse,
            reason: 'a stored snapshot must not forget why a class is stuck');
      });

      test('a snapshot written before #331 reads as a group we manage', () {
        // Neither field was stored then. Defaulting them the other way would
        // withhold every class group\'s roster sync until the next Azure pull;
        // this way an old snapshot behaves exactly as it did.
        final restored = AzureGroup.fromJson(const <String, dynamic>{
          'id': 'g',
          'displayName': 'GBS-2A',
          'securityEnabled': false,
          'mail': 'GBS-2A@student.school.example',
          'mailNickname': 'GBS-2A',
          'memberIds': <String>[],
        });
        expect(restored.canManageMembership, isTrue);
        expect(restored.groupTypes, isEmpty);
        expect(restored.mailEnabled, isFalse);
      });

      test('groupTypes is unmodifiable', () {
        final group = shape(
          mailEnabled: true,
          securityEnabled: false,
          groupTypes: const ['Unified'],
        );
        expect(() => group.groupTypes.add('Dynamic'), throwsUnsupportedError);
      });

      test('two groups differing only in shape are not equal', () {
        expect(
          shape(mailEnabled: true, securityEnabled: true),
          isNot(shape(
            mailEnabled: true,
            securityEnabled: true,
            groupTypes: const ['Unified'],
          )),
        );
      });
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
