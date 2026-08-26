import 'dart:convert';
import 'dart:io';

import 'package:account_manager/src/passwords/password_export.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';

PasswordEntry _account({
  String uid = 'jane.doe',
  String name = 'Jane Doe',
  String? mail = 'jane@student.school',
  String klas = '3C',
  String? ss = 'Sa2b!x',
  String? az = 'Ku9dQy',
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

/// The headings of a sheet, in the order they are printed. The leading login
/// block carries no heading, so it shows up as an empty string.
List<String> _headings(PasswordSheet sheet) =>
    <String>[for (final b in sheet.blocks) b.heading];

/// Every field value on a sheet, flattened — used to assert a password made it
/// onto (or stayed off) the page.
List<String> _values(PasswordSheet sheet) => <String>[
      for (final b in sheet.blocks)
        for (final f in b.fields) f.value,
    ];

/// The `label: value` pairs of the sheet's WiFi block.
List<(String, String)> _wifiFields(PasswordSheet sheet) => <(String, String)>[
      for (final b in sheet.blocks)
        if (b.heading == 'WiFi')
          for (final f in b.fields) (f.label, f.value),
    ];

/// The number of page objects in a rendered PDF. Page dictionaries are written
/// plainly even in a compressed document, so this reads the real production
/// bytes.
int _pageCount(List<int> bytes) =>
    RegExp(r'/Type\s*/Page(?!s)').allMatches(latin1.decode(bytes)).length;

/// The crossed-box placeholder the renderer draws for a glyph the font has no
/// outline for: a stroked rectangle at line width 1.
final RegExp _missingGlyph = RegExp(r're\s+1 w\s+S');

void main() {
  // Loading the bundled sheet fonts reads package assets through rootBundle.
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('studentPasswordSheets', () {
    test('builds one sheet per entry, titled with the name and class', () {
      final sheets = studentPasswordSheets(
        [_account(), _account(uid: 'bob', name: 'Bob Bee', klas: '4A')],
      );
      expect(sheets, hasLength(2));
      expect(sheets[0].title, 'Account voor Jane Doe - 3C');
      expect(sheets[1].title, 'Account voor Bob Bee - 4A');
    });

    test(
        'keeps the legacy section order: login, O365, Smartschool, WiFi, '
        'privacy', () {
      final sheet = studentPasswordSheets([_account()]).single;
      expect(_headings(sheet),
          <String>['', 'Office 365', 'Smartschool', 'WiFi', 'Privacy']);
      // The headingless first block is the login line.
      expect(sheet.blocks.first.fields.single.label, 'Login');
      expect(sheet.blocks.first.fields.single.value, 'jane.doe');
    });

    test('includes only the blocks for the passwords that were generated', () {
      final sheet = studentPasswordSheets([_account(az: null)]).single;
      expect(_headings(sheet), isNot(contains('Office 365')));
      expect(_headings(sheet), contains('Smartschool'));
      expect(_values(sheet), contains('Sa2b!x'));
      expect(_values(sheet), isNot(contains('Ku9dQy')));
    });

    test('the Office 365 block logs in with the mail address', () {
      final sheet = studentPasswordSheets([_account(ss: null)]).single;
      final office = sheet.blocks.firstWhere((b) => b.heading == 'Office 365');
      expect(office.fields.first.value, 'jane@student.school');
      expect(office.fields.last.value, 'Ku9dQy');
    });

    test('the WiFi block prints the configured network (#368)', () {
      final sheet = studentPasswordSheets(
        [_account()],
        wifi: const WifiNetwork(ssid: 'Testnet-L', code: 'l-sleutel'),
      ).single;
      expect(_wifiFields(sheet), <(String, String)>[
        ('Netwerk', 'Testnet-L'),
        ('Code', 'l-sleutel'),
      ]);
    });

    test('an unconfigured network omits the whole WiFi block (#368)', () {
      // No half-empty block and no bare `Netwerk :` line — the block simply is
      // not built, exactly as an ungenerated password omits its own.
      final sheet = studentPasswordSheets(
        [_account()],
        wifi: const WifiNetwork(code: 'orphan-key'),
      ).single;
      expect(_headings(sheet),
          <String>['', 'Office 365', 'Smartschool', 'Privacy']);
      expect(_values(sheet), isNot(contains('orphan-key')));
    });

    test('the default network is the literal the sheets used to hardcode', () {
      // The upgrade path: a settings document written before #368 carries no
      // WiFi fields, and every caller that passes none must still print what it
      // always printed.
      final sheet = studentPasswordSheets([_account()]).single;
      expect(_wifiFields(sheet), <(String, String)>[
        ('Netwerk', 'Smifi-L'),
        ('Code', 'SmifiDeWifi:)'),
      ]);
    });

    test('a name with markup characters is carried through verbatim', () {
      // The HTML sheet had to escape these; a PDF string does not, so the
      // operator sees the real name.
      final sheet = studentPasswordSheets([_account(name: 'A & B <x>')]).single;
      expect(sheet.title, 'Account voor A & B <x> - 3C');
    });
  });

  group('staffPasswordSheet', () {
    test('omits the block for a null password', () {
      final sheet = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        office365Password: null,
      );
      expect(_headings(sheet), <String>['WiFi', 'Smartschool', 'Privacy']);
      expect(_values(sheet), contains('Zz9!'));
    });

    test('both passwords give both blocks, in the legacy order', () {
      final sheet = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        office365Password: 'Qq1?',
      );
      expect(_headings(sheet),
          <String>['Office 365', 'WiFi', 'Smartschool', 'Privacy']);
    });

    test('the WiFi block prints the configured staff network (#368)', () {
      final sheet = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        wifi: const WifiNetwork(ssid: 'Testnet-P', code: 'p-sleutel'),
      );
      expect(_wifiFields(sheet), <(String, String)>[
        ('Netwerk', 'Testnet-P'),
        ('Code', 'p-sleutel'),
      ]);
    });

    test('an unconfigured staff network omits the block (#368)', () {
      final sheet = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        wifi: const WifiNetwork(),
      );
      expect(_headings(sheet), <String>['Smartschool', 'Privacy']);
    });

    test('the default staff network is the literal it used to hardcode', () {
      final sheet = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
      );
      expect(_wifiFields(sheet), <(String, String)>[
        ('Netwerk', 'Smifi-P'),
        ('Code', '!TEAM!SMA!'),
      ]);
    });
  });

  group('the WiFi key label', () {
    test('reads "Code" on both sheets, not "Wachtwoord" (#368)', () {
      // A deliberate unification, not a leftover: legacy said "Wachtwoord" to
      // students and "Code" to staff for the same shared network key. Every
      // other `Wachtwoord` line on a sheet is personal, one-time, and carries a
      // note telling the reader to change it at first sign-in — the network key
      // is none of those, and now says so on both sheets.
      const wifi = WifiNetwork(ssid: 'Net', code: 'sleutel');
      final student = studentPasswordSheets([_account()], wifi: wifi).single;
      final staff = staffPasswordSheet(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        wifi: wifi,
      );
      expect(
          _wifiFields(student).map((f) => f.$1), <String>['Netwerk', 'Code']);
      expect(_wifiFields(staff).map((f) => f.$1), <String>['Netwerk', 'Code']);
    });
  });

  group('PDF rendering', () {
    test('student sheets render as a PDF with one page per student', () async {
      final bytes = await studentPasswordsPdf(
        [_account(), _account(uid: 'bob', name: 'Bob Bee')],
      );
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(latin1.decode(bytes).trimRight(), endsWith('%%EOF'));
      expect(_pageCount(bytes), 2);
    });

    test('the per-staff sheet renders as a one-page PDF', () async {
      final bytes = await staffPasswordPdf(
        name: 'Anna Smit',
        username: 'anna.smit',
        mail: 'anna@school',
        smartschoolPassword: 'Zz9!',
        office365Password: null,
      );
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(_pageCount(bytes), 1);
    });

    test('an empty queue still renders one openable page, not a page-less file',
        () async {
      final bytes = await studentPasswordsPdf(const <PasswordEntry>[]);
      expect(_pageCount(bytes), 1);
    });

    test('the password really lands on the page', () async {
      // Rendered uncompressed and with the base-14 faces, which draw literal
      // text into the content stream, so the test can read what was put on the
      // page: the generated password and the login must both be there.
      final bytes = await passwordSheetsPdf(
        studentPasswordSheets([_account(az: null)]),
        title: 'Leerling-wachtwoorden',
        compress: false,
        fonts: PasswordSheetFonts.fallback(),
      );
      final stream = latin1.decode(bytes);
      expect(stream, contains('(Sa2b!x)'));
      expect(stream, contains('(jane.doe)'));
      expect(stream, contains('(Smartschool)'));
      // No Azure password was generated, so it is nowhere on the sheet.
      expect(stream, isNot(contains('(Ku9dQy)')));
    });

    test('the configured WiFi network really lands on the page (#368)',
        () async {
      // Same uncompressed / base-14 seam as above, so the test reads the words
      // actually drawn: the sheet is the only artefact this app puts on paper,
      // and a WiFi block that silently kept the old literal would be discovered
      // in front of a class.
      final stream = latin1.decode(await passwordSheetsPdf(
        studentPasswordSheets(
          [_account()],
          wifi: const WifiNetwork(ssid: 'Testnet-L', code: 'l-sleutel'),
        ),
        title: 'Leerling-wachtwoorden',
        compress: false,
        fonts: PasswordSheetFonts.fallback(),
      ));
      expect(stream, contains('(Testnet-L)'));
      expect(stream, contains('(l-sleutel)'));
      expect(stream, isNot(contains('(Smifi-L)')));
    });

    test('an unconfigured WiFi network prints no WiFi heading (#368)',
        () async {
      final stream = latin1.decode(await passwordSheetsPdf(
        studentPasswordSheets([_account()], wifi: const WifiNetwork()),
        title: 'Leerling-wachtwoorden',
        compress: false,
        fonts: PasswordSheetFonts.fallback(),
      ));
      expect(stream, isNot(contains('(WiFi)')));
      expect(stream, isNot(contains('(Netwerk)')));
    });
  });

  group('export destination', () {
    test('is a known operator-owned folder, never the system temp dir (#195)',
        () {
      // Cleartext password sheets used to accumulate in %TEMP%\AccountManager,
      // which nothing owns and nothing cleans up.
      final dir = passwordExportDirectory();
      expect(dir, isNot(contains(Directory.systemTemp.path)));
      expect(dir, contains('AccountManager'));
      expect(dir, endsWith('Wachtwoorden'));
    });
  });

  group('sheet fonts', () {
    test('the bundled design-system faces load, not the base-14 stand-ins',
        () async {
      final fonts = await PasswordSheetFonts.load();
      expect(fonts.body.fontName, contains('HankenGrotesk'));
      expect(fonts.heading.fontName, contains('SpaceMono'));
      expect(fonts.mono.fontName, contains('SpaceMono'));
    });

    test('a name outside Latin-1 prints as glyphs, not empty boxes', () async {
      // Turkish and Polish names are routine here, and every one of them falls
      // outside the Latin-1 range the PDF base-14 faces carry. Rendering the
      // same sheet with those faces is the proof: it fills the page with
      // missing-glyph boxes, which is what the bundled fonts fix.
      final sheets = studentPasswordSheets([_account(name: 'Işık Ćwik')]);
      final good = latin1.decode(await passwordSheetsPdf(
        sheets,
        title: 'Leerling-wachtwoorden',
        compress: false,
      ));
      final base14 = latin1.decode(await passwordSheetsPdf(
        sheets,
        title: 'Leerling-wachtwoorden',
        compress: false,
        fonts: PasswordSheetFonts.fallback(),
      ));
      expect(_missingGlyph.hasMatch(base14), isTrue,
          reason: 'the base-14 faces cannot draw these names');
      expect(_missingGlyph.hasMatch(good), isFalse,
          reason: 'the bundled faces cover Latin Extended');
    });
  });
}
