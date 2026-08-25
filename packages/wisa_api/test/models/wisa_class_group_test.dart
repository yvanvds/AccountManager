import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('WisaClassGroup', () {
    test('fullName omits groupName when "00"', () {
      const g = WisaClassGroup(
        name: '1A',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(g.fullName, '1A');
    });

    test('fullName omits a blank groupName too, separator and all (#362)', () {
      // A blank `KLASGROEP` names no group, exactly like the `00` shell. The
      // connector stopped dropping such a row when the sub-group split moved
      // off ADMINGROEP, so this is what keeps it out of the class name.
      const g = WisaClassGroup(
        name: '1A',
        groupName: '  ',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(g.fullName, '1A');
    });

    test('fullName trims the sub-group it appends (#362)', () {
      const g = WisaClassGroup(
        name: '2G',
        groupName: ' LAT ',
        description: '',
        adminCode: '040092',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(g.fullName, '2G LAT');
    });

    test('year returns first digit', () {
      const g = WisaClassGroup(
        name: '5C',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(g.year, 5);
    });

    test('year returns -1 for empty name', () {
      const g = WisaClassGroup(
        name: '',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(g.year, -1);
    });

    test('copyWith replaces schoolCode only', () {
      const g = WisaClassGroup(
        name: '1A',
        groupName: '00',
        description: 'Eerste',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      final h = g.copyWith(schoolCode: '999');
      expect(h.schoolCode, '999');
      expect(h.name, g.name);
      expect(h.description, g.description);
      expect(h.adminCode, g.adminCode);
    });

    test('equality based on all fields', () {
      const a = WisaClassGroup(
        name: '1A',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      const b = WisaClassGroup(
        name: '1A',
        groupName: '00',
        description: '',
        adminCode: 'ASO',
        schoolCode: '111',
        schoolId: 1,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
