import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

/// A tenant-shaped forest:
///
/// ```
/// School
///   Leerlingen -> [1A, 1B]
///   Personeel  -> [Directie]
///   Beheerders -> [Externen]
/// ```
///
/// The third root is the one #351 is about: its members are neither students
/// nor staff, yet every one of them used to enter the snapshot.
List<SmartschoolGroup> _forest() {
  SmartschoolGroup group(
    String name,
    String code, {
    String? parent,
    core.GroupType type = core.GroupType.group,
    List<SmartschoolGroup> children = const [],
  }) =>
      SmartschoolGroup(
        name: name,
        code: code,
        type: type,
        parentCode: parent,
        children: <SmartschoolGroup>[...children],
      );

  return [
    group('School', 'SCH', children: [
      group('Leerlingen', 'LLN', parent: 'SCH', children: [
        group('1A', 'C1A', parent: 'LLN', type: core.GroupType.classGroup),
        group('1B', 'C1B', parent: 'LLN', type: core.GroupType.classGroup),
      ]),
      group('Personeel', 'PERS', parent: 'SCH', children: [
        group('Directie', 'DIR', parent: 'PERS'),
      ]),
      group('Beheerders', 'BEH', parent: 'SCH', children: [
        group('Externen', 'EXT', parent: 'BEH'),
      ]),
    ]),
  ];
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
  group('scopeToRoots', () {
    test('keeps the named subtrees and nothing else', () {
      expect(
        _codes(scopeToRoots(_forest(), const ['Leerlingen', 'Personeel'])),
        ['LLN', 'C1A', 'C1B', 'PERS', 'DIR'],
      );
    });

    test('takes the roots in tree order, not in the order configured', () {
      // They are matched against the tree, so the walk order — and with it the
      // snapshot's group order — is Smartschool's, whatever Instellingen lists
      // first.
      expect(
        _codes(scopeToRoots(_forest(), const ['Personeel', 'Leerlingen'])),
        ['LLN', 'C1A', 'C1B', 'PERS', 'DIR'],
      );
    });

    test('matches a root however the operator spelled it (#241)', () {
      // Both sides are operator-typed: the root in Instellingen, the group in
      // Smartschool. A raw `==` made a name that reads as correct do nothing.
      expect(
        _codes(scopeToRoots(_forest(), const [' personeel ', 'LEERLINGEN'])),
        ['LLN', 'C1A', 'C1B', 'PERS', 'DIR'],
      );
    });

    test('no roots configured leaves the whole forest', () {
      expect(
        _codes(scopeToRoots(_forest(), const [])),
        ['SCH', 'LLN', 'C1A', 'C1B', 'PERS', 'DIR', 'BEH', 'EXT'],
      );
    });

    test('a blank entry names nothing and scopes nothing', () {
      expect(
        _codes(scopeToRoots(_forest(), const ['', '   '])),
        ['SCH', 'LLN', 'C1A', 'C1B', 'PERS', 'DIR', 'BEH', 'EXT'],
      );
    });

    test('a root that matches no group leaves the pull unscoped', () {
      // The fail-safe. Scoping to `Leerlingen` alone would empty the entire
      // staff population out of the snapshot, and an absent population does not
      // read as "not pulled" downstream — it reads as departed.
      expect(
        _codes(scopeToRoots(_forest(), const ['Leerlingen', 'Medewerkers'])),
        ['SCH', 'LLN', 'C1A', 'C1B', 'PERS', 'DIR', 'BEH', 'EXT'],
      );
    });

    test('takes the outermost match, so a nested namesake is walked once', () {
      final forest = _forest();
      // A second "Personeel" inside the first: a sub-group an operator made,
      // which must not be visited twice (its members would be counted twice).
      forest.single.children[1].children.add(
        SmartschoolGroup(name: 'Personeel', code: 'PERS2', parentCode: 'PERS'),
      );
      expect(
        _codes(scopeToRoots(forest, const ['Personeel'])),
        ['PERS', 'DIR', 'PERS2'],
      );
    });

    test('scopes the tree the import rules left behind', () {
      // A discarded root is genuinely gone, so it matches nothing and the pull
      // stays unscoped rather than resurrecting it.
      final pruned = applyImportRules(
        _forest(),
        const [DiscardSmartschoolGroup('Personeel')],
      );
      expect(unmatchedRootNames(pruned, const ['Leerlingen', 'Personeel']),
          ['Personeel']);
      expect(
        _codes(scopeToRoots(pruned, const ['Leerlingen', 'Personeel'])),
        ['SCH', 'LLN', 'C1A', 'C1B', 'BEH', 'EXT'],
      );
    });
  });

  group('unmatchedRootNames', () {
    test('names the missing roots as the operator spelled them', () {
      expect(
        unmatchedRootNames(
          _forest(),
          const ['Leerlingen', 'Medewerkers', 'Externen '],
        ),
        ['Medewerkers'],
      );
    });

    test('is silent about blanks', () {
      expect(unmatchedRootNames(_forest(), const ['', ' ']), isEmpty);
    });
  });
}
