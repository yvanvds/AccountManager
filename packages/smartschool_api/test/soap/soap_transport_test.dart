import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';

void main() {
  group('redactAccessCode', () {
    test('replaces accesscode contents', () {
      const input = '<accesscode xsi:type="xsd:string">topsecret</accesscode>';
      final out = redactAccessCode(input);
      expect(out, contains('[REDACTED]'));
      expect(out, isNot(contains('topsecret')));
    });

    test('is a no-op when no accesscode element is present', () {
      const input = '<userIdentifier>jand</userIdentifier>';
      expect(redactAccessCode(input), input);
    });
  });

  group('HttpSmartschoolSoapTransport', () {
    test('returns the body on a 2xx response', () async {
      final client = MockClient((req) async {
        expect(req.headers['SOAPAction'], '"ns#m"');
        expect(req.headers['Content-Type'], contains('text/xml'));
        return http.Response('<ok/>', 200);
      });
      final transport = HttpSmartschoolSoapTransport(client: client);
      final body = await transport.send(
        endpoint: Uri.parse('https://demo.smartschool.be/Webservices/V3'),
        soapAction: 'ns#m',
        envelope: '<env/>',
      );
      expect(body, '<ok/>');
    });

    test('throws a redacted exception on a non-2xx response', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<accesscode>leaked</accesscode>',
          500,
        );
      });
      final transport = HttpSmartschoolSoapTransport(client: client);
      await expectLater(
        transport.send(
          endpoint: Uri.parse('https://demo.smartschool.be/Webservices/V3'),
          soapAction: 'ns#m',
          envelope: '<env/>',
        ),
        throwsA(
          isA<SmartschoolSoapHttpException>()
              .having((e) => e.toString(), 'toString', contains('[REDACTED]'))
              .having(
                  (e) => e.toString(), 'toString', isNot(contains('leaked'))),
        ),
      );
    });

    // #361: `delClass` dies inside Smartschool on a PHP fatal error and the
    // fault comes back on a 500. Short-circuiting on the status alone meant
    // the fault parsing never ran, so the operator's log line was the whole
    // envelope.
    test('parses a SOAP Fault that arrives on a 500', () async {
      final client = MockClient((req) async => http.Response(_faultBody, 500));
      final transport = HttpSmartschoolSoapTransport(client: client);
      await expectLater(
        transport.send(
          endpoint: Uri.parse('https://demo.smartschool.be/Webservices/V3'),
          soapAction: 'ns#delClass',
          envelope: '<env/>',
        ),
        throwsA(
          isA<SmartschoolSoapFault>()
              .having((e) => e.faultString, 'faultString',
                  'Undefined constant "Smsc\\Legacy\\Core\\_THE_OFFICIAL_CLASS"')
              .having((e) => e.code, 'code', 'SOAP-ENV:Server')
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.isServerFault, 'isServerFault', isTrue),
        ),
      );
    });
  });

  group('smartschoolHttpFailure', () {
    test('a 500 carrying a Fault becomes a fault, not an envelope dump', () {
      final failure = smartschoolHttpFailure(500, _faultBody);

      expect(failure, isA<SmartschoolSoapFault>());
      expect(
        '$failure',
        'SmartschoolSoapFault(SOAP-ENV:Server, HTTP 500): Undefined constant '
            '"Smsc\\Legacy\\Core\\_THE_OFFICIAL_CLASS"',
        reason: 'the operator reads the reason, never the XML around it',
      );
      expect('$failure', isNot(contains('Envelope')));
    });

    test('a 500 whose body is not a SOAP Fault stays an HTTP exception', () {
      // The fallback the issue asks to keep: an HTML error page, a proxy
      // message, an empty body — none of them are faults.
      const html = '<html><body><h1>502 Bad Gateway</h1></body></html>';
      final failure = smartschoolHttpFailure(502, html);

      expect(failure, isA<SmartschoolSoapHttpException>());
      expect((failure as SmartschoolSoapHttpException).statusCode, 502);
      expect(failure.body, html);
    });

    test('an unparseable body stays an HTTP exception rather than throwing',
        () {
      final failure = smartschoolHttpFailure(500, 'not xml at all <<<');
      expect(failure, isA<SmartschoolSoapHttpException>());
    });

    test('an empty body stays an HTTP exception', () {
      expect(
          smartschoolHttpFailure(503, ''), isA<SmartschoolSoapHttpException>());
    });

    test('the redaction survives on whichever exception carries the body', () {
      // Non-fault body: redacted by `SmartschoolSoapHttpException`, as before.
      expect(
        '${smartschoolHttpFailure(500, '<accesscode>leaked</accesscode>')}',
        allOf(contains('[REDACTED]'), isNot(contains('leaked'))),
      );
      // Fault body whose faultstring quotes the request back at us (escaped,
      // as a server must): redacted by the fault itself, which carried no
      // redaction at all before #361.
      final fault = smartschoolHttpFailure(
        500,
        _fault('SOAP-ENV:Server',
            'bad &lt;accesscode&gt;leaked&lt;/accesscode&gt;'),
      );
      expect(fault, isA<SmartschoolSoapFault>());
      expect(
          '$fault', allOf(contains('[REDACTED]'), isNot(contains('leaked'))));
    });

    test('a Client fault is not reported as a server-side one', () {
      final failure = smartschoolHttpFailure(
        500,
        _fault('SOAP-ENV:Client', 'procedure delClass not present'),
      );
      expect((failure as SmartschoolSoapFault).isServerFault, isFalse);
    });
  });
}

String _fault(String code, String faultString) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<SOAP-ENV:Envelope '
    'xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">'
    '<SOAP-ENV:Body><SOAP-ENV:Fault>'
    '<faultcode>$code</faultcode>'
    '<faultstring>$faultString</faultstring>'
    '</SOAP-ENV:Fault></SOAP-ENV:Body></SOAP-ENV:Envelope>';

/// The body Smartschool actually returned for `delClass` (#361), verbatim in
/// shape: a `500` whose fault names a PHP constant missing from *their* code.
final String _faultBody = _fault(
  'SOAP-ENV:Server',
  'Undefined constant "Smsc\\Legacy\\Core\\_THE_OFFICIAL_CLASS"',
);
