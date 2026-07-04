import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single Azure SignalR REST/management HTTP request.
///
/// Carries everything the transport needs to issue the call, including the
/// `authorization` header (built by `SignalRPublisher`, not the transport). Kept
/// a plain value object so the fake transport in tests can assert on the method,
/// url, headers and body — the URL / api-version / payload building the publisher
/// does — mirroring `CosmosRequest`.
class SignalRRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  const SignalRRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  @override
  String toString() => '$method ${url.toString()}';
}

/// An Azure SignalR REST/management HTTP response.
class SignalRResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const SignalRResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  /// SignalR's `:send` broadcast returns **202 Accepted** on success; treat any
  /// 2xx as success to be tolerant of future status choices.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Decodes the body as a JSON object (used by the negotiate response). Empty
  /// bodies decode to an empty map.
  Map<String, dynamic> get json {
    if (body.trim().isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('SignalR response body was not a JSON object');
  }
}

/// Thrown when SignalR returns a non-2xx the caller did not expect. [toString]
/// surfaces the status and body for the operator log.
class SignalRException implements Exception {
  final int statusCode;
  final String body;

  const SignalRException(this.statusCode, this.body);

  @override
  String toString() => 'SignalRException($statusCode): $body';
}

/// Issues a single SignalR REST/management HTTP request and returns the raw
/// response.
///
/// Abstracted the same way [CosmosTransport] is, so `SignalRPublisher`'s URL /
/// api-version / payload building and status handling are unit-testable against
/// an in-memory fake that records the outgoing request and replays a canned
/// response — no network, no service.
abstract interface class SignalRTransport {
  Future<SignalRResponse> send(SignalRRequest request);
}

/// Default transport backed by `package:http`.
class HttpSignalRTransport implements SignalRTransport {
  final http.Client _client;

  HttpSignalRTransport({http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<SignalRResponse> send(SignalRRequest request) async {
    final resp = await _client.send(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body ?? '',
    );
    final body = await resp.stream.bytesToString();
    return SignalRResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: body,
    );
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client was
  /// provided.
  void close() => _client.close();
}
