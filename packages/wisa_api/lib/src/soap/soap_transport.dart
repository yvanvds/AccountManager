import 'package:http/http.dart' as http;

/// Sends a SOAP envelope and returns the response body.
///
/// Abstracted so tests can replace the transport with an in-memory fake.
abstract interface class WisaSoapTransport {
  /// Posts [envelope] to [endpoint] with the given SOAPAction. Returns
  /// the response body. Implementations should throw on non-2xx replies.
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  });
}

/// Thrown when the HTTP transport receives a non-2xx response.
class WisaSoapHttpException implements Exception {
  final int statusCode;
  final String body;
  WisaSoapHttpException(this.statusCode, this.body);
  @override
  String toString() => 'WisaSoapHttpException($statusCode): $body';
}

/// Default transport backed by `package:http`. Sends a SOAP 1.1 POST with
/// `Content-Type: text/xml; charset=utf-8` — what the WISA service
/// expects per the WSDL binding.
class HttpWisaSoapTransport implements WisaSoapTransport {
  final http.Client _client;

  HttpWisaSoapTransport({http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    final resp = await _client.post(
      endpoint,
      headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        'SOAPAction': '"$soapAction"',
      },
      body: envelope,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WisaSoapHttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  /// Releases the underlying HTTP client. Owners of this transport should
  /// call this when done; cheap no-op if a custom client was provided.
  void close() => _client.close();
}
