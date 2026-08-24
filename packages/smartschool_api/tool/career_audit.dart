/// Read-only diagnostic: audits Smartschool *schoolloopbaan* rows
/// (`getStudentCareer`) to establish which career row a stamboeknummer write
/// lands on.
///
/// Background. `saveUser` carries `$stamboeknummer` with no school-year
/// parameter (unlike `saveClass`, which takes `$schoolYearDate`), while the
/// Smartschool schoolloopbaan stores one stamnummer *per row*. When the WISA
/// werkdatum is moved to the next school year before 1 September, the
/// next-year number can land on the still-running year — which is what a
/// school reported for 2025-2026.
///
/// The open question is *which* row Smartschool targets:
///
///   * **last row** — then doing the class move first protects the running
///     year, and ordering the actions is a complete fix;
///   * **current school year** — then ordering changes nothing and the
///     historical rows of *earlier* cross-school movers are corrupted too.
///
/// Earlier years were synced class-moves-first, so their movers decide it:
/// if their old rows still carry the old school's stamnummer, the "last row"
/// model holds.
///
/// Read-only — `sync` + `getStudentCareer`, never a write. Run from anywhere
/// in the repo after sourcing `.smartschool.env`:
///
///     dart run packages/smartschool_api/tool/career_audit.dart --probe
///     dart run packages/smartschool_api/tool/career_audit.dart
///     dart run packages/smartschool_api/tool/career_audit.dart --refresh
///
/// Flags: `--probe` dumps one raw career and stops; `--refresh` re-pulls the
/// group/account sync; `--limit N` caps the students fetched;
/// `--concurrency N` (default 6) bounds parallel SOAP calls.
///
/// Output goes to `packages/smartschool_api/captures/career-audit/`
/// (gitignored — it holds real pupil data straight from Smartschool).
library;

import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';

const String _careerMethod = 'getStudentCareer';

Future<int> main(List<String> args) async {
  final probe = args.contains('--probe');
  final refresh = args.contains('--refresh');
  final limit = _intFlag(args, '--limit');
  final concurrency = _intFlag(args, '--concurrency') ?? 6;

  final config = SmartschoolLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'SMARTSCHOOL_ACCESSCODE is not set. Source .smartschool.env first '
      '(see .smartschool.env.example).',
    );
    return 2;
  }

  final outDir = Directory(
    '${_findRepoRoot().path}/packages/smartschool_api/captures/career-audit',
  )..createSync(recursive: true);
  stdout.writeln('Output: ${outDir.path}');

  final snapshot = await _loadSnapshot(config, outDir, refresh: refresh);
  final students = [
    for (final a in snapshot.accounts)
      if (a.role == core.PersonRole.student) a,
  ];
  stdout.writeln(
    'Snapshot: ${snapshot.groups.length} groups, '
    '${snapshot.accounts.length} accounts, ${students.length} students.',
  );

  final credentials = SmartschoolCredentials(
    site: config.site,
    accessCode: config.accessCode,
  );
  final transport = HttpSmartschoolSoapTransport();

  if (probe) {
    for (final student in students.take(5)) {
      final raw = await _fetchCareer(transport, credentials, student.uid);
      if (raw == null) continue;
      final file = File('${outDir.path}/sample-career.json');
      file.writeAsStringSync(raw);
      stdout
        ..writeln('Probe: wrote ${student.uid}\'s career to ${file.path}')
        ..writeln(_summariseShape(raw));
      transport.close();
      return 0;
    }
    stderr.writeln('Probe: no student returned a career payload.');
    transport.close();
    return 1;
  }

  final cacheFile = File('${outDir.path}/careers.jsonl');
  final cached = _readCache(cacheFile);
  stdout.writeln('Cached careers: ${cached.length}');

  final todo = [
    for (final s in students)
      if (!cached.containsKey(s.uid)) s.uid,
  ];
  final batch = limit == null ? todo : todo.take(limit).toList();
  if (batch.isNotEmpty) {
    stdout.writeln(
      'Fetching ${batch.length} careers (concurrency $concurrency)…',
    );
    final sink = cacheFile.openWrite(mode: FileMode.append);
    var done = 0;
    var failed = 0;
    await _pooled(batch, concurrency, (uid) async {
      String? raw;
      try {
        raw = await _fetchCareer(transport, credentials, uid);
      } on Object catch (e) {
        failed++;
        stderr.writeln('  ! $uid: ${redactAccessCode(e.toString())}');
      }
      if (raw != null) {
        cached[uid] = raw;
        sink.writeln(jsonEncode({'uid': uid, 'career': raw}));
      }
      done++;
      if (done % 100 == 0) {
        stdout.writeln('  … $done/${batch.length}');
      }
    });
    await sink.flush();
    await sink.close();
    stdout.writeln('Fetched $done careers ($failed failed).');
  }
  transport.close();

  _report(cached, snapshot, outDir);
  return 0;
}

// ---------------------------------------------------------------------------
// SOAP
// ---------------------------------------------------------------------------

/// One `getStudentCareer` call. Returns the raw JSON payload, or `null` when
/// Smartschool answered with a bare status code instead (no career on file).
Future<String?> _fetchCareer(
  SmartschoolSoapTransport transport,
  SmartschoolCredentials credentials,
  String uid,
) async {
  final responseXml = await transport.send(
    endpoint: credentials.endpoint,
    soapAction: soapActionFor(credentials.namespace, _careerMethod),
    envelope: buildRpcEnvelope(
      namespace: credentials.namespace,
      method: _careerMethod,
      args: [
        SoapArg.string('accesscode', credentials.accessCode),
        SoapArg.string('userIdentifier', uid),
      ],
    ),
  );
  final ret = decodeReturn(responseXml);
  final text = ret.text.trim();
  if (text.isEmpty || ret.isInt) return null;
  return text;
}

// ---------------------------------------------------------------------------
// Snapshot cache
// ---------------------------------------------------------------------------

Future<SmartschoolSnapshot> _loadSnapshot(
  SmartschoolLiveConfig config,
  Directory outDir, {
  required bool refresh,
}) async {
  final file = File('${outDir.path}/snapshot.json');
  if (!refresh && file.existsSync()) {
    stdout.writeln('Reusing cached snapshot (--refresh to re-pull).');
    return SmartschoolSnapshot.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }
  stdout.writeln('Running a full Smartschool sync (minutes on a real tenant)…');
  final snapshot = await config.connector().sync();
  file.writeAsStringSync(jsonEncode(snapshot.toJson()));
  return snapshot;
}

Map<String, String> _readCache(File file) {
  if (!file.existsSync()) return {};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      final row = jsonDecode(line) as Map<String, dynamic>;
      result[row['uid'] as String] = row['career'] as String;
    } on Object {
      // A truncated final line from an interrupted run: skip it.
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Career parsing
// ---------------------------------------------------------------------------

/// One schoolloopbaan row, reduced to the four fields this audit needs.
class _Row {
  final DateTime? date;
  final String institute;
  final String stam;
  final String className;

  _Row(this.date, this.institute, this.stam, this.className);

  /// The school year a row belongs to: September starts a new one.
  int? get schoolYear {
    final d = date;
    if (d == null) return null;
    return d.month >= 9 ? d.year : d.year - 1;
  }

  @override
  String toString() => '${_ymd(date)}  ${className.padRight(10)} '
      'inst=${institute.padRight(8)} stam=$stam';
}

/// Pulls the rows out of a career payload. Smartschool's exact key names are
/// discovered rather than hard-coded — [_summariseShape] prints them so a
/// contract change surfaces as "0 rows" instead of silently wrong output.
List<_Row> _parseCareer(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on Object {
    return const [];
  }
  final maps = _rowMaps(decoded);
  final rows = <_Row>[];
  for (final m in maps) {
    final date = _pick(m, const ['datum', 'date', 'van', 'start']);
    final institute =
        _pick(m, const ['instell', 'institute', 'schoolnummer', 'inst']);
    final stam = _pick(m, const ['stam']);
    // `groupname` first: `inClass` would otherwise win the 'class' needle.
    final className =
        _pick(m, const ['groupname', 'klas', 'classname', 'group', 'groep']);
    if (date.isEmpty && institute.isEmpty && stam.isEmpty) continue;
    rows.add(
      _Row(DateTime.tryParse(date), institute, stam, className),
    );
  }
  rows.sort((a, b) {
    final x = a.date, y = b.date;
    if (x == null || y == null) return 0;
    return x.compareTo(y);
  });
  return rows;
}

/// Finds the list-of-objects inside a decoded payload, whether the career
/// arrives as a bare list or wrapped in an envelope object.
List<Map<String, dynamic>> _rowMaps(dynamic decoded) {
  if (decoded is List) {
    return [
      for (final e in decoded)
        if (e is Map<String, dynamic>) e,
    ];
  }
  if (decoded is Map<String, dynamic>) {
    for (final value in decoded.values) {
      if (value is List) {
        final rows = _rowMaps(value);
        if (rows.isNotEmpty) return rows;
      }
    }
    // A single-row career may arrive unwrapped.
    return [decoded];
  }
  return const [];
}

/// First value whose key contains one of [needles] (case-insensitive),
/// stringified and trimmed. Empty when nothing matches.
String _pick(Map<String, dynamic> row, List<String> needles) {
  for (final needle in needles) {
    for (final entry in row.entries) {
      if (!entry.key.toLowerCase().contains(needle)) continue;
      final v = entry.value;
      if (v == null) continue;
      final s = '$v'.trim();
      if (s.isNotEmpty) return s;
    }
  }
  return '';
}

String _summariseShape(String raw) {
  final decoded = jsonDecode(raw);
  final rows = _rowMaps(decoded);
  final keys = <String>{for (final r in rows) ...r.keys};
  return 'Shape: ${decoded.runtimeType}, ${rows.length} row(s)\n'
      'Keys: ${keys.join(', ')}\n'
      'Parsed rows:\n${_parseCareer(raw).map((r) => '  $r').join('\n')}';
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

void _report(
  Map<String, String> careers,
  SmartschoolSnapshot snapshot,
  Directory outDir,
) {
  final buffer = StringBuffer();
  var parsed = 0;
  var empty = 0;

  // A "mover" has rows at more than one instellingsnummer.
  final movers = <String, List<_Row>>{};
  for (final entry in careers.entries) {
    final rows = _parseCareer(entry.value);
    if (rows.isEmpty) {
      empty++;
      continue;
    }
    parsed++;
    final institutes = {
      for (final r in rows)
        if (r.institute.isNotEmpty) r.institute,
    };
    if (institutes.length > 1) movers[entry.key] = rows;
  }

  // The running school year — the one a pre-1-September write can damage —
  // and the one starting on the coming 1 September.
  final now = DateTime.now();
  final runningYear = now.month >= 9 ? now.year : now.year - 1;
  final comingYear = runningYear + 1;

  // A stamboeknummer is issued per school, so the same number appearing under
  // two instellingsnummers is the damage signature: a write meant for one
  // school year landed on a row belonging to the other school.
  final byBucket = <int, List<String>>{};
  final damagedUids = <String>[];
  final healthy = <int, int>{};

  for (final entry in movers.entries) {
    final uid = entry.key;
    final rows = entry.value;

    final institutesPerStam = <String, Set<String>>{};
    for (final r in rows) {
      if (r.stam.isEmpty || r.institute.isEmpty) continue;
      (institutesPerStam[r.stam] ??= <String>{}).add(r.institute);
    }
    final damaged = institutesPerStam.values.any((s) => s.length > 1);

    // The school year each institute change takes effect in.
    final switchYears = <int>{};
    String? previous;
    for (final r in rows) {
      if (r.institute.isEmpty) continue;
      if (previous != null && r.institute != previous) {
        final y = r.schoolYear;
        if (y != null) switchYears.add(y);
      }
      previous = r.institute;
    }
    final latest = switchYears.isEmpty ? -1 : switchYears.reduce(_max);

    final block = StringBuffer()
      ..writeln('$uid  (switch in ${switchYears.join(', ')}) '
          '${damaged ? '<<< DAMAGED' : 'ok'}');
    for (final r in rows) {
      block.writeln('    $r');
    }
    (byBucket[latest] ??= []).add(block.toString());
    if (damaged) {
      damagedUids.add(uid);
    } else {
      healthy[latest] = (healthy[latest] ?? 0) + 1;
    }
  }

  final names = {
    for (final a in snapshot.accounts)
      a.uid: '${a.surname} ${a.givenName}'.trim(),
  };

  final headline = StringBuffer()
    ..writeln('Careers fetched : ${careers.length}')
    ..writeln('Parsed with rows: $parsed  (empty/unparsed: $empty)')
    ..writeln('Cross-school movers: ${movers.length}')
    ..writeln()
    ..writeln('Per school year the switch takes effect in '
        '(a "damaged" career reuses one stamnummer across two '
        'instellingsnummers):');
  for (final year in byBucket.keys.toList()..sort()) {
    final total = byBucket[year]!.length;
    final ok = healthy[year] ?? 0;
    final label = year == comingYear
        ? '$year-${year + 1}  (the coming year — synced this summer)'
        : '$year-${year + 1}';
    headline.writeln(
      '  $label: $total movers, ${total - ok} damaged, $ok ok',
    );
  }

  buffer.write(headline);
  for (final year in byBucket.keys.toList()..sort()) {
    buffer
      ..writeln()
      ..writeln('=== Switch effective $year-${year + 1} ===')
      ..writeln(byBucket[year]!.join('\n'));
  }

  final reportFile = File('${outDir.path}/report.txt')
    ..writeAsStringSync(buffer.toString());

  // Correction list: Smartschool no longer holds the overwritten value, so it
  // carries the WISA id (the Smartschool internal number, by operator
  // convention) to look the right one up with a werkdatum inside that year.
  final accountsByUid = {for (final a in snapshot.accounts) a.uid: a};
  final csv = StringBuffer(
    'uid,wisaId,name,schoolYear,rowDate,klas,instituteNumber,'
    'stamboeknummerInSmartschool,suspect\n',
  );
  for (final uid in damagedUids) {
    final rows = movers[uid]!;
    // The write lands on the career's last row, which before 1 September is
    // still the running year's. So the row to repair is the running-year one
    // carrying a stamnummer that belongs to the other school.
    final institutesPerStam = <String, Set<String>>{};
    for (final r in rows) {
      if (r.stam.isEmpty || r.institute.isEmpty) continue;
      (institutesPerStam[r.stam] ??= <String>{}).add(r.institute);
    }
    for (final row in rows) {
      final year = row.schoolYear;
      if (year == null) continue;
      final suspect =
          year == runningYear && (institutesPerStam[row.stam]?.length ?? 0) > 1;
      csv.writeln(
        '$uid,${accountsByUid[uid]?.accountId ?? ''},'
        '"${names[uid] ?? ''}",$year-${year + 1},${_ymd(row.date)},'
        '"${row.className}",${row.institute},${row.stam},$suspect',
      );
    }
  }
  final csvFile = File('${outDir.path}/damaged.csv')
    ..writeAsStringSync(csv.toString());

  stdout
    ..writeln()
    ..write(headline)
    ..writeln()
    ..writeln('Damaged careers: ${damagedUids.length}')
    ..writeln('Full per-student detail: ${reportFile.path}')
    ..writeln('Correction list        : ${csvFile.path}');
}

int _max(int a, int b) => a > b ? a : b;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<void> _pooled<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T) body,
) async {
  var index = 0;
  Future<void> worker() async {
    while (true) {
      final i = index++;
      if (i >= items.length) return;
      await body(items[i]);
    }
  }

  await Future.wait([
    for (var k = 0; k < concurrency; k++) worker(),
  ]);
}

int? _intFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return int.tryParse(args[i + 1]);
}

String _ymd(DateTime? d) => d == null
    ? '??????????'
    : '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

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
