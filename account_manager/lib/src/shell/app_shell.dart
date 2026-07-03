import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../reconcile/reconcile_bootstrap.dart';
import '../screens/home_screen.dart';
import '../screens/reconcile_screen.dart';

/// One navigable destination in the [AppShell].
class ShellDestination {
  const ShellDestination({
    required this.label,
    required this.icon,
    required this.builder,
  });

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
  const AppShell({super.key, this.reconcileBootstrap});

  /// Assembles the reconcile stack on first use, or `null` when Azure AD is
  /// not configured for this build.
  final Future<ReconcileServices> Function()? reconcileBootstrap;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<ShellDestination> _destinations = <ShellDestination>[
    ShellDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      builder: (_) => const HomeScreen(),
    ),
    ShellDestination(
      label: 'Reconcile',
      icon: Icons.sync_alt_outlined,
      builder: (_) => ReconcileScreen(bootstrap: widget.reconcileBootstrap),
    ),
  ];

  int _selected = 0;

  /// The reconcile stack is assembled once and kept across tab switches, so
  /// the screens are kept alive rather than rebuilt per selection.
  late final List<Widget?> _built = List<Widget?>.filled(
    _destinations.length,
    null,
  );

  @override
  Widget build(BuildContext context) {
    _built[_selected] ??= _destinations[_selected].builder(context);
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
