/// Supplies a bearer token for Graph calls.
///
/// The Dart equivalent of the legacy MSAL `IAuthenticationProvider`
/// (`Connector.cs`): [GraphClient] calls [getAccessToken] before each request
/// and sets the `Authorization` header. Implementations handle silent
/// acquisition, refresh, and interactive fallback.
abstract interface class AzureAuthProvider {
  /// Returns a valid access token, refreshing or prompting interactively as
  /// needed. Throws [AzureAuthException] when a token cannot be obtained.
  Future<String> getAccessToken();
}

/// Thrown when authentication cannot produce a usable access token.
class AzureAuthException implements Exception {
  final String message;
  final Object? cause;

  const AzureAuthException(this.message, [this.cause]);

  @override
  String toString() =>
      'AzureAuthException: $message${cause != null ? ' ($cause)' : ''}';
}

/// A fixed-token provider. Useful for read-only live tests and for callers
/// that already hold a token from elsewhere.
class StaticAuthProvider implements AzureAuthProvider {
  final String token;

  const StaticAuthProvider(this.token);

  @override
  Future<String> getAccessToken() async => token;
}
