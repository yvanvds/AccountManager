import 'package:azure_api/azure_api.dart' show AzureCredentials;

/// A protected resource the app mints a bearer token for.
///
/// The Microsoft identity platform (v2 / MSAL) speaks in **scopes**, not the
/// legacy v1 `resource` URIs. Each resource this app talks to maps to a fixed
/// set of scopes:
///   - Microsoft Graph — the delegated read/write scopes from
///     [AzureCredentials.scopes] (minus the OIDC/`offline_access` scopes, which
///     the broker adds itself).
///   - Azure SQL — the single `.default` scope under
///     `https://database.windows.net/`, matching the AAD-only database the port
///     provisions (issue #82).
///
/// [id] is a stable, human-readable key used only to cache tokens per resource
/// inside a [SignInSession]; it is never sent to Azure.
class AadResource {
  const AadResource({required this.id, required this.scopes});

  /// Stable cache key (e.g. `graph`, `sql`). Not sent to Azure.
  final String id;

  /// The scopes requested for this resource.
  final List<String> scopes;

  /// Microsoft Graph, scoped to the delegated permissions the connector needs.
  ///
  /// The `offline_access`/OIDC scopes carried by [AzureCredentials.scopes] are
  /// dropped here: the broker (WAM / MSAL Runtime) manages refresh internally,
  /// and mixing reserved scopes into a broker request is rejected.
  factory AadResource.graph(AzureCredentials credentials) => AadResource(
        id: 'graph',
        scopes: credentials.scopes
            .where((s) => s.startsWith('https://graph.microsoft.com/'))
            .toList(growable: false),
      );

  /// The centralized Azure SQL database (`https://database.windows.net/`).
  static const AadResource sql = AadResource(
    id: 'sql',
    scopes: <String>['https://database.windows.net/.default'],
  );

  /// The centralized Key Vault data plane (`https://vault.azure.net/`), where
  /// the WISA password and Smartschool passphrase live (issue #84).
  static const AadResource vault = AadResource(
    id: 'vault',
    scopes: <String>['https://vault.azure.net/.default'],
  );
}
