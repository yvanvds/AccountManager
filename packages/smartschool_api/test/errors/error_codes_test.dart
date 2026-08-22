import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolErrorCodes', () {
    test('fromJson parses a code->message object', () {
      final codes = SmartschoolErrorCodes.fromJson(
        '{"1":"Ongeldige toegangscode","7":"Onbekend"}',
      );
      expect(codes.isLoaded, isTrue);
      expect(codes.translate(1), 'Ongeldige toegangscode');
      expect(codes.translate(7), 'Onbekend');
    });

    test('coerces non-string values to strings', () {
      final codes = SmartschoolErrorCodes.fromJson('{"42":42}');
      expect(codes.translate(42), '42');
    });

    test('unknown code falls back to a generic Dutch message (#266)', () {
      // The fallback is written straight into the operator's Log panel by the
      // connector, so it is Dutch like every other line of a pass.
      final codes = SmartschoolErrorCodes.fromJson('{"1":"x"}');
      expect(codes.translate(999), 'Smartschool-fout 999');
    });

    test('empty table is not loaded and always falls back', () {
      expect(SmartschoolErrorCodes.empty.isLoaded, isFalse);
      expect(
        SmartschoolErrorCodes.empty.translate(5),
        'Smartschool-fout 5',
      );
    });

    test('throws on a non-object payload', () {
      expect(
        () => SmartschoolErrorCodes.fromJson('[1,2,3]'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
