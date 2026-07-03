/// The authentication seam for the centralized Azure Key Vault.
///
/// The vault is RBAC-authorized (issue #84): each operator connects with their
/// own Azure AD identity (holding *Key Vault Secrets Officer*), so a data-plane
/// call needs a short-lived bearer token minted for the vault resource
/// (`https://vault.azure.net/`). There is no stored vault secret — exactly the
/// plaintext-credential removal the port is about (PROJECT_OVERVIEW §6.2).
///
/// This mirrors [AadTokenProvider], which does the same for the Azure SQL
/// resource: the two stay separate because a bearer token is scoped to one
/// resource and the vault and database tokens are not interchangeable.
/// Production wires an interactive / `az` / MSAL-backed implementation (deferred
/// to the app wiring); tests and headless runs inject a
/// [StaticKeyVaultTokenProvider].
abstract interface class KeyVaultTokenProvider {
  /// Returns a valid bearer token for the Key Vault resource
  /// (`https://vault.azure.net/`). Implementations may cache and refresh;
  /// callers should treat each returned value as short-lived and re-read before
  /// each request rather than holding one indefinitely.
  Future<String> vaultAccessToken();
}

/// A [KeyVaultTokenProvider] that returns a pre-acquired token verbatim.
///
/// The default for headless tests and the opt-in live check: the token is
/// minted outside the process (e.g. `az account get-access-token --resource
/// https://vault.azure.net/`) and handed in, so the package never shells out or
/// drives an interactive sign-in. Mirrors [StaticAadTokenProvider].
class StaticKeyVaultTokenProvider implements KeyVaultTokenProvider {
  const StaticKeyVaultTokenProvider(this._token);

  final String _token;

  @override
  Future<String> vaultAccessToken() async => _token;
}
