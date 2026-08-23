import 'dart:async';

import 'package:account_actions/account_actions.dart' show ActionOutcome;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart'
    show MaterializedGroup, candidateChoices, pendingDecisionCount;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../search/name_query.dart';
import 'action_tiles.dart';

// The class-name ordering moved to the shared tile library when the flat Acties
// list grew a "sorteer op klas" of its own (#295) — both screens order a class
// list the same way or neither is scannable. Re-exported so it stays importable
// from here, exactly as it was before it moved.
export 'action_tiles.dart' show compareClassNames;

/// The **Klasgroepen** tab (#227): the full class inventory.
///
/// Every class the last sync linked is a row here — not only the ones that
/// raised something — with a column per system (WISA · Smartschool · Office
/// 365) and the rows that need work highlighted. That inversion is the whole
/// point. The Acties drill-down listed changes, so a *wrong* proposal looked
/// exactly like every right one: `2G` was offered for creation although
/// Smartschool already had it (#225), and nothing on screen could have shown
/// otherwise. Three green ticks on a row means the class is correct everywhere,
/// and anything else stands out.
///
/// Four things the layout is deliberate about:
///
/// - **A cell means "work you can do on this screen", not mere presence**
///   (#298). Until then the three cells answered *does this class exist in
///   system X* and nothing else, so `1A` — present everywhere and carrying a
///   pending Office 365 roster write — read as three ticks with nothing saying
///   the pending work was an Azure one. A cell now shows the worst of presence
///   and pending work for that one system: red missing, orange work pending,
///   green in order. [SystemIndicatorCell] and the principle behind it live in
///   `system_indicator.dart`, shared with Acties so a coloured cell means the
///   same thing on both screens.
/// - **The Office 365 column is per *class*, not per row.** Sub-groups get no
///   group of their own (#228), so `2F ECO` / `2F MAW` / `2F MOW` / `2F STEMW`
///   are all served by the one group `<PREFIX>-2F`. Each such row names that
///   group and says whose sub-group it is, instead of four rows each looking
///   like they own one.
/// - **The filter defaults *off*.** Acties has the same switch on by default
///   (#226) because it answers "what needs doing?"; this tab answers "is the
///   inventory right?", which only the full list can. The name search (#262) is
///   what makes those few hundred rows navigable without shortening them, and it
///   composes with the switch rather than replacing it.
/// - **Informational notices are not buried.** A class Smartschool already
///   holds, or an Office 365 group left behind by a class that is gone, is real
///   manual work with no automated write, so it contributes nothing to a pending
///   count (#225/#250). The filter and the row **highlight** therefore key on
///   [MaterializedGroup.needsAttention], never on the pending count — and that
///   stays true under #298, which is not the contradiction it looks like. The
///   reconciling principle is *colour by work that can be done on this screen*:
///   here the manual notice is the work you do on this screen, so it lights the
///   row; in Acties an informational candidate diagnoses work that happens
///   somewhere else, so it colours nothing there. The system **cells** are the
///   narrower reading — they promise a write, so they count only applyable
///   work. See the library doc of `system_indicator.dart`.
///
/// A class that needs work is inspected — and, where it is applyable, dry-run
/// and applied — right here, through the same tiles Acties uses
/// (`action_tiles.dart`), so the operator never has to hop to a second list of
/// the same classes. That is also why the Klasgroepen node left the Acties
/// drill-down: this tab is its superset, and the same list must not be
/// maintained in two places.
///
/// Shares the one memoized [ReconcileServices] (and so the one
/// [ReconcileController]) with Reconcile, Acties and Wachtwoorden, so a sync run
/// on Reconcile populates the inventory shown here.
class ClassGroupsScreen extends StatefulWidget {
  const ClassGroupsScreen({super.key, required this.bootstrap});

  /// Assembles (or returns the already-assembled) reconcile stack, or `null`
  /// when Azure AD is not configured for this build.
  final Future<ReconcileServices> Function()? bootstrap;

  @override
  State<ClassGroupsScreen> createState() => _ClassGroupsScreenState();
}

class _ClassGroupsScreenState extends State<ClassGroupsScreen> {
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
      // The session's opening read: the shared overview and the class inventory
      // straight from the store (#115), then the linked view built from that
      // same shared state when the cold seed allows it (#287) — no pull either
      // way. Idempotent with the other screens' own reads (one controller).
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
        eyebrow: 'Arcadia · klasgroepen',
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
        eyebrow: 'Arcadia · klasgroepen',
        title: 'Kan het Klasgroepen-scherm niet openen',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('class-groups-bootstrap-retry'),
          onPressed: _bootstrap,
          child: const Text('Probeer opnieuw'),
        ),
      );
    }
    final services = _services;
    if (_bootstrapping || services == null) {
      return const MessagePanel(
        eyebrow: 'Arcadia · klasgroepen',
        title: 'Voorbereiden…',
        message: 'De instellingen en verbindingsprofielen worden geladen.',
        progress: true,
      );
    }
    return _ClassGroupsBody(controller: services.controller);
  }
}

/// One row of the inventory: the stored class document, plus the live pending
/// entry for it when this session has one to act on.
class _ClassRowModel {
  const _ClassRowModel({required this.group, this.entry});

  final MaterializedGroup group;

  /// The interactive entry for this class in an **active** session; `null` in a
  /// passive one, and for a class with nothing pending.
  final PendingAccountEntry? entry;

  /// Whether this class asks anything of the operator.
  ///
  /// An active session answers from the live dispatch, which drops an entry the
  /// moment it is applied; a passive one from the stored candidates, which is
  /// all it has. Either way the pending *count* is not the question — an
  /// informational notice is work too (#225/#250).
  bool attentionIn({required bool active}) =>
      active ? entry != null : group.needsAttention;

  /// What the name search (#262) matches this row against: the class name and
  /// its description, as one haystack.
  ///
  /// Both, because a class is looked up either way — `3TSO-B` by its code, but
  /// just as often "handel", which only the description carries. Joining them
  /// rather than testing them separately also lets one needle span the two
  /// ("2f handel"), which is how an operator who half-remembers both types it.
  String get searchText => '${group.label} ${group.description}';
}

class _ClassGroupsBody extends StatefulWidget {
  const _ClassGroupsBody({required this.controller});

  final ReconcileController controller;

  @override
  State<_ClassGroupsBody> createState() => _ClassGroupsBodyState();
}

class _ClassGroupsBodyState extends State<_ClassGroupsBody> {
  /// The inventory filter (#227), the mirror of the Acties switch (#226) —
  /// **off** by default, because this tab's job is the full picture. On, it
  /// keeps only the classes that ask something of the operator.
  bool _onlyAttention = false;

  /// The class name search (#262). Unlike [_onlyAttention] this is not a mode
  /// but a lookup *inside* this list: the tab lists every class of the school
  /// group — a few hundred rows — and the filter that would shorten it is off by
  /// design, so "is `3TSO-B` right?" is otherwise answered by scrolling.
  final TextEditingController _search = TextEditingController();

  ReconcileController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_ensureLoaded);
    _search.addListener(_onSearchChanged);
    _ensureLoaded();
  }

  @override
  void dispose() {
    controller.removeListener(_ensureLoaded);
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  /// The typed needle, parsed. Matching is per whitespace-separated part and
  /// order-independent — the same [NameQuery] the two Personeel searches use
  /// (#187/#215/#217), so the three searches in this app behave identically
  /// rather than each having its own idea of what a needle means.
  NameQuery get _query => NameQuery(_search.text);

  /// Whether a read is already queued, so a burst of notifications schedules
  /// one.
  bool _scheduled = false;

  /// Reads the inventory whenever this session does not have it: on first build,
  /// and again after a sync — which drops the cached documents precisely so the
  /// tab re-reads the generation it just wrote.
  ///
  /// Always **deferred to a microtask**, never run inline. This is reached from
  /// `initState` and from a controller notification, and the read's own first act
  /// is to publish its loading state — so calling it inline would notify the
  /// other screens' listeners mid-build ("setState() called during build") and
  /// re-enter `notifyListeners` while it is walking its listeners.
  void _ensureLoaded() {
    if (!mounted || _scheduled) return;
    if (controller.groupDocs != null || controller.loadingGroups) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!mounted) return;
      if (controller.groupDocs == null && !controller.loadingGroups) {
        unawaited(controller.loadGroups());
      }
    });
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

  /// The class inventory, name-sorted, with each class's live entry attached.
  List<_ClassRowModel> _rows() {
    final docs = controller.groupDocs ?? const <MaterializedGroup>[];
    // The group family's entries are keyed by the class name, which is exactly
    // the document label (both come from the linker's cross-system match key).
    final byTarget = <String, PendingAccountEntry>{
      for (final e in controller.groupPendingEntries) e.targetId: e,
    };
    final rows = <_ClassRowModel>[
      for (final doc in docs)
        _ClassRowModel(group: doc, entry: byTarget[doc.label]),
    ];
    rows.sort((a, b) => compareClassNames(a.group.label, b.group.label));
    return rows;
  }

  List<Widget> _slivers(BuildContext context) {
    final bool active = controller.linked != null;
    final rows = _rows();
    // The same predicate the rows below key their highlight on, but derived on
    // the controller since #301 — Acties quotes this number too, and a pointer
    // that counted differently from the list it points at would be worse than
    // none.
    final int attention = controller.classesNeedingAttention;
    // The two filters compose rather than replace one another (#262): the
    // search narrows the inventory to the classes the operator is looking for,
    // and the switch — if they turned it on — keeps the ones asking something.
    final NameQuery query = _query;
    final searched = query.isEmpty
        ? rows
        : <_ClassRowModel>[
            for (final r in rows)
              if (query.matches(r.searchText)) r,
          ];
    final visible = _onlyAttention
        ? <_ClassRowModel>[
            for (final r in searched)
              if (r.attentionIn(active: active)) r,
          ]
        : searched;

    final slivers = <Widget>[
      _gap(PlinkSpacing.s6),
      _section(_ClassGroupsHeader(
        controller: controller,
        total: rows.length,
        attention: attention,
        accountsNeedingAttention: controller.accountsNeedingAttention,
      )),
      _gap(PlinkSpacing.s4),
      _section(_ClassSearchBar(searchController: _search)),
      _gap(PlinkSpacing.s3),
      _section(_AttentionFilterBar(
        onlyAttention: _onlyAttention,
        onChanged: (v) => setState(() => _onlyAttention = v),
      )),
      _gap(PlinkSpacing.s4),
    ];

    // Without a linked view there is nothing to choose, dry-run or apply, and
    // the static rows are otherwise indistinguishable from interactive ones
    // whose taps stopped working (#214). With one this session adopted rather
    // than pulled, the rows *are* interactive and the notice says whose sync
    // they came from instead (#287).
    if (!active) {
      slivers
        ..add(_section(ReadOnlyNotice(
          controller: controller,
          keyValue: 'class-groups-read-only',
        )))
        ..add(_gap(PlinkSpacing.s4));
    } else if (controller.adoptedFrom != null) {
      slivers
        ..add(_section(SharedStateNotice(
          controller: controller,
          keyValue: 'class-groups-shared-state',
        )))
        ..add(_gap(PlinkSpacing.s4));
    }

    if (controller.loadingGroups && controller.groupDocs == null) {
      return slivers
        ..add(_section(const LinearProgressIndicator(
          key: ValueKey('class-groups-loading'),
        )))
        ..add(_gap(PlinkSpacing.s6));
    }

    if (rows.isEmpty) {
      return slivers
        ..add(_section(const EmptyLine(
          'Nog geen klasinventaris. Synchroniseer op het tabblad '
          'Synchronisatie om alle klassen te zien.',
        )))
        ..add(_gap(PlinkSpacing.s6));
    }

    slivers.addAll(_bulkSlivers(
      active,
      <String>{for (final r in searched) r.group.label},
    ));

    if (visible.isEmpty) {
      // A search that finds nothing has to say so in its own words (#262). The
      // line below it — "elke klas staat in orde" — is a statement about the
      // inventory, and reading it after a typo would be a lie about the school.
      slivers.add(_section(EmptyLine(
        query.isEmpty
            ? 'Elke klas staat in orde — er is niets dat aandacht vraagt.'
            : _noMatchLabel,
      )));
    } else {
      slivers.add(SliverPadding(
        padding: _hPad,
        sliver: SliverList.builder(
          itemCount: visible.length,
          itemBuilder: (context, index) => _ClassRow(
            controller: controller,
            row: visible[index],
            active: active,
          ),
        ),
      ));
    }
    slivers
      ..addAll(_resultsSlivers())
      ..add(_gap(PlinkSpacing.s6));
    return slivers;
  }

  /// The line shown when the search (alone or with the switch) hides every class
  /// of a non-empty inventory (#262) — deliberately not the "nog geen
  /// klasinventaris" line, which says the sync never ran, nor the "elke klas
  /// staat in orde" one, which says the school is fine. Worded as Acties words
  /// the same state one tab away (#187).
  static const String _noMatchLabel = 'Geen klassen die aan de filter voldoen.';

  /// The "same situation" bulk affordances (#110/#252), collected above the
  /// inventory instead of interleaved in it.
  ///
  /// The inventory is sorted by class name — that is what makes it scannable —
  /// so a subset of classes that share one situation is no longer a contiguous
  /// run of rows to put a header on. They are still worth one click ("create
  /// every new class of the year"), so they sit here, each acting on exactly the
  /// classes it names.
  ///
  /// [shown] is the set of class names the search left standing, and a cohort is
  /// narrowed to it: a button that acts on "exactly the classes it names" must
  /// not quietly write to classes the operator filtered off the screen, and a
  /// cohort left with one class is no longer a bulk affordance at all — its one
  /// row carries the same action.
  ///
  /// Since #292 a cohort is one *decision* rather than one combination of them,
  /// so a class new to Smartschool that also lacks an Office 365 group appears
  /// under both headers, and pressing either writes only what that header names.
  List<Widget> _bulkSlivers(bool active, Set<String> shown) {
    if (!active) return const <Widget>[];
    final cohorts = <SituationCohort>[];
    for (final cohort in controller.groupPendingSituations) {
      final kept = <PendingDecision>[
        for (final d in cohort.decisions)
          if (shown.contains(d.entry.targetId)) d,
      ];
      if (kept.length > 1) {
        cohorts.add(SituationCohort(key: cohort.key, decisions: kept));
      }
    }
    if (cohorts.isEmpty) return const <Widget>[];
    return <Widget>[
      _section(const _SectionTitle('Klassen in dezelfde situatie')),
      SliverPadding(
        padding: _hPad,
        sliver: SliverList.builder(
          itemCount: cohorts.length,
          itemBuilder: (context, index) => SituationHeader(
            controller: controller,
            cohort: cohorts[index],
            noun: 'klassen',
          ),
        ),
      ),
      _gap(PlinkSpacing.s4),
    ];
  }

  /// The dry-run / apply outcome rows of a pass started from this tab, worded
  /// exactly as Acties words them.
  List<Widget> _resultsSlivers() {
    final dry = controller.dryRunResults;
    final applied = controller.applyResults;
    final slivers = <Widget>[];
    if (dry != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSection(
          title: 'Resultaat van de dry-run',
          subtitle: 'Er is niets geschreven. Dit is wat toepassen zou doen.',
          results: dry,
        ));
    }
    if (applied != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_resultSection(
          title: 'Resultaat van het toepassen',
          subtitle: applyResultsSubtitle(applied),
          results: applied,
        ));
    }
    return slivers;
  }

  List<Widget> _resultSection({
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

/// The tab title plus the one-line state of the inventory.
class _ClassGroupsHeader extends StatelessWidget {
  const _ClassGroupsHeader({
    required this.controller,
    required this.total,
    required this.attention,
    this.accountsNeedingAttention = 0,
  });

  final ReconcileController controller;
  final int total;
  final int attention;

  /// How many accounts are waiting on the Acties tab (#301) — the mirror of the
  /// line Acties carries about this one.
  final int accountsNeedingAttention;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final String? freshness = sharedViewFreshness(controller);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · klasgroepen', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Klasgroepen', style: text.headlineMedium),
        const SizedBox(height: PlinkSpacing.s2),
        Text(
          switch ((total, attention)) {
            (0, _) => 'Nog geen klassen in het gedeelde overzicht.',
            (_, 0) => '$total klas(sen) — alles staat in orde in WISA, '
                'Smartschool en Office 365.',
            _ => '$total klas(sen), waarvan $attention aandacht vragen. '
                'Drie vinkjes betekent dat de klas overal juist staat.',
          },
          style: text.bodyMedium,
        ),
        // The other half of "is everything as expected?" (#301) — the mirror of
        // the pointer Acties carries at this tab, in the same place under the
        // count line, and silent when Acties is holding nothing.
        if (accountsNeedingAttention > 0) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          OtherTabAttentionLine.accounts(count: accountsNeedingAttention),
        ],
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(freshness, style: text.bodySmall),
        ],
      ],
    );
  }
}

/// The class name search above the inventory (#262).
///
/// Same box, same wording and same matching as the two Personeel searches one
/// tab away (#187/#215/#217) — the operator will not remember which list has
/// which kind of search, so all three must behave identically. It sits *above*
/// the switch because it is the more common act on this tab: the switch answers
/// "what needs doing?", the search answers "is this one class right?", which is
/// the question that brought the operator to a few hundred rows.
class _ClassSearchBar extends StatelessWidget {
  const _ClassSearchBar({required this.searchController});

  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('class-groups-search'),
      controller: searchController,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        // Names *and* descriptions: a class is looked up by its code as often as
        // by what it teaches, and a search box that silently ignores half of
        // what is on the row is worse than none (#215/#217).
        hintText: 'Zoek op klas of omschrijving…',
        border: const OutlineInputBorder(),
        suffixIcon: searchController.text.isEmpty
            ? null
            : IconButton(
                key: const ValueKey('class-groups-search-clear'),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Wis zoekopdracht',
                onPressed: searchController.clear,
              ),
      ),
    );
  }
}

/// The inventory filter (#227) — the mirror of the Acties switch (#226), but off
/// by default: the full list is what makes a wrong proposal visible beside the
/// classes that are already right.
class _AttentionFilterBar extends StatelessWidget {
  const _AttentionFilterBar({
    required this.onlyAttention,
    required this.onChanged,
  });

  final bool onlyAttention;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Switch(
          key: const ValueKey('class-groups-only-attention'),
          value: onlyAttention,
          onChanged: onChanged,
        ),
        const SizedBox(width: PlinkSpacing.s2),
        Expanded(
          child: Text(
            'Toon enkel klassen die aandacht vragen',
            style: text.bodyMedium,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) =>
      Text(title, style: Theme.of(context).textTheme.titleMedium);
}

/// One class of the inventory.
///
/// A class with live work is a [PendingCardTile] keyed exactly as the Acties
/// entry tiles are (`entry-group-<klas>`), so opening it offers the same
/// radios, the same per-field diff and the same dry-run / apply pair — and
/// gives way with the same preview lines (#300). A class with nothing to do —
/// the majority, and the reason this tab exists — is a plain card: name,
/// description, three system cells.
class _ClassRow extends StatelessWidget {
  const _ClassRow({
    required this.controller,
    required this.row,
    required this.active,
  });

  final ReconcileController controller;
  final _ClassRowModel row;

  /// Whether this session has a linked view, i.e. whether the rows can act.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color hairline = Theme.of(context).dividerColor;
    final MaterializedGroup group = row.group;
    final PendingAccountEntry? entry = row.entry;
    final bool attention = row.attentionIn(active: active);

    final BoxDecoration decoration = BoxDecoration(
      // The highlight #227 asks for: a class that needs work is picked out of
      // the inventory by its border and a tint, not by being the only row.
      color: attention ? colors.primary.withValues(alpha: 0.06) : null,
      border: Border.all(color: attention ? colors.primary : hairline),
      borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
    );

    final Widget title = Row(
      children: <Widget>[
        Expanded(child: Text(group.label, style: text.bodyLarge)),
        if (!active && attention) ...<Widget>[
          const ReadOnlyLock(),
          const SizedBox(width: PlinkSpacing.s2),
        ],
        PendingBadge(
          count: entry == null
              ? pendingDecisionCount(group.candidates)
              : entry.choices.where((c) => c.selected.canApply).length,
        ),
      ],
    );

    // The row's own body: what the class *is* (description, three system
    // cells), and — while [showLines] — a preview of what it owes. The preview
    // is dropped on an open card, because the expanded body leads every
    // decision with the same sentence (#300); the cells and the description are
    // facts about the class and stay either way.
    Widget body({required bool showLines}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (group.description.isNotEmpty)
              Text(group.description, style: text.bodySmall),
            const SizedBox(height: PlinkSpacing.s2),
            _SystemRow(group: group, work: _workSystems()),
            if (showLines)
              for (final line in _lines(entry, group)) ...<Widget>[
                const SizedBox(height: PlinkSpacing.s1),
                ActionLine(
                  system: line.system,
                  line: line.text,
                  style: entry == null
                      ? text.bodySmall
                          ?.copyWith(color: Theme.of(context).disabledColor)
                      : text.bodySmall,
                ),
              ],
          ],
        );

    // Every row is addressable by its class name, whether or not it has work —
    // the inventory is the thing being verified, so a test (and the element
    // tree) names a class the same way in both shapes.
    final Key rowKey = ValueKey('class-row-${group.label}');

    if (entry == null) {
      return Container(
        key: rowKey,
        margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
        padding: const EdgeInsets.all(PlinkSpacing.s4),
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title,
            const SizedBox(height: PlinkSpacing.s2),
            // Nothing to expand, so nothing repeats it: a passive row keeps its
            // candidate lines.
            body(showLines: true),
          ],
        ),
      );
    }

    return Container(
      key: rowKey,
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: decoration,
      child: PendingCardTile(
        tileKey: ValueKey('entry-group-${entry.targetId}'),
        title: title,
        subtitle: (context, expanded) => body(showLines: !expanded),
        children: entryDetail(context, controller: controller, entry: entry),
      ),
    );
  }

  /// The collapsed summary lines: the live choices in an active session, the
  /// stored candidates in a passive one — each worded exactly as Acties words
  /// it, so an either/or reads as the one decision it is (#251), and each
  /// carrying the system it writes to so [ActionLine] can lead with it (#298).
  ///
  /// A preview, and only that: an open card renders the decisions themselves
  /// and these lines stand down (#300).
  List<({core.Origin system, String text})> _lines(
    PendingAccountEntry? entry,
    MaterializedGroup group,
  ) {
    if (entry != null) {
      return <({core.Origin system, String text})>[
        for (final c in entry.choices)
          (system: c.selected.changes.system, text: pendingChoiceLine(c)),
      ];
    }
    return <({core.Origin system, String text})>[
      for (final c in candidateChoices(group.candidates))
        (system: c.selected.system, text: readOnlyCandidateLine(c)),
    ];
  }

  /// The systems this row has applyable work in (#298) — what turns a cell
  /// orange.
  ///
  /// An **active** session answers from the live dispatch, which drops a
  /// decision the moment it is applied; a passive one from the stored
  /// candidates, which is all it has. The same split
  /// [_ClassRowModel.attentionIn] makes, and for the same reason: in an active
  /// session a class with no entry has nothing left to do, whatever the
  /// document that was materialized before the last apply still says.
  Set<core.Origin> _workSystems() {
    if (!active) return workSystemsOfCandidates(row.group.candidates);
    final PendingAccountEntry? entry = row.entry;
    return entry == null ? const <core.Origin>{} : workSystemsOfEntry(entry);
  }
}

/// The three system cells of one class: WISA · Smartschool · Office 365 (#227),
/// each reading *work you can do here* rather than mere presence since #298.
class _SystemRow extends StatelessWidget {
  const _SystemRow({required this.group, required this.work});

  final MaterializedGroup group;

  /// The systems this class has applyable work in.
  final Set<core.Origin> work;

  @override
  Widget build(BuildContext context) {
    final MaterializedGroup g = group;
    // The Office 365 group is named after the **parent** class (#228), so a
    // sub-group's row names the group it shares rather than pretending to own
    // one. Without this, `2F ECO` and its three siblings each read as a class
    // with a missing group of its own.
    // Only a record that really is a WISA class can be somebody's sub-group; an
    // Azure-only leftover carries the bare name recovered from its display name
    // (`GBS-9Z` → `9Z`), which is the class it *was*, not a parent it belongs to.
    final String? bare = g.className;
    final bool isSubGroup =
        bare != null && g.inWisa && bare.trim() != g.label.trim();
    final String azureDetail = g.azureGroupName ??
        (isSubGroup ? 'nog geen groep voor $bare' : 'nog geen groep');

    // Each cell is addressable on its own — `class-cell-<klas>-<systeem>` — so
    // a test, and the flat list of #295, can ask one row what it says about one
    // system rather than counting icons across three.
    Widget cell(core.Origin system, bool present,
            {String? detail, String? note}) =>
        Expanded(
          child: SystemIndicatorCell(
            key: ValueKey('class-cell-${g.label}-${system.name}'),
            system: system,
            state: systemIndicatorState(
              present: present,
              hasWork: work.contains(system),
            ),
            detail: detail,
            note: note,
          ),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        cell(core.Origin.wisa, g.inWisa),
        cell(core.Origin.smartschool, g.inSmartschool),
        cell(
          core.Origin.azure,
          g.inAzure,
          detail: azureDetail,
          note: isSubGroup ? 'deelgroep van $bare' : null,
        ),
      ],
    );
  }
}

/// The header of a dry-run/apply result set, above the lazy list of rows.
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

/// One outcome row of a dry-run/apply pass started from this tab.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final ActionOutcomeEntry result;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool failed = result.outcome == ActionOutcome.failed;

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
