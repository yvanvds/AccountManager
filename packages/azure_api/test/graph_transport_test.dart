import 'package:azure_api/azure_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('HttpGraphTransport', () {
    test('forwards method, url, headers and body, and maps the response',
        () async {
      late http.BaseRequest seen;
      final transport = HttpGraphTransport(
        client: MockClient((req) async {
          seen = req;
          return http.Response(
            '{"value":1}',
            201,
            headers: {'request-id': 'abc'},
          );
        }),
      );

      final resp = await transport.send(
        GraphRequest(
          method: 'POST',
          url: Uri.parse('https://graph.microsoft.com/v1.0/users'),
          headers: const {'Authorization': 'Bearer t'},
          body: '{"displayName":"x"}',
        ),
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/v1.0/users');
      expect(seen.headers['Authorization'], 'Bearer t');
      expect(resp.statusCode, 201);
      expect(resp.headers['request-id'], 'abc');
      expect(resp.json['value'], 1);
    });
  });
}
