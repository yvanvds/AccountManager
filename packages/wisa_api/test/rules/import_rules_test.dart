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
    test('flips isVirtual on matching school name', () {
      const schools = [
        WisaSchool(id: 1, name: 'SMA', description: 'Sint Maria'),
        WisaSchool(id: 2, name: 'SDK', description: 'Sint Dimphna'),
      ];
      final out =
          applyRulesToSchools(schools, const [MarkAsVirtual('SMA')]);
      expect(out[0].isVirtual, isTrue);
      expect(out[1].isVirtual, isFalse);
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
