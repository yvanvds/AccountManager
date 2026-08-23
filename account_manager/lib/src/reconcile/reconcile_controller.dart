import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:flutter/foundation.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../format/timestamps.dart';
import '../settings/wisa_rule_labels.dart';
import 'log_buffer.dart';

/// What the reconcile screen is doing right now.
enum ReconcilePhase {
  /// Nothing has run yet this session.
  ///
  /// A passive read of the shared store (`loadOverview`) leaves the phase
  /// here — it is not a pass — so a session that only ever reads stays idle,
  /// and the screen keeps explaining what its two buttons do (#275).
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
    this.family = '',
    this.targetId = '',
    this.situationId = '',
  });

  /// Human label of the record the action targets.
  final String target;

  /// The action's own change description (summary + field diff).
  final actions.ChangeSet changes;

  final actions.ActionOutcome outcome;

  /// The failure cause when [outcome] is [actions.ActionOutcome.failed].
  final Object? error;

  /// Which family the [PendingAccountEntry] this row came from belongs to —
  /// `student`, `staff` or `group` (#272).
  final String family;

  /// The [PendingAccountEntry.targetId] this row came from (#272).
  ///
  /// Carried beside the human [target] so a pass's verdict can be routed back
  /// to the very card the operator pressed **Toepassen** on. The label alone
  /// cannot do that: it is a display string, and a class and an account can
  /// read the same.
  final String targetId;

  /// The [PendingChoice.situationId] of the decision this row is the verdict of
  /// — the option's `group ?? kind` (#283).
  ///
  /// [family] + [targetId] name the *card*; a card can raise several
  /// independent decisions at once (a class new to Smartschool **and** without
  /// an Office 365 group raises two), so routing a verdict to the decision it
  /// answers needs this third stamp. A chained follow-up (#230/#240/#245)
  /// carries the situation of the option that unlocked it, because that is the
  /// decision the operator took when they started it.
  ///
  /// Empty on a row recorded before the stamp existed; such a row belongs to no
  /// decision and is reported at card level instead (see
  /// [ReconcileController.unroutedApplyOutcomesFor]).
  final String situationId;

  /// Whether this row is a key for [ReconcileController.applyOutcomesFor] at
  /// all — a row recorded before the entry identity existed carries neither
  /// half and belongs to no card.
  bool get identifiesEntry => family.isNotEmpty && targetId.isNotEmpty;
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
    required this.targetId,
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

  /// The [PendingAccountEntry.targetId] of the entry this option belongs to —
  /// what routes a pass's verdict back to the card it was started from (#272).
  final String targetId;

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

  /// The decision this option belongs to, by the same rule
  /// [PendingChoice.situationId] uses (#283) — the alternative group when this
  /// option is one of several mutually-exclusive resolutions, else its own
  /// kind. What routes a pass's verdict back to the decision that raised it.
  String get situationId => group ?? kind;
}

/// What a confirmed apply of a selection would write, for the confirmation
/// dialog (#234).
///
/// Built by [ReconcileController.applyScope] from the **selected**, applyable
/// option of each choice — exactly the actions `applyEntries` / `applyEntry`
/// would run — so the dialog names the systems the pass genuinely reaches
/// instead of the hard-coded "Smartschool and Azure AD" it used to claim for
/// every action.
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
  /// so two departed students share one bulk-apply subset, and — since #283 —
  /// routes a pass's verdict back to the decision it is the verdict of.
  String get situationId => alternatives.first.situationId;

  /// A short human description of *this* decision (#292): both sides of an
  /// either/or, or the lone action's summary. What a [SituationCohort] leads
  /// with, so the header names the one decision it applies and nothing else.
  String get situationLabel => isChoice
      ? alternatives.map((a) => a.changes.summary).join(' / ')
      : selected.changes.summary;
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

  /// Whether an apply pass would write anything for this entry — at least one
  /// selected option is applyable.
  bool get canApply => choices.any((c) => c.selected.canApply);
}

/// One account's stake in one decision (#292): the card the decision sits on,
/// and the decision itself. The unit of work every bulk affordance acts on.
///
/// Both halves, because neither is enough on its own. The [choice] is what a
/// pass runs and what a cohort is keyed by; the [entry] is what the pass owes
/// the shared store afterwards (`_shareApplied` patches *targets*, and a choice
/// carries only a display label) and what the operator is shown.
class PendingDecision {
  const PendingDecision({required this.entry, required this.choice});

  /// The card this decision was raised on.
  final PendingAccountEntry entry;

  /// The decision itself, with its alternatives and the operator's pick.
  final PendingChoice choice;

  /// The decision's identity, by the same rule everything else keys on.
  String get situationId => choice.situationId;

  /// Whether an apply pass would write anything for **this decision** — the
  /// selected alternative is applyable. Deliberately not
  /// [PendingAccountEntry.canApply], which answers for the whole card: a
  /// namesake class whose import decision is a hand-fix notice still has an
  /// applyable Office 365 group decision beside it, and a cohort of the former
  /// must not count itself as work.
  bool get canApply => choice.selected.canApply;
}

/// Every account that raises one and the same decision (#292) — the subset a
/// bulk apply of that decision covers.
///
/// The cohort replaces the "same combination of decisions" grouping that keyed
/// on the family plus the sorted set of *every* decision on a card. Two students
/// who both need their class changed in Smartschool landed in different subsets
/// the moment one of them also needed an email fix, so the one operation the app
/// exists for at the September rollover — every student changes class — was
/// fragmented hardest of all. One decision, one cohort; a card with three
/// decisions appears in three of them.
class SituationCohort {
  const SituationCohort({required this.key, required this.decisions})
      : assert(decisions.length > 0);

  /// The cohort's identity — the family plus the [PendingChoice.situationId] it
  /// groups. Family included because a situation is only unique within one: the
  /// three dispatchers name their action classes independently.
  final String key;

  /// The accounts raising this decision, in first-seen order.
  final List<PendingDecision> decisions;

  /// How many accounts are in the cohort.
  int get length => decisions.length;

  /// What this decision reads as — both sides of an either/or, or the lone
  /// action's summary. Taken off the first member because every member of a
  /// cohort answers the same question.
  String get label => decisions.first.choice.situationLabel;

  /// How many of them a bulk apply would actually write — the count the "Alles
  /// toepassen (n)" button quotes. Zero for a cohort of informational notices,
  /// which is what disables the button.
  int get applyableCount => decisions.where((d) => d.canApply).length;
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
/// exists, it reports "geen accountwijzigingen nodig" and stops — no re-link, no
/// action churn. Smartschool / Azure are pulled only when still missing this
/// session **or when their own settings inputs have moved** ([
/// systemsAwaitingSettings], #259); re-reading them for drift somebody else
/// introduced through another tool is the explicit [checkDrift] action, not the
/// default. The shortcut also stands down when a setting only the link consumes
/// has moved ([linkAwaitingSettings], #264) — that falls through to the re-link
/// without pulling anything.
class ReconcileController extends ChangeNotifier {
  ReconcileController({
    required this.app,
    required this.applier,
    required this.log,
    required this.store,
    this.syncedBy = '',
    List<WisaSchoolProfile> schoolProfiles = const <WisaSchoolProfile>[],
    this.settingsStore,
    this.liveSettings,
    this.publisher,
    this.subscriber,
    this.persistTimeout = const Duration(minutes: 10),
    DateTime Function()? clock,
  })  : _bootstrapSchoolProfiles = schoolProfiles,
        _now = clock ?? DateTime.now {
    final sub = subscriber;
    if (sub != null) _signalSub = sub.signals.listen(_onSignal);
    // The snapshot this session starts with — seeded from the cold store, or
    // pulled later — belongs to the settings as they stand right now (#238).
    _wisaPullFingerprint = _wisaFingerprint();
    // The same claim for the other two systems (#259). A cold seed was pulled
    // by some other session whose settings this one cannot know, so — exactly
    // as for WISA — it is credited to the document in hand, and only a save
    // made *from here on* asks for a re-pull.
    _smartschoolPullFingerprint = _settingsFingerprint(core.Origin.smartschool);
    _azurePullFingerprint = _settingsFingerprint(core.Origin.azure);
    // …and for the settings only the link consumes (#264), whose "pull" is the
    // relink itself. Nothing is linked yet at this point, so this merely means
    // a save made from here on is what arms it.
    _linkFingerprint = _currentLinkFingerprint();
    // The endpoints and credential refs the connectors in hand were built from
    // (#246). Unlike everything else, a later change to these cannot be adopted
    // — see [relaunchRequiredReason].
    final live = liveSettings;
    _bootstrapConnection =
        live == null ? null : connectionFingerprint(live.current);
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

  /// The profiles bootstrap was assembled with — the fallback for a session
  /// that models no live settings document at all.
  final List<WisaSchoolProfile> _bootstrapSchoolProfiles;

  /// The [connectionFingerprint] of the document the connectors were built
  /// from, or null when no [liveSettings] is wired (which leaves
  /// [relaunchRequiredReason] permanently silent).
  late final String? _bootstrapConnection;

  /// The operator-curated WISA schools from the settings document
  /// (AppSettings.wisaSchools), each carrying the school's short code and long
  /// name. They are what [_schoolLabels] names a school with, so the Actions
  /// drill-down identifies schools exactly as the Settings grid does even in a
  /// session that has not pulled WISA yet (#204). Empty until an operator has
  /// filled the WISA-scholen grid in, which is when the label falls back to the
  /// snapshot and finally to `School <id>`.
  ///
  /// Read from [liveSettings] when one is wired (#246), so renaming a school —
  /// or adding one — in Instellingen re-labels the drill-down on the next
  /// materialize instead of on the next launch.
  List<WisaSchoolProfile> get schoolProfiles =>
      liveSettings?.current.wisaSchools ?? _bootstrapSchoolProfiles;

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
  /// (werkdatum, virtuele werkdatum, virtual-school marks, and since #263 the
  /// persisted import rules) have moved since the snapshot this session holds
  /// was pulled. A drift pass never re-reads WISA —
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

  /// The [smartschoolPullFingerprint] / [azurePullFingerprint] of the settings
  /// the snapshot this session holds for that system was pulled with (#259).
  /// Re-stamped on every pull of that system; compared against the live
  /// document to arm [systemsAwaitingSettings].
  late String _smartschoolPullFingerprint;
  late String _azurePullFingerprint;

  /// The [linkFingerprint] of the settings the linked view in hand was built
  /// with (#264). Re-stamped on every [_relink]; compared against the live
  /// document to arm [linkAwaitingSettings], which is what makes the
  /// unchanged-WISA shortcut fall through to a re-link.
  late String _linkFingerprint;

  ReconcilePhase _phase = ReconcilePhase.idle;
  double _progress = 0.0;
  ApplyStep? _applyStep;
  LinkedState? _linked;

  /// The shared WISA stamp the linked view in hand was **adopted** from (#287),
  /// or `null` when the view is this session's own — built by its [sync] or
  /// [checkDrift] — or when there is no view at all.
  ///
  /// What lets the screens say *whose* pull this session is acting on, in place
  /// of the "deze sessie heeft nog niet gesynchroniseerd" they used to show a
  /// session that had every snapshot it needed sitting in memory.
  SystemSyncMeta? _adoptedFrom;

  /// Why [adoptStoredState] refused to build a view from the cold seed, or
  /// `null` when it has not refused (#287). Sticky until a link succeeds: a
  /// session that stays read-only owes the operator the reason for as long as
  /// it stays that way.
  String? _seedRefusedReason;

  /// Whether adoption has already been tried this session. Each screen opens
  /// with [openSession], and a `link()` over the whole roster is not something
  /// to pay for three times — nor can the answer change without a pass that
  /// links anyway.
  bool _adoptAttempted = false;

  bool _noChangesNeeded = false;
  String? _error;
  List<ActionOutcomeEntry>? _dryRunResults;
  List<ActionOutcomeEntry>? _applyResults;

  SyncState _syncState = SyncState.initial;
  List<Rollup> _rollups = const [];
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

  /// Memoized [linkedAccounts] (#295), keyed on the identity of the linked view
  /// exactly as [_pendingEntriesCache] is. The operator's alternative picks do
  /// **not** enter into it: a document says where an account lives and which
  /// systems hold it, never which resolution was chosen for it.
  List<MaterializedAccount>? _accountDocsCache;
  LinkedState? _accountDocsKey;

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
  /// begins and driven to `1.0` when it ends (#303); meaningless (and unread)
  /// while not [busy].
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

  /// Whose shared sync the view in hand was built from, when this session
  /// **adopted** it rather than pulling for itself (#287); `null` for a view
  /// this session's own [sync] / [checkDrift] produced, and for no view at all.
  ///
  /// The screens read it to say when the state they are offering was pulled and
  /// by whom, instead of demanding a sync the shared store already paid for.
  SystemSyncMeta? get adoptedFrom => _adoptedFrom;

  /// Why this session could not adopt the shared state and stays read-only, or
  /// `null` when it did adopt (or has not tried) — the one blocking notice a
  /// refused session owes the operator (#287).
  String? get seedRefusedReason => _seedRefusedReason;

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

  /// What the last dry-run or apply pass did **for [entry] itself** (#272), in
  /// the order the writes ran — the entry's own verdict.
  ///
  /// The page-level results section reports a whole pass, appended below the
  /// entire list; an operator who applied one class halfway down the
  /// Klasgroepen inventory never sees it, so a write Graph refused reads as a
  /// write that was never attempted. That is the whole of #272: both selected
  /// options *were* dispatched — the Office 365 create came back failed, and
  /// the only two places that said so were a section off the bottom of the page
  /// and a log panel on another screen.
  ///
  /// Rows are matched on the entry identity stamped at apply time
  /// ([ActionOutcomeEntry.family] + [ActionOutcomeEntry.targetId]), never on
  /// the display label: a class and an account can read the same, and the label
  /// of a record can change under a write. Chained follow-ups (#230/#240/#245)
  /// carry the identity of the option that unlocked them, so the roster write a
  /// class-group create pulled in is reported on the same card.
  ///
  /// Empty when the entry took no part in the last pass — including after a
  /// sync, which clears both result lists.
  ///
  /// The whole of it, in dispatch order. The card splits it further:
  /// [applyOutcomesForChoice] gives the part that answers one decision, and
  /// [unroutedApplyOutcomesFor] the part no decision on the card can claim
  /// (#283).
  List<ActionOutcomeEntry> applyOutcomesFor(PendingAccountEntry entry) {
    final results = _applyResults ?? _dryRunResults;
    if (results == null) return const <ActionOutcomeEntry>[];
    return <ActionOutcomeEntry>[
      for (final r in results)
        if (r.identifiesEntry &&
            r.family == entry.family &&
            r.targetId == entry.targetId)
          r,
    ];
  }

  /// The part of [entry]'s verdict that answers [choice] — the rows stamped
  /// with that decision's [PendingChoice.situationId] (#283).
  ///
  /// A card can raise several independent decisions, so a verdict pooled at
  /// card level says *what happened* without saying *to which question*. These
  /// are the rows the decision's own block shows.
  ///
  /// Empty when [choice]'s situation does not name exactly one decision on this
  /// card. An entry groups every action on one target, and two targets that
  /// share a display label share an entry, so a kind is not guaranteed unique
  /// within a card (the same reason #281 keys the blocks by position). A row
  /// that two blocks could equally claim is shown in neither — it falls to
  /// [unroutedApplyOutcomesFor], which is where it was already being read
  /// before #283.
  List<ActionOutcomeEntry> applyOutcomesForChoice(
    PendingAccountEntry entry,
    PendingChoice choice,
  ) {
    if (!_routableSituations(entry).contains(choice.situationId)) {
      return const <ActionOutcomeEntry>[];
    }
    return <ActionOutcomeEntry>[
      for (final r in applyOutcomesFor(entry))
        if (r.situationId == choice.situationId) r,
    ];
  }

  /// The part of [entry]'s verdict that no decision on the card can claim
  /// (#283) — reported at card level, exactly where the whole verdict was
  /// reported before.
  ///
  /// This is not a leftovers bin: it is the normal home of every verdict that
  /// **succeeded**. A write that lands settles its decision, so the next relink
  /// does not raise it again and the block it would have sat in no longer
  /// exists. Dropping those rows would lose exactly what #272 exists to show —
  /// the reported run has the Smartschool half landing and the Office 365 half
  /// refused, and both have to stay readable side by side.
  ///
  /// Also catches a row from a decision that is no longer offered for any other
  /// reason (the record changed under the write, so the dispatcher now proposes
  /// a different kind), one whose situation is ambiguous within the card, and
  /// one recorded before #283 stamped the situation at all.
  ///
  /// Together with [applyOutcomesForChoice] over every choice this partitions
  /// [applyOutcomesFor] exactly: no row is shown twice, and none goes missing.
  List<ActionOutcomeEntry> unroutedApplyOutcomesFor(PendingAccountEntry entry) {
    final routable = _routableSituations(entry);
    return <ActionOutcomeEntry>[
      for (final r in applyOutcomesFor(entry))
        if (!routable.contains(r.situationId)) r,
    ];
  }

  /// The situations that name **exactly one** decision on [entry] — the only
  /// ones a verdict row can be routed by (#283).
  static Set<String> _routableSituations(PendingAccountEntry entry) {
    final counts = <String, int>{};
    for (final c in entry.choices) {
      counts[c.situationId] = (counts[c.situationId] ?? 0) + 1;
    }
    return <String>{
      for (final e in counts.entries)
        if (e.value == 1) e.key,
    };
  }

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

  /// The pending entries grouped into "same situation" cohorts (#110/#292), in
  /// first-seen order. Each cohort is **one** decision and every account that
  /// raises it, so it can be bulk-applied ("unregister every departed student")
  /// while each account keeps its own chosen alternative.
  List<SituationCohort> get pendingSituations =>
      situationCohorts(pendingEntries);

  /// Groups the decisions of [entries] into cohorts in first-seen order — the
  /// shared grouping the global list and the per-classroom / per-group
  /// drill-downs all use (#110/#154/#292).
  ///
  /// Public and static because a screen must be able to group the list it is
  /// *showing* rather than read a cohort off the controller and hope the two
  /// agree: the Personeel search narrows the classroom list, the Klasgroepen
  /// search narrows the inventory, and #252 is precisely what happens when a
  /// bulk button's cohort is resolved anywhere other than the rows on screen.
  ///
  /// One entry contributes one member per decision it carries, so an account
  /// with three decisions is in three cohorts. Non-applyable decisions stay in:
  /// they are part of the situation, they are counted in the header's "n
  /// accounts", and [SituationCohort.applyableCount] — not the length — is what
  /// the apply button quotes and is gated on.
  static List<SituationCohort> situationCohorts(
    List<PendingAccountEntry> entries,
  ) {
    final order = <String>[];
    final byKey = <String, List<PendingDecision>>{};
    for (final e in entries) {
      for (final c in e.choices) {
        final key = '${e.family}|${c.situationId}';
        if (!byKey.containsKey(key)) order.add(key);
        (byKey[key] ??= <PendingDecision>[])
            .add(PendingDecision(entry: e, choice: c));
      }
    }
    return [
      for (final key in order)
        SituationCohort(key: key, decisions: byKey[key]!),
    ];
  }

  /// Every decision of [entries], in dispatch order — the whole-card reading of
  /// the same list a cohort holds one decision of (#292).
  ///
  /// What the "do everything on this account" affordances run through, so the
  /// per-card apply and the per-decision apply share one pass rather than two
  /// that can drift apart.
  static List<PendingDecision> decisionsOf(
    Iterable<PendingAccountEntry> entries,
  ) =>
      <PendingDecision>[
        for (final e in entries)
          for (final c in e.choices) PendingDecision(entry: e, choice: c),
      ];

  /// Every account and staff member of the linked view as a document, derived
  /// school-wide from the view in hand (#295) — the inventory the flat Acties
  /// list renders its rows from, joined to [pendingEntries] by id.
  ///
  /// Derived rather than read: the store's own per-account documents are made by
  /// exactly this [materialize] call, but [LinkedStore] only offers them one
  /// classroom partition at a time — which is what the jaar → klas drill-down
  /// was shaped around. Since #287 every session holds the linked view itself,
  /// so the whole roster is already in memory and the school-wide list needs no
  /// read at all. Deriving it here also keeps Acties, Klasgroepen and the
  /// Synchronisatie overview reading one set of facts rather than three.
  ///
  /// Memoized on the identity of the linked view, for the reason
  /// [pendingEntries] is: the screen reads it several times per frame, and a
  /// September roster is ~9.6k accounts. A failed derivation answers empty and
  /// says so once — the list is then simply not offered, which is honest.
  List<MaterializedAccount> get linkedAccounts {
    final linked = _linked;
    if (linked == null) return const [];
    if (identical(_accountDocsKey, linked) && _accountDocsCache != null) {
      return _accountDocsCache!;
    }
    List<MaterializedAccount> docs;
    try {
      docs = materialize(
        linked,
        generation: _syncState.generation,
        schoolLabels: _schoolLabels(),
      ).accounts;
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Kon de accountlijst niet opbouwen: $e');
      docs = const <MaterializedAccount>[];
    }
    _accountDocsKey = linked;
    _accountDocsCache = docs;
    return docs;
  }

  /// The live group ("Klasgroepen") pending entries (#154): the interactive
  /// tiles the group drill-down builds. Empty in a passive session.
  List<PendingAccountEntry> get groupPendingEntries {
    if (_linked == null) return const [];
    return [
      for (final e in pendingEntries)
        if (e.family == 'group') e,
    ];
  }

  /// [groupPendingEntries] grouped into same-situation cohorts (#154).
  List<SituationCohort> get groupPendingSituations =>
      situationCohorts(groupPendingEntries);

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
                  targetId: id,
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
  ///
  /// The partition itself is `account_actions`' [actions.collapseAlternatives]
  /// (#251) — the one definition of "these actions are one either/or", shared
  /// with the materializer so the badges and this list cannot disagree about
  /// what a decision is. Only the operator's session-local pick is layered on
  /// here; a passive session has no picks to apply.
  List<PendingChoice> _choicesFor(
    String targetId,
    List<PendingActionOption> options,
  ) =>
      [
        for (final choice in actions.collapseAlternatives<PendingActionOption>(
          options,
          groupOf: (o) => o.group,
          isDefault: (o) => o.isDefault,
        ))
          PendingChoice(
            alternatives: choice.options,
            selected: _chosen(targetId, choice),
          ),
      ];

  /// The option the operator picked for [choice] on [targetId] (#110), or the
  /// group's pre-selected default when they have not picked one — or picked a
  /// kind this pass no longer offers.
  PendingActionOption _chosen(
    String targetId,
    actions.Alternatives<PendingActionOption> choice,
  ) {
    final group = choice.options.first.group;
    if (group == null) return choice.selected;
    final kind = _choices['$targetId|$group'];
    if (kind == null) return choice.selected;
    return choice.options.firstWhere(
      (a) => a.kind == kind,
      orElse: () => choice.selected,
    );
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

  /// The [wisaPullFingerprint] of the live settings, or the empty sentinel when
  /// no [liveSettings] holder is wired — which makes every comparison equal and
  /// leaves [driftBlockedReason] silent for the harnesses that model no settings
  /// at all, exactly as [_settingsFingerprint] (#259) and
  /// [_currentLinkFingerprint] (#264) do.
  ///
  /// The sentinel is what makes that mode reachable at all (#274). This method
  /// is what the constructor stamps [_wisaPullFingerprint] *from*, so falling
  /// back to that field read a `late` in the middle of its own initialisation:
  /// building the controller without a holder threw a `LateInitializationError`
  /// before it could return. Both answers leave the gate permanently open —
  /// only this one lets the controller exist.
  String _wisaFingerprint() {
    final live = liveSettings;
    return live == null ? '' : wisaPullFingerprint(live.current);
  }

  /// Why **Check for drift** is unavailable right now, or `null` when it can
  /// run (#238).
  ///
  /// A drift pass deliberately re-reads only Smartschool and Azure: the WISA
  /// roster it links them against is whatever this session already holds, cold
  /// seed included. So once the operator saves a werkdatum — or a virtuele
  /// werkdatum, or a school's virtual mark, or a WISA import rule (#263) —
  /// that roster is not the one their
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
  ///
  /// Deliberately *not* gated on [systemsAwaitingSettings]: a drift pass
  /// unconditionally re-reads Smartschool and Azure, so it is one of the two
  /// passes that adopt a saved rule or prefix rather than a pass that would
  /// reconcile around it.
  bool get canCheckDrift =>
      !busy && !syncLockedByOther && driftBlockedReason == null;

  /// The pull-input fingerprint of [system] as the live document stands right
  /// now, or the empty sentinel when no [liveSettings] holder is wired — which
  /// makes every comparison equal and leaves [systemsAwaitingSettings] empty
  /// for the harnesses that model no settings at all.
  String _settingsFingerprint(core.Origin system) {
    final live = liveSettings;
    if (live == null) return '';
    return switch (system) {
      core.Origin.smartschool => smartschoolPullFingerprint(live.current),
      core.Origin.azure => azurePullFingerprint(live.current),
      _ => '',
    };
  }

  /// The systems whose *own* pull inputs have been changed in Instellingen
  /// since the snapshot this session holds for them was pulled (#259).
  ///
  /// #99's smart sync re-pulls Smartschool and Azure only when this session
  /// does not hold them yet, which is right when the question is "did somebody
  /// edit those systems behind our back" (that is [checkDrift]'s job) and wrong
  /// when the operator has just changed what the pull itself asks for. A saved
  /// `DiscardSmartschoolGroup` or a new school prefix then reached the running
  /// stack (#246) but no pass applied it, while [sync] reported "geen
  /// accountwijzigingen nodig" over the very save it had skipped.
  ///
  /// So this is the targeted equivalent of the `snapshot == null` condition:
  /// non-empty means the next [sync] re-pulls those systems, and
  /// [pendingSettingsReason] says so on screen until it has.
  Set<core.Origin> get systemsAwaitingSettings => <core.Origin>{
        if (_settingsFingerprint(core.Origin.smartschool) !=
            _smartschoolPullFingerprint)
          core.Origin.smartschool,
        if (_settingsFingerprint(core.Origin.azure) != _azurePullFingerprint)
          core.Origin.azure,
      };

  /// The [linkFingerprint] of the live document, or the empty sentinel when no
  /// [liveSettings] holder is wired — which makes every comparison equal and
  /// leaves [linkAwaitingSettings] false for the harnesses that model no
  /// settings at all.
  String _currentLinkFingerprint() {
    final live = liveSettings;
    return live == null ? '' : linkFingerprint(live.current);
  }

  /// Whether a saved setting that only the **link** consumes has moved since
  /// the linked view in hand was built (#264).
  ///
  /// The link's counterpart of [systemsAwaitingSettings], and the reason it is
  /// separate: the Azure domain every proposed UPN carries and the Smartschool
  /// class tree a new class hangs under reach no connector, so no pull
  /// fingerprint covers them. Saving one used to be adopted by **Check for
  /// drift** — which re-links unconditionally — and not by the Synchroniseer
  /// the operator reaches for, because a sync over an unchanged WISA returns
  /// before [_relink]. True means the next [sync] skips that shortcut and
  /// re-links, which costs no pull at all.
  bool get linkAwaitingSettings =>
      _currentLinkFingerprint() != _linkFingerprint;

  /// Which saved settings are waiting for a Synchroniseer to be applied, or
  /// `null` when none are (#259/#264).
  ///
  /// Nothing is refused — the next [sync] adopts them by itself, and so does a
  /// [checkDrift]. This only ends the silence between the save and that pass,
  /// the way [driftBlockedReason] and [relaunchRequiredReason] name their own
  /// situations.
  ///
  /// The link is named beside the two systems rather than as a system of its
  /// own: it is not a pull, and what waits on it is a recomputation this
  /// session can do without touching the network.
  String? get pendingSettingsReason {
    final systems = systemsAwaitingSettings;
    final names = <String>[
      if (systems.contains(core.Origin.smartschool)) 'Smartschool',
      if (systems.contains(core.Origin.azure)) 'Azure AD',
      if (linkAwaitingSettings) 'de koppeling',
    ];
    if (names.isEmpty) return null;
    return 'Instellingen voor ${_andList(names)} gewijzigd — '
        'synchroniseer om ze toe te passen.';
  }

  /// `a`, `a en b`, `a, b en c` — the Dutch enumeration [pendingSettingsReason]
  /// names what is waiting with.
  static String _andList(List<String> names) {
    if (names.length < 2) return names.join();
    return '${names.sublist(0, names.length - 1).join(', ')} en ${names.last}';
  }

  /// Why this session must be relaunched before it can honour the settings as
  /// they now stand, or `null` when it can honour all of them (#246).
  ///
  /// #246 made every *derived* settings value live — the managed-school set, the
  /// school prefix, the Azure domain, the Smartschool class tree and import
  /// rules all reach the next pass. The connection profiles cannot follow: a
  /// WISA host/port/database/login is bound into an open SQL connection, a
  /// Smartschool site into a SOAP endpoint, and either password ref into a Key
  /// Vault secret bootstrap resolved once, asynchronously, before any of this
  /// existed. Rebuilding the connectors under a running pass is not something
  /// this layer can do safely.
  ///
  /// So the session keeps talking to the endpoints it was built with, and says
  /// so. Nothing is refused — the operator may well have edited a profile they
  /// are not using this session, and stranding them behind a hard block would be
  /// worse than a plain statement of fact. That statement is the point: silently
  /// syncing the *previous* WISA server while Instellingen shows a new one is
  /// exactly the class of lie #238 set out to end.
  String? get relaunchRequiredReason {
    final live = liveSettings;
    final at = _bootstrapConnection;
    if (live == null || at == null) return null;
    return connectionFingerprint(live.current) == at
        ? null
        : 'Verbindingsinstellingen gewijzigd — deze sessie blijft de vorige '
            'gebruiken tot de app herstart wordt.';
  }

  /// Records that the WISA snapshot now in hand was pulled with [fingerprint] —
  /// the live settings as they stood when the pull *started*, so a save landing
  /// mid-pull stays pending rather than being credited to a pull that never saw
  /// it (#238).
  void _stampWisaPull(String fingerprint) => _wisaPullFingerprint = fingerprint;

  /// The same record for Smartschool / Azure (#259): [fingerprint] is read
  /// *before* the pull goes out, so a save landing mid-pull stays pending
  /// rather than being credited to a pull that never saw it.
  void _stampPull(core.Origin system, String fingerprint) {
    if (system == core.Origin.smartschool) {
      _smartschoolPullFingerprint = fingerprint;
    } else if (system == core.Origin.azure) {
      _azurePullFingerprint = fingerprint;
    }
  }

  /// The same record for the link (#264): [fingerprint] is read *before*
  /// `applier.link()` samples the settings, so a save landing mid-link stays
  /// pending. That errs towards one redundant re-link rather than towards a
  /// save no pass ever adopts, which is the failure this exists to end.
  void _stampLink(String fingerprint) => _linkFingerprint = fingerprint;

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

  /// The **student** grade-year aggregates (#210): one merged node per year
  /// across *every* managed school, then the "Niet toegewezen" bucket.
  ///
  /// The WISA school split is administrative, not operational — everyone running
  /// this software treats the managed schools as one school — so the school level
  /// carries no decision and is flattened away here. This is a **view**
  /// projection: the stored rollups keep their school → grade-year → classroom
  /// shape, which matters twice over. `school` is the Cosmos partition key of the
  /// per-account documents, so a classroom node keeps its real school and one
  /// partition can still be read on its own; and [totalPendingCount],
  /// [staffPendingCount], [studentPendingCount], [schoolRollups] and the
  /// per-category summaries all aggregate over [RollupLevel.school], so a passive
  /// session's badges keep reading from data that is still there.
  ///
  /// Since #295 Acties no longer *browses* these: the flat account list renders
  /// straight off the linked view. They stay as the counts every passive surface
  /// reads, and as the per-class tallies #301 answers "how many other classes
  /// need attention?" from.
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
  /// stored classroom rollup, so it still carries its own [Rollup.school]
  /// partition.
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
  /// classrooms of a grade-year), alphabetical — the stored parent/child shape
  /// the per-class tallies are read from.
  List<Rollup> childrenOf(String parentKey) {
    final children = [
      for (final r in _rollups)
        if (r.parentKey == parentKey) r,
    ]..sort((a, b) => a.label.compareTo(b.label));
    return children;
  }

  // There is deliberately no open-classroom state here any more (#295). The
  // Acties panel browsed jaar → klas → account because `LinkedStore` offers
  // `readRollups()` and `readClassroom()` and nothing else, so a session could
  // only hold one classroom partition at a time. Since #287 every session adopts
  // the shared linked view at startup, so the whole roster is in `_linked`, and
  // [linkedAccounts] + [pendingEntries] are both school-wide. `openClassroom`,
  // `classroomAccounts`, `classroomPendingEntries`, `classroomPendingSituations`
  // and the accordion's `expandedPath` went with the tree they existed for.
  // `LinkedStore.readClassroom` itself stays: the store is shared, and the
  // Synchronisatie overview still reads rollups.

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
  /// node, or [CategorySummary.empty] when the view holds no class at all. Its
  /// total is the whole class inventory since #227 (it used to be the number of
  /// classes with work), which is what the Klasgroepen tab lists.
  CategorySummary get groupSummary {
    final r = groupRollup;
    return r == null
        ? CategorySummary.empty
        : CategorySummary(total: r.accountCount, pending: r.pendingCount);
  }

  /// The single "Klasgroepen" rollup node (#119), or `null` when the shared view
  /// holds no class at all. Since #227 it aggregates the whole class inventory
  /// ([Rollup.accountCount] is every class), not only the ones with work.
  Rollup? get groupRollup {
    for (final r in _rollups) {
      if (r.level == RollupLevel.groups) return r;
    }
    return null;
  }

  /// The class inventory as stored documents — every linked class since #227,
  /// not only those with work. `null` until [loadGroups] has read them, and
  /// again after a sync rewrote the view (the Klasgroepen tab re-reads).
  List<MaterializedGroup>? get groupDocs => _groupDocs;

  /// Whether a class-inventory read is in flight.
  bool get loadingGroups => _loadingGroups;

  /// How many pending actions an apply pass would actually write — the
  /// **selected** applyable option of each choice (#110). A departed student
  /// counts once (the chosen resolution), not twice, and the informational group
  /// actions are excluded.
  int get applyableCount =>
      _selectedActions(decisionsOf(pendingEntries)).length;

  /// What a confirmed apply of [entries] would actually write (#234) — the
  /// systems the apply-confirmation dialog names, derived from the very options
  /// [applyEntries] / [applyEntry] would run.
  ///
  /// Pass the confirmation dialog the *same* list the pass will run over
  /// (#252): the dialog and the write agreeing is the whole point of building
  /// both from one resolution.
  ///
  /// Two halves, because they are not the same claim. [ApplyScope.systems] is
  /// what the selected actions write themselves, one entry per action.
  /// [ApplyScope.chained] is what only a follow-up would reach — an
  /// `AddStudentToAzure` writes Office 365 and then, off the same click, writes
  /// the Smartschool account its chain unlocks (#230/#240), which is a system
  /// the visible action never names. The follow-up cannot be counted, because
  /// its own `evaluate` decides at apply time whether it runs at all; it can
  /// only be named.
  ApplyScope applyScope(Iterable<PendingAccountEntry> entries) =>
      applyScopeForDecisions(decisionsOf(entries));

  /// What a confirmed apply of [decisions] would write — [applyScope] narrowed
  /// to the decision, which is what a cohort's confirmation dialog needs (#292).
  ///
  /// Summing every decision of every card in the cohort over-claims, and
  /// visibly: "apply the class change to these 14 students" would quote the
  /// email fixes and Office 365 renames that happen to share their cards, and
  /// then not write them. The dialog names one decision because the pass runs
  /// one decision.
  ApplyScope applyScopeForDecisions(Iterable<PendingDecision> decisions) {
    final selected = _selectedActions(decisions);
    if (selected.isEmpty) return ApplyScope.empty;
    final systems = <core.Origin>[for (final o in selected) o.changes.system];
    final chained = <core.Origin>{
      for (final o in selected) ...o.unlockedSystems,
    }..removeAll(systems);
    return ApplyScope(systems: systems, chained: chained);
  }

  /// The live actions to run for [decisions]: each one's selected option, in
  /// order, skipping the ones no apply pass would write.
  List<PendingActionOption> _selectedActions(
    Iterable<PendingDecision> decisions,
  ) =>
      [
        for (final d in decisions)
          if (d.canApply) d.choice.selected,
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
      // Which held system's own pull inputs moved since it was pulled (#259),
      // sampled before anything goes out for the same reason [pulledWith] is:
      // a save landing mid-pass belongs to the next one. Read here rather than
      // after the WISA pull so the school-profile back-fill below — which
      // publishes a repaired document of its own (#207) — can never be mistaken
      // for the operator changing something.
      final stale = systemsAwaitingSettings;
      // …and whether a setting only the link consumes moved (#264), sampled at
      // the same instant and for the same reason.
      final linkStale = linkAwaitingSettings;
      log.addMessage(core.Origin.wisa, 'WISA ophalen…');
      final fresh = await app.sync(core.Origin.wisa) as wapi.WisaSnapshot;
      _stampWisaPull(pulledWith);
      _recordPull(core.Origin.wisa, fresh);
      _setProgress(0.25);
      log.addMessage(
        core.Origin.wisa,
        'WISA opgehaald: ${fresh.students.length} leerling(en), '
        '${fresh.staff.length} personeelsleden, '
        '${fresh.classGroups.length} klassen.',
      );
      // Repair the operator's stored school profiles from this pull (#207).
      // Runs before the unchanged-since-last-sync shortcut below, so a session
      // that has nothing to reconcile still heals a settings document whose
      // schools have no names.
      await _backfillSchoolProfiles(fresh.schools);

      // "Nothing to do" is only honest while every input is the one the view in
      // hand was built from. A saved import rule or school prefix (#259) is a
      // change this pass has to apply, so it falls through to the re-pull below
      // instead of reporting "geen accountwijzigingen nodig" over it — and so
      // is a saved Azure domain or Smartschool class tree (#264), which no pull
      // asks about but every link does. That one falls through to [_relink]
      // alone: it needs no network, and skipping it left the save adopted only
      // by **Check for drift**, the very asymmetry #259 set out to remove.
      if (previous != null &&
          _linked != null &&
          stale.isEmpty &&
          !linkStale &&
          wisaSnapshotUnchanged(previous, fresh)) {
        _noChangesNeeded = true;
        // This pass pulled WISA and found the roster the view was built from
        // still current, so the view stops being somebody else's to attribute
        // even though no re-link was needed (#287). Without this an adopted
        // session would keep the shared-state notice up after taking the very
        // sync it offered — the one path out of adoption that never reaches
        // [_relink].
        _adoptedFrom = null;
        log.addMessage(
          core.Origin.wisa,
          'WISA is ongewijzigd sinds de vorige synchronisatie — '
          'geen accountwijzigingen nodig.',
        );
        await _persistSystemMeta();
        // The short path is a finished pass too, so its bar completes as well
        // (#303) — it used to stop at the 0.25 the WISA pull left it on.
        _setProgress(1.0);
        _logSyncComplete();
        _finish(ReconcilePhase.ready);
        return;
      }

      // First pass of the session: the linked view needs all three systems.
      // And since #259, so does a pass whose own settings inputs moved — the
      // targeted equivalent of that condition, keyed on the per-system
      // fingerprint rather than on "do we hold anything at all".
      final ssStale = stale.contains(core.Origin.smartschool);
      if (app.smartschool.snapshot == null || ssStale) {
        await _renewLock();
        if (ssStale) {
          log.addMessage(
            core.Origin.smartschool,
            'Smartschool-instellingen gewijzigd — Smartschool wordt opnieuw '
            'opgehaald.',
          );
        }
        log.addMessage(core.Origin.smartschool, 'Smartschool ophalen…');
        final ssPulledWith = _settingsFingerprint(core.Origin.smartschool);
        _recordPull(
            core.Origin.smartschool, await app.sync(core.Origin.smartschool));
        _stampPull(core.Origin.smartschool, ssPulledWith);
      }
      _setProgress(0.45);
      final azStale = stale.contains(core.Origin.azure);
      if (app.azure.snapshot == null || azStale) {
        await _renewLock();
        if (azStale) {
          // Worth naming: a moved prefix also drops the delta token (#246), so
          // this one is a full tenant read rather than an incremental pass.
          log.addMessage(
            core.Origin.azure,
            'Azure-instellingen gewijzigd — Azure AD wordt opnieuw opgehaald.',
          );
        }
        log.addMessage(core.Origin.azure, 'Azure AD ophalen…');
        final azPulledWith = _settingsFingerprint(core.Origin.azure);
        _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));
        _stampPull(core.Origin.azure, azPulledWith);
      }
      _setProgress(0.65);

      if (linkStale) {
        // The pass says why it is re-linking, in the panel the operator reads —
        // the counterpart of the two re-pull lines above, and the only visible
        // sign that a save with no pull behind it was applied (#264).
        log.addMessage(
          core.Origin.all,
          'Koppelingsinstellingen gewijzigd — de koppeling wordt opnieuw '
          'berekend.',
        );
      }
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
  /// successful [sync] (#162) or [checkDrift] (#303). The [noChangesNeeded]
  /// path says so explicitly; otherwise it names how many pending actions await
  /// the operator.
  ///
  /// [pass] is the name the line opens with, because a drift check is not a
  /// sync and saying so is the whole point of a terminal line: until #303 the
  /// drift pass logged none at all, so it ended on [_link]'s "Gekoppeld: …" and
  /// the operator could not tell from the Log panel whether it had finished or
  /// was still running.
  void _logSyncComplete({String pass = 'Sync'}) {
    // Name the operator who ran the pass when known (#169); an empty/unknown
    // operator degrades gracefully (nothing appended, no dangling "by ").
    final by = syncedBy.isEmpty ? '' : ' Operator: $syncedBy.';
    final message = _noChangesNeeded
        ? '$pass voltooid — geen accountwijzigingen nodig. Klaar.$by'
        : '$pass voltooid — ${pendingActions.length} openstaande actie(s). '
            'Klaar.$by';
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
  ///
  /// Ends exactly the way a [sync] does (#303): a terminal
  /// "Driftcontrole voltooid — … Klaar." line, and a progress bar driven to the
  /// end by [_relink]. Only the school-profile repair (#207) stays a
  /// sync-and-only-sync affair, and deliberately: [_backfillSchoolProfiles]
  /// writes WISA's school names and codes back over the stored ones, so the
  /// authority to run it comes from the **pull**, not from the pass. A drift
  /// check normally re-reads only Smartschool and Azure, and repairing the
  /// settings document from a WISA snapshot pulled hours ago by somebody else
  /// could undo a rename a fresher sync already recorded. The one branch below
  /// that *does* pull WISA has exactly the authority a sync has, and repairs
  /// with it.
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
        'Smartschool controleren op drift…',
      );
      // A drift pass re-reads both systems unconditionally, so it adopts a
      // saved import rule or school prefix as surely as a sync does — and must
      // stamp that, or the next Synchroniseer would re-pull for a change this
      // pass already applied (#259).
      final ssPulledWith = _settingsFingerprint(core.Origin.smartschool);
      _recordPull(
          core.Origin.smartschool, await app.sync(core.Origin.smartschool));
      _stampPull(core.Origin.smartschool, ssPulledWith);
      _setProgress(0.35);
      await _renewLock();
      log.addMessage(core.Origin.azure, 'Azure AD controleren op drift…');
      final azPulledWith = _settingsFingerprint(core.Origin.azure);
      _recordPull(core.Origin.azure, await app.sync(core.Origin.azure));
      _stampPull(core.Origin.azure, azPulledWith);
      _setProgress(0.6);

      if (app.wisa.snapshot == null) {
        await _renewLock();
        final pulledWith = _wisaFingerprint();
        log.addMessage(core.Origin.wisa, 'WISA ophalen…');
        final fresh = await app.sync(core.Origin.wisa) as wapi.WisaSnapshot;
        _recordPull(core.Origin.wisa, fresh);
        _stampWisaPull(pulledWith);
        // This branch really did pull WISA, so it may repair the stored school
        // profiles on the strength of it, exactly as [sync] does (#303/#207).
        await _backfillSchoolProfiles(fresh.schools);
      }

      await _relink();
      _logSyncComplete(pass: 'Driftcontrole');
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
      // The phase stays [ReconcilePhase.idle]: reading the shared store is not
      // a pass. Claiming `ready` here said "the last pass finished and [linked]
      // is current" over a session that has pulled nothing and linked nothing —
      // and since the read resolves on the microtask queue, it landed before
      // the operator's first frame, which is what kept the screen's only
      // explanation of Synchroniseer / Controleer op drift off the screen
      // entirely (#275).
      notifyListeners();
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Kon het overzicht niet laden: $e');
    }
  }

  /// A screen's opening read (#287): the shared overview, and then — when the
  /// cold seed allows it — the linked view built from that same shared state.
  ///
  /// The two halves are kept apart on purpose. [loadOverview] is the passive
  /// read it has always been (#115) and stays callable on its own;
  /// [adoptStoredState] is the step that makes the session *usable* without a
  /// pull. Every screen opens with this one call, and the adoption inside it
  /// runs at most once however many screens the operator visits.
  Future<void> openSession() async {
    await loadOverview();
    await adoptStoredState();
  }

  /// Builds this session's linked view from the snapshots bootstrap seeded from
  /// the cold store, so an operator who opens the app five minutes after a
  /// colleague synced can choose, dry-run and apply straight away (#287).
  ///
  /// Pulls nothing, and — the crux — persists nothing. [_persist] rewrites the
  /// whole ~9.6k-document materialized view, bumps the generation and broadcasts
  /// `viewChanged`; a startup link that persisted would have every launching
  /// client rewrite the shared view for no reason at all. This runs the link
  /// half of [_relink] alone, leaving the store exactly as it found it.
  ///
  /// The phase stays [ReconcilePhase.idle] for the same reason a passive read
  /// does (#275): adopting is not a pass, and the Synchronisatie screen's
  /// explainer must still be the first thing the operator reads.
  ///
  /// Refuses — leaving the session read-only with [seedRefusedReason] on screen
  /// — when there is nothing honest to adopt: see [_seedRefusal]. Tried once per
  /// session; the answer cannot change without a pass that links for itself.
  ///
  /// An apply on an adopted view is deliberately held to **exactly** the bar an
  /// apply on a freshly-synced one is: no lease, no targeted re-pull first. The
  /// difference between the two is one of degree, not of kind — a session that
  /// did sync is also writing against snapshots that are minutes old, and every
  /// action re-checks the record it is about to write through its own
  /// `evaluate`. Raising the bar here and not there would buy nothing and would
  /// re-introduce the per-session pull this exists to remove.
  Future<void> adoptStoredState() async {
    if (busy || _linked != null || _adoptAttempted) return;
    _adoptAttempted = true;

    final refusal = _seedRefusal();
    if (refusal != null) {
      // Reported on screen, not in the Log panel: nothing ran, and a session
      // that has done nothing yet should still open on an empty log.
      _seedRefusedReason = refusal;
      notifyListeners();
      return;
    }

    final from = _syncState.systems[core.Origin.wisa];
    try {
      await _link();
      _adoptedFrom = from;
      final by =
          from == null || from.syncedBy.isEmpty ? '' : ' door ${from.syncedBy}';
      final when = from == null ? '' : ' van ${formatFreshnessStamp(from.at)}';
      log.addMessage(
        core.Origin.all,
        'Gedeelde staat$when$by overgenomen — geen ophaalactie nodig. '
        'Synchroniseer wanneer je iets recenters wil.',
      );
      notifyListeners();
    } on Object catch (e) {
      // A failed adoption must leave the session exactly as read-only as it was
      // — never half-linked — and must not read as a failed *pass*: nothing was
      // pulled and nothing was written, so [error] (which the screens render as
      // "de laatste sync is mislukt") stays untouched.
      _linked = null;
      _seedRefusedReason =
          'Kon de gedeelde staat niet overnemen — synchroniseer om verder te '
          'gaan.';
      log.addError(core.Origin.all, 'Kon de gedeelde staat niet overnemen: $e');
      notifyListeners();
    }
  }

  /// Why the cold seed cannot honestly be adopted, or `null` when it can (#287).
  ///
  /// One reason, not a list: a refused session shows a single blocking notice,
  /// and the first thing standing in the way is the thing the operator has to
  /// deal with. In order of how fundamental they are:
  ///
  /// * a system with no seeded snapshot — there is simply no view to build;
  /// * no shared WISA stamp at all — nobody has ever synced, so there is no
  ///   colleague's pull to inherit;
  /// * a saved setting that has moved since this session was constructed
  ///   ([pendingSettingsReason] / [driftBlockedReason]) — adopting would act on
  ///   a view built without it, which is the whole of what #238/#259/#264 refuse
  ///   elsewhere;
  /// * a werkdatum mismatch — the stored roster is *as of* a date today's
  ///   settings no longer resolve to, so it may describe another school year.
  ///
  /// A stamp carrying **no** werkdatum is not a mismatch and does not refuse:
  /// the field is null on a WISA pull from before #247 recorded it, and treating
  /// an absence as a contradiction would strand every install whose shared view
  /// predates that on a sync it does not need.
  String? _seedRefusal() {
    final missing = <String>[
      if (app.wisa.snapshot == null) 'WISA',
      if (app.smartschool.snapshot == null) 'Smartschool',
      if (app.azure.snapshot == null) 'Azure AD',
    ];
    if (missing.isNotEmpty) {
      return 'Geen opgeslagen momentopname voor ${_andList(missing)} — '
          'synchroniseer om te beginnen.';
    }
    if (_syncState.systems[core.Origin.wisa] == null) {
      return 'Er is nog geen gedeelde synchronisatie om over te nemen — '
          'synchroniseer om te beginnen.';
    }
    final settings = pendingSettingsReason;
    if (settings != null) return settings;
    final drift = driftBlockedReason;
    if (drift != null) return drift;
    return _staleWorkDateReason();
  }

  /// Why the shared roster's **werkdatum** disqualifies it for this session, or
  /// `null` when it is the one today's settings resolve to (#287/#247).
  ///
  /// WISA returns enrolments *as of* a work date, so a roster pulled on the
  /// other side of the school-year rollover simply has none of the new intake in
  /// it — which on the Acties screen reads exactly like a class that went
  /// missing. That is the one freshness question this session cannot leave to
  /// the operator's judgement, so it is the one it asks.
  ///
  /// Silent when no [liveSettings] holder is wired, exactly as every other gate
  /// in this class is: there is then no document to resolve today's werkdatum
  /// from, and inventing one would refuse every harness that models no settings.
  String? _staleWorkDateReason() {
    final live = liveSettings;
    if (live == null) return null;
    final stored = _syncState.systems[core.Origin.wisa]?.workDate;
    if (stored == null) return null;
    final today = live.current.wisa.workDate.resolve(_now());
    if (_sameWorkDay(stored, today)) return null;
    return 'De gedeelde momentopname is van werkdatum '
        '${wapi.formatWerkdatum(stored)}; vandaag geldt '
        '${wapi.formatWerkdatum(today)} — synchroniseer eerst.';
  }

  /// Whether two werkdatums name the same day on the operator's own calendar.
  /// Compared as local calendar days, not as instants: the stored stamp is an
  /// ISO timestamp and the resolved one is "now", so they are never equal to the
  /// second even when they mean the same day.
  static bool _sameWorkDay(DateTime a, DateTime b) {
    final x = a.toLocal();
    final y = b.toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  /// Reacts to another operator's sync bumping the stored generation past this
  /// session's cached copy (#108): refetch the shared overview and re-read any
  /// open classroom so a passive session catches up — no pull, no `link()`. The
  /// realtime transport (#116) drives this from a SignalR change notification;
  /// until then it is exercised directly. A stale-or-equal [generation] is a
  /// no-op, so a duplicate notification does no work.
  ///
  /// [shard], when the signal named one (#254), says which part of the view
  /// moved, so a drill-down the change provably cannot have touched is left
  /// alone instead of re-read. A missing shard means "assume the whole view".
  Future<void> onStoreChanged(int generation, {ShardRef? shard}) async {
    if (busy || generation <= _syncState.generation) return;
    await _refetchFromStore(shard: shard);
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
      log.addError(
          core.Origin.all, 'Kon niet bijwerken na het herverbinden: $e');
    }
  }

  /// Re-reads the shared overview (sync state, rollups, lease) and the class
  /// inventory from the store — the refetch [onStoreChanged] and
  /// [resyncFromStore] share (no pull, no `link()`).
  ///
  /// The overview itself is always re-read: the rollups are the counts the nudge
  /// was about, and they are small. The Klasgroepen inventory is what [shard]
  /// narrows (#254) — an apply elsewhere in the school has nothing to say about
  /// it, so the read is skipped rather than paid for. A null shard (a sync's
  /// whole-view rewrite, or a reconnect that cannot know what it missed) re-reads
  /// everything, exactly as before.
  ///
  /// The Acties list is **not** re-read here and has nothing to re-read (#295):
  /// it renders off this session's linked view rather than off classroom
  /// partitions, so the shared store moving under it changes the counts above it
  /// and not the rows.
  Future<void> _refetchFromStore({ShardRef? shard}) async {
    _syncState = await store.readSyncState();
    _rollups = await store.readRollups();
    _decisions = await store.readDecisions();
    await _refreshLock();
    if (_groupDocs != null &&
        (shard == null || shard.touchesPartition(groupsPartition))) {
      try {
        _groupDocs = await store.readGroups();
      } on Object catch (e) {
        log.addError(core.Origin.all, 'Kon de klasgroepen niet vernieuwen: $e');
      }
    }
    notifyListeners();
  }

  /// Reads the **class inventory** — every stored class document — from the
  /// store (no pull, no `link()`). One partition read; there are a few hundred
  /// classes at most.
  ///
  /// Since #227 Klasgroepen is a top-level tab that lists every class rather
  /// than a node listing the ones with work, so the read is "load the inventory"
  /// and there is nothing to close. A second call while a read is in flight is a
  /// no-op; a sync drops [groupDocs] so the tab re-reads the generation it just
  /// wrote.
  Future<void> loadGroups() async {
    if (_loadingGroups) return;
    _loadingGroups = true;
    notifyListeners();
    try {
      _groupDocs = await store.readGroups();
    } on Object catch (e) {
      log.addError(core.Origin.all, 'Kon de klasgroepen niet openen: $e');
      _groupDocs = const [];
    } finally {
      _loadingGroups = false;
      notifyListeners();
    }
  }

  // There is deliberately no `applyAll` / `dryRun` over the whole linked view
  // (#294). Every pass starts from a list the operator is looking at: one card
  // ([applyEntry]), one decision across its cohort ([applyDecisions]), or a
  // scoped selection ([applyEntries]). A method that took "everything pending"
  // existed only to serve a header button that wrote every account in the
  // school on the strength of a dialog nobody could verify.

  /// Dry-runs one entry's chosen resolution (#110): the per-row preview.
  Future<void> dryRunEntry(PendingAccountEntry entry) =>
      dryRunEntries(<PendingAccountEntry>[entry]);

  /// Applies one entry's chosen resolution (#110): the per-row apply.
  Future<void> applyEntry(PendingAccountEntry entry) =>
      applyEntries(<PendingAccountEntry>[entry]);

  /// Applies **every** chosen resolution on each of [entries] (#110) — the
  /// whole-card pass. Each entry keeps its own chosen alternative, so one
  /// departed student can be unregistered while another is deleted.
  ///
  /// The per-decision counterpart is [applyDecisions] (#292); this is the "do
  /// everything on this account" reading, which stays because it is not blind —
  /// every decision it runs is on screen on the card above the button.
  ///
  /// It takes the entries themselves rather than a key to resolve back through
  /// [pendingEntries], and that is the whole of #252. The affordance this runs
  /// for is rendered over a **scoped** list — the open classroom's entries, or
  /// the group drill-down's, minus whatever the search box filters out — while
  /// re-resolving a key against [pendingEntries] means every entry in the entire
  /// linked view, across every class. A button labelled "Alles toepassen (1)"
  /// therefore wrote every account group-wide that happened to share the
  /// situation, none of which the operator had seen. Passing the very list the
  /// header counted makes that mismatch structurally impossible: label,
  /// confirmation scope ([applyScope]) and write are one
  /// list.
  Future<void> applyEntries(Iterable<PendingAccountEntry> entries) =>
      _run(decisionsOf(entries), dry: false);

  /// Dry-runs [entries]' chosen resolutions — [applyEntries] with no writes.
  Future<void> dryRunEntries(Iterable<PendingAccountEntry> entries) =>
      _run(decisionsOf(entries), dry: true);

  /// Applies **one nominated decision per account** (#292) — the bulk pass a
  /// [SituationCohort]'s "Alles toepassen" runs, and the seam a school-wide
  /// apply-all builds on.
  ///
  /// The difference from [applyEntries] is the whole of #292: given the same
  /// fourteen students, `applyEntries` writes every selected decision on each of
  /// their cards, while this writes only the decision the operator read on the
  /// header. Bulk-applying "Wijzig Klas in Smartschool" therefore stops
  /// silently writing the email fixes and Office 365 renames that happen to
  /// share those cards — a claim the operator could not have verified, because
  /// the header named one action and the pass ran whatever else was there.
  ///
  /// Each member still contributes its **own** selected alternative, exactly as
  /// the whole-card pass does: a cohort of departed students where one is set to
  /// unregister and one to delete applies each as chosen.
  Future<void> applyDecisions(Iterable<PendingDecision> decisions) =>
      _run(decisions, dry: false);

  /// Dry-runs [decisions] — [applyDecisions] with no writes.
  Future<void> dryRunDecisions(Iterable<PendingDecision> decisions) =>
      _run(decisions, dry: true);

  /// Runs the selected, applyable option of every decision in [decisions]
  /// through the apply path (dry or real). Shared by the per-entry and
  /// per-cohort affordances so both behave identically (#110). Each option
  /// is bound to its own target; on a real write the applier patches the
  /// snapshot and returns a fresh linked view we adopt as the pass proceeds.
  ///
  /// It takes [PendingDecision]s rather than the resolved options because a real
  /// pass owes the shared store a patch afterwards (#254), and the decisions are
  /// what name the targets it touched — an option carries only a display label.
  /// Since #292 that is also what lets one pass serve both readings of "apply":
  /// the whole card is simply every decision on it.
  Future<void> _run(
    Iterable<PendingDecision> decisions, {
    required bool dry,
  }) async {
    if (busy || _linked == null) return;
    final selected = _selectedActions(decisions);
    // The targets this pass writes to, captured before it starts: the decisions
    // are derived from the pre-apply linked view, which the pass replaces. One
    // patch per target however many of its decisions this pass runs — a card
    // has one stored document.
    final touched = <PendingAccountEntry>[];
    final seen = <String>{};
    for (final d in decisions) {
      if (!d.canApply) continue;
      if (seen.add('${d.entry.family}|${d.entry.targetId}')) {
        touched.add(d.entry);
      }
    }
    _begin(ReconcilePhase.applying);

    final options =
        dry ? actions.ApplyOptions.dry : const actions.ApplyOptions();
    final results = <ActionOutcomeEntry>[];
    // The WISA import rules this pass earned (#276). Collected across the whole
    // pass and written once at the end rather than per action, so blacklisting
    // thirty departed teachers is one settings write, not thirty.
    final earnedRules = <EarnedWisaRule>[];
    // "Dry-run" is the term the Acties buttons already use ("Dry-run alles"),
    // so it stays; its counterpart is the "Alles toepassen" of those same
    // buttons rather than a second word for the same thing.
    final label = dry ? 'Dry-run' : 'Toepassen';
    log.addMessage(
      core.Origin.all,
      '$label gestart voor ${selected.length} van ${pendingActions.length} '
      'openstaande actie(s).',
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
          option,
          earnedRules,
        ));
        // Advance once per action so a long apply/dry-run pass reads as busy
        // and visibly progressing rather than a motionless bar (#176).
        _setProgress((index + 1) / selected.length);
      }

      final failed =
          results.where((r) => r.outcome == actions.ActionOutcome.failed);
      log.addMessage(
        core.Origin.all,
        '$label klaar: ${results.length - failed.length} gelukt, '
        '${failed.length} mislukt.',
      );
      if (dry) {
        _dryRunResults = results;
      } else {
        _applyResults = results;
        _dryRunResults = null;
        await _persistEarnedWisaRules(earnedRules);
        await _shareApplied(_refreshRollups(), touched);
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
        // A pass that broke halfway still wrote whatever it got through, so the
        // overview owes the operator those counts too (#236) — and so do the
        // other operators (#254). The rules it earned before it broke are just
        // as real, and just as permanent (#276).
        await _persistEarnedWisaRules(earnedRules);
        await _shareApplied(_refreshRollups(), touched);
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
  ///
  /// Every WISA import rule a real write earned is appended to [earnedRules] on
  /// the way past, for the pass to persist when it ends (#276) — the follow-ups
  /// included, since a chained write is as much this click's doing as the option
  /// the operator picked.
  ///
  /// Each rule is carried with [PendingActionOption.target] as its subject
  /// (#285): the label this option is acting on *is* the name of the person or
  /// class the rule is about, and here is the only moment the app still has it —
  /// the rule itself keeps nothing but an opaque WISA code, and the staff these
  /// rules concern are the ones who later disappear from WISA entirely.
  Future<List<ActionOutcomeEntry>> _applyOne(
    Future<ApplyResult> Function() run,
    PendingActionOption option,
    List<EarnedWisaRule> earnedRules,
  ) async {
    final changes = option.changes;
    try {
      final applied = await run();
      if (applied.refreshed) _linked = applied.linked;
      final result = applied.result;
      for (final r in <actions.ActionResult>[result, ...applied.followUps]) {
        final rule = r.wisaRule;
        // A dry run projects the rule without earning it, and a failed action
        // earned nothing at all — neither may reach the shared document.
        if (rule != null && r.wrote) {
          earnedRules.add(EarnedWisaRule(rule, subject: option.target));
        }
      }
      return <ActionOutcomeEntry>[
        _record(option, changes, result),
        // A chained follow-up is a write the same click performed on the same
        // target, so it is stamped with the same entry identity and lands on
        // the same card (#272) — and, since #283, with the same *decision*,
        // because the operator started it by picking this option.
        for (final followUp in applied.followUps)
          _record(option, followUp.changes, followUp),
      ];
    } on Object catch (e) {
      // An action that throws (instead of returning failed) must not abort
      // the rest of the pass.
      log.addError(changes.system, '${option.target} — ${changes.summary}: $e');
      return <ActionOutcomeEntry>[
        ActionOutcomeEntry(
          target: option.target,
          family: option.family,
          targetId: option.targetId,
          situationId: option.situationId,
          changes: changes,
          outcome: actions.ActionOutcome.failed,
          error: e,
        ),
      ];
    }
  }

  /// Logs one action's outcome and shapes it as a results-list row, stamped
  /// with the entry [option] came from so the card can show its own verdict
  /// (#272) and with the decision it answers so that verdict sits under the
  /// question it belongs to (#283).
  ActionOutcomeEntry _record(
    PendingActionOption option,
    actions.ChangeSet changes,
    actions.ActionResult result,
  ) {
    final target = option.target;
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
      family: option.family,
      targetId: option.targetId,
      situationId: option.situationId,
      changes: changes,
      outcome: result.outcome,
      error: result.error,
    );
  }

  /// Recomputes the linked view from the snapshots in hand and reports what came
  /// out — the **link half**, which writes nothing anywhere.
  ///
  /// Split out of [_relink] for #287: a session adopting the shared cold seed
  /// needs exactly this and must not run the persist half behind it, or every
  /// client would rewrite the whole materialized view on launch.
  Future<void> _link() async {
    // Read before the link, stamped after it: `applier.link()` samples the very
    // same document, so this names exactly the settings the view about to be
    // built was linked with (#264).
    final linkedWith = _currentLinkFingerprint();
    _linked = await applier.link();
    _stampLink(linkedWith);
    // A view now exists, so whatever kept this session read-only no longer
    // does.
    _seedRefusedReason = null;
    final s = _linked!.snapshot;
    log.addMessage(
      core.Origin.all,
      'Gekoppeld: ${s.accounts.length} leerling(en), '
      '${s.staff.length} personeelsleden, ${s.groups.length} klasgroepen; '
      '${pendingActions.length} openstaande actie(s), '
      '${s.warnings.length} waarschuwing(en).',
    );
    _logSkippedNamesakes(s.warnings);
  }

  Future<void> _relink() async {
    _phase = ReconcilePhase.linking;
    _setProgress(0.75);
    notifyListeners();
    await _link();
    // This pass pulled and linked for itself, so the view is no longer somebody
    // else's to attribute (#287).
    _adoptedFrom = null;
    // A re-link invalidates the cached class inventory: those documents were
    // read for the view [_link] just replaced, and the live entries the
    // Klasgroepen rows join them against are the new one's, so the tab re-reads
    // (#227). The Acties list needs no such line since #295 — it holds no store
    // documents of its own, and [linkedAccounts] is keyed on the identity of the
    // linked view that has just been swapped out.
    //
    // Sits here, before [_persist], and not on the far side of the store write
    // it used to (#289). This is an invalidation of *this session's* derived
    // cache; whether the shared write lands has nothing to do with it, and a
    // write that timed out or threw used to skip it entirely — leaving the rows
    // joining fresh entries against the previous generation's documents. Written
    // straight to the field: the pass notifies once when it finishes.
    _groupDocs = null;
    _setProgress(0.9);
    await _persist(_linked!);
    // The pass is done: complete the bar rather than leaving it stopped at 0.9
    // for [_finish] to clear (#303). [_persist] reports its own failures and
    // never throws, so this is the end of the pass either way — the shared view
    // may not have landed, but nothing is still running.
    _setProgress(1.0);
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

  /// Re-derives the overview rollups from the refreshed linked view after a
  /// **real** apply (#236) — the badge counts, and since #226 which nodes the
  /// tree shows at all.
  ///
  /// Until this, `_rollups` was assigned by [_persist] alone, which only ever
  /// runs from [_relink]. An apply patches the snapshot and adopts the refreshed
  /// `_linked` but never re-materialized, so the two halves of the Acties screen
  /// disagreed the moment a pass finished: the drilled-in list (derived from the
  /// live view) had dropped the work, while the overview kept advertising it —
  /// and under the default filter kept a finished class in the tree — until the
  /// next Synchroniseer. [materialize] is pure and already derives exactly these
  /// aggregates from a [LinkedState], so the correction is the same computation
  /// the sync path runs, minus the store write.
  ///
  /// This is the **local** half. It writes nothing and does not bump the
  /// generation: a session must never be ahead of the store on its own say-so,
  /// or the [onStoreChanged] that should overrule it would be gated out as
  /// stale. The shared half is [_shareApplied] (#254), which hands the same
  /// derivation to [LinkedStore.writeApplied] and then adopts what the store
  /// makes of it — so if the two ever disagree, the shared view wins.
  ///
  /// Returns the view it derived, so the shared half re-uses this one
  /// computation rather than materializing the whole thing twice; `null` when
  /// there is nothing to derive from or the derivation failed.
  ///
  /// Never called from the dry-run path: a projection writes nothing, so it must
  /// leave every count exactly as it found it.
  MaterializedView? _refreshRollups() {
    final linked = _linked;
    if (linked == null) return null;
    try {
      final view = materialize(
        linked,
        generation: _syncState.generation,
        schoolLabels: _schoolLabels(),
      );
      _rollups = view.rollups;
      return view;
    } on Object catch (e) {
      // A correction that fails must not turn a successful apply into a failed
      // pass; the counts then simply stay as stale as they were before.
      log.addError(
          core.Origin.all,
          'Kon de tellingen in het overzicht niet '
          'vernieuwen: $e');
      return null;
    }
  }

  /// Writes the documents a **real** apply changed back to the shared store, so
  /// every *other* operator stops being offered work this session already
  /// applied (#254) — the half #236 deliberately left open.
  ///
  /// [view] is the refreshed derivation [_refreshRollups] just made; [touched]
  /// the entries the pass actually wrote to. Together they give the patch its
  /// exact scope: for each touched target, the document it has now — or its id
  /// alone when the refreshed link no longer produces one (the account's last
  /// system record was just deleted). Nothing else in the ~9.6k-document view is
  /// read, written or even looked at.
  ///
  /// Three things follow the write, in this order and for a reason:
  ///
  /// - the session adopts the generation it just wrote, so it is *current*
  ///   rather than ahead — a later sync bumps past it and [onStoreChanged] still
  ///   fires;
  /// - the rollups are re-read **from the store**, not kept from the local
  ///   derivation, so another operator's concurrent correction outranks this
  ///   session's picture of the same nodes rather than the other way round;
  /// - a [ChangeSignal.viewChanged] naming the changed shard goes out, so
  ///   passive sessions refetch that much and not the whole view.
  ///
  /// A write that is deferred (someone is mid-sync) or that fails leaves all
  /// three undone: the local correction from #236 still stands for this session,
  /// the shared view catches up on the next sync, and the operator is told which
  /// it was. A failure here must never turn a successful apply into a failed
  /// pass — the writes to Smartschool and Office 365 really happened.
  Future<void> _shareApplied(
    MaterializedView? view,
    List<PendingAccountEntry> touched,
  ) async {
    if (view == null || touched.isEmpty) return;
    final accounts = <String, MaterializedAccount>{
      for (final a in view.accounts) a.id.value: a,
    };
    final groups = <String, MaterializedGroup>{
      for (final g in view.groups) g.id.value: g,
    };
    final freshAccounts = <MaterializedAccount>[];
    final freshGroups = <MaterializedGroup>[];
    final removedAccountIds = <String>[];
    final removedGroupIds = <String>[];
    for (final entry in touched) {
      if (entry.family == 'group') {
        // A group entry is keyed by the display name the operator sees; the
        // stored document is keyed by the materializer's namespaced form.
        final id = materializedGroupId(entry.targetId);
        final doc = groups[id];
        if (doc == null) {
          removedGroupIds.add(id);
        } else {
          freshGroups.add(doc);
        }
      } else {
        final doc = accounts[entry.targetId];
        if (doc == null) {
          removedAccountIds.add(entry.targetId);
        } else {
          freshAccounts.add(doc);
        }
      }
    }
    // Re-attach the operator decisions the store holds for these targets, the
    // way [_persist] does for the whole view: the derivation above carries none,
    // and writing it raw would silently strip an accepted duplicate or a chosen
    // alternative off exactly the documents this pass touched. Only the
    // re-attachment is taken — `dropped` is meaningless over a subset, since
    // every decision belonging to an untouched account would be in it.
    final merged = mergeDecisions(
      accounts: freshAccounts,
      groups: freshGroups,
      existing: _decisions,
    );
    final patch = AppliedPatch(
      accounts: merged.accounts,
      groups: merged.groups,
      removedAccountIds: removedAccountIds,
      removedGroupIds: removedGroupIds,
    );
    if (patch.isEmpty) return;

    try {
      final at = _now();
      final written = await store
          .writeApplied(patch, appliedBy: syncedBy, at: at)
          .timeout(persistTimeout);
      final generation = written.generation;
      if (generation == null) {
        final holder = written.deferredTo;
        if (holder != null) {
          log.addMessage(
            core.Origin.all,
            'Het gedeelde overzicht is niet bijgewerkt: ${holder.owner} '
            'synchroniseert. De toegepaste wijzigingen komen erin zodra die '
            'synchronisatie klaar is.',
          );
        }
        return;
      }
      _syncState = SyncState(
        generation: generation,
        updatedAt: at,
        updatedBy: syncedBy,
        systems: _syncState.systems,
      );
      _rollups = await store.readRollups();
      final shard = _appliedShard(patch);
      // …and so is the class inventory this session is holding (#271). The
      // rows come from the stored documents, so an apply that **removed** one —
      // a deleted Office 365 class group — would otherwise leave its row on
      // screen, still claiming a group that no longer exists, until the next
      // sync. Same guard the other operators' [_refetchFromStore] uses, so a
      // pass that touched no class pays for no read.
      if (_groupDocs != null &&
          (shard == null || shard.touchesPartition(groupsPartition))) {
        try {
          _groupDocs = await store.readGroups();
        } on Object catch (e) {
          log.addError(
              core.Origin.all, 'Kon de klasgroepen niet vernieuwen: $e');
        }
      }
      await _publish(ChangeSignal.viewChanged(
        generation: generation,
        shard: shard,
      ));
    } on TimeoutException {
      log.addError(
        core.Origin.all,
        'Het bijwerken van het gedeelde overzicht duurde langer dan '
        '${persistTimeout.inSeconds}s — de wijzigingen zijn wel toegepast, maar '
        'andere gebruikers zien ze pas na de volgende synchronisatie.',
      );
    } on Object catch (e) {
      log.addError(
        core.Origin.all,
        'Kon het gedeelde overzicht niet bijwerken: $e',
      );
    }
  }

  /// The narrowest [ShardRef] that provably covers everything [patch] changed,
  /// or `null` for "assume the whole view" (#254).
  ///
  /// Only ever narrows on what this session can vouch for, widening a level at a
  /// time: one classroom, else one school, else the whole view. A removal's
  /// document is gone, so where it sat is no longer knowable here, and a patch
  /// touching accounts *and* class groups spans two partitions — in both the
  /// honest answer is the whole view. A shard that under-claims would have
  /// receivers skip a re-read they needed, which is far worse than one that
  /// costs them a read they did not.
  ShardRef? _appliedShard(AppliedPatch patch) {
    if (patch.removedAccountIds.isNotEmpty ||
        patch.removedGroupIds.isNotEmpty) {
      return null;
    }
    final touchedGroups = patch.groups.isNotEmpty;
    if (patch.accounts.isEmpty) {
      return touchedGroups ? const ShardRef(school: groupsPartition) : null;
    }
    if (touchedGroups) return null;
    final schools = <String>{for (final a in patch.accounts) a.school};
    if (schools.length != 1) return null;
    final classrooms = <String>{for (final a in patch.accounts) a.classroom};
    if (classrooms.length != 1) return ShardRef(school: schools.single);
    return ShardRef(
      school: schools.single,
      classroom: classrooms.single,
      accountId:
          patch.accounts.length == 1 ? patch.accounts.single.id.value : null,
    );
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
    } on TimeoutException {
      log.addError(
        core.Origin.all,
        'Het opslaan van het gedeelde overzicht duurde langer dan '
        '${persistTimeout.inSeconds}s — deze sessie kan ermee verder, maar '
        'andere gebruikers zien het pas na de volgende synchronisatie.',
      );
    } on Object catch (e) {
      log.addError(
        core.Origin.all,
        'Kon het gedeelde overzicht niet opslaan: $e',
      );
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
      final saved = stored.copyWith(wisaSchools: repaired);
      await store.save(saved);
      // Publish what we just wrote (#246). [schoolProfiles] now reads the live
      // document, and this pass has both repaired the stored profiles *and*
      // possibly picked up another operator's save in the re-read above — so
      // without this the holder would keep serving the pre-repair names for the
      // rest of the session, and the Settings view would show one thing while
      // the drill-down labelled another.
      liveSettings?.publish(saved);
      log.addMessage(
        core.Origin.wisa,
        'Naam en code van ${healed.length} WISA-school(en) bijgewerkt in de '
        'instellingen (id ${healed.join(', ')}).',
      );
    } on Object catch (e) {
      log.addError(
        core.Origin.wisa,
        'Kon de WISA-schoolnamen niet bijwerken in de instellingen: $e',
      );
    }
  }

  /// Writes the WISA import rules this apply pass earned to the shared settings
  /// document (#276), so the exclusion outlives the session that decided it.
  ///
  /// Until this, a `DontImportFromWisa` apply only grew the process-lifetime
  /// `WisaImportRules` holder, and that made the rule oscillate rather than
  /// merely evaporate: the apply drops the person from this run's snapshot,
  /// their Azure account keeps surfacing (#269) so the operator deletes it, and
  /// the next launch rebuilds the holder empty — WISA still reports the person
  /// active, no Azure account exists any more, and the linker proposes creating
  /// them. Persisting the rule is what breaks that loop, and it is the same
  /// document #263 reads at pull time and #273 edits, so the rule is visible and
  /// removable in Instellingen → Wisa with no extra UI.
  ///
  /// The document is re-read immediately before the write, exactly as
  /// [_backfillSchoolProfiles] does, so a change another operator saved during
  /// this pass is not clobbered by this session's copy; nothing is written when
  /// every earned rule is already on it.
  ///
  /// **The drift gate stays honest.** `wisaPullFingerprint` covers the persisted
  /// rules (#238), so this write would otherwise arm it — falsely, because the
  /// applier re-pulled WISA *with* these rules the moment each was earned, and
  /// the snapshot in hand already reflects them. So the pull is re-credited to
  /// the document it now matches, but only when the gate was closed to begin
  /// with and the saved document differs from the one in hand by nothing but
  /// these rules. Anything else another operator slipped in — a werkdatum, a
  /// virtual-school mark — arms the gate as it should.
  ///
  /// **Each rule is stamped with its provenance** (#285): the operator running
  /// the pass, the instant it ended, and the name of the record it was earned
  /// about. The shared document is only legible if a rule someone else added
  /// last month says who to ask about it — and a rule that collapses into one
  /// the document already carries keeps the *first* operator's stamp, because
  /// that is the decision the document has been standing on.
  ///
  /// A failing settings store must never fail the pass: the writes it performed
  /// are done and reported, so the problem is logged and the operator can
  /// re-apply (or type the rule in Instellingen) rather than lose the results.
  Future<void> _persistEarnedWisaRules(
    List<EarnedWisaRule> earned,
  ) async {
    final store = settingsStore;
    if (store == null || earned.isEmpty) return;
    final live = liveSettings;
    // One instant for the whole pass, sampled once: thirty rules earned by one
    // click are one decision and read as one.
    final addedAt = _now();
    // Sampled before the write: whether the WISA snapshot in hand is credited
    // to the document this session holds, and what that document plus these
    // rules would fingerprint as.
    final held = live?.current;
    final inSync = _wisaFingerprint() == _wisaPullFingerprint;
    try {
      final stored = await store.load();
      final merged = mergeEarnedWisaRules(
        stored: stored,
        earned: earned,
        addedBy: syncedBy,
        addedAt: addedAt,
      );
      if (merged == null) return;
      await store.save(merged.settings);
      live?.publish(merged.settings);
      if (inSync && held != null) {
        // Provenance is deliberately absent from the fingerprint — who typed a
        // rule changes nothing about what WISA returns — so this re-credit is
        // unaffected by the stamps just written.
        final credited = wisaPullFingerprint(
          mergeEarnedWisaRules(stored: held, earned: earned)?.settings ?? held,
        );
        if (credited == _wisaFingerprint()) _stampWisaPull(credited);
      }
      for (final rule in merged.added) {
        log.addMessage(
          core.Origin.wisa,
          'Importregel bewaard voor iedereen: ${describeWisaRule(rule)}. '
          'Dit blijft gelden tot de regel in Instellingen → Wisa verwijderd '
          'wordt.',
        );
      }
    } on Object catch (e) {
      log.addError(
        core.Origin.wisa,
        'Kon de WISA-importregel(s) niet opslaan in de instellingen: $e',
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
  ///
  /// A WISA pull also stamps the **werkdatum** it asked for (#247), taken off
  /// the snapshot the connector built rather than re-resolved here: with
  /// `isNow: true` the date is resolved inside the pull, so asking the live
  /// settings a second time could answer for a different day (a pass running
  /// across midnight) or for a document saved while the pull was in flight.
  /// The one place that resolved it is the only place that can say what it was.
  void _recordPull(core.Origin system, core.Snapshot snapshot) {
    _pulled[system] = SystemSyncMeta(
      syncedBy: syncedBy,
      at: snapshot.fetchedAt,
      workDate: snapshot is wapi.WisaSnapshot ? snapshot.workDate : null,
    );
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
      log.addError(
        core.Origin.all,
        'Kon de synchronisatiegegevens niet opslaan: $e',
      );
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
      log.addError(
        core.Origin.all,
        'Kon de sync-vergrendeling niet nemen: $e',
      );
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
      log.addError(
        core.Origin.all,
        'Kon de sync-vergrendeling niet verlengen: $e',
      );
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
      log.addError(
        core.Origin.all,
        'Kon de sync-vergrendeling niet vrijgeven: $e',
      );
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
        if (generation != null) {
          await onStoreChanged(generation, shard: signal.shard);
        }
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
      log.addError(
        core.Origin.all,
        'Kon geen wijzigingssignaal versturen: $e',
      );
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
