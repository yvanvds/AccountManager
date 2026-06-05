import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  final snapshot = SmartschoolSnapshot(
    fetchedAt: DateTime(2026, 6, 5),
    groups: [
      const core.Group(
        id: core.GroupId('C1A'),
        name: '1A',
        description: '',
        type: core.GroupType.classGroup,
        official: true,
        origin: core.Origin.smartschool,
      ),
    ],
    accounts: const [],
    memberships: const [
      SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1A')),
    ],
  );

  test('exposes origin and fetchedAt', () {
    expect(snapshot.origin, core.Origin.smartschool);
    expect(snapshot.fetchedAt, DateTime(2026, 6, 5));
  });

  test('lists are unmodifiable', () {
    expect(
      () => snapshot.groups.add(snapshot.groups.first),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.memberships.add(snapshot.memberships.first),
      throwsUnsupportedError,
    );
  });

  test('is a core.Snapshot', () {
    expect(snapshot, isA<core.Snapshot>());
  });
}
