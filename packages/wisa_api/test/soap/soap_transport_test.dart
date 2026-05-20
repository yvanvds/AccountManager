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
  });
}
