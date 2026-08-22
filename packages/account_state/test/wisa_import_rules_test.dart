import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('WisaImportRules.add', () {
    test('keeps insertion order and drops structural duplicates', () {
      final rules = WisaImportRules();
      expect(rules.add(const DontImportClass('3C')), isTrue);
      expect(rules.add(const MarkAsVirtual('S1')), isTrue);
      expect(rules.add(const DontImportClass('3C')), isFalse);

      expect(rules.rules, hasLength(2));
      expect(rules.rules.first, isA<DontImportClass>());
      expect(rules.rules.last, isA<MarkAsVirtual>());
    });
  });

  group('WisaImportRules.unionWith (#263)', () {
    test('puts the persisted rules first and the session\'s own after', () {
      // Persisted rules are the operator's standing configuration; the ones an
      // apply earned this session are the increment on top.
      final rules = WisaImportRules()..add(const DontImportUserFromWisa('u1'));

      final merged = rules.unionWith(const <WisaImportRule>[
        DontImportClass('3C'),
        MarkAsVirtual('V'),
      ]);

      expect(merged.map((r) => r.runtimeType).toList(), <Type>[
        DontImportClass,
        MarkAsVirtual,
        DontImportUserFromWisa,
      ]);
    });

    test('collapses a rule the document and the session both carry', () {
      // Applying a `DontImportClass` the settings document already carries must
      // not grow the pull's rule list — the snapshot is the same either way.
      final rules = WisaImportRules()..add(const DontImportClass('3C'));

      final merged =
          rules.unionWith(const <WisaImportRule>[DontImportClass('3C')]);

      expect(merged, hasLength(1));
    });

    test('does not mutate the session holder', () {
      // The union is composed per pull. Folding the persisted rules into the
      // holder is exactly the freeze #263 removed: a rule later *removed* from
      // the document could then never be dropped.
      final rules = WisaImportRules();
      rules.unionWith(const <WisaImportRule>[DontImportClass('3C')]);

      expect(rules.rules, isEmpty);
      expect(
        rules.unionWith(const <WisaImportRule>[]),
        isEmpty,
        reason: 'a document that dropped the rule pulls without it',
      );
    });

    test('reads both sources at call time', () {
      final rules = WisaImportRules();
      expect(rules.unionWith(const <WisaImportRule>[]), isEmpty);

      rules.add(const DontImportClass('3C'));
      expect(
        rules.unionWith(const <WisaImportRule>[MarkAsVirtual('S1')]),
        hasLength(2),
      );
    });

    test('hands back an unmodifiable list', () {
      expect(
        () => WisaImportRules().unionWith(const <WisaImportRule>[]).add(
            const DontImportClass('3C')),
        throwsUnsupportedError,
      );
    });
  });
}
