import 'package:http/http.dart' as http;

import 'graph_request.dart';

/// Issues a single Graph HTTP request and returns the raw response.
///
/// Abstracted so tests can replace the transport with an in-memory fake that
/// replays recorded Graph responses and records the outgoing requests (the
/// `$filter`/`$select`/`$batch` correctness tests assert on those).
abstract interface class GraphTransport {
  Future<GraphResponse> send(GraphRequest request);
}

/// Default transport backed by `package:http`.
class HttpGraphTransport implements GraphTransport {
  final http.Client _client;

  HttpGraphTransport({http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<GraphResponse> send(GraphRequest request) async {
    final resp = await _client.send(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body ?? '',
    );
    final body = await resp.stream.bytesToString();
    return GraphResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: body,
    );
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client was
  /// provided.
  void close() => _client.close();
}
