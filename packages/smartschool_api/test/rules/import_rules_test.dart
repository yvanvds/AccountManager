import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

/// Builds: Root(G) -> [A(G) -> [A1(K), A2(K)], B(G)].
List<SmartschoolGroup> _forest() {
  final a1 = SmartschoolGroup(
    name: 'A1',
    code: 'A1',
    type: core.GroupType.classGroup,
    parentCode: 'A',
  );
  final a2 = SmartschoolGroup(
    name: 'A2',
    code: 'A2',
    type: core.GroupType.classGroup,
    parentCode: 'A',
  );
  final a = SmartschoolGroup(
    name: 'A',
    code: 'A',
    type: core.GroupType.group,
    parentCode: 'Root',
    children: [a1, a2],
  );
  final b = SmartschoolGroup(
    name: 'B',
    code: 'B',
    type: core.GroupType.group,
    parentCode: 'Root',
  );
  final root = SmartschoolGroup(
    name: 'Root',
    code: 'Root',
    type: core.GroupType.group,
    children: [a, b],
  );
  return [root];
}

List<String> _codes(List<SmartschoolGroup> forest) {
  final out = <String>[];
  void walk(List<SmartschoolGroup> gs) {
    for (final g in gs) {
      out.add(g.code);
      walk(g.children);
    }
  }

  walk(forest);
  return out;
}

void main() {
  test('no rules leaves the forest intact', () {
    expect(
      _codes(applyImportRules(_forest(), const [])),
      ['Root', 'A', 'A1', 'A2', 'B'],
    );
  });

  test('DiscardSmartschoolGroup removes the group and its subtree', () {
    final result = applyImportRules(
      _forest(),
      const [DiscardSmartschoolGroup('A')],
    );
    expect(_codes(result), ['Root', 'B']);
  });

  test('NoSmartschoolSubgroups prunes descendants but keeps the group', () {
    final result = applyImportRules(
      _forest(),
      const [NoSmartschoolSubgroups('A')],
    );
    expect(_codes(result), ['Root', 'A', 'B']);
    final a = result.first.children.firstWhere((g) => g.code == 'A');
    expect(a.children, isEmpty);
  });

  test('rules combine: discard one branch, prune another', () {
    final result = applyImportRules(
      _forest(),
      const [DiscardSmartschoolGroup('B'), NoSmartschoolSubgroups('A')],
    );
    expect(_codes(result), ['Root', 'A']);
  });

  // ---------------------------------------------------------------------------
  // Normalized matching (#241)
  // ---------------------------------------------------------------------------

  group('matches on the normalized group name (#241)', () {
    test('DiscardSmartschoolGroup ignores case', () {
      final result = applyImportRules(
        _forest(),
        const [DiscardSmartschoolGroup('a')],
      );
      expect(_codes(result), ['Root', 'B']);
    });

    test('DiscardSmartschoolGroup ignores surrounding whitespace', () {
      final result = applyImportRules(
        _forest(),
        const [DiscardSmartschoolGroup('  A ')],
      );
      expect(_codes(result), ['Root', 'B']);
    });

    test('NoSmartschoolSubgroups ignores case', () {
      final result = applyImportRules(
        _forest(),
        const [NoSmartschoolSubgroups('a')],
      );
      expect(_codes(result), ['Root', 'A', 'B']);
    });

    test('a non-breaking space in the Smartschool name still matches', () {
      // Smartschool carries the name with the non-breaking space a copy-paste
      // left behind; the operator typed a plain one.
      final forest = [
        SmartschoolGroup(
          name: 'Klassen\u00a01',
          code: 'K1',
          type: core.GroupType.group,
        ),
      ];
      final result = applyImportRules(
        forest,
        const [DiscardSmartschoolGroup('Klassen 1')],
      );
      expect(result, isEmpty);
    });

    test('a blank rule name matches nothing', () {
      // Not even the group whose name is itself blank — an empty key must never
      // index or match anything (INV-12 / #225).
      final forest = [
        SmartschoolGroup(name: '', code: 'X', type: core.GroupType.group),
        SmartschoolGroup(name: 'A', code: 'A', type: core.GroupType.group),
      ];
      final result = applyImportRules(
        forest,
        const [DiscardSmartschoolGroup('   ')],
      );
      expect(_codes(result), ['X', 'A']);
    });
  });

  // ---------------------------------------------------------------------------
  // Unmatched rules (#241)
  // ---------------------------------------------------------------------------

  group('unmatchedImportRules', () {
    List<String> names(List<SmartschoolImportRule> rules) =>
        [for (final r in rules) r.groupName];

    test('reports a rule naming a group the tree does not carry', () {
      expect(
        names(unmatchedImportRules(
          _forest(),
          const [DiscardSmartschoolGroup('Sport')],
        )),
        ['Sport'],
      );
    });

    test('reports nothing when the name differs only in case or whitespace',
        () {
      expect(
        unmatchedImportRules(
          _forest(),
          const [DiscardSmartschoolGroup(' a '), NoSmartschoolSubgroups('B')],
        ),
        isEmpty,
      );
    });

    test('reports a blank rule name, which can never match', () {
      expect(
        names(unmatchedImportRules(
          _forest(),
          const [NoSmartschoolSubgroups('  ')],
        )),
        ['  '],
      );
    });

    test('does not report a rule shadowed by another rule', () {
      // `A1` lives inside the subtree `A` discards. The rule does nothing this
      // pull, but its group exists — that is a rule interaction, not a typo,
      // and calling it out would send the operator hunting a name that is
      // spelled correctly.
      expect(
        unmatchedImportRules(
          _forest(),
          const [DiscardSmartschoolGroup('A'), NoSmartschoolSubgroups('A1')],
        ),
        isEmpty,
      );
    });

    test('keeps one entry per rule, in the order given', () {
      expect(
        names(unmatchedImportRules(
          _forest(),
          const [
            DiscardSmartschoolGroup('Sport'),
            NoSmartschoolSubgroups('A'),
            NoSmartschoolSubgroups('Sport'),
          ],
        )),
        ['Sport', 'Sport'],
      );
    });
  });
}
