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
      const a = WisaSchool(id: 1, name: 'Sint-Maria', code: 'SMA');
      const b = WisaSchool(id: 1, name: 'Sint-Maria', code: 'SMA');
      const c = WisaSchool(
        id: 1,
        name: 'Sint-Maria',
        code: 'SMA',
        isVirtual: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith flips isVirtual', () {
      const a = WisaSchool(id: 1, name: 'Sint-Maria', code: 'SMA');
      expect(a.copyWith(isVirtual: true).isVirtual, isTrue);
      expect(a.copyWith().isVirtual, isFalse);
    });

    test('an isOurs key from a snapshot written before #286 is ignored', () {
      // The flag is gone: ownership is the operator's WISA-scholen list in
      // Settings. A cold snapshot that still carries the key must load, and read
      // back equal to the same school without it, rather than throwing.
      const school = WisaSchool(id: 1, name: 'Sint-Maria', code: 'SMA');
      expect(school.toJson().containsKey('isOurs'), isFalse);
      expect(
        WisaSchool.fromJson(const {
          'id': 1,
          'name': 'Sint-Maria',
          'code': 'SMA',
          'isVirtual': false,
          'isOurs': true,
        }),
        school,
      );
    });

    test('a pre-#208 snapshot document reads back with its halves unswapped',
        () {
      // Documents written before #208 carry the long name under `description`
      // and the short code under `name`. The absent `code` key is the marker.
      const legacy = <String, dynamic>{
        'id': 25,
        'name': 'ISMAA',
        'description': 'Instituut Sancta Maria-A',
        'isVirtual': true,
      };
      final migrated = WisaSchool.fromJson(legacy);
      expect(migrated.name, 'Instituut Sancta Maria-A');
      expect(migrated.code, 'ISMAA');
      expect(migrated.isVirtual, isTrue);
    });

    test('toString includes id, name, code, and virtual flag', () {
      const a = WisaSchool(id: 1, name: 'Sint-Maria', code: 'SMA');
      final s = a.toString();
      expect(s, contains('id: 1'));
      expect(s, contains('name: Sint-Maria'));
      expect(s, contains('code: SMA'));
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
