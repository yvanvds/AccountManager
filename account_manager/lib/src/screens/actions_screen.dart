import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart'
    show
        CandidateAction,
        MaterializedAccount,
        MaterializedGroup,
        Rollup,
        RollupLevel,
        candidateChoices,
        pendingDecisionCount;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../format/timestamps.dart';
import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../search/name_query.dart';

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
/// on-screen tiles build. The global "Dry-run all" / "Apply all" act on every
/// pending entry across all classes.
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
/// A session with no linked view — passive, or one whose pass failed before it
/// linked — can only show the stored documents, so both drill-downs say so out
/// loud rather than quietly swapping in static cards (#214).
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
      // Passive-session read (#115): show the shared overview from the store
      // without pulling or re-linking. Idempotent with the Reconcile screen's
      // own read (both share the one controller). Fire-and-forget.
      unawaited(services.controller.loadOverview());
    } on Object catch (e) {
      if (mounted) setState(() => _bootstrapError = e);
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bootstrap == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Not configured',
        message: 'Azure AD is not configured for this build, so the settings '
            'store and connectors cannot be reached. Provide the AAD '
            '--dart-define values and restart.',
      );
    }
    final error = _bootstrapError;
    if (error != null) {
      final retryNote = _attempts > 1 ? '\n\n(Attempt $_attempts failed.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Could not prepare the actions screen',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('actions-bootstrap-retry'),
          onPressed: _bootstrap,
          child: const Text('Try again'),
        ),
      );
    }
    final services = _services;
    if (_bootstrapping || services == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · acties',
        title: 'Preparing…',
        message: 'Loading the settings and connection profiles.',
        progress: true,
      );
    }
    return _ActionsBody(controller: services.controller);
  }
}

/// One row of a per-classroom (or per-group) pending list: a same-situation
/// bulk header or a single account entry. Flattening the situation → entries
/// tree into a linear list lets a lazy [SliverList] build only the on-screen
/// rows (#111/#154).
sealed class _PendingRow {
  const _PendingRow();
}

class _SituationHeaderRow extends _PendingRow {
  const _SituationHeaderRow(this.entries);

  final List<PendingAccountEntry> entries;
}

class _EntryRow extends _PendingRow {
  const _EntryRow(this.entry);

  final PendingAccountEntry entry;
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
    this.groups,
    required this.hidden,
  });

  /// The top-level accordion nodes still worth rendering.
  final List<Rollup> roots;

  /// The "Klasgroepen" node, or `null` when this tab carries none.
  final Rollup? groups;

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

  /// The active-session pending situations narrowed by the name search. The
  /// "only with actions" toggle is a no-op here — every pending entry already
  /// carries an action — so only the search filters, dropping any subset left
  /// empty so the same-situation headers stay in sync (#187).
  List<List<PendingAccountEntry>> _filterSituations(
    List<List<PendingAccountEntry>> situations,
  ) {
    final query = _query;
    if (query.isEmpty) return situations;
    final out = <List<PendingAccountEntry>>[];
    for (final subset in situations) {
      final kept = <PendingAccountEntry>[
        for (final e in subset)
          if (query.matches(e.target)) e,
      ];
      if (kept.isNotEmpty) out.add(kept);
    }
    return out;
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
      if (controller.showingGroups) controller.closeGroups();
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

  /// Whether the "Klasgroepen" node survives the global filter (#226).
  ///
  /// Deliberately **not** `pendingCount > 0`, unlike every other node. A class
  /// group's candidates are not all applyable: since #225 a class can carry an
  /// informational-only notice (`ClassExistsAsSmartschoolGroup` and friends),
  /// which is manual work the operator still has to do — it just has no
  /// automated write, so it adds nothing to the pending count. Filtering this
  /// node on the pending count would hide exactly the notices #225 exists to
  /// surface. A group document is only ever written for a class that needs
  /// attention, so the node stays as long as it holds one.
  bool _keepGroups(Rollup groups) => groups.accountCount > 0;

  /// The Leerlingen drill-down after the global filter (#226): the merged
  /// grade-years that still hold a visible classroom, plus the class-groups
  /// node, and how many nodes went missing so the tree can say so.
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
    final groups = controller.groupRollup;
    return _FilteredTree(
      roots: roots,
      groups: groups != null && _keepGroups(groups) ? groups : null,
      hidden: hidden,
    );
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
    } else if (controller.showingGroups) {
      slivers.addAll(_groupSlivers(context));
    } else if (controller.hasOverview) {
      // Partition the drill-down by family: the Personeel tab shows only the
      // synthetic staff school node (school → grade → classroom, unchanged); the
      // Leerlingen tab opens straight on the merged grade-years plus the
      // class-groups node (class groups are student-oriented).
      final tree = staffTab ? _staffTree() : _studentTree();
      slivers.add(_section(staffTab
          ? _DrillDownSection(
              controller: controller,
              accordion: _accordion,
              roots: tree.roots,
              groups: null,
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
              groups: tree.groups,
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
    slivers.addAll(_readOnlySlivers());

    // Only the Personeel tab carries a per-list lookup; the mode switch that
    // used to sit beside it now lives once, at the top of the view (#226).
    final searchSlivers = _staffTab
        ? <Widget>[
            _section(_ClassroomSearchBar(searchController: _search)),
            _gap(PlinkSpacing.s3),
          ]
        : const <Widget>[];

    if (controller.linked != null) {
      final situations = controller.classroomPendingSituations;
      if (situations.isEmpty) {
        return slivers
          ..add(_section(const _EmptyLine('Geen openstaande acties in deze '
              'klas.')));
      }
      final rows = _pendingRows(_filterSituations(situations));
      slivers
        ..addAll(searchSlivers)
        ..add(rows.isEmpty
            ? _section(const _EmptyLine(_noMatchLabel))
            : _rowsSliver(rows));
    } else {
      final accounts = controller.classroomAccounts;
      if (accounts == null || accounts.isEmpty) {
        return slivers
          ..add(_section(const _EmptyLine('Geen accounts in deze klas.')));
      }
      final filtered = _filterAccounts(accounts);
      slivers
        ..addAll(searchSlivers)
        ..add(filtered.isEmpty
            ? _section(const _EmptyLine(_noMatchLabel))
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

  /// The read-only announcement shown above either drill-down when this session
  /// has no linked view to act on (#214) — a passive session that only read the
  /// shared overview, or one whose sync/drift pass failed before it could link.
  /// Empty in an active session, where the tiles below are the interactive ones.
  List<Widget> _readOnlySlivers() {
    if (controller.linked != null) return const <Widget>[];
    return <Widget>[
      _section(_ReadOnlyNotice(controller: controller)),
      _gap(PlinkSpacing.s3),
    ];
  }

  /// The drilled-into "Klasgroepen" node (#119): the live interactive group
  /// entries (active) or the read-only materialized group docs (passive),
  /// through a lazy [SliverList] (#154). The read-only half carries the same
  /// announcement as the classroom drill-down (#214).
  List<Widget> _groupSlivers(BuildContext context) {
    final slivers = <Widget>[
      _section(_DetailHeader(
        backKey: const ValueKey('actions-groups-back'),
        title: controller.groupRollup?.label ?? 'Klasgroepen',
        onBack: controller.closeGroups,
      )),
      _gap(PlinkSpacing.s3),
    ];
    if (controller.loadingGroups) {
      return slivers..add(_section(const LinearProgressIndicator()));
    }
    slivers.addAll(_readOnlySlivers());
    if (controller.linked != null) {
      final rows = _pendingRows(controller.groupPendingSituations);
      if (rows.isEmpty) {
        return slivers
          ..add(_section(const _EmptyLine('Geen klasgroepen met openstaande '
              'acties.')));
      }
      slivers.add(_rowsSliver(rows));
    } else {
      final groups = controller.groupDocs;
      if (groups == null || groups.isEmpty) {
        return slivers
          ..add(_section(const _EmptyLine('Geen klasgroepen met openstaande '
              'acties.')));
      }
      slivers.add(SliverPadding(
        padding: _hPad,
        sliver: SliverList.builder(
          itemCount: groups.length,
          itemBuilder: (context, index) => _GroupTile(group: groups[index]),
        ),
      ));
    }
    return slivers;
  }

  /// A lazy sliver over pending [rows] (situation headers + entry tiles) — the
  /// carried-over virtualized list from the old flat pending section (#111).
  Widget _rowsSliver(List<_PendingRow> rows) => SliverPadding(
        padding: _hPad,
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            return switch (row) {
              _SituationHeaderRow(:final entries) =>
                _SituationHeader(controller: controller, entries: entries),
              _EntryRow(:final entry) =>
                _PendingEntryTile(controller: controller, entry: entry),
            };
          },
        ),
      );

  static List<_PendingRow> _pendingRows(
    List<List<PendingAccountEntry>> situations,
  ) {
    final rows = <_PendingRow>[];
    for (final subset in situations) {
      if (subset.length > 1) rows.add(_SituationHeaderRow(subset));
      for (final entry in subset) {
        rows.add(_EntryRow(entry));
      }
    }
    return rows;
  }

  List<Widget> _resultsSlivers() {
    final dry = controller.dryRunResults;
    final applied = controller.applyResults;
    final slivers = <Widget>[];
    if (dry != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSectionSlivers(
          title: 'Dry-run result',
          subtitle: 'No changes were written. This is what an apply would do.',
          results: dry,
        ));
    }
    if (applied != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSectionSlivers(
          title: 'Apply result',
          subtitle: 'Written to the target systems.',
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

/// The Actions title plus the global "Dry-run all" / "Apply all" affordances
/// (#110/#154): the secondary escape hatch that acts on every pending entry's
/// chosen resolution, across all classes.
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
        const SizedBox(height: PlinkSpacing.s4),
        Wrap(
          spacing: PlinkSpacing.s3,
          runSpacing: PlinkSpacing.s2,
          children: <Widget>[
            OutlinedButton.icon(
              key: const ValueKey('actions-dry-run'),
              onPressed: controller.busy || controller.applyableCount == 0
                  ? null
                  : () => _runWithProgress(
                        context,
                        controller: controller,
                        dry: true,
                        run: controller.dryRun,
                      ),
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Dry-run alles'),
            ),
            TextButton.icon(
              key: const ValueKey('actions-apply'),
              onPressed: controller.busy || controller.applyableCount == 0
                  ? null
                  : () => _confirmAndApply(
                        context,
                        controller: controller,
                        title: 'Openstaande acties toepassen?',
                        scope: controller.applyScope(controller.pendingEntries),
                        apply: controller.applyAll,
                      ),
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('Alles toepassen'),
            ),
          ],
        ),
        if (controller.busy) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s4),
          // Determinate, like the Reconcile header's (#176/#243): the value
          // exists on the very same controller, and an indeterminate sweep here
          // was a motionless bar that read as a hung app.
          LinearProgressIndicator(
            key: const ValueKey('actions-progress'),
            value: controller.progress,
          ),
        ],
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
      'Nog geen gematerialiseerd overzicht. Synchroniseer op het Reconcile-'
      'scherm om openstaande acties per klas te zien.',
      style: text.bodyMedium,
    );
  }
}

/// The read-only announcement above a drill-down whose session has no linked
/// view (#214).
///
/// `ReconcileController.linked` is what the interactive
/// [_PendingEntryTile] path is built from: the choices, the per-entry dry-run
/// and apply. Without it the drill-down can only render the stored account /
/// group documents as static cards — correct, but silently so, which reads as
/// an interactive list that stopped responding. This says which of the two the
/// operator is looking at, why, and offers the sync that turns one into the
/// other.
///
/// Two ways to get here, and the operator is told which: a **passive** session
/// that only read the shared overview (`loadOverview()`, never synced), or one
/// whose sync/drift pass **failed** before it could link. A failed pass never
/// discards an existing linked view — `_fail` records the error and returns to
/// `ready`, leaving `linked` untouched — so the failure wording only ever
/// appears when this session had nothing linked to begin with.
class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool failed = controller.error != null;
    final bool lockedByOther = controller.syncLockedByOther;

    return Container(
      key: const ValueKey('actions-read-only'),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.primary),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.visibility_outlined, size: 18, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Alleen-lezen overzicht', style: text.titleSmall),
                    const SizedBox(height: PlinkSpacing.s1),
                    Text(
                      failed
                          ? 'De laatste sync is mislukt, dus deze sessie heeft '
                              'geen actuele acties om toe te passen. Hieronder '
                              'staat het gedeelde overzicht van de vorige sync.'
                          : 'Deze sessie heeft nog niet gesynchroniseerd, dus '
                              'deze acties kunnen niet worden toegepast. '
                              'Hieronder staat het gedeelde overzicht van de '
                              'laatste sync.',
                      style: text.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          FilledButton.icon(
            key: const ValueKey('actions-read-only-sync'),
            onPressed:
                controller.busy || lockedByOther ? null : controller.sync,
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Synchroniseer'),
          ),
          // A dead Synchronise needs its reason on screen too — the same
          // named-holder line the Reconcile screen shows (#108).
          if (lockedByOther) ...<Widget>[
            const SizedBox(height: PlinkSpacing.s2),
            Text(
              '${controller.syncLockOwner} is aan het synchroniseren…',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) =>
      Text(message, style: Theme.of(context).textTheme.bodyMedium);
}

/// The Dutch name the operator knows a system by — the same names the action
/// summaries and the rest of the screen use (#234). Azure AD is "Office 365"
/// throughout this app, so the dialog says that and not the tenant's technical
/// name.
String systemLabel(core.Origin system) => switch (system) {
      core.Origin.azure => 'Office 365',
      core.Origin.smartschool => 'Smartschool',
      core.Origin.wisa => 'WISA',
      core.Origin.all => 'alle systemen',
      core.Origin.other => 'een ander systeem',
    };

/// Joins system names the way Dutch reads them: "a", "a en b", "a, b en c".
String _joinSystems(Iterable<core.Origin> systems) {
  final names = <String>[
    // Pinned order (WISA → Smartschool → Office 365) so the same selection
    // always reads the same way, whatever order the actions were dispatched in.
    for (final s in systems.toSet().toList()..sort((a, b) => a.index - b.index))
      systemLabel(s),
  ];
  if (names.length <= 1) return names.join();
  return '${names.take(names.length - 1).join(', ')} en ${names.last}';
}

String _changeCount(int n) => n == 1 ? '1 wijziging' : '$n wijzigingen';

String _ruleCount(int n) => n == 1 ? '1 importregel' : '$n importregels';

/// The body of the apply-confirmation dialog: what this particular pass will
/// write, and where (#234).
///
/// It used to be one hard-coded sentence claiming "Smartschool and Azure AD"
/// for every action, so a single Graph `PATCH` on one display name announced a
/// write to a system it never touched. Everything needed to say it correctly is
/// on the actions themselves; [ApplyScope] carries it here.
///
/// Three things it is careful about:
/// - **WISA is never written.** The `DontImportFromWisa` family's `ChangeSet`
///   carries `Origin.wisa`, but what it produces is a local import rule — the
///   connector is read-only. So those are counted as import rules and the
///   sentence says outright that nothing is written to WISA.
/// - **Chained follow-ups are named, not counted.** A new student's Office 365
///   create writes Smartschool too (#230/#240). Whether the follow-up runs is
///   decided by its own `evaluate` after the first write, so it gets its own
///   "kan ook" sentence rather than being folded into the count.
/// - **A chain that stays inside a system it already named adds nothing** — a
///   class group's create and its roster write are both Office 365 (#245), so
///   there is no second system to announce.
String applyConfirmationMessage(ApplyScope scope) {
  final writes = scope.systems.where((s) => s != core.Origin.wisa).toList();
  final rules = scope.systems.length - writes.length;
  final clauses = <String>[
    if (writes.isNotEmpty)
      'schrijft ${_changeCount(writes.length)} naar ${_joinSystems(writes)}',
    if (rules > 0)
      'legt ${_ruleCount(rules)} vast (er wordt niets naar WISA geschreven)',
  ];
  final what =
      clauses.isEmpty ? 'Dit schrijft niets.' : 'Dit ${clauses.join(' en ')}.';
  final follow = scope.chained.isEmpty
      ? ''
      : ' Een vervolgactie kan ook naar ${_joinSystems(scope.chained)} '
          'schrijven.';
  return '$what$follow Doe eerst een dry-run om de exacte wijzigingen te '
      'bekijken.';
}

/// Shows the apply-confirmation dialog and, on confirm, runs [apply] behind the
/// modal progress dialog (#110/#243). Shared by the global, per-situation, and
/// per-entry apply affordances so a write is always one deliberate confirmation
/// followed by one visible pass.
///
/// [scope] is what that particular confirmation covers (#234) — the systems the
/// pass will really reach, not a fixed pair.
Future<void> _confirmAndApply(
  BuildContext context, {
  required ReconcileController controller,
  required String title,
  required ApplyScope scope,
  required Future<void> Function() apply,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(applyConfirmationMessage(scope)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuleer'),
        ),
        FilledButton(
          key: const ValueKey('actions-apply-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Toepassen'),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false)) return;
  if (!context.mounted) return;
  await _runWithProgress(
    context,
    controller: controller,
    dry: false,
    run: apply,
  );
}

/// Runs one dry-run/apply pass behind a **modal** progress dialog (#243).
///
/// An "Apply to all" over the September "zonder klas" bucket is sequential, one
/// connector round-trip per action, and runs for minutes. Its only feedback used
/// to be greyed-out buttons and an indeterminate bar in a page header the
/// operator had usually scrolled past — so the app looked hung, and nothing
/// stopped them scrolling, switching family tab, or navigating away mid-write.
///
/// Every affordance goes through here — global, per-situation, per-entry, and
/// dry-run as well as apply — so the pass behaves the same wherever it is
/// started. A dry-run over hundreds of accounts is exactly as slow and was
/// exactly as silent.
///
/// The dialog's lifetime is bound to [run]'s future rather than to any observed
/// controller state: it is dismissed in a `finally`, so a pass that fails — or
/// one that returns immediately because another is already running — can never
/// strand the operator behind a modal barrier.
Future<void> _runWithProgress(
  BuildContext context, {
  required ReconcileController controller,
  required bool dry,
  required Future<void> Function() run,
}) async {
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _ApplyProgressDialog(controller: controller, dry: dry),
  ));
  try {
    await run();
  } finally {
    if (navigator.mounted) navigator.pop();
  }
}

/// The modal dialog a pass runs behind (#243): how far along it is, and the
/// account and action in flight right now.
///
/// Rebuilt from [ReconcileController.applyStep], which the pass publishes before
/// each action off the very list the confirmation dialog was built from, so the
/// count here and the change count the operator just agreed to are the same
/// resolution of the work.
class _ApplyProgressDialog extends StatelessWidget {
  const _ApplyProgressDialog({required this.controller, required this.dry});

  final ReconcileController controller;

  /// Whether this pass writes nothing, which is the one thing the operator most
  /// wants confirmed while staring at a progress dialog for two minutes.
  final bool dry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    // Non-dismissible: the pass is a sequence of live writes, so there is
    // nothing useful to do behind it and plenty of harm in navigating away.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('actions-progress-dialog'),
        title: Text(dry ? 'Dry-run bezig…' : 'Acties toepassen…'),
        content: SizedBox(
          // A [LinearProgressIndicator] demands all the width it is offered, so
          // without a bound the dialog stretches across a desktop window. Fixed
          // at a readable measure, clamped so a narrow window cannot overflow.
          width: (MediaQuery.sizeOf(context).width - 112).clamp(240.0, 400.0),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final ApplyStep? step = controller.applyStep;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Always determinate — an indeterminate sweep is what #176
                  // replaced on Reconcile, and is what this dialog exists to
                  // stop showing.
                  LinearProgressIndicator(
                    key: const ValueKey('actions-progress-bar'),
                    value: step == null ? 0.0 : (step.index - 1) / step.total,
                  ),
                  const SizedBox(height: PlinkSpacing.s4),
                  Text(
                    key: const ValueKey('actions-progress-count'),
                    step == null
                        ? 'Bezig…'
                        : 'Actie ${step.index} van ${step.total}',
                    style: text.titleSmall,
                  ),
                  if (step != null) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s1),
                    Text(
                      key: const ValueKey('actions-progress-step'),
                      '${step.target} — ${step.summary}',
                      style: text.bodyMedium,
                    ),
                  ],
                  if (step != null && step.followUps > 0) ...<Widget>[
                    const SizedBox(height: PlinkSpacing.s2),
                    Text(
                      key: const ValueKey('actions-progress-followups'),
                      // Named, never folded into the count: a follow-up is not
                      // in the pending list, so it cannot be part of the total
                      // the operator was shown (#230/#240/#245).
                      '+ ${_followUpCount(step.followUps)} gestart door een '
                      'eerdere actie.',
                      style: text.bodySmall,
                    ),
                  ],
                  const SizedBox(height: PlinkSpacing.s3),
                  Text(
                    dry
                        ? 'Er wordt niets geschreven.'
                        : 'Sluit het venster niet tot de reeks klaar is.',
                    style: text.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String _followUpCount(int n) => n == 1 ? '1 vervolgactie' : '$n vervolgacties';

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
/// never pulled or re-linked. Tapping a classroom (or the Klasgroepen node)
/// lazily loads just that node's actions (#154).
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
    required this.groups,
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

  /// The "Klasgroepen" rollup node to append below [roots], or `null` when
  /// this tab carries no group family (the Personeel tab).
  final Rollup? groups;

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
        trailing: _PendingBadge(count: root.pendingCount),
        children: childrenOf(root),
      ),
    );
  }

  String? _freshness() {
    final state = controller.syncState;
    if (state.generation == 0) return null;
    final at = state.updatedAt;
    // Same dated stamp as the Reconcile last-sync box (#192): time-only made
    // a generation from last week look like one from this morning.
    final when = at == null ? '' : ' · ${formatFreshnessStamp(at)}';
    final who = state.updatedBy == null || state.updatedBy!.isEmpty
        ? ''
        : ' door ${state.updatedBy}';
    return 'Generatie ${state.generation}$when$who';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    final freshness = _freshness();
    final groupsNode = groups;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Overzicht', style: text.titleMedium),
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(freshness, style: text.bodySmall),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        if (roots.isEmpty && groupsNode == null)
          filtering && hidden > 0
              ? Text(
                  _allHiddenNote,
                  key: const ValueKey('actions-filter-all-hidden'),
                  style: text.bodyMedium,
                )
              : Text(emptyLabel, style: text.bodyMedium)
        else ...<Widget>[
          for (final root in roots) _rootTile(context, root, hairline),
          if (groupsNode != null)
            Container(
              margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
              decoration: BoxDecoration(
                border: Border.all(color: hairline),
                borderRadius:
                    const BorderRadius.all(Radius.circular(PlinkRadius.base)),
              ),
              child: ListTile(
                key: const ValueKey('rollup-groups'),
                title: Text(groupsNode.label, style: text.bodyLarge),
                subtitle: Text(
                  // A node the filter kept while its badge shows a tick needs
                  // its reason on the tile (#225/#226): every class in it
                  // carries a notice to follow up by hand, none an automated
                  // write.
                  groupsNode.pendingCount == 0
                      ? '${groupsNode.accountCount} klasgroep(en) — enkel '
                          'meldingen om manueel op te volgen'
                      : '${groupsNode.accountCount} klasgroep(en)',
                  style: text.bodySmall,
                ),
                trailing: _PendingBadge(count: groupsNode.pendingCount),
                onTap: controller.openGroups,
              ),
            ),
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
      trailing: _PendingBadge(count: grade.pendingCount),
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
      trailing: _PendingBadge(count: classroom.pendingCount),
      onTap: () => controller.openClassroom(classroom),
    );
  }
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return Icon(Icons.check,
          size: 16, color: Theme.of(context).disabledColor);
    }
    return PlinkBadge('$count');
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
/// [_PendingEntryTile] looking identical to it. [_ReadOnlyNotice] above the
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
              const _ReadOnlyLock(),
              const SizedBox(width: PlinkSpacing.s2),
              _PendingBadge(count: pendingDecisionCount(account.candidates)),
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
              child: Text(
                _readOnlyCandidateLine(c),
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The muted lock a read-only card carries where an interactive tile carries
/// its expand affordance (#214) — the per-row half of the read-only state,
/// explained once by [_ReadOnlyNotice] at the top of the list.
class _ReadOnlyLock extends StatelessWidget {
  const _ReadOnlyLock();

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Alleen-lezen — synchroniseer om acties toe te passen',
        child: Icon(
          Icons.lock_outline,
          size: 16,
          color: Theme.of(context).disabledColor,
        ),
      );
}

/// One read-only candidate line of a passive-session tile — [_AccountTile] and
/// [_GroupTile] share it — worded exactly as the interactive
/// [_PendingEntryTile]'s: an either/or reads as one "(keuze)" on its
/// pre-selected half (#251), an informational notice keeps its "(manueel)"
/// marker (#225), and an ordinary action is its bare summary.
///
/// The account card used to render a bare bullet for every candidate (#255), so
/// a student's informational candidate — since #245 the student family has one —
/// read like due work next to a badge that counted it zero.
String _readOnlyCandidateLine(actions.Alternatives<CandidateAction> choice) {
  final summary = choice.selected.summary;
  if (choice.isChoice) return '• $summary (keuze)';
  return choice.selected.canApply ? '• $summary' : '• $summary (manueel)';
}

/// One class group's read-only summary in a passive-session group drill-down,
/// styled inert exactly as [_AccountTile] is (#214).
class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group});

  final MaterializedGroup group;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    final Color muted = Theme.of(context).disabledColor;
    final systems = <String>[
      if (group.inWisa) 'WISA',
      if (group.inSmartschool) 'Smartschool',
      if (group.inAzure) 'Azure',
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
              Expanded(child: Text(group.label, style: text.bodyLarge)),
              const _ReadOnlyLock(),
              const SizedBox(width: PlinkSpacing.s2),
              _PendingBadge(count: pendingDecisionCount(group.candidates)),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Wrap(
            spacing: PlinkSpacing.s2,
            children: <Widget>[for (final s in systems) PlinkBadge(s)],
          ),
          // One line per *decision* (#251), marked exactly as the interactive
          // tile marks it: since #244 a new class is one "create it or stop
          // importing it" either/or, which used to read as two separate to-dos.
          for (final c in candidateChoices(group.candidates))
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: Text(
                _readOnlyCandidateLine(c),
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bulk header of one "same situation" subset (#110): the "apply this
/// resolution to all" affordance that honours each entry's own chosen
/// alternative. Rendered as its own row in the lazy list, only when more than
/// one account shares the situation.
///
/// Every affordance here acts on [entries] — the exact subset this header was
/// built over and counts (#252). That list is already scoped by whatever list
/// rendered it: the open classroom's pending entries, or the group drill-down's,
/// narrowed further by the search box. The bulk pass used to re-resolve the
/// situation key against the *whole* linked view instead, so a header reading
/// "Alles toepassen (1)" inside one class wrote every account group-wide in the
/// same situation. The label, the confirmation scope and the write are now one
/// list, so they cannot drift apart again.
class _SituationHeader extends StatelessWidget {
  const _SituationHeader({required this.controller, required this.entries});

  final ReconcileController controller;
  final List<PendingAccountEntry> entries;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final key = entries.first.situationKey;
    final applyable = entries.where((e) => e.canApply).length;

    return Padding(
      padding: const EdgeInsets.only(
        top: PlinkSpacing.s2,
        bottom: PlinkSpacing.s2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${entries.first.situationLabel} — ${entries.length} '
              'accounts in the same situation',
              style: text.titleSmall,
            ),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          OutlinedButton(
            key: ValueKey('situation-dry-run-$key'),
            onPressed: controller.busy || applyable == 0
                ? null
                : () => _runWithProgress(
                      context,
                      controller: controller,
                      dry: true,
                      run: () => controller.dryRunEntries(entries),
                    ),
            child: const Text('Dry-run alles'),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          FilledButton(
            key: ValueKey('situation-apply-$key'),
            onPressed: controller.busy || applyable == 0
                ? null
                : () => _confirmAndApply(
                      context,
                      controller: controller,
                      title: 'Toepassen op ${entries.length} accounts?',
                      // The dialog is scoped to the very entries the pass below
                      // runs over — the ones this header counted (#234/#252).
                      scope: controller.applyScope(entries),
                      apply: () => controller.applyEntries(entries),
                    ),
            child: Text('Alles toepassen ($applyable)'),
          ),
        ],
      ),
    );
  }
}

/// One account's pending resolution (#110): a single expandable row showing the
/// selected summary, the mutually-exclusive choice (as radios) when there is
/// one, the per-field diff, and per-entry dry-run / apply.
class _PendingEntryTile extends StatelessWidget {
  const _PendingEntryTile({required this.controller, required this.entry});

  final ReconcileController controller;
  final PendingAccountEntry entry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;

    String lineFor(PendingChoice c) {
      final summary = c.selected.changes.summary;
      if (c.isChoice) return '$summary (keuze)';
      return c.selected.canApply ? summary : '$summary (manueel)';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: ExpansionTile(
        key: ValueKey('entry-${entry.family}-${entry.targetId}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: PlinkBadge(entry.family),
        title: Text(entry.target, style: text.bodyLarge),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final c in entry.choices)
              Text(lineFor(c), style: text.bodySmall),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final choice in entry.choices)
            if (choice.isChoice)
              _ChoiceControl(
                controller: controller,
                entry: entry,
                choice: choice,
              )
            else
              _OptionDetail(option: choice.selected),
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            children: <Widget>[
              OutlinedButton(
                key: ValueKey('entry-dry-run-${entry.targetId}'),
                onPressed: controller.busy || !entry.canApply
                    ? null
                    : () => _runWithProgress(
                          context,
                          controller: controller,
                          dry: true,
                          run: () => controller.dryRunEntry(entry),
                        ),
                child: const Text('Dry-run'),
              ),
              const SizedBox(width: PlinkSpacing.s2),
              FilledButton(
                key: ValueKey('entry-apply-${entry.targetId}'),
                onPressed: controller.busy || !entry.canApply
                    ? null
                    : () => _confirmAndApply(
                          context,
                          controller: controller,
                          title: 'Toepassen voor ${entry.target}?',
                          scope: controller.applyScope(<PendingAccountEntry>[
                            entry,
                          ]),
                          apply: () => controller.applyEntry(entry),
                        ),
                child: const Text('Toepassen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The radio group for a mutually-exclusive choice (#110): the operator picks
/// exactly one resolution; the selected one is what an apply runs.
class _ChoiceControl extends StatelessWidget {
  const _ChoiceControl({
    required this.controller,
    required this.entry,
    required this.choice,
  });

  final ReconcileController controller;
  final PendingAccountEntry entry;
  final PendingChoice choice;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Kies één oplossing:',
          style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        for (final option in choice.alternatives)
          InkWell(
            key: ValueKey('alt-${entry.targetId}-${option.kind}'),
            onTap: controller.busy
                ? null
                : () => controller.chooseAlternative(
                      entry: entry,
                      group: option.group!,
                      kind: option.kind,
                    ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: PlinkSpacing.s1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    option.kind == choice.selected.kind
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: option.kind == choice.selected.kind
                        ? colors.primary
                        : Theme.of(context).disabledColor,
                  ),
                  const SizedBox(width: PlinkSpacing.s2),
                  Expanded(
                    child: Text(option.changes.summary, style: text.bodySmall),
                  ),
                ],
              ),
            ),
          ),
        // What the picked resolution will actually write. Collapsing two
        // actions into one choice (#244) must not cost the operator the diff
        // they used to read off the second row — a class create names the class,
        // its description and its Smartschool parent, and that is exactly what
        // decides whether the create or the opt-out is right.
        const SizedBox(height: PlinkSpacing.s2),
        _OptionDetail(option: choice.selected),
      ],
    );
  }
}

/// The per-field diff (or a lifecycle note) for a single option — the one that
/// stands alone, or the one selected inside a [_ChoiceControl].
class _OptionDetail extends StatelessWidget {
  const _OptionDetail({required this.option});

  final PendingActionOption option;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final fields = option.changes.fields;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: fields.isEmpty
          ? <Widget>[
              Text(
                option.canApply
                    ? 'Lifecycle action — no per-field diff.'
                    : '${option.changes.summary} '
                        '(manual — not applied automatically)',
                style: text.bodySmall,
              ),
            ]
          : <Widget>[
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
                  child: Text(
                    '${f.field}: ${f.before ?? '∅'} → ${f.after ?? '∅'}',
                    style: text.bodySmall,
                  ),
                ),
            ],
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

/// Full-panel message (loading / not-configured / error), mirroring the other
/// screens' panels so the views read as one app.
class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.eyebrow,
    required this.title,
    required this.message,
    this.action,
    this.progress = false,
  });

  final String eyebrow;
  final String title;
  final String message;
  final Widget? action;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(PlinkSpacing.s6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Eyebrow(eyebrow, onInk: ink),
              const SizedBox(height: PlinkSpacing.s4),
              Text(title, style: text.headlineSmall),
              const SizedBox(height: PlinkSpacing.s4),
              Text(message, style: text.bodyMedium),
              if (progress) ...<Widget>[
                const SizedBox(height: PlinkSpacing.s5),
                const LinearProgressIndicator(),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: PlinkSpacing.s5),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
