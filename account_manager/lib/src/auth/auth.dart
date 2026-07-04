/// Azure AD sign-in for the Arcadia Account Manager desktop app.
///
/// Mints bearer tokens for the resources the app talks to — Microsoft Graph,
/// the Key Vault data plane, and the AAD-only Cosmos DB account — from a single
/// operator sign-in, silent-first via the Windows WAM broker with an
/// interactive fallback (issue #98). The pure-Dart connectors stay Flutter-free;
/// this layer supplies the concrete providers behind their `AzureAuthProvider` /
/// `CosmosTokenProvider` / `KeyVaultTokenProvider` seams.
library;

export 'aad_broker.dart' show AadBroker, AadBrokerException, BrokerToken;
export 'aad_resource.dart' show AadResource;
export 'composite_broker.dart' show CompositeBroker;
export 'dpapi.dart' show Dpapi;
export 'file_token_cache.dart' show FileTokenCache;
export 'loopback_aad_broker.dart' show LoopbackAadBroker;
export 'method_channel_aad_broker.dart' show MethodChannelAadBroker;
export 'sign_in_session.dart'
    show CosmosSessionTokenProvider, GraphSessionAuthProvider, SignInSession;
