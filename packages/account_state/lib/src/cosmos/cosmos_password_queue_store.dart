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

  /// The ETag observed at the last [load] (and refreshed after each [save]), so
  /// a [save] conditions on the version this session actually read. `null` means
  /// "no version observed yet" — the queue doc has never been read, so the first
  /// write creates it unconditioned (#121).
  String? _etag;

  @override
  Future<List<PasswordEntry>> load() async {
    final doc = await _client.readDocument(
      container: passwordQueueContainer,
      id: passwordQueueDocumentId,
      partitionKey: passwordQueuePartitionKeyValue,
    );
    // A never-persisted queue reads as an empty list, not an error.
    if (doc == null) {
      _etag = null;
      return [];
    }
    _etag = doc['_etag'] as String?;
    final entries = doc['entries'];
    if (entries is! List) return [];
    return [
      for (final e in entries)
        if (e is Map<String, dynamic>) PasswordEntry.fromJson(e),
    ];
  }

  @override
  Future<void> save(List<PasswordEntry> entries) async {
    final document = {
      'id': passwordQueueDocumentId,
      'pk': passwordQueuePartitionKeyValue,
      'entries': [for (final e in entries) e.toJson()],
    };
    // Guard the shared queue with per-document optimistic concurrency (#121).
    // One operator generates passwords while another drains the queue after
    // printing; both computed their list from an earlier [load], so an
    // unconditioned write would let the later save silently clobber the other's.
    // Conditioning on the loaded ETag serializes them: whoever commits first
    // wins, the other's If-Match is stale, and it reloads the current ETag and
    // retries. Each iteration follows a committed write, so the loop converges.
    while (true) {
      final outcome = await _client.upsertDocument(
        container: passwordQueueContainer,
        partitionKey: passwordQueuePartitionKeyValue,
        document: document,
        ifMatch: _etag,
      );
      if (outcome.applied) {
        _etag = outcome.etag;
        return;
      }
      // Stale: the queue changed under us. Re-read to refresh the ETag, then
      // retry the write against the current version.
      final doc = await _client.readDocument(
        container: passwordQueueContainer,
        id: passwordQueueDocumentId,
        partitionKey: passwordQueuePartitionKeyValue,
      );
      _etag = doc?['_etag'] as String?;
    }
  }
}
