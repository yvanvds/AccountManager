/// Microsoft Graph connector for the Arcadia Account Manager port.
///
/// Reads Azure AD / Office 365 users and groups into an immutable
/// `AzureSnapshot` using Graph `$filter`, `$select` and `/users/delta`, and
/// performs the user and group-membership writes the action set depends on.
/// Pure Dart — no Flutter, no UI coupling. See
/// `packages/azure_api/README.md` for the auth approach and design notes.
///
/// Spec: `docs/domain-model.md` §3.6, §3.8, §6.1, §8 (PAIN-2). Legacy
/// reference (read-only): `legacy-wpf/AccountApi/Azure/`.
library;

export 'src/auth/auth_provider.dart'
    show AzureAuthException, AzureAuthProvider, StaticAuthProvider;
export 'src/auth/credentials.dart' show AzureCredentials;
export 'src/auth/loopback_authorizer.dart'
    show BrowserLauncher, LoopbackAuthorizer;
export 'src/auth/oauth_auth_provider.dart'
    show InteractiveAuthorizer, OAuthAuthProvider;
export 'src/auth/token_cache.dart'
    show
        EncryptedTokenCache,
        InMemoryTokenCache,
        TokenCache,
        TokenDecrypt,
        TokenEncrypt;
export 'src/config/live_config.dart' show AzureLiveConfig;
export 'src/connector.dart' show AzureConnector;
export 'src/graph/graph_batch.dart'
    show BatchRequest, BatchResponse, GraphBatch;
export 'src/graph/graph_client.dart' show DeltaResult, GraphClient;
export 'src/graph/graph_request.dart'
    show GraphException, GraphRequest, GraphResponse;
export 'src/graph/graph_transport.dart' show GraphTransport, HttpGraphTransport;
export 'src/group_manager.dart' show GroupManager;
export 'src/models/azure_group.dart' show AzureGroup;
export 'src/models/azure_user.dart' show AzureUser;
export 'src/snapshot.dart' show AzureSnapshot;
export 'src/user_manager.dart' show UserDelta, UserManager;
