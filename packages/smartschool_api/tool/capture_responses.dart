/// Manual capture script: hits a real Smartschool tenant and dumps raw SOAP
/// responses + decoded payloads under
/// `packages/smartschool_api/captures/` (gitignored, local-only).
///
/// Run from anywhere inside the repo, after exporting the env vars:
///
///     dart run packages/smartschool_api/tool/capture_responses.dart
///
/// Requires `SMARTSCHOOL_SITE` and `SMARTSCHOOL_ACCESSCODE` (see
/// `.smartschool.env.example` at the repo root). Read-only: it runs `sync`
/// (group tree + per-group accounts) and never writes. Output, per SOAP
/// call:
///
///     captures/<timestamp>/<method>[-n].xml      — raw SOAP (redacted)
///     captures/<timestamp>/<method>[-n].out.txt  — decoded <return> text
///
/// Use the captures to refresh the record-and-replay fixtures under
/// `test/fixtures/`. **Scrub PII** (names, mails, addresses, national IDs)
/// before committing anything derived from a capture.
library;

import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:smartschool_api/smartschool_api.dart';

Future<int> main(List<String> args) async {
  final config = SmartschoolLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'SMARTSCHOOL_ACCESSCODE is not set. Source .smartschool.env first '
      '(see .smartschool.env.example).',
    );
    return 2;
  }

  final repoRoot = _findRepoRoot();
  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final outDir = Directory(
    '${repoRoot.path}/packages/smartschool_api/captures/$stamp',
  )..createSync(recursive: true);
  stdout.writeln('Writing captures to ${outDir.path}');

  final recorder = _RecordingTransport(HttpSmartschoolSoapTransport());
  final connector = SmartschoolConnector.fromParts(
    site: config.site,
    accessCode: config.accessCode,
    transport: recorder,
    log: _StdoutLog(),
  );

  try {
    stdout.writeln('\n=== sync ===');
    final snapshot = await connector.sync();
    stdout.writeln(
      '  groups=${snapshot.groups.length} '
      'accounts=${snapshot.accounts.length} '
      'memberships=${snapshot.memberships.length}',
    );
  } on Object catch (e) {
    stderr.writeln('Capture failed: ${redactAccessCode(e.toString())}');
    return 1;
  } finally {
    recorder.dump(outDir);
  }

  stdout.writeln('\nDone. Captures: ${outDir.path}');
  stdout.writeln('Remember to scrub PII before deriving committed fixtures.');
  return 0;
}

class _RecordingTransport implements SmartschoolSoapTransport {
  final SmartschoolSoapTransport _inner;
  final List<({String method, String response})> _records = [];

  _RecordingTransport(this._inner);

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final method = _peekMethod(soapAction);
    final response = await _inner.send(
      endpoint: endpoint,
      soapAction: soapAction,
      envelope: envelope,
    );
    _records.add((method: method, response: response));
    return response;
  }

  /// SOAPAction is `<namespace>#<method>`; the method is the suffix.
  String _peekMethod(String soapAction) {
    final hash = soapAction.lastIndexOf('#');
    final raw = hash >= 0 ? soapAction.substring(hash + 1) : soapAction;
    return raw.replaceAll('"', '').trim();
  }

  void dump(Directory outDir) {
    final counts = <String, int>{};
    for (final r in _records) {
      final n = counts.update(r.method, (v) => v + 1, ifAbsent: () => 1);
      final base = n == 1 ? r.method : '${r.method}-$n';
      File('${outDir.path}/$base.xml')
          .writeAsStringSync(redactAccessCode(r.response));
      try {
        final ret = decodeReturn(r.response);
        var text = ret.text;
        // The group tree comes back base64-encoded XML; decode for legibility.
        if (r.method == SmartschoolMethod.getAllGroupsAndClasses &&
            !ret.isInt) {
          final cleaned = text.replaceAll(RegExp(r'\s+'), '');
          if (cleaned.isNotEmpty) {
            text = utf8.decode(base64.decode(cleaned));
          }
        }
        File('${outDir.path}/$base.out.txt').writeAsStringSync(text);
      } on Object catch (e) {
        File('${outDir.path}/$base.out.error.txt')
            .writeAsStringSync(redactAccessCode(e.toString()));
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
      stderr.writeln(
        'Could not locate repo root from ${Directory.current.path}',
      );
      exit(2);
    }
    d = parent;
  }
}
