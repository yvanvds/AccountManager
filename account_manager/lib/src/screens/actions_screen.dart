import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart' show MaterializedAccount;
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
/// ## What it deliberately does not do
///
/// Nothing here applies an action the operator has not seen. The header's global
/// "Dry-run alles" / "Alles toepassen" pair went in #294 for exactly that
/// reason, and the flat list adds no replacement: the only apply is the per-card
/// pair inside the open details pane. School-wide bulk apply with its cohort
/// visible first is #296, and checkbox multi-select is #297.
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
        message: 'Azure AD is niet geconfigureerd voor deze build, dus de '
            'instellingenopslag en de connectoren zijn onbereikbaar. Geef de '
            'AAD --dart-define-waarden mee en start opnieuw op.',
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
    if (mounted) setState(() {});
  }

  /// Rebuilds for the newly-selected family and — when the family actually
  /// changed — drops the selection, which belongs to the list being left behind.
  void _onTabChanged() {
    final index = _tabs.index;
    if (index != _shownIndex) {
      _shownIndex = index;
      _selectedId = null;
    }
    if (mounted) setState(() {});
  }

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
  List<_AccountRow> _visibleRows(List<_AccountRow> rows) {
    final NameQuery query = _query;
    final core.Origin? origin = _system.origin;
    return <_AccountRow>[
      for (final r in rows)
        if ((!_onlyWithActions || r.hasWork) &&
            query.matches(r.searchText) &&
            (origin == null ||
                r.stateFor(origin) != SystemIndicatorState.inOrder))
          r,
    ];
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
    final bool wide = constraints.maxWidth >= _splitBreakpoint;
    final bool active = controller.linked != null;
    final rows = active ? _rows() : const <_AccountRow>[];
    final visible = _visibleRows(rows);
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
        Padding(
          padding: _hPad,
          child: _ActionsHeader(
            controller: controller,
            onlyWithActions: _onlyWithActions,
          ),
        ),
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
                child: _ListControls(
                  searchController: _search,
                  onlyWithActions: _onlyWithActions,
                  onOnlyWithActionsChanged: (v) =>
                      setState(() => _onlyWithActions = v),
                  sort: _sort,
                  onSortChanged: (v) => setState(() => _sort = v),
                  system: _system,
                  onSystemChanged: (v) => setState(() => _system = v),
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
          onTap: () => setState(() => _selectedId = row.id),
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
            _AccountDetail(controller: controller, row: selected),
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

/// The Actions title and how much work is pending — and, since #294, nothing
/// that acts on it.
///
/// It used to carry a global "Dry-run alles" / "Alles toepassen" pair that ran
/// every pending action of every family in every class in one pass. There is no
/// safe reading of that: the operator had seen none of the changes, and at a
/// September changeover the count behind the button is in the thousands. Its
/// confirmation named systems and a number, which is not the same as having
/// looked. Bulk itself is not gone for good — #296 gives it back with the cohort
/// on screen first — but the affordance that applied what nobody had read is.
///
/// The count line stays. It states how much work exists; it is not a button.
class _ActionsHeader extends StatelessWidget {
  const _ActionsHeader({
    required this.controller,
    required this.onlyWithActions,
  });

  final ReconcileController controller;

  /// Whether the work-list filter is on, so the sub-line describes the list the
  /// operator is actually looking at.
  final bool onlyWithActions;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final count = controller.totalPendingCount;
    // The shared stamp both action views carry (#247), so Acties and
    // Klasgroepen name the same generation the same way.
    final freshness = sharedViewFreshness(controller);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · acties', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Acties', style: text.headlineMedium),
        const SizedBox(height: PlinkSpacing.s2),
        Text(
          switch ((count, onlyWithActions)) {
            (0, _) => 'Geen openstaande acties.',
            (_, true) => '$count openstaande actie(s) — de lijst toont enkel '
                'accounts met werk.',
            (_, false) => '$count openstaande actie(s) — de lijst toont elk '
                'account. Drie groene vinkjes betekent dat het account overal '
                'juist staat.',
          },
          style: text.bodyMedium,
        ),
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(freshness, style: text.bodySmall),
        ],
      ],
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

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          key: const ValueKey('actions-search'),
          controller: searchController,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            // Same wording as the Wachtwoorden → Personeel box, which matches
            // the same way (#217): any part of the name, in any order.
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
        const SizedBox(height: PlinkSpacing.s2),
        Row(
          children: <Widget>[
            Switch(
              key: const ValueKey('actions-only-with-actions'),
              value: onlyWithActions,
              onChanged: onOnlyWithActionsChanged,
            ),
            const SizedBox(width: PlinkSpacing.s2),
            Expanded(
              child: Text('Toon enkel accounts met acties',
                  style: text.bodyMedium),
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
  });

  final _AccountRow row;
  final bool selected;
  final VoidCallback onTap;

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
  const _SystemRow({required this.row, this.keyPrefix = 'account-cell'});

  final _AccountRow row;

  /// What names these three cells. The details pane repeats the row's cells, so
  /// the two sets must not answer to one key: `find.byKey` would be ambiguous
  /// exactly when a row is selected, which is every interesting case.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    // Each cell is addressable on its own — `account-cell-<id>-<systeem>` —
    // exactly as a Klasgroepen row's cells are (`class-cell-<klas>-<systeem>`),
    // so a test can ask one row what it says about one system rather than
    // counting icons across three.
    Widget cell(core.Origin system) => Expanded(
          child: SystemIndicatorCell(
            key: ValueKey('$keyPrefix-${row.id}-${system.name}'),
            system: system,
            state: row.stateFor(system),
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

/// The details pane's content for one account: who it is, what each system says
/// about it, and every decision it raises.
///
/// The decisions are [entryDetail] verbatim — one block per decision, each led
/// by its own heading and its system, then the radios or the field diff, then
/// the verdict of the last pass that answers *that* decision (#281/#283). #300
/// made those blocks stand on their own precisely so this pane could reuse them
/// with no collapsed row above to have previewed anything.
class _AccountDetail extends StatelessWidget {
  const _AccountDetail({required this.controller, required this.row});

  final ReconcileController controller;
  final _AccountRow row;

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
        const SizedBox(height: PlinkSpacing.s3),
        // Repeated from the row on purpose: on a narrow window the list is not
        // on screen at all, so the pane has to be able to say what the account's
        // three systems look like.
        _SystemRow(row: row, keyPrefix: 'account-detail-cell'),
        for (final w in row.account.warnings) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s2),
          Text(w, style: text.bodySmall),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        if (entry == null)
          Text(
            'Geen openstaande beslissingen voor dit account.',
            style: text.bodyMedium,
          )
        else
          ...entryDetail(context, controller: controller, entry: entry),
      ],
    );
  }
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
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final ActionOutcomeEntry result;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final failed = result.outcome == actions.ActionOutcome.failed;

    return Padding(
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            failed ? Icons.close : Icons.check,
            size: 16,
            color: failed ? colors.error : colors.primary,
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Text(
              failed
                  ? '${result.target} — ${result.changes.summary}: '
                      '${result.error}'
                  : '${result.target} — ${result.changes.summary}',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
