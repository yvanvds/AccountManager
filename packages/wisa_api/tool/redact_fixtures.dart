/// One-shot redaction script. Reads `artifacts/wisa*.json` (legacy WPF
/// app's cached state — contains real PII) and emits ASCII-only CSV
/// fixtures into `packages/wisa_api/test/fixtures/` in WISA's wire
/// format.
///
/// The output fixtures preserve real-world *value shapes* (class names,
/// date patterns, multi-word surnames, empty-string variants) without
/// retaining any identifying information.
///
/// Run from the repository root:
///
///     dart run packages/wisa_api/tool/redact_fixtures.dart
///
/// The input directory (`artifacts/`) is gitignored. The output (the
/// CSV files under `test/fixtures/`) is committed and used by the
/// `connector_test`.
library;

import 'dart:convert';
import 'dart:io';

/// Number of students to keep in the redacted fixture. Enough to
/// exercise the parser on varied class names and date patterns without
/// bloating the repo.
const int _studentLimit = 100;

/// Number of staff to keep in the redacted fixture.
const int _staffLimit = 100;

void main() {
  final repoRoot = _findRepoRoot();
  final artifactsDir = Directory('${repoRoot.path}/artifacts');
  final outDir = Directory('${repoRoot.path}/packages/wisa_api/test/fixtures');

  if (!artifactsDir.existsSync()) {
    stderr.writeln(
      'artifacts/ not found at ${artifactsDir.path}. '
      'This script needs the legacy JSON state (gitignored, local only).',
    );
    exit(2);
  }

  _writeSchools(artifactsDir, outDir);
  _writeStudents(artifactsDir, outDir);
  _writeStaff(artifactsDir, outDir);
  _writeClassGroups(artifactsDir, outDir);
  _writeTestConnection(outDir);
  stdout.writeln('Wrote redacted fixtures to ${outDir.path}');
}

Directory _findRepoRoot() {
  var d = Directory.current;
  while (true) {
    if (File('${d.path}/pubspec.yaml').existsSync() &&
        Directory('${d.path}/packages').existsSync() &&
        Directory('${d.path}/legacy-wpf').existsSync()) {
      return d;
    }
    final parent = d.parent;
    if (parent.path == d.path) {
      throw StateError(
          'Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}

void _writeSchools(Directory inDir, Directory outDir) {
  final json = jsonDecode(
    File('${inDir.path}/wisaSchools.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final schools = (json['Schools'] as List).cast<Map<String, dynamic>>();
  final buf = StringBuffer('ID,NAME,DESCRIPTION\n');
  for (final s in schools) {
    final id = s['ID'] as int;
    // WISA quirk: its CSV column "NAME" holds the long name, and
    // "DESCRIPTION" holds the short code (see SchoolManager.cs and
    // parseSchoolRow, which untangles it). Emit accordingly. School names are
    // public info (institutional names), not PII — keep verbatim, but
    // strip non-ASCII for encoding-safe fixtures.
    final long = _csvField(_toAscii((s['Description'] as String?) ?? ''));
    final short = _csvField(_toAscii((s['Name'] as String?) ?? ''));
    buf.writeln('$id,$long,$short');
  }
  File('${outDir.path}/sma_get_inst.csv')
      .writeAsStringSync(buf.toString(), flush: true);
}

void _writeStudents(Directory inDir, Directory outDir) {
  final json = jsonDecode(
    File('${inDir.path}/wisaStudents.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final accounts = (json['Accounts'] as List).cast<Map<String, dynamic>>();

  final buf = StringBuffer(
    'KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,STAMBOEKNUMMER,'
    'GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,NATIONALITEIT,STRAAT,STRAATNR,'
    'BUSNR,POSTCODE,WOONPLAATS,KLASWIJZIGING\n',
  );

  final take =
      accounts.length < _studentLimit ? accounts.length : _studentLimit;
  for (var i = 0; i < take; i++) {
    final s = accounts[i];

    // Preserved (not PII or shape-driving):
    final klas = _csvSafe(s['ClassGroup'] as String? ?? '');
    final klasgroep = _csvSafe(s['ClassSubGroup'] as String? ?? '');
    final wisaId = _csvSafe(s['WisaID'] as String? ?? '');
    final stemId = _csvSafe(s['StemID'] as String? ?? '');
    final geboorteDatum = _isoToBelgianDate(s['DateOfBirth'] as String? ?? '');
    final geslacht = (s['Gender'] as String?) == 'Male' ? 'M' : 'V';
    final nationaliteit = _toAscii(s['Nationality'] as String? ?? '');
    final klaswijziging = _isoToBelgianDate(s['ClassChange'] as String? ?? '');
    final straatNr = _csvSafe(s['HouseNumber'] as String? ?? '');
    final busNr = _csvSafe(s['HouseNumberAdd'] as String? ?? '');

    // Redacted: name, place of birth, address text, national ID.
    final naam = _redactSurname(i, s['Name'] as String? ?? '');
    final voornaam = _redactFirstName(i);
    final roepnaam =
        (s['PreferedName'] as String?) == '' ? '' : _redactPreferredName(i);
    const rrn = '00000000000';
    final geboorteplaats = _redactPlace(i, s['PlaceOfBirth'] as String? ?? '');
    final straat = _redactStreet(i);
    const postcode = '0000';
    const woonplaats = 'ANON_CITY';

    buf.writeln(
      [
        klas,
        klasgroep,
        naam,
        voornaam,
        roepnaam,
        geboorteDatum,
        wisaId,
        stemId,
        geslacht,
        rrn,
        geboorteplaats,
        nationaliteit,
        straat,
        straatNr,
        busNr,
        postcode,
        woonplaats,
        klaswijziging,
      ].join(','),
    );
  }
  File('${outDir.path}/sma_sync_lln.csv')
      .writeAsStringSync(buf.toString(), flush: true);
}

void _writeStaff(Directory inDir, Directory outDir) {
  final json = jsonDecode(
    File('${inDir.path}/wisaStaff.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final accounts = (json['Accounts'] as List).cast<Map<String, dynamic>>();

  final buf = StringBuffer('CODE,WISAID,FAMILIENAAM,VOORNAAM\n');
  final take = accounts.length < _staffLimit ? accounts.length : _staffLimit;
  for (var i = 0; i < take; i++) {
    final s = accounts[i];
    final wisaId = _csvSafe(s['WisaID'] as String? ?? '');
    final code = _redactStaffCode(i);
    final lastName = _redactSurname(i, s['LastName'] as String? ?? '');
    final firstName = _redactFirstName(i);
    buf.writeln('$code,$wisaId,$lastName,$firstName');
  }
  File('${outDir.path}/sma_sync_per.csv')
      .writeAsStringSync(buf.toString(), flush: true);
}

/// Class groups whose `OMSCHRIJVING` contains a literal comma. WISA emits
/// these *unquoted*, so the legacy WPF parser mis-split them before caching
/// to `wisaClasses.json` — shifting `AdminCode` and dropping the institute
/// number (issue #29). The cache is therefore an unreliable source for
/// these rows, so we restore WISA's real wire values (captured live against
/// school 25 / ISMAA) keyed by class name. Keep this map in sync with any
/// new comma-bearing descriptions a fresh capture turns up.
const Map<String, ({String description, String adminCode, String schoolCode})>
    _commaDescriptionRepairs = {
  '5OOS': (
    description: '5 Onthaal, organisatie en sales',
    adminCode: '043117',
    schoolCode: '125252',
  ),
  '6OOS': (
    description: '6 Onthaal, organisatie en sales',
    adminCode: '043545',
    schoolCode: '125252',
  ),
};

void _writeClassGroups(Directory inDir, Directory outDir) {
  final json = jsonDecode(
    File('${inDir.path}/wisaClasses.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final groups = (json['Groups'] as List).cast<Map<String, dynamic>>();

  final buf = StringBuffer(
    'KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER\n',
  );
  for (final g in groups) {
    // Class group fields are not PII — class names (`1A`), descriptions
    // (`1ste leerjaar A`), admin/school codes are institutional. WISA emits
    // every field unquoted, including descriptions that contain a literal
    // comma (`5 Onthaal, organisatie en sales`), so we mirror that exactly
    // — no CSV quoting — which keeps the fixture exercising the parser's
    // comma-rejoin path (issue #29).
    final name = _toAscii(g['Name'] as String? ?? '');
    final repair = _commaDescriptionRepairs[name];
    final groupName = _toAscii(g['GroupName'] as String? ?? '');
    final description =
        repair?.description ?? _toAscii(g['Description'] as String? ?? '');
    final adminCode =
        repair?.adminCode ?? _toAscii(g['AdminCode'] as String? ?? '');
    final schoolCode =
        repair?.schoolCode ?? _toAscii(g['SchoolCode'] as String? ?? '');
    buf.writeln('$name,$groupName,$description,$adminCode,$schoolCode');
  }
  File('${outDir.path}/sync_klas.csv')
      .writeAsStringSync(buf.toString(), flush: true);
}

void _writeTestConnection(Directory outDir) {
  // testConnection only checks for a non-empty body. Keep the existing
  // shape — one-line probe response.
  File('${outDir.path}/sma_test_con.csv')
      .writeAsStringSync('RESULT\nOK\n', flush: true);
}

// --- Redaction helpers ---------------------------------------------------

/// Produces a synthetic family name. Every 10th index gets a trailing
/// `" Bis"` token to preserve the legacy edge case of multi-word
/// surnames; every 25th gets a hyphenated form. Other indices are a
/// plain ASCII token.
String _redactSurname(int i, String original) {
  // Length-bucket the synthetic name so we don't always emit identical
  // lengths.
  final base = 'Anon${i.toString().padLeft(4, '0')}';
  if (i % 10 == 0) return '$base Bis';
  if (i % 25 == 0) return '$base-X';
  return base;
}

String _redactFirstName(int i) => 'First${i.toString().padLeft(4, '0')}';

String _redactPreferredName(int i) => 'Pref${i.toString().padLeft(4, '0')}';

/// Synthetic place name; every 7th retains a parenthesised country
/// fragment to keep that legacy edge case (`"Dac (Somalie)"` shape)
/// exercised — but with synthetic place + country names.
String _redactPlace(int i, String original) {
  final base = 'PlaceOfBirth${i.toString().padLeft(4, '0')}';
  if (i % 7 == 0) return '$base (Country${(i % 9).toString().padLeft(2, '0')})';
  return base;
}

String _redactStreet(int i) => 'Anon Street ${i.toString().padLeft(4, '0')}';

/// Synthetic 5-letter staff code. `[A-Z]` only — preserves WISA's
/// observed shape.
String _redactStaffCode(int i) {
  final buf = StringBuffer();
  var n = i;
  for (var pos = 4; pos >= 0; pos--) {
    buf.writeCharCode('A'.codeUnitAt(0) + (n % 26));
    n ~/= 26;
  }
  return buf.toString().split('').reversed.join();
}

/// Converts a legacy JSON date (`YYYY-M-D`) to WISA CSV format
/// (`d/M/yyyy`). Returns empty string for empty input.
String _isoToBelgianDate(String s) {
  if (s.isEmpty) return '';
  final parts = s.split('-');
  if (parts.length != 3) return s;
  final y = parts[0];
  final m = parts[1];
  final d = parts[2];
  return '$d/$m/$y';
}

/// Strips non-ASCII characters (diacritics survive their original
/// position only if equivalent ASCII letter; otherwise replaced with
/// `'?'`). Keeps fixtures encoding-safe regardless of the system Git
/// runs under.
String _toAscii(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r < 0x80) {
      buf.writeCharCode(r);
    } else {
      buf.write(_asciiFold(r));
    }
  }
  return buf.toString();
}

String _asciiFold(int rune) {
  switch (rune) {
    case 0xE0:
    case 0xE1:
    case 0xE2:
    case 0xE3:
    case 0xE4:
    case 0xE5:
      return 'a';
    case 0xC0:
    case 0xC1:
    case 0xC2:
    case 0xC3:
    case 0xC4:
    case 0xC5:
      return 'A';
    case 0xE7:
      return 'c';
    case 0xC7:
      return 'C';
    case 0xE8:
    case 0xE9:
    case 0xEA:
    case 0xEB:
      return 'e';
    case 0xC8:
    case 0xC9:
    case 0xCA:
    case 0xCB:
      return 'E';
    case 0xEC:
    case 0xED:
    case 0xEE:
    case 0xEF:
      return 'i';
    case 0xCC:
    case 0xCD:
    case 0xCE:
    case 0xCF:
      return 'I';
    case 0xF1:
      return 'n';
    case 0xD1:
      return 'N';
    case 0xF2:
    case 0xF3:
    case 0xF4:
    case 0xF5:
    case 0xF6:
      return 'o';
    case 0xD2:
    case 0xD3:
    case 0xD4:
    case 0xD5:
    case 0xD6:
      return 'O';
    case 0xF9:
    case 0xFA:
    case 0xFB:
    case 0xFC:
      return 'u';
    case 0xD9:
    case 0xDA:
    case 0xDB:
    case 0xDC:
      return 'U';
    case 0xFD:
    case 0xFF:
      return 'y';
    case 0xDD:
      return 'Y';
    case 0xDF:
      return 'ss';
    default:
      return '?';
  }
}

/// Strips characters that would corrupt the unquoted CSV format we use
/// (commas, newlines, double quotes). Preserves the original otherwise.
String _csvSafe(String s) =>
    s.replaceAll(',', ' ').replaceAll('"', "'").replaceAll('\n', ' ');

/// CSV-escapes a field: if [s] contains a comma, newline, or double
/// quote, wrap in double quotes and double up any internal quotes.
/// Otherwise return [s] verbatim. Letting some real-world commas
/// survive (in class-group descriptions) intentionally exercises the
/// parser's quoted-field path.
String _csvField(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
