import 'package:azure_api/azure_api.dart' show AzureCredentials;

import 'aad_resource.dart';

/// The Azure AD app-registration settings the sign-in layer needs.
///
/// These are school-specific and must not be baked into the binary, so they are
/// read from `--dart-define`s at build/run time (the same values the legacy
/// `Connector.Init` took). A machine without them configured runs with
/// [isConfigured] `false`, and the sign-in gate shows a "not configured"
/// message instead of failing an acquisition.
///
/// Later Phase C slices move these into the persisted `SettingsStore`; wiring
/// them from `--dart-define` keeps this slice focused on the token flow.
class AadAppConfig {
  const AadAppConfig({
    required this.clientId,
    required this.tenantId,
    required this.azureDomain,
    required this.schoolPrefix,
  });

  final String clientId;
  final String tenantId;
  final String azureDomain;
  final String schoolPrefix;

  /// Reads the config from compile-time environment defines:
  /// `AAD_CLIENT_ID`, `AAD_TENANT_ID`, `AAD_DOMAIN`, `SCHOOL_PREFIX`.
  factory AadAppConfig.fromEnvironment() => const AadAppConfig(
        clientId: String.fromEnvironment('AAD_CLIENT_ID'),
        tenantId: String.fromEnvironment('AAD_TENANT_ID'),
        azureDomain: String.fromEnvironment('AAD_DOMAIN'),
        schoolPrefix: String.fromEnvironment('SCHOOL_PREFIX'),
      );

  /// Whether enough is set to attempt a sign-in. Client and tenant are the
  /// minimum the broker needs.
  bool get isConfigured => clientId.isNotEmpty && tenantId.isNotEmpty;

  /// The STS authority for this tenant.
  String get authority => 'https://login.microsoftonline.com/$tenantId';

  /// The Graph credentials (scopes default from [AzureCredentials]).
  AzureCredentials get credentials => AzureCredentials(
        clientId: clientId,
        tenantId: tenantId,
        azureDomain: azureDomain,
        schoolPrefix: schoolPrefix,
      );

  /// The Graph resource, scoped from [credentials].
  AadResource get graph => AadResource.graph(credentials);
}
