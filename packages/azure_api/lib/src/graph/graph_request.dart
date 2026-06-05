import 'dart:convert';

/// A single Microsoft Graph HTTP request.
///
/// Carries everything the transport needs to issue the call, including the
/// `Authorization` header (set by [GraphClient], not the transport). Kept as a
/// plain value object so the fake transport in tests can assert on the method,
/// url and query string (e.g. the `$filter`/`$select` the connector issued).
class GraphRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  const GraphRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  GraphRequest copyWith({Map<String, String>? headers}) => GraphRequest(
        method: method,
        url: url,
        headers: headers ?? this.headers,
        body: body,
      );

  @override
  String toString() => '$method ${url.toString()}';
}

/// A Microsoft Graph HTTP response.
class GraphResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const GraphResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Decodes the body as a JSON object. Empty bodies (e.g. `204 No Content`
  /// from a DELETE) decode to an empty map.
  Map<String, dynamic> get json {
    if (body.trim().isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Graph response body was not a JSON object');
  }
}

/// Thrown when Graph returns a non-2xx response.
///
/// [toString] surfaces Graph's own `error.code`/`error.message` when present,
/// which is what the operator needs to see in the log.
class GraphException implements Exception {
  final int statusCode;
  final String body;

  const GraphException(this.statusCode, this.body);

  /// Graph's `error.code`, when the body is a standard Graph error envelope.
  String? get code => _errorField('code');

  /// Graph's `error.message`, when present.
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
    return 'GraphException($statusCode$codePart): $detail';
  }
}
