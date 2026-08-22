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

  /// Whether this is Graph's way of saying *"the delta token you resumed from
  /// is no longer usable"* — the one Graph failure the Azure connector recovers
  /// from, by discarding the token and re-reading in full (#213).
  ///
  /// Two shapes, both of them Graph's own:
  /// - `410 Gone` — the documented `resyncRequired` / `syncStateNotFound`
  ///   "start over" signal for a delta query.
  /// - `400 Bad Request` with `Request_UnsupportedQuery` **and** a message
  ///   naming the delta link, e.g. *"DeltaLink older than 30 days is not
  ///   supported."* The code alone is deliberately not enough: Graph also
  ///   returns it for a genuinely malformed query, which must stay loud rather
  ///   than silently degrade into an expensive full read on every pass.
  ///
  /// Do not read that message as the lifetime: the number in Graph's text is
  /// generic, and the documented lifetime of a `directoryObject`/`user` delta
  /// link is **7 days**, not 30 (#288). Nothing here depends on the figure —
  /// the recovery is driven by the reply, not by a clock — but the operator
  /// reading the log should not be told a token has a month left when it has a
  /// week.
  ///
  /// The classification lives on the reply rather than on the connector because
  /// two layers need it: `UserManager.delta` hands it to `GraphClient` as the
  /// failure shape it expects — so the transport logs it as a detail instead of
  /// an error nobody should act on (#229) — and `AzureConnector.sync` uses it to
  /// decide to fall back to a full read.
  bool get isRejectedDeltaToken {
    if (statusCode == 410) return true;
    if (statusCode != 400) return false;
    if (code?.toLowerCase() != 'request_unsupportedquery') return false;
    final detail = (message ?? body).toLowerCase();
    return detail.contains('deltalink') ||
        detail.contains('delta link') ||
        detail.contains('deltatoken') ||
        detail.contains('delta token');
  }

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
