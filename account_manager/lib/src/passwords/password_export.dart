import 'dart:io';
import 'dart:typed_data';

import 'package:account_state/account_state.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Writes an export payload under [suggestedName] and returns the path it was
/// written to. Injected so the Passwords screen can be driven headlessly (a
/// test records the calls) while production writes real files to disk.
///
/// Takes bytes rather than a string because the printable sheets are PDFs
/// (#195); the co-account CSV is UTF-8 encoded by the caller.
typedef PasswordFileWriter = Future<String> Function(
  String suggestedName,
  List<int> bytes,
);

/// Opens an already-written export with whatever the platform associates with
/// its file type — for a password sheet, the PDF viewer, one keystroke away
/// from the printer. Injected alongside [PasswordFileWriter] so a headless test
/// records the call instead of launching a viewer.
typedef PasswordFileOpener = Future<void> Function(String path);

/// The directory password exports are written to.
///
/// Deliberately **not** the system temp directory (#195): cleartext password
/// sheets are the most sensitive artefact this app produces, and `%TEMP%` is a
/// place nothing owns and nothing cleans up. They land in a known, operator-
/// owned folder instead — `Documents\AccountManager\Wachtwoorden` — which the
/// operator can find, print from, and delete.
String passwordExportDirectory() {
  final String home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  final String sep = Platform.pathSeparator;
  final Directory documents = Directory('$home${sep}Documents');
  final String base = documents.existsSync() ? documents.path : home;
  return '$base${sep}AccountManager${sep}Wachtwoorden';
}

/// The default [PasswordFileWriter]: writes into [passwordExportDirectory] and
/// returns the absolute path. A timestamp prefix keeps successive exports from
/// overwriting each other.
Future<String> writePasswordExport(
  String suggestedName,
  List<int> bytes,
) async {
  final dir = Directory(passwordExportDirectory())..createSync(recursive: true);
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('.', '')
      .replaceAll('-', '');
  final file =
      File('${dir.path}${Platform.pathSeparator}${stamp}_$suggestedName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// The default [PasswordFileOpener]: hands [path] to the platform default
/// handler, so an exported sheet lands in the PDF viewer ready to print.
///
/// A plain process launch on purpose — the `printing` plugin would add native
/// Windows code to the build for the same result.
Future<void> openPasswordExport(String path) async {
  final (String executable, List<String> arguments) =
      switch (Platform.operatingSystem) {
    // `start` needs an (empty) window-title argument before the file, else a
    // quoted path is swallowed as the title.
    'windows' => ('cmd', <String>['/c', 'start', '', path]),
    'macos' => ('open', <String>[path]),
    _ => ('xdg-open', <String>[path]),
  };
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}

// ---------------------------------------------------------------------------
// Sheet model
// ---------------------------------------------------------------------------

/// One `label: value` line of a [PasswordSheetBlock], rendered monospaced so
/// the login and the password line up on the printed sheet.
class PasswordSheetField {
  const PasswordSheetField(this.label, this.value);

  final String label;
  final String value;
}

/// One section of a [PasswordSheet] — the Office 365, Smartschool, WiFi, or
/// privacy block. A section that has no password to show is simply not built,
/// which is how the sheets omit blocks.
class PasswordSheetBlock {
  const PasswordSheetBlock({
    this.heading = '',
    this.intro = const <String>[],
    this.fields = const <PasswordSheetField>[],
    this.notes = const <String>[],
  });

  /// The section heading. Empty for the leading login line, which sits directly
  /// under the sheet title.
  final String heading;

  /// Prose shown above the fields ("Aanmelden via office.com.").
  final List<String> intro;

  /// The monospaced `label: value` lines.
  final List<PasswordSheetField> fields;

  /// Prose shown below the fields (the one-time-password note).
  final List<String> notes;
}

/// One printed page: everything one person is handed on paper.
class PasswordSheet {
  const PasswordSheet({required this.title, required this.blocks});

  final String title;
  final List<PasswordSheetBlock> blocks;
}

const String _oneTimeNote = 'Dit is een eenmalig wachtwoord; kies zelf een '
    'nieuw wachtwoord bij de eerste aanmelding.';

/// The WiFi block, or `null` when [wifi] has no SSID to print (#368).
///
/// The label is **Code** on both sheets, deliberately. Legacy said "Wachtwoord"
/// to students and "Code" to staff, which was a leftover rather than a decision:
/// every other `Wachtwoord` line on a sheet is personal, one-time, and sits
/// under a note telling the reader to change it at first sign-in. The network
/// key is none of those things — it is shared, permanent, and the same on every
/// sheet in the stack — so it reads as what it is on both.
PasswordSheetBlock? _wifiBlock(WifiNetwork wifi) {
  if (!wifi.isConfigured) return null;
  return PasswordSheetBlock(
    heading: 'WiFi',
    fields: <PasswordSheetField>[
      PasswordSheetField('Netwerk', wifi.ssid),
      PasswordSheetField('Code', wifi.code),
    ],
  );
}

/// The student sheets, one per queued entry, ported from the legacy
/// `PasswordManager.exportToPDF` layout (#180) and kept identical in content
/// and section order when the format became a real PDF (#195): the login, the
/// Office 365 and Smartschool blocks (only for the passwords that were actually
/// generated), a WiFi block, and a privacy note.
///
/// [wifi] is the network the sheet tells students to join, read from the
/// settings document (#368). It defaults to the literal these sheets carried
/// before it was configurable, so a caller that knows nothing about settings —
/// and a settings document written before the field existed — prints what it
/// always printed. An unconfigured network omits the block, like the two
/// password blocks above it.
List<PasswordSheet> studentPasswordSheets(
  Iterable<PasswordEntry> entries, {
  WifiNetwork wifi = defaultStudentWifi,
}) {
  final sheets = <PasswordSheet>[];
  for (final e in entries) {
    final klas = e.classGroup;
    final title = klas != null && klas.isNotEmpty
        ? 'Account voor ${e.displayName} - $klas'
        : 'Account voor ${e.displayName}';
    final blocks = <PasswordSheetBlock>[
      PasswordSheetBlock(
        fields: <PasswordSheetField>[
          PasswordSheetField('Login', e.accountName),
        ],
      ),
    ];
    final azure = e.azurePassword;
    if (azure != null && azure.isNotEmpty) {
      blocks.add(PasswordSheetBlock(
        heading: 'Office 365',
        intro: const <String>['Aanmelden via office.com.'],
        fields: <PasswordSheetField>[
          PasswordSheetField('Login', e.mail ?? e.accountName),
          PasswordSheetField('Wachtwoord', azure),
        ],
        notes: const <String>[_oneTimeNote],
      ));
    }
    final ss = e.smartschoolPassword;
    if (ss != null && ss.isNotEmpty) {
      blocks.add(PasswordSheetBlock(
        heading: 'Smartschool',
        intro: const <String>['Aanmelden via de Smartschool-website of -app.'],
        fields: <PasswordSheetField>[
          PasswordSheetField('Login', e.accountName),
          PasswordSheetField('Wachtwoord', ss),
        ],
        notes: const <String>[_oneTimeNote],
      ));
    }
    final wifiBlock = _wifiBlock(wifi);
    if (wifiBlock != null) blocks.add(wifiBlock);
    blocks.add(const PasswordSheetBlock(
      heading: 'Privacy',
      notes: <String>[
        'Hou je wachtwoord geheim en deel het met niemand — ook niet met '
            'leerkrachten.',
      ],
    ));
    sheets.add(PasswordSheet(title: title, blocks: blocks));
  }
  return sheets;
}

/// The single-staff sheet, ported from legacy `ExportStaffPasswordToPDF`
/// (#180). A `null` password omits that whole block, which is how the three
/// staff reset buttons choose which sections appear.
///
/// [wifi] is the staff network, read from the settings document (#368) and
/// defaulting to the literal this sheet carried before it was configurable.
PasswordSheet staffPasswordSheet({
  required String name,
  required String username,
  required String mail,
  String? smartschoolPassword,
  String? office365Password,
  WifiNetwork wifi = defaultStaffWifi,
}) {
  final blocks = <PasswordSheetBlock>[];
  if (office365Password != null && office365Password.isNotEmpty) {
    blocks.add(PasswordSheetBlock(
      heading: 'Office 365',
      fields: <PasswordSheetField>[
        PasswordSheetField('Login', mail),
        PasswordSheetField('Wachtwoord', office365Password),
      ],
      notes: const <String>[_oneTimeNote],
    ));
  }
  final wifiBlock = _wifiBlock(wifi);
  if (wifiBlock != null) blocks.add(wifiBlock);
  if (smartschoolPassword != null && smartschoolPassword.isNotEmpty) {
    blocks.add(PasswordSheetBlock(
      heading: 'Smartschool',
      fields: <PasswordSheetField>[
        PasswordSheetField('Login', username),
        PasswordSheetField('Wachtwoord', smartschoolPassword),
      ],
      notes: const <String>[_oneTimeNote],
    ));
  }
  blocks.add(const PasswordSheetBlock(
    heading: 'Privacy',
    notes: <String>[
      'Hou je wachtwoord geheim en deel het met niemand — ook niet aan '
          "collega's.",
    ],
  ));
  return PasswordSheet(title: 'Account voor $name', blocks: blocks);
}

// ---------------------------------------------------------------------------
// PDF rendering
// ---------------------------------------------------------------------------

/// The three typefaces a sheet is set in.
///
/// The PDF base-14 faces (Helvetica / Courier) only carry Latin-1, so every
/// Turkish, Polish, or Croatian name — the names this school hands sheets to
/// every September — would print as a row of empty boxes. The design system
/// already ships Latin-Extended faces with the app, so the sheets are typeset
/// in the product's own fonts and no extra binary joins the repo.
class PasswordSheetFonts {
  const PasswordSheetFonts({
    required this.body,
    required this.heading,
    required this.mono,
  });

  /// Prose: the intro lines and the one-time-password / privacy notes.
  final pw.Font body;

  /// The sheet title and the section headings.
  final pw.Font heading;

  /// The `label : value` credential lines, so login and password line up.
  final pw.Font mono;

  static const String _bodyAsset =
      'packages/plink_design_system/fonts/hanken-grotesk/'
      'HankenGrotesk-Variable.ttf';
  static const String _headingAsset =
      'packages/plink_design_system/fonts/space-mono/SpaceMono-Bold.ttf';
  static const String _monoAsset =
      'packages/plink_design_system/fonts/space-mono/SpaceMono-Regular.ttf';

  static PasswordSheetFonts? _cached;

  /// The PDF base-14 faces. Latin-1 only — used solely as the last-resort
  /// stand-in when the bundled fonts cannot be read, because a sheet with a
  /// mangled name still beats no sheet at all.
  static PasswordSheetFonts fallback() => PasswordSheetFonts(
        body: pw.Font.helvetica(),
        heading: pw.Font.helveticaBold(),
        mono: pw.Font.courier(),
      );

  /// Reads the bundled faces once and caches them: parsing a TrueType file per
  /// export would be paid on every print.
  static Future<PasswordSheetFonts> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      return _cached = PasswordSheetFonts(
        body: pw.Font.ttf(await rootBundle.load(_bodyAsset)),
        heading: pw.Font.ttf(await rootBundle.load(_headingAsset)),
        mono: pw.Font.ttf(await rootBundle.load(_monoAsset)),
      );
    } on Object {
      return fallback();
    }
  }
}

/// Renders [sheets] as an A4 PDF, one page per sheet.
///
/// Typeset in [PasswordSheetFonts.load]'s bundled faces unless [fonts] says
/// otherwise. [compress] is a test seam: with it off the page content streams
/// stay plain text, so a unit test can read what was actually drawn —
/// production always ships the compressed document.
Future<Uint8List> passwordSheetsPdf(
  List<PasswordSheet> sheets, {
  required String title,
  bool compress = true,
  PasswordSheetFonts? fonts,
}) async {
  final faces = fonts ?? await PasswordSheetFonts.load();
  final doc = pw.Document(title: title, compress: compress);
  if (sheets.isEmpty) {
    // Never emit a page-less PDF: viewers refuse to open one, and the operator
    // would be left staring at an error instead of an empty sheet.
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (context) => pw.Text(
        'Geen wachtwoorden om af te drukken.',
        style: pw.TextStyle(font: faces.body, fontSize: 11),
      ),
    ));
  }
  for (final sheet in sheets) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (context) => _sheetColumn(sheet, faces),
    ));
  }
  return doc.save();
}

/// The student sheets as a PDF — one page per student, on the configured
/// student [wifi] network (#368).
Future<Uint8List> studentPasswordsPdf(
  Iterable<PasswordEntry> entries, {
  WifiNetwork wifi = defaultStudentWifi,
}) =>
    passwordSheetsPdf(
      studentPasswordSheets(entries, wifi: wifi),
      title: 'Leerling-wachtwoorden',
    );

/// A single staff member sheet as a one-page PDF, on the configured staff
/// [wifi] network (#368).
Future<Uint8List> staffPasswordPdf({
  required String name,
  required String username,
  required String mail,
  String? smartschoolPassword,
  String? office365Password,
  WifiNetwork wifi = defaultStaffWifi,
}) =>
    passwordSheetsPdf(
      <PasswordSheet>[
        staffPasswordSheet(
          name: name,
          username: username,
          mail: mail,
          smartschoolPassword: smartschoolPassword,
          office365Password: office365Password,
          wifi: wifi,
        ),
      ],
      title: 'Personeelswachtwoord — $name',
    );

pw.Widget _sheetColumn(PasswordSheet sheet, PasswordSheetFonts fonts) {
  final children = <pw.Widget>[
    pw.Text(sheet.title,
        style: pw.TextStyle(font: fonts.heading, fontSize: 16)),
    pw.Divider(thickness: 1),
  ];
  for (final block in sheet.blocks) {
    if (block.heading.isNotEmpty) {
      children.add(pw.SizedBox(height: 14));
      children.add(pw.Text(
        block.heading,
        style: pw.TextStyle(font: fonts.heading, fontSize: 12),
      ));
      children.add(pw.SizedBox(height: 4));
    }
    for (final line in block.intro) {
      children.add(pw.Text(
        line,
        style: pw.TextStyle(font: fonts.body, fontSize: 11),
      ));
      children.add(pw.SizedBox(height: 4));
    }
    // Pad the labels so `Login` and `Wachtwoord` line up under each other, the
    // way the legacy <pre> block did.
    final width = block.fields.fold<int>(
      0,
      (widest, f) => f.label.length > widest ? f.label.length : widest,
    );
    for (final field in block.fields) {
      children.add(pw.Text(
        '${field.label.padRight(width)} : ${field.value}',
        style: pw.TextStyle(font: fonts.mono, fontSize: 11),
      ));
    }
    if (block.notes.isNotEmpty) {
      children.add(pw.SizedBox(height: 4));
    }
    for (final note in block.notes) {
      children.add(pw.Text(
        note,
        style: pw.TextStyle(font: fonts.body, fontSize: 11),
      ));
    }
  }
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: children,
  );
}

// ---------------------------------------------------------------------------
// Co-account CSV
// ---------------------------------------------------------------------------

/// The co-account CSV, ported from legacy `PasswordManager.exportToCSV`
/// (#180): a `;`-separated file with a header row and one row per co-account
/// entry, columns `Gebruikersnaam;Naam;Klas;CoAccount1..CoAccount6`. Slots that
/// were not regenerated are left blank.
///
/// Stays a CSV on purpose (#195) — it is fed to other tooling, not printed.
String coAccountsCsv(Iterable<PasswordEntry> entries) {
  final lines = <String>[
    'Gebruikersnaam;Naam;Klas;CoAccount1;CoAccount2;CoAccount3;'
        'CoAccount4;CoAccount5;CoAccount6',
  ];
  for (final e in entries) {
    final cells = <String>[
      _csv(e.accountName),
      _csv(e.displayName),
      _csv(e.classGroup ?? ''),
      for (var slot = 1; slot <= 6; slot++)
        _csv(e.coAccountPasswords[slot] ?? ''),
    ];
    lines.add(cells.join(';'));
  }
  return '${lines.join('\n')}\n';
}

/// Escapes a CSV cell for the `;`-separated legacy format: a cell containing a
/// separator, quote, or newline is quoted with doubled inner quotes.
String _csv(String s) {
  if (s.contains(';') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
