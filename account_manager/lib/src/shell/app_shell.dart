import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../screens/actions_screen.dart';
import '../screens/class_groups_screen.dart';
import '../screens/home_screen.dart';
import '../screens/passwords_screen.dart';
import '../screens/reconcile_screen.dart';
import '../screens/settings_screen.dart';
import '../settings/settings_bootstrap.dart';
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
/// Deliberately minimal: Home plus the reconcile screen today. Each Phase C
/// view slice (settings, passwords, …) adds one entry to the destinations —
/// the shell is built to grow, not to mirror the seven legacy WPF pages up
/// front.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.reconcileBootstrap,
    this.settingsBootstrap,
  });

  /// Assembles the reconcile stack on first use, or `null` when Azure AD is
  /// not configured for this build.
  final Future<ReconcileServices> Function()? reconcileBootstrap;

  /// Assembles the settings seams (store + secret provider) on first use, or
  /// `null` when Azure AD is not configured for this build.
  final Future<SettingsServices> Function()? settingsBootstrap;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<ShellDestination> _destinations = <ShellDestination>[
    // Every label is the operator's language and the name of the page behind
    // it (#257): the rail is read together with the heading it leads to, so a
    // rail saying "Actions" over a page titled "Acties" reads as two apps.
    ShellDestination(
      tab: ShellTab.start,
      label: 'Start',
      icon: Icons.home_outlined,
      builder: (_) => const HomeScreen(),
    ),
    ShellDestination(
      tab: ShellTab.synchronisatie,
      label: 'Synchronisatie',
      icon: Icons.sync_alt_outlined,
      builder: (_) => ReconcileScreen(bootstrap: widget.reconcileBootstrap),
    ),
    ShellDestination(
      tab: ShellTab.acties,
      label: 'Acties',
      icon: Icons.checklist_outlined,
      builder: (_) => ActionsScreen(bootstrap: widget.reconcileBootstrap),
    ),
    // The class inventory (#227). A destination of its own rather than a node
    // inside Acties: it lists *every* class, so it answers "is this right?",
    // which the action list structurally cannot.
    ShellDestination(
      tab: ShellTab.klasgroepen,
      label: 'Klasgroepen',
      icon: Icons.groups_outlined,
      builder: (_) => ClassGroupsScreen(bootstrap: widget.reconcileBootstrap),
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
      builder: (_) => SettingsScreen(bootstrap: widget.settingsBootstrap),
    ),
  ];

  int _selected = 0;

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
    if (index < 0 || index == _selected) return;
    setState(() => _selected = index);
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
          Expanded(
            child: Row(
              children: <Widget>[
                NavigationRail(
                  selectedIndex: _selected,
                  onDestinationSelected: (int i) =>
                      setState(() => _selected = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: <NavigationRailDestination>[
                    for (final ShellDestination d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        label: Text(d.label),
                      ),
                  ],
                ),
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
}
