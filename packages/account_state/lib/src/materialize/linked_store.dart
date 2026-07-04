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
  /// [droppedDecisions] a merge found no longer applicable. Only the sync/drift
  /// process calls this.
  Future<void> writeMaterialized(
    MaterializedView view, {
    required String syncedBy,
    required DateTime at,
    List<AccountDecision> droppedDecisions = const [],
  });

  /// Creates or replaces one operator decision. The write seam #109/#110 use;
  /// this issue ships no UI that calls it, but tests and the merge round-trip
  /// through it.
  Future<void> putDecision(AccountDecision decision);
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
    );
  }

  @override
  Future<void> putDecision(AccountDecision decision) async {
    _decisions[decisionDocId(decision)] = decision;
  }
}
