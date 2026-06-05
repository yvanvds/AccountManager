import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('parseSmartschoolAccount', () {
    test('maps every flat field', () {
      final a = parseSmartschoolAccount(const {
        'Gebruikersnaam': 'jand',
        'Internnummer': 'W001',
        'Emailadres': 'jan@school.be',
        'Rijksregisternummer': '10030512345',
        'Stamboeknummer': '123456',
        'Basisrol': '1',
        'Voornaam': 'Jan',
        'Naam': 'Desmet',
        'Extravoornamen': 'Jan Baptist',
        'Initialen': 'J.B.',
        'Roepnaam': 'Jantje',
        'Geslacht': 'm',
        'Geboortedatum': '2010-3-5',
        'Geboorteplaats': 'Leuven',
        'Geboorteland': 'België',
        'Straat': 'Kerkstraat',
        'Huisnummer': '12',
        'Busnummer': 'A',
        'Postcode': '3000',
        'Woonplaats': 'Leuven',
        'Land': 'België',
        'Mobielnummer': '0470111222',
        'Telefoonnummer': '016111222',
        'Fax': '016999',
        'Status': 'actief',
      });
      expect(a.uid, 'jand');
      expect(a.accountId, 'W001');
      expect(a.mail, 'jan@school.be');
      expect(a.registerId, '10030512345');
      expect(a.stemId, 123456);
      expect(a.role, core.PersonRole.student);
      expect(a.givenName, 'Jan');
      expect(a.surname, 'Desmet');
      expect(a.extraNames, 'Jan Baptist');
      expect(a.initials, 'J.B.');
      expect(a.preferredName, 'Jantje');
      expect(a.gender, core.Gender.male);
      expect(a.birthDate, DateTime(2010, 3, 5));
      expect(a.birthPlace, 'Leuven');
      expect(a.birthCountry, 'België');
      expect(a.address.streetAddress, 'Kerkstraat 12/A');
      expect(a.address.postalCode, '3000');
      expect(a.address.city, 'Leuven');
      expect(a.mobilePhone, '0470111222');
      expect(a.homePhone, '016111222');
      expect(a.fax, '016999');
      expect(a.status, 'actief');
      expect(a.accountType, core.AccountType.student);
    });

    test('missing fields become empty strings, stemId 0', () {
      final a = parseSmartschoolAccount(const {'Gebruikersnaam': 'x'});
      expect(a.uid, 'x');
      expect(a.mail, '');
      expect(a.accountId, '');
      expect(a.stemId, 0);
      expect(a.role, isNull);
      expect(a.preferredName, '');
      expect(a.birthDate, isNull);
      expect(a.coAccounts, isEmpty);
    });

    test('preserves co-account slots, dropping empty ones', () {
      final a = parseSmartschoolAccount(const {
        'Gebruikersnaam': 'saral',
        'Voornaam_coaccount1': 'Anne',
        'Naam_coaccount1': 'Lemmens',
        'Email_coaccount1': 'anne@example.be',
        'Telefoonnummer_coaccount1': '016',
        'Mobielnummer_coaccount1': '0470',
        'Type_coaccount1': 'Moeder',
        'Type_coaccount2': '',
        'Voornaam_coaccount3': 'Peter',
        'Naam_coaccount3': 'Lemmens',
        'Type_coaccount3': 'Vader',
      });
      expect(a.coAccounts.map((c) => c.slot), [1, 3]);
      final mother = a.coAccounts.first;
      expect(mother.firstName, 'Anne');
      expect(mother.type, 'Moeder');
      expect(mother.email, 'anne@example.be');
      expect(mother.accountType, core.AccountType.coAccount1);
      expect(a.coAccounts.last.accountType, core.AccountType.coAccount3);
    });
  });

  group('parseSmartschoolAccounts', () {
    test('parses a JSON array', () {
      final list = parseSmartschoolAccounts(
        '[{"Gebruikersnaam":"a"},{"Gebruikersnaam":"b"}]',
      );
      expect(list.map((a) => a.uid), ['a', 'b']);
    });

    test('throws on a non-array payload', () {
      expect(
        () => parseSmartschoolAccounts('{"Gebruikersnaam":"a"}'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
