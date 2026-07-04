import '../settings/app_settings.dart';
import '../settings/settings_store.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// A [SettingsStore] backed by the centralized Cosmos `settings` container.
///
/// The Cosmos successor to `AzureSqlSettingsStore`: the same [AppSettings]
/// model, persisted once for the whole team instead of in each operator's
/// `config.json`. Nothing above the seam changes — the orchestration layer still
/// loads once at startup and saves on operator edits.
///
/// Where the SQL store shredded the config across typed columns and a child
/// import-rules table, Cosmos stores the whole model as **one JSON document**
/// (id [settingsDocumentId], its own logical partition), reusing
/// [AppSettings.toJson] / [AppSettings.fromJson] unchanged — the config is
/// document-shaped, which is the point of the migration. No secret is written: a
/// profile contributes only its `SecretRef` name, resolved out of band through
/// the Key Vault `SecretProvider`.
///
/// A single-document upsert is atomic, so [save] "replaces the previous value"
/// with no transaction and a partially written config can never be read back.
class CosmosSettingsStore implements SettingsStore {
  CosmosSettingsStore(this._client);

  final CosmosClient _client;

  @override
  Future<AppSettings> load() async {
    final doc = await _client.readDocument(
      container: settingsContainer,
      id: settingsDocumentId,
      partitionKey: settingsDocumentId,
    );
    // No document yet is first-run, not an error: mirror the file/in-memory
    // stores and hand back a default config so the caller has no special case.
    if (doc == null) return const AppSettings();
    final settings = doc['settings'];
    if (settings is! Map<String, dynamic>) return const AppSettings();
    return AppSettings.fromJson(settings);
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _client.upsertDocument(
      container: settingsContainer,
      partitionKey: settingsDocumentId,
      document: {
        'id': settingsDocumentId,
        'settings': settings.toJson(),
      },
    );
  }
}
