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

    test('reads the live lowercase wire keys (regression #37)', () {
      // The live getAllAccountsExtended payload uses lowercase keys. Reading
      // the exact-cased keys returned null for every field, so all accounts
      // collapsed to one empty-uid record. The lookup must be
      // case-insensitive (Newtonsoft semantics).
      final a = parseSmartschoolAccount(const {
        'gebruikersnaam': 'boecks',
        'internnummer': '13429',
        'emailadres': 'seth@school.be',
        'basisrol': '1',
        'voornaam': 'Seth',
        'naam': 'Deboeck',
        'geslacht': 'm',
        'status': 'actief',
      });
      expect(a.uid, 'boecks');
      expect(a.accountId, '13429');
      expect(a.mail, 'seth@school.be');
      expect(a.role, core.PersonRole.student);
      expect(a.givenName, 'Seth');
      expect(a.surname, 'Deboeck');
    });

    test('drops empty co-account slots that carry the integer 0 type', () {
      // Live empty slots send `"type_coaccountN": 0` (an int), not an empty
      // string; it must still read as empty so the slot is dropped.
      final a = parseSmartschoolAccount(const {
        'gebruikersnaam': 'boecks',
        'voornaam_coaccount1': 'Johan',
        'naam_coaccount1': 'Deboeck',
        'email_coaccount1': 'johan@example.be',
        'type_coaccount1': 'Vader',
        'voornaam_coaccount3': '',
        'naam_coaccount3': '',
        'email_coaccount3': '',
        'type_coaccount3': 0,
      });
      expect(a.coAccounts.map((c) => c.slot), [1]);
      expect(a.coAccounts.single.type, 'Vader');
      expect(a.coAccounts.single.email, 'johan@example.be');
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
