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
      const row = '1A,00,Doe,Anna,,1/9/2008,150002,20000002,V,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.gender, core.Gender.female);
    });

    test('empty houseNumberAdd becomes null', () {
      const row = '1A,00,Doe,Jan,,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
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
      const row = '1A,00,Doe,Jan,,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
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
      const row = '1A,00,Doe,Jan,,not-a-date,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      expect(
        () => parseStudentRow(row, schoolId: 1),
        throwsA(isA<CsvRowParseException>()),
      );
    });

    test('handles an unquoted comma in ROEPNAAM without shifting (issue #148)',
        () {
      // WISA emits ROEPNAAM unquoted, so a call name like "Michelle, Servais"
      // splits the row into 19 fields. Anchoring on the GEBOORTEDATUM date
      // keeps every downstream column aligned; the naive fixed-index parser
      // read " Servais" as the date and threw.
      const row =
          'K1,00,Braes,Michelle,Michelle, Servais,19/07/2022,35338,2400013,V,'
          '22071917883,TIENEN,Belgische,Ramselsesteenweg,178,,2230,HERSELT,'
          '1/09/2025';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.name, 'Braes');
      expect(s.firstName, 'Michelle');
      expect(s.preferredName, 'Michelle, Servais');
      expect(s.birthDate, DateTime(2022, 7, 19));
      expect(s.wisaId, const core.WisaId('35338'));
      expect(s.stemId, '2400013');
      expect(s.gender, core.Gender.female);
      expect(s.nationalId, '22071917883');
      expect(s.birthPlace, 'TIENEN');
      expect(s.nationality, 'Belgische');
      expect(s.address.street, 'Ramselsesteenweg');
      expect(s.address.houseNumber, '178');
      expect(s.address.houseNumberAdd, isNull);
      expect(s.address.postalCode, '2230');
      expect(s.address.city, 'HERSELT');
      expect(s.classChange, DateTime(2025, 9, 1));
    });

    test('absorbs multiple commas in the name block into preferredName', () {
      const row = '1A,00,Doe,Jan,a, b, c,1/9/2008,150001,20000001,M,,Genk,'
          'Belgisch,Kerkstraat,5,,3000,Leuven,1/9/2024';
      final s = parseStudentRow(row, schoolId: 25);
      expect(s.name, 'Doe');
      expect(s.firstName, 'Jan');
      expect(s.preferredName, 'a, b, c');
      expect(s.birthDate, DateTime(2008, 9, 1));
      expect(s.address.city, 'Leuven');
      expect(s.classChange, DateTime(2024, 9, 1));
    });

    test('throws a precise error on a comma in the address block', () {
      // Not the reported failure, but the count guard must reject it with a
      // clear message rather than silently corrupt the address.
      const row = '1A,00,Doe,Jan,Janneke,1/9/2008,150001,20000001,M,,Genk,'
          'Belgisch,Kerk,straat,5,,3000,Leuven,1/9/2024';
      expect(
        () => parseStudentRow(row, schoolId: 25),
        throwsA(
          isA<CsvRowParseException>().having(
            (e) => e.message,
            'message',
            contains('GEBOORTEDATUM onward'),
          ),
        ),
      );
    });
  });

  group('parseStaffRow', () {
    test('parses a typical row', () {
      final s = parseStaffRow('ABCDE,12345,VanDerSanden,Yvan', schoolId: 3);
      expect(s.code, const core.WisaStaffCode('ABCDE'));
      expect(s.wisaId, const core.WisaId('12345'));
      expect(s.lastName, 'VanDerSanden');
      expect(s.firstName, 'Yvan');
    });

    test('stamps the school the row was pulled for (#340)', () {
      // `SmaSyncPer` has no institution column, so the only source of the
      // school is the IS_ID the caller queried with.
      final s = parseStaffRow('ABCDE,12345,VanDerSanden,Yvan', schoolId: 42);
      expect(s.schoolIds, {42});
    });

    test('empty WISAID yields wisaId == null (per OQ-1 resolution)', () {
      final s = parseStaffRow('ABCDE,,VanDerSanden,Yvan', schoolId: 3);
      expect(s.wisaId, isNull);
    });

    test('throws CsvRowParseException on too few columns', () {
      expect(
        () => parseStaffRow('only,two', schoolId: 3),
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

    test('rejoins an unquoted comma-bearing description (issue #29)', () {
      // WISA does not quote OMSCHRIJVING, so the embedded comma splits the
      // row into six fields. The parser must rejoin the description and
      // keep adminCode/schoolCode anchored to the trailing columns —
      // otherwise the institute number is silently dropped.
      final g = parseClassGroupRow(
        '5OOS,00,5 Onthaal, organisatie en sales,043117,125252',
        schoolId: 25,
      );
      expect(g.name, '5OOS');
      expect(g.groupName, '00');
      expect(g.description, '5 Onthaal, organisatie en sales');
      expect(g.adminCode, '043117');
      expect(g.schoolCode, '125252');
    });

    test('rejoins a description containing multiple commas', () {
      final g = parseClassGroupRow('7X,00,a, b, c,111,222', schoolId: 25);
      expect(g.description, 'a, b, c');
      expect(g.adminCode, '111');
      expect(g.schoolCode, '222');
    });

    test('still parses a quoted comma-bearing description', () {
      // If WISA ever quotes the field, the splitter yields five fields and
      // the result must be identical to the unquoted path.
      final g = parseClassGroupRow(
        '5OOS,00,"5 Onthaal, organisatie en sales",043117,125252',
        schoolId: 25,
      );
      expect(g.description, '5 Onthaal, organisatie en sales');
      expect(g.adminCode, '043117');
      expect(g.schoolCode, '125252');
    });
  });

  group('parseSchoolRow', () {
    test('untangles WISA\'s inverted NAME / DESCRIPTION columns (#208)', () {
      // CSV columns are ID,NAME,DESCRIPTION, but WISA fills them the other way
      // round: NAME carries the long name, DESCRIPTION the short code. This is
      // the exact shape of row 11 of the redacted live fixture
      // (test/fixtures/sma_get_inst.csv).
      final s = parseSchoolRow('25,Instituut Sancta Maria-A,ISMAA');
      expect(s.id, 25);
      expect(s.name, 'Instituut Sancta Maria-A');
      expect(s.code, 'ISMAA');
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
