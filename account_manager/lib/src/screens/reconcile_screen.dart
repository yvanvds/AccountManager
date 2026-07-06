import 'dart:async';

import 'package:account_core/account_core.dart' as core;
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

  /// Reconcile is now short and responsive (#154): the sync/drift header, the
  /// status banner, and — as soon as *any* operator has synced — the per-category
  /// overview (students / staff / class groups with their pending indicators)
  /// with the duplicate-mail warnings. The overview reads from the stored rollups
  /// (#163), so it renders in a passive session that never linked; the pending
  /// actions and their per-year/per-class drill-down live on the Actions tab.
  List<Widget> _slivers() {
    final slivers = <Widget>[
      _gap(PlinkSpacing.s6),
      _section(_Header(controller: controller)),
      _gap(PlinkSpacing.s5),
      _section(_StatusBanner(controller: controller)),
    ];
    if (controller.hasOverview || controller.duplicateWarnings.isNotEmpty) {
      slivers
        ..add(_gap(PlinkSpacing.s5))
        ..add(_section(_OverviewSection(controller: controller)));
    }
    slivers.add(_gap(PlinkSpacing.s6));
    return slivers;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final ReconcileController controller;

  /// The shared per-system freshness line, e.g. "Last sync — WISA 09:12 by
  /// jan@… · drift check — Smartschool 10:24 · Azure 10:25". Read from the
  /// materialized store so it names *whichever* operator last synced each system
  /// — not just this session (#108). WISA (the Synchronise target) and the
  /// drift-checked pair (Smartschool, Azure) render as two clauses so their
  /// differing times are self-explanatory (#170). Null before any sync.
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

    // WISA is refreshed by Synchronise; Smartschool and Azure are refreshed by
    // Check for drift. Present them as two labelled clauses so a later WISA-only
    // smart-sync reads as "synced then, drift-checked earlier" rather than an
    // unexplained gap between the timestamps (#170).
    final segments = <String>[];
    if (stamp(core.Origin.wisa, 'WISA') case final wisa?) {
      segments.add('Last sync — $wisa');
    }
    final drift = <String>[
      for (final (system, label) in const [
        (core.Origin.smartschool, 'Smartschool'),
        (core.Origin.azure, 'Azure'),
      ])
        if (stamp(system, label) case final s?) s,
    ];
    if (drift.isNotEmpty) {
      segments.add('drift check — ${drift.join(' · ')}');
    }
    if (segments.isEmpty) return null;
    return segments.join(' · ');
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
          ],
        ),
        if (freshness != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-freshness'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.schedule_outlined, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(
                child: Text(
                  freshness,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
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

/// The at-a-glance category overview restored to the Reconcile tab (#163): the
/// students / staff / class-groups totals with a per-category pending indicator,
/// summed from the stored rollups so it renders even in a passive session that
/// never linked. The duplicate-mail warnings stay here beneath it; they come
/// from the live linked view, so they only appear in an active session.
class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.controller});

  final ReconcileController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final duplicates = controller.duplicateWarnings;
    final students = controller.studentSummary;
    final staff = controller.staffSummary;
    final groups = controller.groupSummary;
    final pending = students.pending + staff.pending + groups.pending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Overview', style: text.titleMedium),
        const SizedBox(height: PlinkSpacing.s3),
        Wrap(
          spacing: PlinkSpacing.s4,
          runSpacing: PlinkSpacing.s4,
          children: <Widget>[
            _CategoryTile(
              key: const ValueKey('reconcile-category-students'),
              category: 'Leerlingen',
              summary: students,
            ),
            _CategoryTile(
              key: const ValueKey('reconcile-category-staff'),
              category: 'Personeel',
              summary: staff,
            ),
            _CategoryTile(
              key: const ValueKey('reconcile-category-groups'),
              category: 'Klasgroepen',
              summary: groups,
            ),
          ],
        ),
        if (pending > 0) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Text(
            'Bekijk en pas de openstaande acties toe op het tabblad Acties.',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        if (duplicates.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          for (final w in duplicates)
            _DuplicateWarningTile(controller: controller, warning: w),
        ],
      ],
    );
  }
}

/// One category card in the Reconcile overview (#163): its name, the total count
/// of accounts/groups it holds, and a pending indicator — a check when nothing
/// is outstanding, otherwise the count of applyable actions (which the Actions
/// tab drills into).
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    super.key,
    required this.category,
    required this.summary,
  });

  final String category;
  final CategorySummary summary;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color hairline = Theme.of(context).dividerColor;
    final int pending = summary.pending;
    final bool clear = pending == 0;

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
          PlinkBadge(category),
          const SizedBox(height: PlinkSpacing.s3),
          Text('${summary.total}', style: text.headlineSmall),
          const SizedBox(height: PlinkSpacing.s2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                clear ? Icons.check_circle_outline : Icons.pending_actions,
                size: 16,
                color: clear ? colors.primary : colors.error,
              ),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(
                child: Text(
                  clear
                      ? 'geen openstaande acties'
                      : '$pending openstaande '
                          '${pending == 1 ? 'actie' : 'acties'}',
                  style: text.bodySmall,
                ),
              ),
            ],
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
