import 'dart:async';

import 'package:account_core/account_core.dart' as core;

import '../materialize/linked_store.dart';
import '../materialize/materialized_state.dart';
import 'cosmos_client.dart';
import 'cosmos_config.dart';
import 'cosmos_retry.dart';

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
    // Per-account docs: upsert the fresh set, then delete the stragglers no
    // longer present so a departed account's doc does not linger. This is the
    // big one (~9.6k docs); its progress is what the operator sees ticking.
    await _replaceContainer(
      container: linkedAccountsContainer,
      freshIds: {for (final a in view.accounts) a.id.value},
      docsById: {
        for (final a in view.accounts)
          a.id.value: (pk: a.school, doc: a.toJson()),
      },
      label: 'accounts',
      onProgress: onProgress,
    );
    // Per-group docs: same wholesale replace, in the single groups partition
    // (#119).
    await _replaceContainer(
      container: linkedGroupsContainer,
      freshIds: {for (final g in view.groups) g.id.value},
      docsById: {
        for (final g in view.groups)
          g.id.value: (pk: g.school, doc: g.toJson()),
      },
      label: 'groups',
      onProgress: onProgress,
    );
    // Rollups: same replace, keyed by the rollup node key.
    await _replaceContainer(
      container: rollupsContainer,
      freshIds: {for (final r in view.rollups) r.key},
      docsById: {
        for (final r in view.rollups) r.key: (pk: r.school, doc: r.toJson()),
      },
      label: 'rollups',
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

  /// Upserts every document in [docsById], then deletes any document currently
  /// in [container] whose id is not in [freshIds] — the "replace the whole set"
  /// the derived containers need without a container-level truncate.
  ///
  /// The upserts and deletes run with bounded concurrency (the [_governor]'s
  /// ceiling) rather than strictly one at a time: a full account container is
  /// ~9.6k docs, and issuing that many serial round-trips is what made a full
  /// sync look hung (#168). The ceiling is not a fixed guess: it narrows on
  /// every 429 the client reports and widens back as the account keeps up, so a
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
    final total = docsById.length;
    await _runBounded(
      docsById.values,
      (entry) => _client.upsertDocument(
        container: container,
        partitionKey: entry.pk,
        document: entry.doc,
      ),
      onDone: (label == null || onProgress == null)
          ? null
          : (done) {
              if (done == total || done % _progressEvery == 0) {
                onProgress('Persisting $label: $done/$total…');
              }
            },
    );
    final existing = await _client.queryDocuments(
      container: container,
      query: 'SELECT c.id, c.pk FROM c',
    );
    final stragglers = [
      for (final doc in existing)
        if (doc['id'] is String && !freshIds.contains(doc['id']))
          (
            id: doc['id'] as String,
            pk: (doc['pk'] as String?) ?? doc['id'] as String,
          ),
    ];
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
