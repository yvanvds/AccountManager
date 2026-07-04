import 'package:account_core/account_core.dart' as core;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('WisaSnapshot', () {
    final fetchedAt = DateTime(2026, 5, 20, 9, 0);
    final snapshot = WisaSnapshot(
      fetchedAt: fetchedAt,
      students: const [],
      staff: const [],
      classGroups: const [],
      schools: const [WisaSchool(id: 1, name: 'SMA', description: 'X')],
    );

    test('origin is Origin.wisa', () {
      expect(snapshot.origin, core.Origin.wisa);
    });

    test('fetchedAt is preserved', () {
      expect(snapshot.fetchedAt, fetchedAt);
    });

    test('students list is unmodifiable', () {
      expect(
        () => (snapshot.students as List).add(_anyStudent()),
        throwsUnsupportedError,
      );
    });

    test('schools list is unmodifiable', () {
      expect(
        () => (snapshot.schools as List).clear(),
        throwsUnsupportedError,
      );
    });

    test('input list is copied (later mutation does not leak in)', () {
      final mutableSchools = [
        const WisaSchool(id: 1, name: 'SMA', description: 'X'),
      ];
      final snap = WisaSnapshot(
        fetchedAt: fetchedAt,
        students: const [],
        staff: const [],
        classGroups: const [],
        schools: mutableSchools,
      );
      mutableSchools.clear();
      expect(snap.schools, hasLength(1));
    });

    test('toJson/fromJson round-trips every list and field (#107)', () {
      final full = WisaSnapshot(
        fetchedAt: DateTime.utc(2026, 5, 20, 9, 30, 15),
        students: [_anyStudent()],
        staff: const [
          WisaStaff(
            code: core.WisaStaffCode('T01'),
            wisaId: core.WisaId('900001'),
            firstName: 'Ann',
            lastName: 'Teacher',
          ),
          // A staff member with no numeric id — the nullable branch.
          WisaStaff(
              code: core.WisaStaffCode('T02'), firstName: 'Bo', lastName: 'X'),
        ],
        classGroups: const [
          WisaClassGroup(
            name: '1A',
            groupName: '00',
            description: 'First',
            adminCode: 'A1',
            schoolCode: '012345',
            schoolId: 1,
          ),
        ],
        schools: const [
          WisaSchool(id: 1, name: 'SMA', description: 'X', isVirtual: true),
        ],
      );

      final restored = WisaSnapshot.fromJson(full.toJson());
      expect(restored.fetchedAt, full.fetchedAt);
      expect(restored.students, full.students);
      expect(restored.staff, full.staff);
      expect(restored.classGroups, full.classGroups);
      expect(restored.schools, full.schools);
    });
  });
}

WisaStudent _anyStudent() => WisaStudent(
      classGroup: '1A',
      classSubGroup: '00',
      name: 'Doe',
      firstName: 'Jan',
      preferredName: '',
      birthDate: DateTime(2008, 9, 1),
      wisaId: const core.WisaId('150001'),
      stemId: '20000001',
      gender: core.Gender.male,
      nationalId: '',
      birthPlace: '',
      nationality: '',
      address: const core.Address(
        street: '',
        houseNumber: '',
        postalCode: '',
        city: '',
        country: 'BE',
      ),
      classChange: DateTime(2024, 9, 1),
      schoolId: 1,
    );
