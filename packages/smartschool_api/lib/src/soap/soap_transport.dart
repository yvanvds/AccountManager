import 'package:http/http.dart' as http;

/// Sends a SOAP envelope and returns the response body.
///
/// Abstracted so tests can replace the transport with an in-memory fake
/// that replays recorded Smartschool responses.
abstract interface class SmartschoolSoapTransport {
  /// Posts [envelope] to [endpoint] with the given SOAPAction. Returns the
  /// response body. Implementations should throw on non-2xx replies.
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  });
}

/// Thrown when the HTTP transport receives a non-2xx response.
///
/// The body may echo back the request envelope, which carries the
/// accesscode in plaintext. [toString] redacts it so the exception is safe
/// to log.
class SmartschoolSoapHttpException implements Exception {
  final int statusCode;
  final String body;
  SmartschoolSoapHttpException(this.statusCode, this.body);
  @override
  String toString() =>
      'SmartschoolSoapHttpException($statusCode): ${redactAccessCode(body)}';
}

/// Replaces the contents of `<accesscode>…</accesscode>` elements with
/// `[REDACTED]`. Used by transport exceptions and the capture script.
/// Conservative — runs on plain strings, never throws.
String redactAccessCode(String input) {
  return input.replaceAllMapped(
    RegExp(r'(<accesscode[^>]*>).*?(</accesscode>)', dotAll: true),
    (m) => '${m.group(1)}[REDACTED]${m.group(2)}',
  );
}

/// Default transport backed by `package:http`. Sends a SOAP 1.1 POST with
/// `Content-Type: text/xml; charset=utf-8`, as the V3 service expects.
class HttpSmartschoolSoapTransport implements SmartschoolSoapTransport {
  final http.Client _client;

  HttpSmartschoolSoapTransport({http.Client? client})
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
      throw SmartschoolSoapHttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client
  /// was provided.
  void close() => _client.close();
}
