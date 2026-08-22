import 'dart:async';

import 'package:account_actions/account_actions.dart' show ActionOutcome;
import 'package:account_state/account_state.dart'
    show MaterializedGroup, candidateChoices, pendingDecisionCount;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../search/name_query.dart';
import 'action_tiles.dart';

/// The **Klasgroepen** tab (#227): the full class inventory.
///
/// Every class the last sync linked is a row here — not only the ones that
/// raised something — with a presence column per system (WISA · Smartschool ·
/// Office 365) and the rows that need work highlighted. That inversion is the
/// whole point. The Acties drill-down listed changes, so a *wrong* proposal
/// looked exactly like every right one: `2G` was offered for creation although
/// Smartschool already had it (#225), and nothing on screen could have shown
/// otherwise. Three ticks on a row means the class is correct everywhere, and
/// anything else stands out.
///
/// Three things the layout is deliberate about:
///
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
///   count (#225/#250). The filter and the highlight therefore key on
///   [MaterializedGroup.needsAttention], never on the pending count.
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
    final int attention =
        rows.where((r) => r.attentionIn(active: active)).length;
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

/// Orders class names the way an operator reads a class list: by year first and
/// numerically (`2A` before `10A`), then alphabetically, so `2F` sorts beside
/// its sub-groups rather than between `20A` and `21B`.
int compareClassNames(String a, String b) {
  final ya = _leadingYear(a);
  final yb = _leadingYear(b);
  if (ya != yb) {
    // A non-numeric class (`OKAN`) sorts after every numbered year.
    if (ya == null) return 1;
    if (yb == null) return -1;
    return ya - yb;
  }
  return a.toLowerCase().compareTo(b.toLowerCase());
}

int? _leadingYear(String name) {
  final match = RegExp(r'^\s*(\d+)').firstMatch(name);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The tab title plus the one-line state of the inventory.
class _ClassGroupsHeader extends StatelessWidget {
  const _ClassGroupsHeader({
    required this.controller,
    required this.total,
    required this.attention,
  });

  final ReconcileController controller;
  final int total;
  final int attention;

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
/// A class with live work is an [ExpansionTile] keyed exactly as the Acties
/// entry tiles are (`entry-group-<klas>`), so opening it offers the same
/// radios, the same per-field diff and the same dry-run / apply pair. A class
/// with nothing to do — the majority, and the reason this tab exists — is a
/// plain card: name, description, three presence cells.
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

    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (group.description.isNotEmpty)
          Text(group.description, style: text.bodySmall),
        const SizedBox(height: PlinkSpacing.s2),
        _PresenceRow(group: group),
        for (final line in _lines(entry, group)) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(
            line,
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
            body,
          ],
        ),
      );
    }

    return Container(
      key: rowKey,
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: decoration,
      child: ExpansionTile(
        key: ValueKey('entry-group-${entry.targetId}'),
        shape: const Border(),
        collapsedShape: const Border(),
        title: title,
        subtitle: body,
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: entryDetail(context, controller: controller, entry: entry),
      ),
    );
  }

  /// The collapsed summary lines: the live choices in an active session, the
  /// stored candidates in a passive one — each worded exactly as Acties words
  /// it, so an either/or reads as the one decision it is (#251).
  List<String> _lines(PendingAccountEntry? entry, MaterializedGroup group) {
    if (entry != null) {
      return <String>[for (final c in entry.choices) pendingChoiceLine(c)];
    }
    return <String>[
      for (final c in candidateChoices(group.candidates))
        readOnlyCandidateLine(c),
    ];
  }
}

/// The three presence cells of one class: WISA · Smartschool · Office 365.
class _PresenceRow extends StatelessWidget {
  const _PresenceRow({required this.group});

  final MaterializedGroup group;

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: _PresenceCell(system: 'WISA', present: g.inWisa)),
        Expanded(
          child: _PresenceCell(system: 'Smartschool', present: g.inSmartschool),
        ),
        Expanded(
          child: _PresenceCell(
            system: 'Office 365',
            present: g.inAzure,
            detail: azureDetail,
            note: isSubGroup ? 'deelgroep van $bare' : null,
          ),
        ),
      ],
    );
  }
}

class _PresenceCell extends StatelessWidget {
  const _PresenceCell({
    required this.system,
    required this.present,
    this.detail,
    this.note,
  });

  final String system;
  final bool present;

  /// The name of the thing that is (or is not) there — the Office 365 group.
  final String? detail;

  /// A second line that explains the row's relationship to [detail].
  final String? note;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color muted = Theme.of(context).disabledColor;

    return Padding(
      padding: const EdgeInsets.only(right: PlinkSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            present ? Icons.check_circle_outline : Icons.remove_circle_outline,
            size: 16,
            color: present ? colors.primary : muted,
          ),
          const SizedBox(width: PlinkSpacing.s1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  system,
                  style: text.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: text.bodySmall?.copyWith(color: muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (note != null)
                  Text(
                    note!,
                    style: text.bodySmall?.copyWith(color: muted),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
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
