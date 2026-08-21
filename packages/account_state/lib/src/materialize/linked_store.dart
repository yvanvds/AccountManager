import 'package:account_core/account_core.dart' as core;

import 'linked_state_materializer.dart';
import 'materialized_state.dart';

/// The persistence seam for the materialized reconcile view (#115, keystone of
/// #112).
///
/// The full write path (sync / check-for-drift only) replaces the derived
/// per-account docs and rollups and bumps the generation; the narrow write path
/// ([writeApplied], #254) patches just the documents one apply changed and moves
/// the rollups above them by delta; the read path (every passive session) reads
/// the rollups and lazily loads one classroom's accounts, with **no connector
/// pull and no `link()`**. Operator [AccountDecision]s live in their own
/// documents so a re-sync never clobbers them — [writeMaterialized] only deletes
/// the ones a merge dropped.
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

  /// Every per-group doc (#119), loaded lazily when the "Klasgroepen" node is
  /// opened. Reads the single [groupsPartition]; there are few, so no narrower
  /// filter is needed.
  Future<List<MaterializedGroup>> readGroups();

  /// Every persisted operator decision (read by the sync path to merge).
  Future<List<AccountDecision>> readDecisions();

  /// Replaces the derived view with [view] — per-account docs and rollups — and
  /// bumps the stored generation to [MaterializedView.generation]. Deletes the
  /// [droppedDecisions] a merge found no longer applicable. Records the per-system
  /// last-sync metadata in [systemSyncs] (the systems this pass pulled), merged
  /// into the stored map so a system not pulled this pass keeps its earlier
  /// stamp (#108). Only the sync/drift process calls this.
  ///
  /// A full view is ~9.6k account docs, so a real write can take a while.
  /// [onProgress], when given, is called with human-readable progress lines
  /// (e.g. `Persisting accounts: 2000/9600…`) so a long write is visible in the
  /// operator log rather than looking hung (#168).
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
    Map<core.Origin, SystemSyncMeta> systemSyncs = const {},
    void Function(String message)? onProgress,
  });

  /// Creates or replaces one operator decision. The write seam #109/#110 use;
  /// this issue ships no UI that calls it, but tests and the merge round-trip
  /// through it.
  Future<void> putDecision(AccountDecision decision);

  /// Deletes one operator decision (matched by its [decisionDocId]). The revoke
  /// path #109 uses to un-accept a duplicate: a no-op when the decision is not
  /// present (already revoked, or swept by a merge).
  Future<void> deleteDecision(AccountDecision decision);

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

  /// Writes back the **narrow slice** of the materialized view one real apply
  /// changed (#254): the touched per-account / per-group documents, the rollup
  /// nodes above them, and a bumped generation.
  ///
  /// The counterpart of [writeMaterialized], and deliberately nothing like it.
  /// A sync recomputes and republishes the whole ~9.6k-document view under the
  /// coarse sync lease; an apply writes one row (or a classroom's worth) and
  /// runs unleased and concurrently with every other operator's apply. Doing
  /// that through [writeMaterialized] was not affordable, which is exactly why
  /// #236 kept its correction local and left the shared view stale for everyone
  /// else — this is the seam that closes it.
  ///
  /// Three rules make it safe to run without the lease:
  ///
  /// 1. **It stands down for a sync.** When another operator holds a live
  ///    sync/drift lease as of [at], nothing is written and the holder comes
  ///    back in [AppliedWrite.deferredTo]. That pass is rewriting the whole view
  ///    from a *fresher* link than this session's, so letting a narrow patch
  ///    land on top of it — or worse, bump the generation past it — would be
  ///    precisely the "a local correction outranks the shared view" this issue
  ///    must not create. The applied writes are real regardless; the shared
  ///    counts simply catch up when that sync finishes.
  /// 2. **The rollups move by delta, never by replacement.** What each touched
  ///    document contributed *in the store* is subtracted and what it
  ///    contributes now is added ([rollupChangesFor]), so two operators clearing
  ///    different work in the same class compose instead of overwriting each
  ///    other's counts.
  /// 3. **Every document write is conditioned on the version it replaces**, so
  ///    the delta and the document it was computed from cannot come apart under
  ///    a concurrent writer: a losing write re-reads and recomputes.
  ///
  /// What it does **not** attempt is a merge of two operators' candidate lists
  /// for the *same* account: the last writer's document wins there, and the next
  /// full sync — which recomputes everything from scratch — is what heals it.
  ///
  /// Returns the generation it wrote so the caller can adopt it (a session that
  /// wrote the view is current, not ahead of it) and name it in a
  /// [ChangeSignal.viewChanged]; an empty patch writes nothing and bumps
  /// nothing.
  Future<AppliedWrite> writeApplied(
    AppliedPatch patch, {
    required String appliedBy,
    required DateTime at,
  });
}

/// The slice of the materialized view one **real apply** changed (#254) — the
/// input to [LinkedStore.writeApplied].
///
/// Built by the reconcile controller from the targets its pass resolved: for
/// each one, the freshly re-derived document, or its id in the `removed…` lists
/// when the refreshed link no longer has a document for it at all (a student
/// whose last account was just deleted, a class group that is gone).
class AppliedPatch {
  const AppliedPatch({
    this.accounts = const [],
    this.groups = const [],
    this.removedAccountIds = const [],
    this.removedGroupIds = const [],
  });

  /// Freshly derived documents for the accounts/staff the pass wrote to.
  final List<MaterializedAccount> accounts;

  /// Freshly derived documents for the class groups the pass wrote to (#119).
  final List<MaterializedGroup> groups;

  /// Ids the pass wrote to whose account document the refreshed link no longer
  /// produces — the stored document must go with them.
  final List<String> removedAccountIds;

  /// The same for class-group documents.
  final List<String> removedGroupIds;

  /// True when the patch names no document at all, so there is nothing to write
  /// and no reason to bump the generation.
  bool get isEmpty =>
      accounts.isEmpty &&
      groups.isEmpty &&
      removedAccountIds.isEmpty &&
      removedGroupIds.isEmpty;

  bool get isNotEmpty => !isEmpty;
}

/// What one [LinkedStore.writeApplied] did (#254).
class AppliedWrite {
  const AppliedWrite._(this.generation, this.deferredTo);

  /// The patch landed and the shared view is now at [generation].
  const AppliedWrite.written(int generation) : this._(generation, null);

  /// Nothing was written because [lease]'s holder is mid sync/drift — they are
  /// republishing the whole view from a fresher link, so a narrow patch must not
  /// land on top of it.
  const AppliedWrite.deferred(SyncLease lease) : this._(null, lease);

  /// Nothing was written because the patch named no document.
  const AppliedWrite.unchanged() : this._(null, null);

  /// The generation the patch wrote, or `null` when nothing was written.
  final int? generation;

  /// The sync lease this write stood down for, when it did.
  final SyncLease? deferredTo;

  /// Whether the shared view actually moved.
  bool get written => generation != null;
}

/// The stable document id for a decision: one per account + kind + situation.
String decisionDocId(AccountDecision d) =>
    '${d.accountId.value}|${d.kind.toJson()}|${d.targetKind}';

/// An in-memory [LinkedStore] for tests and headless runs.
///
/// Models the store's contract with no infra: a global replace on
/// [writeMaterialized] (a sync recomputes the whole view), a per-document patch
/// with delta'd rollups on [writeApplied] (an apply corrects what it wrote),
/// point reads for the rollups/classrooms, and a decision map keyed by
/// [decisionDocId]. The Cosmos wire behaviour is covered separately by
/// `CosmosLinkedStore`'s unit tests.
///
/// Each method runs to completion with no `await` between its reads and its
/// writes, so — exactly as on the event loop the real sessions share — two
/// "operators" driving one instance interleave only between calls, never inside
/// one.
class InMemoryLinkedStore implements LinkedStore {
  final Map<String, MaterializedAccount> _accounts = {};
  final Map<String, MaterializedGroup> _groups = {};
  List<Rollup> _rollups = const [];
  final Map<String, AccountDecision> _decisions = {};
  SyncState _syncState = SyncState.initial;
  SyncLease? _lease;

  /// How many accounts are currently stored — for test assertions.
  int get accountCount => _accounts.length;

  /// How many group docs are currently stored — for test assertions.
  int get groupCount => _groups.length;

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
  Future<List<MaterializedGroup>> readGroups() async => List.of(_groups.values);

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
    void Function(String message)? onProgress,
  }) async {
    _accounts
      ..clear()
      ..addEntries(view.accounts.map((a) => MapEntry(a.id.value, a)));
    _groups
      ..clear()
      ..addEntries(view.groups.map((g) => MapEntry(g.id.value, g)));
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
  Future<AppliedWrite> writeApplied(
    AppliedPatch patch, {
    required String appliedBy,
    required DateTime at,
  }) async {
    final lease = _lease;
    if (lease != null && lease.isLiveAt(at) && lease.owner != appliedBy) {
      return AppliedWrite.deferred(lease);
    }
    if (patch.isEmpty) return const AppliedWrite.unchanged();

    // What the store holds for the touched ids *right now* — the only honest
    // basis for the delta, because it already includes whatever another operator
    // applied and wrote since this session linked.
    final storedAccounts = <MaterializedAccount>[
      for (final id in <String>[
        for (final a in patch.accounts) a.id.value,
        ...patch.removedAccountIds,
      ])
        if (_accounts[id] case final stored?) stored,
    ];
    final storedGroups = <MaterializedGroup>[
      for (final id in <String>[
        for (final g in patch.groups) g.id.value,
        ...patch.removedGroupIds,
      ])
        if (_groups[id] case final stored?) stored,
    ];
    final changes = rollupChangesFor(
      storedAccounts: storedAccounts,
      freshAccounts: patch.accounts,
      storedGroups: storedGroups,
      freshGroups: patch.groups,
    );

    for (final a in patch.accounts) {
      _accounts[a.id.value] = a;
    }
    for (final id in patch.removedAccountIds) {
      _accounts.remove(id);
    }
    for (final g in patch.groups) {
      _groups[g.id.value] = g;
    }
    for (final id in patch.removedGroupIds) {
      _groups.remove(id);
    }

    final byKey = <String, Rollup>{for (final r in _rollups) r.key: r};
    for (final change in changes) {
      final next = change.applyTo(byKey[change.key]);
      if (next == null) {
        byKey.remove(change.key);
      } else {
        byKey[change.key] = next;
      }
    }
    _rollups = List.of(byKey.values);

    _syncState = _syncState.bumped(at: at, by: appliedBy);
    return AppliedWrite.written(_syncState.generation);
  }

  @override
  Future<void> putDecision(AccountDecision decision) async {
    _decisions[decisionDocId(decision)] = decision;
  }

  @override
  Future<void> deleteDecision(AccountDecision decision) async {
    _decisions.remove(decisionDocId(decision));
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
