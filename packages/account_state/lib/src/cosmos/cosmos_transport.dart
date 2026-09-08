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

  /// `true` when Cosmos refused the request outright (**403 Forbidden**). On the
  /// container-create path this never means "the operator is missing a role
  /// somebody could grant" — the data-plane role can *never* create a container
  /// — so [CosmosClient.ensureContainer] reads it as "never provisioned" (#414).
  bool get isForbidden => statusCode == 403;

  /// `true` when Cosmos rejected a create for an id or unique-key collision —
  /// the signal `CosmosPersonIdResolver` reads to adopt the winning id.
  bool get isConflict => statusCode == 409;

  /// `true` when Cosmos rejected a conditioned write because the `If-Match`
  /// ETag was stale (the document changed since it was read). The signal the
  /// write-path stores read to reload and retry — distinct from the [isConflict]
  /// a create races on (#121).
  bool get isPreconditionFailed => statusCode == 412;

  /// `true` when Cosmos rejected the request because the request rate exceeded
  /// the account's provisioned throughput (**429 TooManyRequests**). This is a
  /// "slow down", not a "no": the request is retryable after [retryAfter]
  /// (#196).
  bool get isThrottled => statusCode == 429;

  /// How long Cosmos asks the client to wait before retrying a [isThrottled]
  /// request, from `x-ms-retry-after-ms` (milliseconds). Falls back to the
  /// standard `retry-after` header (seconds) when the Cosmos-specific one is
  /// absent, and is `null` when neither is present or parseable — the caller
  /// then uses its own backoff. Header names are case-insensitive on the wire
  /// (`package:http` lower-cases them), so callers read this rather than the raw
  /// header.
  Duration? get retryAfter {
    final ms = int.tryParse(headers['x-ms-retry-after-ms']?.trim() ?? '');
    if (ms != null) return Duration(milliseconds: ms);
    final seconds = int.tryParse(headers['retry-after']?.trim() ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// The document's current `_etag`, from the `etag` response header Cosmos
  /// returns on a point read or a write. `null` when absent. Header names are
  /// case-insensitive on the wire (`package:http` lower-cases them), so callers
  /// read this rather than the raw header.
  String? get etag {
    final value = headers['etag'];
    return (value == null || value.isEmpty) ? null : value;
  }

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

/// Thrown when a container is genuinely absent *and* the account's identity may
/// not create it over the data plane — i.e. the container was never provisioned
/// (#414).
///
/// Cosmos answers that create with a **403** whose message talks about an AAD
/// token that "cannot be authorized in data plane", which reads as a permissions
/// problem and sends whoever hits it hunting for a role assignment that would
/// not help: *no* data-plane role can create a container, by design. The
/// container set is a control-plane job and `tool/provision-cosmos.ps1` is its
/// source of truth, so the honest report is the missing container and the script
/// that creates it.
///
/// This is what a container added to [bootstrapContainers] but never provisioned
/// on the shared account looks like — the `lateArrivals` drift that made both
/// Cosmos-backed halves of the reception desk fail (#403 added the container to
/// the spec; the script had not been re-run).
///
/// [toString] is the one legible sentence; the raw Cosmos error stays available
/// on [body] / [message] for a log or a details pane, so trimming the operator's
/// note never loses it.
class CosmosContainerNotProvisioned extends CosmosException {
  const CosmosContainerNotProvisioned(
    this.container,
    super.statusCode,
    super.body,
  );

  /// The container id that does not exist (e.g. `lateArrivals`).
  final String container;

  @override
  String toString() => "Cosmos container '$container' is not provisioned on "
      'this account — run tool/provision-cosmos.ps1 to create it.';
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
