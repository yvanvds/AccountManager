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

  test('toJson/fromJson round-trips groups, accounts, memberships (#107)', () {
    final full = SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026, 6, 5, 8, 15),
      groups: [
        const core.Group(
          id: core.GroupId('C1A'),
          name: '1A',
          description: 'First',
          type: core.GroupType.classGroup,
          official: true,
          untis: '1A',
          sourceId: 298,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: const [
        SmartschoolAccount(
          uid: 'jand',
          accountId: '150001',
          mail: 'jan.doe@student.school.example',
          registerId: '01010112345',
          stemId: 20000001,
          role: core.PersonRole.student,
          givenName: 'Jan',
          surname: 'Doe',
          extraNames: '',
          initials: 'JD',
          preferredName: 'Jantje',
          gender: core.Gender.male,
          birthDate: null,
          birthPlace: 'Gent',
          birthCountry: 'BE',
          address: core.Address(
            street: 'Kerkstraat',
            houseNumber: '1',
            postalCode: '9000',
            city: 'Gent',
            country: 'BE',
          ),
          mobilePhone: '',
          homePhone: '',
          fax: '',
          untisId: '',
          status: 'actief',
          referenceIdentifier: '4069_12016_0',
          coAccounts: [
            CoAccountSlot(
              slot: 1,
              firstName: 'Mama',
              lastName: 'Doe',
              email: 'mama@doe.example',
              phone: '',
              mobile: '0470',
              type: 'Moeder',
            ),
          ],
        ),
      ],
      memberships: const [
        SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1A')),
      ],
    );

    final restored = SmartschoolSnapshot.fromJson(full.toJson());
    expect(restored.fetchedAt, full.fetchedAt);
    expect(restored.groups, full.groups);
    expect(restored.accounts, full.accounts);
    expect(restored.memberships, full.memberships);
    // Co-account slots survive the round-trip (they were the point of #21).
    expect(restored.accounts.single.coAccounts, hasLength(1));
    // The Smartschool-internal ids reach the persisted snapshot too (#138).
    expect(restored.groups.single.sourceId, 298);
    expect(restored.accounts.single.referenceIdentifier, '4069_12016_0');
    expect(restored.accounts.single.internalUserId, 12016);
  });
}
