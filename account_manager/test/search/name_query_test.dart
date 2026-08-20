import 'package:account_manager/src/search/name_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// The needle handling behind both Personeel search boxes — Wachtwoorden
/// (#215) and Acties (#187/#217). Pinned once here so the two screens sharing
/// it cannot drift apart again.
void main() {
  group('NameQuery', () {
    test('an empty or whitespace-only needle matches everyone', () {
      for (final text in <String>['', '   ', '\t\n ']) {
        final query = NameQuery(text);
        expect(query.isEmpty, isTrue, reason: 'needle ${text.length} spaces');
        expect(query.matches('Jan Peeters'), isTrue);
        expect(query.matches(''), isTrue);
      }
    });

    test('a single fragment matches either half of the name, any case', () {
      expect(NameQuery('peeters').matches('Jan Peeters'), isTrue);
      expect(NameQuery('JAN').matches('Jan Peeters'), isTrue);
      expect(NameQuery('jan').matches('Jan Peeters'), isTrue);
    });

    test('a fragment matches mid-word, not just at a word boundary', () {
      expect(NameQuery('eter').matches('Jan Peeters'), isTrue);
      expect(NameQuery('an pe').matches('Jan Peeters'), isTrue);
    });

    test('a non-occurring fragment matches nothing', () {
      expect(NameQuery('zzz').matches('Jan Peeters'), isFalse);
    });

    test('both halves match in the stored order', () {
      expect(NameQuery('jan peeters').matches('Jan Peeters'), isTrue);
    });

    test('both halves match reversed — the point of #217', () {
      // "peeters jan" is the order the operator remembers the name in half the
      // time; as one contiguous substring it found nobody.
      expect(NameQuery('peeters jan').matches('Jan Peeters'), isTrue);
      expect(NameQuery('Smit Anna').matches('Anna Smit'), isTrue);
    });

    test('every part must occur — parts from two people match neither', () {
      expect(NameQuery('jan smit').matches('Jan Peeters'), isFalse);
      expect(NameQuery('jan smit').matches('Anna Smit'), isFalse);
    });

    test('runs of whitespace in the needle collapse', () {
      expect(NameQuery('  peeters    jan  ').matches('Jan Peeters'), isTrue);
      expect(NameQuery('peeters\tjan').matches('Jan Peeters'), isTrue);
    });

    test('the name is normalised too, so padding cannot decide a match', () {
      // A missing voornaam or surname leaves the composed "Voornaam Naam" with
      // a stray space; it must not break a two-part needle or create a match.
      expect(NameQuery('peeters').matches('  Peeters'), isTrue);
      expect(NameQuery('jan peeters').matches('Jan   Peeters'), isTrue);
      expect(NameQuery('jan peeters').matches(' Peeters '), isFalse);
    });

    test('parts exposes the typed words, lower-cased and trimmed', () {
      expect(NameQuery(' Peeters   JAN ').parts, <String>['peeters', 'jan']);
      expect(NameQuery('   ').parts, isEmpty);
    });
  });
}
