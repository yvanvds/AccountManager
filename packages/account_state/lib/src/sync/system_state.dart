import 'package:account_core/account_core.dart' as core;

/// Performs one sync for a single system, returning a fresh snapshot.
///
/// [previous] is the snapshot currently held by the owning [SystemState]
/// (`null` before the first successful sync). It is the seam that threads
/// incremental state across syncs: the Azure syncer reads `previous.deltaToken`
/// and `previous.users` to apply a `/users/delta` on top of the last result
/// (PAIN-2). Syncers whose systems do a full read each time (WISA, Smartschool)
/// simply ignore it.
///
/// [fullRead] says **this pass is a deliberate re-read**: build the snapshot
/// from what the system holds right now rather than resuming whatever
/// incremental state [previous] carries (#316). Only the *resume point* is
/// dropped — [previous] is still handed in, so a syncer that remembers things
/// from the snapshot in hand (Azure's retained staff ids, #269) keeps
/// remembering them. Syncers that read the whole system every pass ignore it,
/// exactly as they ignore [previous]; it costs them nothing because they have no
/// resume point to drop.
///
/// A syncer that throws leaves the [SystemState] untouched — the previous
/// snapshot and `lastSync` survive a failed sync (domain-model §6.1).
typedef Syncer<S extends core.Snapshot> = Future<S> Function(
  S? previous, {
  bool fullRead,
});

/// Tests whether a connector is configured and reachable. Returns `true` on a
/// successful probe. Used by [SystemState.test]; kept separate from [Syncer]
/// because connection-tested state is transient and never gates a sync.
typedef ConnectionTester = Future<bool> Function();

/// Owns one system's synced state: the last-good [snapshot], when it was
/// fetched ([lastSync]), and the transient [connection] test result.
///
/// Mirrors a legacy per-system `*State` (`WisaState`/`SmartschoolState`/
/// `AzureState`) but as pure Dart with no config, disk, or observer coupling.
/// The connector and its per-sync parameters live behind the injected
/// [Syncer], so this class is connector-agnostic and unit-testable against
/// fakes.
///
/// ## What is and isn't persisted
///
/// Nothing here is persisted by this class. The [snapshot] is derived data (a
/// connector may cache it for fast first paint — that's a connector concern),
/// and [connection] is **transient**: it starts [core.ConnectionState.unknown]
/// on every fresh [SystemState] and is re-established per session by calling
/// [test]. It is never written to disk (domain-model §6.1; the legacy
/// `connectionTested` flag was persisted — we drop that).
class SystemState<S extends core.Snapshot> {
  SystemState({
    required this.system,
    required Syncer<S> syncer,
    S? initial,
  })  : _syncer = syncer,
        _snapshot = initial,
        _lastSync = initial?.fetchedAt;

  /// Which system this state belongs to.
  final core.Origin system;

  final Syncer<S> _syncer;

  S? _snapshot;
  DateTime? _lastSync;
  core.ConnectionState _connection = core.ConnectionState.unknown;
  bool _syncing = false;

  /// The last successfully synced snapshot, or `null` before the first sync.
  S? get snapshot => _snapshot;

  /// When [snapshot] was fetched (its `fetchedAt`), or `null` before the first
  /// sync. Drives the dashboard freshness badge.
  DateTime? get lastSync => _lastSync;

  /// The transient connection-test result. Not persisted; resets to
  /// [core.ConnectionState.unknown] each session until [test] runs.
  core.ConnectionState get connection => _connection;

  /// Whether a [sync] is currently in flight.
  bool get isSyncing => _syncing;

  /// Runs one sync and, **only on success**, replaces [snapshot] with the
  /// fresh result and stamps [lastSync] from its `fetchedAt`.
  ///
  /// If the syncer throws, the previous [snapshot] and [lastSync] are left
  /// intact and the error propagates to the caller (domain-model §6.1).
  /// Concurrent syncs are rejected with a [StateError] rather than racing on
  /// the shared snapshot slot.
  ///
  /// [fullRead] asks the syncer for a deliberate re-read instead of an
  /// incremental resume (#316) — see [Syncer]. The snapshot in hand is handed to
  /// the syncer either way; the flag only says whether the pass may build on the
  /// resume point that snapshot carries.
  Future<S> sync({bool fullRead = false}) async {
    if (_syncing) {
      throw StateError('A $system sync is already in progress');
    }
    _syncing = true;
    try {
      final fresh = await _syncer(_snapshot, fullRead: fullRead);
      _snapshot = fresh;
      _lastSync = fresh.fetchedAt;
      return fresh;
    } finally {
      _syncing = false;
    }
  }

  /// Installs [snapshot] as the current [snapshot] **without running a sync** —
  /// the incremental-refresh primitive (#72).
  ///
  /// The State layer uses this to splice an action's mutated connector record
  /// into the in-memory snapshot after a successful `apply`, so a re-`link()`
  /// sees the change with no network re-sync (the incremental-refresh
  /// constraint from #40). [lastSync] is deliberately left untouched: a local
  /// patch is not a fresh fetch, so the dashboard freshness badge must not
  /// reset. Callers build [snapshot] by copying the current one with the single
  /// record replaced/removed and reusing its `fetchedAt`.
  ///
  /// Rejected while a [sync] is in flight — patching the shared snapshot slot
  /// under an in-flight sync would race the fresh result in.
  void patch(S snapshot) {
    if (_syncing) {
      throw StateError('Cannot patch $system while a sync is in progress');
    }
    _snapshot = snapshot;
  }

  /// Probes the connector with [tester] and records the outcome in
  /// [connection] ([core.ConnectionState.ok] / [core.ConnectionState.failed]).
  /// A tester that throws counts as a failed probe. The result is transient
  /// and never persisted. Returns the probe result.
  Future<bool> test(ConnectionTester tester) async {
    _connection = core.ConnectionState.inProgress;
    try {
      final ok = await tester();
      _connection = ok ? core.ConnectionState.ok : core.ConnectionState.failed;
      return ok;
    } on Object {
      _connection = core.ConnectionState.failed;
      return false;
    }
  }
}
