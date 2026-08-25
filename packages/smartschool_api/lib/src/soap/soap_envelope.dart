import 'package:xml/xml.dart';

import 'credentials.dart';
import 'redact.dart';

/// Builds an RPC/encoded SOAP 1.1 envelope for a Smartschool V3 operation.
///
/// The V3 WSDL declares `style="rpc"`, `use="encoded"`, with the operation
/// namespace equal to the tenant URL (e.g.
/// `https://<site>.smartschool.be/Webservices/V3`). The body therefore
/// wraps a single `<ns1:method>` element (in [namespace]) whose children are
/// the message parts, named and ordered exactly as the WSDL declares them
/// (`accesscode`, `userIdentifier`, …), each carrying its `xsi:type`.
///
/// Hand-rolled to match what the legacy .NET `SoapHttpClientProtocol` stub
/// emits on the wire (`legacy-wpf/AccountApi/Web References/SS/`).
String buildRpcEnvelope({
  required String namespace,
  required String method,
  required List<SoapArg> args,
}) {
  const soapEnv = 'http://schemas.xmlsoap.org/soap/envelope/';
  const soapEnc = 'http://schemas.xmlsoap.org/soap/encoding/';
  const xsi = 'http://www.w3.org/2001/XMLSchema-instance';

  final b = XmlBuilder();
  b.processing('xml', 'version="1.0" encoding="utf-8"');
  b.element(
    'soap:Envelope',
    namespaces: {
      soapEnv: 'soap',
      xsi: 'xsi',
      'http://www.w3.org/2001/XMLSchema': 'xsd',
      soapEnc: 'soapenc',
      namespace: 'ns1',
    },
    nest: () {
      b.element(
        'soap:Body',
        nest: () {
          b.attribute('encodingStyle', soapEnc, namespace: soapEnv);
          b.element(
            'ns1:$method',
            nest: () {
              for (final a in args) {
                b.element(
                  a.name,
                  nest: () {
                    b.attribute('type', a.xsiType, namespace: xsi);
                    b.text(a.value);
                  },
                );
              }
            },
          );
        },
      );
    },
  );
  return b.buildDocument().toXmlString();
}

/// The full `SOAPAction` header value for [method] in [namespace]:
/// `<namespace>#<method>` (per the WSDL `soapAction` binding).
String soapActionFor(String namespace, String method) => '$namespace#$method';

/// Thrown when a Smartschool SOAP response is malformed (no envelope, no
/// `return` element where one is expected).
class SmartschoolSoapResponseException implements Exception {
  final String message;
  SmartschoolSoapResponseException(this.message);
  @override
  String toString() => 'SmartschoolSoapResponseException: $message';
}

/// Thrown when the SOAP response carries a `<soap:Fault>`. Exposes the
/// fault code and string so callers can log the Smartschool-side error.
///
/// A fault is a fault whether it arrives on a `200` or, as `delClass` does
/// today, on a `500` (#361): the HTTP status decides the transport outcome,
/// not whether the body is readable. When it arrived on a non-2xx reply the
/// status travels along in [statusCode] for diagnostics — the log line stays
/// the one readable sentence Smartschool wrote, never the envelope around it.
class SmartschoolSoapFault implements Exception {
  final String code;
  final String faultString;

  /// The HTTP status the fault came back on, when it did not come back on a
  /// 2xx. Null for a fault decoded out of an ordinary `200` response.
  final int? statusCode;

  SmartschoolSoapFault(this.code, this.faultString, {this.statusCode});

  /// Whether [code] names the **server** as the faulting party (SOAP 1.1
  /// `Server`, however it is prefixed) rather than our request (`Client`).
  ///
  /// A server fault is Smartschool's own failure, so re-sending the identical
  /// request is not a fix — which is what lets a caller tell the operator to
  /// go and do the thing by hand instead of offering the same write again.
  bool get isServerFault =>
      code.split(':').last.trim().toLowerCase() == 'server';

  @override
  String toString() {
    final where = statusCode == null ? code : '$code, HTTP $statusCode';
    return 'SmartschoolSoapFault($where): ${redactAccessCode(faultString)}';
  }
}

/// Reads a `<soap:Fault>` out of [responseXml], or returns null when the body
/// carries none — including when it is not XML at all (an HTML error page from
/// a proxy, an empty body), which is why this never throws.
///
/// [statusCode] is stamped onto the fault when the body arrived on a non-2xx
/// reply, so the transport can hand back a parsed fault without losing the
/// status it came with.
SmartschoolSoapFault? parseSoapFault(String responseXml, {int? statusCode}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(responseXml);
  } on Object {
    return null;
  }
  final fault = doc
      .findAllElements(
        'Fault',
        namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
      )
      .firstOrNull;
  if (fault == null) return null;
  return SmartschoolSoapFault(
    fault.findElements('faultcode').firstOrNull?.innerText ?? '',
    fault.findElements('faultstring').firstOrNull?.innerText ?? '',
    statusCode: statusCode,
  );
}

/// The `<return>` part of an RPC response: its inner text and the declared
/// `xsi:type` (e.g. `xsd:int`, `xsd:string`), when present.
class SoapReturn {
  final String text;
  final String? xsiType;
  const SoapReturn(this.text, this.xsiType);

  /// `true` when the return looks like an integer status/error code rather
  /// than a payload. Smartschool returns small ints for write results and
  /// for "no direct accounts" (code 19) on `getAllAccountsExtended`.
  bool get isInt =>
      (xsiType != null && xsiType!.endsWith('int')) ||
      int.tryParse(text.trim()) != null;

  /// Parsed integer value, or `null` when the text is not an integer.
  int? get asInt => int.tryParse(text.trim());
}

/// Extracts the `<return>` element from an RPC response envelope.
///
/// Surfaces `<soap:Fault>` as a [SmartschoolSoapFault] first. Throws
/// [SmartschoolSoapResponseException] when neither a fault nor a `return`
/// element is present.
SoapReturn decodeReturn(String responseXml) {
  final doc = XmlDocument.parse(responseXml);
  _throwIfFault(doc);
  // Match by local name: some servers prefix the return element
  // (`<ns:return>`), which `findAllElements('return')` (qualified-name
  // match) would miss.
  final ret = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'return')
      .firstOrNull;
  if (ret == null) {
    throw SmartschoolSoapResponseException('No <return> element in response');
  }
  final type = ret.getAttribute(
        'type',
        namespace: 'http://www.w3.org/2001/XMLSchema-instance',
      ) ??
      ret.getAttribute('xsi:type');
  return SoapReturn(ret.innerText, type);
}

/// Decodes a write-style response into its integer result code. `0` means
/// success; any other value is a Smartschool error code (translate via the
/// error-code table). Throws when the response carries no integer return.
int decodeIntResult(String responseXml) {
  final ret = decodeReturn(responseXml);
  final value = ret.asInt;
  if (value == null) {
    throw SmartschoolSoapResponseException(
      'Expected an integer <return>, got "${ret.text}"',
    );
  }
  return value;
}

void _throwIfFault(XmlDocument doc) {
  final faults = doc.findAllElements(
    'Fault',
    namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
  );
  final fault = faults.isNotEmpty ? faults.first : null;
  if (fault == null) return;
  final code = fault.findElements('faultcode').firstOrNull?.innerText ?? '';
  final str = fault.findElements('faultstring').firstOrNull?.innerText ?? '';
  // No status: this body reached the decoder, so it arrived on a 2xx.
  throw SmartschoolSoapFault(code, str);
}
