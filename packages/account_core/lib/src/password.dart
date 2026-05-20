import 'dart:math';

/// Password generator ported faithfully from legacy
/// `legacy-wpf/AccountApi/Password.cs`.
///
/// Produces an 8-character password in the fixed shape
/// `Capital + vowel + consonant + vowel + consonant + vowel + digit + symbol`.
///
/// Anti-confusion rules carried over from legacy:
/// - Capital letters exclude `A`, `E`, `I`, `L`, `O`, `U`, `Y` (see
///   [_capitals]). `I` and `O` are excluded because they are visually
///   confusable with the digit positions; vowels are excluded so the capital
///   does not "feel" like part of the pronounceable stem.
/// - Lowercase consonants exclude `l` (confusable with `1`).
/// - Digits are drawn from 2..9 inclusive; `0` and `1` are excluded
///   (confusable with `o`/`O` and `l`/`I`).
/// - Symbols are drawn from `{!, ?, *}`.
///
/// Lowercase vowels include `o` and `i` because the legacy `VOWELS` constant
/// is `"aeiouy"`. This is preserved verbatim — passwords may contain
/// lowercase `o` or `i`.
class Password {
  static const String _capitals = 'BCDFGHJKMNPQRSTVWXZ';
  static const String _vowels = 'aeiouy';
  static const String _consonants = 'bcdfghjkmnpqrstvwxz';
  static const String _symbols = '!?*';

  /// Generates a fresh 8-character password.
  ///
  /// [random] is exposed only for deterministic testing; production callers
  /// should use the default `Random.secure()`.
  static String create({Random? random}) {
    final r = random ?? Random.secure();
    final buf = StringBuffer()
      ..writeCharCode(_capitals.codeUnitAt(r.nextInt(_capitals.length)))
      ..writeCharCode(_vowels.codeUnitAt(r.nextInt(_vowels.length)))
      ..writeCharCode(_consonants.codeUnitAt(r.nextInt(_consonants.length)))
      ..writeCharCode(_vowels.codeUnitAt(r.nextInt(_vowels.length)))
      ..writeCharCode(_consonants.codeUnitAt(r.nextInt(_consonants.length)))
      ..writeCharCode(_vowels.codeUnitAt(r.nextInt(_vowels.length)))
      // Digit in [2, 9]. `nextInt(8) + 2` mirrors legacy `Next(2, 10)`.
      ..writeCharCode(0x30 + 2 + r.nextInt(8))
      ..writeCharCode(_symbols.codeUnitAt(r.nextInt(_symbols.length)));
    return buf.toString();
  }

  /// The character set used in the capital position.
  static String get capitals => _capitals;

  /// The character set used in the vowel positions (1, 3, 5).
  static String get vowels => _vowels;

  /// The character set used in the consonant positions (2, 4).
  static String get consonants => _consonants;

  /// The character set used in the symbol position (7).
  static String get symbols => _symbols;
}
