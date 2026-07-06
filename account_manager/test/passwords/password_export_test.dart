import 'package:account_manager/src/passwords/password_export.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';

PasswordEntry _account({
  String uid = 'jane.doe',
  String name = 'Jane Doe',
  String? mail = 'jane@student.school',
  String klas = '3C',
  String? ss = 'Sa2b!x',
  String? az = 'Ku9d?y',
}) =>
    PasswordEntry(
      personId: PersonId('ss:$uid'),
      kind: PasswordAccountKind.account,
      accountName: uid,
      displayName: name,
      mail: mail,
      classGroup: klas,
      smartschoolPassword: ss,
      azurePassword: az,
    );

PasswordEntry _co({
  String uid = 'jane.doe',
  String name = 'Jane Doe',
  String klas = '3C',
  Map<int, String> co = const {1: 'Aa1!', 3: 'Cc3?'},
}) =>
    PasswordEntry(
      personId: PersonId('ss:$uid'),
      kind: PasswordAccountKind.coAccount,
      accountName: uid,
      displayName: name,
      classGroup: klas,
      coAccountPasswords: co,
    );

void main() {
  group('coAccountsCsv', () {
    test('emits the legacy header and one row per entry, blank for unset slots',
        () {
      final csv = coAccountsCsv([_co()]);
      final lines = csv.trim().split('\n');
      expect(
        lines.first,
        'Gebruikersnaam;Naam;Klas;CoAccount1;CoAccount2;CoAccount3;'
        'CoAccount4;CoAccount5;CoAccount6',
      );
      // slot 1 and 3 filled; 2, 4, 5, 6 blank.
      expect(lines[1], 'jane.doe;Jane Doe;3C;Aa1!;;Cc3?;;;');
    });

    test('quotes a cell containing the separator', () {
      final csv = coAccountsCsv([_co(name: 'Doe; Jane')]);
      expect(csv, contains('"Doe; Jane"'));
    });
  });

  group('studentPasswordsHtml', () {
    test('includes only the blocks for the passwords that were generated', () {
      final html = studentPasswordsHtml([_account(az: null)]);
      expect(html, contains('Jane Doe'));
      expect(html, contains('Smartschool'));
      // No Azure password → no Office 365 login block for this student.
      expect(html, isNot(contains('Ku9d?y')));
      expect(html, contains('Sa2b!x'));
    });

    test('escapes HTML-special characters in a name', () {
      final html = studentPasswordsHtml([_account(name: 'A & B <x>')]);
      expect(html, contains('A &amp; B &lt;x&gt;'));
    });
  });

  group('staffPasswordHtml', () {
    test('omits the block for a null password', () {
      final html = staffPasswordHtml(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        office365Password: null,
      );
      expect(html, contains('Smartschool'));
      expect(html, contains('Zz9!'));
      expect(html, isNot(contains('Office 365')));
    });
  });
}
