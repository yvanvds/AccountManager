import 'dart:convert';

import 'package:account_manager/src/auth/auth.dart';
import 'package:azure_api/azure_api.dart'
    show
        AzureAuthException,
        AzureAuthProvider,
        AzureCredentials,
        InMemoryTokenCache,
        TokenCache;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A per-resource auth provider stand-in for [OAuthAuthProvider].
class _FakeProvider implements AzureAuthProvider {
  _FakeProvider(this._result);
  final Object _result; // a String token, or an Exception to throw.
  int calls = 0;

  @override
  Future<String> getAccessToken() async {
    calls++;
    final r = _result;
    if (r is String) return r;
    throw r;
  }
}

/// Builds an unsigned JWT (`header.payload.signature`) carrying [claims]. The
/// decoder never verifies the signature, so a literal `sig` segment suffices.
String _jwt(Map<String, Object?> claims) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none', 'typ': 'JWT'})}.${seg(claims)}.sig';
}

void main() {
  final graph = AadResource.graph(AzureCredentials(
    clientId: 'c',
    tenantId: 't',
    azureDomain: 'd',
    schoolPrefix: 'p',
  ));

  test('acquireSilent without a silent acquirer returns null', () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) => _FakeProvider('SHOULD-NOT-BE-USED'),
    );
    expect(await broker.acquireSilent(graph), isNull);
  });

  test('acquireInteractive returns the provider token with a future expiry',
      () async {
    final now = DateTime.utc(2026, 1, 1, 12);
    final broker = LoopbackAadBroker(
      providerFactory: (_) => _FakeProvider('AT'),
      assumedLifetime: const Duration(minutes: 50),
      clock: () => now,
    );

    final token = await broker.acquireInteractive(graph);
    expect(token.accessToken, 'AT');
    expect(token.expiresOn, now.add(const Duration(minutes: 50)));
  });

  test('acquireInteractive stamps the operator UPN decoded from the JWT (#169)',
      () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) =>
          _FakeProvider(_jwt({'upn': 'yvan@school.example'})),
    );

    final token = await broker.acquireInteractive(graph);
    expect(token.account, 'yvan@school.example',
        reason: 'so session.account is populated and syncedBy is non-empty');
  });

  test('an opaque (non-JWT) token leaves the operator unknown, gracefully',
      () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) => _FakeProvider('opaque-access-token'),
    );

    final token = await broker.acquireInteractive(graph);
    expect(token.account, isNull);
  });

  group('operatorAccountFromJwt', () {
    test('prefers upn over the other identity claims', () {
      final token = _jwt({
        'upn': 'yvan@school.example',
        'preferred_username': 'other@school.example',
        'unique_name': 'nope@school.example',
        'email': 'nope2@school.example',
      });
      expect(operatorAccountFromJwt(token), 'yvan@school.example');
    });

    test('falls back to preferred_username, then unique_name, then email', () {
      expect(
        operatorAccountFromJwt(
            _jwt({'preferred_username': 'a@school.example'})),
        'a@school.example',
      );
      expect(
        operatorAccountFromJwt(_jwt({'unique_name': 'b@school.example'})),
        'b@school.example',
      );
      expect(
        operatorAccountFromJwt(_jwt({'email': 'c@school.example'})),
        'c@school.example',
      );
    });

    test('returns null for an opaque, truncated, or claimless token', () {
      expect(operatorAccountFromJwt('opaque'), isNull);
      expect(operatorAccountFromJwt('only.two'), isNull);
      expect(operatorAccountFromJwt('not.base64!.sig'), isNull);
      expect(operatorAccountFromJwt(_jwt({'sub': 'no-upn-here'})), isNull);
      expect(operatorAccountFromJwt(_jwt({'upn': ''})), isNull);
    });
  });

  test('reuses one provider per resource so its cache survives calls',
      () async {
    final providers = <String, _FakeProvider>{};
    final broker = LoopbackAadBroker(
      providerFactory: (r) =>
          providers.putIfAbsent(r.id, () => _FakeProvider('AT')),
    );

    await broker.acquireInteractive(graph);
    await broker.acquireInteractive(graph);
    // Same provider instance both times (built once, then reused).
    expect(providers.length, 1);
    expect(providers['graph']!.calls, 2);
  });

  test('wraps an AzureAuthException as an AadBrokerException', () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) =>
          _FakeProvider(const AzureAuthException('sign-in was denied')),
    );

    await expectLater(
      broker.acquireInteractive(graph),
      throwsA(isA<AadBrokerException>()
          .having((e) => e.message, 'message', 'sign-in was denied')),
    );
  });

  group('oauth factory silent leg', () {
    // oauth2 requires the token endpoint to declare a JSON content type.
    http.Response jsonResp(Map<String, Object?> body) => http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );

    Map<String, Object?> tokenBody(String accessToken, {String? scope}) => {
          'token_type': 'Bearer',
          'access_token': accessToken,
          'expires_in': 3600,
          'refresh_token': 'refresh-for-$accessToken',
          if (scope != null) 'scope': scope,
        };

    /// The production broker over a scripted token endpoint: interactive
    /// exchanges an auth code, silent redeems refresh tokens. Records every
    /// refresh request and each authorizer invocation.
    (LoopbackAadBroker, List<Map<String, String>>, List<Uri>) build({
      bool rejectRefresh = false,
      TokenCache Function(String resourceId)? cacheFactory,
    }) {
      final refreshRequests = <Map<String, String>>[];
      final authorizerCalls = <Uri>[];
      final broker = LoopbackAadBroker.oauth(
        clientId: 'client-123',
        tenantId: 'tenant-abc',
        azureDomain: 'school.example',
        schoolPrefix: 'GBS',
        cacheFactory: cacheFactory,
        authorizer: (authUrl, redirect) async {
          authorizerCalls.add(authUrl);
          return {'code': 'auth-code-xyz'};
        },
        httpClient: MockClient((req) async {
          final fields = req.bodyFields;
          if (fields['grant_type'] == 'refresh_token') {
            refreshRequests.add(fields);
            if (rejectRefresh) {
              return http.Response(
                jsonEncode({'error': 'invalid_grant'}),
                400,
                headers: {'content-type': 'application/json'},
              );
            }
            return jsonResp(tokenBody('REFRESHED-AT'));
          }
          return jsonResp(tokenBody('INTERACTIVE-AT'));
        }),
      );
      return (broker, refreshRequests, authorizerCalls);
    }

    test('returns null when no resource has signed in yet', () async {
      final (broker, refreshRequests, authorizerCalls) = build();

      expect(await broker.acquireSilent(AadResource.cosmos), isNull);
      expect(refreshRequests, isEmpty);
      expect(authorizerCalls, isEmpty);
    });

    test('redeems another resource\'s refresh token — no browser round-trip',
        () async {
      final (broker, refreshRequests, authorizerCalls) = build();

      // Graph pays the one interactive prompt…
      await broker.acquireInteractive(graph);
      expect(authorizerCalls, hasLength(1));

      // …then cosmos is minted silently from Graph's refresh token, with the
      // cosmos scopes requested on the refresh grant.
      final cosmos = await broker.acquireSilent(AadResource.cosmos);
      expect(cosmos, isNotNull);
      expect(cosmos!.accessToken, 'REFRESHED-AT');
      expect(authorizerCalls, hasLength(1), reason: 'no second prompt');
      expect(refreshRequests, hasLength(1));
      expect(
        refreshRequests.single['scope'],
        contains('https://cosmos.azure.com/.default'),
      );

      // The minted credentials are cached: a repeat silent acquisition needs
      // neither the authorizer nor the token endpoint.
      final again = await broker.acquireSilent(AadResource.cosmos);
      expect(again!.accessToken, 'REFRESHED-AT');
      expect(refreshRequests, hasLength(1));
    });

    test('a rejected refresh token yields null (fall back to interactive)',
        () async {
      final (broker, refreshRequests, _) = build(rejectRefresh: true);

      await broker.acquireInteractive(graph);

      expect(await broker.acquireSilent(AadResource.cosmos), isNull);
      expect(refreshRequests, isNotEmpty, reason: 'the redeem was attempted');
    });

    test('the silent leg stamps the operator UPN from the refreshed JWT (#169)',
        () async {
      // The refresh grant returns a JWT access token; the silently-minted
      // resource token then carries the decoded operator (the real seed for
      // syncedBy in a resumed session).
      final jwt = _jwt({'upn': 'yvan@school.example'});
      final broker = LoopbackAadBroker.oauth(
        clientId: 'client-123',
        tenantId: 'tenant-abc',
        azureDomain: 'school.example',
        schoolPrefix: 'GBS',
        authorizer: (authUrl, redirect) async => {'code': 'auth-code-xyz'},
        httpClient: MockClient((req) async => jsonResp(tokenBody(jwt))),
      );

      await broker.acquireInteractive(graph);
      final cosmos = await broker.acquireSilent(AadResource.cosmos);
      expect(cosmos!.account, 'yvan@school.example');
    });

    test('a persistent cache survives a "restart" — silent, no browser',
        () async {
      // The same backing store handed to two broker instances models an app
      // restart with the DPAPI file cache (#103): the second run signs in
      // with no interactive prompt at all.
      final store = <String, TokenCache>{};
      TokenCache persistent(String id) =>
          store.putIfAbsent(id, InMemoryTokenCache.new);

      final (first, _, firstAuthorizer) = build(cacheFactory: persistent);
      await first.acquireInteractive(graph);
      expect(firstAuthorizer, hasLength(1));

      final (second, _, secondAuthorizer) = build(cacheFactory: persistent);
      final token = await second.acquireSilent(graph);

      expect(token, isNotNull);
      expect(token!.accessToken, 'INTERACTIVE-AT',
          reason: 'the persisted, still-valid token is reused as-is');
      expect(secondAuthorizer, isEmpty, reason: 'no browser on the re-run');
    });
  });
}
