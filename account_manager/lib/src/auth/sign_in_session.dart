import 'package:account_state/account_state.dart'
    show
        BlobTokenProvider,
        CosmosTokenProvider,
        KeyVaultTokenProvider,
        SignalRTokenProvider;
import 'package:azure_api/azure_api.dart'
    show AzureAuthException, AzureAuthProvider;

import 'aad_broker.dart';
import 'aad_resource.dart';

/// The operator's signed-in Azure AD session for one run of the app.
///
/// Owns token acquisition for every [AadResource] the app talks to and the
/// ordering the legacy MSAL flow used (`Connector.cs`):
///   1. a cached, still-valid token for this resource → return it;
///   2. otherwise a **silent** broker acquisition (no prompt on a
///      school-account machine);
///   3. otherwise an **interactive** sign-in.
///
/// Because the broker keeps the account signed in, the interactive prompt is
/// paid at most once per session: after the first resource signs in, the
/// remaining resources (e.g. Azure SQL after Graph) are satisfied silently —
/// this is the "sign in once, not per request" requirement (issue #98).
///
/// Tokens are cached in memory only; the broker (WAM / MSAL Runtime) owns the
/// encrypted, cross-restart cache, so the app never writes bearer tokens to
/// disk itself.
class SignInSession {
  SignInSession(
    this._broker, {
    Duration refreshLeeway = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : _refreshLeeway = refreshLeeway,
        _clock = clock ?? DateTime.now;

  final AadBroker _broker;
  final Duration _refreshLeeway;
  final DateTime Function() _clock;

  final Map<String, BrokerToken> _cache = <String, BrokerToken>{};
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};

  BrokerToken? _lastGood;

  /// The account (home id / UPN) of the current session, or `null` before the
  /// first successful acquisition. Drives the "signed in as …" status.
  String? get account => _lastGood?.account;

  /// Whether any resource has been acquired this session.
  bool get isSignedIn => _lastGood != null;

  /// Returns a valid access token for [resource], acquiring it silently or
  /// interactively as needed. Concurrent calls for the same resource share a
  /// single acquisition.
  Future<String> tokenFor(AadResource resource) {
    final cached = _cache[resource.id];
    if (cached != null && !_isExpiring(cached)) {
      return Future<String>.value(cached.accessToken);
    }
    // Note the block body: `Map.remove` returns the stored future, and an
    // arrow callback would hand that back to `whenComplete`, which then waits
    // on it — a self-referential deadlock. Discard the return value.
    return _inFlight[resource.id] ??= _acquire(resource).whenComplete(() {
      _inFlight.remove(resource.id);
    });
  }

  Future<String> _acquire(AadResource resource) async {
    final silent = await _broker.acquireSilent(resource);
    if (silent != null) return _store(resource, silent);

    final interactive = await _broker.acquireInteractive(resource);
    return _store(resource, interactive);
  }

  String _store(AadResource resource, BrokerToken token) {
    _cache[resource.id] = token;
    _lastGood = token;
    return token.accessToken;
  }

  bool _isExpiring(BrokerToken token) =>
      _clock().toUtc().add(_refreshLeeway).isAfter(token.expiresOn);

  /// Clears the in-memory token cache (the broker's own account cache is
  /// untouched — a subsequent [tokenFor] can still acquire silently).
  void signOut() {
    _cache.clear();
    _lastGood = null;
  }
}

/// Adapts a [SignInSession] to the Graph auth seam. Wired into `AzureConnector`
/// so every Graph request carries the operator's bearer token.
class GraphSessionAuthProvider implements AzureAuthProvider {
  GraphSessionAuthProvider(this._session, this._graph);

  final SignInSession _session;
  final AadResource _graph;

  @override
  Future<String> getAccessToken() async {
    try {
      return await _session.tokenFor(_graph);
    } on AadBrokerException catch (e) {
      // Honour the seam's contract: Graph acquisition failures surface as
      // AzureAuthException.
      throw AzureAuthException(e.message, e);
    }
  }
}

/// Adapts a [SignInSession] to the Cosmos auth seam ([CosmosTokenProvider]) so
/// each data-plane request is authenticated with the operator's own AAD
/// identity (Cosmos DB Built-in Data Contributor), no stored account key.
class CosmosSessionTokenProvider implements CosmosTokenProvider {
  CosmosSessionTokenProvider(this._session);

  final SignInSession _session;

  @override
  Future<String> cosmosAccessToken() => _session.tokenFor(AadResource.cosmos);
}

/// Adapts a [SignInSession] to the Key Vault auth seam ([KeyVaultTokenProvider])
/// so the WISA password and Smartschool passphrase are read with the operator's
/// own AAD identity (Key Vault Secrets Officer), no stored vault secret.
class VaultSessionTokenProvider implements KeyVaultTokenProvider {
  VaultSessionTokenProvider(this._session);

  final SignInSession _session;

  @override
  Future<String> vaultAccessToken() => _session.tokenFor(AadResource.vault);
}

/// Adapts a [SignInSession] to the Blob auth seam ([BlobTokenProvider]) so
/// cold-snapshot overflow blobs are read/written with the operator's own AAD
/// identity (Storage Blob Data Contributor), no stored account key (#107).
class BlobSessionTokenProvider implements BlobTokenProvider {
  BlobSessionTokenProvider(this._session);

  final SignInSession _session;

  @override
  Future<String> blobAccessToken() => _session.tokenFor(AadResource.storage);
}

/// Adapts a [SignInSession] to the SignalR auth seam ([SignalRTokenProvider]) so
/// change signals are broadcast with the operator's own AAD identity (SignalR
/// Service Owner), no stored access key (#116).
class SignalRSessionTokenProvider implements SignalRTokenProvider {
  SignalRSessionTokenProvider(this._session);

  final SignInSession _session;

  @override
  Future<String> signalRAccessToken() => _session.tokenFor(AadResource.signalr);
}
