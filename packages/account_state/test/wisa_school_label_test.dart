import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// The `SMAGetInst` column swap in fixture form: the short code arrives on
/// [WisaSchool.description] and the long name on [WisaSchool.name].
WisaSchool _school(int id, {String code = '', String name = ''}) =>
    WisaSchool(id: id, name: name, description: code);

void main() {
  group('wisaSchoolLabel', () {
    test('pairs the long name with the short code', () {
      expect(
        wisaSchoolLabel(
          schoolId: 25,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
        ),
        'Instituut Sancta Maria-A (ISMAA)',
      );
    });

    test('degrades to whichever half is known', () {
      expect(
        wisaSchoolLabel(schoolId: 25, name: 'Instituut Sancta Maria-A'),
        'Instituut Sancta Maria-A',
      );
      expect(wisaSchoolLabel(schoolId: 25, code: 'ISMAA'), 'ISMAA');
    });

    test('falls back to the id only when neither half is known', () {
      expect(wisaSchoolLabel(schoolId: 25), 'School 25');
      expect(wisaSchoolLabel(schoolId: 25, code: '  ', name: ' '), 'School 25');
    });
  });

  group('wisaSchoolCodeLabel', () {
    test('leads with the code, then the name, then the id', () {
      expect(
        wisaSchoolCodeLabel(
          schoolId: 25,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
        ),
        'ISMAA',
      );
      expect(
        wisaSchoolCodeLabel(schoolId: 25, name: 'Instituut Sancta Maria-A'),
        'Instituut Sancta Maria-A',
      );
      expect(wisaSchoolCodeLabel(schoolId: 25), 'School 25');
    });
  });

  group('WisaSchoolProfile labels', () {
    test('read the same pair the Settings grid renders', () {
      const profile = WisaSchoolProfile(
        schoolId: 25,
        code: 'ISMAA',
        name: 'Instituut Sancta Maria-A',
      );
      expect(profile.label, 'Instituut Sancta Maria-A (ISMAA)');
      expect(profile.codeLabel, 'ISMAA');
    });

    test('a profile stored before the code/name were persisted keeps the id',
        () {
      const profile = WisaSchoolProfile(schoolId: 25);
      expect(profile.label, 'School 25');
      expect(profile.codeLabel, 'School 25');
    });
  });

  group('wisaSchoolLabels', () {
    test('labels every school from the persisted profiles alone (#204)', () {
      // The cold-snapshot case: the session has pulled no schools, so the
      // operator's curated Settings list is the only identity available — and
      // it must still name the school rather than degrade to `School 25`.
      expect(
        wisaSchoolLabels(profiles: const [
          WisaSchoolProfile(
            schoolId: 25,
            code: 'ISMAA',
            name: 'Instituut Sancta Maria-A',
          ),
          WisaSchoolProfile(
              schoolId: 30, code: 'ISMAB', name: 'Sancta Maria-B'),
        ]),
        {
          25: 'Instituut Sancta Maria-A (ISMAA)',
          30: 'Sancta Maria-B (ISMAB)',
        },
      );
    });

    test('takes the code off description and the name off name', () {
      expect(
        wisaSchoolLabels(schools: [
          _school(25, code: 'ISMAA', name: 'Instituut Sancta Maria-A'),
        ]),
        {25: 'Instituut Sancta Maria-A (ISMAA)'},
      );
    });

    test('a live pull refreshes a renamed school over the stored profile', () {
      expect(
        wisaSchoolLabels(
          profiles: const [
            WisaSchoolProfile(schoolId: 25, code: 'ISMAA', name: 'Oude naam'),
          ],
          schools: [_school(25, code: 'ISMAA', name: 'Nieuwe naam')],
        ),
        {25: 'Nieuwe naam (ISMAA)'},
      );
    });

    test('a half the pull does not carry keeps the stored profile value', () {
      // A snapshot school with an empty code must not blank out the code the
      // operator already curated — the same per-half merge the Settings grid
      // applies to a fetch.
      expect(
        wisaSchoolLabels(
          profiles: const [
            WisaSchoolProfile(
              schoolId: 25,
              code: 'ISMAA',
              name: 'Instituut Sancta Maria-A',
            ),
          ],
          schools: [_school(25, name: 'Instituut Sancta Maria-A')],
        ),
        {25: 'Instituut Sancta Maria-A (ISMAA)'},
      );
    });

    test('unions the two sources and skips a school neither half names', () {
      expect(
        wisaSchoolLabels(
          profiles: const [
            WisaSchoolProfile(schoolId: 25, code: 'ISMAA'),
            // Nothing to say about school 99: no map entry, so the materializer
            // falls back to `School 99`.
            WisaSchoolProfile(schoolId: 99),
          ],
          schools: [_school(30, name: 'Sancta Maria-B')],
        ),
        {25: 'ISMAA', 30: 'Sancta Maria-B'},
      );
    });
  });
}
