import 'package:account_core/account_core.dart' as core;

import 'materialized_state.dart';

/// The persistence seam for the materialized reconcile view (#115, keystone of
/// #112).
///
/// The write path (sync / check-for-drift only) replaces the derived per-account
/// docs and rollups and bumps the generation; the read path (every passive
/// session) reads the rollups and lazily loads one classroom's accounts, with
/// **no connector pull and no `link()`**. Operator [AccountDecision]s live in
/// their own documents so a re-sync never clobbers them — [writeMaterialized]
/// only deletes the ones a merge dropped.
///
/// Kept an interface with an in-memory [InMemoryLinkedStore] fake and the
/// Cosmos-backed `CosmosLinkedStore` production implementation, mirroring the
/// other persistence seams in this package.
abstract interface class LinkedStore {
  /// The freshness + generation marker, or [SyncState.initial] when nothing has
  /// been materialized yet (first ever run) — so first-run has no special case.
  Future<SyncState> readSyncState();

  /// Every rollup node (school / grade-year / classroom), for building the
  /// drill-down tree. Cheap: the aggregates never touch the per-account docs.
  Future<List<Rollup>> readRollups();

  /// The per-account docs in one classroom, loaded lazily on drill-down.
  Future<List<MaterializedAccount>> readClassroom({
    required String school,
    required String classroom,
  });

  /// Every persisted operator decision (read by the sync path to merge).
  Future<List<AccountDecision>> readDecisions();

  /// Replaces the derived view with [view] — per-account docs and rollups — and
  /// bumps the stored generation to [MaterializedView.generation]. Deletes the
  /// [droppedDecisions] a merge found no longer applicable. Records the per-system
  /// last-sync metadata in [systemSyncs] (the systems this pass pulled), merged
  /// into the stored map so a system not pulled this pass keeps its earlier
  /// stamp (#108). Only the sync/drift process calls this.
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
  });

  /// Creates or replaces one operator decision. The write seam #109/#110 use;
  /// this issue ships no UI that calls it, but tests and the merge round-trip
  /// through it.
  Future<void> putDecision(AccountDecision decision);

  /// Merges [systemSyncs] into the stored per-system last-sync metadata
  /// **without** rewriting the view or bumping the generation (#108) — the light
  /// write the smart-sync "WISA unchanged" path uses to still stamp who/when it
  /// pulled, so passive sessions see fresh per-system freshness even when the
  /// materialized view did not change.
  Future<void> recordSystemSync(Map<core.Origin, SystemSyncMeta> systemSyncs);

  /// The live sync/drift lease as of [now], or `null` when none is held (never
  /// taken, released, or expired). Used to disable a passive session's
  /// Synchronise/Check-for-drift while another operator is syncing (#108).
  Future<SyncLease?> readLease(DateTime now);

  /// Attempts to take the coarse sync/drift lease for [owner] as of [now].
  ///
  /// Succeeds ([LeaseOutcome.acquired]) when the lease is free — never taken,
  /// released, expired, or already [owner]'s — writing a fresh lease that
  /// expires at `now + syncLeaseTtl`. Fails when another operator holds a live
  /// lease, returning that holder in [LeaseOutcome.lease] so the caller can name
  /// them. Only the sync/drift process calls this.
  Future<LeaseOutcome> acquireLease({
    required String owner,
    required DateTime now,
  });

  /// Heart-beats [owner]'s lease as of [now], pushing its expiry to
  /// `now + syncLeaseTtl`. Returns [LeaseOutcome.acquired] false when the lease
  /// was lost meanwhile (expired and taken by another operator), so a long sync
  /// can notice it no longer holds the lease.
  Future<LeaseOutcome> renewLease({
    required String owner,
    required DateTime now,
  });

  /// Releases the lease if it is [owner]'s. A no-op when someone else already
  /// holds it (a taken-over lease must not be released out from under them).
  Future<void> releaseLease({required String owner});
}

/// The stable document id for a decision: one per account + kind + situation.
String decisionDocId(AccountDecision d) =>
    '${d.accountId.value}|${d.kind.toJson()}|${d.targetKind}';

/// An in-memory [LinkedStore] for tests and headless runs.
///
/// Models the store's contract with no infra: a global replace on
/// [writeMaterialized] (a sync recomputes the whole view), point reads for the
/// rollups/classrooms, and a decision map keyed by [decisionDocId]. The Cosmos
/// wire behaviour is covered separately by `CosmosLinkedStore`'s unit tests.
class InMemoryLinkedStore implements LinkedStore {
  final Map<String, MaterializedAccount> _accounts = {};
  List<Rollup> _rollups = const [];
  final Map<String, AccountDecision> _decisions = {};
  SyncState _syncState = SyncState.initial;
  SyncLease? _lease;

  /// How many accounts are currently stored — for test assertions.
  int get accountCount => _accounts.length;

  @override
  Future<SyncState> readSyncState() async => _syncState;

  @override
  Future<List<Rollup>> readRollups() async => List.of(_rollups);

  @override
  Future<List<MaterializedAccount>> readClassroom({
    required String school,
    required String classroom,
  }) async =>
      [
        for (final a in _accounts.values)
          if (a.school == school && a.classroom == classroom) a,
      ];

  @override
  Future<List<AccountDecision>> readDecisions() async =>
      List.of(_decisions.values);

  @override
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
  }) async {
    _accounts
      ..clear()
      ..addEntries(view.accounts.map((a) => MapEntry(a.id.value, a)));
    _rollups = List.of(view.rollups);
    for (final d in droppedDecisions) {
      _decisions.remove(decisionDocId(d));
    }
    _syncState = SyncState(
      generation: view.generation,
      updatedAt: at,
      updatedBy: syncedBy,
      // Merge: a system not pulled this pass keeps its earlier stamp.
      systems: {..._syncState.systems, ...systemSyncs},
    );
  }

  @override
  Future<void> putDecision(AccountDecision decision) async {
    _decisions[decisionDocId(decision)] = decision;
  }

  @override
  Future<void> recordSystemSync(
    Map<core.Origin, SystemSyncMeta> systemSyncs,
  ) async {
    _syncState = SyncState(
      generation: _syncState.generation,
      updatedAt: _syncState.updatedAt,
      updatedBy: _syncState.updatedBy,
      systems: {..._syncState.systems, ...systemSyncs},
    );
  }

  @override
  Future<SyncLease?> readLease(DateTime now) async {
    final lease = _lease;
    if (lease == null || lease.isExpiredAt(now)) return null;
    return lease;
  }

  @override
  Future<LeaseOutcome> acquireLease({
    required String owner,
    required DateTime now,
  }) async {
    final lease = _lease;
    if (lease != null && lease.isLiveAt(now) && lease.owner != owner) {
      return LeaseOutcome(acquired: false, lease: lease);
    }
    return LeaseOutcome(acquired: true, lease: _take(owner, now));
  }

  @override
  Future<LeaseOutcome> renewLease({
    required String owner,
    required DateTime now,
  }) async {
    final lease = _lease;
    if (lease != null && lease.isLiveAt(now) && lease.owner != owner) {
      // Expired while we worked and another operator took over.
      return LeaseOutcome(acquired: false, lease: lease);
    }
    return LeaseOutcome(acquired: true, lease: _take(owner, now));
  }

  @override
  Future<void> releaseLease({required String owner}) async {
    if (_lease?.owner == owner) _lease = null;
  }

  SyncLease _take(String owner, DateTime now) => _lease = SyncLease(
        owner: owner,
        heartbeatAt: now,
        expiresAt: now.add(syncLeaseTtl),
      );
}
