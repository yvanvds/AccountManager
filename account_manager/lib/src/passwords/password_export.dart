import 'dart:io';

import 'package:account_state/account_state.dart';

/// Writes an export payload under [suggestedName] and returns the path it was
/// written to. Injected so the Passwords screen can be driven headlessly (a
/// test records the calls) while production writes real files to disk.
typedef PasswordFileWriter = Future<String> Function(
  String suggestedName,
  String content,
);

/// The default [PasswordFileWriter]: writes into a per-run `AccountManager`
/// folder under the system temp directory and returns the absolute path. A
/// timestamp prefix keeps successive exports from overwriting each other.
Future<String> writePasswordExport(String suggestedName, String content) async {
  final dir = Directory('${Directory.systemTemp.path}/AccountManager');
  dir.createSync(recursive: true);
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('.', '')
      .replaceAll('-', '');
  final file = File('${dir.path}/${stamp}_$suggestedName');
  await file.writeAsString(content);
  return file.path;
}

/// The co-account CSV, ported from legacy `PasswordManager.exportToCSV`
/// (#180): a `;`-separated file with a header row and one row per co-account
/// entry, columns `Gebruikersnaam;Naam;Klas;CoAccount1..CoAccount6`. Slots that
/// were not regenerated are left blank.
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

/// A printable HTML sheet with one section per student, ported from the legacy
/// `PasswordManager.exportToPDF` layout (#180) but rendered as browser-printable
/// HTML — the operator opens it and prints, avoiding a native PDF dependency.
/// Each section shows the login, the Office 365 and Smartschool blocks (only
/// for the passwords that were generated), a WiFi block, and a privacy note.
String studentPasswordsHtml(Iterable<PasswordEntry> entries) {
  final sections = <String>[];
  for (final e in entries) {
    final buf = StringBuffer()
      ..writeln('<section>')
      ..writeln(
          '<h1>Account voor ${_html(e.displayName)}${e.classGroup != null && e.classGroup!.isNotEmpty ? ' - ${_html(e.classGroup!)}' : ''}</h1>')
      ..writeln('<pre>Login     : ${_html(e.accountName)}</pre>');
    final azure = e.azurePassword;
    if (azure != null && azure.isNotEmpty) {
      buf
        ..writeln('<h2>Office 365</h2>')
        ..writeln('<p>Aanmelden via office.com.</p>')
        ..writeln(
            '<pre>Login     : ${_html(e.mail ?? e.accountName)}\nWachtwoord: ${_html(azure)}</pre>')
        ..writeln('<p>Dit is een eenmalig wachtwoord; kies zelf een nieuw '
            'wachtwoord bij de eerste aanmelding.</p>');
    }
    final ss = e.smartschoolPassword;
    if (ss != null && ss.isNotEmpty) {
      buf
        ..writeln('<h2>Smartschool</h2>')
        ..writeln('<p>Aanmelden via de Smartschool-website of -app.</p>')
        ..writeln(
            '<pre>Login     : ${_html(e.accountName)}\nWachtwoord: ${_html(ss)}</pre>')
        ..writeln('<p>Dit is een eenmalig wachtwoord; kies zelf een nieuw '
            'wachtwoord bij de eerste aanmelding.</p>');
    }
    buf
      ..writeln('<h2>WiFi</h2>')
      ..writeln('<pre>Netwerk   : Smifi-L\nWachtwoord: SmifiDeWifi:)</pre>')
      ..writeln('<h2>Privacy</h2>')
      ..writeln('<p>Hou je wachtwoord geheim en deel het met niemand — ook '
          'niet met leerkrachten.</p>')
      ..writeln('</section>');
    sections.add(buf.toString());
  }
  return _htmlDocument('Leerling-wachtwoorden', sections.join('\n'));
}

/// A single-staff printable HTML sheet, ported from legacy
/// `ExportStaffPasswordToPDF` (#180). A `null` password omits that whole block,
/// which is how the three staff reset buttons choose which sections appear.
String staffPasswordHtml({
  required String name,
  required String username,
  required String mail,
  String? smartschoolPassword,
  String? office365Password,
}) {
  final buf = StringBuffer()
    ..writeln('<section>')
    ..writeln('<h1>Account voor ${_html(name)}</h1>');
  if (office365Password != null && office365Password.isNotEmpty) {
    buf
      ..writeln('<h2>Office 365</h2>')
      ..writeln(
          '<pre>Login     : ${_html(mail)}\nWachtwoord: ${_html(office365Password)}</pre>')
      ..writeln('<p>Dit is een eenmalig wachtwoord; kies zelf een nieuw '
          'wachtwoord bij de eerste aanmelding.</p>');
  }
  buf
    ..writeln('<h2>WiFi</h2>')
    ..writeln('<pre>Netwerk   : Smifi-P\nCode      : !TEAM!SMA!</pre>');
  if (smartschoolPassword != null && smartschoolPassword.isNotEmpty) {
    buf
      ..writeln('<h2>Smartschool</h2>')
      ..writeln(
          '<pre>Login     : ${_html(username)}\nWachtwoord: ${_html(smartschoolPassword)}</pre>')
      ..writeln('<p>Dit is een eenmalig wachtwoord; kies zelf een nieuw '
          'wachtwoord bij de eerste aanmelding.</p>');
  }
  buf
    ..writeln('<h2>Privacy</h2>')
    ..writeln('<p>Hou je wachtwoord geheim en deel het met niemand — ook '
        'niet aan collega\'s.</p>')
    ..writeln('</section>');
  return _htmlDocument('Personeelswachtwoord — $name', buf.toString());
}

String _htmlDocument(String title, String body) => '<!doctype html>\n'
    '<html lang="nl"><head><meta charset="utf-8">'
    '<title>${_html(title)}</title>'
    '<style>body{font-family:sans-serif;margin:2rem;}'
    'section{page-break-after:always;margin-bottom:2rem;}'
    'h1{font-size:1.4rem;border-bottom:1px solid #333;}'
    'pre{font-family:monospace;font-size:1rem;}</style>'
    '</head><body>\n$body\n</body></html>\n';

/// Escapes the five XML/HTML special characters. Passwords only ever contain
/// `!?*`, letters, and digits, but names may carry `&`/`<`/`>`.
String _html(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// Escapes a CSV cell for the `;`-separated legacy format: a cell containing a
/// separator, quote, or newline is quoted with doubled inner quotes.
String _csv(String s) {
  if (s.contains(';') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
