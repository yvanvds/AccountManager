import 'package:http/http.dart' as http;

/// A single Azure Blob Storage HTTP request.
///
/// The Blob counterpart of `CosmosRequest`: a plain value object carrying the
/// method, url, headers (including the `authorization` bearer built by
/// [BlobStore]) and body, so the in-memory fake transport in tests can assert
/// on the outgoing call without a network or a storage account.
class BlobRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  const BlobRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  @override
  String toString() => '$method ${url.toString()}';
}

/// An Azure Blob Storage HTTP response.
class BlobResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const BlobResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  bool get isNotFound => statusCode == 404;
}

/// Thrown when Blob Storage returns an unexpected non-2xx response (i.e.
/// anything other than a benign 404 on read/delete). Mirrors [CosmosException]:
/// [toString] surfaces the status and the (usually XML) error body for the log.
class BlobException implements Exception {
  final int statusCode;
  final String body;

  const BlobException(this.statusCode, this.body);

  @override
  String toString() => 'BlobException($statusCode): $body';
}

/// Issues a single Blob data-plane HTTP request and returns the raw response.
///
/// Abstracted the same way [CosmosTransport] is, so [HttpBlobStore]'s
/// URL/header building and status handling are unit-testable against an
/// in-memory fake that replays recorded responses and records the outgoing
/// requests — no network, no storage account.
abstract interface class BlobTransport {
  Future<BlobResponse> send(BlobRequest request);
}

/// Default transport backed by `package:http`.
class HttpBlobTransport implements BlobTransport {
  final http.Client _client;

  HttpBlobTransport({http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<BlobResponse> send(BlobRequest request) async {
    final resp = await _client.send(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body ?? '',
    );
    final body = await resp.stream.bytesToString();
    return BlobResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: body,
    );
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client was
  /// provided.
  void close() => _client.close();
}
