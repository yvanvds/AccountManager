import 'dart:convert';

import 'package:test/test.dart';
import 'package:wisa_api/src/soap/credentials.dart';
import 'package:wisa_api/src/soap/soap_envelope.dart';
import 'package:xml/xml.dart';

void main() {
  group('buildGetCsvDataEnvelope', () {
    const creds = WisaCredentials(
      username: 'user',
      password: 'pw',
      database: 'db',
    );

    test('produces a valid XML document', () {
      final xml = buildGetCsvDataEnvelope(
        credentials: creds,
        queryCode: 'SMATestCon',
        params: const [],
      );
      // Should not throw — proof the envelope parses cleanly.
      XmlDocument.parse(xml);
    });

    test('includes the credentials block', () {
      final xml = buildGetCsvDataEnvelope(
        credentials: creds,
        queryCode: 'SMATestCon',
        params: const [],
      );
      expect(xml, contains('<Username>user</Username>'));
      expect(xml, contains('<Password>pw</Password>'));
      expect(xml, contains('<Database>db</Database>'));
    });

    test('includes the query code', () {
      final xml = buildGetCsvDataEnvelope(
        credentials: creds,
        queryCode: 'SmaSyncLln',
        params: const [],
      );
      expect(xml, contains('SmaSyncLln'));
    });

    test('serialises each param as <item><Name/><Value/></item>', () {
      final xml = buildGetCsvDataEnvelope(
        credentials: creds,
        queryCode: 'SmaSyncLln',
        params: const [
          WisaParam('IS_ID', '25'),
          WisaParam('Werkdatum', '01/09/2024'),
        ],
      );
      expect(xml, contains('<Name>IS_ID</Name>'));
      expect(xml, contains('<Value>25</Value>'));
      expect(xml, contains('<Name>Werkdatum</Name>'));
      expect(xml, contains('<Value>01/09/2024</Value>'));
    });

    test('declares Header=true by default', () {
      final xml = buildGetCsvDataEnvelope(
        credentials: creds,
        queryCode: 'SmaSyncLln',
        params: const [],
      );
      expect(xml, contains('<Header'));
      expect(xml, contains('>true</Header>'));
    });
  });

  group('decodeGetCsvDataResponse', () {
    String makeResponse(String csv) {
      final encoded = base64.encode(utf8.encode(csv));
      return '''<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <NS1:GetCSVDataResponse xmlns:NS1="urn:WisaAPIService-WisaAPIService">
      <Result xsi:type="xsd:base64Binary" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">$encoded</Result>
    </NS1:GetCSVDataResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>''';
    }

    test('decodes base64 Result into the CSV blob', () {
      const csv = 'a,b,c\n1,2,3\n';
      expect(decodeGetCsvDataResponse(makeResponse(csv)), csv);
    });

    test('returns empty string for empty Result', () {
      expect(decodeGetCsvDataResponse(makeResponse('')), '');
    });

    test('tolerates whitespace inside the base64 payload', () {
      // WISA wraps the base64 across ~76-char lines separated by CRLF.
      // Dart's base64.decode is strict; the decoder must strip whitespace.
      const csv = 'ID,NAME\n1,Alpha\n2,Beta\n';
      final encoded = base64.encode(utf8.encode(csv));
      final wrapped =
          '${encoded.substring(0, 8)}\r\n${encoded.substring(8, 16)}\n  '
          '${encoded.substring(16)}';
      final xml = '''<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <NS1:GetCSVDataResponse xmlns:NS1="urn:WisaAPIService-WisaAPIService">
      <Result xsi:type="xsd:base64Binary" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">$wrapped</Result>
    </NS1:GetCSVDataResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>''';
      expect(decodeGetCsvDataResponse(xml), csv);
    });

    test('throws WisaSoapResponseException when Result is missing', () {
      const xml = '''<?xml version="1.0"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body/>
</SOAP-ENV:Envelope>''';
      expect(
        () => decodeGetCsvDataResponse(xml),
        throwsA(isA<WisaSoapResponseException>()),
      );
    });

    test('throws WisaSoapFault when response carries a Fault', () {
      const xml = '''<?xml version="1.0"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <SOAP-ENV:Fault>
      <faultcode>SOAP-ENV:Server</faultcode>
      <faultstring>Database is offline</faultstring>
    </SOAP-ENV:Fault>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>''';
      expect(
        () => decodeGetCsvDataResponse(xml),
        throwsA(
          isA<WisaSoapFault>().having(
            (e) => e.faultString,
            'faultString',
            'Database is offline',
          ),
        ),
      );
    });
  });
}
