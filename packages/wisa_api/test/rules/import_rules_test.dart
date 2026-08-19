import 'package:account_core/account_core.dart' as core;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

WisaClassGroup _g(
  String name, {
  String groupName = '00',
  String schoolCode = '111',
  int schoolId = 1,
}) =>
    WisaClassGroup(
      name: name,
      groupName: groupName,
      description: '',
      adminCode: 'ASO',
      schoolCode: schoolCode,
      schoolId: schoolId,
    );

WisaStaff _s(String code) => WisaStaff(
      code: core.WisaStaffCode(code),
      firstName: code,
      lastName: code,
    );

void main() {
  group('DontImportClass', () {
    test('removes matching class group', () {
      final groups = [_g('1A'), _g('1B'), _g('1C')];
      final out = applyRulesToClassGroups(
        groups,
        const [DontImportClass('1B')],
      );
      expect(out.map((g) => g.name), ['1A', '1C']);
    });

    test('non-matching name is a no-op', () {
      final groups = [_g('1A')];
      final out = applyRulesToClassGroups(
        groups,
        const [DontImportClass('9Z')],
      );
      expect(out, groups);
    });
  });

  group('DontImportUserFromWisa', () {
    test('removes matching staff member by code', () {
      final staff = [_s('AAAAA'), _s('BBBBB')];
      final out = applyRulesToStaff(
        staff,
        const [DontImportUserFromWisa('AAAAA')],
      );
      expect(out.map((s) => s.code.value), ['BBBBB']);
    });
  });

  group('ReplaceInstitute', () {
    test('rewrites schoolCode when original matches', () {
      final groups = [_g('1A', schoolCode: '111'), _g('1B', schoolCode: '222')];
      final out = applyRulesToClassGroups(
        groups,
        const [ReplaceInstitute(original: '111', replacement: '999')],
      );
      expect(out[0].schoolCode, '999');
      expect(out[1].schoolCode, '222');
    });

    test('does not touch non-matching schoolCode', () {
      final groups = [_g('1A', schoolCode: '111')];
      final out = applyRulesToClassGroups(
        groups,
        const [ReplaceInstitute(original: '222', replacement: '999')],
      );
      expect(out[0].schoolCode, '111');
    });
  });

  group('MarkAsVirtual', () {
    test('flips isVirtual on the matching short school code', () {
      // The rule keys off the short code, never the long name (#208).
      const schools = [
        WisaSchool(id: 1, name: 'Sint Maria', code: 'SMA'),
        WisaSchool(id: 2, name: 'Sint Dimphna', code: 'SDK'),
      ];
      final out = applyRulesToSchools(schools, const [MarkAsVirtual('SMA')]);
      expect(out[0].isVirtual, isTrue);
      expect(out[1].isVirtual, isFalse);
    });

    test('does not match on the long school name', () {
      const schools = [WisaSchool(id: 1, name: 'Sint Maria', code: 'SMA')];
      final out =
          applyRulesToSchools(schools, const [MarkAsVirtual('Sint Maria')]);
      expect(out.single.isVirtual, isFalse);
    });
  });

  group('MarkAsOurs', () {
    test('flips isOurs on the matching short school code only', () {
      const schools = [
        WisaSchool(id: 1, name: 'Sint Maria', code: 'SMA'),
        WisaSchool(id: 2, name: 'Sint Dimphna', code: 'SDK'),
      ];
      final out = applyRulesToSchools(schools, const [MarkAsOurs('SMA')]);
      expect(out[0].isOurs, isTrue);
      expect(out[1].isOurs, isFalse);
      // No cross-contamination with the virtual marker.
      expect(out[0].isVirtual, isFalse);
    });

    test('does not match on the long school name', () {
      const schools = [WisaSchool(id: 1, name: 'Sint Maria', code: 'SMA')];
      final out =
          applyRulesToSchools(schools, const [MarkAsOurs('Sint Maria')]);
      expect(out.single.isOurs, isFalse);
    });

    test('MarkAsVirtual and MarkAsOurs flag independently on one school', () {
      const schools = [WisaSchool(id: 1, name: 'Sint Maria', code: 'SMA')];
      final out = applyRulesToSchools(
        schools,
        const [MarkAsVirtual('SMA'), MarkAsOurs('SMA')],
      );
      expect(out.single.isVirtual, isTrue);
      expect(out.single.isOurs, isTrue);
    });

    test('is a no-op for class groups and staff', () {
      final groups = [_g('1A')];
      expect(
          applyRulesToClassGroups(groups, const [MarkAsOurs('SMA')]), groups);
      final staff = [_s('AAAAA')];
      expect(applyRulesToStaff(staff, const [MarkAsOurs('SMA')]), staff);
    });
  });

  group('rule interactions', () {
    test('ReplaceInstitute then DontImportClass on same class group', () {
      // 1A gets its institute rewritten, then is filtered out.
      final groups = [_g('1A', schoolCode: '111'), _g('1B', schoolCode: '111')];
      final out = applyRulesToClassGroups(
        groups,
        const [
          ReplaceInstitute(original: '111', replacement: '999'),
          DontImportClass('1A'),
        ],
      );
      expect(out, hasLength(1));
      expect(out.single.name, '1B');
      expect(out.single.schoolCode, '999');
    });

    test('rule order matters: discard before modify still discards', () {
      final groups = [_g('1A', schoolCode: '111')];
      final out = applyRulesToClassGroups(
        groups,
        const [
          DontImportClass('1A'),
          ReplaceInstitute(original: '111', replacement: '999'),
        ],
      );
      expect(out, isEmpty);
    });
  });
}
