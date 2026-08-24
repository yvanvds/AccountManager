/// Read-only: turns the Smartschool career audit's damage list into a
/// correction sheet, with the 2025-2026 stamboeknummers taken from WISA.
///
/// The Smartschool schoolloopbaan no longer holds the overwritten value — a
/// stamboeknummer write with no school-year parameter landed on the running
/// year's row — so the right number has to come from WISA, which keeps it per
/// enrolment (`inuit.IU_STAMBOEKNUMMER`) and hands back the one valid on the
/// Werkdatum. A Werkdatum inside 2025-2026 therefore yields exactly the value
/// that row should carry.
///
/// Input : `packages/smartschool_api/captures/career-audit/damaged.csv`
///         (rows flagged `suspect=true`), produced by
///         `packages/smartschool_api/tool/career_audit.dart`.
/// Output: `correcties-2025-2026.csv` beside it — name, class, and the
///         correct stamboeknummer, nothing else.
///
/// Read-only: `SMAGetInst` + one `sync` at the given Werkdatum. Never writes.
///
///     dart run packages/wisa_api/tool/correction_list.dart
///     dart run packages/wisa_api/tool/correction_list.dart --werkdatum 2026-03-01
library;

import 'dart:convert';
import 'dart:io';

import 'package:wisa_api/wisa_api.dart';

Future<int> main(List<String> args) async {
  final werkdatum = _dateFlag(args, '--werkdatum') ?? DateTime(2026, 3, 1);

  final config = WisaLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'WISA_USERNAME is not set. Source .wisa.env first '
      '(see .wisa.env.example).',
    );
    return 2;
  }

  final repoRoot = _findRepoRoot();
  final auditDir = Directory(
    '${repoRoot.path}/packages/smartschool_api/captures/career-audit',
  );
  final damagedFile = File('${auditDir.path}/damaged.csv');
  if (!damagedFile.existsSync()) {
    stderr.writeln(
      'Missing ${damagedFile.path}. Run the career audit first:\n'
      '  dart run packages/smartschool_api/tool/career_audit.dart',
    );
    return 2;
  }

  // The rows to repair: one per (student, running-year career row).
  final suspects = <_Suspect>[];
  for (final row in _readCsv(damagedFile.readAsStringSync())) {
    if ((row['suspect'] ?? '') != 'true') continue;
    final rowDate = DateTime.tryParse(row['rowDate'] ?? '');
    suspects.add(
      _Suspect(
        uid: row['uid'] ?? '',
        wisaId: row['wisaId'] ?? '',
        klas: row['klas'] ?? '',
        institute: row['instituteNumber'] ?? '',
        wrongStam: row['stamboeknummerInSmartschool'] ?? '',
        // A row that starts after the default Werkdatum (a mid-year move)
        // needs its own: the enrolment it belongs to is not the one valid
        // on 1 March.
        werkdatum: (rowDate != null && rowDate.isAfter(werkdatum))
            ? rowDate
            : werkdatum,
      ),
    );
  }
  stdout.writeln('Rows flagged by the audit: ${suspects.length}');
  if (suspects.isEmpty) return 0;

  final connector = config.connector();
  final schools = await connector.loadSchools();
  stdout.writeln('Schools: ${schools.length}');

  // One pull per distinct Werkdatum — normally just the default.
  final dates = {for (final s in suspects) s.werkdatum}.toList()..sort();
  final byDate = <DateTime, Map<String, WisaStudent>>{};
  for (final date in dates) {
    stdout.writeln('Pulling WISA at Werkdatum ${formatWerkdatum(date)}…');
    final snapshot = await connector.sync(schools: schools, workDate: date);
    byDate[date] = {for (final s in snapshot.students) s.wisaId.value: s};
    stdout.writeln('  ${snapshot.students.length} enrolled students');
  }

  final out = StringBuffer('Naam,Klas,Stamboeknummer\n');
  final missing = <_Suspect>[];
  final classMismatch = <String>[];
  var alreadyCorrect = 0;
  var written = 0;

  for (final suspect in suspects) {
    final student = byDate[suspect.werkdatum]?[suspect.wisaId];
    if (student == null) {
      missing.add(suspect);
      continue;
    }
    // Only rows that actually differ from what Smartschool holds today.
    if (student.stemId == suspect.wrongStam) {
      alreadyCorrect++;
      continue;
    }
    // WISA splits the class into code + subgroup ("2A" + "ECO") where
    // Smartschool carries the joined name. A difference in neither form
    // means the student also changed class during 2025-2026.
    final joined = student.classSubGroup.isEmpty
        ? student.classGroup
        : '${student.classGroup} ${student.classSubGroup}';
    if (suspect.klas != student.classGroup && suspect.klas != joined) {
      classMismatch.add(
        '${student.name} ${student.firstName}: '
        'Smartschool "${suspect.klas}" vs WISA "$joined"',
      );
    }
    out.writeln(
      '"${student.name} ${student.firstName}",'
      '"${suspect.klas}",'
      '${student.stemId}',
    );
    written++;
  }

  final outFile = File('${auditDir.path}/correcties-2025-2026.csv')
    ..writeAsStringSync(out.toString());

  stdout
    ..writeln()
    ..writeln('Already correct in Smartschool (skipped): $alreadyCorrect')
    ..writeln('Written : $written rows -> ${outFile.path}');

  if (classMismatch.isNotEmpty) {
    stdout.writeln(
      'Class differs between Smartschool and WISA (${classMismatch.length}) — '
      'check which loopbaan row to edit:',
    );
    for (final line in classMismatch) {
      stdout.writeln('  $line');
    }
  }
  if (missing.isNotEmpty) {
    stdout.writeln(
      'Not enrolled in WISA at this Werkdatum (${missing.length}) — '
      'needs a manual lookup:',
    );
    for (final s in missing) {
      stdout.writeln(
        '  ${s.uid} (wisaId ${s.wisaId}, klas ${s.klas}, '
        'instelling ${s.institute}, staat nu op ${s.wrongStam})',
      );
    }
  }
  return 0;
}

class _Suspect {
  final String uid;
  final String wisaId;
  final String klas;
  final String institute;
  final String wrongStam;

  /// The Werkdatum whose enrolment this career row belongs to.
  final DateTime werkdatum;

  _Suspect({
    required this.uid,
    required this.wisaId,
    required this.klas,
    required this.institute,
    required this.wrongStam,
    required this.werkdatum,
  });
}

/// Minimal RFC-4180 reader: the audit writes quoted names and class codes.
List<Map<String, String>> _readCsv(String text) {
  final lines = const LineSplitter().convert(text)
    ..removeWhere((l) => l.trim().isEmpty);
  if (lines.isEmpty) return const [];
  final header = _splitCsvLine(lines.first);
  final rows = <Map<String, String>>[];
  for (final line in lines.skip(1)) {
    final fields = _splitCsvLine(line);
    rows.add({
      for (var i = 0; i < header.length; i++)
        header[i]: i < fields.length ? fields[i] : '',
    });
  }
  return rows;
}

List<String> _splitCsvLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (c == ',' && !inQuotes) {
      fields.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  fields.add(buffer.toString());
  return fields;
}

DateTime? _dateFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  final parsed = DateTime.tryParse(args[i + 1]);
  if (parsed == null) {
    throw ArgumentError('$name is not an ISO-8601 date: "${args[i + 1]}"');
  }
  return parsed;
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/packages').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate the repository root.');
    }
    dir = parent;
  }
}
