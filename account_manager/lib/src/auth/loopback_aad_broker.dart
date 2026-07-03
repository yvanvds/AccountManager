import 'package:azure_api/azure_api.dart';
import 'package:http/http.dart' as http;

import 'aad_broker.dart';
import 'aad_resource.dart';

/// [AadBroker] backed by the interactive loopback OAuth flow — auth-code with
/// PKCE through the system browser — reusing `azure_api`'s [OAuthAuthProvider]
/// and [LoopbackAuthorizer].
///
/// This is the fallback for machines without the WAM broker (the dev laptop):
/// it can always sign in interactively, no native code required. It is the
/// concrete answer to the issue's "the existing OAuthAuthProvider loopback flow
/// can serve as the fallback" (#98).
///
/// It participates only in the **interactive** leg — [acquireSilent] returns
/// `null` — because [OAuthAuthProvider] cannot promise a no-prompt acquisition.
/// Once a resource has signed in, its provider caches the refresh token, so a
/// later [acquireInteractive] refreshes silently (no browser) until the refresh
/// token is revoked; and [SignInSession]'s own cache means a token is reused for
/// its whole lifetime without re-consulting this broker at all.
///
/// One [OAuthAuthProvider] is built per resource (each with that resource's
/// scopes + `offline_access`) and kept, so its cache survives across calls.
class LoopbackAadBroker implements AadBroker {
  /// Primary constructor: [providerFactory] builds the per-resource auth
  /// provider. Tests inject a fake; production uses [LoopbackAadBroker.oauth].
  LoopbackAadBroker({
    required AzureAuthProvider Function(AadResource resource) providerFactory,
    Duration assumedLifetime = const Duration(minutes: 50),
    DateTime Function()? clock,
  })  : _providerFactory = providerFactory,
        _assumedLifetime = assumedLifetime,
        _clock = clock ?? DateTime.now;

  /// Production constructor: signs in via the system browser + loopback
  /// redirect. [authorizer] is a [LoopbackAuthorizer] wired to a browser
  /// launcher; [redirectUri] must be registered on the public-client app.
  factory LoopbackAadBroker.oauth({
    required String clientId,
    required String tenantId,
    required String azureDomain,
    required String schoolPrefix,
    required InteractiveAuthorizer authorizer,
    Uri? redirectUri,
    http.Client? httpClient,
    Duration assumedLifetime = const Duration(minutes: 50),
  }) {
    final caches = <String, TokenCache>{};
    return LoopbackAadBroker(
      assumedLifetime: assumedLifetime,
      providerFactory: (resource) => OAuthAuthProvider(
        credentials: AzureCredentials(
          clientId: clientId,
          tenantId: tenantId,
          azureDomain: azureDomain,
          schoolPrefix: schoolPrefix,
          redirectUri: redirectUri,
          // The resource's scopes, plus offline_access for a refresh token.
          scopes: <String>[...resource.scopes, 'offline_access'],
        ),
        cache: caches.putIfAbsent(resource.id, InMemoryTokenCache.new),
        authorizer: authorizer,
        httpClient: httpClient,
      ),
    );
  }

  final AzureAuthProvider Function(AadResource resource) _providerFactory;
  final Duration _assumedLifetime;
  final DateTime Function() _clock;

  final Map<String, AzureAuthProvider> _providers =
      <String, AzureAuthProvider>{};

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async => null;

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    final provider =
        _providers.putIfAbsent(resource.id, () => _providerFactory(resource));
    try {
      final token = await provider.getAccessToken();
      // OAuthAuthProvider does not surface the token's expiry, and it manages
      // its own cache/refresh; a conservative lifetime just makes SignInSession
      // re-consult it (silently) sooner.
      return BrokerToken(
        accessToken: token,
        expiresOn: _clock().toUtc().add(_assumedLifetime),
      );
    } on AzureAuthException catch (e) {
      throw AadBrokerException(e.message, cause: e);
    }
  }
}
