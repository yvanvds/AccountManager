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
  teLaat,
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
    required this.current,
    required super.child,
  });

  /// Selects [tab] in the shell.
  final void Function(ShellTab tab) go;

  /// The destination the operator is looking at right now (#407).
  ///
  /// Published because the shell keeps every visited destination **alive** in an
  /// [IndexedStack]: a screen the operator navigated away from is still mounted,
  /// still building and still able to request keyboard focus. That is invisible
  /// for a screen that only renders, and it is a bug for the scan tab, whose
  /// whole job is to hold the keyboard focus a scanner types into — without this
  /// it would go on stealing focus from Instellingen's text fields for the rest
  /// of the session.
  final ShellTab current;

  static ShellNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNavigation>();

  /// [go] is a bound method of the shell's state, so it is the very same
  /// function on every rebuild and no dependent ever has to be told about a new
  /// one. [current] is not: a dependent that reads it has to be rebuilt when the
  /// operator changes tabs, which is the notification the scan tab hangs its
  /// focus handling off.
  @override
  bool updateShouldNotify(ShellNavigation oldWidget) =>
      oldWidget.current != current;
}
