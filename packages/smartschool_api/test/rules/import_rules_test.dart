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
}
