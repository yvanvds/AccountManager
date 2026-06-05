import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;

import 'auth_provider.dart';
import 'credentials.dart';
import 'token_cache.dart';

/// Drives the interactive leg of the auth-code flow: given the authorization
/// URL the user must visit, returns the query parameters Azure appended to the
/// redirect (`code`, `state`, …).
///
/// The package does not open browsers or bind sockets itself — that is
/// platform work. The Flutter app supplies an implementation (e.g.
/// [LoopbackAuthorizer]); tests supply a fake that returns a canned `code`.
typedef InteractiveAuthorizer = Future<Map<String, String>> Function(
  Uri authorizationUrl,
  Uri redirectUri,
);

/// Public-client OAuth2 provider using auth-code-with-PKCE against the
/// Microsoft identity platform, backed by `package:oauth2`.
///
/// Acquisition order, mirroring legacy MSAL `AcquireTokenSilent` →
/// `AcquireTokenInteractive` (`Connector.cs`):
///   1. valid cached token  → return it;
///   2. expired but refreshable → silent refresh;
///   3. otherwise → interactive sign-in via [authorizer].
///
/// PKCE (S256) is handled by `oauth2` — no client secret is sent, as required
/// for a native/desktop public client. The serialized credentials are written
/// through [cache], which must encrypt at rest (see [EncryptedTokenCache]).
class OAuthAuthProvider implements AzureAuthProvider {
  final AzureCredentials credentials;
  final TokenCache cache;
  final InteractiveAuthorizer authorizer;
  final http.Client _httpClient;

  OAuthAuthProvider({
    required this.credentials,
    required this.cache,
    required this.authorizer,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  @override
  Future<String> getAccessToken() async {
    final cached = await _loadCached();
    if (cached != null) {
      if (!cached.isExpired) return cached.accessToken;
      if (cached.canRefresh) {
        final refreshed = await _tryRefresh(cached);
        if (refreshed != null) return refreshed;
      }
    }
    return _interactive();
  }

  Future<oauth2.Credentials?> _loadCached() async {
    final stored = await cache.read();
    if (stored == null || stored.isEmpty) return null;
    try {
      return oauth2.Credentials.fromJson(stored);
    } on FormatException {
      // Corrupt cache — discard and fall back to interactive sign-in.
      await cache.clear();
      return null;
    }
  }

  /// Silent refresh. Returns the new access token, or `null` when the refresh
  /// fails (e.g. the refresh token was revoked) so the caller falls back to
  /// interactive sign-in.
  Future<String?> _tryRefresh(oauth2.Credentials cached) async {
    try {
      final refreshed = await cached.refresh(
        identifier: credentials.clientId,
        httpClient: _httpClient,
      );
      await cache.write(refreshed.toJson());
      return refreshed.accessToken;
    } on oauth2.AuthorizationException {
      await cache.clear();
      return null;
    }
  }

  Future<String> _interactive() async {
    final grant = oauth2.AuthorizationCodeGrant(
      credentials.clientId,
      credentials.authorizationEndpoint,
      credentials.tokenEndpoint,
      httpClient: _httpClient,
    );
    final authUrl = grant.getAuthorizationUrl(
      credentials.redirectUri,
      scopes: credentials.scopes,
    );

    final Map<String, String> responseParams;
    try {
      responseParams = await authorizer(authUrl, credentials.redirectUri);
    } catch (e) {
      throw AzureAuthException('interactive sign-in failed', e);
    }

    try {
      final client = await grant.handleAuthorizationResponse(responseParams);
      await cache.write(client.credentials.toJson());
      return client.credentials.accessToken;
    } on oauth2.AuthorizationException catch (e) {
      throw AzureAuthException('authorization was denied', e);
    } on FormatException catch (e) {
      throw AzureAuthException('invalid authorization response', e);
    }
  }

  /// Releases the token-endpoint HTTP client.
  void close() => _httpClient.close();
}
