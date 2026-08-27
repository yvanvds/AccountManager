import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart'
    show MaterializedAccount, OtherEnrolment;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../search/name_query.dart';
import 'action_tiles.dart';

// The wording helpers moved to the shared tile library when Klasgroepen became
// a screen of its own (#227); re-exported so they stay importable from here.
export 'action_tiles.dart' show applyConfirmationMessage, systemLabel;

/// The Actions view (#154/#295): one flat, sortable list of accounts on the
/// left and the selected account's decisions on the right.
///
/// ## Why it is flat
///
/// It used to browse jaar → klas → account (#119/#210), for two reasons, and
/// neither survives. The first was rendering cost — a September changeover
/// produces thousands of tiles — which a lazy [ListView] answers just as well as
/// a tree does. The second was the read strategy: `LinkedStore` offers
/// `readRollups()` and `readClassroom()` and nothing else, so a session that had
/// not synced genuinely could only hold one classroom partition at a time.
/// Since #287 every session adopts the shared linked view at startup, so the
/// whole roster is in memory and `pendingEntries` / `linkedAccounts` are both
/// school-wide.
///
/// What was left was a browsing structure costing two clicks per class to answer
/// questions that are not per-class: *who is leaving?*, *who is missing from
/// Office 365?*, *who needs the class change?* Sorting and filtering answer
/// those; a tree does not.
///
/// ## The two questions #295 left open, and how they were settled
///
/// **"Sort by system" is a filter, not a sort.** A tri-state indicator has no
/// meaningful order — green before orange before red is one arbitrary ranking of
/// six, and sorting by it buries the rows the operator was looking for among the
/// ones they were not. What they actually mean is *show me everyone with
/// Smartschool work*, so that is what [_SystemFilter] does: it keeps the rows
/// whose cell for that one system is **not** green, which answers "who is
/// missing from Office 365?" and "who has Smartschool work?" with the same
/// control. Sorting is therefore by name or by class ([_ActionSort]) — the two
/// orders that really do order — and both the sort and the filter outlive a
/// selection, because they describe the list and not the row.
///
/// **The split folds at [_splitBreakpoint].** Above it the list and the details
/// sit side by side, which is the layout the screen is for. Below it there is
/// not enough width for two readable columns — the details pane carries field
/// diffs and radio labels, so squeezing it wraps every line — so the panes
/// become one: the list fills the width, selecting a row replaces it with the
/// details, and **Overzicht** comes back. Measured off the pane's own
/// constraints rather than the window's, so the navigation rail is already
/// accounted for.
///
/// ## What a row says
///
/// The display name, the class, a pending badge, and the three system
/// indicators — WISA · Smartschool · Office 365 — in the shared vocabulary of
/// #298: red missing, orange work pending, green in order. That vocabulary lives
/// in `system_indicator.dart` and is the same one Klasgroepen's rows speak, so a
/// coloured cell means one thing across the app.
///
/// **Colour by work that can be done on this screen.** Klasgroepen highlights a
/// row on `MaterializedGroup.needsAttention`, informational notices included
/// (#225/#250), because there the manual notice *is* the work the operator does
/// on that screen. Here an informational candidate is a diagnosis of work that
/// happens elsewhere, so it colours nothing, raises no badge and puts no row in
/// the work list — `pendingDecisionCount` has counted it zero since #245/#255,
/// and the indicators apply that same predicate. The case that forces the rule
/// is `AzureClassGroupMembership`: Office 365 class membership is a property of
/// the group, so the write is one `SyncAzureClassGroupMembers` per class on
/// Klasgroepen. Colouring it here would paint ~3000 student rows orange at the
/// rollover for work this screen structurally cannot do. (#290 proposed the
/// opposite and was closed; the action still declares `canApply => false`.)
///
/// ## What the details pane shows
///
/// [entryDetail] — the very blocks #281/#283 built and #300 made self-sufficient
/// — so every decision on the account leads with its own heading, then its field
/// diff (or radios), then the verdict of the last pass that answers *that*
/// decision. Reused rather than reinvented: Klasgroepen renders the identical
/// blocks inside its expandable rows, and two screens wording one decision two
/// ways is how an operator stops trusting either.
///
/// ## School-wide apply-all, cohort first (#296)
///
/// At the September rollover every student in the school needs the same
/// Smartschool class change. Doing that one account at a time is not a workflow
/// anyone will follow, so a decision block in the details pane offers
/// **Toepassen op alle (N)** — but only for the actions #293 sanctions for it,
/// which excludes every destructive one.
///
/// Pressing it does **not** write. It arms a review: the list drops its own
/// controls and filters down to exactly the N accounts the pass would touch, and
/// a banner above it names the one decision and offers **Dry-run alles**,
/// **Alles toepassen (N)** and **Annuleer**. So the operator scrolls the real
/// cohort — the same rows, the same indicators, each still selectable to read
/// its diff — before any confirmation is offered.
///
/// That is exactly what the global "Alles toepassen" of #294 could not do, and
/// the difference is not the dialog: it is that the button names *one* action
/// whose description and field diff the operator is looking at, over a list they
/// can see. The cohort is re-read from the controller by key on every build
/// rather than captured, so switching an account's alternative mid-review moves
/// it out of the cohort instead of being written as the resolution the operator
/// changed their mind about.
///
/// ## Why there is no selection here any more (#311)
///
/// #297 answered the same need from the other side: a checkbox on every row
/// carrying work, and a **Selecteer alle zichtbare (N)** bar above the list, so
/// one decision could be run over a hand-picked set — the affordance for the
/// destructive kinds #293 withholds a school-wide apply from. Both are gone.
///
/// Select-all is what took it down. It was one press to stage a write across
/// every account the current filter happened to be showing — four hundred and
/// more on an ordinary visit — which is the objection that removed the global
/// "Alles toepassen" in #294, with a filter standing in front of it. The count
/// beside it was whatever the filter was showing, which is not a set anybody has
/// read, and "the operator has looked at every row they ticked" stops being true
/// the moment one press ticks all of them. The bar also cost a bordered block
/// standing between the filter chips and the list on every visit, ticks or no
/// ticks — 126 logical pixels with its gap, on the view whose whole point is the
/// list.
///
/// So bulk on this screen is #296's cohort and nothing else: one *sanctioned*
/// decision, the list narrowed to exactly the accounts the pass will write, and
/// the confirmation offered over rows the operator is scrolling. What the
/// sanction withholds — the deletes, the unregisters, the renames — is applied
/// one account at a time from the details pane, which is the pace those actions
/// were always meant to run at.
///
/// ## Where an apply leaves the operator (#299)
///
/// Standing exactly where they were, reading what the pass did. That takes two
/// things, and the screen owns only the second.
///
/// The **refresh** is the controller's: `_applyOne` swaps in the view relinked
/// after every write and the derived lists are keyed on its identity, so a row's
/// indicators, its badge and the details pane's decisions all re-render in place
/// from the settled state, with no re-selection and no sync. What #299 added
/// there is that a pass pins those lists for its duration and drops them once at
/// the end — a rollover writes thousands of accounts and notifies per write, and
/// re-deriving the school between two writes is time spent on a list nobody can
/// read behind the modal.
///
/// The **list** is this screen's. An apply settles what it lands, so the account
/// just applied stops matching "toon enkel accounts met acties" and would drop
/// out the instant the pass ends — taking the selection, the open pane and the
/// verdict with it. So the pass's targets are held through the state filters
/// until the operator looks away, marked **Toegepast** when nothing is left on
/// them, and the pane keeps rendering the account's own verdict even once its
/// entry is gone.
///
/// That hold is not a filter and must never behave like one, so every control
/// that reshapes the list drops it: the sort, the work switch, the system chips,
/// the search box, a family tab change, and selecting an account the pass did
/// not touch. Selecting one it *did* keeps it — a bulk pass settles many
/// accounts and reading the second must not delete the first out from under the
/// tap. A sync drops it on its own, the pass that replaces the view being the
/// same one that clears the results the hold is read from.
///
/// The case that decides all of it is the half-succeeded pass, which is where
/// #272 came from: Smartschool takes the write, Graph refuses the other half.
/// The account keeps the refused decision, so it stays on the list under its own
/// steam, its card shows the refusal under the question it answers (#283) and
/// the landed half at card level. Nothing about that reads as a clean success,
/// which is the whole point.
///
/// ## What it deliberately does not do
///
/// Nothing here applies an action the operator has not seen. The header's global
/// "Dry-run alles" / "Alles toepassen" pair went in #294 for exactly that
/// reason, and the select-all bar of #297 followed it in #311 for the same one.
/// Every bulk apply is started from a list that is on screen: the cohort the
/// screen filtered itself down to (#296), and no other.
///
/// A running pass cannot be cancelled and is never concurrent — a rollover over
/// ~3000 accounts takes a long time, and is resumable in practice because every
/// applied decision settles out of the refreshed view, so re-arming picks up
/// what is left.
///
/// A session that #287 refuses to seed gets one blocking [ReadOnlyNotice] and no
/// list at all. The old screen offered a read-only browse of the stored
/// documents instead (#214); that was a second, inert way to browse the same
/// data, and the whole point of the notice is that there is one thing to do
/// about it.
///
/// Class groups are **not** here. They are a top-level Klasgroepen tab since
/// #227 — a full class inventory, which is a superset of what an Acties node
/// could show.
///
/// Shares the one memoized [ReconcileServices] (and so the one
/// [ReconcileController]) with the Reconcile, Klasgroepen and Passwords screens,
/// so a sync run on Reconcile populates the actions shown here.
class ActionsScreen extends StatefulWidget {
  const ActionsScreen({super.key, required this.bootstrap});

  /// Assembles (or returns the already-assembled) reconcile stack, or `null`
  /// when Azure AD is not configured for this build.
  final Future<ReconcileServices> Function()? bootstrap;

  @override
  State<ActionsScreen> createState() => _ActionsScreenState();
}

class _ActionsScreenState extends State<ActionsScreen> {
  ReconcileServices? _services;
  Object? _bootstrapError;
  bool _bootstrapping = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final make = widget.bootstrap;
    if (make == null) return;
    setState(() {
      _attempts++;
      _bootstrapping = true;
      _bootstrapError = null;
    });
    try {
      final services = await make();
      if (mounted) setState(() => _services = services);
      // The session's opening read: the shared overview from the store (#115),
      // and then the linked view built from the same shared state when the cold
      // seed allows it (#287) — no pull either way. Idempotent with the other
      // screens' own reads (all share the one controller). Fire-and-forget.
      unawaited(services.controller.openSession());
    } on Object catch (e) {
      if (mounted) setState(() => _bootstrapError = e);
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bootstrap == null) {
      return const MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Niet geconfigureerd',
        message: 'Azure AD is niet geconfigureerd, dus de instellingenopslag '
            'en de connectoren zijn onbereikbaar. Vul de app-registratie in '
            'onder Instellingen → Verbinding → Azure AD, bewaar, en start de '
            'app opnieuw op.',
      );
    }
    final error = _bootstrapError;
    if (error != null) {
      final retryNote = _attempts > 1 ? '\n\n(Poging $_attempts mislukt.)' : '';
      return MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Kan het Acties-scherm niet openen',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('actions-bootstrap-retry'),
          onPressed: _bootstrap,
          child: const Text('Probeer opnieuw'),
        ),
      );
    }
    final services = _services;
    if (_bootstrapping || services == null) {
      return const MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Voorbereiden…',
        message: 'De instellingen en verbindingsprofielen worden geladen.',
        progress: true,
      );
    }
    return _ActionsBody(controller: services.controller);
  }
}

/// The two family tabs (#179): staff and student actions are reviewed as
/// separate workflows, so the Actions view splits them across a horizontal tab
/// bar rather than one combined list. Index order matches the Reconcile
/// overview's category order (Leerlingen, then Personeel).
enum _ActionFamilyTab { leerlingen, personeel }

/// How the flat list is ordered (#295).
///
/// Two orders, because two things about an account order meaningfully: who they
/// are, and where they sit. "By system" is not a third — see the class doc of
/// [ActionsScreen] and [_SystemFilter].
enum _ActionSort {
  naam('Naam'),
  klas('Klas');

  const _ActionSort(this.label);

  final String label;
}

/// Which system's trouble the list is narrowed to (#295) — the half of "sort by
/// system" that is actually useful, expressed as what it is.
///
/// A row survives when its cell for that system is not green: it is missing
/// there, or this screen has applyable work against it. That is one control for
/// both of the questions the drill-down could not answer — *who is missing from
/// Office 365?* and *who has Smartschool work?*
enum _SystemFilter {
  alle('Alle', null),
  wisa('WISA', core.Origin.wisa),
  smartschool('Smartschool', core.Origin.smartschool),
  azure('Office 365', core.Origin.azure);

  const _SystemFilter(this.label, this.origin);

  final String label;

  /// The system this filter is about, or `null` for "narrow nothing".
  final core.Origin? origin;
}

/// One row of the flat list: the account as a document, plus the live pending
/// entry for it when it has one.
///
/// Both halves, and each answers something the other cannot. The document says
/// who the account is, which class it sits in and which systems hold it — facts
/// that are true of an account with nothing to do, which is most of them. The
/// entry is the work, and is `null` for exactly those.
class _AccountRow {
  const _AccountRow({required this.account, this.entry});

  final MaterializedAccount account;

  /// The interactive entry for this account, or `null` when nothing is pending.
  final PendingAccountEntry? entry;

  String get id => account.id.value;

  /// Whether an apply pass would write anything here — the predicate the
  /// "toon enkel accounts met acties" switch keeps rows on, and the same one the
  /// badge counts and the indicators colour by (#245/#255/#298). An entry that
  /// carries only an informational diagnosis is not work this screen can do.
  bool get hasWork => entry?.canApply ?? false;

  /// How many applyable decisions the badge quotes.
  int get pendingCount => entry == null
      ? 0
      : entry!.choices.where((c) => c.selected.canApply).length;

  /// The systems this row has applyable work in (#298) — what turns a cell
  /// orange. Read off the live dispatch, which drops a decision the moment it
  /// is applied.
  Set<core.Origin> get workSystems =>
      entry == null ? const <core.Origin>{} : workSystemsOfEntry(entry!);

  bool presentIn(core.Origin system) => switch (system) {
        core.Origin.wisa => account.inWisa,
        core.Origin.smartschool => account.inSmartschool,
        core.Origin.azure => account.inAzure,
        _ => true,
      };

  /// What this row's cell for [system] reads as.
  SystemIndicatorState stateFor(core.Origin system) => systemIndicatorState(
        present: presentIn(system),
        hasWork: workSystems.contains(system),
      );

  /// What the name search matches against — the display name alone. The class
  /// has its own control (the sort) and its own column, so folding it into the
  /// haystack would make "3" match every third-year student.
  String get searchText => account.label;
}

class _ActionsBody extends StatefulWidget {
  const _ActionsBody({required this.controller});

  final ReconcileController controller;

  @override
  State<_ActionsBody> createState() => _ActionsBodyState();
}

class _ActionsBodyState extends State<_ActionsBody>
    with SingleTickerProviderStateMixin {
  /// Below this many logical pixels of pane width the list and the details stop
  /// fitting side by side and become one pane with a back button.
  static const double _splitBreakpoint = 900.0;

  late final TabController _tabs;
  int _shownIndex = 0;

  /// The **global** Acties filter (#226): with the switch on, the list holds
  /// only the accounts carrying an applyable action.
  ///
  /// Defaults on — the Acties view exists to answer "what needs doing?", and the
  /// full inventory is the exception, not the starting point. Deliberately not
  /// reset by a family tab change: since #226 it is the view-wide mode, and the
  /// operator's mode outlives whichever tab they happen to be on.
  ///
  /// Since #295 turning it **off** means something it never could before: the
  /// list then holds every account of the school, in order, three green cells
  /// each. The drill-down could only ever show the classes and accounts that had
  /// raised something, because that is all a rollup knew.
  bool _onlyWithActions = true;

  /// The name search (#187/#217), promoted out of the Personeel classroom list
  /// it was born in.
  ///
  /// It is the list's own lookup now rather than one class's, so — unlike its
  /// ancestor — it is **not** cleared on a family tab change: the box stays on
  /// screen across the change, and text vanishing out of a visible box reads as
  /// a bug rather than as a fresh start.
  final TextEditingController _search = TextEditingController();

  _ActionSort _sort = _ActionSort.naam;
  _SystemFilter _system = _SystemFilter.alle;

  /// The selected account's id, or `null` when nothing is selected.
  ///
  /// Held here rather than on the controller — where the drill-down's open
  /// classroom used to live — because nothing outside this screen needs to know
  /// it, and because a selection must survive every controller notification a
  /// running pass emits.
  String? _selectedId;

  /// The [SituationCohort.key] of the decision under school-wide review (#296),
  /// or `null` when the list is the ordinary one.
  ///
  /// The key, never the members. A cohort under review is live — the operator
  /// can switch an account's alternative while looking at it — so it is
  /// re-resolved from the controller on every build; see
  /// [ReconcileController.applyToAllCohortFor].
  String? _cohortKey;

  /// The accounts the last apply pass wrote to, by id — the rows the list holds
  /// on screen for a moment longer than the filter would (#299).
  ///
  /// An apply settles what it lands, so an account whose work is finished stops
  /// matching "toon enkel accounts met acties" and would drop out of the list
  /// the instant the pass ends — taking the selection, the open details pane
  /// and the verdict the operator was waiting for with it. Worse when the pass
  /// half-succeeds: the reported case behind #272 is a class whose Smartschool
  /// write landed and whose Office 365 write was refused, and a row that
  /// vanishes on the strength of the half that worked makes a refusal read as a
  /// clean success.
  ///
  /// So the pass's targets are held through the filters until the operator
  /// looks away — see [_forgetSettled] for exactly when that is. Ids, for the
  /// reason [_selectedId] and [_ticked] are ids: the rows are rebuilt from the
  /// refreshed view underneath them.
  final Set<String> _settled = <String>{};

  /// The results list [_settled] was taken from, so it is re-read exactly once
  /// per pass. `_begin` nulls the results when any pass starts and the tail of
  /// the pass installs the new list, so an identity check covers both halves:
  /// the hold is dropped when a pass begins and re-armed from what it wrote.
  List<ActionOutcomeEntry>? _settledFrom;

  ReconcileController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _ActionFamilyTab.values.length, vsync: this)
      ..addListener(_onTabChanged);
    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    // Typing a name is the operator moving on, so the rows the last pass is
    // holding on screen let go (#299).
    if (mounted) setState(_forgetSettled);
  }

  /// Rebuilds for the newly-selected family and — when the family actually
  /// changed — drops the selection and any armed cohort, both of which belong
  /// to the list being left behind. A cohort is single-family by construction
  /// (its key leads with the family), so it would review an empty list here.
  void _onTabChanged() {
    final index = _tabs.index;
    if (index != _shownIndex) {
      _shownIndex = index;
      _selectedId = null;
      _cohortKey = null;
      // …as do the rows the last pass is holding on screen (#299).
      _forgetSettled();
    }
    if (mounted) setState(() {});
  }

  /// Re-reads [_settled] off the last pass's results (#299), at the top of
  /// [_body] — a reconciliation of state against what the build is about to
  /// read, rather than a controller listener: it is idempotent, the build is
  /// where the re-read set is needed, and a listener calling `setState` would
  /// have to defend against firing while a frame is already building.
  ///
  /// The whole pass, not only the accounts that came out clean: one that failed
  /// still has work and stays visible on its own, and one whose card now shows
  /// a refusal beside a success is exactly the row that must not move.
  ///
  /// Group results are dropped — a class is a Klasgroepen row, and its id is a
  /// display label rather than an account id, so keeping it could only ever
  /// collide with one.
  void _holdSettled() {
    final List<ActionOutcomeEntry>? results = controller.applyResults;
    if (identical(_settledFrom, results)) return;
    _settledFrom = results;
    _settled.clear();
    if (results == null) return;
    for (final r in results) {
      if (r.family != 'group' && r.targetId.isNotEmpty) {
        _settled.add(r.targetId);
      }
    }
  }

  /// Lets the held rows go (#299) — they are a courtesy to the operator reading
  /// a verdict, not a second filter, so they must clear reliably or a long
  /// session accumulates settled rows in a list that claims to show work.
  ///
  /// Called from every control that says the operator has moved on: a sort, the
  /// work switch, the system chips, the search box, a family tab change, and
  /// selecting an account that is not itself one of the held ones. A sync
  /// clears it too, through [_holdSettled] — the pass that replaces the view
  /// nulls the results the hold is read from.
  void _forgetSettled() {
    if (_settled.isEmpty) return;
    _settled.clear();
  }

  // The class-inventory pre-read this screen used to schedule from `build` is
  // gone with the pointer at Klasgroepen it existed for (#301 → #309). Nothing
  // Acties renders reads `groupDocs` any more, so warming it here was a
  // partition read on every cold visit that no pixel on this screen depended
  // on. Klasgroepen still reads it, through its own identical guard, on the tab
  // where the classes actually are.

  /// Whether the Personeel family tab is the selected one.
  bool get _staffTab => _tabs.index == _ActionFamilyTab.personeel.index;

  /// The typed needle, parsed. Matching is per whitespace-separated part and
  /// order-independent — the same [NameQuery] the Wachtwoorden and Klasgroepen
  /// boxes use (#215/#217/#262), so every search in this app behaves the same.
  /// Per-part matching is what makes either name order work: "peeters jan"
  /// finds "Jan Peeters", which as one contiguous substring found nobody.
  NameQuery get _query => NameQuery(_search.text);

  /// Every account of the selected family, with its live entry joined on — the
  /// unfiltered list, in the chosen order.
  List<_AccountRow> _rows() {
    // Keyed by target id, which is a `LinkedAccountId` — unique per person by
    // INV-24. This map literal is last-wins, so on a collision it is the one
    // place in this screen that loses an entry outright rather than merging it:
    // the row keeps whichever entry the controller listed last and the other
    // record's decisions never render. That is deliberate rather than defended
    // against here, because a row can only show one entry and picking between
    // two contradictory ones is not this screen's call. The collision itself is
    // caught upstream, where it can be reported as the linker bug it is —
    // `LinkedSnapshot.fromRecords` raises a `DuplicateLinkedId` warning, which
    // the sync log and the Synchronisatie overview both name (#319).
    final byTarget = <String, PendingAccountEntry>{
      for (final e in controller.pendingEntries)
        if (e.family != 'group') e.targetId: e,
    };
    final rows = <_AccountRow>[
      for (final doc in controller.linkedAccounts)
        if (doc.isStaff == _staffTab)
          _AccountRow(account: doc, entry: byTarget[doc.id.value]),
    ];
    rows.sort(_compare);
    return rows;
  }

  /// The chosen order, with the name as the tie-break under either and the
  /// account's own id under that.
  ///
  /// Both tie-breaks earn their place: a class of twenty must not reshuffle
  /// between rebuilds, and `List.sort` is **not** stable — two namesakes (or a
  /// September intake still carrying a placeholder name) would otherwise come
  /// back in a different order every build.
  int _compare(_AccountRow a, _AccountRow b) {
    if (_sort == _ActionSort.klas) {
      final byClass =
          compareClassNames(a.account.classroom, b.account.classroom);
      if (byClass != 0) return byClass;
    }
    final byName =
        a.account.label.toLowerCase().compareTo(b.account.label.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }

  /// [_rows] narrowed by the three controls, which compose rather than replace
  /// one another: the switch keeps the accounts with work, the search keeps the
  /// names asked for, the system filter keeps the rows that system has something
  /// to say about.
  ///
  /// A cohort under review (#296) replaces all three instead of composing with
  /// them — that is what "the list shows you the cohort" means. The N on the
  /// button counts the school, so a search or a system chip left over from a
  /// moment ago must not quietly hide members of the very list the operator is
  /// being asked to confirm. The controls are off screen while it is armed, so
  /// there is nothing to look inert.
  List<_AccountRow> _visibleRows(
    List<_AccountRow> rows,
    SituationCohort? cohort,
  ) {
    if (cohort != null) {
      final members = <String>{
        for (final d in cohort.decisions) d.entry.targetId,
      };
      return <_AccountRow>[
        for (final r in rows)
          if (members.contains(r.id)) r,
      ];
    }
    final NameQuery query = _query;
    final core.Origin? origin = _system.origin;
    return <_AccountRow>[
      for (final r in rows)
        // A row the last pass just settled is exempt from both *state* filters
        // — the work switch and the system chip, which are two readings of
        // "does this need doing?" and are exactly what an apply has just
        // answered (#299). Never from the search: that one is about who the
        // account is, and a needle that no longer matches was typed after the
        // pass, which drops the hold anyway.
        if ((_settled.contains(r.id) ||
                ((!_onlyWithActions || r.hasWork) &&
                    (origin == null ||
                        r.stateFor(origin) != SystemIndicatorState.inOrder))) &&
            query.matches(r.searchText))
          r,
    ];
  }

  /// The cohort the screen is reviewing, re-read by key from the controller on
  /// every build (#296) — `null` when nothing is armed, and also when the armed
  /// cohort has emptied out from under the review.
  SituationCohort? _armedCohort() {
    final key = _cohortKey;
    if (key == null) return null;
    return controller.applyToAllCohortFor(key);
  }

  /// Arms the school-wide review of [decision]: the list narrows to its cohort
  /// and the banner takes over from the list controls. Nothing is written.
  ///
  /// Since #311 this is the only bulk path on the screen, so there is no second
  /// set of accounts to reconcile it against: the review's list *is* its cohort,
  /// resolved school-wide.
  void _armCohort(PendingDecision decision) {
    final cohort = controller.applyToAllCohort(decision);
    if (cohort == null) return;
    setState(() => _cohortKey = cohort.key);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: LayoutBuilder(builder: _body),
        ),
      ),
    );
  }

  static const EdgeInsets _hPad =
      EdgeInsets.symmetric(horizontal: PlinkSpacing.s6);

  Widget _body(BuildContext context, BoxConstraints constraints) {
    _holdSettled();
    final bool wide = constraints.maxWidth >= _splitBreakpoint;
    final bool active = controller.linked != null;
    final SituationCohort? cohort = active ? _armedCohort() : null;
    final rows = active ? _rows() : const <_AccountRow>[];
    final visible = _visibleRows(rows, cohort);
    // A selection the current filters have hidden is not a selection any more:
    // the operator cannot see what they would be acting on.
    final _AccountRow? selected = _selectedRow(visible);
    // In one pane the details take the whole width, so the list stands down.
    final bool showList = wide || selected == null;

    final Widget head = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: PlinkSpacing.s6),
        const Padding(padding: _hPad, child: _ActionsHeader()),
        const SizedBox(height: PlinkSpacing.s4),
        Padding(padding: _hPad, child: _stateNotice()),
      ],
    );

    // A refused session is the header and one blocking notice, and nothing
    // else. It scrolls as a whole rather than being pinned above a pane that is
    // not there: on a short window the notice — which carries the sync button
    // the operator needs — would otherwise be the part that overflows.
    if (!active) return SingleChildScrollView(child: head);

    return Column(
      // Stretch, not start: the panes below have to fill the measured width
      // rather than shrink to their content.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _capped(
          constraints,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              head,
              Padding(
                padding: _hPad,
                // The two are exclusive: while a cohort is under review the
                // list is *that cohort*, so controls that would narrow it
                // further would either lie about N or do nothing.
                child: cohort == null
                    ? _ListControls(
                        searchController: _search,
                        onlyWithActions: _onlyWithActions,
                        // Every one of the three reshapes the list, which is
                        // the operator saying they are done reading the last
                        // pass — so each lets the held rows go (#299).
                        onOnlyWithActionsChanged: (v) => setState(() {
                          _onlyWithActions = v;
                          _forgetSettled();
                        }),
                        sort: _sort,
                        onSortChanged: (v) => setState(() {
                          _sort = v;
                          _forgetSettled();
                        }),
                        system: _system,
                        onSystemChanged: (v) => setState(() {
                          _system = v;
                          _forgetSettled();
                        }),
                      )
                    : _CohortReviewBanner(
                        controller: controller,
                        cohort: cohort,
                        onDisarm: () => setState(() => _cohortKey = null),
                      ),
              ),
              const SizedBox(height: PlinkSpacing.s3),
              Padding(
                padding: _hPad,
                child: _FamilyTabBar(controller: controller, tabs: _tabs),
              ),
              const SizedBox(height: PlinkSpacing.s3),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (showList)
                Expanded(
                  flex: 5,
                  child: _listPane(
                    rows: rows,
                    visible: visible,
                    selected: selected,
                  ),
                ),
              if (wide) const VerticalDivider(width: 1, thickness: 1),
              if (wide || !showList)
                Expanded(
                  flex: 6,
                  child: _detailPane(selected: selected, wide: wide),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// How much of a short window the fixed block above the panes may take before
  /// it starts scrolling inside itself.
  static const double _headShare = 0.65;

  /// Bounds the block above the panes so it can never overflow a short window.
  ///
  /// It is a fixed header at any ordinary window height — the content is well
  /// under [_headShare] of it, so the [SingleChildScrollView] simply sizes to
  /// its child and the panes below take the rest. Squeeze the window and the
  /// header scrolls within its share instead of pushing the list off the bottom,
  /// which is what a plain [Column] would do: the panes' [Expanded] can only
  /// give back space that is left, and here there is none.
  Widget _capped(BoxConstraints constraints, Widget child) {
    if (!constraints.hasBoundedHeight) return child;
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: constraints.maxHeight * _headShare),
      child: SingleChildScrollView(child: child),
    );
  }

  /// The row the selection names, or `null` — including when the filters have
  /// taken it off the screen.
  _AccountRow? _selectedRow(List<_AccountRow> visible) {
    final id = _selectedId;
    if (id == null) return null;
    for (final r in visible) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The announcement above the list about where this session's view comes
  /// from.
  ///
  /// Two of them, and never both: [ReadOnlyNotice] when there is no linked view
  /// at all — a session refused the shared seed (#287), or one whose sync/drift
  /// pass failed before it could link (#214) — and [SharedStateNotice] when the
  /// list below *is* interactive but was built from the cold seed a colleague's
  /// sync left behind (#287). Nothing at all in a session that pulled for
  /// itself.
  ///
  /// A refused session gets the notice and no list: since #295 there is no
  /// read-only browse of the stored documents to fall back on, because a second
  /// inert way to browse the same data is not what a blocking notice is for.
  Widget _stateNotice() {
    final Widget? notice = controller.linked == null
        ? ReadOnlyNotice(controller: controller)
        : controller.adoptedFrom == null
            ? null
            : SharedStateNotice(controller: controller);
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s4),
      child: notice,
    );
  }

  /// The left pane: the flat list itself, lazily built so a September roster of
  /// thousands costs only the rows on screen (#111/#154).
  Widget _listPane({
    required List<_AccountRow> rows,
    required List<_AccountRow> visible,
    required _AccountRow? selected,
  }) {
    if (rows.isEmpty) {
      return Padding(
        padding: _hPad,
        child: EmptyLine(_staffTab
            ? 'Geen personeelsleden in het gedeelde overzicht.'
            : 'Geen leerlingen in het gedeelde overzicht.'),
      );
    }
    if (visible.isEmpty) {
      return Padding(
        padding: _hPad,
        child: EmptyLine(
            _onlyWithActions && _query.isEmpty && _system == _SystemFilter.alle
                ? 'Geen openstaande acties — alles staat in orde.'
                : _noMatchLabel),
      );
    }
    return ListView.builder(
      key: const ValueKey('actions-list'),
      padding: _hPad,
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final row = visible[index];
        return _AccountListRow(
          row: row,
          selected: identical(row, selected),
          onTap: () => setState(() {
            // Moving to an account the last pass did not touch is the operator
            // done with its results, so the held rows go (#299). Moving to one
            // it *did* keeps them: a bulk pass settles many accounts at once
            // and reading the second must not delete the first from under the
            // tap that opened it.
            if (!_settled.contains(row.id)) _forgetSettled();
            _selectedId = row.id;
          }),
          justApplied: _settled.contains(row.id),
        );
      },
    );
  }

  /// The line shown when the active controls hide every account of a non-empty
  /// list — distinct from the "nothing pending at all" line, which is a
  /// statement about the school rather than about the filters.
  static const String _noMatchLabel =
      'Geen accounts die aan de filter voldoen.';

  /// The right pane (or, on a narrow window, the only one): the selected
  /// account's decisions, and below them what the last pass did.
  Widget _detailPane({required _AccountRow? selected, required bool wide}) {
    final TextTheme text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: _hPad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!wide && selected != null) ...<Widget>[
            _DetailBackHeader(onBack: () => setState(() => _selectedId = null)),
            const SizedBox(height: PlinkSpacing.s3),
          ],
          if (selected == null)
            Text(
              key: const ValueKey('actions-detail-empty'),
              'Kies een account in de lijst om de openstaande beslissingen te '
              'zien.',
              style: text.bodyMedium,
            )
          else
            _AccountDetail(
              controller: controller,
              row: selected,
              onApplyToAll: _armCohort,
            ),
          ..._resultSections(),
          const SizedBox(height: PlinkSpacing.s6),
        ],
      ),
    );
  }

  /// The page-level verdict of the last pass, rendered in the details pane.
  ///
  /// It reports the *pass*, which is a different thing from the per-decision
  /// verdicts [entryDetail] renders on the card that raised the work (#272/
  /// #283). It sits here rather than under the list because every apply on this
  /// screen is started from an open details pane, so this is where the operator
  /// already is when the pass ends.
  List<Widget> _resultSections() {
    final dry = controller.dryRunResults;
    final applied = controller.applyResults;
    return <Widget>[
      if (dry != null)
        _ResultSection(
          title: 'Resultaat van de dry-run',
          subtitle: 'Er is niets geschreven. Dit is wat toepassen zou doen.',
          results: dry,
        ),
      if (applied != null)
        _ResultSection(
          title: 'Resultaat van het toepassen',
          subtitle: applyResultsSubtitle(applied),
          results: applied,
        ),
    ];
  }
}

/// The Acties eyebrow — and, since #309, nothing else.
///
/// The account list *is* this view; everything stacked above it is preamble the
/// operator reads once and then scrolls past on every visit afterwards, while
/// the vertical budget it eats is paid every time. On a 1080p window the header,
/// the search box, the work switch and the filter chips together left the list
/// the lower half of the screen — two or three accounts at a time. So four lines
/// came off, each for its own reason:
///
/// - **The title.** `Arcadia · acties` says the same thing one line above it.
/// - **The count** (`N openstaande actie(s) — …`). Four digits of pending work
///   is not actionable, and its trailing clause explained the work-list switch
///   that is visible two lines further down anyway.
/// - **The pointer at Klasgroepen** (#301). What the other tab is holding
///   belongs on that tab; the mirror line there — how many accounts Acties is
///   holding — stays, because Klasgroepen has the room and its list is shorter.
///   The asymmetry is the choice, not an oversight.
/// - **The freshness stamp** (#247/#287). It is a property of the shared state
///   rather than of this list. [sharedViewFreshness] still renders it on
///   Klasgroepen, and Start/Synchronisatie still carries the per-system
///   last-sync box, so an operator judging staleness has not lost the signal.
///
/// It has carried nothing that *acts* since #294 either: the global "Dry-run
/// alles" / "Alles toepassen" pair that wrote every pending action of every
/// family in one pass, over a list nobody had looked at. Bulk itself came back
/// on the decision block in #296, where pressing it filters the list to the
/// cohort and shows the accounts before offering a confirmation.
class _ActionsHeader extends StatelessWidget {
  const _ActionsHeader();

  @override
  Widget build(BuildContext context) {
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[Eyebrow('Arcadia · acties', onInk: ink)],
    );
  }
}

/// Everything that shapes the list: the name search, the work-list switch, the
/// sort and the system filter.
///
/// Collected in one block above the family tabs, because each of them governs
/// both families and every one of them is a property of *the list* rather than
/// of a row. The switch in particular is set in exactly one place (#226); its
/// per-classroom ancestor had to be re-flipped in every class the operator
/// opened, which is why it never actually collapsed anything to the work list.
///
/// The name box and the work-list switch share one row since #310. Each of
/// them shapes the same list, so reading them together matches what they do —
/// and the box no longer claims 1500px of a wide window for a field that holds
/// a name. Laid out as a [Wrap] so a window too narrow for both puts the switch
/// on a second run instead of overflowing.
class _ListControls extends StatelessWidget {
  const _ListControls({
    required this.searchController,
    required this.onlyWithActions,
    required this.onOnlyWithActionsChanged,
    required this.sort,
    required this.onSortChanged,
    required this.system,
    required this.onSystemChanged,
  });

  final TextEditingController searchController;
  final bool onlyWithActions;
  final ValueChanged<bool> onOnlyWithActionsChanged;
  final _ActionSort sort;
  final ValueChanged<_ActionSort> onSortChanged;
  final _SystemFilter system;
  final ValueChanged<_SystemFilter> onSystemChanged;

  /// The widest the name box gets (#310).
  ///
  /// A name is a handful of words; beyond this the field is empty rubber, and
  /// the width is better spent on the switch beside it. Bounded rather than
  /// fixed: on a window narrower than this the box takes what there is, so the
  /// cap never becomes the thing that overflows.
  static const double _searchMaxWidth = 380.0;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: PlinkSpacing.s4,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _searchMaxWidth),
              child: TextField(
                key: const ValueKey('actions-search'),
                controller: searchController,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  // Same wording as the Wachtwoorden → Personeel box, which
                  // matches the same way (#217): any part of the name, in any
                  // order.
                  hintText: 'Zoek op naam…',
                  border: const OutlineInputBorder(),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('actions-search-clear'),
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Wis zoekopdracht',
                          onPressed: searchController.clear,
                        ),
                ),
              ),
            ),
            // Sized to the switch and its label rather than stretched: the Wrap
            // already bounds it to the row, so the label folds before anything
            // can spill.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Switch(
                  key: const ValueKey('actions-only-with-actions'),
                  value: onlyWithActions,
                  onChanged: onOnlyWithActionsChanged,
                ),
                const SizedBox(width: PlinkSpacing.s2),
                Flexible(
                  child: Text('Toon enkel accounts met acties',
                      style: text.bodyMedium),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: PlinkSpacing.s2),
        Wrap(
          spacing: PlinkSpacing.s2,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text('Sorteer op', style: text.bodySmall),
            for (final option in _ActionSort.values)
              ChoiceChip(
                key: ValueKey('actions-sort-${option.name}'),
                label: Text(option.label),
                selected: sort == option,
                onSelected: (_) => onSortChanged(option),
              ),
            const SizedBox(width: PlinkSpacing.s3),
            Text('Systeem', style: text.bodySmall),
            for (final option in _SystemFilter.values)
              ChoiceChip(
                key: ValueKey('actions-system-${option.name}'),
                label: Text(option.label),
                selected: system == option,
                onSelected: (_) => onSystemChanged(option),
              ),
          ],
        ),
      ],
    );
  }
}

/// The cohort under school-wide review (#296): what the one armed decision is,
/// how many accounts in the school raise it, and the two passes that cover
/// exactly them — plus the way out.
///
/// It stands where [_ListControls] normally stands, and that placement is the
/// design. The list below it *is* the cohort, so this reads as a caption of the
/// rows the operator is scrolling rather than as a floating button whose scope
/// has to be taken on trust. It is the answer to the "Alles toepassen" of #294:
/// the same power, but the list is filtered to what will be written and the
/// operator is standing in front of it before a dialog is ever offered.
///
/// Both passes run over the very cohort this banner counted — the standing rule
/// since #252 — and that cohort is re-read from the controller on every build,
/// so an alternative switched mid-review moves the account out of the list, out
/// of N, out of the confirmation's change count and out of the write together.
class _CohortReviewBanner extends StatelessWidget {
  const _CohortReviewBanner({
    required this.controller,
    required this.cohort,
    required this.onDisarm,
  });

  final ReconcileController controller;
  final SituationCohort cohort;

  /// Leaves the review and gives the list its own controls back.
  final VoidCallback onDisarm;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int count = cohort.length;

    return Container(
      key: const ValueKey('actions-cohort-banner'),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.06),
        border: Border.all(color: colors.primary),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${cohort.label} — $count account(s) in de hele school',
            style: text.titleSmall,
          ),
          const SizedBox(height: PlinkSpacing.s1),
          Text(
            'De lijst toont enkel deze accounts. Bekijk ze en bevestig '
            'hieronder; elk account krijgt zijn eigen gekozen oplossing.',
            style: text.bodySmall,
          ),
          const SizedBox(height: PlinkSpacing.s3),
          Wrap(
            spacing: PlinkSpacing.s2,
            runSpacing: PlinkSpacing.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              TextButton(
                key: const ValueKey('actions-cohort-cancel'),
                onPressed: controller.busy ? null : onDisarm,
                child: const Text('Annuleer'),
              ),
              OutlinedButton(
                key: const ValueKey('actions-cohort-dry-run'),
                onPressed: controller.busy
                    ? null
                    : () => runWithProgress(
                          context,
                          controller: controller,
                          dry: true,
                          // Nothing is written, so the review survives it: the
                          // dry-run is what the operator reads before pressing
                          // the one beside it.
                          run: () =>
                              controller.dryRunDecisions(cohort.decisions),
                        ),
                child: const Text('Dry-run alles'),
              ),
              FilledButton(
                key: const ValueKey('actions-cohort-apply'),
                onPressed: controller.busy ? null : () => _apply(context),
                child: Text('Alles toepassen ($count)'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Confirms, runs, and — only when the pass really ran — leaves the review.
  ///
  /// A cancelled confirmation must put the operator back exactly where they
  /// were, still looking at the cohort. A finished pass has invalidated it:
  /// every decision it wrote settles out of the refreshed view, so what is left
  /// is the failures, and re-arming from a card is how they are picked up.
  Future<void> _apply(BuildContext context) async {
    final ran = await confirmAndApply(
      context,
      controller: controller,
      // The count and the noun the banner just showed, so the dialog is
      // recognisably about the list behind it.
      title: 'Toepassen op ${cohort.length} account(s)?',
      // Scoped to this one decision across the cohort (#292): summing every
      // decision on every card would quote writes this pass will not make.
      scope: controller.applyScopeForDecisions(cohort.decisions),
      apply: () => controller.applyDecisions(cohort.decisions),
    );
    if (ran) onDisarm();
  }
}

/// The horizontal family tab bar (#179): switches the list below between the
/// Leerlingen (student) and Personeel (staff) action families, each carrying a
/// pending-count badge so the operator sees where the work sits without opening
/// both. Staff and student actions are reviewed as separate workflows,
/// mirroring the legacy WPF app.
class _FamilyTabBar extends StatelessWidget {
  const _FamilyTabBar({required this.controller, required this.tabs});

  final ReconcileController controller;
  final TabController tabs;

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: <Widget>[
        _tab(
          keyValue: 'actions-tab-leerlingen',
          label: 'Leerlingen',
          count: controller.studentPendingCount,
        ),
        _tab(
          keyValue: 'actions-tab-personeel',
          label: 'Personeel',
          count: controller.staffPendingCount,
        ),
      ],
    );
  }

  Widget _tab({
    required String keyValue,
    required String label,
    required int count,
  }) =>
      Tab(
        key: ValueKey(keyValue),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label),
            if (count > 0) ...<Widget>[
              const SizedBox(width: PlinkSpacing.s2),
              PlinkBadge('$count'),
            ],
          ],
        ),
      );
}

/// One account in the flat list: who they are, where they sit, and what each of
/// the three systems says about them.
///
/// A line rather than an expandable card, which is the whole shape change of
/// #295: the decisions live in the details pane beside it, so a row stays one
/// scannable height whatever it is carrying, and a list of three thousand is a
/// list of three thousand rows rather than of three thousand collapsed cards.
class _AccountListRow extends StatelessWidget {
  const _AccountListRow({
    required this.row,
    required this.selected,
    required this.onTap,
    this.justApplied = false,
  });

  final _AccountRow row;
  final bool selected;
  final VoidCallback onTap;

  /// Whether the last apply pass wrote to this account (#299) — which is why
  /// the row may be here at all with nothing left to do.
  ///
  /// It gets a marker rather than being left to the badge's muted tick, because
  /// that tick is also what an account that was in order all along shows, and
  /// the difference between "nothing to do here" and "this is what you just
  /// did" is the whole reason the row is being held.
  final bool justApplied;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color hairline = Theme.of(context).dividerColor;

    return Container(
      key: ValueKey('account-row-${row.id}'),
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: BoxDecoration(
        color: selected ? colors.primary.withValues(alpha: 0.06) : null,
        border: Border.all(color: selected ? colors.primary : hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
        child: Padding(
          padding: const EdgeInsets.all(PlinkSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      row.account.label,
                      style: text.bodyLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: PlinkSpacing.s2),
                  Text(row.account.classroom, style: text.bodySmall),
                  // Only once the work is gone: a pass that half-failed leaves
                  // the row with its remaining decisions, and calling that
                  // "toegepast" is the misreading #299 is written against.
                  if (justApplied && !row.hasWork) ...<Widget>[
                    const SizedBox(width: PlinkSpacing.s2),
                    Row(
                      key: ValueKey('account-done-${row.id}'),
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.task_alt, size: 14, color: colors.primary),
                        const SizedBox(width: PlinkSpacing.s1),
                        Text(
                          'Toegepast',
                          style:
                              text.bodySmall?.copyWith(color: colors.primary),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(width: PlinkSpacing.s2),
                  PendingBadge(count: row.pendingCount),
                ],
              ),
              const SizedBox(height: PlinkSpacing.s2),
              _SystemRow(row: row),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three system cells of one account: WISA · Smartschool · Office 365, in
/// the shared vocabulary of #298 — red missing, orange work pending, green in
/// order.
class _SystemRow extends StatelessWidget {
  const _SystemRow({
    required this.row,
    this.keyPrefix = 'account-cell',
    this.showAzureSchools = false,
  });

  final _AccountRow row;

  /// What names these three cells. The details pane repeats the row's cells, so
  /// the two sets must not answer to one key: `find.byKey` would be ambiguous
  /// exactly when a row is selected, which is every interesting case.
  final String keyPrefix;

  /// Whether the Office 365 cell also names the schools that account's Azure
  /// `department` lists (#352) — the details pane only.
  ///
  /// The same split #334 made for the sibling-enrolment line, and for the same
  /// reason: this is context for reading *one* card at the moment of a
  /// destructive per-record decision, not a column to scan. On a list of staff
  /// an extra
  /// line under every card's third cell is noise. Because the two sets of cells
  /// share this widget, the gate has to be here — a `detail` handed to the cell
  /// unconditionally would appear in both.
  final bool showAzureSchools;

  @override
  Widget build(BuildContext context) {
    // Each cell is addressable on its own — `account-cell-<id>-<systeem>` —
    // exactly as a Klasgroepen row's cells are (`class-cell-<klas>-<systeem>`),
    // so a test can ask one row what it says about one system rather than
    // counting icons across three.
    final List<String> schools = row.account.departmentSchools;
    final String? azureSchools = showAzureSchools && schools.isNotEmpty
        ? _departmentSchoolsLine(schools)
        : null;
    Widget cell(core.Origin system) => Expanded(
          child: SystemIndicatorCell(
            key: ValueKey('$keyPrefix-${row.id}-${system.name}'),
            system: system,
            state: row.stateFor(system),
            detail: system == core.Origin.azure ? azureSchools : null,
          ),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        cell(core.Origin.wisa),
        cell(core.Origin.smartschool),
        cell(core.Origin.azure),
      ],
    );
  }
}

/// What the card says about one *other* group school this person is enrolled in
/// (#334): "Ook ingeschreven in Instituut Sancta Maria-B (ISMAB), klas 3HWa".
///
/// A statement, not an action. It sits beside the class facts because that is
/// what it explains: at the start of a school year a student may apply to
/// several schools of the group, and until she turns up the card carries a
/// second school's traces — a departure beside a create, a class name from
/// nowhere. Rare enough that nobody remembers it when it appears, which is
/// exactly why it is written down rather than left to be inferred.
///
/// The school is named by the WISA school list ([OtherEnrolment.schoolLabel],
/// baked in by the materializer), and the class is *that* school's — read here
/// and nowhere else. Every value this app writes comes from our own school's row
/// (INV-25).
/// What the Office 365 cell says about the schools a staff member's Azure
/// `department` lists (#352): "Scholen: SSM, GBS".
///
/// The field's own content, verbatim — its order, its casing, its entries,
/// separated the way it separates them. No re-sorting, no case-folding, no
/// label invented for an unknown prefix: this is a quotation of a field
/// maintained by other software (#237), offered so the operator can read what
/// the app's two Office 365 departure actions split on and check it before
/// pressing.
///
/// Our own school stays in the list. "SSM only" is the case that makes a
/// deletion safe, so it is the one worth stating out loud — the release/delete
/// split filters our prefix out (`departmentSchoolsExcept`), and the reading
/// must not.
String _departmentSchoolsLine(List<String> schools) =>
    'Scholen: ${schools.join(', ')}';

String _otherEnrolmentLine(OtherEnrolment e) {
  final String klas = e.classroom.trim();
  final String where = klas.isEmpty ? 'zonder klas' : 'klas $klas';
  return 'Ook ingeschreven in ${e.schoolLabel}, $where';
}

/// The details pane's content for one account: who it is, what each system says
/// about it, and every decision it raises.
///
/// Since #334 it also states the other group schools the person is enrolled in,
/// directly under the class facts they qualify, and since #352 the schools a
/// staff member's Azure `department` lists, under the Office 365 cell. Only
/// here, and not on the collapsed list row: the row is one dense line per
/// account across a roster of thousands, and both are context for reading *one*
/// card, not a way to scan.
///
/// The decisions are [entryDetail] verbatim — one block per decision, each led
/// by its own heading and its system, then the radios or the field diff, then
/// the verdict of the last pass that answers *that* decision (#281/#283). #300
/// made those blocks stand on their own precisely so this pane could reuse them
/// with no collapsed row above to have previewed anything.
class _AccountDetail extends StatelessWidget {
  const _AccountDetail({
    required this.controller,
    required this.row,
    required this.onApplyToAll,
  });

  final ReconcileController controller;
  final _AccountRow row;

  /// What a decision block's "Toepassen op alle (N)" arms (#296).
  final void Function(PendingDecision decision) onApplyToAll;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final PendingAccountEntry? entry = row.entry;

    return Column(
      key: ValueKey('actions-detail-${row.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(row.account.label, style: text.titleMedium)),
            const SizedBox(width: PlinkSpacing.s2),
            PendingBadge(count: row.pendingCount),
          ],
        ),
        const SizedBox(height: PlinkSpacing.s1),
        Text(row.account.classroom, style: text.bodySmall),
        for (final (int i, OtherEnrolment e)
            in row.account.otherEnrolments.indexed) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(
            key: ValueKey('account-other-enrolment-${row.id}-$i'),
            _otherEnrolmentLine(e),
            style: text.bodySmall,
          ),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        // Repeated from the row on purpose: on a narrow window the list is not
        // on screen at all, so the pane has to be able to say what the account's
        // three systems look like.
        _SystemRow(
          row: row,
          keyPrefix: 'account-detail-cell',
          showAzureSchools: true,
        ),
        for (final w in row.account.warnings) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s2),
          Text(w, style: text.bodySmall),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        if (entry == null) ...<Widget>[
          Text(
            'Geen openstaande beslissingen voor dit account.',
            style: text.bodyMedium,
          ),
          ..._settledVerdict(),
        ] else
          ...entryDetail(
            context,
            controller: controller,
            entry: entry,
            onApplyToAll: onApplyToAll,
          ),
        if (row.account.isStaff)
          _RetireStaffBlock(controller: controller, row: row),
      ],
    );
  }

  /// What the last pass did to an account it left with nothing to decide
  /// (#299) — the verdict block [entryDetail] would have shown at card level,
  /// for the card that no longer exists.
  ///
  /// The ordinary end of a successful apply, and the moment the operator most
  /// wants to read: their work settled every decision, so the entry that
  /// carried them is gone and with it every route to the verdict except the
  /// page-level results section — which reports the whole *pass*, and in a
  /// rollover is hundreds of rows deep. Keyed exactly as the card-level block
  /// is, because it is the same block about the same account.
  List<Widget> _settledVerdict() {
    final String family = row.account.isStaff ? 'staff' : 'student';
    final outcomes = controller.applyOutcomesForTarget(
      family: family,
      targetId: row.id,
    );
    if (outcomes.isEmpty) return const <Widget>[];
    return <Widget>[
      EntryOutcomes(
        keyValue: 'entry-outcomes-$family-${row.id}',
        outcomes: outcomes,
        settled: true,
      ),
    ];
  }
}

/// The "medewerker uit dienst" command for one staff member (#349).
///
/// **Why it is here and not in the pending list.** WISA's staff export carries
/// no employment status; whether somebody is in actief dienstverband is decided
/// from the werkdatum, server-side. When HR leaves a dienstverband open for a
/// teacher who will not be hired again — which is the standing situation here,
/// not an edge case — she arrives in every pull looking exactly like a colleague
/// who is staying, so the dispatch (§6.3) has nothing to raise and her accounts
/// can never be cleaned up. The judgement is the operator's, so this is a
/// command on the record they have open rather than a decision on a card.
///
/// **One record at a time, deliberately.** There is no cohort, no "toepassen op
/// alle", and `RetireStaffMember.canApplyToAll` is false so nothing downstream
/// could offer one either. A departure has to be read and the name recognised,
/// because the person who knows whether a teacher is coming back is the person
/// looking at the screen.
///
/// It sits below the decisions and behind its own confirmation because it is not
/// part of the card's work: applying every decision on the card must never carry
/// a retirement with it.
class _RetireStaffBlock extends StatelessWidget {
  const _RetireStaffBlock({required this.controller, required this.row});

  final ReconcileController controller;
  final _AccountRow row;

  @override
  Widget build(BuildContext context) {
    final core.LinkedStaff? staff = controller.liveStaffFor(row.id);
    // Nothing to open for somebody WISA has already let go: their departure is
    // an ordinary decision on the card above.
    if (staff == null || !controller.canRetireStaff(staff)) {
      return const SizedBox.shrink();
    }
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String name = row.account.label;

    return Column(
      key: ValueKey('actions-retire-${row.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: PlinkSpacing.s4),
        const Divider(height: 1, thickness: 1),
        const SizedBox(height: PlinkSpacing.s3),
        Text('Uit dienst', style: text.titleSmall),
        const SizedBox(height: PlinkSpacing.s1),
        Text(
          'WISA meldt dit personeelslid nog als in dienst. Gebruik dit enkel '
          'wanneer je weet dat de persoon niet terugkomt: het account wordt '
          'voortaan genegeerd bij het importeren uit WISA, en de accounts in '
          'Smartschool en Office 365 worden opgeruimd.',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: PlinkSpacing.s3),
        Wrap(
          spacing: PlinkSpacing.s2,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton(
              key: ValueKey('actions-retire-dry-run-${row.id}'),
              onPressed: controller.busy
                  ? null
                  : () => runWithProgress(
                        context,
                        controller: controller,
                        dry: true,
                        run: () => controller.retireStaff(staff, dry: true),
                      ),
              child: const Text('Dry-run'),
            ),
            FilledButton(
              key: ValueKey('actions-retire-apply-${row.id}'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed:
                  controller.busy ? null : () => _retire(context, staff, name),
              child: const Text('Medewerker uit dienst'),
            ),
          ],
        ),
      ],
    );
  }

  /// Confirms, naming the systems the chain behind the rule will reach (#234) —
  /// the WISA rule alone would understate what one press does.
  Future<void> _retire(
    BuildContext context,
    core.LinkedStaff staff,
    String name,
  ) =>
      confirmAndApply(
        context,
        controller: controller,
        title: '$name uit dienst?',
        scope: controller.retirementScope(staff),
        apply: () => controller.retireStaff(staff),
      );
}

/// The back affordance of the one-pane layout: on a window too narrow for two
/// columns the details replace the list, so there has to be a way back to it.
class _DetailBackHeader extends StatelessWidget {
  const _DetailBackHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('actions-detail-back'),
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Overzicht'),
        ),
      );
}

/// One dry-run/apply results block: its title, its subtitle, and one row per
/// outcome.
class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.title,
    required this.subtitle,
    required this.results,
  });

  final String title;
  final String subtitle;
  final List<ActionOutcomeEntry> results;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: PlinkSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: text.titleMedium),
          const SizedBox(height: PlinkSpacing.s1),
          Text(subtitle, style: text.bodySmall),
          const SizedBox(height: PlinkSpacing.s3),
          for (final result in results) _ResultRow(result: result),
        ],
      ),
    );
  }
}

/// One outcome row of a dry-run/apply pass: the check/cross plus the target and
/// its change summary (or the failure cause).
///
/// A row can also be *marked* without having failed (#343): an action with a
/// best-effort step — the Smartschool create that also places its student — is
/// applied even when that step blew up, and this is the pass list the whole
/// September intake cohort is read back from, so the half that did not land is
/// spelled out here rather than left to the log panel.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final ActionOutcomeEntry result;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final failed = result.outcome == actions.ActionOutcome.failed;
    final List<String> warnings = result.warnings;
    final bool warned = !failed && warnings.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            switch ((failed, warned)) {
              (true, _) => Icons.close,
              (false, true) => Icons.warning_amber_outlined,
              (false, false) => Icons.check,
            },
            size: 16,
            color: failed || warned ? colors.error : colors.primary,
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  failed
                      ? '${result.target} — ${result.changes.summary}: '
                          '${result.error}'
                      : '${result.target} — ${result.changes.summary}',
                  style: text.bodySmall,
                ),
                for (final warning in warnings)
                  Text(
                    warning,
                    style: text.bodySmall?.copyWith(color: colors.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
