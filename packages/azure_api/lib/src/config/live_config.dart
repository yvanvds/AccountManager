import 'dart:io';

/// Configuration for talking to a live Azure AD tenant.
///
/// Used by the capture script (`tool/capture_responses.dart`) and the opt-in,
/// **read-only** integration test (`test/integration/azure_live_test.dart`).
/// Offline unit tests never read this; they inject a fake transport and a
/// [StaticAuthProvider].
///
/// See `.azure.env.example` at the repository root for the variable names.
class AzureLiveConfig {
  final String clientId;
  final String tenantId;
  final String azureDomain;
  final String schoolPrefix;

  /// A pre-acquired bearer token. The live test is read-only and does not run
  /// the interactive sign-in, so the token is supplied directly (e.g. from
  /// `az account get-access-token`).
  final String accessToken;

  const AzureLiveConfig({
    required this.clientId,
    required this.tenantId,
    required this.azureDomain,
    required this.schoolPrefix,
    required this.accessToken,
  });

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'AZURE_CLIENT_ID',
    'AZURE_TENANT_ID',
    'AZURE_DOMAIN',
    'AZURE_SCHOOL_PREFIX',
    'AZURE_ACCESS_TOKEN',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `AZURE_ACCESS_TOKEN` is
  /// empty or missing — the integration test uses this as its skip signal, so
  /// `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `AZURE_ACCESS_TOKEN` is set but one of the
  /// other required variables is missing.
  static AzureLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessToken = (source['AZURE_ACCESS_TOKEN'] ?? '').trim();
    if (accessToken.isEmpty) return null;

    String required(String name) {
      final value = (source[name] ?? '').trim();
      if (value.isEmpty) {
        throw ArgumentError(
          'AZURE_ACCESS_TOKEN is set but $name is missing or empty.',
        );
      }
      return value;
    }

    return AzureLiveConfig(
      clientId: required('AZURE_CLIENT_ID'),
      tenantId: required('AZURE_TENANT_ID'),
      azureDomain: required('AZURE_DOMAIN'),
      schoolPrefix: required('AZURE_SCHOOL_PREFIX'),
      accessToken: accessToken,
    );
  }
}
