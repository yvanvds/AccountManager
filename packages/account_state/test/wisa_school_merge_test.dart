import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A snapshot school, with each half on the field that claims it (#208).
WisaSchool _school(int id, {String code = '', String name = ''}) =>
    WisaSchool(id: id, name: name, code: code);

void main() {
  group('mergeWisaSchoolProfiles', () {
    test('fills both halves into a profile stored with neither (#207)', () {
      // The reported document: three entries carrying only `schoolId` + `ours`,
      // which the Settings grid rendered as "School 25" forever.
      final repaired = mergeWisaSchoolProfiles(
        profiles: const [WisaSchoolProfile(schoolId: 25, ours: true)],
        schools: [
          _school(25, code: 'ISMAA', name: 'Instituut Sancta Maria-A'),
        ],
      );

      expect(repaired.single.name, 'Instituut Sancta Maria-A');
      expect(repaired.single.code, 'ISMAA');
      expect(repaired.single.nameLabel, 'Instituut Sancta Maria-A');
      expect(repaired.single.label, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('never rewrites the operator-owned fields', () {
      // `ours`, `virtual` and `prefix` are Settings decisions; a pull that
      // repairs the two derived halves must leave every one of them alone.
      final repaired = mergeWisaSchoolProfiles(
        profiles: const [
          WisaSchoolProfile(
            schoolId: 7,
            ours: true,
            virtual: true,
            prefix: 'SP',
          ),
        ],
        schools: [_school(7, code: 'SP7', name: 'Sint-Pieter')],
      );

      expect(repaired.single.ours, isTrue);
      expect(repaired.single.virtual, isTrue);
      expect(repaired.single.prefix, 'SP');
    });

    test('a half the pull does not carry leaves the stored one standing', () {
      final repaired = mergeWisaSchoolProfiles(
        profiles: const [
          WisaSchoolProfile(schoolId: 7, code: 'SP', name: 'Sint-Pieter'),
        ],
        schools: [_school(7, name: 'Sint-Pieter (nieuwe naam)')],
      );

      expect(repaired.single.code, 'SP', reason: 'not blanked by the pull');
      expect(repaired.single.name, 'Sint-Pieter (nieuwe naam)',
          reason: 'a WISA-side rename does reach the stored profile');
    });

    test('adds and removes nothing by default, and keeps the order', () {
      // The repair a sync runs: the operator curated this list, so the grid may
      // not grow, shrink or reorder behind their back.
      final repaired = mergeWisaSchoolProfiles(
        profiles: const [
          WisaSchoolProfile(schoolId: 31, ours: true),
          WisaSchoolProfile(schoolId: 25, ours: true),
        ],
        schools: [
          _school(25, code: 'ISMAA', name: 'Instituut Sancta Maria-A'),
          _school(27, code: 'ISMAB', name: 'Instituut Sancta Maria-B'),
        ],
      );

      expect(repaired.map((p) => p.schoolId), [31, 25]);
      expect(repaired.first.name, isEmpty,
          reason: 'school 31 is in no pull, so nothing to fill in');
      expect(repaired.last.name, 'Instituut Sancta Maria-A');
    });

    test('addUnknown appends the schools the list does not have yet', () {
      // What "Scholen ophalen" does: the refresh may introduce a school the
      // operator has never seen, unmanaged and non-virtual until they say so.
      final merged = mergeWisaSchoolProfiles(
        profiles: const [WisaSchoolProfile(schoolId: 25, ours: true)],
        schools: [
          _school(25, code: 'ISMAA', name: 'Instituut Sancta Maria-A'),
          _school(27, code: 'ISMAB', name: 'Instituut Sancta Maria-B'),
        ],
        addUnknown: true,
      );

      expect(merged.map((p) => p.schoolId), [25, 27]);
      expect(merged.last.name, 'Instituut Sancta Maria-B');
      expect(merged.last.code, 'ISMAB');
      expect(merged.last.ours, isFalse);
      expect(merged.last.virtual, isFalse);
      expect(merged.first.ours, isTrue, reason: 'the managed mark survives');
    });

    test('a pulled half that is only whitespace is not stored', () {
      final repaired = mergeWisaSchoolProfiles(
        profiles: const [WisaSchoolProfile(schoolId: 7, name: 'Sint-Pieter')],
        schools: [_school(7, code: '   ')],
      );

      expect(repaired.single.code, isEmpty);
      expect(repaired.single.name, 'Sint-Pieter');
    });

    test('an empty pull changes nothing', () {
      const stored = [WisaSchoolProfile(schoolId: 25, ours: true)];
      expect(
        mergeWisaSchoolProfiles(profiles: stored, schools: const []),
        stored,
      );
    });
  });
}
