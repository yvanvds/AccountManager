import '../materialize/linked_store.dart';
import '../materialize/materialized_state.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// The [LinkedStore] backed by the Cosmos `linkedAccounts`, `rollups`,
/// `decisions`, and `syncState` containers (#115, keystone of #112).
///
/// The materialized view is shared, read-mostly state: [writeMaterialized]
/// (sync/drift only) rewrites the per-account and rollup documents and bumps the
/// generation, while every passive session reads the rollups and lazily loads a
/// classroom's accounts — no pull, no `link()`. Operator decisions live in their
/// own documents and are only ever deleted here (when a merge drops them),
/// never rewritten by the derived-doc replace.
///
/// A rewrite is not a single transaction — Cosmos has no cross-document atomic
/// write — so [writeMaterialized] upserts the fresh set and then deletes the
/// documents that are no longer present. A reader that races a rewrite sees a
/// consistent-enough mix (the generation bump is what #116 uses to detect a
/// mid-flight change); the sync/drift lease (#108) serializes writers so two
/// rewrites never interleave.
class CosmosLinkedStore implements LinkedStore {
  CosmosLinkedStore(this._client);

  final CosmosClient _client;

  @override
  Future<SyncState> readSyncState() async {
    final doc = await _client.readDocument(
      container: syncStateContainer,
      id: syncStateDocumentId,
      partitionKey: syncStateDocumentId,
    );
    if (doc == null) return SyncState.initial;
    return SyncState.fromJson(doc);
  }

  @override
  Future<List<Rollup>> readRollups() async {
    final docs = await _client.queryDocuments(
      container: rollupsContainer,
      query: 'SELECT * FROM c',
    );
    return [for (final d in docs) Rollup.fromJson(d)];
  }

  @override
  Future<List<MaterializedAccount>> readClassroom({
    required String school,
    required String classroom,
  }) async {
    // Scoped to the school partition (cheap) and filtered to the classroom.
    final docs = await _client.queryDocuments(
      container: linkedAccountsContainer,
      query: 'SELECT * FROM c WHERE c.classroom = @classroom',
      parameters: {'@classroom': classroom},
      partitionKey: school,
    );
    return [for (final d in docs) MaterializedAccount.fromJson(d)];
  }

  @override
  Future<List<AccountDecision>> readDecisions() async {
    final docs = await _client.queryDocuments(
      container: decisionsContainer,
      query: 'SELECT * FROM c',
    );
    return [for (final d in docs) AccountDecision.fromJson(d)];
  }

  @override
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
  }) async {
    // Per-account docs: upsert the fresh set, then delete the stragglers no
    // longer present so a departed account's doc does not linger.
    await _replaceContainer(
      container: linkedAccountsContainer,
      freshIds: {for (final a in view.accounts) a.id.value},
      docsById: {
        for (final a in view.accounts)
          a.id.value: (pk: a.school, doc: a.toJson()),
      },
    );
    // Rollups: same replace, keyed by the rollup node key.
    await _replaceContainer(
      container: rollupsContainer,
      freshIds: {for (final r in view.rollups) r.key},
      docsById: {
        for (final r in view.rollups) r.key: (pk: r.school, doc: r.toJson()),
      },
    );

    // Drop the decisions the merge found no longer applicable.
    for (final d in droppedDecisions) {
      await _client.deleteDocument(
        container: decisionsContainer,
        id: decisionDocId(d),
        partitionKey: d.accountId.value,
      );
    }

    // Bump the generation last, so a reader that sees the new generation also
    // sees the rewritten docs.
    await _client.upsertDocument(
      container: syncStateContainer,
      partitionKey: syncStateDocumentId,
      document: {
        'id': syncStateDocumentId,
        ...SyncState(
          generation: view.generation,
          updatedAt: at,
          updatedBy: syncedBy,
        ).toJson(),
      },
    );
  }

  @override
  Future<void> putDecision(AccountDecision decision) async {
    await _client.upsertDocument(
      container: decisionsContainer,
      partitionKey: decision.accountId.value,
      document: {
        'id': decisionDocId(decision),
        'pk': decision.accountId.value,
        ...decision.toJson(),
      },
    );
  }

  /// Upserts every document in [docsById], then deletes any document currently
  /// in [container] whose id is not in [freshIds] — the "replace the whole set"
  /// the derived containers need without a container-level truncate.
  Future<void> _replaceContainer({
    required String container,
    required Set<String> freshIds,
    required Map<String, ({String pk, Map<String, dynamic> doc})> docsById,
  }) async {
    for (final entry in docsById.entries) {
      await _client.upsertDocument(
        container: container,
        partitionKey: entry.value.pk,
        document: entry.value.doc,
      );
    }
    final existing = await _client.queryDocuments(
      container: container,
      query: 'SELECT c.id, c.pk FROM c',
    );
    for (final doc in existing) {
      final id = doc['id'] as String?;
      if (id == null || freshIds.contains(id)) continue;
      await _client.deleteDocument(
        container: container,
        id: id,
        partitionKey: (doc['pk'] as String?) ?? id,
      );
    }
  }
}
