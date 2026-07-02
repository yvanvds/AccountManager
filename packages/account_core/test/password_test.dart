import 'dart:math';

import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

void main() {
  group('Password.create()', () {
    test('produces exactly 8 characters', () {
      for (var i = 0; i < 100; i++) {
        expect(Password.create().length, equals(8));
      }
    });

    test('positions match the fixed shape per spec', () {
      // Capital + vowel + consonant + vowel + consonant + vowel + digit + symbol
      for (var i = 0; i < 100; i++) {
        final p = Password.create();
        expect(
          Password.capitals.contains(p[0]),
          isTrue,
          reason: 'p[0]=${p[0]} not in capitals',
        );
        expect(
          Password.vowels.contains(p[1]),
          isTrue,
          reason: 'p[1]=${p[1]} not in vowels',
        );
        expect(
          Password.consonants.contains(p[2]),
          isTrue,
          reason: 'p[2]=${p[2]} not in consonants',
        );
        expect(
          Password.vowels.contains(p[3]),
          isTrue,
          reason: 'p[3]=${p[3]} not in vowels',
        );
        expect(
          Password.consonants.contains(p[4]),
          isTrue,
          reason: 'p[4]=${p[4]} not in consonants',
        );
        expect(
          Password.vowels.contains(p[5]),
          isTrue,
          reason: 'p[5]=${p[5]} not in vowels',
        );
        // Digit in [2, 9].
        final d = int.parse(p[6]);
        expect(d, greaterThanOrEqualTo(2));
        expect(d, lessThanOrEqualTo(9));
        expect(
          Password.symbols.contains(p[7]),
          isTrue,
          reason: 'p[7]=${p[7]} not in symbols',
        );
      }
    });

    test('digit position never contains 0 or 1 (anti-confusion)', () {
      for (var i = 0; i < 200; i++) {
        final p = Password.create();
        expect(p[6], isNot(equals('0')));
        expect(p[6], isNot(equals('1')));
      }
    });

    test('capital position never contains O, I, A, E, U, Y, L', () {
      // Letters dropped from the capital alphabet for anti-confusion
      // (O/I look like digits 0/1; vowels removed so the capital doesn't
      // feel part of the pronounceable stem).
      const banned = {'A', 'E', 'I', 'L', 'O', 'U', 'Y'};
      for (var i = 0; i < 200; i++) {
        expect(banned.contains(Password.create()[0]), isFalse);
      }
    });

    test('consonant positions never contain l (anti-confusion vs digit 1)', () {
      for (var i = 0; i < 200; i++) {
        final p = Password.create();
        expect(p[2], isNot(equals('l')));
        expect(p[4], isNot(equals('l')));
      }
    });

    test('statistical sanity: every character class appears across N samples',
        () {
      // If any class were silently empty (e.g. constants accidentally cleared)
      // some position would be stuck on a single character — this catches it.
      final caps = <String>{};
      final vowels = <String>{};
      final consonants = <String>{};
      final digits = <String>{};
      final symbols = <String>{};
      for (var i = 0; i < 2000; i++) {
        final p = Password.create();
        caps.add(p[0]);
        vowels.addAll([p[1], p[3], p[5]]);
        consonants.addAll([p[2], p[4]]);
        digits.add(p[6]);
        symbols.add(p[7]);
      }
      expect(caps.length, greaterThan(5));
      expect(vowels.length, equals(Password.vowels.length));
      expect(consonants.length, greaterThan(10));
      expect(digits.length, equals(8)); // 2..9
      expect(symbols.length, equals(3)); // ! ? *
    });

    test('deterministic with a seeded Random — same seed ⇒ same password', () {
      final p1 = Password.create(random: Random(42));
      final p2 = Password.create(random: Random(42));
      expect(p1, equals(p2));
    });

    test('character sets match the legacy constants verbatim', () {
      expect(Password.capitals, equals('BCDFGHJKMNPQRSTVWXZ'));
      expect(Password.vowels, equals('aeiouy'));
      expect(Password.consonants, equals('bcdfghjkmnpqrstvwxz'));
      expect(Password.symbols, equals('!?*'));
    });
  });
}
