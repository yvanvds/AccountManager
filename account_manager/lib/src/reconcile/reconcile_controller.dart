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

/// One selectable resolution inside a [PendingAccountEntry] (#110).
///
/// Wraps the live action to run when this alternative is chosen, plus the pure
/// description the list renders. [group] is the [actions.StudentAction]-style
/// alternative-group key — non-null only when this option is one of several
/// mutually-exclusive alternatives.
class PendingActionOption {
  const PendingActionOption({
    required this.action,
    required this.kind,
    required this.group,
    required this.isDefault,
    required this.family,
    required this.target,
    required this.changes,
    required this.canApply,
    this.unlockedSystems = const {},
  });

  /// The live `StudentAction` / `StaffAction` / `GroupAction` this option runs.
  final Object action;

  /// The action's class name — the stable discriminator a decision keys on.
  final String kind;

  /// The mutually-exclusive-alternative key, or `null` when the option stands
  /// alone (see [actions.StudentAction.alternativeGroup]).
  final String? group;

  /// Whether this is the pre-selected default of its alternative group.
  final bool isDefault;

  /// `student`, `staff`, or `group`.
  final String family;

  /// Human label of the target this option acts on (for the result rows).
  final String target;

  /// The action's pure diff (summary + field changes).
  final actions.ChangeSet changes;

  /// Whether an apply pass would actually write this option.
  final bool canApply;

  /// The systems only a **chained follow-up** of this option would write to
  /// (`StudentAction.unlockedSystems` et al., #234) — never the option's own
  /// [changes] system.
  ///
  /// Read off the action rather than derived from the pending list, because the
  /// follow-up is not in it: the dispatcher is a pure function of the record as
  /// it stands, so `AddStudentToSmartschool` only appears once the Azure create
  /// has run and relinked. The confirmation dialog has to name that second
  /// system *before* the write.
  final Set<core.Origin> unlockedSystems;
}

/// What a confirmed apply of a selection would write, for the confirmation
/// dialog (#234).
///
/// Built by [ReconcileController.applyScope] from the **selected**, applyable
/// option of each choice — exactly the actions `applyAll` / `applySituation` /
/// `applyEntry` would run — so the dialog names the systems the pass genuinely
/// reaches instead of the hard-coded "Smartschool and Azure AD" it used to
/// claim for every action.
class ApplyScope {
  const ApplyScope({required this.systems, required this.chained});

  /// One entry per action the pass would run: the system that action writes to.
  /// A list, not a set — its length is the change count the dialog quotes, and
  /// two Azure patches are two changes to one system.
  final List<core.Origin> systems;

  /// Systems only a chained follow-up would reach, with everything already in
  /// [systems] removed. Non-empty only for the provisioning chains whose second
  /// write lands in another system (a new student's / staff member's Office 365
  /// create pulls the Smartschool create in behind it).
  final Set<core.Origin> chained;

  /// Nothing selected — a dialog built from this claims no write at all.
  static const ApplyScope empty =
      ApplyScope(systems: <core.Origin>[], chained: <core.Origin>{});
}

/// The action a running dry-run/apply pass is on **right now** (#243) — what the
/// modal progress dialog names while the operator waits.
///
/// Published by [ReconcileController._run] straight off the list it is walking:
/// the selected, applyable option of each choice, which is the very same
/// resolution [ReconcileController.applyScope] summarised for the confirmation
/// dialog a moment earlier. The progress dialog therefore counts exactly the
/// actions the operator just agreed to, rather than resolving the work a second
/// way that could disagree with what they were shown.
class ApplyStep {
  const ApplyStep({
    required this.dry,
    required this.index,
    required this.total,
    required this.target,
    required this.summary,
    this.followUps = 0,
  });

  /// Whether this pass is a dry-run (nothing is written) rather than an apply.
  final bool dry;

  /// 1-based position of the action in flight within the planned list.
  final int index;

  /// How many actions the pass set out to run.
  ///
  /// The *planned* actions only, and deliberately so. A chained follow-up
  /// (#230/#240/#245) is not in the pending list at all: dispatch is a pure
  /// function of the record as it stands, so the second link only exists once
  /// the first write has landed and relinked, and its own `evaluate` decides
  /// then whether it runs. It can never be counted up front — so it is reported
  /// separately in [followUps] instead of quietly inflating a total the operator
  /// was already shown.
  final int total;

  /// Human label of the record this action targets ("Jan Peeters").
  final String target;

  /// The action's one-line change summary ("Maak een nieuw Office 365 account").
  final String summary;

  /// Extra writes that chained off already-finished steps of this pass — the
  /// follow-ups [total] structurally cannot include.
  final int followUps;
}

/// One decision point within a [PendingAccountEntry]: either a lone action or a
/// set of mutually-exclusive alternatives, exactly one of which is [selected].
///
/// A departed student's "unregister *vs* delete" pair is a single choice with
/// two [alternatives]; an ordinary modify action is a choice of one. Rendering
/// the alternatives as one choice — rather than independent rows — is the core
/// of #110: the operator picks one resolution and never runs both.
class PendingChoice {
  PendingChoice({required this.alternatives, required this.selected})
      : assert(alternatives.isNotEmpty);

  /// The mutually-exclusive options (one or more).
  final List<PendingActionOption> alternatives;

  /// The currently-chosen option (defaults to the group's default).
  final PendingActionOption selected;

  /// True when this is a real choice the operator must resolve (more than one
  /// alternative), false for a lone action.
  bool get isChoice => alternatives.length > 1;

  /// The situation this choice resolves — the alternative-group key for a real
  /// choice, else the single action kind. Drives the "same situation" grouping
  /// so two departed students share one bulk-apply subset.
  String get situationId => alternatives.first.group ?? alternatives.first.kind;
}

/// The pending actions for **one** linked account, staff member, or class group
/// — the "one entry per account" the list renders (#110).
class PendingAccountEntry {
  const PendingAccountEntry({
    required this.family,
    required this.targetId,
    required this.target,
    required this.choices,
  });

  /// `student`, `staff`, or `group`.
  final String family;

  /// The stable key of the target this entry groups (the account/staff/group id).
  final String targetId;

  /// Human label of the target.
  final String target;

  /// The decision points for this target, in dispatch order.
  final List<PendingChoice> choices;

  /// A stable signature of this entry's *situation* — its family plus the sorted
  /// set of its choices' [PendingChoice.situationId]. Two entries with the same
  /// key are "in the same situation", so a bulk apply can act on the subset.
  String get situationKey {
    final ids = choices.map((c) => c.situationId).toList()..sort();
    return '$family|${ids.join(',')}';
  }

  /// A short human description of the situation (the choices' summaries), used as
  /// the header of a same-situation subset.
  String get situationLabel => choices.map((c) {
        if (!c.isChoice) return c.selected.changes.summary;
        return c.alternatives.map((a) => a.changes.summary).join(' / ');
      }).join('; ');

  /// Whether an apply pass would write anything for this entry — at least one
  /// selected option is applyable.
  bool get canApply => choices.any((c) => c.selected.canApply);
}

/// One colliding Smartschool account inside a [DuplicateMailWarning] (#109),
/// flattened for display: the fields the drill-down lists so the operator can
/// tell the accounts apart before accepting the collision.
class DuplicateAccountRow {
  const DuplicateAccountRow({
    required this.uid,
    required this.name,
    required this.accountType,
    required this.role,
  });

  /// The Smartschool username / login.
  final String uid;

  /// Display name (`givenName surname`), or the uid when the concrete record
  /// carries no name.
  final String name;

  /// The account type (`student` or a co-account slot).
  final String accountType;

  /// The account's role, or `onbekend` when unknown.
  final String role;
}

/// A duplicate-mail warning (INV-23) shaped for the reconcile screen (#109): the
/// shared [mail], the colliding [accounts] the drill-down lists, and whether the
/// operator has [accepted] this exact collision (persisted as a decision). An
/// accepted collision is demoted, not hidden, so it can be reviewed and revoked.
class DuplicateMailWarning {
  const DuplicateMailWarning({
    required this.mail,
    required this.accounts,
    required this.accepted,
  });

  /// The address the [accounts] share (as the linker normalized it).
  final String mail;

  /// Every Smartschool account claiming [mail]; at least two.
  final List<DuplicateAccountRow> accounts;

  /// True when the current colliding set has been accepted as deliberate. A
  /// changed set (a third account appears) resets this to false so the warning
  /// re-surfaces.
  final bool accepted;

  /// The colliding uids, sorted — the stable key an acceptance covers.
  List<String> get uids => sortedDuplicateUids(accounts.map((a) => a.uid));
}

/// A per-category summary for the Reconcile overview (#163): how many accounts
/// (or class groups) the category holds, and how many of them carry an applyable
/// pending action. Derived from the stored [Rollup]s, so it is readable in a
/// passive session that never linked — the whole point of the materialized view.
class CategorySummary {
  const CategorySummary({required this.total, required this.pending});

  /// The total accounts (students / staff) or class groups in this category.
  final int total;

  /// How many of them carry at least one applyable pending action (the
  /// informational group notices, which never write, are excluded).
  final int pending;

  /// The zero state before any sync has materialized a rollup.
  static const CategorySummary empty = CategorySummary(total: 0, pending: 0);
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
    this.schoolProfiles = const <WisaSchoolProfile>[],
    this.settingsStore,
    this.liveSettings,
    this.publisher,
    this.subscriber,
    this.persistTimeout = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    final sub = subscriber;
    if (sub != null) _signalSub = sub.signals.listen(_onSignal);
    // The snapshot this session starts with — seeded from the cold store, or
    // pulled later — belongs to the settings as they stand right now (#238).
    _wisaPullFingerprint = _wisaFingerprint();
    // A save the operator makes in Instellingen must repaint this screen: it is
    // kept alive across tab switches, so nothing else would tell it the WISA
    // pull inputs moved.
    _settingsSub = liveSettings?.changes.listen((_) => notifyListeners());
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

  /// The operator-curated WISA schools from the settings document
  /// (AppSettings.wisaSchools), each carrying the school's short code and long
  /// name. They are what [_schoolLabels] names a school with, so the Actions
  /// drill-down identifies schools exactly as the Settings grid does even in a
  /// session that has not pulled WISA yet (#204). Empty until an operator has
  /// filled the WISA-scholen grid in, which is when the label falls back to the
  /// snapshot and finally to `School <id>`.
  final List<WisaSchoolProfile> schoolProfiles;

  /// Where [schoolProfiles] is persisted, so a WISA pull can repair the stored
  /// profiles from the school list it just loaded (#207).
  ///
  /// Documents written before `code`/`name` existed on a profile (#171/#194)
  /// carry a school id and an `ours` flag and nothing else, and the Settings
  /// grid — which consults no snapshot — then renders them as `School 25`
  /// forever, because the only writer of the two halves used to be the
  /// **Scholen ophalen** button followed by **Opslaan**. Every sync already
  /// pulls the full school list, so it can fill them in silently instead;
  /// [_backfillSchoolProfiles] does, touching only those two fields. Null when
  /// no store is wired (the in-memory harnesses), which simply skips the
  /// repair.
  final SettingsStore? settingsStore;

  /// The live settings document (#238) — the same holder the WISA syncer reads
  /// at pull time and the Settings view publishes into on every load and save.
  ///
  /// The controller uses it for one thing: to tell whether the WISA pull inputs
  /// (werkdatum, virtuele werkdatum, virtual-school marks) have moved since the
  /// snapshot this session holds was pulled. A drift pass never re-reads WISA —
  /// that is what Synchroniseer is for — so once they have, a drift check would
  /// silently relink against a roster built with the old settings and publish
  /// the result to every other operator. [driftBlockedReason] refuses instead.
  ///
  /// Null in the harnesses that do not model settings at all; the gate is then
  /// never armed and drift behaves exactly as before.
  final LiveSettings? liveSettings;

  /// Publishes a [ChangeSignal] when this session takes/releases the sync lease
  /// or writes a new view generation, so other operators are nudged in real time
  /// (#116). Null when no realtime transport is wired — the store's `generation`
  /// marker still lets a client detect staleness on its next read.
  final SignalPublisher? publisher;

  /// Receives other operators' [ChangeSignal]s so this session reacts live: a
  /// `viewChanged` refetches the changed shard, a `syncStarted` / `syncEnded`
  /// re-reads the lease to disable/enable Synchronise. Null when unwired (#116).
  final SignalSubscriber? subscriber;

  /// How long [_persist] waits for the shared-store write before giving up and
  /// returning the pass to `ready` (#168). A full materialized view is ~9.6k
  /// account docs; if the write stalls (throttling loop, a wedged connection),
  /// the operator must not be stuck with Synchronise disabled forever — the
  /// in-memory linked view is still usable this session. The wait is generous
  /// so a merely-slow (but progressing) write is never cut off in practice;
  /// tests inject a tiny value.
  final Duration persistTimeout;

  final DateTime Function() _now;

  StreamSubscription<ChangeSignal>? _signalSub;

  StreamSubscription<AppSettings>? _settingsSub;

  /// The [wisaPullFingerprint] of the settings the WISA snapshot this session
  /// holds was pulled with (#238). Re-stamped on every WISA pull; compared
  /// against the live document to arm [driftBlockedReason].
  late String _wisaPullFingerprint;

  ReconcilePhase _phase = ReconcilePhase.idle;
  double _progress = 0.0;
  ApplyStep? _applyStep;
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

  /// The operator's chosen alternative per situation (#110), keyed by
  /// `<targetId>|<alternativeGroup>` → the chosen action kind. A missing entry
  /// means the situation still shows its default alternative.
  final Map<String, String> _choices = {};

  /// Memoized [pendingEntries] (#111). Building the entries runs
  /// `describeChanges()` for every pending action, and the screen reads
  /// `pendingEntries` (directly and via `pendingSituations` / `applyableCount`)
  /// several times per frame — recomputing it each time is what janks a large
  /// pending set. The cache is keyed on the identity of the linked view (a fresh
  /// `link()` / apply-refresh replaces it) and a version bumped on every
  /// [chooseAlternative], so a stale entry can never be served.
  List<PendingAccountEntry>? _pendingEntriesCache;
  LinkedState? _pendingCacheKey;
  int _choicesVersion = 0;
  int _pendingCacheChoicesVersion = -1;

  /// The persisted operator decisions loaded from the shared store (#109/#110),
  /// used to tell which duplicate-mail collisions have been accepted. Refreshed
  /// on every overview read and after each accept/revoke.
  List<AccountDecision> _decisions = const [];

  ReconcilePhase get phase => _phase;

  /// Whether a pass is running (buttons disable on this).
  bool get busy =>
      _phase == ReconcilePhase.syncing ||
      _phase == ReconcilePhase.linking ||
      _phase == ReconcilePhase.applying;

  /// How far the running pass has advanced, `0.0`–`1.0` — the value the busy
  /// bar renders (#176). It steps forward at every stage of a sync/drift pass
  /// (each system pulled, linking, persisting) and once per action during an
  /// apply/dry-run, so the bar visibly *advances* rather than sitting as a
  /// motionless sweep that reads as a hung app. Reset to `0.0` when a pass
  /// begins; meaningless (and unread) while not [busy].
  double get progress => _progress;

  /// Steps the pass indicator to [value] (clamped) and repaints. A pass only
  /// ever moves forward, so a lower [value] than the current one is ignored —
  /// the shared [_relink] can't drag a further-along drift pass backwards.
  void _setProgress(double value) {
    final next = value.clamp(0.0, 1.0);
    if (next <= _progress) return;
    _progress = next;
    notifyListeners();
  }

  /// The action the running dry-run/apply pass is on, or `null` when no pass is
  /// walking actions (#243). Drives the modal progress dialog's text, so a pass
  /// that writes hundreds of accounts says which account and which action it is
  /// on instead of leaving the operator with greyed-out buttons for minutes.
  ApplyStep? get applyStep => _applyStep;

  /// Publishes the pass's current step and repaints.
  ///
  /// Its own notification rather than something riding along with
  /// [_setProgress]: that one ignores any value not greater than the current
  /// one, so a step published through it would be dropped exactly when the bar
  /// does not move — the first action of every pass, and every action of a pass
  /// of one.
  void _setApplyStep(ApplyStep step) {
    _applyStep = step;
    notifyListeners();
  }

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

  /// The pending actions grouped **one entry per target** (#110): each linked
  /// account/staff/group becomes a single [PendingAccountEntry], and its
  /// mutually-exclusive actions (unregister *vs* delete) collapse into one
  /// [PendingChoice] rather than independent rows. Rebuilt from the live view on
  /// every read; the operator's picks live in [_choices] so a rebuild preserves
  /// them.
  List<PendingAccountEntry> get pendingEntries {
    final l = _linked;
    if (l == null) return const [];
    if (identical(_pendingCacheKey, l) &&
        _pendingCacheChoicesVersion == _choicesVersion &&
        _pendingEntriesCache != null) {
      return _pendingEntriesCache!;
    }
    final entries = <PendingAccountEntry>[];
    entries.addAll(_entriesFor(
      family: 'student',
      actionList: l.studentActions,
      targetId: (a) => a.target.id.value,
      label: (a) => _accountLabel(a.target),
      group: (a) => a.alternativeGroup,
      isDefault: (a) => a.isDefaultAlternative,
      changes: (a) => a.describeChanges(),
      // Since #245 the student family has an informational member too
      // (`AzureClassGroupMembership`), so the apply affordance is gated on the
      // action rather than assumed, exactly as the group family's is.
      canApply: (a) => a.canApply,
      unlockedSystems: (a) => a.unlockedSystems,
    ));
    entries.addAll(_entriesFor(
      family: 'staff',
      actionList: l.staffActions,
      targetId: (a) => a.target.id.value,
      label: (a) => _staffLabel(a.target),
      group: (a) => a.alternativeGroup,
      isDefault: (a) => a.isDefaultAlternative,
      changes: (a) => a.describeChanges(),
      // Read off the action like the other two families since #240: every staff
      // action is applyable today, but nothing here should assume it.
      canApply: (a) => a.canApply,
      unlockedSystems: (a) => a.unlockedSystems,
    ));
    entries.addAll(_entriesFor(
      family: 'group',
      actionList: l.groupActions,
      targetId: (a) => _groupLabel(a.target),
      label: (a) => _groupLabel(a.target),
      group: (a) => a.alternativeGroup,
      isDefault: (a) => a.isDefaultAlternative,
      changes: (a) => a.describeChanges(),
      canApply: (a) => a.canApply,
      unlockedSystems: (a) => a.unlockedSystems,
    ));
    _pendingCacheKey = l;
    _pendingCacheChoicesVersion = _choicesVersion;
    _pendingEntriesCache = entries;
    return entries;
  }

  /// The pending entries grouped into "same situation" subsets (#110), in
  /// first-seen order. Each subset shares a [PendingAccountEntry.situationKey],
  /// so it can be bulk-applied ("apply this resolution to all departed
  /// students") while each entry keeps its own chosen alternative.
  List<List<PendingAccountEntry>> get pendingSituations =>
      _groupSituations(pendingEntries);

  /// Groups [entries] into "same situation" subsets in first-seen order — the
  /// shared grouping the global list and the per-classroom / per-group
  /// drill-downs all use (#110/#154).
  static List<List<PendingAccountEntry>> _groupSituations(
    List<PendingAccountEntry> entries,
  ) {
    final order = <String>[];
    final bySituation = <String, List<PendingAccountEntry>>{};
    for (final e in entries) {
      final key = e.situationKey;
      if (!bySituation.containsKey(key)) order.add(key);
      (bySituation[key] ??= <PendingAccountEntry>[]).add(e);
    }
    return [for (final key in order) bySituation[key]!];
  }

  /// The live pending entries for the accounts of the currently-open classroom
  /// (#154): the interactive tiles the Actions drill-down builds for one class,
  /// joined to the lazily-loaded classroom docs by account id. Empty before a
  /// classroom is opened, or in a passive session with no live view to act on.
  List<PendingAccountEntry> get classroomPendingEntries {
    final accounts = _classroomAccounts;
    if (accounts == null || _linked == null) return const [];
    final ids = <String>{for (final a in accounts) a.id.value};
    return [
      for (final e in pendingEntries)
        if (ids.contains(e.targetId)) e,
    ];
  }

  /// [classroomPendingEntries] grouped into same-situation subsets, so the
  /// per-class list keeps the bulk-apply affordance of the old flat list (#154).
  List<List<PendingAccountEntry>> get classroomPendingSituations =>
      _groupSituations(classroomPendingEntries);

  /// The live group ("Klasgroepen") pending entries (#154): the interactive
  /// tiles the group drill-down builds. Empty in a passive session.
  List<PendingAccountEntry> get groupPendingEntries {
    if (_linked == null) return const [];
    return [
      for (final e in pendingEntries)
        if (e.family == 'group') e,
    ];
  }

  /// [groupPendingEntries] grouped into same-situation subsets (#154).
  List<List<PendingAccountEntry>> get groupPendingSituations =>
      _groupSituations(groupPendingEntries);

  /// The count shown in the Actions header (#154): the live entry count in an
  /// active session, or the summed top-level rollup pending counts in a passive
  /// session that only read the materialized view (no live entries to build).
  int get totalPendingCount {
    if (_linked != null) return pendingEntries.length;
    var total = 0;
    for (final r in _rollups) {
      if (r.level == RollupLevel.school || r.level == RollupLevel.groups) {
        total += r.pendingCount;
      }
    }
    return total;
  }

  /// The pending-action count shown on the Personeel tab's badge (#179): the
  /// live staff-family entry count in an active session, else the staff school
  /// rollup's stored pending count in a passive session.
  int get staffPendingCount {
    if (_linked != null) {
      return pendingEntries.where((e) => e.family == 'staff').length;
    }
    return staffSchoolRollup?.pendingCount ?? 0;
  }

  /// The pending-action count shown on the Leerlingen tab's badge (#179): the
  /// live student- and group-family entry count in an active session, else the
  /// summed student-school and "Klasgroepen" rollup pending counts in a passive
  /// session. Together with [staffPendingCount] this partitions
  /// [totalPendingCount] with no overlap or double-counting.
  int get studentPendingCount {
    if (_linked != null) {
      return pendingEntries.where((e) => e.family != 'staff').length;
    }
    var total = 0;
    for (final r in _rollups) {
      if (r.level == RollupLevel.groups ||
          (r.level == RollupLevel.school && r.school != staffPartition)) {
        total += r.pendingCount;
      }
    }
    return total;
  }

  /// Builds one [PendingAccountEntry] per target from [actionList], collapsing
  /// mutually-exclusive alternatives (shared non-null [group]) into a single
  /// [PendingChoice].
  List<PendingAccountEntry> _entriesFor<T>({
    required String family,
    required List<T> actionList,
    required String Function(T) targetId,
    required String Function(T) label,
    required String? Function(T) group,
    required bool Function(T) isDefault,
    required actions.ChangeSet Function(T) changes,
    required bool Function(T) canApply,
    required Set<core.Origin> Function(T) unlockedSystems,
  }) {
    final order = <String>[];
    final byTarget = <String, List<T>>{};
    final labels = <String, String>{};
    for (final a in actionList) {
      final id = targetId(a);
      if (!byTarget.containsKey(id)) order.add(id);
      (byTarget[id] ??= <T>[]).add(a);
      labels[id] = label(a);
    }

    return [
      for (final id in order)
        PendingAccountEntry(
          family: family,
          targetId: id,
          target: labels[id]!,
          choices: _choicesFor(
            id,
            [
              for (final a in byTarget[id]!)
                PendingActionOption(
                  action: a as Object,
                  kind: a.runtimeType.toString(),
                  group: group(a),
                  isDefault: isDefault(a),
                  family: family,
                  target: labels[id]!,
                  changes: changes(a),
                  canApply: canApply(a),
                  unlockedSystems: unlockedSystems(a),
                ),
            ],
          ),
        ),
    ];
  }

  /// Partitions one target's [options] into [PendingChoice]s: options sharing a
  /// non-null [PendingActionOption.group] become one mutually-exclusive choice
  /// (its selection honoured from [_choices], defaulting to the group default);
  /// every other option is a choice of one.
  List<PendingChoice> _choicesFor(
    String targetId,
    List<PendingActionOption> options,
  ) {
    final choices = <PendingChoice>[];
    final groupOrder = <String>[];
    final byGroup = <String, List<PendingActionOption>>{};
    for (final o in options) {
      final g = o.group;
      if (g == null) {
        choices.add(PendingChoice(alternatives: [o], selected: o));
      } else {
        if (!byGroup.containsKey(g)) groupOrder.add(g);
        (byGroup[g] ??= <PendingActionOption>[]).add(o);
      }
    }
    for (final g in groupOrder) {
      final alts = byGroup[g]!;
      final defaultKind =
          alts.firstWhere((a) => a.isDefault, orElse: () => alts.first).kind;
      final chosenKind = _choices['$targetId|$g'] ?? defaultKind;
      final selected = alts.firstWhere(
        (a) => a.kind == chosenKind,
        orElse: () => alts.firstWhere((a) => a.kind == defaultKind),
      );
      choices.add(PendingChoice(alternatives: alts, selected: selected));
    }
    return choices;
  }

  /// Records the operator's pick of a mutually-exclusive alternative (#110):
  /// within [entry]'s choice keyed by [group], select the option of [kind]. A
  /// no-op for a lone action. Notifies so the list re-renders the new selection.
  void chooseAlternative({
    required PendingAccountEntry entry,
    required String group,
    required String kind,
  }) {
    _choices['${entry.targetId}|$group'] = kind;
    _choicesVersion++;
    notifyListeners();
  }

  /// The duplicate-mail warnings of the current linked view (INV-23), each with
  /// its colliding accounts flattened for the drill-down and tagged with whether
  /// this exact collision has been [DuplicateMailWarning.accepted] (#109). Empty
  /// before a sync this session (a passive session has no live snapshot). Ordered
  /// as the linker raised them.
  List<DuplicateMailWarning> get duplicateWarnings {
    final l = _linked;
    if (l == null) return const [];
    return [
      for (final w in l.snapshot.warnings)
        if (w is core.ResolveDuplicateMail)
          DuplicateMailWarning(
            mail: w.mail,
            accounts: [for (final a in w.accounts) _duplicateRow(a)],
            accepted: duplicateAccepted(
              _decisions,
              mail: w.mail,
              uids: w.accounts.map((a) => a.uid),
            ),
          ),
    ];
  }

  DuplicateAccountRow _duplicateRow(core.SmartschoolAccount account) {
    final concrete = account is ss.SmartschoolAccount ? account : null;
    final name = concrete == null
        ? account.uid
        : (_nonEmpty('${concrete.givenName} ${concrete.surname}') ??
            account.uid);
    return DuplicateAccountRow(
      uid: account.uid,
      name: name,
      accountType: account.accountType.toJson(),
      role: concrete?.role?.toJson() ?? 'onbekend',
    );
  }

  /// Accepts the duplicate-mail collision on [mail] as deliberate (#109),
  /// persisting an [AccountDecision] keyed to one of the colliding accounts so it
  /// survives a re-sync (re-attached by the decisions merge). A no-op when no
  /// live warning matches [mail]. The warning is demoted immediately.
  Future<void> acceptDuplicate(String mail) async {
    final warning = _duplicateWarningFor(mail);
    if (warning == null) return;
    final uids = warning.accounts.map((a) => a.uid);
    final accountId = _linkedIdForUids(uids);
    if (accountId == null) {
      log.addError(
        core.Origin.smartschool,
        'Kon geen account vinden voor de dubbele mail "$mail".',
      );
      return;
    }
    final decision = acceptedDuplicateDecision(
      accountId: accountId,
      mail: mail,
      uids: uids,
      decidedBy: syncedBy,
      decidedAt: _now(),
    );
    try {
      await store.putDecision(decision);
      _decisions = [
        for (final d in _decisions)
          if (decisionDocId(d) != decisionDocId(decision)) d,
        decision,
      ];
      log.addMessage(
        core.Origin.smartschool,
        'Dubbele mail "$mail" geaccepteerd.',
      );
      notifyListeners();
    } on Object catch (e) {
      log.addError(
          core.Origin.smartschool, 'Kon de acceptatie niet opslaan: $e');
    }
  }

  /// Revokes a previously accepted duplicate-mail collision on [mail] (#109), so
  /// it warns again. A no-op when the collision is not currently accepted.
  Future<void> revokeDuplicate(String mail) async {
    final warning = _duplicateWarningFor(mail);
    if (warning == null) return;
    final decision = findAcceptedDuplicate(
      _decisions,
      mail: mail,
      uids: warning.accounts.map((a) => a.uid),
    );
    if (decision == null) return;
    try {
      await store.deleteDecision(decision);
      _decisions = [
        for (final d in _decisions)
          if (decisionDocId(d) != decisionDocId(decision)) d,
      ];
      log.addMessage(
        core.Origin.smartschool,
        'Acceptatie van dubbele mail "$mail" ingetrokken.',
      );
      notifyListeners();
    } on Object catch (e) {
      log.addError(
        core.Origin.smartschool,
        'Kon de acceptatie niet intrekken: $e',
      );
    }
  }

  core.ResolveDuplicateMail? _duplicateWarningFor(String mail) {
    final l = _linked;
    if (l == null) return null;
    final want = normalizeDuplicateMail(mail);
    for (final w in l.snapshot.warnings) {
      if (w is core.ResolveDuplicateMail &&
          normalizeDuplicateMail(w.mail) == want) {
        return w;
      }
    }
    return null;
  }

  /// The linked-account id of the first (sorted) [uids] that resolves to a linked
  /// account or staff member — the stable target an accepted-duplicate decision
  /// attaches to, so the merge keeps it while that account still carries the
  /// warning. Null when none of the uids maps (defensive; the colliding accounts
  /// are always in the snapshot per INV-23).
  core.LinkedAccountId? _linkedIdForUids(Iterable<String> uids) {
    final l = _linked;
    if (l == null) return null;
    final byUid = <String, core.LinkedAccountId>{
      for (final a in l.snapshot.accounts)
        if (a.smartschool?.uid case final uid?) uid: a.id,
      for (final s in l.snapshot.staff)
        if (s.smartschool?.uid case final uid?) uid: s.id,
    };
    for (final uid in sortedDuplicateUids(uids)) {
      final id = byUid[uid];
      if (id != null) return id;
    }
    return null;
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

  /// The [wisaPullFingerprint] of the live settings, or the stamped one when no
  /// [liveSettings] holder is wired (which leaves the gate permanently open).
  String _wisaFingerprint() {
    final live = liveSettings;
    return live == null
        ? _wisaPullFingerprint
        : wisaPullFingerprint(live.current);
  }

  /// Why **Check for drift** is unavailable right now, or `null` when it can
  /// run (#238).
  ///
  /// A drift pass deliberately re-reads only Smartschool and Azure: the WISA
  /// roster it links them against is whatever this session already holds, cold
  /// seed included. So once the operator saves a werkdatum — or a virtuele
  /// werkdatum, or a school's virtual mark — that roster is not the one their
  /// change asks for, and a drift pass would relink against the old one,
  /// materialize the result, bump the generation and broadcast it to every other
  /// operator. Refusing until a full [sync] has pulled WISA with the new
  /// settings is the honest answer.
  String? get driftBlockedReason => _wisaFingerprint() == _wisaPullFingerprint
      ? null
      : 'WISA-instellingen gewijzigd — synchroniseer eerst.';

  /// Whether **Check for drift** can be started right now: no pass running, no
  /// other operator holding the lease, and the WISA settings unchanged since
  /// this session's roster was pulled (#238).
  bool get canCheckDrift =>
      !busy && !syncLockedByOther && driftBlockedReason == null;

  /// Records that the WISA snapshot now in hand was pulled with [fingerprint] —
  /// the live settings as they stood when the pull *started*, so a save landing
  /// mid-pull stays pending rather than being credited to a pull that never saw
  /// it (#238).
  void _stampWisaPull(String fingerprint) => _wisaPullFingerprint = fingerprint;

  /// Whether the store holds a materialized overview (rollups) to drill into —
  /// true after any session has synced, even without a pull this session.
  bool get hasOverview => _rollups.isNotEmpty;

  /// The school-level rollups, alphabetical — the stored per-school aggregates.
  /// They no longer render as nodes in the student drill-down (#210 flattened
  /// that to grade-years), but they are what the per-category summaries and the
  /// passive-session badge counts are summed from, so they stay materialized.
  List<Rollup> get schoolRollups {
    final schools = [
      for (final r in _rollups)
        if (r.level == RollupLevel.school) r,
    ]..sort((a, b) => a.label.compareTo(b.label));
    return schools;
  }

  /// The single synthetic staff ("Personeel") school rollup, or `null` when no
  /// staff account has been materialized — the drill-down root of the Personeel
  /// tab (#179), which shows only the staff action family.
  Rollup? get staffSchoolRollup {
    for (final r in _rollups) {
      if (r.level == RollupLevel.school && r.school == staffPartition) return r;
    }
    return null;
  }

  /// The synthetic "Niet toegewezen" school rollup — accounts with no class of
  /// ours (a leaver, or a student of a school we do not manage who still owns
  /// one of our accounts, #178) — or `null` when the bucket is empty.
  Rollup? get unassignedRollup {
    for (final r in _rollups) {
      if (r.level == RollupLevel.school && r.school == unassignedPartition) {
        return r;
      }
    }
    return null;
  }

  /// The top-level nodes of the **student** drill-down (#210): one merged
  /// grade-year node per year across *every* managed school, then the
  /// "Niet toegewezen" bucket.
  ///
  /// The WISA school split is administrative, not operational — everyone running
  /// this software treats the managed schools as one school — so the school level
  /// carries no decision and is flattened away here. This is a **view**
  /// projection: the stored rollups keep their school → grade-year → classroom
  /// shape, which matters twice over. `school` is the Cosmos partition key of the
  /// per-account documents, so a classroom node must keep its real school for
  /// [openClassroom] to read exactly one partition; and [totalPendingCount],
  /// [staffPendingCount], [studentPendingCount], [schoolRollups] and the
  /// per-category summaries all aggregate over [RollupLevel.school], so a passive
  /// session's badges keep reading from data that is still there.
  ///
  /// Ordering is pinned: Jaar 1 … Jaar 7 numerically, then the non-numeric years
  /// ([gradeNodeLabel] renders those as "Overige klassen" — `OKAN` and friends
  /// bucket into the materializer's synthetic `Overig`), then
  /// "Niet toegewezen". The Klasgroepen node is appended by the screen, below
  /// these.
  List<Rollup> get studentRollups {
    final tallies = <String, _GradeTally>{};
    for (final r in _rollups) {
      if (r.level != RollupLevel.gradeYear) continue;
      if (r.school == staffPartition || r.school == unassignedPartition) {
        continue;
      }
      (tallies[r.gradeYear] ??= _GradeTally())
          .add(accounts: r.accountCount, pending: r.pendingCount);
    }
    final grades = <Rollup>[
      for (final entry in tallies.entries)
        Rollup(
          level: RollupLevel.gradeYear,
          key: _mergedGradeKey(entry.key),
          parentKey: null,
          // Merged across schools, so this node belongs to no single partition;
          // only the classroom nodes beneath it carry a real one.
          school: '',
          label: gradeNodeLabel(entry.key),
          gradeYear: entry.key,
          classroom: '',
          accountCount: entry.value.accounts,
          pendingCount: entry.value.pending,
        ),
    ]..sort(_byGradeYear);
    final unassigned = unassignedRollup;
    return <Rollup>[...grades, if (unassigned != null) unassigned];
  }

  /// The classroom nodes under one [studentRollups] node (#210).
  ///
  /// A merged grade-year node collects that year's classrooms from **every**
  /// managed school; "Niet toegewezen" skips its always-synthetic grade level and
  /// lists its classrooms ("Zonder klas") directly. Every node returned is a real
  /// stored classroom rollup, so it still carries the [Rollup.school] partition
  /// [openClassroom] reads.
  List<Rollup> studentChildrenOf(Rollup node) {
    final bool unassigned = node.school == unassignedPartition;
    final children = <Rollup>[
      for (final r in _rollups)
        if (r.level == RollupLevel.classroom &&
            r.school != staffPartition &&
            (unassigned
                ? r.school == unassignedPartition
                : r.school != unassignedPartition &&
                    r.gradeYear == node.gradeYear))
          r,
    ]..sort((a, b) => a.label.compareTo(b.label));
    return children;
  }

  /// The synthetic node key of the merged grade-year [gradeYear] — distinct from
  /// any stored rollup key, which is always school-scoped (#210).
  static String _mergedGradeKey(String gradeYear) => 'grades|$gradeYear';

  /// How a grade-year node is named: `Jaar 3` for a real year, and
  /// "Overige klassen" for the materializer's synthetic non-numeric bucket
  /// (`OKAN` and friends), which as a top-level node would otherwise read as the
  /// nonsensical "Jaar Overig" (#210).
  static String gradeNodeLabel(String gradeYear) =>
      int.tryParse(gradeYear) == null ? _otherGradesLabel : 'Jaar $gradeYear';

  static const String _otherGradesLabel = 'Overige klassen';

  /// Pins the top-level order: numeric years ascending, then the non-numeric
  /// ones by label, so the accordion never reshuffles between syncs.
  static int _byGradeYear(Rollup a, Rollup b) {
    final na = int.tryParse(a.gradeYear);
    final nb = int.tryParse(b.gradeYear);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.label.compareTo(b.label);
  }

  /// The rollup nodes directly under [parentKey] (grade-years of a school, or
  /// classrooms of a grade-year), alphabetical. The stored parent/child shape —
  /// what the Personeel tab drills; the student tree flattens it away through
  /// [studentRollups] / [studentChildrenOf] (#210).
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

  /// The three category summaries the Reconcile overview renders (#163), summed
  /// from the stored rollups so they read in a passive session too: students are
  /// every school rollup *except* the synthetic staff bucket, staff is that
  /// bucket, and class groups is the single "Klasgroepen" node. Each is zero
  /// before any operator has synced.
  CategorySummary get studentSummary {
    var total = 0;
    var pending = 0;
    for (final r in _rollups) {
      if (r.level == RollupLevel.school && r.school != staffPartition) {
        total += r.accountCount;
        pending += r.pendingCount;
      }
    }
    return CategorySummary(total: total, pending: pending);
  }

  /// The staff category summary (#163): the single school rollup living in the
  /// synthetic [staffPartition] bucket, or [CategorySummary.empty] when no staff
  /// account has been materialized.
  CategorySummary get staffSummary {
    for (final r in _rollups) {
      if (r.level == RollupLevel.school && r.school == staffPartition) {
        return CategorySummary(total: r.accountCount, pending: r.pendingCount);
      }
    }
    return CategorySummary.empty;
  }

  /// The class-groups category summary (#163): the single "Klasgroepen" rollup
  /// node, or [CategorySummary.empty] when no group carries an action to surface.
  CategorySummary get groupSummary {
    final r = groupRollup;
    return r == null
        ? CategorySummary.empty
        : CategorySummary(total: r.accountCount, pending: r.pendingCount);
  }

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

  /// How many pending actions an apply pass would actually write — the
  /// **selected** applyable option of each choice (#110). A departed student
  /// counts once (the chosen resolution), not twice, and the informational group
  /// actions are excluded.
  int get applyableCount => _selectedActions(pendingEntries).length;

  /// What a confirmed apply of [entries] would actually write (#234) — the
  /// systems the apply-confirmation dialog names, derived from the very options
  /// [applyAll] / [applySituation] / [applyEntry] would run.
  ///
  /// Two halves, because they are not the same claim. [ApplyScope.systems] is
  /// what the selected actions write themselves, one entry per action.
  /// [ApplyScope.chained] is what only a follow-up would reach — an
  /// `AddStudentToAzure` writes Office 365 and then, off the same click, writes
  /// the Smartschool account its chain unlocks (#230/#240), which is a system
  /// the visible action never names. The follow-up cannot be counted, because
  /// its own `evaluate` decides at apply time whether it runs at all; it can
  /// only be named.
  ApplyScope applyScope(Iterable<PendingAccountEntry> entries) {
    final selected = _selectedActions(entries);
    if (selected.isEmpty) return ApplyScope.empty;
    final systems = <core.Origin>[for (final o in selected) o.changes.system];
    final chained = <core.Origin>{
      for (final o in selected) ...o.unlockedSystems,
    }..removeAll(systems);
    return ApplyScope(systems: systems, chained: chained);
  }

  /// The live actions to run for [entries]: the selected, applyable option of
  /// every choice, in order.
  List<PendingActionOption> _selectedActions(
    Iterable<PendingAccountEntry> entries,
  ) =>
      [
        for (final e in entries)
          for (final c in e.choices)
            if (c.selected.canApply) c.selected,
      ];

  /// Runs the smart sync: pull WISA, diff against the retained snapshot, and
  /// only when something changed (or nothing is linked yet) pull the still-
  /// missing systems and re-link.
  Future<void> sync() async {
    if (busy) return;
    if (!await _acquireLock()) return;
    _begin(ReconcilePhase.syncing);
    try {
      final previous = app.wisa.snapshot;
      // Read before the pull, stamped after it: the syncer resolves the very
      // same document, so this names exactly the settings WISA was asked with
      // (#238).
      final pulledWith = _wisaFingerprint();
      log.addMessage(core.Origin.wisa, 'Syncing WISA…');
      final fresh = await app.sync(core.Origin.wisa) as wapi.WisaSnapshot;
      _stampWisaPull(pulledWith);
      _recordPull(core.Origin.wisa, fresh);
      _setProgress(0.25);
      log.addMessage(
        core.Origin.wisa,
        'WISA sync done: ${fresh.students.length} students, '
        '${fresh.staff.length} staff, ${fresh.classGroups.length} classes.',
      );
      // Repair the operator's stored school profiles from this pull (#207).
      // Runs before the unchanged-since-last-sync shortcut below, so a session
      // that has nothing to reconcile still heals a settings document whose
      // schools have no names.
      await _backfillSchoolProfiles(fresh.schools);

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
        _logSyncComplete();
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
      _setProgress(0.45);
      if (app.azure.snapshot == null) {
        await _renewLock();
        log.addMessage(core.Origin.azure, 'Syncing Azure AD…');
        _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));
      }
      _setProgress(0.65);

      await _relink();
      _logSyncComplete();
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      _fail(e);
    } finally {
      await _releaseLock();
    }
  }

  /// Terminal "the pass is done, the screen is current" log line closing a
  /// successful [sync] (#162). The [noChangesNeeded] path says so explicitly;
  /// otherwise it names how many pending actions await the operator.
  void _logSyncComplete() {
    // Name the operator who ran the pass when known (#169); an empty/unknown
    // operator degrades gracefully (nothing appended, no dangling "by ").
    final by = syncedBy.isEmpty ? '' : ' Operator: $syncedBy.';
    final message = _noChangesNeeded
        ? 'Sync complete — no account changes needed. Ready.$by'
        : 'Sync complete — ${pendingActions.length} pending action(s). Ready.$by';
    log.addMessage(core.Origin.all, message);
  }

  /// Explicitly re-reads Smartschool and Azure (drift introduced by edits made
  /// through other tools) and re-links. WISA is not re-pulled — that is what
  /// [sync] is for.
  ///
  /// Refuses outright while [driftBlockedReason] is set: because WISA is not
  /// re-pulled here, a pass run after a werkdatum change would reconcile against
  /// the roster the change never reached and publish that to the whole team
  /// (#238). The button is disabled with the same reason on screen; this guard
  /// is the backstop for every other caller.
  Future<void> checkDrift() async {
    if (busy) return;
    final blocked = driftBlockedReason;
    if (blocked != null) {
      log.addMessage(core.Origin.wisa, blocked);
      return;
    }
    if (!await _acquireLock()) return;
    _begin(ReconcilePhase.syncing);
    try {
      log.addMessage(
        core.Origin.smartschool,
        'Checking Smartschool for drift…',
      );
      _recordPull(
          core.Origin.smartschool, await app.sync(core.Origin.smartschool));
      _setProgress(0.35);
      await _renewLock();
      log.addMessage(core.Origin.azure, 'Checking Azure AD for drift…');
      _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));
      _setProgress(0.6);

      if (app.wisa.snapshot == null) {
        await _renewLock();
        final pulledWith = _wisaFingerprint();
        log.addMessage(core.Origin.wisa, 'Syncing WISA…');
        _recordPull(core.Origin.wisa, await app.sync(core.Origin.wisa));
        _stampWisaPull(pulledWith);
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
      _decisions = await store.readDecisions();
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
    _decisions = await store.readDecisions();
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

  /// Dry-runs the chosen resolution of **every** pending entry (PAIN-3): the
  /// full apply path, zero writes. Results land in [dryRunResults].
  Future<void> dryRun() => _run(_selectedActions(pendingEntries), dry: true);

  /// Applies the chosen resolution of every pending entry for real, refreshing
  /// the linked view from the State layer's incremental patches as it goes.
  /// Only the **selected** alternative of each choice runs — a departed student
  /// is unregistered *or* deleted, never both (#110). Results land in
  /// [applyResults].
  Future<void> applyAll() => _run(_selectedActions(pendingEntries), dry: false);

  /// Dry-runs one entry's chosen resolution (#110): the per-row preview.
  Future<void> dryRunEntry(PendingAccountEntry entry) =>
      _run(_selectedActions([entry]), dry: true);

  /// Applies one entry's chosen resolution (#110): the per-row apply.
  Future<void> applyEntry(PendingAccountEntry entry) =>
      _run(_selectedActions([entry]), dry: false);

  /// Applies the chosen resolution to every entry in the same situation (#110):
  /// "apply this resolution to all departed students". Each entry keeps its own
  /// chosen alternative. [situationKey] matches [PendingAccountEntry.situationKey].
  Future<void> applySituation(String situationKey) => _run(
        _selectedActions(
          pendingEntries.where((e) => e.situationKey == situationKey),
        ),
        dry: false,
      );

  /// Dry-runs every entry in the same situation (#110).
  Future<void> dryRunSituation(String situationKey) => _run(
        _selectedActions(
          pendingEntries.where((e) => e.situationKey == situationKey),
        ),
        dry: true,
      );

  /// Runs [selected] — the pre-resolved, applyable options — through the apply
  /// path (dry or real). Shared by the global, per-entry, and per-situation
  /// affordances so all three behave identically (#110). Each option is bound to
  /// its own target; on a real write the applier patches the snapshot and
  /// returns a fresh linked view we adopt as the pass proceeds.
  Future<void> _run(
    List<PendingActionOption> selected, {
    required bool dry,
  }) async {
    if (busy || _linked == null) return;
    _begin(ReconcilePhase.applying);

    final options =
        dry ? actions.ApplyOptions.dry : const actions.ApplyOptions();
    final results = <ActionOutcomeEntry>[];
    final label = dry ? 'Dry-run' : 'Apply';
    log.addMessage(
      core.Origin.all,
      '$label started for ${selected.length} of ${pendingActions.length} '
      'pending action(s).',
    );

    try {
      for (final (index, option) in selected.indexed) {
        // Name the action *before* it runs, so the modal progress dialog says
        // what is in flight rather than what just finished (#243). `results`
        // already holds one row per write performed, so anything in it beyond
        // the [index] steps that completed is a chained follow-up.
        _setApplyStep(ApplyStep(
          dry: dry,
          index: index + 1,
          total: selected.length,
          target: option.target,
          summary: option.changes.summary,
          followUps: results.length - index,
        ));
        results.addAll(await _applyOne(
          () => _applyAny(option.action, options),
          option.target,
          option.changes,
        ));
        // Advance once per action so a long apply/dry-run pass reads as busy
        // and visibly progressing rather than a motionless bar (#176).
        _setProgress((index + 1) / selected.length);
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
      _applyStep = null;
      _finish(ReconcilePhase.ready);
    } on Object catch (e) {
      // _applyOne swallows per-action failures; reaching here means the pass
      // itself broke (e.g. the post-write re-link). Keep partial results.
      if (dry) {
        _dryRunResults = results;
      } else {
        _applyResults = results;
      }
      // Nothing is in flight any more, however the pass ended (#243).
      _applyStep = null;
      _fail(e);
    }
  }

  /// Dispatches one live action to the applier by its family.
  Future<ApplyResult> _applyAny(Object action, actions.ApplyOptions options) {
    if (action is actions.StudentAction) {
      return applier.applyStudent(action, options: options);
    }
    if (action is actions.StaffAction) {
      return applier.applyStaff(action, options: options);
    }
    return applier.applyGroup(action as actions.GroupAction, options: options);
  }

  /// Runs one selected option and returns a result row per **write it
  /// performed**: the option's own, followed by any follow-up the State layer
  /// chained onto it (#230).
  ///
  /// A new student's provisioning is one such chain — the Office 365 create
  /// unlocks the Smartschool create, which the applier runs against the freshly
  /// relinked record — and the operator's one click therefore made two writes.
  /// Both are logged and both land in the results list; hiding the second would
  /// under-report what the app just did.
  Future<List<ActionOutcomeEntry>> _applyOne(
    Future<ApplyResult> Function() run,
    String target,
    actions.ChangeSet changes,
  ) async {
    try {
      final applied = await run();
      if (applied.refreshed) _linked = applied.linked;
      final result = applied.result;
      return <ActionOutcomeEntry>[
        _record(target, changes, result),
        for (final followUp in applied.followUps)
          _record(target, followUp.changes, followUp),
      ];
    } on Object catch (e) {
      // An action that throws (instead of returning failed) must not abort
      // the rest of the pass.
      log.addError(changes.system, '$target — ${changes.summary}: $e');
      return <ActionOutcomeEntry>[
        ActionOutcomeEntry(
          target: target,
          changes: changes,
          outcome: actions.ActionOutcome.failed,
          error: e,
        ),
      ];
    }
  }

  /// Logs one action's outcome and shapes it as a results-list row.
  ActionOutcomeEntry _record(
    String target,
    actions.ChangeSet changes,
    actions.ActionResult result,
  ) {
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
  }

  Future<void> _relink() async {
    _phase = ReconcilePhase.linking;
    _setProgress(0.75);
    notifyListeners();
    _linked = await applier.link();
    final s = _linked!.snapshot;
    log.addMessage(
      core.Origin.all,
      'Linked: ${s.accounts.length} students, ${s.staff.length} staff, '
      '${s.groups.length} groups; ${pendingActions.length} pending '
      'action(s), ${s.warnings.length} warning(s).',
    );
    _logSkippedNamesakes(s.warnings);
    _setProgress(0.9);
    await _persist(_linked!);
  }

  /// Names every WISA class the group link passed over because Smartschool
  /// already carries its name on a group it could not adopt (#225).
  ///
  /// The skip is correct — an unofficial group is not a class — but it used to
  /// be invisible, and an unmatched WISA class reads exactly like a class that
  /// does not exist downstream. That is what had the Klasgroepen list offering
  /// to create a class Smartschool already had, so each one gets a line of its
  /// own naming the group that was skipped and why.
  void _logSkippedNamesakes(List<core.LinkWarning> warnings) {
    for (final w in warnings) {
      if (w is! core.SmartschoolNamesakeSkipped) continue;
      final ss = w.smartschool;
      log.addMessage(
        core.Origin.smartschool,
        'Klas "${w.wisaName}" niet gekoppeld: Smartschool heeft al '
        '"${ss.name}" (code ${ss.id.value}), '
        '${ss.official ? 'met een andere schrijfwijze' : 'maar geen '
            'officiële klas'}.',
      );
    }
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
      // Say so when the managed-school filter dropped students (#230). The drop
      // is deliberate (#178) but it used to be invisible, so a school the
      // operator forgot to flag as ours in Instellingen looked exactly like a
      // WISA pull that never returned the class.
      if (view.skippedUnmanagedStudents > 0) {
        log.addMessage(
          core.Origin.wisa,
          '${view.skippedUnmanagedStudents} leerling(en) overgeslagen: '
          'niet in een school die we beheren.',
        );
      }
      final merge = mergeDecisions(
        accounts: view.accounts,
        groups: view.groups,
        existing: await store.readDecisions(),
      );
      // The surviving decisions are what the store keeps; mirror them so the
      // live duplicate-warning demotion reflects the post-sync truth (#109).
      _decisions = merge.surviving;
      final merged = MaterializedView(
        generation: view.generation,
        accounts: merge.accounts,
        groups: merge.groups,
        rollups: view.rollups,
      );
      final at = _now();
      // Guard the shared-store write with a timeout: a full view is ~9.6k
      // account docs, and a stalled write must not leave the pass wedged in
      // `linking` with Synchronise disabled forever — the in-memory view is
      // usable this session regardless (#168). Progress lines from the store
      // keep a long-but-healthy write visible in the log.
      await store
          .writeMaterialized(
            merged,
            syncedBy: syncedBy,
            at: at,
            droppedDecisions: merge.dropped,
            systemSyncs: _pulled,
            onProgress: (m) => log.addMessage(core.Origin.all, m),
          )
          .timeout(persistTimeout);
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
    } on TimeoutException {
      log.addError(
        core.Origin.all,
        'Persisting the linked view timed out after '
        '${persistTimeout.inSeconds}s — the linked view is usable this session '
        'but was not saved to the shared store.',
      );
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Could not persist the linked view: $e');
    }
  }

  /// The WISA school-id → label map the materializer bakes into its documents.
  ///
  /// Built from the persisted [schoolProfiles] merged with the current WISA
  /// snapshot's schools (empty before the first pull), so a school reads as
  /// `Instituut Sancta Maria-A (ISMAA)` — the same identity the Settings grid
  /// shows — instead of degrading to `School <id>` whenever the session's
  /// snapshot happens to carry no schools (#204).
  Map<int, String> _schoolLabels() => wisaSchoolLabels(
        profiles: schoolProfiles,
        schools: app.wisa.snapshot?.schools ?? const <wapi.WisaSchool>[],
      );

  /// Writes the school names and codes this WISA pull carries back into the
  /// stored profiles (#207), so the Settings grid names every school it lists
  /// without the operator having to press **Scholen ophalen** and **Opslaan**.
  ///
  /// Strictly a repair of the two derived halves: no profile is added, removed
  /// or reordered, and `ours` / `virtual` / `prefix` are never rewritten — the
  /// operator's curation of *which* schools are listed and managed stays a
  /// Settings-only decision. The document is re-read immediately before the
  /// write so a change another operator saved during this pass is not clobbered
  /// by this session's startup copy, and nothing is written when the pull adds
  /// nothing new.
  ///
  /// A failing settings store must never fail the sync: the pull itself
  /// succeeded and the labels are correct in memory (the drill-down merges the
  /// snapshot), so the problem is logged and the pass continues.
  Future<void> _backfillSchoolProfiles(List<wapi.WisaSchool> schools) async {
    final store = settingsStore;
    if (store == null || schools.isEmpty) return;
    try {
      final stored = await store.load();
      final repaired = mergeWisaSchoolProfiles(
        profiles: stored.wisaSchools,
        schools: schools,
      );
      final healed = <int>[
        for (var i = 0; i < repaired.length; i++)
          if (repaired[i] != stored.wisaSchools[i]) repaired[i].schoolId,
      ];
      if (healed.isEmpty) return;
      await store.save(stored.copyWith(wisaSchools: repaired));
      log.addMessage(
        core.Origin.wisa,
        'Updated the name and code of ${healed.length} WISA school(s) in the '
        'settings (id ${healed.join(', ')}).',
      );
    } on Object catch (e) {
      log.addError(
        core.Origin.wisa,
        'Could not update the WISA school names in the settings: $e',
      );
    }
  }

  void _begin(ReconcilePhase phase) {
    _phase = phase;
    _progress = 0.0;
    _applyStep = null;
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
    _settingsSub?.cancel();
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

/// Accumulator for one merged grade-year node of
/// [ReconcileController.studentRollups] (#210): the summed account and pending
/// counts of that year across every managed school.
class _GradeTally {
  int accounts = 0;
  int pending = 0;

  void add({required int accounts, required int pending}) {
    this.accounts += accounts;
    this.pending += pending;
  }
}
