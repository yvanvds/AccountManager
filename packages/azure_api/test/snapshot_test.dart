import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

void main() {
  group('AzureSnapshot', () {
    final snapshot = AzureSnapshot(
      fetchedAt: DateTime.utc(2026, 6, 5, 9),
      deltaToken: 'TOKEN123',
      users: const [
        AzureUser(id: 'i1', upn: 'a@b', employeeId: 'W1', department: '3A'),
      ],
      groups: [
        AzureGroup(id: 'g1', displayName: 'GBS-3A', memberIds: const ['i1']),
      ],
    );

    test('origin is azure', () {
      expect(snapshot.origin, core.Origin.azure);
      expect(snapshot, isA<core.Snapshot>());
    });

    test('exposed lists are unmodifiable', () {
      expect(
        () => snapshot.users.add(const AzureUser(id: 'x', upn: 'y')),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.groups.add(AzureGroup(id: 'x', displayName: 'y')),
        throwsUnsupportedError,
      );
    });

    test('toJson/fromJson round-trip preserves users, groups, token, time', () {
      final restored = AzureSnapshot.fromJson(snapshot.toJson());
      expect(restored.fetchedAt, snapshot.fetchedAt);
      expect(restored.deltaToken, 'TOKEN123');
      expect(restored.users, snapshot.users);
      expect(restored.groups, snapshot.groups);
    });

    test('one account per employeeId reports no collision', () {
      expect(snapshot.duplicateEmployeeIds, isEmpty);
    });
  });

  group('duplicateEmployeeIds (INV-26, #360)', () {
    AzureSnapshot snapOf(List<AzureUser> users) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 8, 25),
          users: users,
          groups: const [],
        );

    test('two accounts on one employeeId are both reported', () {
      // The live shape: one UPN keeps the given name's hyphen, the other strips
      // it, and both carry the WISA id.
      final snap = snapOf(const [
        AzureUser(id: 'i1', upn: 'marie-jeanne.doe@s.be', employeeId: 'W7'),
        AzureUser(id: 'i2', upn: 'mariejeanne.doe@s.be', employeeId: 'W7'),
      ]);

      expect(snap.duplicateEmployeeIds.keys, ['w7']);
      expect(
        snap.duplicateEmployeeIds['w7']!.map((u) => u.id),
        ['i1', 'i2'],
        reason: 'both accounts, in snapshot order',
      );
    });

    test('the key is normalized, so case and padding still collide', () {
      final snap = snapOf(const [
        AzureUser(id: 'i1', upn: 'a@s.be', employeeId: ' w7 '),
        AzureUser(id: 'i2', upn: 'b@s.be', employeeId: 'W7'),
      ]);

      expect(snap.duplicateEmployeeIds, hasLength(1));
      expect(snap.duplicateEmployeeIds['w7'], hasLength(2));
    });

    test('a blank or absent employeeId is not an identity to share', () {
      final snap = snapOf(const [
        AzureUser(id: 'i1', upn: 'a@s.be'),
        AzureUser(id: 'i2', upn: 'b@s.be'),
        AzureUser(id: 'i3', upn: 'c@s.be', employeeId: '   '),
      ]);

      expect(snap.duplicateEmployeeIds, isEmpty);
    });

    test('three accounts on one id are all reported', () {
      final snap = snapOf(const [
        AzureUser(id: 'i1', upn: 'a@s.be', employeeId: 'W7'),
        AzureUser(id: 'i2', upn: 'b@s.be', employeeId: 'W7'),
        AzureUser(id: 'i3', upn: 'c@s.be', employeeId: 'W7'),
        AzureUser(id: 'i4', upn: 'd@s.be', employeeId: 'W8'),
      ]);

      expect(snap.duplicateEmployeeIds.keys, ['w7']);
      expect(snap.duplicateEmployeeIds['w7'], hasLength(3));
    });

    test('the result is unmodifiable', () {
      final snap = snapOf(const [
        AzureUser(id: 'i1', upn: 'a@s.be', employeeId: 'W7'),
        AzureUser(id: 'i2', upn: 'b@s.be', employeeId: 'W7'),
      ]);

      expect(
        () => snap.duplicateEmployeeIds['w9'] = const <AzureUser>[],
        throwsUnsupportedError,
      );
    });
  });
}
