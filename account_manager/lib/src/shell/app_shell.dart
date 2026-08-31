import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../reconcile/reconcile_controller.dart';
import '../screens/action_tiles.dart';
import '../screens/actions_screen.dart';
import '../screens/class_groups_screen.dart';
import '../screens/passwords_screen.dart';
import '../screens/reconcile_screen.dart';
import '../screens/settings_screen.dart';
import '../settings/connection_config.dart';
import '../settings/local_preferences.dart';
import '../settings/settings_bootstrap.dart';
import '../update/app_release.dart' show AppRelease;
import '../update/release_notes.dart';
import '../update/update_controller.dart';
import 'shell_navigation.dart';

export 'shell_navigation.dart';

/// One navigable destination in the [AppShell].
class ShellDestination {
  const ShellDestination({
    required this.tab,
    required this.label,
    required this.icon,
    required this.builder,
  });

  /// Which destination this is, so a screen can ask for it by name (#301).
  final ShellTab tab;

  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// The navigation frame for the whole app.
///
/// Deliberately minimal: each Phase C view slice (settings, passwords, …) adds
/// one entry to the destinations — the shell is built to grow, not to mirror
/// the seven legacy WPF pages up front.
///
/// The rail is ordered as the work is done (#366) — Synchronisatie,
/// Klasgroepen, Acties, Wachtwoorden, Instellingen — and there is no landing
/// page above it: a Start placeholder cost the first click of every session.
///
/// It is also a status surface rather than only a menu (#367): the Klasgroepen
/// and Acties entries wear a counter chip for what they are holding, so "does
/// this session need work, and where?" is answered without a click.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.reconcileBootstrap,
    this.settingsBootstrap,
    this.connection,
    this.update,
    this.preferences,
    this.openReleaseLink,
  });

  /// Assembles the reconcile stack on first use, or `null` when Azure AD is
  /// not configured for this build.
  final Future<ReconcileServices> Function()? reconcileBootstrap;

  /// Assembles the settings seams (store + secret provider) on first use, or
  /// `null` when Azure AD is not configured for this build.
  final Future<SettingsServices> Function()? settingsBootstrap;

  /// This machine's backend coordinates and the reachability probe (#370),
  /// handed straight to the Settings view's Verbinding section. Unlike the two
  /// bootstraps it is never gated on AAD: it is what an operator reaches for
  /// when the rest of the configuration is wrong.
  final ConnectionServices? connection;

  /// How this build finds out about newer published releases (#371).
  ///
  /// The shell owns the controller rather than `main()` because the shell is
  /// what has a lifecycle to hang it on — and because the two surfaces that read
  /// it (the offer bar above the rail, and the Versie section in Instellingen)
  /// are both below this point in the tree.
  final UpdateServices? update;

  /// This machine's remembered state (#394), which the update check needs for
  /// the "notes last seen for version X" marker (#395).
  ///
  /// Passed down explicitly rather than read out of [LocalPreferencesScope]:
  /// the controller is built in [State.initState], where an inherited lookup is
  /// not allowed, and the marker has to be in hand before the check answers.
  /// `null` gives the controller a session-only bag — a widget test pumping the
  /// shell then remembers within its run and forgets at the end, which is what
  /// it should do.
  final LocalPreferences? preferences;

  /// Where a link in the **Wat is er nieuw** dialog goes; `null` means the
  /// operator's default browser. A seam so a test can follow the link without
  /// starting a process.
  final Future<void> Function(Uri url)? openReleaseLink;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<ShellDestination> _destinations = <ShellDestination>[
    // Every label is the operator's language and the name of the page behind
    // it (#257): the rail is read together with the heading it leads to, so a
    // rail saying "Actions" over a page titled "Acties" reads as two apps.
    // First, and the destination a launch lands on (#366): the session begins
    // by pulling, or by deciding the shared state is fresh enough.
    ShellDestination(
      tab: ShellTab.synchronisatie,
      label: 'Synchronisatie',
      icon: Icons.sync_alt_outlined,
      builder: (_) => ReconcileScreen(bootstrap: widget.reconcileBootstrap),
    ),
    // The class inventory (#227). A destination of its own rather than a node
    // inside Acties: it lists *every* class, so it answers "is this right?",
    // which the action list structurally cannot.
    //
    // Above Acties (#366) because class-group work is upstream of account work:
    // a class that has to be created, renamed or split must be applied before
    // the account actions that place students into it, or those actions land
    // against a group that is about to change. The rail reads top-to-bottom in
    // the order the operator is meant to work.
    ShellDestination(
      tab: ShellTab.klasgroepen,
      label: 'Klasgroepen',
      icon: Icons.groups_outlined,
      builder: (_) => ClassGroupsScreen(bootstrap: widget.reconcileBootstrap),
    ),
    ShellDestination(
      tab: ShellTab.acties,
      label: 'Acties',
      icon: Icons.checklist_outlined,
      builder: (_) => ActionsScreen(bootstrap: widget.reconcileBootstrap),
    ),
    ShellDestination(
      tab: ShellTab.wachtwoorden,
      label: 'Wachtwoorden',
      icon: Icons.password_outlined,
      builder: (_) => PasswordsScreen(bootstrap: widget.reconcileBootstrap),
    ),
    ShellDestination(
      tab: ShellTab.instellingen,
      label: 'Instellingen',
      icon: Icons.settings_outlined,
      builder: (_) => SettingsScreen(
        bootstrap: widget.settingsBootstrap,
        connection: widget.connection,
        update: _update,
      ),
    ),
  ];

  /// The update check for this session (#371), or `null` on a build with no
  /// update mechanism wired.
  ///
  /// Built in [initState] — before `_destinations` is first read, which happens
  /// on the first build — so the Settings destination closes over the same
  /// instance the offer bar renders from.
  UpdateController? _update;

  /// Index 0 is Synchronisatie, so a launch lands on the screen the session
  /// actually begins on (#366) rather than on a placeholder to click past.
  int _selected = 0;

  /// The controller the rail's counter chips are read from (#367), once the
  /// reconcile stack has been assembled — `null` before that, and for good on a
  /// build where Azure AD is not configured.
  ReconcileController? _counts;

  /// Whether an adoption attempt is already in flight, so a burst of rail taps
  /// starts one.
  bool _adopting = false;

  /// Whether a class-inventory read is already queued (see [_ensureGroups]).
  bool _warming = false;

  @override
  void initState() {
    super.initState();
    unawaited(_adopt());

    // Fired and forgotten, which is the whole non-blocking requirement (#371):
    // the first frame is built from this same `initState`, so nothing on screen
    // is waiting on a network round-trip. `start()` never throws — a failed or
    // offline check is a log line and nothing else.
    final UpdateServices? services = widget.update;
    if (services != null) {
      final UpdateController controller = UpdateController(
        services,
        preferences: widget.preferences,
      );
      _update = controller;
      // The **Wat is er nieuw** dialog (#395) is the one thing the check may
      // put on screen by itself, so it hangs off the same listener rather than
      // off a `build`: a dialog opened from a build runs during a frame the
      // navigator is already laying out.
      controller.addListener(_maybeShowReleaseNotes);
      unawaited(controller.start());
    }
  }

  @override
  void dispose() {
    _update?.removeListener(_maybeShowReleaseNotes);
    _update?.dispose();
    super.dispose();
  }

  /// Whether **Wat is er nieuw** is already on stage, so a second controller
  /// notification (the check's own `busy` flip lands one) cannot stack a second
  /// copy of it.
  bool _showingReleaseNotes = false;

  /// Shows the release notes of the version now running, once (#395).
  ///
  /// A dialog is the right shape here and a bar is not, which is the opposite of
  /// the call #371 made for the update *offer* — and for the opposite reason.
  /// An offer asks for a decision the operator may not want to make now, so it
  /// waits in a strip of chrome. This asks for nothing: it is the answer to
  /// "what changed?", it is read once, and a bar the operator has to notice and
  /// dismiss would be the worse interruption of the two. It is still never a
  /// gate — the barrier dismisses it, `Sluiten` dismisses it, and nothing in the
  /// app is waiting on either.
  void _maybeShowReleaseNotes() {
    final UpdateController? update = _update;
    if (update == null || _showingReleaseNotes) return;
    if (!update.whatsNewPending) return;
    final AppRelease? release = update.releaseNotes;
    if (release == null) return;

    _showingReleaseNotes = true;
    // Off the notification, onto the next frame: this runs inside
    // `notifyListeners`, and pushing a route from there re-enters the navigator
    // mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ReleaseNotesDialog.show(
        context,
        release,
        onOpenLink: widget.openReleaseLink,
      );
      _showingReleaseNotes = false;
      // Written when the operator closes it, not when it opens: a session that
      // never got that far has not been told anything yet.
      await update.acknowledgeReleaseNotes();
    });
  }

  /// Takes hold of the (memoized) reconcile stack so the rail can count what
  /// Klasgroepen and Acties are holding (#367).
  ///
  /// The rail does **not** force the stack into existence: the closure is the
  /// one `main()` memoizes, and Synchronisatie — the destination a launch lands
  /// on since #366 — resolves the very same one from its own `initState` on the
  /// first frame. So this adopts what the session was going to build anyway,
  /// and on an unconfigured build (`reconcileBootstrap == null`) it does
  /// nothing at all rather than throwing.
  ///
  /// A failure is swallowed on purpose. The rail is a status surface, not an
  /// error surface — Synchronisatie already reports the failed bootstrap and
  /// offers the retry, and a rail that turned an unreachable store into a red
  /// banner over every tab would say the same thing five times. It stays
  /// countless instead, and [_select] re-attempts, so a retry that succeeds is
  /// picked up on the operator's next tab change rather than at the next launch.
  Future<void> _adopt() async {
    final Future<ReconcileServices> Function()? make =
        widget.reconcileBootstrap;
    if (make == null || _counts != null || _adopting) return;
    _adopting = true;
    try {
      final ReconcileServices services = await make();
      if (mounted) setState(() => _counts = services.controller);
    } on Object {
      // Deliberately silent — see above.
    } finally {
      _adopting = false;
    }
  }

  /// Selects the destination at [index] — what a rail tap and [_go] both run
  /// through, so neither can grow behaviour the other lacks.
  void _select(int index) {
    if (index == _selected) return;
    setState(() => _selected = index);
    unawaited(_adopt());
  }

  /// Selects the destination named [tab] (#301) — how a screen follows its own
  /// pointer at another one, rather than asking the operator to find the rail
  /// entry themselves.
  ///
  /// Exactly what tapping the rail entry does, and nothing more: a destination
  /// the operator has been to before is kept alive by the [IndexedStack] and
  /// comes back as they left it; one they have not is built on the next frame,
  /// as it would be either way.
  void _go(ShellTab tab) {
    final int index = _destinations.indexWhere((d) => d.tab == tab);
    if (index < 0) return;
    _select(index);
  }

  /// Reads the class inventory when this session does not hold it, so the
  /// Klasgroepen chip can count something before the operator has opened that
  /// tab — and again after a sync, which drops the documents on purpose.
  ///
  /// #309 removed exactly this pre-read from Acties, on the grounds that no
  /// pixel Acties renders reads `groupDocs`. That reasoning is what puts it
  /// here now: the rail is on screen at all times and its chip *is* such a
  /// pixel, so the read is paid for once per generation by the one surface that
  /// depends on it, instead of on the first visit to a tab the chip exists to
  /// make unnecessary.
  ///
  /// The same guard Klasgroepen keeps, deferred to a microtask for the same
  /// reason: this runs from a build driven by a controller notification, and
  /// [ReconcileController.loadGroups] publishes its loading state as its first
  /// act — calling it inline would re-enter `notifyListeners` mid-walk.
  void _ensureGroups(ReconcileController controller) {
    if (_warming) return;
    if (controller.groupDocs != null || controller.loadingGroups) return;
    _warming = true;
    scheduleMicrotask(() {
      _warming = false;
      if (!mounted) return;
      if (controller.groupDocs == null && !controller.loadingGroups) {
        unawaited(controller.loadGroups());
      }
    });
  }

  /// How many items the destination [tab] is holding for the operator, or
  /// `null` when that is not knowable yet (#367) — the two render the same
  /// (no chip), but they are not the same claim: unknown is not zero, and a
  /// chip carrying a stale or invented number is worse than none.
  ///
  /// Both numbers are the controller's own derivations, the same pair the
  /// cross-tab pointer lines quote ([OtherTabAttentionLine]) — so the chip, the
  /// pointer and the header of the page it leads to cannot drift apart.
  ///
  /// Accounts rather than the pending-card total for Acties, deliberately.
  /// `totalPendingCount` counts every family, class groups included, so a rail
  /// showing it beside the Klasgroepen chip would count the same class work
  /// twice; and in a passive session it sums stored rollups while the Acties
  /// list renders no rows at all, which is precisely a chip disagreeing with
  /// the page under it.
  int? _pendingOn(ShellTab tab) {
    final ReconcileController? c = _counts;
    if (c == null) return null;
    return switch (tab) {
      // Zero until the inventory has been read, so the unread state has to be
      // told apart from an inventory that is genuinely in order.
      ShellTab.klasgroepen =>
        c.groupDocs == null ? null : c.classesNeedingAttention,
      // A passive session cannot count accounts — it has no linked view to
      // count over, and the list it renders holds no interactive rows either.
      ShellTab.acties => c.linked == null ? null : c.accountsNeedingAttention,
      _ => null,
    };
  }

  /// The reconcile stack is assembled once and kept across tab switches, so
  /// the screens are kept alive rather than rebuilt per selection.
  late final List<Widget?> _built = List<Widget?>.filled(
    _destinations.length,
    null,
  );

  @override
  Widget build(BuildContext context) {
    _built[_selected] ??= _destinations[_selected].builder(context);
    // Above the rail *and* the views, so a screen can follow its own pointer at
    // another tab (#301).
    return ShellNavigation(
      go: _go,
      child: _scaffold(),
    );
  }

  Widget _scaffold() {
    return Scaffold(
      // The per-product identity rule spans the top of the whole shell (its
      // intended placement — a full-width accent bar), with the navigation
      // rail and the active view below it.
      body: Column(
        children: <Widget>[
          const PlinkIdentityRule(),
          _updateOffer(),
          Expanded(
            child: Row(
              children: <Widget>[
                _rail(),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: IndexedStack(
                    index: _selected,
                    children: <Widget>[
                      for (var i = 0; i < _destinations.length; i++)
                        _built[i] ?? const SizedBox.shrink(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The update offer (#371), or nothing at all — which is what it is almost
  /// always.
  ///
  /// A bar across the top of the shell rather than a dialog, and that is the
  /// design decision rather than a styling one: an update must never interrupt
  /// what an operator is doing, so it takes a strip of chrome and waits. It
  /// appears only once a check has actually found a newer release, so a build
  /// that never checks, a check that failed, and a check that came back
  /// up-to-date all render identically: nothing.
  Widget _updateOffer() {
    final UpdateController? update = _update;
    if (update == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: update,
      builder: (BuildContext context, Widget? _) => update.isOffering
          ? _UpdateOfferBar(controller: update)
          : const SizedBox.shrink(),
    );
  }

  /// The navigation rail, rebuilt on every controller notification so the chips
  /// it carries move with the shared state instead of freezing at first build
  /// (#367) — a pull and an apply both land here.
  ///
  /// Listened to on the rail alone rather than around the whole scaffold: the
  /// views below already rebuild off the same controller through their own
  /// [ListenableBuilder]s, and re-running the shell's `build` would only hand
  /// the [IndexedStack] the identical widget instances back.
  Widget _rail() {
    final ReconcileController? counts = _counts;
    if (counts == null) return _railBar();
    return ListenableBuilder(
      listenable: counts,
      builder: (BuildContext context, Widget? _) {
        _ensureGroups(counts);
        return _railBar();
      },
    );
  }

  Widget _railBar() {
    return NavigationRail(
      selectedIndex: _selected,
      onDestinationSelected: _select,
      labelType: NavigationRailLabelType.all,
      destinations: <NavigationRailDestination>[
        for (final ShellDestination d in _destinations)
          NavigationRailDestination(
            icon: _railIcon(d),
            label: Text(d.label),
          ),
      ],
    );
  }

  /// A destination's icon, wearing what that destination is holding (#367).
  ///
  /// The chip is [PendingBadge] — the badge the Acties and Klasgroepen rows
  /// already carry — rather than a second badge style invented for the rail,
  /// and it is only reached for a count above zero: an entry with nothing on it
  /// reads as "nothing here", which a `0` to interpret (or that badge's
  /// zero-state tick) does not.
  ///
  /// Hung off the icon as an unpositioned [Stack] overlay, so it adds nothing to
  /// the rail's layout: the column's width is set by the longest label, and the
  /// chip paints over the corner of the icon the way a badge does.
  Widget _railIcon(ShellDestination d) {
    final Widget icon = Icon(d.icon);
    final int? count = _pendingOn(d.tab);
    if (count == null || count <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        icon,
        Positioned(
          top: -11,
          left: 11,
          child: PendingBadge(
            key: ValueKey<String>('rail-count-${d.tab.name}'),
            count: count,
          ),
        ),
      ],
    );
  }
}

/// The strip that offers a newer release (#371).
///
/// Two buttons and no third: **Bijwerken** applies it, **Later** puts the bar
/// away for this session. There is deliberately no "always update" — the
/// consent is per update, because the cost of getting it wrong is a restart in
/// the middle of a sync.
class _UpdateOfferBar extends StatelessWidget {
  const _UpdateOfferBar({required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool working = controller.phase != UpdatePhase.available;

    return Material(
      key: const ValueKey('update-offer'),
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PlinkSpacing.s5,
          vertical: PlinkSpacing.s3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.system_update_alt_outlined,
                  color: colors.onSecondaryContainer,
                ),
                const SizedBox(width: PlinkSpacing.s3),
                Expanded(
                  child: Text(
                    controller.message,
                    key: const ValueKey('update-offer-message'),
                    style: text.bodyMedium
                        ?.copyWith(color: colors.onSecondaryContainer),
                  ),
                ),
                const SizedBox(width: PlinkSpacing.s3),
                FilledButton(
                  key: const ValueKey('update-offer-apply'),
                  onPressed: working ? null : controller.apply,
                  child: const Text('Bijwerken'),
                ),
                const SizedBox(width: PlinkSpacing.s2),
                TextButton(
                  key: const ValueKey('update-offer-dismiss'),
                  onPressed: working ? null : controller.dismiss,
                  child: const Text('Later'),
                ),
              ],
            ),
            if (controller.phase == UpdatePhase.downloading) ...<Widget>[
              const SizedBox(height: PlinkSpacing.s2),
              LinearProgressIndicator(
                key: const ValueKey('update-offer-progress'),
                // Indeterminate until the server tells us how big the download
                // is: a bar frozen at 0% reads as a hang.
                value: controller.progress > 0 ? controller.progress : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
