/// Static configuration for talking to one Azure AD tenant.
///
/// Mirrors the arguments the legacy `Connector.Init` took (`clientId`,
/// `tenantId`, `azureDomain`, `schoolPrefix`); the parent-window handle is
/// dropped — the interactive browser flow is supplied by an authorizer
/// callback instead (`docs/domain-model.md` §6.1).
class AzureCredentials {
  /// Application (client) id of the registered Azure AD app.
  final String clientId;

  /// Directory (tenant) id, or a value like `organizations` / `common`.
  final String tenantId;

  /// The verified domain users live under, e.g. `school.example`. Student
  /// UPNs are minted under `student.<azureDomain>`; staff under
  /// `<azureDomain>`.
  final String azureDomain;

  /// School prefix used to scope the `$filter` reads and group listing — the
  /// heart of the PAIN-2 fix.
  final String schoolPrefix;

  /// Redirect URI for the public-client flow. Defaults to a fixed loopback
  /// address, as Azure requires for native/desktop apps. The port must be
  /// fixed (not ephemeral) because it is baked into the authorization URL and
  /// the loopback server has to bind exactly that port.
  final Uri redirectUri;

  /// Delegated scopes requested. Defaults to the legacy `User.ReadWrite.All`
  /// plus `offline_access` (needed for refresh tokens) and the OIDC scopes.
  final List<String> scopes;

  AzureCredentials({
    required this.clientId,
    required this.tenantId,
    required this.azureDomain,
    required this.schoolPrefix,
    Uri? redirectUri,
    List<String>? scopes,
  })  : redirectUri =
            redirectUri ?? Uri.parse('http://localhost:8765/auth-redirect'),
        scopes = scopes ??
            const [
              'https://graph.microsoft.com/User.ReadWrite.All',
              'https://graph.microsoft.com/Group.ReadWrite.All',
              'offline_access',
            ];

  /// Microsoft identity-platform authorization endpoint for this tenant.
  Uri get authorizationEndpoint => Uri.parse(
        'https://login.microsoftonline.com/$tenantId/oauth2/v2.0/authorize',
      );

  /// Microsoft identity-platform token endpoint for this tenant.
  Uri get tokenEndpoint => Uri.parse(
        'https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token',
      );
}
