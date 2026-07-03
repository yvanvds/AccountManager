import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single Key Vault data-plane HTTP request.
///
/// Carries everything the transport needs to issue the call, including the
/// `Authorization` header (set by [KeyVaultSecretProvider], not the transport).
/// Kept as a plain value object so the fake transport in tests can assert on the
/// method, url and body (the ref<->secret-name mapping tests check the path the
/// provider built).
class KeyVaultRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  const KeyVaultRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  @override
  String toString() => '$method ${url.toString()}';
}

/// A Key Vault data-plane HTTP response.
class KeyVaultResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const KeyVaultResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  bool get isNotFound => statusCode == 404;

  /// Decodes the body as a JSON object. Empty bodies decode to an empty map.
  Map<String, dynamic> get json {
    if (body.trim().isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException(
        'Key Vault response body was not a JSON object');
  }
}

/// Thrown when Key Vault returns a non-2xx response other than a benign 404.
///
/// [toString] surfaces Key Vault's own `error.code`/`error.message` when present
/// (the standard `{ "error": { "code", "message" } }` envelope), which is what
/// the operator needs to see in the log.
class KeyVaultException implements Exception {
  final int statusCode;
  final String body;

  const KeyVaultException(this.statusCode, this.body);

  /// Key Vault's `error.code`, when the body is a standard error envelope.
  String? get code => _errorField('code');

  /// Key Vault's `error.message`, when present.
  String? get message => _errorField('message');

  String? _errorField(String field) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) return error[field] as String?;
      }
    } on FormatException {
      // Non-JSON error body; fall through.
    }
    return null;
  }

  @override
  String toString() {
    final detail = message ?? body;
    final codePart = code != null ? ' ($code)' : '';
    return 'KeyVaultException($statusCode$codePart): $detail';
  }
}

/// Issues a single Key Vault HTTP request and returns the raw response.
///
/// Abstracted the same way `azure_api`'s `GraphTransport` is, so the provider's
/// URL building, ref-mapping and status handling are unit-testable against an
/// in-memory fake that replays recorded responses and records the outgoing
/// requests — no network, no vault.
abstract interface class KeyVaultTransport {
  Future<KeyVaultResponse> send(KeyVaultRequest request);
}

/// Default transport backed by `package:http`.
class HttpKeyVaultTransport implements KeyVaultTransport {
  final http.Client _client;

  HttpKeyVaultTransport({http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<KeyVaultResponse> send(KeyVaultRequest request) async {
    final resp = await _client.send(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body ?? '',
    );
    final body = await resp.stream.bytesToString();
    return KeyVaultResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: body,
    );
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client was
  /// provided.
  void close() => _client.close();
}
