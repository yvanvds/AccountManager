import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('HttpWisaSoapTransport', () {
    test('POSTs envelope with SOAPAction header and text/xml content type',
        () async {
      late http.Request capturedRequest;
      final client = MockClient((req) async {
        capturedRequest = req;
        return http.Response('<ok/>', 200);
      });
      final transport = HttpWisaSoapTransport(client: client);
      final body = await transport.send(
        endpoint: Uri.parse('http://example/SOAP/'),
        soapAction: 'urn:WisaAPIService-WisaAPIService#GetCSVData',
        envelope: '<envelope/>',
      );
      expect(body, '<ok/>');
      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.body, '<envelope/>');
      expect(
        capturedRequest.headers['content-type'],
        contains('text/xml'),
      );
      expect(
        capturedRequest.headers['soapaction'],
        '"urn:WisaAPIService-WisaAPIService#GetCSVData"',
      );
      transport.close();
    });

    test('throws WisaSoapHttpException on non-2xx response', () async {
      final client = MockClient(
        (req) async => http.Response('boom', 500),
      );
      final transport = HttpWisaSoapTransport(client: client);
      expect(
        () => transport.send(
          endpoint: Uri.parse('http://example/SOAP/'),
          soapAction: 'X',
          envelope: '<x/>',
        ),
        throwsA(
          isA<WisaSoapHttpException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.body, 'body', 'boom'),
        ),
      );
      transport.close();
    });

    test('WisaSoapHttpException.toString redacts echoed credentials',
        () async {
      const echoed =
          '<Envelope><Username>alice</Username><Password>hunter2</Password></Envelope>';
      final ex = WisaSoapHttpException(500, echoed);
      final s = ex.toString();
      expect(s, isNot(contains('hunter2')));
      expect(s, isNot(contains('alice')));
      expect(s, contains('[REDACTED]'));
    });
  });

  group('redactCredentials', () {
    test('replaces Username and Password element contents', () {
      const input =
          '<x><Username>u</Username><Password>p</Password></x>';
      expect(
        redactCredentials(input),
        '<x><Username>[REDACTED]</Username><Password>[REDACTED]</Password></x>',
      );
    });

    test('handles attributes on the element tag', () {
      const input = '<Password xsi:type="xsd:string">secret</Password>';
      expect(redactCredentials(input), contains('[REDACTED]'));
      expect(redactCredentials(input), isNot(contains('secret')));
    });

    test('is a no-op when neither element is present', () {
      expect(redactCredentials('<x>plain</x>'), '<x>plain</x>');
    });
  });
}
