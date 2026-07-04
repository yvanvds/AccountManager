import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single Cosmos DB data-plane HTTP request.
///
/// Carries everything the transport needs to issue the call, including the
/// `authorization` header (built by [CosmosClient], not the transport). Kept a
/// plain value object so the fake transport in tests can assert on the method,
/// url, headers and body — the URL/partition-key/continuation building the
/// client does.
class CosmosRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  const CosmosRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  @override
  String toString() => '$method ${url.toString()}';
}

/// A Cosmos DB data-plane HTTP response.
class CosmosResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const CosmosResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  bool get isNotFound => statusCode == 404;

  /// `true` when Cosmos rejected a create for an id or unique-key collision —
  /// the signal `CosmosPersonIdResolver` reads to adopt the winning id.
  bool get isConflict => statusCode == 409;

  /// The `x-ms-continuation` token for a paged query, or `null` when the query
  /// is exhausted. Header names are case-insensitive on the wire; callers read
  /// this rather than the raw header.
  String? get continuation {
    final value = headers['x-ms-continuation'];
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Decodes the body as a JSON object. Empty bodies decode to an empty map.
  Map<String, dynamic> get json {
    if (body.trim().isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Cosmos response body was not a JSON object');
  }
}

/// Thrown when Cosmos returns a non-2xx response the caller did not expect
/// (i.e. anything other than a benign 404 or a create's 409).
///
/// [toString] surfaces Cosmos's own `code`/`message` when present (the standard
/// `{ "code", "message" }` envelope), which is what the operator needs in the
/// log.
class CosmosException implements Exception {
  final int statusCode;
  final String body;

  const CosmosException(this.statusCode, this.body);

  /// Cosmos's `code`, when the body is a standard error envelope.
  String? get code => _field('code');

  /// Cosmos's `message`, when present.
  String? get message => _field('message');

  String? _field(String field) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded[field] as String?;
    } on FormatException {
      // Non-JSON error body; fall through.
    }
    return null;
  }

  @override
  String toString() {
    final detail = message ?? body;
    final codePart = code != null ? ' ($code)' : '';
    return 'CosmosException($statusCode$codePart): $detail';
  }
}

/// Issues a single Cosmos data-plane HTTP request and returns the raw response.
///
/// Abstracted the same way `azure_api`'s `GraphTransport` and
/// `KeyVaultTransport` are, so [CosmosClient]'s URL building, partition-key /
/// continuation headers and status handling are unit-testable against an
/// in-memory fake that replays recorded responses and records the outgoing
/// requests — no network, no account.
abstract interface class CosmosTransport {
  Future<CosmosResponse> send(CosmosRequest request);
}

/// Default transport backed by `package:http`.
class HttpCosmosTransport implements CosmosTransport {
  final http.Client _client;

  HttpCosmosTransport({http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<CosmosResponse> send(CosmosRequest request) async {
    final resp = await _client.send(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body ?? '',
    );
    final body = await resp.stream.bytesToString();
    return CosmosResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: body,
    );
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client was
  /// provided.
  void close() => _client.close();
}
