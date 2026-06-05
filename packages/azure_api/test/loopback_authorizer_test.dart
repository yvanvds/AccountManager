import 'dart:async';

import 'package:azure_api/azure_api.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('LoopbackAuthorizer', () {
    test('captures the redirect query parameters from the loopback server',
        () async {
      final redirect = Uri.parse('http://localhost:8762/auth-redirect');
      final authorizer = LoopbackAuthorizer(
        launchBrowser: (authUrl) async {
          // Simulate the browser bouncing back to the loopback server. Fire and
          // forget — the server only answers once call() reaches `server.first`.
          unawaited(
            http.get(
              redirect.replace(queryParameters: {'code': 'abc', 'state': 's'}),
            ),
          );
        },
      );

      final params = await authorizer.call(
        Uri.parse('https://login.microsoftonline.com/t/oauth2/v2.0/authorize'),
        redirect,
      );

      expect(params['code'], 'abc');
      expect(params['state'], 's');
    });

    test('throws AzureAuthException when the redirect carries an error',
        () async {
      final redirect = Uri.parse('http://localhost:8763/auth-redirect');
      final authorizer = LoopbackAuthorizer(
        launchBrowser: (authUrl) async {
          unawaited(
            http.get(
              redirect.replace(
                queryParameters: {
                  'error': 'access_denied',
                  'error_description': 'user declined',
                },
              ),
            ),
          );
        },
      );

      expect(
        () => authorizer.call(
          Uri.parse(
            'https://login.microsoftonline.com/t/oauth2/v2.0/authorize',
          ),
          redirect,
        ),
        throwsA(isA<AzureAuthException>()),
      );
    });
  });
}
