import 'package:test/test.dart';
import 'package:wisa_api/src/csv/csv_parser.dart';

void main() {
  group('splitCsvLine', () {
    test('splits unquoted comma-separated fields', () {
      expect(splitCsvLine('a,b,c'), ['a', 'b', 'c']);
    });

    test('handles trailing empty field', () {
      expect(splitCsvLine('a,b,'), ['a', 'b', '']);
    });

    test('handles leading empty field', () {
      expect(splitCsvLine(',b,c'), ['', 'b', 'c']);
    });

    test('handles single-field line', () {
      expect(splitCsvLine('only'), ['only']);
    });

    test('handles empty input as single empty field', () {
      expect(splitCsvLine(''), ['']);
    });

    test('preserves whitespace inside fields (caller trims)', () {
      expect(splitCsvLine('a , b , c'), ['a ', ' b ', ' c']);
    });

    test('treats commas inside double-quoted fields as literal', () {
      expect(
        splitCsvLine('"hello, world",next'),
        ['hello, world', 'next'],
      );
    });

    test('escapes embedded double-quote as ""', () {
      expect(
        splitCsvLine('"she said ""hi""",next'),
        ['she said "hi"', 'next'],
      );
    });

    test('only treats quote as opening when it is at field start', () {
      expect(
        splitCsvLine('a"b",c'),
        ['a"b"', 'c'],
      );
    });

    test('handles 18-column WISA student row', () {
      const row =
          '1A,00,Doe,Jan,,1/9/2008,150001,20000001,M,,Genk,Belgisch,'
          'Kerkstraat,5,,3000,Leuven,1/9/2024';
      final f = splitCsvLine(row);
      expect(f.length, 18);
      expect(f[0], '1A');
      expect(f[6], '150001');
      expect(f[17], '1/9/2024');
    });
  });

  group('splitCsvWithHeader', () {
    test('validates header and returns rows', () {
      const csv = 'a,b\n1,2\n3,4\n';
      final r = splitCsvWithHeader(csv, 'a,b');
      expect(r.header, 'a,b');
      expect(r.rows, ['1,2', '3,4']);
    });

    test('handles CRLF line endings', () {
      const csv = 'a,b\r\n1,2\r\n';
      final r = splitCsvWithHeader(csv, 'a,b');
      expect(r.rows, ['1,2']);
    });

    test('throws CsvHeaderMismatch on header drift', () {
      expect(
        () => splitCsvWithHeader('x,y\n1,2', 'a,b'),
        throwsA(isA<CsvHeaderMismatch>()),
      );
    });

    test('throws CsvHeaderMismatch on empty input', () {
      expect(
        () => splitCsvWithHeader('', 'a,b'),
        throwsA(isA<CsvHeaderMismatch>()),
      );
    });
  });
}
