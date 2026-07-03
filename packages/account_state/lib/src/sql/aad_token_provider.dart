/// The authentication seam for the centralized Azure SQL database.
///
/// The Phase B database is provisioned **AAD-only** — there is no SQL login and
/// no stored database password (issue #82, PROJECT_OVERVIEW §6.2's plaintext
/// credentials are exactly what the port removes). Each operator connects with
/// their own Azure AD identity, so a connection needs a short-lived bearer
/// token minted for the SQL resource (`https://database.windows.net/`).
///
/// This interface hides *how* that token is obtained the same way
/// [AzureConnector]'s `AuthProvider` does for Graph: production wires an
/// interactive / `az` / MSAL-backed implementation (deferred to the adapter
/// slices), while tests and headless runs inject a [StaticAadTokenProvider].
/// Nothing above the seam knows which.
abstract interface class AadTokenProvider {
  /// Returns a valid bearer token for the Azure SQL resource
  /// (`https://database.windows.net/`). Implementations may cache and refresh;
  /// callers should treat each returned value as short-lived and re-read before
  /// opening a new connection rather than holding one indefinitely.
  Future<String> databaseAccessToken();
}

/// An [AadTokenProvider] that returns a pre-acquired token verbatim.
///
/// The default for headless tests and the opt-in live check: the token is
/// minted outside the process (e.g. `az account get-access-token --resource
/// https://database.windows.net/`) and handed in, so the package never shells
/// out or drives an interactive sign-in. Mirrors `azure_api`'s
/// `StaticAuthProvider`.
class StaticAadTokenProvider implements AadTokenProvider {
  const StaticAadTokenProvider(this._token);

  final String _token;

  @override
  Future<String> databaseAccessToken() async => _token;
}
