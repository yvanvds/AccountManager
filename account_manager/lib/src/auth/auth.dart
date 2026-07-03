/// Azure AD sign-in for the Arcadia Account Manager desktop app.
///
/// Mints bearer tokens for both resources the app talks to — Microsoft Graph
/// and the AAD-only Azure SQL database — from a single operator sign-in,
/// silent-first via the Windows WAM broker with an interactive fallback
/// (issue #98). The pure-Dart connectors stay Flutter-free; this layer supplies
/// the concrete providers behind their `AzureAuthProvider` / `AadTokenProvider`
/// seams.
library;

export 'aad_broker.dart' show AadBroker, AadBrokerException, BrokerToken;
export 'aad_resource.dart' show AadResource;
export 'method_channel_aad_broker.dart' show MethodChannelAadBroker;
export 'sign_in_session.dart'
    show GraphSessionAuthProvider, SignInSession, SqlSessionTokenProvider;
