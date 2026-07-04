import 'package:account_core/account_core.dart' as core;

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
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
  }) async {
    // Merge the systems pulled this pass over whatever the last write recorded,
    // so a system this pass did not pull keeps its earlier stamp (#108).
    final systems = {
      ...(await readSyncState()).systems,
      ...systemSyncs,
    };
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
          systems: systems,
        ).toJson(),
      },
    );
  }

  @override
  Future<void> recordSystemSync(
    Map<core.Origin, SystemSyncMeta> systemSyncs,
  ) async {
    if (systemSyncs.isEmpty) return;
    // Merge into the existing sync-state doc, preserving the generation and the
    // materialize freshness — this is a metadata-only touch, not a view rewrite.
    final current = await readSyncState();
    await _client.upsertDocument(
      container: syncStateContainer,
      partitionKey: syncStateDocumentId,
      document: {
        'id': syncStateDocumentId,
        ...SyncState(
          generation: current.generation,
          updatedAt: current.updatedAt,
          updatedBy: current.updatedBy,
          systems: {...current.systems, ...systemSyncs},
        ).toJson(),
      },
    );
  }

  @override
  Future<SyncLease?> readLease(DateTime now) async {
    final doc = await _client.readDocument(
      container: syncStateContainer,
      id: syncLeaseDocumentId,
      partitionKey: syncLeaseDocumentId,
    );
    if (doc == null) return null;
    final lease = SyncLease.fromJson(doc);
    return lease.isExpiredAt(now) ? null : lease;
  }

  @override
  Future<LeaseOutcome> acquireLease({
    required String owner,
    required DateTime now,
  }) async {
    // Fast path: an atomic create wins iff no lease document exists (a released
    // lease is deleted, and a crashed holder's is TTL-swept). This is the hot,
    // contended path and it is race-free — two acquirers cannot both create.
    final created = await _client.createDocument(
      container: syncStateContainer,
      partitionKey: syncLeaseDocumentId,
      document: _leaseDoc(owner, now),
    );
    if (created) {
      return LeaseOutcome(acquired: true, lease: _lease(owner, now));
    }
    // A document already exists. Read it to decide.
    final doc = await _client.readDocument(
      container: syncStateContainer,
      id: syncLeaseDocumentId,
      partitionKey: syncLeaseDocumentId,
    );
    // Vanished between create and read (TTL sweep / release) — try once more.
    if (doc == null) return acquireLease(owner: owner, now: now);
    final existing = SyncLease.fromJson(doc);
    // Live lease held by someone else — blocked.
    if (existing.isLiveAt(now) && existing.owner != owner) {
      return LeaseOutcome(acquired: false, lease: existing);
    }
    // Ours already, or a crashed holder's the TTL has not yet swept: take it.
    // Overwriting an expired lease races only on crash-recovery (rare); the
    // hot path above never reaches here. Hardened further by #121.
    await _writeLease(owner, now);
    return LeaseOutcome(acquired: true, lease: _lease(owner, now));
  }

  @override
  Future<LeaseOutcome> renewLease({
    required String owner,
    required DateTime now,
  }) async {
    final doc = await _client.readDocument(
      container: syncStateContainer,
      id: syncLeaseDocumentId,
      partitionKey: syncLeaseDocumentId,
    );
    if (doc != null) {
      final existing = SyncLease.fromJson(doc);
      if (existing.isLiveAt(now) && existing.owner != owner) {
        // Lost it: it expired while we worked and another operator took over.
        return LeaseOutcome(acquired: false, lease: existing);
      }
    }
    await _writeLease(owner, now);
    return LeaseOutcome(acquired: true, lease: _lease(owner, now));
  }

  @override
  Future<void> releaseLease({required String owner}) async {
    final doc = await _client.readDocument(
      container: syncStateContainer,
      id: syncLeaseDocumentId,
      partitionKey: syncLeaseDocumentId,
    );
    if (doc == null) return;
    if (SyncLease.fromJson(doc).owner != owner) return; // taken over — leave it
    await _client.deleteDocument(
      container: syncStateContainer,
      id: syncLeaseDocumentId,
      partitionKey: syncLeaseDocumentId,
    );
  }

  SyncLease _lease(String owner, DateTime now) => SyncLease(
        owner: owner,
        heartbeatAt: now,
        expiresAt: now.add(syncLeaseTtl),
      );

  Future<void> _writeLease(String owner, DateTime now) =>
      _client.upsertDocument(
        container: syncStateContainer,
        partitionKey: syncLeaseDocumentId,
        document: _leaseDoc(owner, now),
      );

  /// The lease document: the [SyncLease] fields plus the id/partition key and a
  /// Cosmos `ttl` (seconds) so an abandoned lease is physically swept, freeing a
  /// fresh acquire.
  Map<String, dynamic> _leaseDoc(String owner, DateTime now) => {
        'id': syncLeaseDocumentId,
        'pk': syncLeaseDocumentId,
        'ttl': syncLeaseTtl.inSeconds,
        ..._lease(owner, now).toJson(),
      };

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
