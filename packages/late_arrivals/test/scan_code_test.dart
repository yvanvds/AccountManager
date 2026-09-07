import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeScanCode', () {
    test('passes a bare code through unchanged', () {
      expect(normalizeScanCode('123456'), '123456');
    });

    test("strips the scanner's Enter terminator", () {
      expect(normalizeScanCode('123456\r\n'), '123456');
      expect(normalizeScanCode('123456\n'), '123456');
      expect(normalizeScanCode('123456\r'), '123456');
    });

    test('strips surrounding whitespace and tabs', () {
      expect(normalizeScanCode('  123456\t'), '123456');
    });

    test('strips interior whitespace a manual re-type leaves behind', () {
      expect(normalizeScanCode('12 34 56'), '123456');
    });

    test('strips the exotic spaces a copy-paste carries', () {
      // No-break space, narrow no-break space, and a BOM.
      expect(normalizeScanCode('\u00a0123\u202f456\ufeff'), '123456');
    });

    test('strips the framing control bytes some wedges emit', () {
      // STX ... ETX around the payload.
      expect(normalizeScanCode('\u0002123456\u0003'), '123456');
    });

    test('folds case, so a manual re-type reaches the same index entry', () {
      expect(normalizeScanCode('AB12'), 'ab12');
    });

    test('keeps leading zeros - they are part of the Internnummer', () {
      expect(normalizeScanCode('000123'), '000123');
    });

    test('yields the empty string for a burst of pure noise', () {
      expect(normalizeScanCode('\r\n'), isEmpty);
      expect(normalizeScanCode('   '), isEmpty);
      expect(normalizeScanCode(''), isEmpty);
    });
  });
}
