/// The authentication seam for the centralized Azure SignalR service (#116).
///
/// The service is used **AAD-only** — no access key and no connection string in
/// settings. The writer posting to the REST/management endpoint authenticates
/// with its own Azure AD identity (holding a *SignalR Service Owner* / *SignalR
/// App Server* data-plane role), so a request needs a short-lived bearer token
/// minted for the SignalR resource (`https://signalr.azure.com`).
///
/// This interface hides *how* that token is obtained exactly as
/// [CosmosTokenProvider] does for Cosmos: production wires a session-backed
/// implementation (the app's `SignalRSessionTokenProvider`), while tests and
/// headless runs inject a [StaticSignalRTokenProvider]. Nothing above the seam
/// knows which.
abstract interface class SignalRTokenProvider {
  /// Returns a valid bearer token for the SignalR resource
  /// (`https://signalr.azure.com`). Implementations may cache and refresh;
  /// callers treat each returned value as short-lived and re-read before issuing
  /// a request rather than holding one indefinitely.
  Future<String> signalRAccessToken();
}

/// A [SignalRTokenProvider] that returns a pre-acquired token verbatim.
///
/// The default for headless tests and the opt-in live check: the token is
/// minted outside the process (e.g. `az account get-access-token --resource
/// https://signalr.azure.com`) and handed in, so the package never shells out or
/// drives an interactive sign-in. Mirrors [StaticCosmosTokenProvider].
class StaticSignalRTokenProvider implements SignalRTokenProvider {
  const StaticSignalRTokenProvider(this._token);

  final String _token;

  @override
  Future<String> signalRAccessToken() async => _token;
}
