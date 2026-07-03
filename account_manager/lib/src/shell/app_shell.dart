import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../screens/home_screen.dart';

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
/// Deliberately minimal: a single Home destination today. Each Phase C view
/// slice (reconcile, settings, passwords, …) adds one entry to [_destinations]
/// — the shell is built to grow, not to mirror the seven legacy WPF pages up
/// front.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static final List<ShellDestination> _destinations = <ShellDestination>[
    ShellDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      builder: (_) => const HomeScreen(),
    ),
  ];

  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final ShellDestination current = _destinations[_selected];
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
                Expanded(child: current.builder(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
