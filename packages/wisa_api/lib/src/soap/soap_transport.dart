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
///
/// Some WISA error responses echo back the original request envelope,
/// which contains the password in plaintext. [toString] redacts those
/// credential fields so the exception is safe to log.
class WisaSoapHttpException implements Exception {
  final int statusCode;
  final String body;
  WisaSoapHttpException(this.statusCode, this.body);
  @override
  String toString() =>
      'WisaSoapHttpException($statusCode): ${redactCredentials(body)}';
}

/// Replaces the contents of `<Username>…</Username>` and
/// `<Password>…</Password>` elements with `[REDACTED]`. Used by
/// transport exceptions and by the capture script. Conservative — runs
/// on plain strings, never throws.
String redactCredentials(String input) {
  return input
      .replaceAllMapped(
        RegExp(r'(<Username[^>]*>).*?(</Username>)', dotAll: true),
        (m) => '${m.group(1)}[REDACTED]${m.group(2)}',
      )
      .replaceAllMapped(
        RegExp(r'(<Password[^>]*>).*?(</Password>)', dotAll: true),
        (m) => '${m.group(1)}[REDACTED]${m.group(2)}',
      );
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
