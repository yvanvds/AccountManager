/// Manual capture script: hits a real Azure AD tenant via Microsoft Graph and
/// dumps raw JSON responses under `packages/azure_api/captures/` (gitignored,
/// local-only).
///
/// Run from anywhere inside the repo, after exporting the env vars:
///
///     dart run packages/azure_api/tool/capture_responses.dart
///
/// Requires the `AZURE_*` vars (see `.azure.env.example` at the repo root).
/// **Read-only**: it lists the school's users and groups and never writes.
/// Uses the pre-acquired `AZURE_ACCESS_TOKEN`, so no interactive sign-in.
///
/// Output, per Graph call:
///
///     captures/<timestamp>/<name>.json   — raw Graph JSON (tokens redacted)
///
/// Use the captures to refresh the record-and-replay fixtures under
/// `test/fixtures/`. **Scrub PII** (names, mails, employeeIds, object ids)
/// before committing anything derived from a capture.
library;

import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';

Future<int> main(List<String> args) async {
  final config = AzureLiveConfig.fromEnvironment();
  if (config == null) {
    stderr.writeln(
      'AZURE_ACCESS_TOKEN is not set. Source .azure.env first '
      '(see .azure.env.example).',
    );
    return 2;
  }

  final repoRoot = _findRepoRoot();
  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final outDir = Directory(
    '${repoRoot.path}/packages/azure_api/captures/$stamp',
  )..createSync(recursive: true);

  final log = _StderrLog();
  final transport = _CapturingTransport(HttpGraphTransport(), outDir);
  final connector = AzureConnector(
    credentials: AzureCredentials(
      clientId: config.clientId,
      tenantId: config.tenantId,
      azureDomain: config.azureDomain,
      schoolPrefix: config.schoolPrefix,
    ),
    authProvider: StaticAuthProvider(config.accessToken),
    transport: transport,
    log: log,
  );

  try {
    final snapshot = await connector.sync();
    stderr.writeln(
      'Captured ${snapshot.users.length} users, ${snapshot.groups.length} '
      'groups → ${outDir.path}',
    );
    return 0;
  } on GraphException catch (e) {
    stderr.writeln('Graph error: $e');
    return 1;
  } finally {
    connector.close();
  }
}

/// Wraps a transport, writing each response body to a numbered JSON file with
/// bearer tokens redacted.
class _CapturingTransport implements GraphTransport {
  final GraphTransport _inner;
  final Directory _outDir;
  int _seq = 0;

  _CapturingTransport(this._inner, this._outDir);

  @override
  Future<GraphResponse> send(GraphRequest request) async {
    final resp = await _inner.send(request);
    final name = _nameFor(request.url);
    File('${_outDir.path}/${_seq++}-$name.json')
        .writeAsStringSync(_pretty(resp.body));
    return resp;
  }

  String _nameFor(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    final base = segments.isEmpty ? 'root' : segments.join('-');
    return base.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  String _pretty(String body) {
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(_redact(body)));
    } on FormatException {
      return _redact(body);
    }
  }

  /// Redacts anything that looks like a bearer token from the captured text.
  String _redact(String input) => input.replaceAllMapped(
        RegExp(r'(Bearer\s+)[A-Za-z0-9._-]+'),
        (m) => '${m.group(1)}[REDACTED]',
      );
}

class _StderrLog implements core.ILog {
  @override
  void addMessage(core.Origin origin, String message) =>
      stderr.writeln('[${origin.name}] $message');

  @override
  void addError(core.Origin origin, String message) =>
      stderr.writeln('[${origin.name}] ERROR $message');
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/packages').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return Directory.current;
    dir = parent;
  }
}
