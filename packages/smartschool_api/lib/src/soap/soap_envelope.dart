import 'package:xml/xml.dart';

import 'credentials.dart';

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
      b.element('soap:Body', nest: () {
        b.attribute('encodingStyle', soapEnc, namespace: soapEnv);
        b.element('ns1:$method', nest: () {
          for (final a in args) {
            b.element(a.name, nest: () {
              b.attribute('type', a.xsiType, namespace: xsi);
              b.text(a.value);
            },);
          }
        },);
      },);
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
class SmartschoolSoapFault implements Exception {
  final String code;
  final String faultString;
  SmartschoolSoapFault(this.code, this.faultString);
  @override
  String toString() => 'SmartschoolSoapFault($code): $faultString';
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
  throw SmartschoolSoapFault(code, str);
}
