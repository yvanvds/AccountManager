import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

SmartschoolAccount _account({
  String uid = 'jand',
  String mail = 'jan@school.be',
  String? referenceIdentifier,
  List<CoAccountSlot> coAccounts = const [],
}) {
  return SmartschoolAccount(
    uid: uid,
    accountId: 'W001',
    mail: mail,
    registerId: '',
    stemId: 0,
    role: core.PersonRole.student,
    givenName: 'Jan',
    surname: 'Desmet',
    extraNames: '',
    initials: '',
    preferredName: '',
    gender: core.Gender.male,
    birthDate: null,
    birthPlace: '',
    birthCountry: '',
    address: const core.Address(
      street: '',
      houseNumber: '',
      postalCode: '',
      city: '',
      country: '',
    ),
    mobilePhone: '',
    homePhone: '',
    fax: '',
    untisId: '',
    status: 'actief',
    referenceIdentifier: referenceIdentifier,
    coAccounts: coAccounts,
  );
}

void main() {
  group('CoAccountSlot', () {
    const slot = CoAccountSlot(
      slot: 1,
      firstName: 'Anne',
      lastName: 'Lemmens',
      email: 'anne@example.be',
      phone: '016',
      mobile: '0470',
      type: 'Moeder',
    );

    test('value equality and hashCode', () {
      const same = CoAccountSlot(
        slot: 1,
        firstName: 'Anne',
        lastName: 'Lemmens',
        email: 'anne@example.be',
        phone: '016',
        mobile: '0470',
        type: 'Moeder',
      );
      expect(slot, same);
      expect(slot.hashCode, same.hashCode);
    });

    test('accountType derives from slot', () {
      expect(slot.accountType, core.AccountType.coAccount1);
    });

    test('isEmpty detects a blank slot', () {
      expect(slot.isEmpty, isFalse);
      const blank = CoAccountSlot(
        slot: 2,
        firstName: '',
        lastName: '',
        email: '',
        phone: '',
        mobile: '',
        type: '',
      );
      expect(blank.isEmpty, isTrue);
    });
  });

  group('SmartschoolAccount', () {
    test('equality includes co-account slots', () {
      const slot = CoAccountSlot(
        slot: 1,
        firstName: 'Anne',
        lastName: 'L',
        email: '',
        phone: '',
        mobile: '',
        type: 'Moeder',
      );
      expect(
        _account(coAccounts: const [slot]),
        _account(coAccounts: const [slot]),
      );
      expect(_account(coAccounts: const [slot]) == _account(), isFalse);
      expect(_account() == _account(mail: 'other@school.be'), isFalse);
    });

    test('accountType is always student for the primary record', () {
      expect(_account().accountType, core.AccountType.student);
    });

    test('exposes the referenceIdentifier and its user id (#138)', () {
      final a = _account(referenceIdentifier: '4069_12016_0');
      expect(a.referenceIdentifier, '4069_12016_0');
      expect(a.internalUserId, 12016);
      expect(_account().referenceIdentifier, isNull);
      expect(_account().internalUserId, isNull);
    });

    test('referenceIdentifier takes part in equality (#138)', () {
      expect(
        _account(referenceIdentifier: '4069_12016_0'),
        _account(referenceIdentifier: '4069_12016_0'),
      );
      expect(
        _account(referenceIdentifier: '4069_12016_0').hashCode,
        _account(referenceIdentifier: '4069_12016_0').hashCode,
      );
      expect(
        _account(referenceIdentifier: '4069_12016_0') ==
            _account(referenceIdentifier: '4069_99999_0'),
        isFalse,
      );
      expect(
        _account(referenceIdentifier: '4069_12016_0') == _account(),
        isFalse,
      );
    });

    test('referenceIdentifier survives copyWith and JSON (#138)', () {
      final a = _account(referenceIdentifier: '4069_12016_0');
      expect(
          a.copyWith(mail: 'x@school.be').referenceIdentifier, '4069_12016_0');
      expect(
        a.copyWith(referenceIdentifier: '4069_99999_0').internalUserId,
        99999,
      );
      expect(SmartschoolAccount.fromJson(a.toJson()), a);
      // Absent stays absent rather than round-tripping as an empty string.
      expect(_account().toJson().containsKey('referenceIdentifier'), isFalse);
      expect(
        SmartschoolAccount.fromJson(_account().toJson()).referenceIdentifier,
        isNull,
      );
    });
  });

  group('SmartschoolGroup', () {
    SmartschoolGroup node({int? id}) => SmartschoolGroup(
          name: '1A',
          description: 'Klas 1A',
          code: 'C1A',
          id: id,
          type: core.GroupType.classGroup,
          official: true,
          untis: '1A',
          instituteNumber: '30024',
          adminNumber: 12345,
          parentCode: 'SCH',
        );

    test('toCoreGroup carries the Smartschool group id as sourceId (#138)', () {
      final g = node(id: 298).toCoreGroup();
      expect(g.sourceId, 298);
      expect(g.id, const core.GroupId('C1A'));
      expect(g.parentId, const core.GroupId('SCH'));
    });

    test('toCoreGroup leaves sourceId null while the id is unresolved', () {
      expect(node().id, isNull);
      expect(node().toCoreGroup().sourceId, isNull);
    });
  });

  group('SmartschoolMembership', () {
    test('value equality', () {
      const a =
          SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1A'));
      const b =
          SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1A'));
      const c =
          SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1B'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a.accountType, core.AccountType.student);
    });
  });

  group('toString', () {
    test('is informative for each model', () {
      const slot = CoAccountSlot(
        slot: 1,
        firstName: 'Anne',
        lastName: 'L',
        email: '',
        phone: '',
        mobile: '',
        type: 'Moeder',
      );
      expect(slot.toString(), contains('Moeder'));
      expect(_account().toString(), contains('jand'));
      expect(
        const SmartschoolMembership(uid: 'jand', groupId: core.GroupId('C1A'))
            .toString(),
        contains('C1A'),
      );
    });
  });
}
