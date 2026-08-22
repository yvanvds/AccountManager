import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_state/account_state.dart'
    show
        MaterializedAccount,
        Rollup,
        RollupLevel,
        candidateChoices,
        pendingDecisionCount;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../search/name_query.dart';
import 'action_tiles.dart';

// The wording helpers moved to the shared tile library when Klasgroepen became
// a screen of its own (#227); re-exported so they stay importable from here.
export 'action_tiles.dart' show applyConfirmationMessage, systemLabel;

/// The Actions view (#154): the pending-actions browser, split off the
/// Reconcile screen so a September changeover's hundreds/thousands of tiles no
/// longer render inline on one very long page.
///
/// Instead of one flat list, actions are browsed through the rollup drill-down
/// (#119) — grade-year → classroom for students since #210 dropped the
/// administrative school level, school → grade-year → classroom for staff: the
/// tree loads only the aggregate counts, and one classroom's actions are lazily
/// loaded (via `LinkedStore.readClassroom`) and built only when the operator
/// drills into it.
/// The per-class list itself renders through a lazy [SliverList] so only the
/// on-screen tiles build. Every apply starts from something the operator has
/// opened — one card, or one decision across the cohort shown above it; the
/// header's global "Dry-run alles" / "Alles toepassen" pair was removed in #294
/// precisely because it did not.
///
/// One view-wide switch above the family tab bar — "toon enkel accounts met
/// acties", on by default — collapses all of that to the work list (#226):
/// grade-years and classrooms with nothing pending are not rendered, and an
/// opened classroom lists only accounts with a pending action. What it holds
/// back is counted and named, so a year the operator expected is explained
/// rather than merely absent.
///
/// The tree is a single-open accordion whose open path outlives the detail view
/// (#235): drilling into a class and pressing **Overzicht** comes back to the
/// grade-year it was opened from, and opening another year closes the one that
/// was open. The path is held on the [ReconcileController], because while a
/// class is open the tree is not built at all.
///
/// Class groups are **not** here. The "Klasgroepen" node used to hang under the
/// Leerlingen tree and open the classes that raised something; since #227 that
/// is a top-level tab listing every class, which is a superset of what this node
/// showed — so it left rather than being maintained in two places.
///
/// A session with no linked view — passive, or one whose pass failed before it
/// linked — can only show the stored documents, so both drill-downs say so out
/// loud rather than quietly swapping in static cards (#214).
///
/// Every action line names the system it writes to (#298): one card can raise
/// work in two systems and the summaries do not always say where they land. The
/// three-way system indicator that reads *needs work* rather than *exists*
/// arrives with the flat list of #295; its vocabulary — and the principle it
/// shares with Klasgroepen — already lives in `system_indicator.dart`.
///
/// **Colour by work that can be done on this screen.** Klasgroepen highlights a
/// row on `MaterializedGroup.needsAttention`, informational notices included
/// (#225/#250), because there the manual notice *is* the work the operator
/// does on that screen. Here an informational candidate is a diagnosis of work
/// that happens elsewhere, so it colours nothing, raises no badge and puts no
/// row in the work list — `pendingDecisionCount` has counted it zero since
/// #245/#255, and the indicators apply that same predicate. The case that
/// forces the rule is `AzureClassGroupMembership`: Office 365 class membership
/// is a property of the group, so the write is one `SyncAzureClassGroupMembers`
/// per class on Klasgroepen. Colouring it here would paint ~3000 student rows
/// orange at the rollover for work this screen structurally cannot do. (#290
/// proposed the opposite and was closed; the action still declares
/// `canApply => false`.)
///
/// Shares the one memoized [ReconcileServices] (and so the one
/// [ReconcileController]) with the Reconcile and Passwords screens, so a sync
/// run on Reconcile populates the actions shown here.
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
/// bar rather than one combined rollup. Index order matches the Reconcile
/// overview's category order (Leerlingen, then Personeel).
enum _ActionFamilyTab { leerlingen, personeel }

/// One family tab's drill-down after the global "toon enkel accounts met acties"
/// filter has been applied (#226): the nodes that survive, plus a count of what
/// it removed so the tree can say why a year is missing rather than silently
/// shrinking.
class _FilteredTree {
  const _FilteredTree({
    required this.roots,
    required this.hidden,
  });

  /// The top-level accordion nodes still worth rendering.
  final List<Rollup> roots;

  /// How many nodes disappeared from what the tree would otherwise show —
  /// counted as the operator would browse it, so a hidden year counts once
  /// rather than once per classroom inside it.
  final int hidden;
}

/// The seam the drill-down's expandable nodes are driven through (#235): where
/// a node's persistent [ExpansibleController] comes from, whether it is the open
/// one at its depth, and where a tap on it is recorded.
///
/// Passed down rather than reached for, so [_DrillDownSection] and [_GradeNode]
/// stay the stateless projections of the rollups they already were — the open
/// path itself lives on the [ReconcileController], one level above the tree.
class _Accordion {
  const _Accordion({
    required this.controllerFor,
    required this.isOpen,
    required this.onToggled,
  });

  final ExpansibleController Function(String node) controllerFor;

  /// Whether [node] is the open node at that depth of the tree — 0 for a
  /// top-level node, 1 for a grade-year nested under the staff school.
  final bool Function(String node, int depth) isOpen;

  final void Function(String node, int depth, bool open) onToggled;
}

class _ActionsBody extends StatefulWidget {
  const _ActionsBody({required this.controller});

  final ReconcileController controller;

  @override
  State<_ActionsBody> createState() => _ActionsBodyState();
}

class _ActionsBodyState extends State<_ActionsBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _shownIndex = 0;

  /// The **global** Acties filter (#226), promoted out of the per-classroom bar
  /// it was born in (#187): with the switch on, everything below it shows only
  /// what carries an applyable action — grade-year and classroom nodes with a
  /// zero pending count are not rendered, a grade-year left with no visible
  /// classroom goes with them, and an opened classroom lists only accounts with
  /// a pending action.
  ///
  /// One decision per session rather than one per class, so it is deliberately
  /// **not** reset by a family tab change ([_onTabChanged]): the operator's mode
  /// outlives whichever tab they happen to be on. Defaults on — the Acties view
  /// exists to answer "what needs doing?", and the full inventory is the
  /// exception, not the starting point.
  bool _onlyWithActions = true;

  /// The Personeel name search (#187/#217). Unlike [_onlyWithActions] this is a
  /// per-list lookup, not a mode, so it stays inside the opened classroom and is
  /// cleared on every family tab change.
  final TextEditingController _search = TextEditingController();

  /// One [ExpansibleController] per accordion node the operator has met this
  /// session, keyed by [_rollupNodeKey] (#235).
  ///
  /// An `ExpansionTile` reads [ExpansionTile.initiallyExpanded] once, in its
  /// `initState`, and thereafter owns its own open/closed state — so nothing
  /// declarative can close the year that was open when another is tapped, and
  /// nothing survives the tile being disposed. Both halves of #235 need a handle
  /// that outlives the tile, which is exactly what an injected controller is:
  /// held here, it carries a node's expansion across the detail view, and it is
  /// the one thing that can collapse a sibling on demand.
  final Map<String, ExpansibleController> _tiles =
      <String, ExpansibleController>{};

  ReconcileController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _ActionFamilyTab.values.length, vsync: this)
      ..addListener(_onTabChanged);
    _search.addListener(_onSearchChanged);
    // Anything that moves the open path without going through a tap — a re-sync
    // clearing it (#235) — is picked up here and pushed into the tiles.
    controller.addListener(_syncExpansion);
  }

  @override
  void dispose() {
    controller.removeListener(_syncExpansion);
    for (final ExpansibleController tile in _tiles.values) {
      tile.dispose();
    }
    _tiles.clear();
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

  /// The drill-down tree's accordion seam (#235), handed to the widgets that
  /// build the expandable nodes.
  _Accordion get _accordion => _Accordion(
        controllerFor: _tileFor,
        isOpen: _isNodeOpen,
        onToggled: _onNodeToggled,
      );

  /// The persistent controller of one accordion node, created on first render.
  /// Safe to call from `build`: a controller nobody is listening to yet cannot
  /// schedule a rebuild.
  ExpansibleController _tileFor(String node) => _tiles.putIfAbsent(node, () {
        final ExpansibleController tile = ExpansibleController();
        if (_isNodeOpenKey(node)) tile.expand();
        return tile;
      });

  /// Whether [node] is the open node at [depth] of
  /// [ReconcileController.expandedPath].
  bool _isNodeOpen(String node, int depth) {
    final List<String> path = controller.expandedPath;
    return path.length > depth && path[depth] == node;
  }

  bool _isNodeOpenKey(String node) => controller.expandedPath.contains(node);

  /// Records the operator opening or closing one accordion node.
  ///
  /// Opening replaces whatever sat at that depth — which is what makes the tree
  /// single-open — and truncates everything below it, since a node's children
  /// go away with it. Closing truncates from that depth. The path setter
  /// notifies, so [_syncExpansion] does the actual collapsing of the sibling
  /// that just lost its place.
  void _onNodeToggled(String node, int depth, bool open) {
    final List<String> path = controller.expandedPath;
    if (open) {
      controller.expandedPath = <String>[...path.take(depth), node];
    } else if (_isNodeOpen(node, depth)) {
      controller.expandedPath = path.take(depth).toList();
    }
  }

  /// Brings every tile controller back in line with the open path. Idempotent —
  /// [ExpansibleController.expand] / [ExpansibleController.collapse] are no-ops
  /// on a controller that already agrees — so it is safe to run on every
  /// controller notification.
  void _syncExpansion() {
    if (!mounted) return;
    final Set<String> open = controller.expandedPath.toSet();
    for (final MapEntry<String, ExpansibleController> tile in _tiles.entries) {
      if (open.contains(tile.key)) {
        tile.value.expand();
      } else {
        tile.value.collapse();
      }
    }
  }

  /// Forgets the tail of the open path the global filter has just stopped
  /// rendering (#226/#235).
  ///
  /// Without this, a year the operator opened with the filter off would come
  /// back open — and, having been invisible in between, unexpectedly so — the
  /// next time they switched the filter off again.
  void _pruneExpansion() {
    final List<String> path = controller.expandedPath;
    if (path.isEmpty) return;
    final Set<String> visible = _visibleNodeKeys();
    var keep = 0;
    while (keep < path.length && visible.contains(path[keep])) {
      keep++;
    }
    if (keep < path.length) controller.expandedPath = path.take(keep).toList();
  }

  /// The keys of every accordion node either family tree would render under the
  /// current filter — both tabs, because the open path outlives a tab change.
  Set<String> _visibleNodeKeys() {
    final keys = <String>{
      for (final root in _studentTree().roots) _rollupNodeKey(root),
    };
    for (final root in _staffTree().roots) {
      keys.add(_rollupNodeKey(root));
      for (final grade in controller.childrenOf(root.key)) {
        if (_keepGrade(grade)) keys.add(_rollupNodeKey(grade));
      }
    }
    return keys;
  }

  /// Whether the Personeel family tab is the selected one — the only tab that
  /// carries a name search (#187).
  bool get _staffTab => _tabs.index == _ActionFamilyTab.personeel.index;

  /// The active name search, parsed (empty on any non-Personeel tab, which
  /// carries no search box).
  ///
  /// A single searchbox matches the person's display name ("Voornaam Naam"),
  /// and since #217 the needle is split on whitespace with every part required
  /// — the same [NameQuery] the Wachtwoorden → Personeel box uses (#215), so
  /// the two Personeel searches one tab apart behave identically. Per-part
  /// matching is what makes either name order work: "peeters jan" finds
  /// "Jan Peeters", which as one contiguous substring found nobody.
  NameQuery get _query => NameQuery(_staffTab ? _search.text : '');

  /// The passive-session classroom accounts narrowed by the active filters: the
  /// "only with actions" toggle keeps just the accounts with an applyable
  /// candidate (the same `hasPending` predicate the rollup pending counts and
  /// the tile badge use), and the name search keeps matching display names.
  List<MaterializedAccount> _filterAccounts(
      List<MaterializedAccount> accounts) {
    final query = _query;
    return [
      for (final a in accounts)
        if ((!_onlyWithActions || a.hasPending) && query.matches(a.label)) a,
    ];
  }

  /// The active-session pending entries narrowed by the name search. The "only
  /// with actions" toggle is a no-op here — every pending entry already carries
  /// an action — so only the search filters (#187).
  ///
  /// The cohorts are grouped *from this result* rather than filtered afterwards
  /// (#292), so a bulk header can only ever cover accounts the search left on
  /// screen: label, confirmation scope and write come from one list, which is
  /// the standing rule since #252.
  List<PendingAccountEntry> _filterEntries(
    List<PendingAccountEntry> entries,
  ) {
    final query = _query;
    if (query.isEmpty) return entries;
    return <PendingAccountEntry>[
      for (final e in entries)
        if (query.matches(e.target)) e,
    ];
  }

  /// Rebuilds the sliver content for the newly-selected family, and — when the
  /// selected family actually changed — closes any open drill-down so each tab
  /// opens at its own overview rather than showing the other family's detail.
  ///
  /// The name search is cleared, because it is a lookup inside the list that is
  /// being left behind. [_onlyWithActions] is **not**: since #226 it is the
  /// view-wide mode, set once above the tab bar, and resetting it here would put
  /// the switch and the tree it governs out of step on every tab change.
  void _onTabChanged() {
    final index = _tabs.index;
    if (index != _shownIndex) {
      _shownIndex = index;
      _search.clear();
      if (controller.selectedClassroom != null) controller.closeClassroom();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: CustomScrollView(slivers: _slivers(context)),
          ),
        );
      },
    );
  }

  static const EdgeInsets _hPad =
      EdgeInsets.symmetric(horizontal: PlinkSpacing.s6);

  static Widget _section(Widget child) => SliverPadding(
        padding: _hPad,
        sliver: SliverToBoxAdapter(child: child),
      );

  static SliverToBoxAdapter _gap(double height) =>
      SliverToBoxAdapter(child: SizedBox(height: height));

  /// Whether a grade-year or classroom node survives the global filter (#226).
  ///
  /// [Rollup.pendingCount] is already "how many applyable actions sit under this
  /// node", so hiding is a pure render-time projection of the stored overview —
  /// no store or materializer change is involved.
  bool _keepNode(Rollup r) => !_onlyWithActions || r.pendingCount > 0;

  /// Whether a nested grade-year node (the Personeel tab's middle level) keeps
  /// at least one visible classroom. A grade that would open onto nothing is
  /// hidden as a whole rather than left as an empty accordion.
  bool _keepGrade(Rollup grade) =>
      !_onlyWithActions || controller.childrenOf(grade.key).any(_keepNode);

  /// The Leerlingen drill-down after the global filter (#226): the merged
  /// grade-years that still hold a visible classroom, and how many nodes went
  /// missing so the tree can say so.
  ///
  /// The "Klasgroepen" node used to hang below these roots and open a list of
  /// the classes with work. It is a top-level tab of its own since #227 — a full
  /// class inventory, not just the ones that raised something — so it is not
  /// rendered here any more: the same list must not be maintained in two places,
  /// and the tab is the superset.
  _FilteredTree _studentTree() {
    final roots = <Rollup>[];
    var hidden = 0;
    for (final root in controller.studentRollups) {
      final classrooms = controller.studentChildrenOf(root);
      final kept = classrooms.where(_keepNode).length;
      if (_onlyWithActions && kept == 0) {
        // The year itself disappears rather than opening onto an empty list.
        hidden++;
        continue;
      }
      roots.add(root);
      hidden += classrooms.length - kept;
    }
    return _FilteredTree(roots: roots, hidden: hidden);
  }

  /// The Personeel drill-down after the global filter (#226): the staff school
  /// node, kept only while some grade below it still holds a visible classroom.
  _FilteredTree _staffTree() {
    final root = controller.staffSchoolRollup;
    if (root == null) return const _FilteredTree(roots: <Rollup>[], hidden: 0);
    var hidden = 0;
    var keptGrades = 0;
    for (final grade in controller.childrenOf(root.key)) {
      final classrooms = controller.childrenOf(grade.key);
      final kept = classrooms.where(_keepNode).length;
      if (_onlyWithActions && kept == 0) {
        hidden++;
        continue;
      }
      keptGrades++;
      hidden += classrooms.length - kept;
    }
    if (_onlyWithActions && keptGrades == 0) {
      return const _FilteredTree(roots: <Rollup>[], hidden: 1);
    }
    return _FilteredTree(roots: <Rollup>[root], hidden: hidden);
  }

  List<Widget> _slivers(BuildContext context) {
    final slivers = <Widget>[
      _gap(PlinkSpacing.s6),
      _section(_ActionsHeader(
        controller: controller,
        onlyWithActions: _onlyWithActions,
      )),
      _gap(PlinkSpacing.s4),
      // The one place the filter is set (#226): above the family tab bar, so it
      // governs both tabs, the drill-down, and every classroom opened from it.
      _section(_ActionsFilterBar(
        onlyWithActions: _onlyWithActions,
        onChanged: (v) {
          setState(() => _onlyWithActions = v);
          // Pruned after the flag has flipped, against the tree the operator is
          // about to see (#235).
          _pruneExpansion();
        },
      )),
      _gap(PlinkSpacing.s4),
      _section(_FamilyTabBar(controller: controller, tabs: _tabs)),
      _gap(PlinkSpacing.s4),
    ];
    final staffTab = _tabs.index == _ActionFamilyTab.personeel.index;
    if (controller.selectedClassroom != null) {
      slivers.addAll(_classroomSlivers(context));
    } else if (controller.hasOverview) {
      // Partition the drill-down by family: the Personeel tab shows only the
      // synthetic staff school node (school → grade → classroom, unchanged); the
      // Leerlingen tab opens straight on the merged grade-years. Class groups
      // are a tab of their own since #227.
      final tree = staffTab ? _staffTree() : _studentTree();
      slivers.add(_section(staffTab
          ? _DrillDownSection(
              controller: controller,
              accordion: _accordion,
              roots: tree.roots,
              hidden: tree.hidden,
              filtering: _onlyWithActions,
              emptyLabel: 'Geen openstaande personeelsacties.',
              childrenOf: (root) => <Widget>[
                for (final grade in controller.childrenOf(root.key))
                  if (_keepGrade(grade))
                    _GradeNode(
                      controller: controller,
                      accordion: _accordion,
                      grade: grade,
                      onlyWithActions: _onlyWithActions,
                    ),
              ],
            )
          : _DrillDownSection(
              controller: controller,
              accordion: _accordion,
              roots: tree.roots,
              hidden: tree.hidden,
              filtering: _onlyWithActions,
              emptyLabel: 'Nog geen gematerialiseerd overzicht.',
              childrenOf: (root) => <Widget>[
                for (final classroom in controller.studentChildrenOf(root))
                  if (_keepNode(classroom))
                    _ClassroomTile(
                      controller: controller,
                      classroom: classroom,
                      indent: PlinkSpacing.s5,
                    ),
              ],
            )));
    } else {
      slivers.add(_section(_EmptyState(controller: controller)));
    }
    slivers
      ..addAll(_resultsSlivers())
      ..add(_gap(PlinkSpacing.s6));
    return slivers;
  }

  /// The drilled-into classroom: a back header, then either the live
  /// interactive entry tiles for that class (active session) or the read-only
  /// materialized account docs (passive session) — both through a lazy
  /// [SliverList] so only the on-screen tiles build (#154).
  ///
  /// The read-only half announces itself (#214): without a linked view there is
  /// nothing to choose, dry-run or apply, and the static account cards are
  /// otherwise indistinguishable from an interactive list whose taps stopped
  /// working.
  List<Widget> _classroomSlivers(BuildContext context) {
    final classroom = controller.selectedClassroom;
    final slivers = <Widget>[
      _section(_DetailHeader(
        backKey: const ValueKey('actions-classroom-back'),
        title: classroom?.label ?? '',
        onBack: controller.closeClassroom,
      )),
      _gap(PlinkSpacing.s3),
    ];
    if (controller.loadingClassroom) {
      return slivers..add(_section(const LinearProgressIndicator()));
    }
    slivers.addAll(_stateNoticeSlivers());

    // Only the Personeel tab carries a per-list lookup; the mode switch that
    // used to sit beside it now lives once, at the top of the view (#226).
    final searchSlivers = _staffTab
        ? <Widget>[
            _section(_ClassroomSearchBar(searchController: _search)),
            _gap(PlinkSpacing.s3),
          ]
        : const <Widget>[];

    if (controller.linked != null) {
      final all = controller.classroomPendingEntries;
      if (all.isEmpty) {
        return slivers
          ..add(_section(const EmptyLine('Geen openstaande acties in deze '
              'klas.')));
      }
      final shown = _filterEntries(all);
      final rows =
          pendingRows(ReconcileController.situationCohorts(shown), shown);
      slivers
        ..addAll(searchSlivers)
        ..add(rows.isEmpty
            ? _section(const EmptyLine(_noMatchLabel))
            : _rowsSliver(rows));
    } else {
      final accounts = controller.classroomAccounts;
      if (accounts == null || accounts.isEmpty) {
        return slivers
          ..add(_section(const EmptyLine('Geen accounts in deze klas.')));
      }
      final filtered = _filterAccounts(accounts);
      slivers
        ..addAll(searchSlivers)
        ..add(filtered.isEmpty
            ? _section(const EmptyLine(_noMatchLabel))
            : SliverPadding(
                padding: _hPad,
                sliver: SliverList.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      _AccountTile(account: filtered[index]),
                ),
              ));
    }
    return slivers;
  }

  /// The line shown when the active filters (toggle and/or search) hide every
  /// account in the open classroom (#187) — distinct from the "no accounts at
  /// all" empty state so the operator knows to relax the filter.
  static const String _noMatchLabel =
      'Geen accounts die aan de filter voldoen.';

  /// The announcement shown above either drill-down about where this session's
  /// view comes from.
  ///
  /// Two of them, and never both: [ReadOnlyNotice] when there is no linked view
  /// to act on (#214) — a session refused the shared seed, or one whose
  /// sync/drift pass failed before it could link — and [SharedStateNotice] when
  /// the tiles below *are* interactive but were built from the cold seed a
  /// colleague's sync left behind (#287). Empty only in a session that pulled
  /// for itself.
  List<Widget> _stateNoticeSlivers() {
    final Widget? notice = controller.linked == null
        ? ReadOnlyNotice(controller: controller)
        : controller.adoptedFrom == null
            ? null
            : SharedStateNotice(controller: controller);
    if (notice == null) return const <Widget>[];
    return <Widget>[_section(notice), _gap(PlinkSpacing.s3)];
  }

  /// A lazy sliver over pending [rows] (situation headers + entry tiles) — the
  /// carried-over virtualized list from the old flat pending section (#111).
  Widget _rowsSliver(List<PendingRow> rows) => SliverPadding(
        padding: _hPad,
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            return switch (row) {
              SituationHeaderRow(:final cohort) =>
                SituationHeader(controller: controller, cohort: cohort),
              EntryRow(:final entry) =>
                PendingEntryTile(controller: controller, entry: entry),
            };
          },
        ),
      );

  List<Widget> _resultsSlivers() {
    final dry = controller.dryRunResults;
    final applied = controller.applyResults;
    final slivers = <Widget>[];
    if (dry != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSectionSlivers(
          title: 'Resultaat van de dry-run',
          subtitle: 'Er is niets geschreven. Dit is wat toepassen zou doen.',
          results: dry,
        ));
    }
    if (applied != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSectionSlivers(
          title: 'Resultaat van het toepassen',
          subtitle: applyResultsSubtitle(applied),
          results: applied,
        ));
    }
    return slivers;
  }

  List<Widget> _resultSectionSlivers({
    required String title,
    required String subtitle,
    required List<ActionOutcomeEntry> results,
  }) =>
      <Widget>[
        _section(_ResultsHeader(title: title, subtitle: subtitle)),
        SliverPadding(
          padding: _hPad,
          sliver: SliverList.builder(
            itemCount: results.length,
            itemBuilder: (context, index) => _ResultRow(result: results[index]),
          ),
        ),
      ];
}

/// The Actions title and how much work is pending — and, since #294, nothing
/// that acts on it.
///
/// It used to carry a global "Dry-run alles" / "Alles toepassen" pair that ran
/// every pending action of every family in every class in one pass. There is no
/// safe reading of that: the drill-down below is collapsed, so the operator had
/// seen none of the changes, and at a September changeover the count behind the
/// button is in the thousands. Its confirmation named systems and a number,
/// which is not the same as having looked. Bulk itself is not gone — it lives on
/// the per-decision cohort header, where the cohort is on screen and one action
/// deep — but the affordance that applied what nobody had read is.
///
/// The count line stays. It states how much work exists; it is not a button.
class _ActionsHeader extends StatelessWidget {
  const _ActionsHeader({
    required this.controller,
    required this.onlyWithActions,
  });

  final ReconcileController controller;

  /// Whether the global filter is on, so the sub-line describes the tree the
  /// operator is actually looking at (#226) — with the filter on there are no
  /// ticked-off classes left to explain.
  final bool onlyWithActions;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final count = controller.totalPendingCount;

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
            (_, true) =>
              '$count openstaande actie(s) — enkel jaren en klassen met '
                  'acties worden getoond.',
            (_, false) => '$count openstaande actie(s) — blader per jaar en '
                'klas. Klassen zonder acties tonen een vinkje.',
          },
          style: text.bodyMedium,
        ),
      ],
    );
  }
}

/// The one, view-wide "toon enkel accounts met acties" switch (#226).
///
/// It sits above the family tab bar, so the single decision it records governs
/// both families, the whole jaar → klas drill-down, and every classroom opened
/// from it. Its per-classroom ancestor (#187) had to be re-flipped in every
/// class the operator opened and was reset on every tab change, which is why it
/// never actually collapsed the tree to the work list.
class _ActionsFilterBar extends StatelessWidget {
  const _ActionsFilterBar({
    required this.onlyWithActions,
    required this.onChanged,
  });

  final bool onlyWithActions;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Switch(
          key: const ValueKey('actions-only-with-actions'),
          value: onlyWithActions,
          onChanged: onChanged,
        ),
        const SizedBox(width: PlinkSpacing.s2),
        Expanded(
          child: Text('Toon enkel accounts met acties', style: text.bodyMedium),
        ),
      ],
    );
  }
}

/// The horizontal family tab bar (#179): switches the drill-down below between
/// the Leerlingen (student + class-group) and Personeel (staff) action
/// families, each carrying a pending-count badge so the operator sees where the
/// work sits without opening both. Staff and student actions are reviewed as
/// separate workflows, mirroring the legacy WPF app.
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

/// The empty state before any sync/overview exists: nothing to browse yet.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Text(
      'Nog geen gematerialiseerd overzicht. Synchroniseer op het tabblad '
      'Synchronisatie om openstaande acties per klas te zien.',
      style: text.bodyMedium,
    );
  }
}

/// The stable widget key of one rollup node, by level — so a test (and the
/// element tree) names a node the same way wherever it is rendered.
String _rollupNodeKey(Rollup r) => switch (r.level) {
      RollupLevel.school => 'rollup-school-${r.key}',
      RollupLevel.gradeYear => 'rollup-grade-${r.key}',
      RollupLevel.classroom => 'rollup-class-${r.key}',
      RollupLevel.groups => 'rollup-groups',
    };

/// The materialized overview (#115/#119): the drill-down driven by the stored
/// rollups, so it renders from the shared state even in a passive session that
/// never pulled or re-linked. Tapping a classroom lazily loads just that node's
/// actions (#154).
///
/// The "Klasgroepen" node used to sit below the student roots and open the
/// classes with work. It became a top-level tab of its own in #227 — the full
/// class inventory rather than a list of changes — so it is gone from here: the
/// same list must not be maintained in two places.
///
/// The tree is two levels deep on the Leerlingen tab (#210): merged grade-year →
/// classroom, with no school node — the WISA school split is administrative, so
/// drilling through it never presented a choice. The Personeel tab keeps its
/// stored school → grade-year → classroom shape; both are driven from the very
/// same rollups, only projected differently by [childrenOf].
class _DrillDownSection extends StatelessWidget {
  const _DrillDownSection({
    required this.controller,
    required this.accordion,
    required this.roots,
    required this.emptyLabel,
    required this.childrenOf,
    required this.hidden,
    required this.filtering,
  });

  final ReconcileController controller;

  /// Drives the top-level nodes as a single-open accordion whose open node
  /// outlives a drill-down (#235).
  final _Accordion accordion;

  /// The top-level accordion nodes: the merged grade-years plus
  /// "Niet toegewezen" on the Leerlingen tab, the single staff school node on
  /// the Personeel tab (#179/#210).
  final List<Rollup> roots;

  /// Builds the expanded children of one root — classroom tiles under a merged
  /// grade-year, the nested grade nodes under the staff school.
  final List<Widget> Function(Rollup root) childrenOf;

  /// The message shown when this tab has nothing to browse.
  final String emptyLabel;

  /// How many nodes the global filter removed from this tab's tree (#226).
  final int hidden;

  /// Whether the global filter is on — the difference between "there is nothing
  /// here" and "the filter is holding it back", which is what tells an operator
  /// why a year they expected is missing.
  final bool filtering;

  /// The footnote under a tree the filter has thinned out, so a missing year is
  /// explained rather than merely absent.
  String get _hiddenNote =>
      'Verborgen door de filter: $hidden zonder openstaande acties.';

  /// The stand-in for the tree when the filter hid every last node — distinct
  /// from [emptyLabel], which means the shared view holds nothing at all.
  String get _allHiddenNote =>
      'Alles is verborgen door de filter: $hidden zonder openstaande acties. '
      'Zet de filter af voor het volledige overzicht.';

  /// One top-level accordion node (depth 0), driven by [accordion] rather than
  /// by the `ExpansionTile`'s own state (#235) — so the year the operator drilled
  /// a class out of is still open when they come back, and opening another one
  /// closes it.
  Widget _rootTile(BuildContext context, Rollup root, Color hairline) {
    final TextTheme text = Theme.of(context).textTheme;
    final String node = _rollupNodeKey(root);
    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: ExpansionTile(
        key: ValueKey(node),
        controller: accordion.controllerFor(node),
        initiallyExpanded: accordion.isOpen(node, 0),
        onExpansionChanged: (open) => accordion.onToggled(node, 0, open),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(root.label, style: text.bodyLarge),
        trailing: PendingBadge(count: root.pendingCount),
        children: childrenOf(root),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    // The shared stamp both views carry (#247), so Acties and Klasgroepen name
    // the same generation the same way.
    final freshness = sharedViewFreshness(controller);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Overzicht', style: text.titleMedium),
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(freshness, style: text.bodySmall),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        if (roots.isEmpty)
          filtering && hidden > 0
              ? Text(
                  _allHiddenNote,
                  key: const ValueKey('actions-filter-all-hidden'),
                  style: text.bodyMedium,
                )
              : Text(emptyLabel, style: text.bodyMedium)
        else ...<Widget>[
          for (final root in roots) _rootTile(context, root, hairline),
          if (filtering && hidden > 0) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s1),
            Text(
              _hiddenNote,
              key: const ValueKey('actions-filter-hidden'),
              style: text.bodySmall,
            ),
          ],
        ],
      ],
    );
  }
}

/// A nested grade-year node inside a school node — the middle level of the
/// Personeel tab's stored tree, which #210 left as it was. The student tree has
/// no school to nest under, so its grade-years are [_DrillDownSection] roots and
/// carry their "Jaar N" label from [ReconcileController.gradeNodeLabel] instead.
class _GradeNode extends StatelessWidget {
  const _GradeNode({
    required this.controller,
    required this.accordion,
    required this.grade,
    required this.onlyWithActions,
  });

  final ReconcileController controller;

  /// Drives this node at depth 1 (#235). The depth is what keeps the staff tree
  /// usable: opening a grade-year replaces its *sibling* year, never the school
  /// node above it — which single-open on one flat key would have collapsed out
  /// from under the year the operator just opened.
  final _Accordion accordion;

  final Rollup grade;

  /// Whether the global filter is on, in which case only the classrooms of this
  /// year that carry an applyable action are listed (#226).
  final bool onlyWithActions;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String node = _rollupNodeKey(grade);
    return ExpansionTile(
      key: ValueKey(node),
      controller: accordion.controllerFor(node),
      initiallyExpanded: accordion.isOpen(node, 1),
      onExpansionChanged: (open) => accordion.onToggled(node, 1, open),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: PlinkSpacing.s5, right: 16),
      title: Text('Jaar ${grade.label}', style: text.bodyMedium),
      trailing: PendingBadge(count: grade.pendingCount),
      children: <Widget>[
        for (final classroom in controller.childrenOf(grade.key))
          if (!onlyWithActions || classroom.pendingCount > 0)
            _ClassroomTile(
              controller: controller,
              classroom: classroom,
              indent: PlinkSpacing.s6,
            ),
      ],
    );
  }
}

/// A leaf classroom node: tapping it opens that class's accounts, which reads
/// exactly one Cosmos partition ([Rollup.school]). Indented to whatever depth the
/// enclosing tree puts it at — one level under a merged grade-year on the
/// Leerlingen tab, two under school → grade-year on the Personeel tab.
class _ClassroomTile extends StatelessWidget {
  const _ClassroomTile({
    required this.controller,
    required this.classroom,
    required this.indent,
  });

  final ReconcileController controller;
  final Rollup classroom;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return ListTile(
      key: ValueKey(_rollupNodeKey(classroom)),
      contentPadding: EdgeInsets.only(left: indent, right: 16),
      title: Text(classroom.label, style: text.bodyMedium),
      subtitle:
          Text('${classroom.accountCount} account(s)', style: text.bodySmall),
      trailing: PendingBadge(count: classroom.pendingCount),
      onTap: () => controller.openClassroom(classroom),
    );
  }
}

/// The back-to-overview header of a drilled-into classroom / group node.
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.backKey,
    required this.title,
    required this.onBack,
  });

  final Key backKey;
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        TextButton.icon(
          key: backKey,
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Overzicht'),
        ),
        const SizedBox(width: PlinkSpacing.s2),
        Text(title, style: text.titleMedium),
      ],
    );
  }
}

/// The name search above a drilled-into classroom's account list, on the
/// Personeel tab only (#187/#217).
///
/// The "toon enkel accounts met acties" toggle that used to sit beside it moved
/// to the top of the view in #226 — it is a mode, and the filter must not be
/// settable in two places. A name search is the opposite: a lookup inside *this*
/// list, so it stays here.
class _ClassroomSearchBar extends StatelessWidget {
  const _ClassroomSearchBar({required this.searchController});

  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('actions-search'),
      controller: searchController,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        // Same wording as the Wachtwoorden → Personeel box, which matches the
        // same way (#217): any part of the name, in any order.
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
    );
  }
}

/// One account's read-only summary in a passive-session classroom drill-down:
/// the systems it lives in and its candidate action summaries (no live actions
/// to apply without a sync this session).
///
/// Styled as the inert card it is (#214): a muted lock beside the pending
/// badge, and the candidate lines in the disabled colour, so a card that offers
/// no choice, dry-run or apply does not sit next to the interactive
/// [PendingEntryTile] looking identical to it. [ReadOnlyNotice] above the
/// list carries the explanation.
class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account});

  final MaterializedAccount account;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    final Color muted = Theme.of(context).disabledColor;
    final systems = <String>[
      if (account.inWisa) 'WISA',
      if (account.inSmartschool) 'Smartschool',
      if (account.inAzure) 'Azure',
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(account.label, style: text.bodyLarge)),
              const ReadOnlyLock(),
              const SizedBox(width: PlinkSpacing.s2),
              PendingBadge(count: pendingDecisionCount(account.candidates)),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Wrap(
            spacing: PlinkSpacing.s2,
            children: <Widget>[for (final s in systems) PlinkBadge(s)],
          ),
          for (final w in account.warnings)
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: Text(w, style: text.bodySmall),
            ),
          // One line per *decision* (#251), worded exactly as the interactive
          // tile words it: a departed student's unregister / delete pair is one
          // either/or, so it reads as the single choice the interactive tile
          // shows — never as two bullets that both look due — and an
          // informational candidate is marked "(manueel)" (#255).
          for (final c in candidateChoices(account.candidates))
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: ActionLine(
                system: c.selected.system,
                line: readOnlyCandidateLine(c),
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The header of a dry-run/apply result set: its title and subtitle, above the
/// lazy list of outcome rows.
class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s1),
        Text(subtitle, style: text.bodySmall),
        const SizedBox(height: PlinkSpacing.s3),
      ],
    );
  }
}

/// One outcome row of a dry-run/apply pass: the check/cross plus the target and
/// its change summary (or the failure cause). Built lazily by the results
/// [SliverList].
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
