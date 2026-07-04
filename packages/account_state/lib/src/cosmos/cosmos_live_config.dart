import 'dart:io';

/// Configuration for the opt-in Cosmos DB live checks
/// (`test/integration/cosmos_*_live_test.dart`).
///
/// The checks exercise the real `account_state` Cosmos adapters end to end
/// against the provisioned account: mint a bearer token for
/// `https://cosmos.azure.com`, then read/write the `settings`, `identity` and
/// `passwordQueue` containers through [HttpCosmosClient]. Per the repo
/// live-testing policy the identity check writes only under a disposable,
/// namespaced natural key it deletes afterwards; the settings and queue checks
/// round-trip their own singleton documents.
///
/// Offline unit tests never read this. See `.cosmos.env.example` at the
/// repository root for the variable names.
class CosmosLiveConfig {
  const CosmosLiveConfig({
    required this.endpoint,
    required this.database,
    required this.accessToken,
  });

  /// The account data-plane endpoint under test, e.g.
  /// `https://accountmanager-cosmos-arcadia.documents.azure.com:443/`.
  final String endpoint;

  /// The database (SQL API) name under test.
  final String database;

  /// A pre-acquired bearer token for `https://cosmos.azure.com`. Expires in
  /// ~1 hour, so it is minted fresh per run rather than stored (e.g.
  /// `az account get-access-token --resource https://cosmos.azure.com`).
  final String accessToken;

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'COSMOS_ENDPOINT',
    'COSMOS_DATABASE',
    'COSMOS_ACCESS_TOKEN',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `COSMOS_ACCESS_TOKEN` is empty
  /// or missing — the integration tests use this as their skip signal, so
  /// `dart test` stays offline by default.
  ///
  /// Throws [ArgumentError] when `COSMOS_ACCESS_TOKEN` is set but one of the
  /// other required variables is missing.
  static CosmosLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessToken = (source['COSMOS_ACCESS_TOKEN'] ?? '').trim();
    if (accessToken.isEmpty) return null;

    String required(String name) {
      final value = (source[name] ?? '').trim();
      if (value.isEmpty) {
        throw ArgumentError(
          'COSMOS_ACCESS_TOKEN is set but $name is missing or empty.',
        );
      }
      return value;
    }

    return CosmosLiveConfig(
      endpoint: required('COSMOS_ENDPOINT'),
      database: required('COSMOS_DATABASE'),
      accessToken: accessToken,
    );
  }
}
