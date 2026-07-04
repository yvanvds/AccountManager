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

class _ReconcileBody extends StatelessWidget {
  const _ReconcileBody({required this.controller, required this.log});

  final ReconcileController controller;
  final LogBuffer log;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final linked = controller.linked;
        return Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(PlinkSpacing.s6),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _Header(controller: controller),
                        const SizedBox(height: PlinkSpacing.s5),
                        _StatusBanner(controller: controller),
                        if (controller.selectedClassroom != null) ...<Widget>[
                          const SizedBox(height: PlinkSpacing.s5),
                          _ClassroomDetail(controller: controller),
                        ] else if (controller.showingGroups) ...<Widget>[
                          const SizedBox(height: PlinkSpacing.s5),
                          _GroupsDetail(controller: controller),
                        ] else if (controller.hasOverview) ...<Widget>[
                          const SizedBox(height: PlinkSpacing.s5),
                          _DrillDownSection(controller: controller),
                        ],
                        if (linked != null) ...<Widget>[
                          const SizedBox(height: PlinkSpacing.s5),
                          _OverviewSection(
                            linked: linked,
                            controller: controller,
                          ),
                          const SizedBox(height: PlinkSpacing.s5),
                          _ActionsSection(controller: controller),
                        ],
                        ..._results(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1),
            _LogPanel(log: log),
          ],
        );
      },
    );
  }

  List<Widget> _results(BuildContext context) {
    final dry = controller.dryRunResults;
    final applied = controller.applyResults;
    return <Widget>[
      if (dry != null) ...<Widget>[
        const SizedBox(height: PlinkSpacing.s5),
        _ResultsSection(
          title: 'Dry-run result',
          subtitle: 'No changes were written. This is what an apply would do.',
          results: dry,
        ),
      ],
      if (applied != null) ...<Widget>[
        const SizedBox(height: PlinkSpacing.s5),
        _ResultsSection(
          title: 'Apply result',
          subtitle: 'Written to the target systems.',
          results: applied,
        ),
      ],
    ];
  }
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

/// The pending-actions list (#110): **one entry per account**, mutually
/// exclusive resolutions rendered as a choice, and per-entry / per-situation
/// apply as the primary affordances. The global "apply all" is kept as a
/// secondary escape hatch, not the headline.
class _ActionsSection extends StatelessWidget {
  const _ActionsSection({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final entries = controller.pendingEntries;
    final situations = controller.pendingSituations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Pending actions (${entries.length})', style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        if (entries.isEmpty)
          Text(
            'Everything is in sync — no pending actions.',
            style: text.bodyMedium,
          )
        else ...<Widget>[
          for (final subset in situations)
            _SituationSection(controller: controller, entries: subset),
          const SizedBox(height: PlinkSpacing.s3),
          Wrap(
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
        ],
      ],
    );
  }
}

/// One "same situation" subset (#110): the entries whose situation matches, with
/// a bulk "apply this resolution to all" affordance that honours each entry's
/// own chosen alternative. The bulk header only appears when more than one
/// account is in the situation — a lone entry is resolved from its own tile.
class _SituationSection extends StatelessWidget {
  const _SituationSection({required this.controller, required this.entries});

  final ReconcileController controller;
  final List<PendingAccountEntry> entries;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final key = entries.first.situationKey;
    final applyable = entries.where((e) => e.canApply).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (entries.length > 1) ...<Widget>[
          Padding(
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
          ),
        ],
        for (final entry in entries)
          _PendingEntryTile(controller: controller, entry: entry),
      ],
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

class _ResultsSection extends StatelessWidget {
  const _ResultsSection({
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
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s1),
        Text(subtitle, style: text.bodySmall),
        const SizedBox(height: PlinkSpacing.s3),
        for (final r in results)
          Padding(
            padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  r.outcome == actions.ActionOutcome.failed
                      ? Icons.close
                      : Icons.check,
                  size: 16,
                  color: r.outcome == actions.ActionOutcome.failed
                      ? colors.error
                      : colors.primary,
                ),
                const SizedBox(width: PlinkSpacing.s2),
                Expanded(
                  child: Text(
                    r.outcome == actions.ActionOutcome.failed
                        ? '${r.target} — ${r.changes.summary}: ${r.error}'
                        : '${r.target} — ${r.changes.summary}',
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.log});

  final LogBuffer log;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return SizedBox(
      height: 160,
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
