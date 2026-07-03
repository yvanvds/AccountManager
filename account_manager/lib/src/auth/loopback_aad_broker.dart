import 'package:azure_api/azure_api.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;

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
/// The **silent** leg honours the "sign in once per session" requirement: an
/// AAD refresh token is issued per client (app), not per scope set, so once
/// any resource has signed in interactively, [acquireSilent] redeems that
/// refresh token for the next resource's scopes with no browser round-trip.
/// With a persistent [cacheFactory] (the DPAPI-encrypted file cache, #103)
/// the refresh token also survives restarts, so a returning operator signs in
/// with no browser at all; the default in-memory caches pay one interactive
/// prompt per run (Graph at startup — SQL and Key Vault always follow
/// silently).
///
/// One [OAuthAuthProvider] is built per resource (each with that resource's
/// scopes + `offline_access`) and kept, so its cache survives across calls.
class LoopbackAadBroker implements AadBroker {
  /// Primary constructor: [providerFactory] builds the per-resource auth
  /// provider and [silentAcquirer] (when given) implements the no-prompt leg.
  /// Tests inject fakes; production uses [LoopbackAadBroker.oauth].
  LoopbackAadBroker({
    required AzureAuthProvider Function(AadResource resource) providerFactory,
    Future<BrokerToken?> Function(AadResource resource)? silentAcquirer,
    Duration assumedLifetime = const Duration(minutes: 50),
    DateTime Function()? clock,
  })  : _providerFactory = providerFactory,
        _silentAcquirer = silentAcquirer,
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
    DateTime Function()? clock,
    TokenCache Function(String resourceId)? cacheFactory,
  }) {
    final client = httpClient ?? http.Client();
    final now = clock ?? DateTime.now;
    final makeCache = cacheFactory ?? ((_) => InMemoryTokenCache());
    final caches = <String, TokenCache>{};
    TokenCache cacheFor(String id) =>
        caches.putIfAbsent(id, () => makeCache(id));

    // Materializes the cache on first use — with a persistent factory that
    // is what reads the previous run's credentials back off disk.
    Future<oauth2.Credentials?> storedCredentials(String id) async {
      final String? stored;
      try {
        stored = await cacheFor(id).read();
      } on FormatException {
        // Undecryptable payload (tampered / another user's): no cache.
        return null;
      }
      if (stored == null || stored.isEmpty) return null;
      try {
        return oauth2.Credentials.fromJson(stored);
      } on FormatException {
        return null;
      }
    }

    BrokerToken asBrokerToken(oauth2.Credentials credentials) => BrokerToken(
          accessToken: credentials.accessToken,
          expiresOn: credentials.expiration?.toUtc() ??
              now().toUtc().add(assumedLifetime),
        );

    Future<BrokerToken?> silent(AadResource resource) async {
      // 1. This resource's own cached token, still valid.
      final own = await storedCredentials(resource.id);
      if (own != null && !own.isExpired) return asBrokerToken(own);

      // 2. Redeem a held refresh token for this resource's scopes — own
      //    first, then any other signed-in resource's. An AAD refresh token
      //    is issued per client, not per scope set, so the Graph sign-in can
      //    silently mint the SQL and Key Vault tokens.
      final donors = <oauth2.Credentials>[
        if (own != null && own.canRefresh) own,
      ];
      for (final id in caches.keys.toList()) {
        if (id == resource.id) continue;
        final other = await storedCredentials(id);
        if (other != null && other.canRefresh) donors.add(other);
      }

      for (final donor in donors) {
        try {
          final refreshed = await donor.refresh(
            identifier: clientId,
            newScopes: <String>[...resource.scopes, 'offline_access'],
            httpClient: client,
          );
          await cacheFor(resource.id).write(refreshed.toJson());
          return asBrokerToken(refreshed);
        } on Exception {
          // Rejected/revoked refresh token or a malformed response — try the
          // next donor; with none left the caller falls back to interactive.
          continue;
        }
      }
      return null;
    }

    return LoopbackAadBroker(
      assumedLifetime: assumedLifetime,
      clock: clock,
      silentAcquirer: silent,
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
        cache: cacheFor(resource.id),
        authorizer: authorizer,
        httpClient: client,
      ),
    );
  }

  final AzureAuthProvider Function(AadResource resource) _providerFactory;
  final Future<BrokerToken?> Function(AadResource resource)? _silentAcquirer;
  final Duration _assumedLifetime;
  final DateTime Function() _clock;

  final Map<String, AzureAuthProvider> _providers =
      <String, AzureAuthProvider>{};

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async =>
      _silentAcquirer?.call(resource);

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
