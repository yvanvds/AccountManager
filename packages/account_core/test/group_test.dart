import 'dart:convert';

import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

Group _group({
  String id = 'g1',
  String? parent,
  String? institute,
  int? admin,
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
      origin: Origin.wisa,
    );

void main() {
  group('Group JSON round-trip', () {
    test('minimal (no parent, no institute, no admin)', () {
      final g = _group();
      expect(Group.fromJson(g.toJson()), equals(g));
    });

    test('full (parent, institute, admin)', () {
      final g = _group(parent: 'root', institute: '12345', admin: 7);
      expect(Group.fromJson(g.toJson()), equals(g));
    });

    test('survives encode/decode through dart:convert', () {
      final g = _group(parent: 'root', institute: '12345', admin: 7);
      final encoded = jsonEncode(g.toJson());
      final decoded =
          Group.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded, equals(g));
    });

    test('omits null optionals from JSON', () {
      final g = _group();
      final json = g.toJson();
      expect(json.containsKey('parentId'), isFalse);
      expect(json.containsKey('instituteNumber'), isFalse);
      expect(json.containsKey('adminNumber'), isFalse);
    });
  });

  group('Group equality', () {
    test('value equality on every field', () {
      expect(_group(), equals(_group()));
      expect(_group().hashCode, equals(_group().hashCode));
      expect(_group(official: true), isNot(equals(_group(official: false))));
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
}
