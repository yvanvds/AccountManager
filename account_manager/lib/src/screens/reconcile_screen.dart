import 'dart:async';

import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart'
    show LinkedState, MaterializedAccount, MaterializedGroup, Rollup;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/log_buffer.dart';
import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';

/// The core screen of the app (#99): drives the reconcile loop — sync →
/// linked overview → pending actions → dry-run → apply — with the inline log
/// panel underneath.
///
/// The heavy lifting lives in [ReconcileController]; this widget renders its
/// state and owns the (lazy) bootstrap: the services are only assembled the
/// first time the screen is opened, after sign-in has completed.
class ReconcileScreen extends StatefulWidget {
  const ReconcileScreen({super.key, required this.bootstrap});

  /// Assembles the reconcile stack, or `null` when Azure AD is not configured
  /// for this build (no sign-in, so no stores or connectors to reach).
  final Future<ReconcileServices> Function()? bootstrap;

  @override
  State<ReconcileScreen> createState() => _ReconcileScreenState();
}

class _ReconcileScreenState extends State<ReconcileScreen> {
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
      // without pulling or re-linking. Fire-and-forget; it notifies listeners.
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
        eyebrow: 'Arcadia · reconcile',
        title: 'Not configured',
        message: 'Azure AD is not configured for this build, so the settings '
            'store and connectors cannot be reached. Provide the AAD '
            '--dart-define values and restart.',
      );
    }
    final error = _bootstrapError;
    if (error != null) {
      // A fast failure makes a retry look like a dead button — say the
      // attempt happened.
      final retryNote = _attempts > 1 ? '\n\n(Attempt $_attempts failed.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · reconcile',
        title: 'Could not prepare the reconcile screen',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('reconcile-bootstrap-retry'),
          onPressed: _bootstrap,
          child: const Text('Try again'),
        ),
      );
    }
    final services = _services;
    if (_bootstrapping || services == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · reconcile',
        title: 'Preparing…',
        message: 'Loading the settings and connection profiles.',
        progress: true,
      );
    }
    return _ReconcileBody(
      controller: services.controller,
      log: services.log,
    );
  }
}

/// One row of the flattened pending-actions list (#111): a same-situation
/// bulk header or a single account entry. Flattening the situation → entries
/// tree into a linear list lets a lazy [SliverList] build only the on-screen
/// rows, so a September changeover's hundreds/thousands of tiles no longer all
/// build, lay out, and paint every frame.
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

class _ReconcileBody extends StatelessWidget {
  const _ReconcileBody({required this.controller, required this.log});

  final ReconcileController controller;
  final LogBuffer log;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // The scrollable content sits over the log panel, separated by a
        // draggable handle the operator can use to grow/shrink the log (#152).
        // The handle + panel height live in [_ResizableLogSection] so they
        // persist across these controller-driven rebuilds.
        return _ResizableLogSection(
          log: log,
          content: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              // A CustomScrollView with lazy SliverLists for the pending
              // actions and the results, so only the visible tiles are
              // built — the fixed header/overview/banner stay as adapters
              // (#111). Slivers sit directly under the scroll view (not in a
              // SliverMainAxisGroup) so the scroll cache extent reaches the
              // sections below the fold.
              child: CustomScrollView(slivers: _slivers()),
            ),
          ),
        );
      },
    );
  }

  /// The horizontal inset that stands in for the old body padding; vertical
  /// insets are the leading/trailing gaps and the inter-section [_gap]s.
  static const EdgeInsets _hPad =
      EdgeInsets.symmetric(horizontal: PlinkSpacing.s6);

  /// A fixed-size section: its child laid out once, inset to the body margin.
  static Widget _section(Widget child) => SliverPadding(
        padding: _hPad,
        sliver: SliverToBoxAdapter(child: child),
      );

  /// A vertical spacer between sections (no horizontal inset needed).
  static SliverToBoxAdapter _gap(double height) =>
      SliverToBoxAdapter(child: SizedBox(height: height));

  List<Widget> _slivers() {
    final linked = controller.linked;
    final slivers = <Widget>[
      _gap(PlinkSpacing.s6),
      _section(_Header(controller: controller)),
      _gap(PlinkSpacing.s5),
      _section(_StatusBanner(controller: controller)),
    ];
    if (controller.selectedClassroom != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..add(_section(_ClassroomDetail(controller: controller)));
    } else if (controller.showingGroups) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..add(_section(_GroupsDetail(controller: controller)));
    } else if (controller.hasOverview) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..add(_section(_DrillDownSection(controller: controller)));
    }
    if (linked != null) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..add(
            _section(_OverviewSection(linked: linked, controller: controller)))
        ..add(_gap(PlinkSpacing.s5))
        ..addAll(_actionsSlivers());
    }
    slivers
      ..addAll(_resultsSlivers())
      ..add(_gap(PlinkSpacing.s6));
    return slivers;
  }

  /// The pending-actions section (#110/#111): the title and dry-run/apply
  /// buttons stay as adapters, but the situation headers and per-account entry
  /// tiles render through a lazy [SliverList] so a huge pending set does not
  /// build every tile up front.
  List<Widget> _actionsSlivers() {
    final entries = controller.pendingEntries;
    if (entries.isEmpty) {
      return <Widget>[_section(const _PendingActionsHeader(count: 0))];
    }
    final rows = _pendingRows(controller.pendingSituations);
    return <Widget>[
      _section(_PendingActionsHeader(count: entries.length)),
      SliverPadding(
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
      ),
      _section(_PendingActionsFooter(controller: controller)),
    ];
  }

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

  /// One dry-run/apply result set (#111): its header is an adapter and its
  /// outcome rows render through a lazy [SliverList] — an apply over thousands
  /// of accounts yields thousands of rows.
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

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final ReconcileController controller;

  /// The shared per-system freshness line ("Last sync — WISA 09:12 by jan@…"),
  /// read from the materialized store so it names *whichever* operator last
  /// synced each system — not just this session (#108). Null before any sync.
  String? _freshness() {
    final systems = controller.syncState.systems;
    String? stamp(core.Origin system, String label) {
      final meta = systems[system];
      if (meta == null) return null;
      final t = meta.at.toLocal();
      final hhmm = '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      final by = meta.syncedBy.isEmpty ? '' : ' by ${meta.syncedBy}';
      return '$label $hhmm$by';
    }

    final parts = <String>[
      for (final (system, label) in const [
        (core.Origin.wisa, 'WISA'),
        (core.Origin.smartschool, 'Smartschool'),
        (core.Origin.azure, 'Azure'),
      ])
        if (stamp(system, label) case final s?) s,
    ];
    if (parts.isEmpty) return null;
    return 'Last sync — ${parts.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final freshness = _freshness();
    final lockedByOther = controller.syncLockedByOther;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · reconcile', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        Text('Reconcile', style: text.headlineMedium),
        const SizedBox(height: PlinkSpacing.s4),
        Wrap(
          spacing: PlinkSpacing.s3,
          runSpacing: PlinkSpacing.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              key: const ValueKey('reconcile-sync'),
              onPressed:
                  controller.busy || lockedByOther ? null : controller.sync,
              icon: const Icon(Icons.sync),
              label: const Text('Synchronise'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('reconcile-drift'),
              onPressed: controller.busy || lockedByOther
                  ? null
                  : controller.checkDrift,
              icon: const Icon(Icons.difference_outlined),
              label: const Text('Check for drift'),
            ),
            if (freshness != null) Text(freshness, style: text.bodySmall),
          ],
        ),
        if (lockedByOther) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-sync-lock'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.lock_clock_outlined, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(
                child: Text(
                  '${controller.syncLockOwner} is aan het synchroniseren…',
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        ],
        if (controller.busy) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s4),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final error = controller.error;
    if (error != null) {
      return _bordered(
        context,
        color: colors.error,
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: colors.error),
            const SizedBox(width: PlinkSpacing.s3),
            Expanded(
              child: Text(
                error,
                style: text.bodyMedium?.copyWith(color: colors.error),
              ),
            ),
          ],
        ),
      );
    }
    if (controller.noChangesNeeded) {
      return _bordered(
        context,
        color: colors.primary,
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, color: colors.primary),
            const SizedBox(width: PlinkSpacing.s3),
            Expanded(
              child: Text(
                'WISA is unchanged since the previous sync — '
                'no account changes needed.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }
    if (controller.phase == ReconcilePhase.idle) {
      return Text(
        'Synchronise pulls WISA and diffs it against the previous snapshot; '
        'Smartschool and Azure are read once per session. Use "Check for '
        'drift" when accounts were edited through another tool.',
        style: text.bodyMedium,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _bordered(
    BuildContext context, {
    required Color color,
    required Widget child,
  }) =>
      Container(
        padding: const EdgeInsets.all(PlinkSpacing.s4),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius:
              const BorderRadius.all(Radius.circular(PlinkRadius.base)),
        ),
        child: child,
      );
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.linked, required this.controller});

  final LinkedState linked;
  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final snapshot = linked.snapshot;
    final duplicates = controller.duplicateWarnings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Linked overview', style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        Wrap(
          spacing: PlinkSpacing.s4,
          runSpacing: PlinkSpacing.s4,
          children: <Widget>[
            _CountTile(system: 'WISA', counts: snapshot.wisa),
            _CountTile(system: 'Smartschool', counts: snapshot.smartschool),
            _CountTile(system: 'Azure AD', counts: snapshot.azure),
          ],
        ),
        if (duplicates.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          for (final w in duplicates)
            _DuplicateWarningTile(controller: controller, warning: w),
        ],
      ],
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.system, required this.counts});

  final String system;
  final core.LinkCounts counts;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;

    return Container(
      width: 200,
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PlinkBadge(system),
          const SizedBox(height: PlinkSpacing.s3),
          Text(
            '${counts.linked} / ${counts.total}',
            style: text.headlineSmall,
          ),
          const SizedBox(height: PlinkSpacing.s1),
          Text(
            counts.unlinked == 0
                ? 'fully linked'
                : '${counts.unlinked} not in every system',
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// A duplicate-mail warning as an expandable drill-down (#109): the header
/// names the collision (demoted when accepted), and expanding it lists every
/// colliding account (uid, name, account type, role) with an "accept this
/// duplicate" / "revoke" action. Accepting persists a decision so the collision
/// stops warning until the colliding set changes.
class _DuplicateWarningTile extends StatelessWidget {
  const _DuplicateWarningTile({
    required this.controller,
    required this.warning,
  });

  final ReconcileController controller;
  final DuplicateMailWarning warning;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color hairline = Theme.of(context).dividerColor;
    final accepted = warning.accepted;

    final headline = 'Dubbele mail "${warning.mail}" op '
        '${warning.accounts.length} Smartschool-accounts'
        '${accepted ? ' — geaccepteerd' : ''}.';

    return Container(
      margin: const EdgeInsets.only(top: PlinkSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: ExpansionTile(
        key: ValueKey('dup-warning-${warning.mail}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          accepted ? Icons.check_circle_outline : Icons.warning_amber_outlined,
          size: 20,
          color: accepted ? colors.primary : colors.error,
        ),
        title: Text(
          headline,
          style: text.bodySmall?.copyWith(
            color: accepted ? Theme.of(context).disabledColor : null,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final a in warning.accounts)
            Padding(
              padding: const EdgeInsets.only(bottom: PlinkSpacing.s2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(a.name, style: text.bodyMedium),
                  Text(
                    '${a.uid} · ${a.accountType} · ${a.role}',
                    style: text.bodySmall
                        ?.copyWith(color: Theme.of(context).disabledColor),
                  ),
                ],
              ),
            ),
          const SizedBox(height: PlinkSpacing.s2),
          Align(
            alignment: Alignment.centerLeft,
            child: accepted
                ? OutlinedButton.icon(
                    key: ValueKey('dup-revoke-${warning.mail}'),
                    onPressed: () => controller.revokeDuplicate(warning.mail),
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('Acceptatie intrekken'),
                  )
                : FilledButton.icon(
                    key: ValueKey('dup-accept-${warning.mail}'),
                    onPressed: () => controller.acceptDuplicate(warning.mail),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Deze dubbele mail accepteren'),
                  ),
          ),
        ],
      ),
    );
  }
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
          key: const ValueKey('reconcile-apply-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await apply();
}

/// The pending-actions title (#110/#111): the "Pending actions (N)" heading,
/// plus the "everything is in sync" line when there is nothing to do. Kept a
/// fixed-size adapter above the lazy entry list.
class _PendingActionsHeader extends StatelessWidget {
  const _PendingActionsHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Pending actions ($count)', style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        if (count == 0)
          Text(
            'Everything is in sync — no pending actions.',
            style: text.bodyMedium,
          ),
      ],
    );
  }
}

/// The global dry-run/apply affordances (#110): the secondary escape hatch that
/// acts on every pending entry's chosen resolution. Sits below the lazy entry
/// list as a fixed-size adapter (#111).
class _PendingActionsFooter extends StatelessWidget {
  const _PendingActionsFooter({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PlinkSpacing.s3),
      child: Wrap(
        spacing: PlinkSpacing.s3,
        children: <Widget>[
          OutlinedButton.icon(
            key: const ValueKey('reconcile-dry-run'),
            onPressed: controller.busy || controller.applyableCount == 0
                ? null
                : controller.dryRun,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Dry-run all'),
          ),
          TextButton.icon(
            key: const ValueKey('reconcile-apply'),
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
    );
  }
}

/// The bulk header of one "same situation" subset (#110): the "apply this
/// resolution to all" affordance that honours each entry's own chosen
/// alternative. Rendered as its own row in the lazy list (#111), only when more
/// than one account shares the situation — a lone entry is resolved from its
/// own tile.
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

/// The materialized overview (#115): the school → grade-year → classroom
/// drill-down driven by the stored rollups, so it renders from the shared state
/// even in a passive session that never pulled or re-linked.
class _DrillDownSection extends StatelessWidget {
  const _DrillDownSection({required this.controller});

  final ReconcileController controller;

  String? _freshness() {
    final state = controller.syncState;
    if (state.generation == 0) return null;
    final at = state.updatedAt;
    final when = at == null
        ? ''
        : ' · ${at.toLocal().hour.toString().padLeft(2, '0')}:'
            '${at.toLocal().minute.toString().padLeft(2, '0')}';
    final who = state.updatedBy == null || state.updatedBy!.isEmpty
        ? ''
        : ' door ${state.updatedBy}';
    return 'Generatie ${state.generation}$when$who';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;
    final schools = controller.schoolRollups;
    final groups = controller.groupRollup;
    final freshness = _freshness();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Overzicht', style: text.titleMedium),
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s1),
          Text(freshness, style: text.bodySmall),
        ],
        const SizedBox(height: PlinkSpacing.s3),
        if (schools.isEmpty && groups == null)
          Text('Nog geen gematerialiseerd overzicht.', style: text.bodyMedium)
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
          // The group-family node (#119): class-group actions live outside the
          // school → grade-year → classroom tree, so they get their own entry.
          if (groups != null)
            Container(
              margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
              decoration: BoxDecoration(
                border: Border.all(color: hairline),
                borderRadius:
                    const BorderRadius.all(Radius.circular(PlinkRadius.base)),
              ),
              child: ListTile(
                key: const ValueKey('rollup-groups'),
                title: Text(groups.label, style: text.bodyLarge),
                subtitle: Text('${groups.accountCount} klasgroep(en)',
                    style: text.bodySmall),
                trailing: _PendingBadge(count: groups.pendingCount),
                onTap: controller.openGroups,
              ),
            ),
        ],
      ],
    );
  }
}

/// The "Klasgroepen" drill-down (#119): the per-group docs for the group-action
/// family, lazily loaded from the store — the group counterpart of
/// [_ClassroomDetail]. Renders even in a passive session that never linked.
class _GroupsDetail extends StatelessWidget {
  const _GroupsDetail({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final groups = controller.groupDocs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton.icon(
              key: const ValueKey('reconcile-groups-back'),
              onPressed: controller.closeGroups,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Overzicht'),
            ),
            const SizedBox(width: PlinkSpacing.s2),
            Text(controller.groupRollup?.label ?? 'Klasgroepen',
                style: text.titleMedium),
          ],
        ),
        const SizedBox(height: PlinkSpacing.s3),
        if (controller.loadingGroups)
          const LinearProgressIndicator()
        else if (groups == null || groups.isEmpty)
          Text('Geen klasgroepen met openstaande acties.',
              style: text.bodyMedium)
        else
          for (final group in groups) _GroupTile(group: group),
      ],
    );
  }
}

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

/// One classroom's accounts, lazily loaded from the store on drill-down.
class _ClassroomDetail extends StatelessWidget {
  const _ClassroomDetail({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final classroom = controller.selectedClassroom;
    final accounts = controller.classroomAccounts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton.icon(
              key: const ValueKey('reconcile-classroom-back'),
              onPressed: controller.closeClassroom,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Overzicht'),
            ),
            const SizedBox(width: PlinkSpacing.s2),
            Text(classroom?.label ?? '', style: text.titleMedium),
          ],
        ),
        const SizedBox(height: PlinkSpacing.s3),
        if (controller.loadingClassroom)
          const LinearProgressIndicator()
        else if (accounts == null || accounts.isEmpty)
          Text('Geen accounts in deze klas.', style: text.bodyMedium)
        else
          for (final account in accounts) _AccountTile(account: account),
      ],
    );
  }
}

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

/// The header of a dry-run/apply result set: its title and subtitle, above the
/// lazy list of outcome rows (#111).
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

/// One outcome row of a dry-run/apply pass (#111): the check/cross plus the
/// target and its change summary (or the failure cause). Built lazily by the
/// results [SliverList].
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

/// The vertical extent the log panel opens to before the operator drags it, and
/// the bounds a drag is clamped to (#152). The maximum is computed per layout so
/// the content above always keeps at least [_ResizableLogSection._minContent].
const double _kDefaultLogHeight = 160;
const double _kMinLogHeight = 64;

/// Wraps the reconcile [content] over a [_LogPanel] whose height the operator
/// can change by dragging the [_LogResizeHandle] that replaces the old static
/// divider (#152). The height is in-memory only — the app has no settings/prefs
/// store yet, so a resized panel resets to [_kDefaultLogHeight] on restart.
class _ResizableLogSection extends StatefulWidget {
  const _ResizableLogSection({required this.content, required this.log});

  final Widget content;
  final LogBuffer log;

  @override
  State<_ResizableLogSection> createState() => _ResizableLogSectionState();
}

class _ResizableLogSectionState extends State<_ResizableLogSection> {
  /// Kept for the content above the log so it never collapses to nothing.
  static const double _minContent = 160;

  double _logHeight = _kDefaultLogHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Grow the log as far as the viewport allows while leaving [_minContent]
        // for the scroll area; clamp() keeps the stored height inside that band
        // when the window (and so the available space) shrinks.
        final double maxLog = (constraints.maxHeight - _minContent)
            .clamp(_kMinLogHeight, double.infinity);
        final double logHeight = _logHeight.clamp(_kMinLogHeight, maxLog);
        return Column(
          children: <Widget>[
            Expanded(child: widget.content),
            _LogResizeHandle(
              onDrag: (double dy) => setState(() {
                _logHeight = (logHeight - dy).clamp(_kMinLogHeight, maxLog);
              }),
            ),
            _LogPanel(log: widget.log, height: logHeight),
          ],
        );
      },
    );
  }
}

/// The draggable replacement for the static content/log divider: a thin rule
/// with a centered grab bar. Dragging it vertically reports the delta up to
/// [_ResizableLogSection], which owns the clamped height (#152).
class _LogResizeHandle extends StatelessWidget {
  const _LogResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        key: const ValueKey('reconcile-log-resize'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails d) => onDrag(d.delta.dy),
        child: Container(
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.log, required this.height});

  final LogBuffer log;
  final double height;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return SizedBox(
      key: const ValueKey('reconcile-log-panel'),
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PlinkSpacing.s4,
              PlinkSpacing.s2,
              PlinkSpacing.s4,
              0,
            ),
            child: Row(
              children: <Widget>[
                Text('Log', style: text.titleSmall),
                const Spacer(),
                ListenableBuilder(
                  listenable: log,
                  builder: (context, _) => TextButton(
                    onPressed: log.entries.isEmpty ? null : log.clear,
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: log,
              builder: (context, _) {
                final entries = log.entries.reversed.toList(growable: false);
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PlinkSpacing.s4,
                    ),
                    child: Text('No messages yet.', style: text.bodySmall),
                  );
                }
                // Newest first, anchored to the top — reads like a tail.
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PlinkSpacing.s4,
                    vertical: PlinkSpacing.s2,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final time = '${e.time.hour.toString().padLeft(2, '0')}:'
                        '${e.time.minute.toString().padLeft(2, '0')}:'
                        '${e.time.second.toString().padLeft(2, '0')}';
                    return Text(
                      '$time  [${e.origin.name}]  ${e.message}',
                      style: text.bodySmall?.copyWith(
                        color: e.isError ? colors.error : null,
                        fontFamily: 'monospace',
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

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
