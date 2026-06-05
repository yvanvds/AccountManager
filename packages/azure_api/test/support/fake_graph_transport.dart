import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_api/azure_api.dart';

/// A [GraphTransport] that records every outgoing [GraphRequest] and replays a
/// response from an injected handler. The recorded requests let tests assert
/// on the exact `$filter`/`$select`/`$batch` the connector issued.
class FakeGraphTransport implements GraphTransport {
  final List<GraphRequest> requests = [];
  final FutureOr<GraphResponse> Function(GraphRequest request) _handler;

  FakeGraphTransport(this._handler);

  /// Convenience: always replies with [response], recording calls.
  FakeGraphTransport.constant(GraphResponse response)
      : _handler = ((_) => response);

  @override
  Future<GraphResponse> send(GraphRequest request) async {
    requests.add(request);
    return _handler(request);
  }

  GraphRequest get last => requests.last;
}

/// A `200 OK` JSON response.
GraphResponse jsonOk(Object body) => GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: body is String ? body : jsonEncode(body),
    );

/// A `204 No Content` response (Graph's reply to PATCH/DELETE and member
/// `$ref` writes).
GraphResponse noContent() => const GraphResponse(statusCode: 204);

/// An error response with a Graph error envelope.
GraphResponse graphError(int status, String code, String message) =>
    GraphResponse(
      statusCode: status,
      body: jsonEncode({
        'error': {'code': code, 'message': message},
      }),
    );

/// Reads a committed fixture from `test/fixtures/`. Tolerates being run from
/// the package root or the workspace root.
String readFixture(String name) {
  final candidates = <String>[
    'test/fixtures/$name',
    'packages/azure_api/test/fixtures/$name',
    Uri.base.resolve('test/fixtures/$name').toFilePath(),
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw FileSystemException('fixture not found', name);
}

/// Reads and decodes a JSON fixture object.
Map<String, dynamic> readJsonFixture(String name) =>
    jsonDecode(readFixture(name)) as Map<String, dynamic>;
