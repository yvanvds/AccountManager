import 'dart:convert';

import 'package:azure_api/azure_api.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:test/test.dart';

void main() {
  final credentials = AzureCredentials(
    clientId: 'client-123',
    tenantId: 'tenant-abc',
    azureDomain: 'school.example',
    schoolPrefix: 'GBS',
  );

  /// Builds a serialized oauth2 credentials payload as the cache would hold it.
  String cachedCredentials({
    required String accessToken,
    String refreshToken = 'refresh-1',
    required DateTime expiration,
  }) =>
      oauth2.Credentials(
        accessToken,
        refreshToken: refreshToken,
        tokenEndpoint: credentials.tokenEndpoint,
        scopes: credentials.scopes,
        expiration: expiration,
      ).toJson();

  String tokenResponse(
    String accessToken, {
    String refreshToken = 'refresh-2',
  }) =>
      jsonEncode({
        'token_type': 'Bearer',
        'access_token': accessToken,
        'expires_in': 3600,
        'refresh_token': refreshToken,
        'scope': credentials.scopes.join(' '),
      });

  // oauth2 requires the token endpoint to declare a JSON content type.
  http.Response jsonResp(String body, int status) => http.Response(
        body,
        status,
        headers: {'content-type': 'application/json'},
      );

  // An authorizer that must never run (asserts the silent path was taken).
  Future<Map<String, String>> failIfCalled(Uri url, Uri redirect) async {
    fail('interactive sign-in should not have been triggered');
  }

  group('silent acquisition', () {
    test('returns a valid cached token without HTTP or interaction', () async {
      final cache = InMemoryTokenCache();
      await cache.write(
        cachedCredentials(
          accessToken: 'CACHED-AT',
          expiration: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: cache,
        authorizer: failIfCalled,
        httpClient: MockClient((_) async {
          fail('no token endpoint call expected');
        }),
      );
      expect(await provider.getAccessToken(), 'CACHED-AT');
    });

    test('refreshes an expired token silently and re-caches it', () async {
      final cache = InMemoryTokenCache();
      await cache.write(
        cachedCredentials(
          accessToken: 'OLD-AT',
          expiration: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      );
      Uri? refreshUrl;
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: cache,
        authorizer: failIfCalled,
        httpClient: MockClient((req) async {
          refreshUrl = req.url;
          expect(req.bodyFields['grant_type'], 'refresh_token');
          expect(req.bodyFields['client_id'], 'client-123');
          return jsonResp(tokenResponse('FRESH-AT'), 200);
        }),
      );

      expect(await provider.getAccessToken(), 'FRESH-AT');
      expect(refreshUrl, credentials.tokenEndpoint);
      // New credentials were written back to the cache.
      expect(await cache.read(), contains('FRESH-AT'));
    });
  });

  group('interactive acquisition', () {
    test('requests the right tenant, scopes, and PKCE challenge', () async {
      Uri? seenAuthUrl;
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: InMemoryTokenCache(),
        authorizer: (authUrl, redirect) async {
          seenAuthUrl = authUrl;
          return {'code': 'auth-code-xyz'};
        },
        httpClient: MockClient((req) async {
          expect(req.bodyFields['grant_type'], 'authorization_code');
          expect(req.bodyFields['code'], 'auth-code-xyz');
          expect(req.bodyFields['code_verifier'], isNotNull);
          return jsonResp(tokenResponse('INTERACTIVE-AT'), 200);
        }),
      );

      expect(await provider.getAccessToken(), 'INTERACTIVE-AT');
      expect(
        seenAuthUrl!.origin + seenAuthUrl!.path,
        'https://login.microsoftonline.com/tenant-abc/oauth2/v2.0/authorize',
      );
      expect(
        seenAuthUrl!.queryParameters['scope'],
        contains('User.ReadWrite.All'),
      );
      expect(seenAuthUrl!.queryParameters['code_challenge_method'], 'S256');
      expect(seenAuthUrl!.queryParameters['code_challenge'], isNotNull);
    });

    test('falls back to interactive when the refresh token is rejected',
        () async {
      final cache = InMemoryTokenCache();
      await cache.write(
        cachedCredentials(
          accessToken: 'OLD-AT',
          expiration: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      );
      var authorizerCalled = false;
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: cache,
        authorizer: (authUrl, redirect) async {
          authorizerCalled = true;
          return {'code': 'new-code'};
        },
        httpClient: MockClient((req) async {
          if (req.bodyFields['grant_type'] == 'refresh_token') {
            return jsonResp(jsonEncode({'error': 'invalid_grant'}), 400);
          }
          return jsonResp(tokenResponse('RECOVERED-AT'), 200);
        }),
      );

      expect(await provider.getAccessToken(), 'RECOVERED-AT');
      expect(authorizerCalled, isTrue);
    });

    test('wraps a failing authorizer in AzureAuthException', () async {
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: InMemoryTokenCache(),
        authorizer: (authUrl, redirect) async {
          throw StateError('user closed the window');
        },
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        () => provider.getAccessToken(),
        throwsA(isA<AzureAuthException>()),
      );
    });
  });

  group('corrupt cache', () {
    test('is discarded and the flow falls back to interactive', () async {
      final cache = InMemoryTokenCache();
      await cache.write('not-valid-json');
      var authorizerCalled = false;
      final provider = OAuthAuthProvider(
        credentials: credentials,
        cache: cache,
        authorizer: (authUrl, redirect) async {
          authorizerCalled = true;
          return {'code': 'c'};
        },
        httpClient: MockClient(
          (_) async => jsonResp(tokenResponse('AT-AFTER-CORRUPT'), 200),
        ),
      );
      expect(await provider.getAccessToken(), 'AT-AFTER-CORRUPT');
      expect(authorizerCalled, isTrue);
    });
  });
}
