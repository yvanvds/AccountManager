import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:flutter/foundation.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'log_buffer.dart';

/// What the reconcile screen is doing right now.
enum ReconcilePhase {
  /// Nothing has run yet this session.
  idle,

  /// A sync (or drift check) is pulling snapshots.
  syncing,

  /// The linked view is being recomputed.
  linking,

  /// A dry-run or apply pass is walking the pending actions.
  applying,

  /// The last pass finished; [ReconcileController.linked] is current.
  ready,
}

/// One pending action, shaped for display: which family it belongs to, the
/// record it targets, and its pure change description.
class PendingActionView {
  const PendingActionView({
    required this.family,
    required this.target,
    required this.changes,
    this.canApply = true,
  });

  /// `student`, `staff`, or `group` — the dispatcher family.
  final String family;

  /// Human label of the record the action targets.
  final String target;

  /// The action's pure diff ([actions.StudentAction.describeChanges] et al.).
  final actions.ChangeSet changes;

  /// False for the informational group actions (e.g. an orphan Smartschool
  /// class): they tell the operator something but have no automated write, so
  /// the dry-run/apply passes skip them.
  final bool canApply;
}

/// The outcome of one action in a dry-run or apply pass, for the results list.
class ActionOutcomeEntry {
  const ActionOutcomeEntry({
    required this.target,
    required this.changes,
    required this.outcome,
    this.error,
  });

  /// Human label of the record the action targets.
  final String target;

  /// The action's own change description (summary + field diff).
  final actions.ChangeSet changes;

  final actions.ActionOutcome outcome;

  /// The failure cause when [outcome] is [actions.ActionOutcome.failed].
  final Object? error;
}

/// Drives the reconcile loop over the State layer (#99): **sync → linked
/// overview → pending actions → dry-run → apply**, with progress and failures
/// reported through the shared [LogBuffer].
///
/// The smart-sync behaviour is the product-direction piece: [sync] retains the
/// previous WISA snapshot (via [ApplicationState]'s [SystemState]) and diffs
/// the fresh pull against it. When WISA is unchanged and a linked view already
/// exists, it reports "no account changes needed" and stops — no re-link, no
/// action churn. Smartschool / Azure are pulled only when still missing this
/// session; re-reading them is the explicit [checkDrift] action (someone
/// edited via another tool), not the default.
class ReconcileController extends ChangeNotifier {
  ReconcileController({
    required this.app,
    required this.applier,
    required this.log,
    required this.store,
    this.syncedBy = '',
    this.publisher,
    this.subscriber,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    final sub = subscriber;
    if (sub != null) _signalSub = sub.signals.listen(_onSignal);
  }

  /// The three connector snapshots (owned by the State layer).
  final ApplicationState app;

  /// Runs actions (dry-run capable) and keeps the snapshots consistent.
  final StateApplier applier;

  /// Shared sink for progress and failure messages.
  final LogBuffer log;

  /// The materialized-view store (#115): a sync writes the derived per-account
  /// docs + rollups here, and a passive session reads the overview back with no
  /// connector pull and no `link()`.
  final LinkedStore store;

  /// The operator (UPN) whose session writes the materialized view.
  final String syncedBy;

  /// Publishes a [ChangeSignal] when this session takes/releases the sync lease
  /// or writes a new view generation, so other operators are nudged in real time
  /// (#116). Null when no realtime transport is wired — the store's `generation`
  /// marker still lets a client detect staleness on its next read.
  final SignalPublisher? publisher;

  /// Receives other operators' [ChangeSignal]s so this session reacts live: a
  /// `viewChanged` refetches the changed shard, a `syncStarted` / `syncEnded`
  /// re-reads the lease to disable/enable Synchronise. Null when unwired (#116).
  final SignalSubscriber? subscriber;

  final DateTime Function() _now;

  StreamSubscription<ChangeSignal>? _signalSub;

  ReconcilePhase _phase = ReconcilePhase.idle;
  LinkedState? _linked;
  bool _noChangesNeeded = false;
  String? _error;
  List<ActionOutcomeEntry>? _dryRunResults;
  List<ActionOutcomeEntry>? _applyResults;

  SyncState _syncState = SyncState.initial;
  List<Rollup> _rollups = const [];
  Rollup? _selectedClassroom;
  List<MaterializedAccount>? _classroomAccounts;
  bool _loadingClassroom = false;
  bool _showingGroups = false;
  List<MaterializedGroup>? _groupDocs;
  bool _loadingGroups = false;
  SyncLease? _lock;

  /// The per-system last-sync metadata this pass pulled, stamped as each system
  /// is read and folded into the shared store on persist (#108).
  final Map<core.Origin, SystemSyncMeta> _pulled = {};

  ReconcilePhase get phase => _phase;

  /// Whether a pass is running (buttons disable on this).
  bool get busy =>
      _phase == ReconcilePhase.syncing ||
      _phase == ReconcilePhase.linking ||
      _phase == ReconcilePhase.applying;

  /// The current derived view, or `null` before the first successful sync.
  LinkedState? get linked => _linked;

  /// True when the last [sync] found WISA unchanged — the "no account changes
  /// needed" banner.
  bool get noChangesNeeded => _noChangesNeeded;

  /// The last pass's failure, or `null`. Shown inline; details go to [log].
  String? get error => _error;

  /// Results of the last dry-run pass, or `null` when none ran since the last
  /// sync/apply.
  List<ActionOutcomeEntry>? get dryRunResults => _dryRunResults;

  /// Results of the last apply pass, or `null`.
  List<ActionOutcomeEntry>? get applyResults => _applyResults;

  /// All pending actions of the current linked view, student → staff → group.
  List<Object> get pendingActions {
    final l = _linked;
    if (l == null) return const [];
    return [...l.studentActions, ...l.staffActions, ...l.groupActions];
  }

  /// The pending actions shaped for the list UI, in [pendingActions] order.
  List<PendingActionView> get pendingViews {
    final l = _linked;
    if (l == null) return const [];
    return [
      for (final a in l.studentActions)
        PendingActionView(
          family: 'student',
          target: _accountLabel(a.target),
          changes: a.describeChanges(),
        ),
      for (final a in l.staffActions)
        PendingActionView(
          family: 'staff',
          target: _staffLabel(a.target),
          changes: a.describeChanges(),
        ),
      for (final a in l.groupActions)
        PendingActionView(
          family: 'group',
          target: _groupLabel(a.target),
          changes: a.describeChanges(),
          canApply: a.canApply,
        ),
    ];
  }

  /// The stored freshness + generation marker of the materialized view.
  SyncState get syncState => _syncState;

  /// The coarse sync/drift lease held by **another** operator, or `null` when the
  /// lock is free (or held by this session's own in-flight pass). While non-null,
  /// Synchronise and Check-for-drift are disabled and the holder is named (#108).
  SyncLease? get syncLock => _lock;

  /// Whether another operator is currently syncing, blocking this session's
  /// Synchronise / Check-for-drift.
  bool get syncLockedByOther => _lock != null;

  /// The operator (UPN) holding the sync/drift lease, when [syncLockedByOther].
  String? get syncLockOwner => _lock?.owner;

  /// Whether the store holds a materialized overview (rollups) to drill into —
  /// true after any session has synced, even without a pull this session.
  bool get hasOverview => _rollups.isNotEmpty;

  /// The school-level rollups, alphabetical — the top of the drill-down.
  List<Rollup> get schoolRollups {
    final schools = [
      for (final r in _rollups)
        if (r.level == RollupLevel.school) r,
    ]..sort((a, b) => a.label.compareTo(b.label));
    return schools;
  }

  /// The rollup nodes directly under [parentKey] (grade-years of a school, or
  /// classrooms of a grade-year), alphabetical.
  List<Rollup> childrenOf(String parentKey) {
    final children = [
      for (final r in _rollups)
        if (r.parentKey == parentKey) r,
    ]..sort((a, b) => a.label.compareTo(b.label));
    return children;
  }

  /// The classroom whose accounts are currently open in the drill-down, or
  /// `null` when none is selected.
  Rollup? get selectedClassroom => _selectedClassroom;

  /// The per-account docs of [selectedClassroom], lazily loaded from the store;
  /// `null` until a classroom is opened.
  List<MaterializedAccount>? get classroomAccounts => _classroomAccounts;

  /// Whether a classroom drill-down read is in flight.
  bool get loadingClassroom => _loadingClassroom;

  /// The single "Klasgroepen" rollup node (#119), or `null` when no group has a
  /// pending action to drill into.
  Rollup? get groupRollup {
    for (final r in _rollups) {
      if (r.level == RollupLevel.groups) return r;
    }
    return null;
  }

  /// Whether the group ("Klasgroepen") drill-down is currently open.
  bool get showingGroups => _showingGroups;

  /// The per-group docs of the open group drill-down, lazily loaded from the
  /// store; `null` until the "Klasgroepen" node is opened (#119).
  List<MaterializedGroup>? get groupDocs => _groupDocs;

  /// Whether a group drill-down read is in flight.
  bool get loadingGroups => _loadingGroups;

  /// How many pending actions an apply pass would actually write (the
  /// informational group actions are excluded).
  int get applyableCount {
    final l = _linked;
    if (l == null) return 0;
    return l.studentActions.length +
        l.staffActions.length +
        l.groupActions.where((a) => a.canApply).length;
  }

  /// Runs the smart sync: pull WISA, diff against the retained snapshot, and
  /// only when something changed (or nothing is linked yet) pull the still-
  /// missing systems and re-link.
  Future<void> sync() async {
    if (busy) return;
    if (!await _acquireLock()) return;
    _begin(ReconcilePhase.syncing);
    try {
      final previous = app.wisa.snapshot;
      log.addMessage(core.Origin.wisa, 'Syncing WISA…');
      final fresh = await app.sync(core.Origin.wisa) as wapi.WisaSnapshot;
      _recordPull(core.Origin.wisa, fresh);
      log.addMessage(
        core.Origin.wisa,
        'WISA sync done: ${fresh.students.length} students, '
        '${fresh.staff.length} staff, ${fresh.classGroups.length} classes.',
      );

      if (previous != null &&
          _linked != null &&
          wisaSnapshotUnchanged(previous, fresh)) {
        _noChangesNeeded = true;
        log.addMessage(
          core.Origin.wisa,
          'WISA is unchanged since the previous sync — '
          'no account changes needed.',
        );
        await _persistSystemMeta();
        _finish(ReconcilePhase.ready);
        return;
      }

      // First pass of the session: the linked view needs all three systems.
      if (app.smartschool.snapshot == null) {
        await _renewLock();
        log.addMessage(core.Origin.smartschool, 'Syncing Smartschool…');
        _recordPull(
            core.Origin.smartschool, await app.sync(core.Origin.smartschool));
      }
      if (app.azure.snapshot == null) {
        await _renewLock();
        log.addMessage(core.Origin.azure, 'Syncing Azure AD…');
        _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));
      }

      await _relink();
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      _fail(e);
    } finally {
      await _releaseLock();
    }
  }

  /// Explicitly re-reads Smartschool and Azure (drift introduced by edits made
  /// through other tools) and re-links. WISA is not re-pulled — that is what
  /// [sync] is for.
  Future<void> checkDrift() async {
    if (busy) return;
    if (!await _acquireLock()) return;
    _begin(ReconcilePhase.syncing);
    try {
      log.addMessage(
        core.Origin.smartschool,
        'Checking Smartschool for drift…',
      );
      _recordPull(
          core.Origin.smartschool, await app.sync(core.Origin.smartschool));
      await _renewLock();
      log.addMessage(core.Origin.azure, 'Checking Azure AD for drift…');
      _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));

      if (app.wisa.snapshot == null) {
        await _renewLock();
        log.addMessage(core.Origin.wisa, 'Syncing WISA…');
        _recordPull(core.Origin.wisa, await app.sync(core.Origin.wisa));
      }

      await _relink();
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      _fail(e);
    } finally {
      await _releaseLock();
    }
  }

  /// Loads the materialized overview from the store **without pulling or
  /// re-linking** (#115) — the passive-session read path. A session that opened
  /// only to change a password renders the reconcile overview from the shared
  /// rollups another operator's sync wrote.
  Future<void> loadOverview() async {
    if (busy) return;
    try {
      _syncState = await store.readSyncState();
      _rollups = await store.readRollups();
      await _refreshLock();
      if (_phase == ReconcilePhase.idle) _phase = ReconcilePhase.ready;
      notifyListeners();
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not load the overview: $e');
    }
  }

  /// Reacts to another operator's sync bumping the stored generation past this
  /// session's cached copy (#108): refetch the shared overview and re-read any
  /// open classroom so a passive session catches up — no pull, no `link()`. The
  /// realtime transport (#116) drives this from a SignalR change notification;
  /// until then it is exercised directly. A stale-or-equal [generation] is a
  /// no-op, so a duplicate notification does no work.
  Future<void> onStoreChanged(int generation) async {
    if (busy || generation <= _syncState.generation) return;
    await _refetchFromStore();
  }

  /// Catches this session up from the shared store after the realtime client
  /// (re)connects (#124). Unlike [onStoreChanged] there is **no** generation
  /// gate: a reconnecting client cannot know which nudges it missed while
  /// disconnected, so it always re-reads and adopts the store's own generation
  /// as the truth — the SignalR signal is only the nudge, the store is the
  /// source of truth. A no-op while a local pass runs (that pass writes and
  /// broadcasts the fresh view itself), and a store failure is logged rather
  /// than thrown into the background reconnect loop.
  Future<void> resyncFromStore() async {
    if (busy) return;
    try {
      await _refetchFromStore();
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not catch up after reconnect: $e');
    }
  }

  /// Re-reads the shared overview (sync state, rollups, lease) and any open
  /// drill-down from the store — the refetch [onStoreChanged] and
  /// [resyncFromStore] share (no pull, no `link()`).
  Future<void> _refetchFromStore() async {
    _syncState = await store.readSyncState();
    _rollups = await store.readRollups();
    await _refreshLock();
    final open = _selectedClassroom;
    if (open != null) {
      try {
        _classroomAccounts = await store.readClassroom(
          school: open.school,
          classroom: open.classroom,
        );
      } on Object catch (e) {
        log.addError(core.Origin.all, 'Could not refresh ${open.label}: $e');
      }
    }
    if (_showingGroups) {
      try {
        _groupDocs = await store.readGroups();
      } on Object catch (e) {
        log.addError(core.Origin.all, 'Could not refresh the class groups: $e');
      }
    }
    notifyListeners();
  }

  /// Opens a classroom in the drill-down, lazily reading its per-account docs
  /// from the store (no pull, no `link()`).
  Future<void> openClassroom(Rollup classroom) async {
    _selectedClassroom = classroom;
    _classroomAccounts = null;
    _loadingClassroom = true;
    notifyListeners();
    try {
      _classroomAccounts = await store.readClassroom(
        school: classroom.school,
        classroom: classroom.classroom,
      );
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not open ${classroom.label}: $e');
      _classroomAccounts = const [];
    } finally {
      _loadingClassroom = false;
      notifyListeners();
    }
  }

  /// Closes the classroom drill-down, back to the overview.
  void closeClassroom() {
    _selectedClassroom = null;
    _classroomAccounts = null;
    notifyListeners();
  }

  /// Opens the "Klasgroepen" drill-down (#119), lazily reading the per-group
  /// docs from the store (no pull, no `link()`) — the group-family counterpart
  /// of [openClassroom].
  Future<void> openGroups() async {
    _showingGroups = true;
    _selectedClassroom = null;
    _classroomAccounts = null;
    _groupDocs = null;
    _loadingGroups = true;
    notifyListeners();
    try {
      _groupDocs = await store.readGroups();
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not open the class groups: $e');
      _groupDocs = const [];
    } finally {
      _loadingGroups = false;
      notifyListeners();
    }
  }

  /// Closes the group drill-down, back to the overview.
  void closeGroups() {
    _showingGroups = false;
    _groupDocs = null;
    notifyListeners();
  }

  /// Dry-runs every pending action (PAIN-3): the full apply path, zero writes.
  /// Results land in [dryRunResults].
  Future<void> dryRun() => _applyAll(dry: true);

  /// Applies every pending action for real, refreshing the linked view from
  /// the State layer's incremental patches as it goes. Results land in
  /// [applyResults].
  Future<void> applyAll() => _applyAll(dry: false);

  Future<void> _applyAll({required bool dry}) async {
    final l = _linked;
    if (busy || l == null) return;
    _begin(ReconcilePhase.applying);

    final options =
        dry ? actions.ApplyOptions.dry : const actions.ApplyOptions();
    final results = <ActionOutcomeEntry>[];
    final label = dry ? 'Dry-run' : 'Apply';
    log.addMessage(
      core.Origin.all,
      '$label started for $applyableCount of ${pendingActions.length} '
      'pending action(s).',
    );

    try {
      // Walk the lists captured before the pass: each action is bound to its
      // target, and on a real write the applier patches the snapshot and
      // returns a fresh linked view we adopt as we go.
      for (final action in l.studentActions) {
        results.add(await _applyOne(
          () => applier.applyStudent(action, options: options),
          _accountLabel(action.target),
          action.describeChanges(),
        ));
      }
      for (final action in l.staffActions) {
        results.add(await _applyOne(
          () => applier.applyStaff(action, options: options),
          _staffLabel(action.target),
          action.describeChanges(),
        ));
      }
      for (final action in l.groupActions) {
        // Informational actions (canApply false) carry no automated write —
        // their apply() throws by contract, so the pass leaves them out.
        if (!action.canApply) continue;
        results.add(await _applyOne(
          () => applier.applyGroup(action, options: options),
          _groupLabel(action.target),
          action.describeChanges(),
        ));
      }

      final failed =
          results.where((r) => r.outcome == actions.ActionOutcome.failed);
      log.addMessage(
        core.Origin.all,
        '$label finished: ${results.length - failed.length} ok, '
        '${failed.length} failed.',
      );
      if (dry) {
        _dryRunResults = results;
      } else {
        _applyResults = results;
        _dryRunResults = null;
      }
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      // _applyOne swallows per-action failures; reaching here means the pass
      // itself broke (e.g. the post-write re-link). Keep partial results.
      if (dry) {
        _dryRunResults = results;
      } else {
        _applyResults = results;
      }
      _fail(e);
    }
  }

  Future<ActionOutcomeEntry> _applyOne(
    Future<ApplyResult> Function() run,
    String target,
    actions.ChangeSet changes,
  ) async {
    try {
      final applied = await run();
      if (applied.refreshed) _linked = applied.linked;
      final result = applied.result;
      if (result.outcome == actions.ActionOutcome.failed) {
        log.addError(
          changes.system,
          '$target — ${changes.summary}: ${result.error}',
        );
      } else {
        log.addMessage(core.Origin.all, '$target — ${changes.summary}');
      }
      return ActionOutcomeEntry(
        target: target,
        changes: changes,
        outcome: result.outcome,
        error: result.error,
      );
    } on Object catch (e) {
      // An action that throws (instead of returning failed) must not abort
      // the rest of the pass.
      log.addError(changes.system, '$target — ${changes.summary}: $e');
      return ActionOutcomeEntry(
        target: target,
        changes: changes,
        outcome: actions.ActionOutcome.failed,
        error: e,
      );
    }
  }

  Future<void> _relink() async {
    _phase = ReconcilePhase.linking;
    notifyListeners();
    _linked = await applier.link();
    final s = _linked!.snapshot;
    log.addMessage(
      core.Origin.all,
      'Linked: ${s.accounts.length} students, ${s.staff.length} staff, '
      '${s.groups.length} groups; ${pendingActions.length} pending '
      'action(s), ${s.warnings.length} warning(s).',
    );
    await _persist(_linked!);
  }

  /// Materializes the fresh linked view and writes it to the shared store
  /// (#115): one document per account, the rollup aggregates, and a bumped
  /// generation. Still-applicable operator decisions are re-attached and only
  /// the ones whose situation is gone are dropped, so a re-sync never clobbers
  /// in-progress work. A store failure is logged but does not fail the sync —
  /// the in-memory view is still usable this session.
  Future<void> _persist(LinkedState linked) async {
    try {
      final previous = await store.readSyncState();
      final view = materialize(
        linked,
        generation: previous.generation + 1,
        schoolLabels: _schoolLabels(),
      );
      final merge = mergeDecisions(
        accounts: view.accounts,
        groups: view.groups,
        existing: await store.readDecisions(),
      );
      final merged = MaterializedView(
        generation: view.generation,
        accounts: merge.accounts,
        groups: merge.groups,
        rollups: view.rollups,
      );
      final at = _now();
      await store.writeMaterialized(
        merged,
        syncedBy: syncedBy,
        at: at,
        droppedDecisions: merge.dropped,
        systemSyncs: _pulled,
      );
      _rollups = merged.rollups;
      _syncState = SyncState(
        generation: view.generation,
        updatedAt: at,
        updatedBy: syncedBy,
        // The store merges this pass's pulls over what it had; mirror that here.
        systems: {...previous.systems, ..._pulled},
      );
      // Nudge every passive session to refetch: the whole view was rewritten,
      // so the signal names no narrower shard (#116).
      await _publish(ChangeSignal.viewChanged(generation: view.generation));
      // A re-sync invalidates any open drill-down; the next open re-reads.
      _selectedClassroom = null;
      _classroomAccounts = null;
      _showingGroups = false;
      _groupDocs = null;
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not persist the linked view: $e');
    }
  }

  /// The WISA school-id → name map for the materializer's school labels, from
  /// the current WISA snapshot's schools list (empty before the first pull).
  Map<int, String> _schoolLabels() => {
        for (final s in app.wisa.snapshot?.schools ?? const <wapi.WisaSchool>[])
          s.id: s.name,
      };

  void _begin(ReconcilePhase phase) {
    _phase = phase;
    _error = null;
    _noChangesNeeded = false;
    _dryRunResults = null;
    _applyResults = null;
    _pulled.clear();
    notifyListeners();
  }

  /// Stamps [snapshot]'s fetch time against [system] for this pass, folded into
  /// the shared store's per-system freshness on persist (#108).
  void _recordPull(core.Origin system, core.Snapshot snapshot) {
    _pulled[system] =
        SystemSyncMeta(syncedBy: syncedBy, at: snapshot.fetchedAt);
  }

  /// Stamps the smart-sync "WISA unchanged" path: nothing was re-linked, so the
  /// view is untouched, but WISA was still pulled — record its freshness with a
  /// light metadata write that does not bump the generation (#108).
  Future<void> _persistSystemMeta() async {
    if (_pulled.isEmpty) return;
    try {
      await store.recordSystemSync(_pulled);
      _syncState = SyncState(
        generation: _syncState.generation,
        updatedAt: _syncState.updatedAt,
        updatedBy: _syncState.updatedBy,
        systems: {..._syncState.systems, ..._pulled},
      );
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not record sync metadata: $e');
    }
  }

  /// Takes the coarse sync/drift lease before a heavy pass (#108). Returns true
  /// when this session may proceed — it acquired the lease, or the lease store
  /// is unreachable (a coordination hiccup must not turn Synchronise into a dead
  /// button; the pass's own writes would surface a real outage). Returns false,
  /// naming the holder, when another operator is already syncing.
  Future<bool> _acquireLock() async {
    try {
      final outcome = await store.acquireLease(owner: syncedBy, now: _now());
      if (outcome.acquired) {
        _lock = null;
        // Nudge other operators to disable their Synchronise/Check-for-drift.
        await _publish(ChangeSignal.syncStarted(owner: syncedBy));
        return true;
      }
      _lock = outcome.lease;
      log.addMessage(
        core.Origin.all,
        '${outcome.lease.owner} is bezig met synchroniseren — probeer straks '
        'opnieuw.',
      );
      notifyListeners();
      return false;
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not take the sync lock: $e');
      return true;
    }
  }

  /// Heart-beats the held lease between the per-system pulls, so its expiry
  /// tracks the work done rather than a wall clock (#108). Best-effort: a failed
  /// heartbeat is logged but never aborts an in-flight pass. Losing the lease
  /// (expired and taken over) is surfaced but the current write still finishes.
  Future<void> _renewLock() async {
    try {
      final outcome = await store.renewLease(owner: syncedBy, now: _now());
      if (!outcome.acquired) {
        log.addError(
          core.Origin.all,
          'Sync-vergrendeling verlopen; ${outcome.lease.owner} heeft ze '
          'overgenomen.',
        );
      }
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not renew the sync lock: $e');
    }
  }

  /// Releases the held lease at the end of a pass, freeing the next operator.
  /// Best-effort; an abandoned lease also expires on its own (#108).
  Future<void> _releaseLock() async {
    try {
      await store.releaseLease(owner: syncedBy);
      // Only after the lease is actually gone — nudge others to re-enable.
      await _publish(ChangeSignal.syncEnded(owner: syncedBy));
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not release the sync lock: $e');
    }
  }

  /// Reads the current lease and records whether **another** operator holds it,
  /// so a passive session disables Synchronise/Check-for-drift and names the
  /// holder (#108). Our own lease never blocks us.
  Future<void> _refreshLock() async {
    try {
      final lease = await store.readLease(_now());
      _lock = (lease != null && lease.owner != syncedBy) ? lease : null;
    } on Object catch (_) {
      // Leave the last-known lock state; a transient read failure must not
      // spuriously enable or disable the buttons.
    }
  }

  /// Reacts to another operator's realtime signal (#116). A `viewChanged` drives
  /// the same stale-generation refetch as a direct [onStoreChanged]; a lease
  /// signal re-reads the *authoritative* lease from the store (the signal is only
  /// the nudge, the lease document is the truth). This session's own echoed
  /// signals are harmless: [onStoreChanged] no-ops on its own generation, and a
  /// lease signal is ignored while this session is the one syncing.
  Future<void> _onSignal(ChangeSignal signal) async {
    switch (signal.kind) {
      case ChangeSignalKind.viewChanged:
        final generation = signal.generation;
        if (generation != null) await onStoreChanged(generation);
      case ChangeSignalKind.syncStarted:
      case ChangeSignalKind.syncEnded:
        // While this session runs its own pass it owns the lease; ignore the
        // echo so it never disables its own buttons.
        if (busy) return;
        await _refreshLock();
        notifyListeners();
    }
  }

  /// Best-effort publish of [signal] to the realtime transport (#116). A failed
  /// push is logged but never fails the pass that triggered it — the stored
  /// generation marker is the fallback source of truth. A no-op when no
  /// publisher is wired.
  Future<void> _publish(ChangeSignal signal) async {
    final p = publisher;
    if (p == null) return;
    try {
      await p.publish(signal);
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not publish a change signal: $e');
    }
  }

  void _finish(ReconcilePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _signalSub?.cancel();
    subscriber?.close();
    super.dispose();
  }

  void _fail(Object e) {
    _error = e.toString();
    log.addError(core.Origin.all, e.toString());
    _finish(ReconcilePhase.ready);
  }

  // The core linked records only carry the linking keys; the human names live
  // on the concrete connector records, which is what a LinkedState built from
  // real snapshots always holds — hence the type checks with key fallbacks.

  static String _accountLabel(core.LinkedAccount a) {
    final wisa = a.wisa;
    if (wisa is wapi.WisaStudent) {
      return _nonEmpty('${wisa.firstName} ${wisa.name}') ??
          wisa.wisaId.toString();
    }
    return _personLabel(a.smartschool, a.azure) ??
        wisa?.wisaId.toString() ??
        '(account)';
  }

  static String _staffLabel(core.LinkedStaff s) {
    final wisa = s.wisa;
    if (wisa is wapi.WisaStaff) {
      return _nonEmpty('${wisa.firstName} ${wisa.lastName}') ??
          wisa.code.toString();
    }
    return _personLabel(s.smartschool, s.azure) ??
        wisa?.code.toString() ??
        '(staff member)';
  }

  static String _groupLabel(core.LinkedGroup g) =>
      _nonEmpty(g.wisa?.name ?? '') ??
      _nonEmpty(g.smartschool?.name ?? '') ??
      g.azure?.displayName ??
      '(group)';

  static String? _personLabel(
    core.SmartschoolAccount? smartschool,
    core.AzureUser? azure,
  ) {
    if (smartschool is ss.SmartschoolAccount) {
      return _nonEmpty('${smartschool.givenName} ${smartschool.surname}') ??
          smartschool.uid;
    }
    if (smartschool != null) return smartschool.uid;
    return azure?.upn;
  }

  static String? _nonEmpty(String s) {
    final trimmed = s.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
