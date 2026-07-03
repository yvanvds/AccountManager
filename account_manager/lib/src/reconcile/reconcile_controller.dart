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
  });

  /// The three connector snapshots (owned by the State layer).
  final ApplicationState app;

  /// Runs actions (dry-run capable) and keeps the snapshots consistent.
  final StateApplier applier;

  /// Shared sink for progress and failure messages.
  final LogBuffer log;

  ReconcilePhase _phase = ReconcilePhase.idle;
  LinkedState? _linked;
  bool _noChangesNeeded = false;
  String? _error;
  List<ActionOutcomeEntry>? _dryRunResults;
  List<ActionOutcomeEntry>? _applyResults;

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
    _begin(ReconcilePhase.syncing);
    try {
      final previous = app.wisa.snapshot;
      log.addMessage(core.Origin.wisa, 'Syncing WISA…');
      final fresh = await app.sync(core.Origin.wisa) as wapi.WisaSnapshot;
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
        _finish(ReconcilePhase.ready);
        return;
      }

      // First pass of the session: the linked view needs all three systems.
      if (app.smartschool.snapshot == null) {
        log.addMessage(core.Origin.smartschool, 'Syncing Smartschool…');
        await app.sync(core.Origin.smartschool);
      }
      if (app.azure.snapshot == null) {
        log.addMessage(core.Origin.azure, 'Syncing Azure AD…');
        await app.sync(core.Origin.azure);
      }

      await _relink();
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      _fail(e);
    }
  }

  /// Explicitly re-reads Smartschool and Azure (drift introduced by edits made
  /// through other tools) and re-links. WISA is not re-pulled — that is what
  /// [sync] is for.
  Future<void> checkDrift() async {
    if (busy) return;
    _begin(ReconcilePhase.syncing);
    try {
      log.addMessage(
        core.Origin.smartschool,
        'Checking Smartschool for drift…',
      );
      await app.sync(core.Origin.smartschool);
      log.addMessage(core.Origin.azure, 'Checking Azure AD for drift…');
      await app.sync(core.Origin.azure);

      if (app.wisa.snapshot == null) {
        log.addMessage(core.Origin.wisa, 'Syncing WISA…');
        await app.sync(core.Origin.wisa);
      }

      await _relink();
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      _fail(e);
    }
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
  }

  void _begin(ReconcilePhase phase) {
    _phase = phase;
    _error = null;
    _noChangesNeeded = false;
    _dryRunResults = null;
    _applyResults = null;
    notifyListeners();
  }

  void _finish(ReconcilePhase phase) {
    _phase = phase;
    notifyListeners();
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
