import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

String _readFixture(String name) {
  final tryPaths = <String>[
    Uri.base.resolve('test/fixtures/$name').toFilePath(),
    'test/fixtures/$name',
    'packages/smartschool_api/test/fixtures/$name',
  ];
  for (final p in tryPaths) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw FileSystemException('fixture not found: $name', tryPaths.join(', '));
}

void main() {
  final base64Tree = base64.encode(utf8.encode(_readFixture('group_tree.xml')));

  test('returns empty for an empty payload', () {
    expect(parseGroupTree(''), isEmpty);
    expect(parseGroupTree('   '), isEmpty);
  });

  group('parseGroupTree', () {
    final forest = parseGroupTree(base64Tree);

    test('reads the top-level group', () {
      expect(forest, hasLength(1));
      final root = forest.first;
      expect(root.name, 'School');
      expect(root.code, 'SCH');
      expect(root.type, core.GroupType.group);
      expect(root.official, isFalse);
      expect(root.visible, isTrue);
      expect(root.coAccountLabel, 'Ouders');
      expect(root.parentCode, isNull);
    });

    test('nests children with parentCode edges', () {
      final root = forest.first;
      expect(root.children.map((g) => g.code), ['C1A', 'C1B', 'GSPORT']);
      for (final child in root.children) {
        expect(child.parentCode, 'SCH');
      }
    });

    test('maps K to classGroup and reads official-class fields', () {
      final c1a = forest.first.children.firstWhere((g) => g.code == 'C1A');
      expect(c1a.type, core.GroupType.classGroup);
      expect(c1a.official, isTrue);
      expect(c1a.adminNumber, 12345);
      expect(c1a.instituteNumber, '30024');
      expect(c1a.untis, '1A');
      expect(c1a.titulars, ['titularis1', 'titularis2']);
    });

    test('toCoreGroup projects fields and edges', () {
      final c1a = forest.first.children.firstWhere((g) => g.code == 'C1A');
      final g = c1a.toCoreGroup();
      expect(g.id, const core.GroupId('C1A'));
      expect(g.parentId, const core.GroupId('SCH'));
      expect(g.official, isTrue);
      expect(g.adminNumber, 12345);
      expect(g.instituteNumber, '30024');
      expect(g.untis, '1A');
      expect(g.origin, core.Origin.smartschool);

      final root = forest.first.toCoreGroup();
      expect(root.parentId, isNull);
      expect(root.adminNumber, isNull);
      expect(root.instituteNumber, isNull);
    });
  });

  test('handles a single top-level <group> root element', () {
    const xml = '<group><name>Solo</name><type>G</type>'
        '<code>S1</code></group>';
    final forest = parseGroupTree(base64.encode(utf8.encode(xml)));
    expect(forest, hasLength(1));
    expect(forest.first.name, 'Solo');
    expect(forest.first.code, 'S1');
  });
}
