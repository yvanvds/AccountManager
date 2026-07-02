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
  });
}
