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
      expect(a.referenceIdentifier, isNull);
      expect(a.internalUserId, isNull);
    });

    test('keeps the referenceIdentifier and splits out the user id (#138)', () {
      final a = parseSmartschoolAccount(const {
        'Gebruikersnaam': 'gulinv',
        'referenceIdentifier': '4069_12016_0',
      });
      expect(a.referenceIdentifier, '4069_12016_0');
      expect(a.internalUserId, 12016);
    });

    test('reads the referenceIdentifier whatever its wire casing (#138)', () {
      // The lookup is case-insensitive like every other field (see #37).
      final a = parseSmartschoolAccount(const {
        'gebruikersnaam': 'gulinv',
        'referenceidentifier': '4069_12016_0',
      });
      expect(a.internalUserId, 12016);
    });

    test('a malformed referenceIdentifier is kept raw, id null (#138)', () {
      // Older tenants can truncate the field; it must not fail the parse.
      final a = parseSmartschoolAccount(const {
        'gebruikersnaam': 'saral',
        'referenceIdentifier': '4069',
      });
      expect(a.referenceIdentifier, '4069');
      expect(a.internalUserId, isNull);
    });

    test('an empty referenceIdentifier reads as absent, not as "" (#138)', () {
      final a = parseSmartschoolAccount(const {
        'gebruikersnaam': 'saral',
        'referenceIdentifier': '',
      });
      expect(a.referenceIdentifier, isNull);
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

  group('parseSmartschoolGroupIds', () {
    test('reads the per-account groups array (#138)', () {
      final ids = parseSmartschoolGroupIds(const {
        'gebruikersnaam': 'gulinv',
        'groups': [
          {'id': '298', 'code': 'SSM1A', 'name': '1A'},
          {'id': '4', 'code': 'LLN', 'name': 'Leerlingen'},
        ],
      });
      expect(ids, {'SSM1A': 298, 'LLN': 4});
    });

    test('accepts an int id and trims the code', () {
      final ids = parseSmartschoolGroupIds(const {
        'GROUPS': [
          {'ID': 298, 'CODE': '  SSM1A  '},
        ],
      });
      expect(ids, {'SSM1A': 298});
    });

    test('skips rows without a usable code or numeric id', () {
      final ids = parseSmartschoolGroupIds(const {
        'groups': [
          {'id': '298'},
          {'code': 'NOID'},
          {'id': 'abc', 'code': 'BAD'},
          {'id': '', 'code': 'EMPTY'},
          'not-a-map',
          {'id': '7', 'code': 'OK'},
        ],
      });
      expect(ids, {'OK': 7});
    });

    test('returns an empty map when the payload carries no groups', () {
      expect(parseSmartschoolGroupIds(const {'gebruikersnaam': 'x'}), isEmpty);
      expect(parseSmartschoolGroupIds(const {'groups': 'nonsense'}), isEmpty);
    });
  });

  group('parseSmartschoolAccountPayload', () {
    test('returns accounts and the union of their group ids (#138)', () {
      final payload = parseSmartschoolAccountPayload(
        '[{"gebruikersnaam":"a","groups":[{"id":"101","code":"C1A"}]},'
        '{"gebruikersnaam":"b","groups":[{"id":"401","code":"GSPORT"},'
        '{"id":"101","code":"C1A"}]}]',
      );
      expect(payload.accounts.map((a) => a.uid), ['a', 'b']);
      expect(payload.groupIds, {'C1A': 101, 'GSPORT': 401});
    });

    test('throws on a non-array payload', () {
      expect(
        () => parseSmartschoolAccountPayload('{"gebruikersnaam":"a"}'),
        throwsA(isA<FormatException>()),
      );
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
