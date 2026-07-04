import 'package:account_core/account_core.dart' as core;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

WisaStudent _student({String wisaId = '150001'}) => WisaStudent(
      classGroup: '1A',
      classSubGroup: '00',
      name: 'Doe',
      firstName: 'Jan',
      preferredName: '',
      birthDate: DateTime(2008, 9, 1),
      wisaId: core.WisaId(wisaId),
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

void main() {
  group('WisaStudent', () {
    test('equality based on all fields', () {
      expect(_student(), _student());
      expect(_student().hashCode, _student().hashCode);
    });

    test('differs by wisaId', () {
      expect(_student(wisaId: '150001'), isNot(_student(wisaId: '150002')));
    });

    test('toString includes name and wisaId', () {
      final s = _student();
      expect(s.toString(), contains('Doe'));
      expect(s.toString(), contains('150001'));
    });

    test('fullName respects preferredName precedence', () {
      final s = WisaStudent(
        classGroup: '1A',
        classSubGroup: '00',
        name: 'Doe',
        firstName: 'Jan',
        preferredName: 'Janneke',
        birthDate: DateTime(2008, 9, 1),
        wisaId: const core.WisaId('150001'),
        stemId: '',
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
      expect(s.fullName, 'Janneke Doe');
    });
  });

  group('WisaStaff', () {
    WisaStaff staff({String code = 'AAAAA', String? wisaId = '90001'}) =>
        WisaStaff(
          code: core.WisaStaffCode(code),
          wisaId: wisaId == null ? null : core.WisaId(wisaId),
          firstName: 'First',
          lastName: 'Last',
        );

    test('equality based on all fields', () {
      expect(staff(), staff());
      expect(staff().hashCode, staff().hashCode);
    });

    test('differs by code', () {
      expect(staff(code: 'AAAAA'), isNot(staff(code: 'BBBBB')));
    });

    test('differs by wisaId-null vs wisaId-set', () {
      expect(staff(wisaId: null), isNot(staff(wisaId: '90001')));
    });

    test('toString includes code and name', () {
      final s = staff();
      expect(s.toString(), contains('AAAAA'));
      expect(s.toString(), contains('First Last'));
    });
  });

  group('WisaSchool', () {
    test('equality based on all fields including isVirtual', () {
      const a = WisaSchool(id: 1, name: 'SMA', description: 'X');
      const b = WisaSchool(id: 1, name: 'SMA', description: 'X');
      const c = WisaSchool(
        id: 1,
        name: 'SMA',
        description: 'X',
        isVirtual: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith flips isVirtual', () {
      const a = WisaSchool(id: 1, name: 'SMA', description: 'X');
      expect(a.copyWith(isVirtual: true).isVirtual, isTrue);
      expect(a.copyWith().isVirtual, isFalse);
    });

    test('isOurs participates in equality and copyWith and round-trips', () {
      const a = WisaSchool(id: 1, name: 'SMA', description: 'X');
      const managed = WisaSchool(
        id: 1,
        name: 'SMA',
        description: 'X',
        isOurs: true,
      );
      expect(a, isNot(managed));
      expect(a.copyWith(isOurs: true).isOurs, isTrue);
      expect(a.copyWith().isOurs, isFalse);
      expect(WisaSchool.fromJson(managed.toJson()), managed);
      // Old snapshots without the key default to not-ours.
      expect(
        WisaSchool.fromJson(const {'id': 1, 'name': 'SMA', 'description': 'X'})
            .isOurs,
        isFalse,
      );
    });

    test('toString includes id, name, and virtual flag', () {
      const a = WisaSchool(id: 1, name: 'SMA', description: 'X');
      final s = a.toString();
      expect(s, contains('id: 1'));
      expect(s, contains('SMA'));
      expect(s, contains('isVirtual'));
    });
  });

  group('WisaClassGroup', () {
    test('toString includes name and schoolId', () {
      const g = WisaClassGroup(
        name: '1A',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 25,
      );
      expect(g.toString(), contains('1A'));
      expect(g.toString(), contains('25'));
    });
  });
}
