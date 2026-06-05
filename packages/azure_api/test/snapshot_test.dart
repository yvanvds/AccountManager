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
  });
}
