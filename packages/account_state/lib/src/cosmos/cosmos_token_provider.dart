/// The authentication seam for the centralized Cosmos DB account.
///
/// The account is provisioned **AAD-only** (`disableLocalAuth`) — there is no
/// account key and no stored secret. Each operator connects with their own
/// Azure AD identity (holding the *Cosmos DB Built-in Data Contributor*
/// data-plane role), so a request needs a short-lived bearer token minted for
/// the Cosmos resource (`https://cosmos.azure.com`).
///
/// This interface hides *how* that token is obtained the same way
/// `AzureConnector`'s `AuthProvider` does for Graph and [KeyVaultTokenProvider]
/// does for the vault: production wires an interactive / broker-backed
/// implementation (the app's `CosmosSessionTokenProvider`), while tests and
/// headless runs inject a [StaticCosmosTokenProvider]. Nothing above the seam
/// knows which.
abstract interface class CosmosTokenProvider {
  /// Returns a valid bearer token for the Cosmos resource
  /// (`https://cosmos.azure.com`). Implementations may cache and refresh;
  /// callers should treat each returned value as short-lived and re-read before
  /// issuing a request rather than holding one indefinitely.
  Future<String> cosmosAccessToken();
}

/// A [CosmosTokenProvider] that returns a pre-acquired token verbatim.
///
/// The default for headless tests and the opt-in live check: the token is
/// minted outside the process (e.g. `az account get-access-token --resource
/// https://cosmos.azure.com`) and handed in, so the package never shells out or
/// drives an interactive sign-in. Mirrors `azure_api`'s `StaticAuthProvider` and
/// the retired `StaticAadTokenProvider`.
class StaticCosmosTokenProvider implements CosmosTokenProvider {
  const StaticCosmosTokenProvider(this._token);

  final String _token;

  @override
  Future<String> cosmosAccessToken() async => _token;
}
