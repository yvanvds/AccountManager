/// Manual capture script: hits a real WISA host and dumps raw SOAP
/// responses + decoded CSV under `packages/wisa_api/captures/`
/// (gitignored, local-only).
///
/// Run from anywhere inside the repo:
///
///     dart run packages/wisa_api/tool/capture_responses.dart
///
/// Requires the six `WISA_*` env vars (see `.wisa.env.example` at the
/// repo root). Output captures one file per SOAP call:
///
///     captures/<timestamp>/<query>.xml   — raw SOAP response
///     captures/<timestamp>/<query>.csv   — decoded CSV payload
///
/// Always-on issue #29 diagnostic: after `SyncKlas` is captured the
/// script reports whether any class group description appears to contain
/// a literal comma (i.e. WISA is *not* quoting the field) and whether
/// every row has the same field count as the header. One real capture
/// is enough to decide between the three avenues listed in issue #29.
library;

import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:wisa_api/wisa_api.dart';

Future<int> main(List<String> args) async {
  final config = WisaLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'WISA_USERNAME is not set. Source .wisa.env first '
      '(see .wisa.env.example).',
    );
    return 2;
  }

  final repoRoot = _findRepoRoot();
  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final outDir = Directory(
    '${repoRoot.path}/packages/wisa_api/captures/$stamp',
  )..createSync(recursive: true);
  stdout.writeln('Writing captures to ${outDir.path}');

  final recorder = _RecordingTransport(HttpWisaSoapTransport());
  final logger = _StdoutLog();
  final connector = WisaConnector.fromParts(
    server: config.server,
    port: config.port,
    database: config.database,
    username: config.username,
    password: config.password,
    transport: recorder,
    log: logger,
  );

  try {
    stdout.writeln('\n=== testConnection ===');
    final ok = await connector.testConnection();
    stdout.writeln('  result: $ok');

    stdout.writeln('\n=== loadSchools ===');
    final schools = await connector.loadSchools();
    stdout.writeln('  schools loaded: ${schools.length}');
    final target = schools.where((s) => s.id == config.schoolId).toList();
    if (target.isEmpty) {
      stderr.writeln(
        '  no school with ID ${config.schoolId} in the response; '
        'sync will be skipped.',
      );
    } else {
      stdout.writeln('  syncing school ${target.first.id} '
          '("${target.first.name}")');
      stdout.writeln('\n=== sync ===');
      final snapshot = await connector.sync(
        schools: target,
        workDate: DateTime.now(),
      );
      stdout.writeln(
        '  students=${snapshot.students.length} '
        'staff=${snapshot.staff.length} '
        'classGroups=${snapshot.classGroups.length}',
      );
    }
  } on Exception catch (e) {
    stderr.writeln('Capture failed: ${redactCredentials(e.toString())}');
    return 1;
  } finally {
    recorder.dump(outDir);
  }

  _runIssue29Diagnostic(outDir);
  stdout.writeln('\nDone. Captures: ${outDir.path}');
  return 0;
}

/// Walks the records the [_RecordingTransport] gathered and prints the
/// issue-29 verdict for the `SyncKlas` capture.
void _runIssue29Diagnostic(Directory outDir) {
  final klasFile = File('${outDir.path}/SyncKlas.csv');
  if (!klasFile.existsSync()) {
    stdout.writeln('\n[issue-29] no SyncKlas.csv captured — skipped.');
    return;
  }
  final csv = klasFile.readAsStringSync();
  if (csv.isEmpty) {
    stdout.writeln('\n[issue-29] SyncKlas.csv is empty.');
    return;
  }
  final lines = csv.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  if (lines.length < 2) {
    stdout.writeln('\n[issue-29] SyncKlas.csv has no data rows.');
    return;
  }
  final headerFields = lines.first.split(',').length;
  var mismatched = 0;
  var quoted = 0;
  var maxFields = headerFields;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    final fields = line.split(',').length;
    if (fields != headerFields) mismatched++;
    if (fields > maxFields) maxFields = fields;
    if (line.contains('"')) quoted++;
  }
  stdout.writeln('\n[issue-29] SyncKlas verdict');
  stdout.writeln('  header columns      : $headerFields');
  stdout.writeln('  data rows           : ${lines.length - 1}');
  stdout.writeln('  rows w/ mismatch    : $mismatched');
  stdout.writeln('  max fields observed : $maxFields');
  stdout.writeln('  rows containing "   : $quoted');
  if (quoted > 0) {
    stdout.writeln(
      '  → WISA appears to QUOTE fields containing commas. '
      'The new csv parser already handles this; legacy JSON corruption '
      'is a pre-existing legacy-parser bug.',
    );
  } else if (mismatched > 0) {
    stdout.writeln(
      '  → WISA does NOT quote and rows with embedded commas mis-split. '
      'Pick a non-comma separator (issue #29 avenue 1) or switch to '
      'GetXMLData (avenue 2).',
    );
  } else {
    stdout.writeln(
      '  → no comma-in-description rows in this capture; question is '
      'inconclusive from this dataset.',
    );
  }
}

class _RecordingTransport implements WisaSoapTransport {
  final WisaSoapTransport _inner;
  final List<({String queryCode, String response})> _records = [];

  _RecordingTransport(this._inner);

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final code = _peekQueryCode(envelope);
    final response = await _inner.send(
      endpoint: endpoint,
      soapAction: soapAction,
      envelope: envelope,
    );
    _records.add((queryCode: code, response: response));
    return response;
  }

  String _peekQueryCode(String envelope) {
    final m =
        RegExp(r'<QueryCode[^>]*>([^<]+)</QueryCode>').firstMatch(envelope);
    return m?.group(1)?.trim() ?? 'unknown';
  }

  /// Writes one `.xml` (raw SOAP) and one `.csv` (decoded payload) per
  /// captured call. The `.xml` is run through [redactCredentials] in
  /// case the server echoed the request envelope back in an error path.
  void dump(Directory outDir) {
    final counts = <String, int>{};
    for (final r in _records) {
      final n = counts.update(r.queryCode, (v) => v + 1, ifAbsent: () => 1);
      final base = n == 1 ? r.queryCode : '${r.queryCode}-$n';
      File('${outDir.path}/$base.xml')
          .writeAsStringSync(redactCredentials(r.response));
      try {
        final csv = decodeGetCsvDataResponse(r.response);
        File('${outDir.path}/$base.csv').writeAsStringSync(csv);
      } on Exception catch (e) {
        File('${outDir.path}/$base.csv.error.txt')
            .writeAsStringSync(redactCredentials(e.toString()));
      }
    }
  }
}

class _StdoutLog implements core.ILog {
  @override
  void addMessage(core.Origin origin, String message) {
    stdout.writeln('[${origin.name}] $message');
  }

  @override
  void addError(core.Origin origin, String message) {
    stderr.writeln('[${origin.name}] ERROR: $message');
  }
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
      stderr
          .writeln('Could not locate repo root from ${Directory.current.path}');
      exit(2);
    }
    d = parent;
  }
}
