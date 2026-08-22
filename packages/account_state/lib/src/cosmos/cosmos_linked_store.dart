import 'dart:async';
import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:crypto/crypto.dart';

import '../materialize/linked_state_materializer.dart';
import '../materialize/linked_store.dart';
import '../materialize/materialized_state.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';
import 'cosmos_retry.dart';

/// The field every materialized document (account, group, rollup) carries its
/// own content hash in, so the next write can tell "identical" from "changed"
/// without reading the document back (#200).
///
/// Written by [CosmosLinkedStore] alongside the document's own fields and read
/// back by the straggler projection; nothing else interprets it, and the
/// `fromJson` factories ignore it.
const String contentHashField = 'contentHash';

/// A stable content hash of one materialized document.
///
/// Computed over the **whole** serialized document — every field, nested
/// candidates and decisions included — rather than a chosen subset, because a
/// hash that misses a field is worse than no hash at all: the change would be
/// skipped and an operator's edit would silently never reach the shared store.
/// The encoding is canonical (map keys sorted at every level), so the hash
/// depends on the document's *content* and not on the order `toJson` happened
/// to build its maps in.
///
/// [document] must be the freshly serialized document, i.e. *without* a
/// [contentHashField] of its own — the hash is stamped on afterwards.
String materializedContentHash(Map<String, dynamic> document) =>
    sha256.convert(utf8.encode(_canonicalJson(document))).toString();

String _canonicalJson(Object? value) {
  final out = StringBuffer();
  _writeCanonical(out, value);
  return out.toString();
}

void _writeCanonical(StringBuffer out, Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    out.write('{');
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) out.write(',');
      out
        ..write(jsonEncode(entries[i].key.toString()))
        ..write(':');
      _writeCanonical(out, entries[i].value);
    }
    out.write('}');
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(out, value[i]);
    }
    out.write(']');
  } else {
    out.write(jsonEncode(value));
  }
}

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
/// write — so [writeMaterialized] upserts the documents whose content actually
/// changed (#200) and then deletes the ones that are no longer present. A
/// reader that races a rewrite sees a consistent-enough mix (the generation
/// bump — which stays unconditional — is what #116 uses to detect a
/// mid-flight change); the sync/drift lease (#108) serializes writers so two
/// rewrites never interleave.
///
/// [writeApplied] (#254) is the other write path: an apply's handful of touched
/// documents plus the rollup nodes above them, run **unleased** and concurrently
/// with every other operator's apply. It is safe there precisely because it does
/// none of the above — it stands down for a live sync lease, moves counts by
/// delta rather than by replacement, and conditions every write on the ETag of
/// the version it replaces.
class CosmosLinkedStore implements LinkedStore {
  /// [governor] is the shared throttling state (#196): pass the *same* instance
  /// that was wired into the [CosmosClient], so the fan-out narrows in response
  /// to the 429s these very writes provoke. Left unset (tests, and any caller
  /// whose client does not report) the fan-out simply stays at
  /// [CosmosThrottleGovernor.maxConcurrency].
  CosmosLinkedStore(this._client, {CosmosThrottleGovernor? governor})
      : _governor = governor ?? CosmosThrottleGovernor();

  final CosmosClient _client;

  /// How many per-document upserts/deletes may be in flight at once during a
  /// [writeMaterialized] container replace, and how that ceiling reacts to
  /// throttling. A full account container is ~9.6k docs; a bounded fan-out turns
  /// thousands of serial round-trips into a write that finishes in a fraction of
  /// the wall-clock (#168), and narrowing it while the account is throttling
  /// keeps the write progressing instead of hammering a limit it has already hit
  /// (#196).
  final CosmosThrottleGovernor _governor;

  /// Emit a progress line every this many upserts (plus one at the end), so a
  /// long write ticks in the operator log rather than looking hung (#168).
  static const int _progressEvery = 1000;

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
  Future<List<MaterializedGroup>> readGroups() async {
    // The whole group set lives in one logical partition (groupsPartition) and
    // is small, so a single scoped query returns it all (#119).
    final docs = await _client.queryDocuments(
      container: linkedGroupsContainer,
      query: 'SELECT * FROM c',
      partitionKey: groupsPartition,
    );
    return [for (final d in docs) MaterializedGroup.fromJson(d)];
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
    void Function(String message)? onProgress,
  }) async {
    // Merge the systems pulled this pass over whatever the last write recorded,
    // so a system this pass did not pull keeps its earlier stamp (#108).
    final systems = {
      ...(await readSyncState()).systems,
      ...systemSyncs,
    };
    // Per-account docs: upsert the ones that changed, then delete the
    // stragglers no longer present so a departed account's doc does not linger.
    // This is the big one (~9.6k docs); its progress is what the operator sees
    // ticking.
    await _replaceContainer(
      container: linkedAccountsContainer,
      freshIds: {for (final a in view.accounts) a.id.value},
      docsById: {
        for (final a in view.accounts)
          a.id.value: (pk: a.school, doc: a.toJson()),
      },
      // The labels are what the progress line names the container with, and it
      // goes straight into the operator's Log panel (#266) — so they are the
      // words the app already uses, not the container names.
      label: 'accounts',
      onProgress: onProgress,
    );
    // Per-group docs: same replace, in the single groups partition (#119).
    await _replaceContainer(
      container: linkedGroupsContainer,
      freshIds: {for (final g in view.groups) g.id.value},
      docsById: {
        for (final g in view.groups)
          g.id.value: (pk: g.school, doc: g.toJson()),
      },
      label: 'klasgroepen',
      onProgress: onProgress,
    );
    // Rollups: same replace, keyed by the rollup node key.
    await _replaceContainer(
      container: rollupsContainer,
      freshIds: {for (final r in view.rollups) r.key},
      docsById: {
        for (final r in view.rollups) r.key: (pk: r.school, doc: r.toJson()),
      },
      label: 'tellingen',
      onProgress: onProgress,
    );

    // Drop the decisions the merge found no longer applicable.
    await _runBounded(
      droppedDecisions,
      (d) => _client.deleteDocument(
        container: decisionsContainer,
        id: decisionDocId(d),
        partitionKey: d.accountId.value,
      ),
    );

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
  Future<AppliedWrite> writeApplied(
    AppliedPatch patch, {
    required String appliedBy,
    required DateTime at,
  }) async {
    // Rule 1: stand down for a sync. That pass republishes the whole view from a
    // fresher link than ours, so a narrow patch must not land on top of it — nor
    // bump the generation past it (#254).
    final lease = await readLease(at);
    if (lease != null && lease.owner != appliedBy) {
      return AppliedWrite.deferred(lease);
    }
    if (patch.isEmpty) return const AppliedWrite.unchanged();

    // Rule 3: every document write is conditioned on the version it replaces, and
    // that very version is what the delta below is computed against — so a
    // concurrent writer can never split the pair.
    final storedAccounts = <MaterializedAccount>[];
    for (final fresh in patch.accounts) {
      final before = await _replaceDocument(
        container: linkedAccountsContainer,
        id: fresh.id.value,
        partitionKey: fresh.school,
        body: fresh.toJson(),
      );
      if (before != null) {
        storedAccounts.add(MaterializedAccount.fromJson(before));
      }
    }
    for (final id in patch.removedAccountIds) {
      // No partition key to point at: the document is gone from the fresh view,
      // so where it used to sit is only knowable from the store itself.
      final before = await _removeDocument(
        container: linkedAccountsContainer,
        id: id,
      );
      if (before != null) {
        storedAccounts.add(MaterializedAccount.fromJson(before));
      }
    }

    final storedGroups = <MaterializedGroup>[];
    for (final fresh in patch.groups) {
      final before = await _replaceDocument(
        container: linkedGroupsContainer,
        id: fresh.id.value,
        partitionKey: groupsPartition,
        body: fresh.toJson(),
      );
      if (before != null) storedGroups.add(MaterializedGroup.fromJson(before));
    }
    for (final id in patch.removedGroupIds) {
      final before = await _removeDocument(
        container: linkedGroupsContainer,
        id: id,
        partitionKey: groupsPartition,
      );
      if (before != null) storedGroups.add(MaterializedGroup.fromJson(before));
    }

    // Rule 2: the rollups move by delta, so two operators clearing different
    // work in the same class compose instead of overwriting each other.
    for (final change in rollupChangesFor(
      storedAccounts: storedAccounts,
      freshAccounts: patch.accounts,
      storedGroups: storedGroups,
      freshGroups: patch.groups,
    )) {
      await _adjustRollup(change);
    }

    // Last, as in [writeMaterialized]: a reader that sees the new generation
    // also sees the patched documents.
    return AppliedWrite.written(await _bumpGeneration(appliedBy, at));
  }

  /// Creates-or-replaces one derived document, returning the document it
  /// replaced (or `null` when there was none).
  ///
  /// Conditioned throughout: an absent document is claimed with an atomic
  /// create, a present one with an `If-Match` on the ETag just read. A loser
  /// re-reads and retries — every iteration means some writer committed, so it
  /// converges, exactly as [putDecision] does. The returned "before" is what the
  /// caller's rollup delta must be computed against, which is why this returns
  /// it rather than the caller reading it separately.
  Future<Map<String, dynamic>?> _replaceDocument({
    required String container,
    required String id,
    required String partitionKey,
    required Map<String, dynamic> body,
  }) async {
    final document = {...body, contentHashField: materializedContentHash(body)};
    while (true) {
      final existing = await _client.readDocument(
        container: container,
        id: id,
        partitionKey: partitionKey,
      );
      if (existing == null) {
        final created = await _client.createDocument(
          container: container,
          partitionKey: partitionKey,
          document: document,
        );
        if (created) return null;
        continue; // another writer created it first — condition on theirs
      }
      final outcome = await _client.upsertDocument(
        container: container,
        partitionKey: partitionKey,
        document: document,
        ifMatch: existing['_etag'] as String?,
      );
      if (outcome.applied) return existing;
    }
  }

  /// Deletes one derived document, returning what it held (or `null` when it was
  /// already gone). With no [partitionKey] the document is located by a
  /// cross-partition read on its id — the case where the fresh view no longer
  /// says where it used to sit.
  Future<Map<String, dynamic>?> _removeDocument({
    required String container,
    required String id,
    String? partitionKey,
  }) async {
    Map<String, dynamic>? existing;
    if (partitionKey != null) {
      existing = await _client.readDocument(
        container: container,
        id: id,
        partitionKey: partitionKey,
      );
    } else {
      final found = await _client.queryDocuments(
        container: container,
        query: 'SELECT * FROM c WHERE c.id = @id',
        parameters: {'@id': id},
      );
      existing = found.isEmpty ? null : found.first;
    }
    if (existing == null) return null;
    await _client.deleteDocument(
      container: container,
      id: id,
      partitionKey: partitionKey ?? (existing['pk'] as String?) ?? id,
    );
    return existing;
  }

  /// Folds one [RollupChange] into the node the store currently holds, under the
  /// same ETag discipline as the documents beneath it: a losing write re-reads
  /// the winner's node and adds its delta on top, so concurrent applies to one
  /// class accumulate rather than clobber. A node left with no documents is
  /// deleted — the sync path would not emit it either.
  Future<void> _adjustRollup(RollupChange change) async {
    while (true) {
      final existing = await _client.readDocument(
        container: rollupsContainer,
        id: change.key,
        partitionKey: change.school,
      );
      final next =
          change.applyTo(existing == null ? null : Rollup.fromJson(existing));
      if (next == null) {
        if (existing != null) {
          await _client.deleteDocument(
            container: rollupsContainer,
            id: change.key,
            partitionKey: change.school,
          );
        }
        return;
      }
      final body = next.toJson();
      final document = {
        ...body,
        contentHashField: materializedContentHash(body),
      };
      if (existing == null) {
        final created = await _client.createDocument(
          container: rollupsContainer,
          partitionKey: change.school,
          document: document,
        );
        if (created) return;
        continue;
      }
      final outcome = await _client.upsertDocument(
        container: rollupsContainer,
        partitionKey: change.school,
        document: document,
        ifMatch: existing['_etag'] as String?,
      );
      if (outcome.applied) return;
    }
  }

  /// Bumps the shared generation for an apply and returns what it wrote.
  ///
  /// Conditioned, unlike the sync path's unconditional stamp: two applies
  /// finishing together must produce two distinct generations, or the second
  /// would broadcast a number a receiver has already seen and gate its own
  /// refetch out.
  Future<int> _bumpGeneration(String appliedBy, DateTime at) async {
    while (true) {
      final existing = await _client.readDocument(
        container: syncStateContainer,
        id: syncStateDocumentId,
        partitionKey: syncStateDocumentId,
      );
      final next =
          (existing == null ? SyncState.initial : SyncState.fromJson(existing))
              .bumped(at: at, by: appliedBy);
      final document = {'id': syncStateDocumentId, ...next.toJson()};
      if (existing == null) {
        final created = await _client.createDocument(
          container: syncStateContainer,
          partitionKey: syncStateDocumentId,
          document: document,
        );
        if (created) return next.generation;
        continue;
      }
      final outcome = await _client.upsertDocument(
        container: syncStateContainer,
        partitionKey: syncStateDocumentId,
        document: document,
        ifMatch: existing['_etag'] as String?,
      );
      if (outcome.applied) return next.generation;
    }
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
    final id = decisionDocId(decision);
    final pk = decision.accountId.value;
    final document = {
      'id': id,
      'pk': pk,
      ...decision.toJson(),
    };
    // Per-document optimistic concurrency (#121). Decisions are frequent,
    // per-account writes that the coarse sync lease deliberately does not gate,
    // so two operators writing decisions on *different* accounts touch
    // different docs and never contend, while two writing the *same* account's
    // decision serialize through the ETag: the first commits, the second's
    // If-Match is stale, and it re-reads the winner's ETag and retries. Each
    // iteration makes progress (some writer committed), so the loop converges.
    while (true) {
      final existing = await _client.readDocument(
        container: decisionsContainer,
        id: id,
        partitionKey: pk,
      );
      if (existing == null) {
        // No doc yet: an atomic create wins iff we are first. A concurrent
        // create races to a 409, on which we re-read to condition the retry.
        final created = await _client.createDocument(
          container: decisionsContainer,
          partitionKey: pk,
          document: document,
        );
        if (created) return;
        continue;
      }
      final outcome = await _client.upsertDocument(
        container: decisionsContainer,
        partitionKey: pk,
        document: document,
        ifMatch: existing['_etag'] as String?,
      );
      if (outcome.applied) return;
      // Stale: another operator wrote this decision between our read and write.
      // Loop to re-read its ETag and retry.
    }
  }

  @override
  Future<void> deleteDecision(AccountDecision decision) async {
    await _client.deleteDocument(
      container: decisionsContainer,
      id: decisionDocId(decision),
      partitionKey: decision.accountId.value,
    );
  }

  /// Brings [container] to exactly [docsById]: upserts the documents whose
  /// content actually changed and deletes any document currently in [container]
  /// whose id is not in [freshIds] — the "replace the whole set" the derived
  /// containers need without a container-level truncate.
  ///
  /// **Only what changed is written (#200).** Nearly every document of a
  /// re-sync is byte-identical to the stored one, and rewriting all ~9.6k of
  /// them wholesale is what generated the write burst that tripped #196 —
  /// which the retry/backoff there absorbs but cannot remove. So each fresh
  /// document carries a [materializedContentHash] in [contentHashField], and
  /// the upsert is skipped when the stored document already hashes the same.
  /// The single id/pk/hash projection below answers both questions at once: an
  /// id the fresh set no longer has is a straggler to delete, and an id whose
  /// stored hash still matches is a write to skip. The generation bump in
  /// [writeMaterialized] stays unconditional, so readers still detect the new
  /// view even when not one document moved.
  ///
  /// The upserts and deletes run with bounded concurrency (the [_governor]'s
  /// ceiling) rather than strictly one at a time: a first, full write is ~9.6k
  /// docs, and issuing that many serial round-trips is what made a full sync
  /// look hung (#168). The ceiling is not a fixed guess: it narrows on every 429
  /// the client reports and widens back as the account keeps up, so a
  /// real-volume write adapts to the provisioned throughput instead of assuming
  /// a safe width (#196). When [onProgress] and [label] are given, a line is
  /// emitted every [_progressEvery] upserts (and once at the end) so a long
  /// write is visible.
  Future<void> _replaceContainer({
    required String container,
    required Set<String> freshIds,
    required Map<String, ({String pk, Map<String, dynamic> doc})> docsById,
    String? label,
    void Function(String message)? onProgress,
  }) async {
    // One projection read, both answers: what to delete and what to skip. Read
    // *before* the writes — every id this pass writes is in [freshIds], so the
    // straggler set is the same either way, and doing it first is what makes
    // the stored hashes available to compare against.
    final existing = await _client.queryDocuments(
      container: container,
      query: 'SELECT c.id, c.pk, c.$contentHashField FROM c',
    );
    final storedHashes = <String, String>{};
    final stragglers = <({String id, String pk})>[];
    for (final doc in existing) {
      final id = doc['id'];
      if (id is! String) continue;
      if (!freshIds.contains(id)) {
        stragglers.add((id: id, pk: (doc['pk'] as String?) ?? id));
        continue;
      }
      final hash = doc[contentHashField];
      // A document stored before #200 carries no hash; it is rewritten once and
      // hashed from then on.
      if (hash is String) storedHashes[id] = hash;
    }

    final writes = <({String pk, Map<String, dynamic> doc})>[];
    var unchanged = 0;
    for (final entry in docsById.entries) {
      final hash = materializedContentHash(entry.value.doc);
      if (storedHashes[entry.key] == hash) {
        unchanged++;
        continue;
      }
      writes.add((
        pk: entry.value.pk,
        doc: {...entry.value.doc, contentHashField: hash},
      ));
    }

    final total = writes.length;
    if (label != null && onProgress != null && unchanged > 0) {
      onProgress(
        'Opslaan van $label: $unchanged ongewijzigd, $total te schrijven…',
      );
    }
    await _runBounded(
      writes,
      (entry) => _client.upsertDocument(
        container: container,
        partitionKey: entry.pk,
        document: entry.doc,
      ),
      onDone: (label == null || onProgress == null)
          ? null
          : (done) {
              if (done == total || done % _progressEvery == 0) {
                onProgress('Opslaan van $label: $done/$total…');
              }
            },
    );
    await _runBounded(
      stragglers,
      (s) => _client.deleteDocument(
        container: container,
        id: s.id,
        partitionKey: s.pk,
      ),
    );
  }

  /// Runs [action] over [items] with at most [CosmosThrottleGovernor.concurrency]
  /// futures in flight at once, calling [onDone] with the running completed
  /// count after each. A worker-pool (not fixed chunks) keeps the pool full —
  /// the slowest item in a chunk never idles the rest.
  ///
  /// The pool is *elastic* (#196): the governor narrows `concurrency` on every
  /// 429 the client sees, and a worker that finds the pool wider than the
  /// current ceiling retires (never the last one, so progress is always made);
  /// as throttling eases and the ceiling widens again, a finishing worker tops
  /// the pool back up.
  ///
  /// A failure is *terminal for the whole pass*: the first error is captured,
  /// every other worker stops claiming items at its next turn, and only once all
  /// of them have wound down is the error rethrown. This is what keeps a failed
  /// persist from leaving unawaited workers firing writes into an account that
  /// has already been reported as failed — the second consequence in #196.
  Future<void> _runBounded<T>(
    Iterable<T> items,
    Future<void> Function(T) action, {
    void Function(int done)? onDone,
  }) async {
    final list = items.toList(growable: false);
    if (list.isEmpty) return;
    var next = 0;
    var done = 0;
    var active = 0;
    Object? failure;
    StackTrace? failureStack;
    final drained = Completer<void>();
    late final void Function() spawn;

    Future<void> worker() async {
      try {
        while (true) {
          if (failure != null) return; // a sibling failed: stop claiming work
          // The governor narrowed the fan-out under throttling; shed a worker,
          // but never the last one.
          if (active > _governor.concurrency && active > 1) return;
          final i = next++;
          if (i >= list.length) return;
          await action(list[i]);
          onDone?.call(++done);
          // Throttling eased and there is work left: widen back out. The number
          // of new workers is decided *once* — a spawned worker that finds
          // nothing to do returns (and decrements `active`) synchronously, so
          // re-reading `active` in the loop condition would never terminate.
          final room = _governor.concurrency - active;
          for (var w = 0; w < room && next < list.length; w++) {
            spawn();
          }
        }
      } catch (e, st) {
        failure ??= e;
        failureStack ??= st;
      } finally {
        active--;
        if (active == 0 && !drained.isCompleted) drained.complete();
      }
    }

    spawn = () {
      active++;
      unawaited(worker());
    };

    final pool = list.length < _governor.concurrency
        ? list.length
        : _governor.concurrency;
    for (var w = 0; w < pool; w++) {
      spawn();
    }
    await drained.future;
    final error = failure;
    if (error != null) {
      Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
    }
  }
}
