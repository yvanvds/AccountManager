import '../passwords/password_entry.dart';
import '../passwords/password_queue_store.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// A [PasswordQueueStore] backed by the centralized Cosmos `passwordQueue`
/// container.
///
/// The Cosmos successor to `AzureSqlPasswordQueueStore`: the same
/// [PasswordEntry] queue, shared by the whole team instead of living on the
/// generating operator's disk. That sharing is the point — one operator
/// generates the passwords and another prints the sheets, which only works if
/// both see the one queue.
///
/// Where the SQL store spread the queue across one row per entry, Cosmos keeps
/// the **whole queue in one document** (id [passwordQueueDocumentId]) with the
/// entries as a JSON array, reusing [PasswordEntry.toJson] / [PasswordEntry.fromJson]
/// unchanged. A single-document upsert is atomic and preserves array order, so
/// [save] faithfully "replaces the whole queue" — including draining it after
/// distribution, when the operator saves the remaining (usually empty) list —
/// with no transaction and no partial-queue read.
class CosmosPasswordQueueStore implements PasswordQueueStore {
  CosmosPasswordQueueStore(this._client);

  final CosmosClient _client;

  @override
  Future<List<PasswordEntry>> load() async {
    final doc = await _client.readDocument(
      container: passwordQueueContainer,
      id: passwordQueueDocumentId,
      partitionKey: passwordQueuePartitionKeyValue,
    );
    // A never-persisted queue reads as an empty list, not an error.
    if (doc == null) return [];
    final entries = doc['entries'];
    if (entries is! List) return [];
    return [
      for (final e in entries)
        if (e is Map<String, dynamic>) PasswordEntry.fromJson(e),
    ];
  }

  @override
  Future<void> save(List<PasswordEntry> entries) async {
    await _client.upsertDocument(
      container: passwordQueueContainer,
      partitionKey: passwordQueuePartitionKeyValue,
      document: {
        'id': passwordQueueDocumentId,
        'pk': passwordQueuePartitionKeyValue,
        'entries': [for (final e in entries) e.toJson()],
      },
    );
  }
}
