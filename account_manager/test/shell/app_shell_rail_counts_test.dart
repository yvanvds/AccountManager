import 'package:account_manager/src/screens/action_tiles.dart';
import 'package:account_manager/src/screens/class_groups_screen.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

/// The counter chips the navigation rail wears (#367).
///
/// The rail is the only thing on screen at all times, so what it says has to be
/// true of a session the operator has not clicked into yet: these runs pump the
/// **shell**, never the Klasgroepen or Acties screen, and assert the chips off a
/// controller neither of those screens has ever been mounted over.
Widget _wrap(Widget child) => MaterialApp(home: child);

Finder _chipFinder(String tab) =>
    find.byKey(ValueKey<String>('rail-count-$tab'));

/// The number the rail entry for [tab] is wearing, or `null` when it wears no
/// chip at all — which is what "nothing here" looks like.
int? _chip(WidgetTester tester, String tab) {
  final Finder f = _chipFinder(tab);
  if (f.evaluate().isEmpty) return null;
  return tester.widget<PendingBadge>(f).count;
}

/// A digit sequence rendered inside the rail itself, so a passing count is not
/// merely a widget property nobody paints.
Finder _railText(String text) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(text),
    );

void main() {
  testWidgets(
      'the rail wears no chip before the session has anything to count — '
      'unknown is not zero (#367)', (WidgetTester tester) async {
    // A cold session over an empty shared store: nothing has been pulled, so
    // there is no linked view to count accounts over and no class inventory
    // that says anything. A chip here would be an invented number.
    final harness = ReconcileHarness();
    await tester
        .pumpWidget(_wrap(AppShell(reconcileBootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_chip(tester, 'klasgroepen'), isNull);
    expect(_chip(tester, 'acties'), isNull);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byType(PendingBadge),
      ),
      findsNothing,
    );

    // The rail did read the inventory, though — it is the surface that now
    // depends on it, so it does not wait for a visit to Klasgroepen to find out
    // whether that tab is holding anything.
    expect(harness.controller.groupDocs, isNotNull);
    expect(harness.controller.classesNeedingAttention, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the rail counts what Klasgroepen and Acties are holding after a pull, '
      'without either tab being opened (#367)', (WidgetTester tester) async {
    // `3C` and `3D` both lack their Office 365 group (two classes), and of the
    // two students only Sam's Office 365 display name is stale (one account).
    final harness = appliedClassWorkHarness();
    await tester
        .pumpWidget(_wrap(AppShell(reconcileBootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await harness.controller.sync();
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Each chip is its own screen's derivation, so the rail cannot disagree
    // with the page it leads to.
    expect(_chip(tester, 'klasgroepen'),
        harness.controller.classesNeedingAttention);
    expect(
        _chip(tester, 'acties'), harness.controller.accountsNeedingAttention);
    expect(_chip(tester, 'klasgroepen'), 2);
    expect(_chip(tester, 'acties'), 1);
    expect(_railText('2'), findsOneWidget);
    expect(_railText('1'), findsOneWidget);

    // The counts are not frozen at first build, and they did not cost a visit:
    // the shell has still never built the Klasgroepen screen.
    expect(find.byType(ClassGroupsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an apply moves the chips in place, and a destination with nothing left '
      'wears none (#367)', (WidgetTester tester) async {
    final harness = appliedClassWorkHarness();
    await tester
        .pumpWidget(_wrap(AppShell(reconcileBootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await harness.controller.sync();
    await tester.pumpAndSettle();
    expect(_chip(tester, 'acties'), 1);

    // Sam's stale Office 365 name is the one applyable account action in the
    // fixture; applying it re-links, so the account really is done afterwards.
    await harness.controller.applyEntry(
      harness.controller.pendingEntries
          .singleWhere((e) => e.family == 'student'),
    );
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // No re-sync: the chip follows the shared state the apply just changed.
    expect(harness.controller.accountsNeedingAttention, 0);
    expect(_chip(tester, 'acties'), isNull,
        reason: 'an entry holding nothing reads as "nothing here", not as a 0');
    expect(_railText('1'), findsNothing);

    // …and only that one moved: the class work the pass did not touch is still
    // counted, on the number its own tab would state.
    expect(_chip(tester, 'klasgroepen'),
        harness.controller.classesNeedingAttention);
    expect(_chip(tester, 'klasgroepen'), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unconfigured build renders the rail with no chips (#367)',
      (WidgetTester tester) async {
    // No Azure AD, so there is no reconcile stack to count over. The rail must
    // still be a rail rather than an error.
    await tester.pumpWidget(_wrap(const AppShell()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(_chip(tester, 'klasgroepen'), isNull);
    expect(_chip(tester, 'acties'), isNull);
    expect(tester.takeException(), isNull);
  });
}
