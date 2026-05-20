import 'package:account_core/account_core.dart' as core;
import 'package:test/test.dart';
import 'package:wisa_api/src/csv/csv_parser.dart';
import 'package:wisa_api/src/csv/row_parsers.dart';

void main() {
  group('parseStudentRow', () {
    test('parses a typical row', () {
      const row =
          '1A,00,Doe,Jan,Janneke,1/9/2008,150001,20000001,M,99090199999,'
          'Genk,Belgisch,Kerkstraat,5,a,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.classGroup, '1A');
      expect(s.classSubGroup, '00');
      expect(s.name, 'Doe');
      expect(s.firstName, 'Jan');
      expect(s.preferredName, 'Janneke');
      expect(s.birthDate, DateTime(2008, 9, 1));
      expect(s.wisaId, const core.WisaId('150001'));
      expect(s.stemId, '20000001');
      expect(s.gender, core.Gender.male);
      expect(s.nationalId, '99090199999');
      expect(s.birthPlace, 'Genk');
      expect(s.nationality, 'Belgisch');
      expect(s.address.street, 'Kerkstraat');
      expect(s.address.houseNumber, '5');
      expect(s.address.houseNumberAdd, 'a');
      expect(s.address.postalCode, '3000');
      expect(s.address.city, 'Leuven');
      expect(s.classChange, DateTime(2024, 9, 1));
      expect(s.schoolId, 25);
    });

    test('gender defaults to female for any value other than M', () {
      const row =
          '1A,00,Doe,Anna,,1/9/2008,150002,20000002,V,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.gender, core.Gender.female);
    });

    test('empty houseNumberAdd becomes null', () {
      const row =
          '1A,00,Doe,Jan,,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.address.houseNumberAdd, isNull);
    });

    test('fullName prefers preferredName over firstName', () {
      const row =
          '1A,00,Doe,Jan,Janneke,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.fullName, 'Janneke Doe');
    });

    test('fullName falls back to firstName when preferredName empty', () {
      const row =
          '1A,00,Doe,Jan,,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.fullName, 'Jan Doe');
    });

    test('throws CsvRowParseException on too few columns', () {
      expect(
        () => parseStudentRow('only,three,fields', schoolId: 1),
        throwsA(isA<CsvRowParseException>()),
      );
    });

    test('throws CsvRowParseException on malformed date', () {
      const row =
          '1A,00,Doe,Jan,,not-a-date,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      expect(
        () => parseStudentRow(row, schoolId: 1),
        throwsA(isA<CsvRowParseException>()),
      );
    });
  });

  group('parseStaffRow', () {
    test('parses a typical row', () {
      final s = parseStaffRow('ABCDE,12345,VanDerSanden,Yvan');
      expect(s.code, const core.WisaStaffCode('ABCDE'));
      expect(s.wisaId, const core.WisaId('12345'));
      expect(s.lastName, 'VanDerSanden');
      expect(s.firstName, 'Yvan');
    });

    test('empty WISAID yields wisaId == null (per OQ-1 resolution)', () {
      final s = parseStaffRow('ABCDE,,VanDerSanden,Yvan');
      expect(s.wisaId, isNull);
    });

    test('throws CsvRowParseException on too few columns', () {
      expect(
        () => parseStaffRow('only,two'),
        throwsA(isA<CsvRowParseException>()),
      );
    });
  });

  group('parseClassGroupRow', () {
    test('parses a typical row', () {
      final g =
          parseClassGroupRow('1A,00,Eerste jaar,ASO,123456', schoolId: 25);
      expect(g.name, '1A');
      expect(g.groupName, '00');
      expect(g.description, 'Eerste jaar');
      expect(g.adminCode, 'ASO');
      expect(g.schoolCode, '123456');
      expect(g.schoolId, 25);
    });

    test('fullName omits groupName when "00"', () {
      final g = parseClassGroupRow('1A,00,,ASO,123456', schoolId: 25);
      expect(g.fullName, '1A');
    });

    test('fullName appends groupName when not "00"', () {
      final g = parseClassGroupRow('1A,Alpha,,ASO,123456', schoolId: 25);
      expect(g.fullName, '1A Alpha');
    });

    test('year returns first digit of name', () {
      final g = parseClassGroupRow('3B,00,,ASO,123456', schoolId: 25);
      expect(g.year, 3);
    });

    test('year returns -1 for non-digit start', () {
      final g = parseClassGroupRow('Foo,00,,ASO,123456', schoolId: 25);
      expect(g.year, -1);
    });
  });

  group('parseSchoolRow', () {
    test('parses a typical row, swapping NAME and DESCRIPTION', () {
      // CSV columns: ID,NAME,DESCRIPTION
      // Legacy maps column 1 -> description, column 2 -> name.
      final s = parseSchoolRow('25,SMA,Sint-Maria-Aalst');
      expect(s.id, 25);
      expect(s.description, 'SMA');
      expect(s.name, 'Sint-Maria-Aalst');
      expect(s.isVirtual, isFalse);
    });

    test('throws CsvRowParseException on non-integer ID', () {
      expect(
        () => parseSchoolRow('notanint,SMA,Sint-Maria-Aalst'),
        throwsA(isA<CsvRowParseException>()),
      );
    });
  });
}
