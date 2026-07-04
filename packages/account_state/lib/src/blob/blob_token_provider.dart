/// The authentication seam for the centralized Blob Storage account.
///
/// Like the Cosmos account, storage is reached with the operator's own Azure AD
/// identity (holding a data-plane role such as *Storage Blob Data Contributor*)
/// — no account key, no stored secret. Each request needs a short-lived bearer
/// token minted for the storage resource (`https://storage.azure.com`).
///
/// Mirrors [CosmosTokenProvider]: production wires the app's session-backed
/// implementation, while tests and headless runs inject a
/// [StaticBlobTokenProvider]. Nothing above the seam knows which.
abstract interface class BlobTokenProvider {
  /// Returns a valid bearer token for the storage resource
  /// (`https://storage.azure.com`). Implementations may cache and refresh;
  /// callers treat each value as short-lived and re-read before a request.
  Future<String> blobAccessToken();
}

/// A [BlobTokenProvider] that returns a pre-acquired token verbatim.
///
/// The default for headless tests and the opt-in live check: the token is
/// minted outside the process (e.g. `az account get-access-token --resource
/// https://storage.azure.com`) and handed in, so the package never shells out
/// or drives an interactive sign-in. Mirrors [StaticCosmosTokenProvider].
class StaticBlobTokenProvider implements BlobTokenProvider {
  const StaticBlobTokenProvider(this._token);

  final String _token;

  @override
  Future<String> blobAccessToken() async => _token;
}
