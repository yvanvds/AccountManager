import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_state/account_state.dart'
    show MaterializedAccount, MaterializedGroup, Rollup;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../format/timestamps.dart';
import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';

/// The Actions view (#154): the pending-actions browser, split off the
/// Reconcile screen so a September changeover's hundreds/thousands of tiles no
/// longer render inline on one very long page.
///
/// Instead of one flat list, actions are browsed through the school →
/// grade-year → classroom rollup drill-down (#119): the tree loads only the
/// aggregate counts, and one classroom's actions are lazily loaded (via
/// `LinkedStore.readClassroom`) and built only when the operator drills into it.
/// The per-class list itself renders through a lazy [SliverList] so only the
/// on-screen tiles build. The global "Dry-run all" / "Apply all" act on every
/// pending entry across all classes.
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

  /// The classroom drill-down filters (#187): show only accounts carrying an
  /// applyable action (both tabs), and a name search (Personeel tab). They
  /// combine — a filtered account list respects both. Reset when the family tab
  /// changes so each tab opens at a clean, unfiltered list.
  bool _onlyWithActions = false;
  final TextEditingController _search = TextEditingController();

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

  /// Whether the Personeel family tab is the selected one — the only tab that
  /// carries a name search (#187).
  bool get _staffTab => _tabs.index == _ActionFamilyTab.personeel.index;

  /// The active, normalized search query (empty on any non-Personeel tab).
  String get _query => _staffTab ? _search.text.trim().toLowerCase() : '';

  /// Whether [label] passes the current name search. A single searchbox matches
  /// the person's display name ("Voornaam Naam"), so a query on either the
  /// voornaam or the naam is a substring hit (#187).
  bool _matchesSearch(String label) {
    final q = _query;
    return q.isEmpty || label.toLowerCase().contains(q);
  }

  /// The passive-session classroom accounts narrowed by the active filters: the
  /// "only with actions" toggle keeps just the accounts with an applyable
  /// candidate (the same `hasPending` predicate the rollup pending counts and
  /// the tile badge use), and the name search keeps matching display names.
  List<MaterializedAccount> _filterAccounts(
      List<MaterializedAccount> accounts) {
    return [
      for (final a in accounts)
        if ((!_onlyWithActions || a.hasPending) && _matchesSearch(a.label)) a,
    ];
  }

  /// The active-session pending situations narrowed by the name search. The
  /// "only with actions" toggle is a no-op here — every pending entry already
  /// carries an action — so only the search filters, dropping any subset left
  /// empty so the same-situation headers stay in sync (#187).
  List<List<PendingAccountEntry>> _filterSituations(
    List<List<PendingAccountEntry>> situations,
  ) {
    if (_query.isEmpty) return situations;
    final out = <List<PendingAccountEntry>>[];
    for (final subset in situations) {
      final kept = <PendingAccountEntry>[
        for (final e in subset)
          if (_matchesSearch(e.target)) e,
      ];
      if (kept.isNotEmpty) out.add(kept);
    }
    return out;
  }

  /// Rebuilds the sliver content for the newly-selected family, and — when the
  /// selected family actually changed — closes any open drill-down so each tab
  /// opens at its own overview rather than showing the other family's detail.
  void _onTabChanged() {
    final index = _tabs.index;
    if (index != _shownIndex) {
      _shownIndex = index;
      // A fresh tab opens at a clean, unfiltered list (#187).
      _onlyWithActions = false;
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

  List<Widget> _slivers(BuildContext context) {
    final slivers = <Widget>[
      _gap(PlinkSpacing.s6),
      _section(_ActionsHeader(controller: controller)),
      _gap(PlinkSpacing.s5),
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
      // synthetic staff school node; the Leerlingen tab shows the student
      // schools plus the class-groups node (class groups are student-oriented).
      final staffRollup = controller.staffSchoolRollup;
      slivers.add(_section(staffTab
          ? _DrillDownSection(
              controller: controller,
              schools: <Rollup>[if (staffRollup != null) staffRollup],
              groups: null,
              emptyLabel: 'Geen openstaande personeelsacties.',
            )
          : _DrillDownSection(
              controller: controller,
              schools: controller.studentSchoolRollups,
              groups: controller.groupRollup,
              emptyLabel: 'Nog geen gematerialiseerd overzicht.',
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

    Widget filterBar() => _section(_ClassroomFilterBar(
          onlyWithActions: _onlyWithActions,
          onOnlyWithActionsChanged: (v) => setState(() => _onlyWithActions = v),
          showSearch: _staffTab,
          searchController: _search,
        ));

    if (controller.linked != null) {
      final situations = controller.classroomPendingSituations;
      if (situations.isEmpty) {
        return slivers
          ..add(_section(const _EmptyLine('Geen openstaande acties in deze '
              'klas.')));
      }
      final rows = _pendingRows(_filterSituations(situations));
      slivers
        ..add(filterBar())
        ..add(_gap(PlinkSpacing.s3))
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
        ..add(filterBar())
        ..add(_gap(PlinkSpacing.s3))
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

  /// The drilled-into "Klasgroepen" node (#119): the live interactive group
  /// entries (active) or the read-only materialized group docs (passive),
  /// through a lazy [SliverList] (#154).
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
  const _ActionsHeader({required this.controller});

  final ReconcileController controller;

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
          count == 0
              ? 'Geen openstaande acties. Klassen zonder acties tonen een vinkje.'
              : '$count openstaande actie(s) — blader per jaar en klas.',
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
                  : controller.dryRun,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Dry-run all'),
            ),
            TextButton.icon(
              key: const ValueKey('actions-apply'),
              onPressed: controller.busy || controller.applyableCount == 0
                  ? null
                  : () => _confirmAndApply(
                        context,
                        title: 'Apply pending actions?',
                        count: controller.applyableCount,
                        apply: controller.applyAll,
                      ),
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('Apply all'),
            ),
          ],
        ),
        if (controller.busy) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s4),
          const LinearProgressIndicator(),
        ],
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

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) =>
      Text(message, style: Theme.of(context).textTheme.bodyMedium);
}

/// Shows the apply-confirmation dialog and, on confirm, runs [apply] (#110).
/// Shared by the global, per-situation, and per-entry apply affordances so a
/// write is always one deliberate confirmation.
Future<void> _confirmAndApply(
  BuildContext context, {
  required String title,
  required int count,
  required Future<void> Function() apply,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(
        'This writes $count change(s) to Smartschool and Azure AD. '
        'Run a dry-run first to preview the exact changes.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('actions-apply-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await apply();
}

/// The materialized overview (#115/#119): the school → grade-year → classroom
/// drill-down driven by the stored rollups, so it renders from the shared state
/// even in a passive session that never pulled or re-linked. Tapping a classroom
/// (or the Klasgroepen node) lazily loads just that node's actions (#154).
class _DrillDownSection extends StatelessWidget {
  const _DrillDownSection({
    required this.controller,
    required this.schools,
    required this.groups,
    required this.emptyLabel,
  });

  final ReconcileController controller;

  /// The school-level rollup roots to render — student schools for the
  /// Leerlingen tab, the single staff node for the Personeel tab (#179).
  final List<Rollup> schools;

  /// The "Klasgroepen" rollup node to append below [schools], or `null` when
  /// this tab carries no group family (the Personeel tab).
  final Rollup? groups;

  /// The message shown when this tab has nothing to browse.
  final String emptyLabel;

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
        if (schools.isEmpty && groupsNode == null)
          Text(emptyLabel, style: text.bodyMedium)
        else ...<Widget>[
          for (final school in schools)
            Container(
              margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
              decoration: BoxDecoration(
                border: Border.all(color: hairline),
                borderRadius:
                    const BorderRadius.all(Radius.circular(PlinkRadius.base)),
              ),
              child: ExpansionTile(
                key: ValueKey('rollup-school-${school.key}'),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(school.label, style: text.bodyLarge),
                trailing: _PendingBadge(count: school.pendingCount),
                children: <Widget>[
                  for (final grade in controller.childrenOf(school.key))
                    _GradeNode(controller: controller, grade: grade),
                ],
              ),
            ),
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
                subtitle: Text('${groupsNode.accountCount} klasgroep(en)',
                    style: text.bodySmall),
                trailing: _PendingBadge(count: groupsNode.pendingCount),
                onTap: controller.openGroups,
              ),
            ),
        ],
      ],
    );
  }
}

class _GradeNode extends StatelessWidget {
  const _GradeNode({required this.controller, required this.grade});

  final ReconcileController controller;
  final Rollup grade;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return ExpansionTile(
      key: ValueKey('rollup-grade-${grade.key}'),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: PlinkSpacing.s5, right: 16),
      title: Text('Jaar ${grade.label}', style: text.bodyMedium),
      trailing: _PendingBadge(count: grade.pendingCount),
      children: <Widget>[
        for (final classroom in controller.childrenOf(grade.key))
          ListTile(
            key: ValueKey('rollup-class-${classroom.key}'),
            contentPadding:
                const EdgeInsets.only(left: PlinkSpacing.s6, right: 16),
            title: Text(classroom.label, style: text.bodyMedium),
            subtitle: Text('${classroom.accountCount} account(s)',
                style: text.bodySmall),
            trailing: _PendingBadge(count: classroom.pendingCount),
            onTap: () => controller.openClassroom(classroom),
          ),
      ],
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

/// The filter bar above a drilled-into classroom's account list (#187): a
/// "toon enkel accounts met acties" toggle (both tabs) and — on the Personeel
/// tab — a name search. Both narrow the list below and combine: the shown list
/// respects the toggle and the search together.
class _ClassroomFilterBar extends StatelessWidget {
  const _ClassroomFilterBar({
    required this.onlyWithActions,
    required this.onOnlyWithActionsChanged,
    required this.showSearch,
    required this.searchController,
  });

  final bool onlyWithActions;
  final ValueChanged<bool> onOnlyWithActionsChanged;

  /// Whether to render the name search field (Personeel tab only).
  final bool showSearch;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showSearch) ...<Widget>[
          TextField(
            key: const ValueKey('actions-search'),
            controller: searchController,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Zoek op voornaam of naam',
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
          const SizedBox(height: PlinkSpacing.s3),
        ],
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
      ],
    );
  }
}

/// One account's read-only summary in a passive-session classroom drill-down:
/// the systems it lives in and its candidate action summaries (no live actions
/// to apply without a sync this session).
class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account});

  final MaterializedAccount account;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
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
              _PendingBadge(
                  count: account.candidates.where((c) => c.canApply).length),
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
          for (final c in account.candidates)
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: Text('• ${c.summary}', style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// One class group's read-only summary in a passive-session group drill-down.
class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group});

  final MaterializedGroup group;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
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
              _PendingBadge(
                  count: group.candidates.where((c) => c.canApply).length),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s2),
          Wrap(
            spacing: PlinkSpacing.s2,
            children: <Widget>[for (final s in systems) PlinkBadge(s)],
          ),
          for (final c in group.candidates)
            Padding(
              padding: const EdgeInsets.only(top: PlinkSpacing.s1),
              child: Text(
                c.canApply ? '• ${c.summary}' : '• ${c.summary} (manueel)',
                style: text.bodySmall,
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
                : () => controller.dryRunSituation(key),
            child: const Text('Dry-run all'),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          FilledButton(
            key: ValueKey('situation-apply-$key'),
            onPressed: controller.busy || applyable == 0
                ? null
                : () => _confirmAndApply(
                      context,
                      title: 'Apply to ${entries.length} accounts?',
                      count: applyable,
                      apply: () => controller.applySituation(key),
                    ),
            child: Text('Apply to all ($applyable)'),
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
                    : () => controller.dryRunEntry(entry),
                child: const Text('Dry-run'),
              ),
              const SizedBox(width: PlinkSpacing.s2),
              FilledButton(
                key: ValueKey('entry-apply-${entry.targetId}'),
                onPressed: controller.busy || !entry.canApply
                    ? null
                    : () => _confirmAndApply(
                          context,
                          title: 'Apply for ${entry.target}?',
                          count: entry.choices
                              .where((c) => c.selected.canApply)
                              .length,
                          apply: () => controller.applyEntry(entry),
                        ),
                child: const Text('Apply'),
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
      ],
    );
  }
}

/// The per-field diff (or a lifecycle note) for a single, non-choice option.
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
