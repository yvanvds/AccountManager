import 'dart:convert';

import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

Address _addr({String street = 'Kerkstraat', String? add}) => Address(
      street: street,
      houseNumber: '12',
      houseNumberAdd: add,
      postalCode: '2000',
      city: 'Antwerpen',
      country: 'BE',
    );

void main() {
  group('Address.streetAddress (Smartschool concat)', () {
    test('without houseNumberAdd ⇒ "street houseNumber"', () {
      expect(_addr().streetAddress, equals('Kerkstraat 12'));
    });

    test('with houseNumberAdd ⇒ "street houseNumber/add"', () {
      expect(_addr(add: '3B').streetAddress, equals('Kerkstraat 12/3B'));
    });

    test('empty street is preserved (legacy parity)', () {
      // Matches legacy AccountManager.cs lines 57-59: the connector
      // unconditionally concatenates whatever the model holds. The connector
      // boundary is not where we sanitise empty addresses.
      expect(_addr(street: '').streetAddress, equals(' 12'));
      expect(_addr(street: '', add: '3').streetAddress, equals(' 12/3'));
    });

    test('empty houseNumberAdd ⇒ skipped (treated like null)', () {
      expect(_addr(add: '').streetAddress, equals('Kerkstraat 12'));
    });

    test('empty houseNumber ⇒ no leading space, no slash branch', () {
      const a = Address(
        street: 'Kerkstraat',
        houseNumber: '',
        postalCode: '2000',
        city: 'Antwerpen',
        country: 'BE',
      );
      expect(a.streetAddress, equals('Kerkstraat'));
    });
  });

  group('Address JSON round-trip', () {
    test('all fields populated', () {
      final a = _addr(add: '3B');
      expect(Address.fromJson(a.toJson()), equals(a));
    });

    test('omits houseNumberAdd when null', () {
      final a = _addr();
      expect(a.toJson().containsKey('houseNumberAdd'), isFalse);
      expect(Address.fromJson(a.toJson()), equals(a));
    });

    test('survives encode/decode through dart:convert', () {
      final a = _addr(add: '3B');
      final encoded = jsonEncode(a.toJson());
      final decoded =
          Address.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded, equals(a));
    });
  });

  group('Address equality', () {
    test('value equality, not reference', () {
      expect(_addr(), equals(_addr()));
      expect(_addr().hashCode, equals(_addr().hashCode));
    });

    test('differs when any field differs', () {
      expect(_addr(add: 'A'), isNot(equals(_addr(add: 'B'))));
      expect(_addr(street: 'X'), isNot(equals(_addr(street: 'Y'))));
    });
  });

  group('Person JSON round-trip', () {
    test('minimal Person (only required fields)', () {
      const p = Person(
        id: PersonId('p1'),
        role: PersonRole.student,
        givenName: 'Anna',
        surname: 'Janssens',
        gender: Gender.female,
      );
      expect(Person.fromJson(p.toJson()), equals(p));
    });

    test('Person with every optional field populated', () {
      final p = Person(
        id: const PersonId('p2'),
        role: PersonRole.teacher,
        givenName: 'Bert',
        surname: 'De Vries',
        preferredName: 'Bertje',
        gender: Gender.male,
        birthDate: DateTime.utc(1985, 3, 17),
        birthPlace: 'Gent',
        birthCountry: 'BE',
        address: _addr(add: '3B'),
        mobilePhone: '+32 470 12 34 56',
        homePhone: '03 555 22 11',
        nationalId: '85.03.17-123.45',
      );
      expect(Person.fromJson(p.toJson()), equals(p));
    });

    test('omits null optionals from JSON', () {
      const p = Person(
        id: PersonId('p3'),
        role: PersonRole.it,
        givenName: 'Carla',
        surname: 'Peeters',
        gender: Gender.x,
      );
      final json = p.toJson();
      expect(json.containsKey('preferredName'), isFalse);
      expect(json.containsKey('birthDate'), isFalse);
      expect(json.containsKey('address'), isFalse);
    });
  });

  group('Person equality', () {
    test('same content ⇒ equal, different gender ⇒ not equal', () {
      const a = Person(
        id: PersonId('p1'),
        role: PersonRole.student,
        givenName: 'A',
        surname: 'B',
        gender: Gender.female,
      );
      const b = Person(
        id: PersonId('p1'),
        role: PersonRole.student,
        givenName: 'A',
        surname: 'B',
        gender: Gender.female,
      );
      const c = Person(
        id: PersonId('p1'),
        role: PersonRole.student,
        givenName: 'A',
        surname: 'B',
        gender: Gender.male,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
