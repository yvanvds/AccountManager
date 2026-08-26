import 'package:flutter/widgets.dart';

/// The shell's destinations, by name (#301).
///
/// A screen that points at another tab — "12 klas(sen) vragen ook aandacht" on
/// Acties, its mirror on Klasgroepen — names the destination rather than the
/// index the navigation rail happens to give it, so reordering the rail cannot
/// silently re-aim a link.
enum ShellTab {
  synchronisatie,
  klasgroepen,
  acties,
  wachtwoorden,
  instellingen,
}

/// Lets a screen inside the shell send the operator to another tab (#301).
///
/// It lives in a file of its own rather than in `app_shell.dart` so the shared
/// tile library can reach it: the shell imports the screens and the screens
/// import the tiles, so a tile importing the shell would close the ring.
///
/// [maybeOf] is deliberately nullable and every caller has to cope with `null`.
/// A screen is pumped on its own in every widget test, and a pointer that
/// cannot be followed is still worth stating — so outside the shell the line
/// renders as plain prose instead of throwing or disappearing.
class ShellNavigation extends InheritedWidget {
  const ShellNavigation({
    super.key,
    required this.go,
    required super.child,
  });

  /// Selects [tab] in the shell.
  final void Function(ShellTab tab) go;

  static ShellNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNavigation>();

  /// [go] is a bound method of the shell's state, so it is the very same
  /// function on every rebuild and no dependent ever has to be told about a new
  /// one.
  @override
  bool updateShouldNotify(ShellNavigation oldWidget) => false;
}
