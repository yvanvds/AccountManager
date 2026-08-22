import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

void main() {
  group('INV-22 student signal — exact companyName (#279)', () {
    test('the school\'s own prefix, and nothing else, marks a student', () {
      expect(studentBelongsToSchool('GBS', 'GBS'), isTrue);
      expect(studentBelongsToSchool('SSM', 'GBS'), isFalse);
    });

    test('deliberately not a substring test', () {
      // `companyName` is a field we write ourselves and write nothing else
      // into, so equality is the whole rule. Widening it here would adopt a
      // sibling school's students on the strength of a shared letter run.
      expect(studentBelongsToSchool('GBS,SSM', 'GBS'), isFalse);
      expect(studentBelongsToSchool('GBSX', 'GBS'), isFalse);
      expect(studentBelongsToSchool('XGBS', 'GBS'), isFalse);
    });

    test('trims and case-folds both sides (INV-12)', () {
      expect(studentBelongsToSchool('  gbs  ', 'GBS'), isTrue);
      expect(studentBelongsToSchool('GBS', '  gBs '), isTrue);
    });

    test('a missing or blank value on either side matches nothing', () {
      expect(studentBelongsToSchool(null, 'GBS'), isFalse);
      expect(studentBelongsToSchool('   ', 'GBS'), isFalse);
      expect(studentBelongsToSchool('GBS', null), isFalse);
      expect(studentBelongsToSchool('   ', '   '), isFalse);
    });
  });

  group('INV-22 staff signal — department contains (#279)', () {
    test('our prefix anywhere in the comma list marks a staff member', () {
      // The field is not ours to write (#237): other software maintains it as
      // the list of schools the teacher is active at, and us sitting second is
      // the ordinary state, not an edge case.
      expect(staffBelongsToSchool('GBS', 'GBS'), isTrue);
      expect(staffBelongsToSchool('GBS,SSM', 'GBS'), isTrue);
      expect(staffBelongsToSchool('SSM,GBS', 'GBS'), isTrue);
      expect(staffBelongsToSchool('SSM,GBS,ZAV', 'GBS'), isTrue);
    });

    test('a list that never names us marks nobody', () {
      expect(staffBelongsToSchool('SSM,ZAV', 'GBS'), isFalse);
      expect(staffBelongsToSchool(null, 'GBS'), isFalse);
      expect(staffBelongsToSchool('   ', 'GBS'), isFalse);
    });

    test('trims and case-folds both sides (INV-12)', () {
      expect(staffBelongsToSchool(' ssm,gbs ', 'GBS'), isTrue);
      expect(staffBelongsToSchool('SSM,GBS', ' gbs '), isTrue);
    });

    test('a blank prefix matches nobody, not everybody', () {
      // Every string contains the empty string, so the naive test would claim
      // the whole tenant for a school whose prefix is not configured yet.
      expect(staffBelongsToSchool('SSM,GBS', null), isFalse);
      expect(staffBelongsToSchool('SSM,GBS', '   '), isFalse);
      expect(staffBelongsToSchool('', ''), isFalse);
    });
  });

  group('belongsToSchool — the union a bulk read asks (#279)', () {
    test('is true for a student row and for a staff row', () {
      expect(
        belongsToSchool(companyName: 'GBS', schoolPrefix: 'GBS'),
        isTrue,
      );
      expect(
        belongsToSchool(department: 'SSM,GBS', schoolPrefix: 'GBS'),
        isTrue,
      );
    });

    test('is false for another school entirely', () {
      expect(
        belongsToSchool(
          companyName: 'SSM',
          department: 'SSM,ZAV',
          schoolPrefix: 'GBS',
        ),
        isFalse,
      );
      expect(belongsToSchool(schoolPrefix: 'GBS'), isFalse);
    });

    test('a blank prefix claims nobody', () {
      expect(
        belongsToSchool(
          companyName: 'GBS',
          department: 'SSM,GBS',
          schoolPrefix: '  ',
        ),
        isFalse,
      );
    });

    test(
        'is exactly the union of the two halves — never narrower than either, '
        'for every combination of the values that occur', () {
      // This is the property the connector reads depend on: the read applies
      // the union, the linker applies one specific half, so the read can never
      // drop a row the linker would have kept.
      const values = <String?>[
        null,
        '',
        '  ',
        'GBS',
        'gbs',
        ' GBS ',
        'SSM',
        'GBS,SSM',
        'SSM,GBS',
        'SSM,GBS,ZAV',
        'GBSX',
      ];
      const prefixes = <String?>[null, '', 'GBS', ' gbs '];

      for (final prefix in prefixes) {
        for (final companyName in values) {
          for (final department in values) {
            final student = studentBelongsToSchool(companyName, prefix);
            final staff = staffBelongsToSchool(department, prefix);
            final union = belongsToSchool(
              companyName: companyName,
              department: department,
              schoolPrefix: prefix,
            );
            expect(
              union,
              student || staff,
              reason: 'company=$companyName dept=$department prefix=$prefix',
            );
            if (student || staff) {
              expect(
                union,
                isTrue,
                reason: 'the union must never be narrower than a half: '
                    'company=$companyName dept=$department prefix=$prefix',
              );
            }
          }
        }
      }
    });
  });
}
