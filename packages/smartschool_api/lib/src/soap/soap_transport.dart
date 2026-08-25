import 'package:http/http.dart' as http;

import 'redact.dart';
import 'soap_envelope.dart';

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

/// Thrown when the HTTP transport receives a non-2xx response **whose body is
/// not a SOAP Fault** — an HTML error page, a proxy message, an empty body.
///
/// The body may echo back the request envelope, which carries the
/// accesscode in plaintext. [toString] redacts it so the exception is safe
/// to log.
///
/// Since #361 a non-2xx body that *is* a SOAP Fault no longer lands here: see
/// [smartschoolHttpFailure].
class SmartschoolSoapHttpException implements Exception {
  final int statusCode;
  final String body;
  SmartschoolSoapHttpException(this.statusCode, this.body);
  @override
  String toString() =>
      'SmartschoolSoapHttpException($statusCode): ${redactAccessCode(body)}';
}

/// The exception a non-2xx reply `(statusCode, body)` becomes.
///
/// A SOAP Fault is a SOAP Fault whether it arrives with `200` or `500`: the
/// status decides the transport outcome, not whether the body is parseable.
/// Smartschool's `delClass` returns its PHP fatal error exactly that way, and
/// short-circuiting on the status alone meant the fault parsing never ran and
/// the whole envelope went into the operator's log line (#361).
///
/// So: a body carrying a `<soap:Fault>` becomes a [SmartschoolSoapFault] with
/// the [statusCode] preserved for diagnostics; anything else keeps the old
/// [SmartschoolSoapHttpException], body and redaction included.
///
/// Public because it is the *decision*, not the socket — an alternative
/// transport (and the app's offline test doubles) can reach the same verdict
/// from the same reply without re-deriving it.
Object smartschoolHttpFailure(int statusCode, String body) =>
    parseSoapFault(body, statusCode: statusCode) ??
    SmartschoolSoapHttpException(statusCode, body);

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
      throw smartschoolHttpFailure(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  /// Releases the underlying HTTP client. Cheap no-op if a custom client
  /// was provided.
  void close() => _client.close();
}
