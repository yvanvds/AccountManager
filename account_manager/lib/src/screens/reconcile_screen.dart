import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart' show SystemSyncMeta;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../format/timestamps.dart';
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
      // The session's opening read: the shared overview from the store (#115),
      // and then the linked view built from the same shared state when the cold
      // seed allows it (#287) — no pull either way. Fire-and-forget; it
      // notifies listeners.
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
      return const _MessagePanel(
        eyebrow: 'Arcadia · synchronisatie',
        title: 'Niet geconfigureerd',
        message: 'Azure AD is niet geconfigureerd voor deze build, dus de '
            'instellingenopslag en de connectoren zijn onbereikbaar. Geef de '
            'AAD --dart-define-waarden mee en start opnieuw op.',
      );
    }
    final error = _bootstrapError;
    if (error != null) {
      // A fast failure makes a retry look like a dead button — say the
      // attempt happened.
      final retryNote = _attempts > 1 ? '\n\n(Poging $_attempts mislukt.)' : '';
      return _MessagePanel(
        eyebrow: 'Arcadia · synchronisatie',
        title: 'Kan het Synchronisatie-scherm niet openen',
        message: '$error$retryNote',
        action: FilledButton(
          key: const ValueKey('reconcile-bootstrap-retry'),
          onPressed: _bootstrap,
          child: const Text('Probeer opnieuw'),
        ),
      );
    }
    final services = _services;
    if (_bootstrapping || services == null) {
      return const _MessagePanel(
        eyebrow: 'Arcadia · synchronisatie',
        title: 'Voorbereiden…',
        message: 'De instellingen en verbindingsprofielen worden geladen.',
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

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool ink = Theme.of(context).brightness == Brightness.dark;
    final bool hasFreshness = controller.syncState.systems.isNotEmpty;
    final lockedByOther = controller.syncLockedByOther;
    // Why "Controleer op drift" is unavailable, when it is the WISA settings
    // rather than another operator's lease that blocks it (#238).
    final String? driftBlocked = controller.driftBlockedReason;
    // The one class of saved setting this running session cannot adopt — the
    // connection profiles the connectors were constructed from (#246).
    final String? relaunch = controller.relaunchRequiredReason;
    // Saved Smartschool / Azure pull inputs the next pass will adopt but no
    // pass has yet (#259), and since #264 the ones only the link consumes (the
    // Azure domain, the Smartschool class tree) — the gap in which
    // Synchroniseer used to report "geen accountwijzigingen nodig" over a save
    // it had skipped.
    final String? pendingSettings = controller.pendingSettingsReason;
    // Whose sync this session is working from, when it adopted the shared state
    // rather than pulling for itself (#287) — and, when it could not, the one
    // blocking reason it stays read-only.
    final SystemSyncMeta? adopted = controller.adoptedFrom;
    final String? seedRefused = controller.seedRefusedReason;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow('Arcadia · synchronisatie', onInk: ink),
        const SizedBox(height: PlinkSpacing.s4),
        // The page names itself the way the rail names it (#257).
        Text('Synchronisatie', style: text.headlineMedium),
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
              // The screen's own controls speak the operator's language, like
              // the rail that leads here and the heading above them (#265).
              // "Synchroniseer" is what the Acties read-only banner already
              // calls this very action.
              label: const Text('Synchroniseer'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('reconcile-drift'),
              // Also disabled while a saved WISA setting has not been synced
              // yet: a drift pass never re-reads WISA, so it would reconcile
              // against the roster the change never reached (#238).
              onPressed:
                  controller.canCheckDrift ? controller.checkDrift : null,
              icon: const Icon(Icons.difference_outlined),
              // The pass the last-sync box already calls a "driftcontrole",
              // phrased as the imperative its neighbour is (#265).
              label: const Text('Controleer op drift'),
            ),
          ],
        ),
        if (driftBlocked != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-drift-blocked'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.info_outline, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(child: Text(driftBlocked, style: text.bodySmall)),
            ],
          ),
        ],
        if (pendingSettings != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-settings-pending'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.info_outline, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(child: Text(pendingSettings, style: text.bodySmall)),
            ],
          ),
        ],
        if (adopted != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-adopted'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.groups_outlined, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(
                child: Text(
                  'Deze sessie werkt met de gedeelde synchronisatie van '
                  '${formatFreshnessStamp(adopted.at)}'
                  '${adopted.syncedBy.isEmpty ? '' : ', door '
                      '${adopted.syncedBy}'}'
                  ' — er is niets opgehaald.',
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        ],
        if (seedRefused != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-seed-refused'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.info_outline, size: 16, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(child: Text(seedRefused, style: text.bodySmall)),
            ],
          ),
        ],
        if (relaunch != null) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          Row(
            key: const ValueKey('reconcile-relaunch-required'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.warning_amber_outlined, size: 16, color: colors.error),
              const SizedBox(width: PlinkSpacing.s2),
              Flexible(child: Text(relaunch, style: text.bodySmall)),
            ],
          ),
        ],
        if (hasFreshness) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s4),
          _LastSyncBox(controller: controller),
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
          // A determinate bar that steps forward through the pass (#176): each
          // system pulled, linking, persisting, and every applied action nudges
          // [ReconcileController.progress], so the operator sees the reconcile
          // advancing instead of a motionless sweep that reads as a hung app.
          LinearProgressIndicator(
            key: const ValueKey('reconcile-progress'),
            value: controller.progress,
          ),
        ],
      ],
    );
  }
}

/// The shared per-system last-sync box (#188): a bordered card headed
/// "Laatste synchronisatie" with one row per system — WISA, Smartschool,
/// Azure — each on its own line showing whether it was refreshed by a sync or a
/// drift check, the time, and which operator ran it. This replaces the old
/// run-on freshness line that packed all three systems into a single wrapped
/// sentence.
///
/// Read from the materialized store so it names *whichever* operator last synced
/// each system — not just this session (#108). WISA is what **Synchroniseer**
/// targets; Smartschool and Azure are refreshed by **Controleer op drift**, so a
/// later WISA-only smart-sync reads as "synced then, drift-checked earlier" per
/// row rather than an unexplained gap between timestamps (#170). Only rendered
/// once at least one system has been synced.
class _LastSyncBox extends StatelessWidget {
  const _LastSyncBox({required this.controller});

  final ReconcileController controller;

  /// The systems in display order, each with its label and whether it is
  /// refreshed by **Synchroniseer** (`isSync`) or by **Controleer op drift**.
  static const List<(core.Origin, String, bool)> _rows =
      <(core.Origin, String, bool)>[
    (core.Origin.wisa, 'WISA', true),
    (core.Origin.smartschool, 'Smartschool', false),
    (core.Origin.azure, 'Azure', false),
  ];

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color hairline = Theme.of(context).dividerColor;
    final systems = controller.syncState.systems;

    return Container(
      key: const ValueKey('reconcile-last-sync'),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.schedule_outlined, size: 18, color: colors.primary),
              const SizedBox(width: PlinkSpacing.s2),
              Text('Laatste synchronisatie', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: PlinkSpacing.s3),
          for (final (system, label, isSync) in _rows)
            _SystemRow(
              system: system,
              label: label,
              isSync: isSync,
              meta: systems[system],
            ),
        ],
      ),
    );
  }
}

/// One system's row inside the [_LastSyncBox]: a fixed-width name column so the
/// three statuses line up, then the sync/drift icon and a
/// "kind · when · by who" status, where the stamp is dated as soon as it
/// leaves today (#192). A system that has never been synced shows a muted
/// placeholder rather than being dropped, so all three systems are always
/// accounted for.
class _SystemRow extends StatelessWidget {
  const _SystemRow({
    required this.system,
    required this.label,
    required this.isSync,
    required this.meta,
  });

  final core.Origin system;
  final String label;
  final bool isSync;
  final SystemSyncMeta? meta;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final SystemSyncMeta? meta = this.meta;

    final String status;
    if (meta == null) {
      status = 'nog niet gesynchroniseerd';
    } else {
      // Dated as soon as it leaves today (#192): a stamp from three days ago
      // must not read like this morning's, since a stale row is exactly what
      // this box exists to surface.
      final String when = formatFreshnessStamp(meta.at);
      final String kind = isSync ? 'synchronisatie' : 'driftcontrole';
      final String by = meta.syncedBy.isEmpty ? '' : ' · door ${meta.syncedBy}';
      status = '$kind · $when$by';
    }

    return Padding(
      key: ValueKey('reconcile-last-sync-${system.name}'),
      padding: const EdgeInsets.only(bottom: PlinkSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              isSync ? Icons.sync : Icons.difference_outlined,
              size: 16,
              color: meta == null ? colors.onSurfaceVariant : colors.primary,
            ),
          ),
          const SizedBox(width: PlinkSpacing.s2),
          Expanded(
            child: Text(
              status,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
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
                // Word for word the Log line #258 already writes beside it, so
                // the banner and the log do not say the same thing twice in
                // two different phrasings (#265).
                'WISA is ongewijzigd sinds de vorige synchronisatie — '
                'geen accountwijzigingen nodig.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }
    // Until the operator starts their first pass, the banner explains the two
    // buttons above it instead of reporting on a pass that has not run. It only
    // reaches the screen because a passive `loadOverview` read no longer claims
    // the pass phase `ready` (#275) — for most of this screen's life it was
    // gated on a phase the store read moved off before the first frame.
    if (controller.phase == ReconcilePhase.idle) {
      return Text(
        'Synchroniseer haalt WISA op en vergelijkt het met de vorige '
        'momentopname; Smartschool en Azure worden één keer per sessie '
        'gelezen. Gebruik "Controleer op drift" wanneer accounts via een '
        'ander programma zijn aangepast.',
        key: const ValueKey('reconcile-explainer'),
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
    final collisions = controller.linkIdCollisions;
    final azureIdentities = controller.azureIdentityCollisions;
    final students = controller.studentSummary;
    final staff = controller.staffSummary;
    final groups = controller.groupSummary;
    final pending = students.pending + staff.pending + groups.pending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The same word the Acties tree heads itself with (#253), so the two
        // tabs name the same kind of section the same way (#265).
        Text('Overzicht', style: text.titleMedium),
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
        // Above nothing and below everything: an id collision (#319) is rarer
        // and more serious than a duplicate mail — it means the view itself is
        // wrong, not that two accounts need tidying — so it is never folded
        // into the duplicate list.
        if (collisions.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          for (final c in collisions) _IdCollisionTile(collision: c),
        ],
        // Beneath those again (INV-26, #360). Not folded into the duplicate-mail
        // list above it either: a shared mail is two Smartschool accounts to
        // tidy, this is two Office 365 accounts for one person — one of which
        // may hold their mailbox — and it is resolved in Entra, not here.
        if (azureIdentities.isNotEmpty) ...<Widget>[
          const SizedBox(height: PlinkSpacing.s3),
          for (final c in azureIdentities)
            _AzureIdentityCollisionTile(collision: c),
        ],
      ],
    );
  }
}

/// Two or more Office 365 accounts on one WISA id, as a plain, always-expanded
/// notice (INV-26, #360): the headline says how many accounts share the id, and
/// each account gets a line with the facts that tell the live one from the
/// abandoned one — UPN, object id, whether it is enabled, and the
/// `companyName`/`jobTitle` pair the licence group's rule turns on.
///
/// Shown open and with no control, for the same reason [_IdCollisionTile] is:
/// there is nothing here for the app to do. Resolving the pair means deleting an
/// account, and the wrong one holds the student's mail and OneDrive — so this
/// states the case and leaves the decision, and the deletion, to the operator in
/// Entra.
class _AzureIdentityCollisionTile extends StatelessWidget {
  const _AzureIdentityCollisionTile({required this.collision});

  final AzureIdentityCollision collision;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Container(
      key: ValueKey('azure-identity-collision-${collision.employeeId}'),
      margin: const EdgeInsets.only(top: PlinkSpacing.s2),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.error),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.person_search_outlined, size: 20, color: colors.error),
          const SizedBox(width: PlinkSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Dubbel Office 365-account: ${collision.accounts.length} '
                  'accounts dragen WISA-id "${collision.employeeId}". '
                  'De app kiest niet — los dit op in Entra.',
                  style: text.bodyMedium,
                ),
                for (final a in collision.accounts) ...<Widget>[
                  const SizedBox(height: PlinkSpacing.s2),
                  Text(a, style: text.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An id collision as a plain, always-expanded notice (#319): the headline says
/// how many records share the id, and each colliding record gets a line naming
/// what it holds in each system.
///
/// Not an [ExpansionTile] like the duplicate-mail warning next to it, and with
/// no accept/revoke: there is nothing here for the operator to decide. The one
/// useful thing is that they can see the collision at all — and can tell support
/// exactly which id and which records are involved — so it is shown open.
class _IdCollisionTile extends StatelessWidget {
  const _IdCollisionTile({required this.collision});

  final LinkIdCollision collision;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Container(
      key: ValueKey('id-collision-${collision.id}'),
      margin: const EdgeInsets.only(top: PlinkSpacing.s2),
      padding: const EdgeInsets.all(PlinkSpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.error),
        borderRadius: const BorderRadius.all(Radius.circular(PlinkRadius.base)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 20, color: colors.error),
          const SizedBox(width: PlinkSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Koppelingsfout: ${collision.records.length} records delen '
                  'id "${collision.id}", zodat hun acties op één kaart '
                  'terechtkomen.',
                  style: text.bodyMedium,
                ),
                for (final r in collision.records) ...<Widget>[
                  const SizedBox(height: PlinkSpacing.s2),
                  Text(r, style: text.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
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

class _LogPanel extends StatefulWidget {
  const _LogPanel({required this.log, required this.height});

  final LogBuffer log;
  final double height;

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  /// Anchors the rendered paragraph so a right-click can be resolved back to
  /// the entry underneath it (#197).
  ///
  /// It sits on a [KeyedSubtree] around the paragraph rather than on the [Text]
  /// itself, which keeps `reconcile-log-text` the plain [ValueKey] #193 left.
  final GlobalKey _paragraphKey = GlobalKey();

  static void _copy(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  /// Puts the whole buffer on the clipboard, oldest first (#193).
  ///
  /// Reads [LogBuffer.toPlainText] rather than the on-screen selection: only
  /// what fits the panel is laid out, so a selection can never cover all 500
  /// entries a long reconcile pass leaves behind.
  void _copyAll() => _copy(widget.log.toPlainText());

  /// The paragraph's render object, or `null` before it has been laid out.
  ///
  /// Descends instead of casting whatever the key points at: [Text] wraps its
  /// [RichText] in semantics and selection plumbing, so the [RenderParagraph]
  /// is not necessarily the topmost render object under the key.
  static RenderParagraph? _firstParagraph(RenderObject? node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node?.visitChildren((RenderObject child) {
      found ??= _firstParagraph(child);
    });
    return found;
  }

  /// Which rendered entry sits under a global [position], or `null` when the
  /// pointer is not over the paragraph at all — right-clicking the empty space
  /// under a short log has no line to copy (#197).
  int? _entryIndexAt(Offset position) {
    final RenderParagraph? paragraph =
        _firstParagraph(_paragraphKey.currentContext?.findRenderObject());
    if (paragraph == null || !paragraph.hasSize) return null;
    final Offset local = paragraph.globalToLocal(position);
    if (!(Offset.zero & paragraph.size).contains(local)) return null;
    return logEntryIndexAt(
      paragraph.text.toPlainText(),
      paragraph.getPositionForOffset(local).offset,
    );
  }

  /// The panel's right-click menu: the framework's own items plus **Regel
  /// kopiëren**, which takes the single entry under the pointer (#197).
  ///
  /// Grabbing one message was already possible — the entries render as one
  /// paragraph (#193), so a triple-click selects exactly one line — but
  /// nothing on screen said so, which is what this makes visible. The line
  /// index has to come from the paragraph's own text, because that single
  /// paragraph is precisely what leaves no per-row widget to hang a hover
  /// button on: SelectionArea concatenates separate selectables with no
  /// separator, so a widget per entry would copy a multi-line selection as one
  /// unreadable blob.
  Widget _contextMenu(
    BuildContext context,
    SelectableRegionState region,
    List<LogEntry> entries,
  ) {
    // Read once and hold on to it: SelectableRegionState clears the
    // right-click position the first time contextMenuAnchors is read.
    final TextSelectionToolbarAnchors anchors = region.contextMenuAnchors;
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      ...region.contextMenuButtonItems,
    ];
    final int? index = _entryIndexAt(anchors.primaryAnchor);
    if (index != null && index < entries.length) {
      final LogEntry entry = entries[index];
      items.insert(
        0,
        ContextMenuButtonItem(
          label: 'Regel kopiëren',
          onPressed: () {
            region.hideToolbar();
            _copy(entry.line);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LogBuffer log = widget.log;

    return SizedBox(
      key: const ValueKey('reconcile-log-panel'),
      height: widget.height,
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
                Text('Logboek', style: text.titleSmall),
                const Spacer(),
                ListenableBuilder(
                  listenable: log,
                  builder: (context, _) {
                    final bool empty = log.entries.isEmpty;
                    return Row(
                      children: <Widget>[
                        TextButton(
                          key: const ValueKey('reconcile-log-copy-all'),
                          onPressed: empty ? null : _copyAll,
                          child: const Text('Alles kopiëren'),
                        ),
                        TextButton(
                          key: const ValueKey('reconcile-log-clear'),
                          onPressed: empty ? null : log.clear,
                          child: const Text('Wissen'),
                        ),
                      ],
                    );
                  },
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
                    child: Text('Nog geen berichten.', style: text.bodySmall),
                  );
                }
                // Newest first, anchored to the top — reads like a tail.
                //
                // One selectable paragraph rather than a widget per entry
                // (#193): SelectionArea concatenates the text of separate
                // selectables with no separator at all
                // (MultiSelectableSelectionContainerDelegate.getSelectedContent),
                // so dragging across a list of per-entry Texts would copy the
                // lines run together into one unreadable blob — exactly the
                // thing an operator is pasting into a support ticket. Keeping
                // the newlines inside a single paragraph makes the copy line
                // per entry, and makes triple-click select exactly one entry;
                // per-entry spans keep the error colour. The per-line copy
                // affordance (#197) therefore hangs off the context menu, with
                // the line resolved from the paragraph's own text.
                return SelectionArea(
                  contextMenuBuilder:
                      (BuildContext context, SelectableRegionState region) =>
                          _contextMenu(context, region, entries),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PlinkSpacing.s4,
                      vertical: PlinkSpacing.s2,
                    ),
                    child: KeyedSubtree(
                      key: _paragraphKey,
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            for (int i = 0; i < entries.length; i++)
                              TextSpan(
                                text: i == entries.length - 1
                                    ? entries[i].line
                                    : '${entries[i].line}\n',
                                style: entries[i].isError
                                    ? TextStyle(color: colors.error)
                                    : null,
                              ),
                          ],
                        ),
                        key: const ValueKey('reconcile-log-text'),
                        style:
                            text.bodySmall?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
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
