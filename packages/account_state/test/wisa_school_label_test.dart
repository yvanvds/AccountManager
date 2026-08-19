import 'dart:convert';
import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A snapshot school, with each half on the field that claims it (#208).
WisaSchool _school(int id, {String code = '', String name = ''}) =>
    WisaSchool(id: id, name: name, code: code);

/// The redacted-from-live `SMAGetInst` fixture, resolved whether `dart test`
/// runs from this package or from the workspace root (CI does the latter).
String _readSchoolFixture() {
  const rel = 'test/fixtures/sma_get_inst.csv';
  final candidates = <String>[
    Uri.base.resolve('../wisa_api/$rel').toFilePath(),
    Uri.base.resolve('packages/wisa_api/$rel').toFilePath(),
    '../wisa_api/$rel',
    'packages/wisa_api/$rel',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw FileSystemException('fixture not found', candidates.join(', '));
}

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

  group('wisaSchoolNameLabel', () {
    test('leads with the long name, then the code, then the id', () {
      expect(
        wisaSchoolNameLabel(
          schoolId: 25,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
        ),
        'Instituut Sancta Maria-A',
      );
      expect(
        wisaSchoolNameLabel(schoolId: 25, code: 'ISMAA'),
        'ISMAA',
      );
      expect(wisaSchoolNameLabel(schoolId: 25), 'School 25');
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
      expect(profile.nameLabel, 'Instituut Sancta Maria-A');
    });

    test('a profile stored before the code/name were persisted keeps the id',
        () {
      const profile = WisaSchoolProfile(schoolId: 25);
      expect(profile.label, 'School 25');
      expect(profile.nameLabel, 'School 25');
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

    test('takes the code off code and the name off name', () {
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

  // The convention pinned by *real* data rather than by hand-built fixtures
  // that can quietly agree with a bug (#208). Every step is production code:
  // the redacted-from-live CSV → `parseSchoolRow` → `wisaSchoolLabels`.
  group('from the redacted SMAGetInst fixture to a rendered label', () {
    final rows = const LineSplitter()
        .convert(_readSchoolFixture())
        .where((l) => l.trim().isNotEmpty)
        .skip(1) // the ID,NAME,DESCRIPTION header
        .toList();
    final schools = [for (final r in rows) parseSchoolRow(r)];

    test('the fixture is the shape this test relies on', () {
      expect(rows, contains('25,Instituut Sancta Maria-A,ISMAA'));
    });

    test('parses the long name onto name and the short code onto code', () {
      final ismaa = schools.firstWhere((s) => s.id == 25);
      expect(ismaa.name, 'Instituut Sancta Maria-A');
      expect(ismaa.code, 'ISMAA');
    });

    test('renders the long name first with the short code in parentheses', () {
      final labels = wisaSchoolLabels(schools: schools);
      expect(labels[25], 'Instituut Sancta Maria-A (ISMAA)');
      expect(labels[27], 'Instituut Sancta Maria-B (ISMAB)');
      // The inverse — what the drill-down read before the fix — must be gone.
      expect(labels[25], isNot('ISMAA (Instituut Sancta Maria-A)'));
    });

    test('a code-only fixture row degrades to the code, not to School <id>',
        () {
      // Row 2 of the fixture is `0,,?`: no long name, only a placeholder code.
      final labels = wisaSchoolLabels(schools: schools);
      expect(labels[0], '?');
    });

    test('the grid leads each fixture school with its long name', () {
      final ismaa = schools.firstWhere((s) => s.id == 25);
      final profile = WisaSchoolProfile(
        schoolId: ismaa.id,
        code: ismaa.code,
        name: ismaa.name,
      );
      expect(profile.nameLabel, 'Instituut Sancta Maria-A');
      expect(profile.label, 'Instituut Sancta Maria-A (ISMAA)');
    });
  });
}
