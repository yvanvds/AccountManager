import 'dart:convert';

import 'package:xml/xml.dart';

import 'credentials.dart';

/// Builds a `GetCSVData` SOAP 1.1 envelope for the WISA service.
///
/// The WSDL declares RPC-encoded SOAP with `urn:WisaAPIService-WisaAPIService`
/// as the operation namespace and `urn:WisaAPIService` as the type
/// namespace. The legacy .NET stub serialises against the same WSDL; this
/// envelope is hand-rolled to match what that stub emits on the wire.
String buildGetCsvDataEnvelope({
  required WisaCredentials credentials,
  required String queryCode,
  required List<WisaParam> params,
  bool includeHeader = true,
  String separator = ',',
  String options = '',
}) {
  final b = XmlBuilder();
  b.processing('xml', 'version="1.0" encoding="utf-8"');
  b.element(
    'soap:Envelope',
    namespaces: {
      'http://schemas.xmlsoap.org/soap/envelope/': 'soap',
      'http://www.w3.org/2001/XMLSchema-instance': 'xsi',
      'http://www.w3.org/2001/XMLSchema': 'xsd',
      'http://schemas.xmlsoap.org/soap/encoding/': 'soapenc',
      'urn:WisaAPIService': 'ns0',
    },
    nest: () {
      b.attribute(
        'encodingStyle',
        'http://schemas.xmlsoap.org/soap/encoding/',
        namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
      );
      b.element('soap:Body', nest: () {
        b.element('tns:GetCSVData', namespaces: {
          'urn:WisaAPIService-WisaAPIService': 'tns',
        }, nest: () {
          // Credentials part.
          b.element('Credentials', nest: () {
            b.attribute(
              'type',
              'ns0:TWISAAPICredentials',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            b.element('Username', nest: credentials.username);
            b.element('Password', nest: credentials.password);
            b.element('Database', nest: credentials.database);
          },);
          // QueryCode part.
          b.element('QueryCode', nest: () {
            b.attribute(
              'type',
              'xsd:string',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            b.text(queryCode);
          },);
          // Params: SOAP-encoded array of TWISAAPIParamValue.
          b.element('Params', nest: () {
            b.attribute(
              'arrayType',
              'ns0:TWISAAPIParamValue[${params.length}]',
              namespace: 'http://schemas.xmlsoap.org/soap/encoding/',
            );
            b.attribute(
              'type',
              'soapenc:Array',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            for (final p in params) {
              b.element('item', nest: () {
                b.attribute(
                  'type',
                  'ns0:TWISAAPIParamValue',
                  namespace: 'http://www.w3.org/2001/XMLSchema-instance',
                );
                b.element('Name', nest: p.name);
                b.element('Value', nest: p.value);
              },);
            }
          },);
          // Header part.
          b.element('Header', nest: () {
            b.attribute(
              'type',
              'xsd:boolean',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            b.text(includeHeader ? 'true' : 'false');
          },);
          b.element('Separator', nest: () {
            b.attribute(
              'type',
              'xsd:string',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            b.text(separator);
          },);
          b.element('Options', nest: () {
            b.attribute(
              'type',
              'xsd:string',
              namespace: 'http://www.w3.org/2001/XMLSchema-instance',
            );
            b.text(options);
          },);
        },);
      },);
    },
  );
  return b.buildDocument().toXmlString();
}

/// Thrown when a WISA SOAP response is malformed (no envelope, missing
/// `Result`, or `Result` is not base64).
class WisaSoapResponseException implements Exception {
  final String message;
  WisaSoapResponseException(this.message);
  @override
  String toString() => 'WisaSoapResponseException: $message';
}

/// Thrown when the SOAP response carries a `<soap:Fault>`. Exposes the
/// fault code and string so callers can log the WISA-side error.
class WisaSoapFault implements Exception {
  final String code;
  final String faultString;
  WisaSoapFault(this.code, this.faultString);
  @override
  String toString() => 'WisaSoapFault($code): $faultString';
}

/// Decodes a `GetCSVDataResponse` SOAP envelope into the CSV payload.
///
/// The WISA service returns `Result` as a base64-encoded byte blob. We
/// decode the bytes as Latin-1 (a strict superset of ASCII), matching the
/// legacy `Encoding.Default.GetString(...)` call on a Belgian Windows
/// host — which uses Windows-1252, byte-compatible with Latin-1 for the
/// characters WISA emits.
String decodeGetCsvDataResponse(String responseXml) {
  final doc = XmlDocument.parse(responseXml);
  // Surface SOAP faults first.
  final fault = doc.findAllElements(
    'Fault',
    namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
  );
  if (fault.isNotEmpty) {
    final f = fault.first;
    final code = f.findElements('faultcode').firstOrNull?.innerText ?? '';
    final str = f.findElements('faultstring').firstOrNull?.innerText ?? '';
    throw WisaSoapFault(code, str);
  }
  // Anywhere-in-the-tree `Result` element (the response wrapper element
  // name varies across server versions).
  final results = doc.findAllElements('Result');
  if (results.isEmpty) {
    throw WisaSoapResponseException('No <Result> element in response');
  }
  // WISA emits the base64 payload wrapped across lines (~76-char chunks
  // separated by CRLF). Dart's `base64.decode` is strict and rejects any
  // inline whitespace, unlike .NET's `Convert.FromBase64String`, which
  // is why the legacy app never hit this. Strip all whitespace first.
  final encoded = results.first.innerText.replaceAll(RegExp(r'\s+'), '');
  if (encoded.isEmpty) return '';
  try {
    final bytes = base64.decode(encoded);
    return latin1.decode(bytes, allowInvalid: true);
  } on FormatException catch (e) {
    throw WisaSoapResponseException('Result is not valid base64: ${e.message}');
  }
}
