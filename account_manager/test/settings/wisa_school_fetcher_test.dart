import 'dart:convert';

import 'package:account_manager/src/settings/settings_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisa_api/wisa_api.dart';

/// In-memory WISA SOAP transport that answers any query with a fixed CSV blob,
/// wrapped in the base64 `GetCSVDataResponse` envelope the connector decodes.
/// Records the request envelopes it saw so a test can assert `SMAGetInst` was
/// the query issued.
class _FakeTransport implements WisaSoapTransport {
  _FakeTransport(this.csv);

  final String csv;
  final List<String> envelopes = <String>[];

  @override
  Future<String> send({
    required Uri endpoint,
    required String soapAction,
    required String envelope,
  }) async {
    envelopes.add(envelope);
    final encoded = base64.encode(latin1.encode(csv));
    return '''<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <NS1:GetCSVDataResponse xmlns:NS1="urn:WisaAPIService-WisaAPIService">
      <Result xsi:type="xsd:base64Binary" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">$encoded</Result>
    </NS1:GetCSVDataResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>''';
  }
}

void main() {
  group('fetchWisaSchoolsLive', () {
    test('issues SMAGetInst and returns the parsed id + name + code list',
        () async {
      // ID,NAME,DESCRIPTION, filled the way WISA really fills it (see the
      // redacted fixture packages/wisa_api/test/fixtures/sma_get_inst.csv):
      // column 2 is the long name, column 3 the short code. The connector
      // untangles them onto `name` / `code` (#208).
      final transport = _FakeTransport(
        'ID,NAME,DESCRIPTION\n'
        '3,Sint-Jan,SJ\n'
        '7,Sint-Pieter,SP\n',
      );
      final schools = await fetchWisaSchoolsLive(
        const WisaConnection(server: 'db.school.example', port: '1433'),
        'pw',
        transport: transport,
      );

      expect(transport.envelopes, hasLength(1));
      expect(transport.envelopes.single, contains(WisaQuery.getSchools));
      expect(schools.map((s) => s.id), [3, 7]);
      expect(schools.map((s) => s.name), ['Sint-Jan', 'Sint-Pieter']);
      expect(schools.map((s) => s.code), ['SJ', 'SP']);
    });

    test('throws WisaSchoolFetchException when the server is missing',
        () async {
      await expectLater(
        fetchWisaSchoolsLive(const WisaConnection(port: '1433'), 'pw'),
        throwsA(isA<WisaSchoolFetchException>()),
      );
    });

    test('throws WisaSchoolFetchException when the port is not numeric',
        () async {
      await expectLater(
        fetchWisaSchoolsLive(
          const WisaConnection(server: 'db.school.example', port: 'nope'),
          'pw',
        ),
        throwsA(isA<WisaSchoolFetchException>()),
      );
    });
  });
}
