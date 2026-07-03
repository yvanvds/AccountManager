import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart' show LinkedState;
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

  Future<void> _confirmApply(BuildContext context) async {
    final count = controller.applyableCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply pending actions?'),
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
    if (confirmed ?? false) await controller.applyAll();
  }

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
                        if (linked != null) ...<Widget>[
                          const SizedBox(height: PlinkSpacing.s5),
                          _OverviewSection(linked: linked),
                          const SizedBox(height: PlinkSpacing.s5),
                          _ActionsSection(
                            controller: controller,
                            onApply: () => _confirmApply(context),
                          ),
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

  String? _freshness() {
    final app = controller.app;
    String stamp(DateTime? t) => t == null
        ? '—'
        : '${t.toLocal().hour.toString().padLeft(2, '0')}:'
            '${t.toLocal().minute.toString().padLeft(2, '0')}';
    if (app.wisa.lastSync == null &&
        app.smartschool.lastSync == null &&
        app.azure.lastSync == null) {
      return null;
    }
    return 'Last sync — WISA ${stamp(app.wisa.lastSync)} · '
        'Smartschool ${stamp(app.smartschool.lastSync)} · '
        'Azure ${stamp(app.azure.lastSync)}';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final freshness = _freshness();

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
              onPressed: controller.busy ? null : controller.sync,
              icon: const Icon(Icons.sync),
              label: const Text('Synchronise'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('reconcile-drift'),
              onPressed: controller.busy ? null : controller.checkDrift,
              icon: const Icon(Icons.difference_outlined),
              label: const Text('Check for drift'),
            ),
            if (freshness != null) Text(freshness, style: text.bodySmall),
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
  const _OverviewSection({required this.linked});

  final LinkedState linked;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final snapshot = linked.snapshot;

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
        if (snapshot.warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          ...snapshot.warnings.map((w) => _WarningLine(warning: w)),
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

class _WarningLine extends StatelessWidget {
  const _WarningLine({required this.warning});

  final core.LinkWarning warning;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String message = switch (warning) {
      core.ResolveDuplicateMail(:final mail, :final accounts) =>
        'Duplicate mail "$mail" on ${accounts.length} Smartschool accounts.',
    };
    return Padding(
      padding: const EdgeInsets.only(top: PlinkSpacing.s1),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber_outlined, size: 16, color: colors.error),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _ActionsSection extends StatelessWidget {
  const _ActionsSection({required this.controller, required this.onApply});

  final ReconcileController controller;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final pending = controller.pendingViews;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Pending actions (${pending.length})', style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        if (pending.isEmpty)
          Text(
            'Everything is in sync — no pending actions.',
            style: text.bodyMedium,
          )
        else ...<Widget>[
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
              FilledButton.icon(
                key: const ValueKey('reconcile-apply'),
                onPressed: controller.busy || controller.applyableCount == 0
                    ? null
                    : onApply,
                icon: const Icon(Icons.play_arrow_outlined),
                label: const Text('Apply all'),
              ),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          ...pending.map((p) => _PendingActionTile(view: p)),
        ],
      ],
    );
  }
}

class _PendingActionTile extends StatelessWidget {
  const _PendingActionTile({required this.view});

  final PendingActionView view;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color hairline = Theme.of(context).dividerColor;

    return Container(
      margin: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: PlinkBadge(view.family),
        title: Text(view.target, style: text.bodyLarge),
        subtitle: Text(
          view.canApply
              ? view.changes.summary
              : '${view.changes.summary} (manual — not applied automatically)',
          style: text.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          PlinkSpacing.s5,
          0,
          PlinkSpacing.s5,
          PlinkSpacing.s4,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: view.changes.fields.isEmpty
            ? <Widget>[
                Text(
                  'Lifecycle action — no per-field diff.',
                  style: text.bodySmall,
                ),
              ]
            : <Widget>[
                for (final f in view.changes.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: PlinkSpacing.s1),
                    child: Text(
                      '${f.field}: ${f.before ?? '∅'} → ${f.after ?? '∅'}',
                      style: text.bodySmall,
                    ),
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
