import 'package:test/test.dart';
import 'package:wisa_api/src/csv/date_format.dart';

void main() {
  group('parseBelgianDate', () {
    test('parses single-digit day and month', () {
      expect(parseBelgianDate('1/9/2024'), DateTime(2024, 9, 1));
    });

    test('parses two-digit day and month', () {
      expect(parseBelgianDate('31/12/2024'), DateTime(2024, 12, 31));
    });

    test('trims surrounding whitespace', () {
      expect(parseBelgianDate('  5/3/2020  '), DateTime(2020, 3, 5));
    });

    test('rejects two-digit year', () {
      expect(() => parseBelgianDate('1/1/24'), throwsFormatException);
    });

    test('rejects non-numeric components', () {
      expect(() => parseBelgianDate('a/b/yyyy'), throwsFormatException);
    });

    test('rejects out-of-range month', () {
      expect(() => parseBelgianDate('1/13/2024'), throwsFormatException);
    });

    test('rejects empty string', () {
      expect(() => parseBelgianDate(''), throwsFormatException);
    });
  });

  group('tryParseBelgianDate', () {
    test('returns the date for a well-formed value', () {
      expect(tryParseBelgianDate('19/07/2022'), DateTime(2022, 7, 19));
    });

    test('returns null instead of throwing on non-dates', () {
      expect(tryParseBelgianDate(' Servais'), isNull);
      expect(tryParseBelgianDate('Kerkstraat'), isNull);
      expect(tryParseBelgianDate('2400013'), isNull);
      expect(tryParseBelgianDate('1/1/24'), isNull);
      expect(tryParseBelgianDate(''), isNull);
    });
  });

  group('formatWerkdatum', () {
    test('zero-pads single-digit day and month', () {
      expect(formatWerkdatum(DateTime(2024, 9, 1)), '01/09/2024');
    });

    test('does not zero-pad two-digit day and month', () {
      expect(formatWerkdatum(DateTime(2024, 12, 31)), '31/12/2024');
    });
  });
}
