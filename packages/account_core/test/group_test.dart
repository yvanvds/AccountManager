import 'dart:convert';

import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

Group _group({
  String id = 'g1',
  String? parent,
  String? institute,
  int? admin,
  String untis = '',
  int? sourceId,
  GroupType type = GroupType.classGroup,
  bool official = true,
}) =>
    Group(
      id: GroupId(id),
      name: '5A',
      description: 'Vijfde jaar A',
      type: type,
      official: official,
      parentId: parent == null ? null : GroupId(parent),
      instituteNumber: institute,
      adminNumber: admin,
      untis: untis,
      sourceId: sourceId,
      origin: Origin.wisa,
    );

void main() {
  group('Group JSON round-trip', () {
    test('minimal (no parent, no institute, no admin)', () {
      final g = _group();
      expect(Group.fromJson(g.toJson()), equals(g));
    });

    test('full (parent, institute, admin, untis, sourceId)', () {
      final g = _group(
        parent: 'root',
        institute: '12345',
        admin: 7,
        untis: '5A',
        sourceId: 298,
      );
      expect(Group.fromJson(g.toJson()), equals(g));
      expect(Group.fromJson(g.toJson()).sourceId, 298);
    });

    test('survives encode/decode through dart:convert', () {
      final g =
          _group(parent: 'root', institute: '12345', admin: 7, untis: '5A');
      final encoded = jsonEncode(g.toJson());
      final decoded =
          Group.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded, equals(g));
    });

    test('omits null optionals and empty untis from JSON', () {
      final g = _group();
      final json = g.toJson();
      expect(json.containsKey('parentId'), isFalse);
      expect(json.containsKey('instituteNumber'), isFalse);
      expect(json.containsKey('adminNumber'), isFalse);
      expect(json.containsKey('untis'), isFalse);
      expect(json.containsKey('sourceId'), isFalse);
    });

    test('legacy JSON without untis decodes to an empty untis', () {
      final json = _group(institute: '12345').toJson()..remove('untis');
      expect(Group.fromJson(json).untis, '');
    });

    test('JSON written before #138 decodes to a null sourceId', () {
      final json = _group(sourceId: 298).toJson()..remove('sourceId');
      expect(Group.fromJson(json).sourceId, isNull);
    });
  });

  group('Group equality', () {
    test('value equality on every field', () {
      expect(_group(), equals(_group()));
      expect(_group().hashCode, equals(_group().hashCode));
      expect(_group(official: true), isNot(equals(_group(official: false))));
      expect(_group(untis: '5A'), isNot(equals(_group(untis: 'stale'))));
      expect(_group(sourceId: 298), isNot(equals(_group(sourceId: 4))));
      expect(_group(sourceId: 298), isNot(equals(_group())));
      expect(
        _group(type: GroupType.group),
        isNot(equals(_group(type: GroupType.classGroup))),
      );
    });
  });

  group('Membership', () {
    const m = Membership(
      personId: PersonId('p1'),
      groupId: GroupId('g1'),
      accountType: AccountType.student,
      origin: Origin.smartschool,
    );

    test('JSON round-trip', () {
      expect(Membership.fromJson(m.toJson()), equals(m));
    });

    test('equality and hashCode', () {
      const same = Membership(
        personId: PersonId('p1'),
        groupId: GroupId('g1'),
        accountType: AccountType.student,
        origin: Origin.smartschool,
      );
      const different = Membership(
        personId: PersonId('p1'),
        groupId: GroupId('g2'),
        accountType: AccountType.student,
        origin: Origin.smartschool,
      );
      expect(m, equals(same));
      expect(m.hashCode, equals(same.hashCode));
      expect(m, isNot(equals(different)));
    });

    test('two memberships of the same person in the same system are allowed',
        () {
      // INV-30 / PAIN-1: many-to-many. The model permits it; whether to
      // enforce uniqueness is a linker decision, not a domain one.
      const a = Membership(
        personId: PersonId('p1'),
        groupId: GroupId('g1'),
        accountType: AccountType.student,
        origin: Origin.smartschool,
      );
      const b = Membership(
        personId: PersonId('p1'),
        groupId: GroupId('g2'),
        accountType: AccountType.student,
        origin: Origin.smartschool,
      );
      expect(a, isNot(equals(b)));
      // Both are valid records — nothing here prevents holding both.
    });
  });

  group('group-name normalization (#225)', () {
    test('trims, lower-cases, and collapses internal whitespace runs', () {
      expect(normalizeGroupName('  2G  '), '2g');
      expect(normalizeGroupName('5A  01'), '5a 01');
      expect(normalizeGroupName('5A\t01'), '5a 01');
    });

    test('non-breaking spaces normalize to a plain space', () {
      // What an operator's copy-paste leaves in a Smartschool class name; it
      // does not make it a different class from the WISA one.
      expect(normalizeGroupName('5A\u00a001'), '5a 01');
      expect(normalizeGroupName('5A\u202f01'), '5a 01');
      expect(normalizeGroupName('5A\u00a0\u00a001'), '5a 01');
    });

    test('a blank or null name is no key at all', () {
      expect(normalizeGroupName(null), isNull);
      expect(normalizeGroupName('   '), isNull);
      expect(normalizeGroupName('\u00a0'), isNull);
    });

    test('the space between a class and its sub-group is preserved', () {
      // The looser fingerprint drops it; the match key must not, or `5A 01`
      // and `5A01` would link as one class.
      expect(normalizeGroupName('5A 01'), isNot(normalizeGroupName('5A01')));
    });

    test('the fingerprint ignores whitespace entirely', () {
      expect(groupNameFingerprint('2 G'), groupNameFingerprint('2G'));
      expect(groupNameFingerprint('2\u00a0g'), '2g');
      expect(groupNameFingerprint('5A 01'), '5a01');
      expect(groupNameFingerprint('  '), isNull);
      expect(groupNameFingerprint(null), isNull);
    });
  });

  group('Office 365 class-group naming (#228)', () {
    test('a class group is <PREFIX>-<KLAS>', () {
      expect(azureClassGroupName('SSM', '2A'), 'SSM-2A');
      expect(azureClassGroupName(' SSM ', ' 2A '), 'SSM-2A');
    });

    test('a missing half names no group', () {
      expect(azureClassGroupName('', '2A'), isNull);
      expect(azureClassGroupName('SSM', '  '), isNull);
      expect(azureClassGroupName(null, null), isNull);
    });

    test('the bare class name is recovered from the prefixed display name', () {
      expect(azureClassNameOf('SSM-2A', 'SSM'), '2A');
      // The prefix compares case-insensitively (INV-12); the class name is
      // returned as written so it can be displayed.
      expect(azureClassNameOf('ssm-2A', 'SSM'), '2A');
      expect(azureClassNameOf('  SSM-2A  ', 'SSM'), '2A');
    });

    test('a name outside our namespace belongs to no class', () {
      expect(azureClassNameOf('2A', 'SSM'), isNull);
      expect(azureClassNameOf('OTHER-2A', 'SSM'), isNull);
      expect(azureClassNameOf('SSM-', 'SSM'), isNull);
      expect(azureClassNameOf('SSM-2A', ''), isNull);
      expect(azureClassNameOf(null, 'SSM'), isNull);
    });

    test('naming round-trips for every plausible bare class name', () {
      for (final className in ['1A', '2F', '7EW', 'OKAN', '3STW']) {
        final name = azureClassGroupName('SSM', className)!;
        expect(azureClassNameOf(name, 'SSM'), className);
      }
    });

    test(
        'bare class names need no slug rule \u2014 but a name that would break the '
        'mail nickname is rejected rather than mangled', () {
      // The decided rule: bare class names carry no spaces, so `<PREFIX>-<KLAS>`
      // is used verbatim. This is the assertion that tells us early if a WISA
      // class name ever stops honouring that.
      for (final className in ['1A', '2F', '7EW', 'OKAN', '3STW']) {
        expect(
            isValidMailNickname(azureClassGroupName('SSM', className)), isTrue,
            reason: '$className must survive as a mail nickname');
      }
      // \u2026and the shapes Graph refuses.
      expect(isValidMailNickname('SSM-2F ECO'), isFalse, reason: 'space');
      expect(isValidMailNickname('SSM-2\u00c9'), isFalse, reason: 'diacritic');
      expect(isValidMailNickname('SSM-2A@x'), isFalse, reason: 'reserved @');
      expect(isValidMailNickname('SSM-2A;1'), isFalse, reason: 'reserved ;');
      expect(isValidMailNickname('SSM-2A\u00a0'), isFalse, reason: 'nbsp');
      expect(isValidMailNickname(''), isFalse);
      expect(isValidMailNickname(null), isFalse);
    });
  });
}
