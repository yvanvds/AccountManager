/// Read-only diagnostic: for each named school, pull the raw `SyncKlas`
/// rows (before `_dedupeClassGroups` runs) and report, per class, which
/// KLASGROEP codes and which ADMINGROEP codes WISA actually returns.
///
/// The question it answers: is the "does this class use sub-groups?"
/// decision better keyed on "has a non-`00` KLASGROEP row" than on the
/// legacy "more than one distinct ADMINGROEP"? (2G LAT vs 2F STEMW.)
///
/// Read-only: `SMAGetInst` + one `sync` per school. Never writes, and
/// prints no personal data — class codes and counts only.
///
///     dart run packages/wisa_api/tool/klasgroep_audit.dart ismaa ismab
library;

import 'dart:io';

import 'package:wisa_api/wisa_api.dart';

Future<int> main(List<String> args) async {
  final wanted = (args.isEmpty ? const ['ismaa', 'ismab'] : args)
      .map((s) => s.toLowerCase())
      .toList();

  final config = WisaLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln('WISA_USERNAME is not set. Source .wisa.env first.');
    return 2;
  }
  final workDate = config.resolveWorkDate(DateTime.now());

  final recorder = _SyncKlasRecorder(HttpWisaSoapTransport());
  final connector = WisaConnector.fromParts(
    server: config.server,
    port: config.port,
    database: config.database,
    username: config.username,
    password: config.password,
    transport: recorder,
  );

  final schools = await connector.loadSchools();
  stdout.writeln('Werkdatum: ${formatWerkdatum(workDate)}');
  stdout.writeln('Schools reachable with these credentials:');
  for (final s in schools) {
    stdout.writeln('  id=${s.id}  code=${s.code}  name=${s.name}');
  }

  final targets = [
    for (final s in schools)
      if (wanted.contains(s.code.toLowerCase()) ||
          wanted.any((w) => s.name.toLowerCase().contains(w)))
        s,
  ];
  if (targets.isEmpty) {
    stderr.writeln('\nNo school matched ${wanted.join(', ')}.');
    return 1;
  }

  for (final school in targets) {
    stdout.writeln('\n${'=' * 72}');
    stdout.writeln('== ${school.code} (id=${school.id}) — ${school.name}');
    stdout.writeln('=' * 72);

    recorder.reset();
    final snapshot = await connector.sync(
      schools: [school],
      workDate: workDate,
    );
    final csv = recorder.csv;
    if (csv == null || csv.isEmpty) {
      stderr.writeln('  no SyncKlas payload captured — skipped.');
      continue;
    }

    final rows = _parseRaw(csv);
    stdout.writeln('  raw SyncKlas rows        : ${rows.length}');
    stdout.writeln('  rows after dedupe (app)  : ${snapshot.classGroups.length}'
        ' — i.e. ${snapshot.classGroups.length} class(es) in the snapshot');

    // How many students WISA puts in each (KLAS, KLASGROEP) pair.
    final studentsPerPair = <String, int>{};
    for (final s in snapshot.students) {
      studentsPerPair.update(
        '${s.classGroup}|${s.classSubGroup}',
        (v) => v + 1,
        ifAbsent: () => 1,
      );
    }

    // Group the raw rows per class.
    final byClass = <String, List<_Row>>{};
    for (final r in rows) {
      byClass.putIfAbsent(r.klas, () => []).add(r);
    }
    final names = byClass.keys.toList()..sort();

    final buckets = <String, List<String>>{};
    void bucket(String key, String line) =>
        buckets.putIfAbsent(key, () => []).add(line);

    stdout.writeln('\n  KLAS      KLASGROEP codes            ADMINGROEP codes');
    stdout.writeln('  ${'-' * 68}');
    for (final name in names) {
      final rs = byClass[name]!;
      final codes = rs.map((r) => r.klasgroep).toList()..sort();
      final admin = <String>{for (final r in rs) r.admingroep}.toList()..sort();
      final has00 = codes.contains('00');
      final named = codes.where((c) => c != '00').toList();

      final emitted = _emittedName(name, named, admin.length);
      final students = [
        for (final e in studentsPerPair.entries)
          if (e.key.split('|').first == name)
            '${e.key.split('|')[1]}:${e.value}'
      ]..sort();

      stdout.writeln('  ${name.padRight(9)} ${codes.join(',').padRight(26)} '
          '${admin.join(',').padRight(20)} -> "$emitted"'
          '${students.isEmpty ? '' : '   students[${students.join(' ')}]'}');

      final String key;
      if (!has00 && named.isEmpty) {
        key = 'E. no rows at all (impossible)';
      } else if (!has00 && named.isNotEmpty) {
        key = 'D. NO "00" row, ${named.length} named group(s)';
      } else if (named.isEmpty) {
        key = 'A. only "00" — no sub-groups at all';
      } else if (admin.length > 1) {
        key = 'C. "00" + ${named.length} named, >1 ADMINGROEP  '
            '(splits today — 2F shape)';
      } else {
        key = 'B. "00" + ${named.length} named, 1 ADMINGROEP   '
            '(collapses today — 2G shape) *** WOULD CHANGE ***';
      }
      bucket(key, '$name -> "$emitted"');
    }

    stdout.writeln('\n  Shapes found in ${school.code}:');
    final keys = buckets.keys.toList()..sort();
    for (final k in keys) {
      stdout.writeln('    ${buckets[k]!.length.toString().padLeft(4)}  $k');
      for (final line in buckets[k]!) {
        stdout.writeln('            $line');
      }
    }
  }

  return 0;
}

/// What the connector emits today for a class, per `_dedupeClassGroups`:
/// sub-groups win only when the class carries more than one ADMINGROEP.
String _emittedName(String klas, List<String> named, int adminCount) {
  if (adminCount > 1 && named.isNotEmpty) {
    return named.map((c) => '$klas $c').join(' + ');
  }
  return klas;
}

class _Row {
  final String klas;
  final String klasgroep;
  final String omschrijving;
  final String admingroep;
  _Row(this.klas, this.klasgroep, this.omschrijving, this.admingroep);
}

/// Splits the raw CSV the same way [parseClassGroupRow] does — anchor on the
/// first two and last two columns, rejoin the middle as the description.
List<_Row> _parseRaw(String csv) {
  final lines = csv.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <_Row>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final f = line.split(',');
    if (f.length < 5) continue;
    out.add(_Row(
      f[0].trim(),
      f[1].trim(),
      f.sublist(2, f.length - 2).join(',').trim(),
      f[f.length - 2].trim(),
    ));
  }
  return out;
}

/// Keeps the decoded CSV of the most recent `SyncKlas` call.
class _SyncKlasRecorder implements WisaSoapTransport {
  final WisaSoapTransport _inner;
  String? csv;

  _SyncKlasRecorder(this._inner);

  void reset() => csv = null;

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final code = RegExp(r'<QueryCode[^>]*>([^<]+)</QueryCode>')
        .firstMatch(envelope)
        ?.group(1)
        ?.trim();
    final response = await _inner.send(
      endpoint: endpoint,
      soapAction: soapAction,
      envelope: envelope,
    );
    if (code == WisaQuery.syncClassGroups) {
      csv = decodeGetCsvDataResponse(response);
    }
    return response;
  }
}
