import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('formatSmartschoolDate', () {
    test('formats Y-M-D without zero-padding', () {
      expect(formatSmartschoolDate(DateTime(2010, 3, 5)), '2010-3-5');
      expect(formatSmartschoolDate(DateTime(2011, 12, 1)), '2011-12-1');
    });

    test('returns empty string for null', () {
      expect(formatSmartschoolDate(null), '');
    });
  });

  group('parseSmartschoolDate', () {
    test('parses Y-M-D, padded or not', () {
      expect(parseSmartschoolDate('2010-3-5'), DateTime(2010, 3, 5));
      expect(parseSmartschoolDate('2010-03-05'), DateTime(2010, 3, 5));
    });

    test('returns null for malformed input', () {
      expect(parseSmartschoolDate(''), isNull);
      expect(parseSmartschoolDate('2010-03'), isNull);
      expect(parseSmartschoolDate('not-a-date'), isNull);
      expect(parseSmartschoolDate('2010-x-5'), isNull);
    });

    test('round-trips through format', () {
      final d = DateTime(2009, 7, 22);
      expect(parseSmartschoolDate(formatSmartschoolDate(d)), d);
    });
  });
}
