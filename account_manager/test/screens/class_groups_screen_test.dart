import 'package:account_manager/src/screens/class_groups_screen.dart';
import 'package:account_state/account_state.dart' show InMemoryLinkedStore;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A tall viewport so the whole inventory lays out without the assertions
/// tripping on the fold.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

final Finder _readOnly = find.byKey(const ValueKey('class-groups-read-only'));
final Finder _filter =
    find.byKey(const ValueKey('class-groups-only-attention'));

void main() {
  testWidgets('shows the not-configured panel when AAD is absent, in Dutch',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ClassGroupsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
    expect(_filter, findsNothing);
  });

  testWidgets('a failed bootstrap offers a retry, in Dutch',
      (WidgetTester tester) async {
    var attempts = 0;
    await tester.pumpWidget(_wrap(ClassGroupsScreen(bootstrap: () async {
      attempts++;
      if (attempts == 1) throw StateError('geen verbinding');
      return ReconcileHarness().bootstrap();
    })));
    await tester.pumpAndSettle();

    expect(find.text('Kan het Klasgroepen-scherm niet openen'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('class-groups-bootstrap-retry')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Klasgroepen'), findsOneWidget);
  });

  testWidgets(
      'the inventory lists every class, not only the ones with work (#227)',
      (WidgetTester tester) async {
    // The fixture: `1A` is correct in all three systems, the sub-grouped `2F`
    // (`2F ECO` + `2F MAW`) has no Office 365 group, and `GBS-9Z` is the group
    // of a class that no longer exists.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Every class is a row — including `1A`, which raises nothing at all and so
    // had no document whatsoever before this issue.
    expect(find.byKey(const ValueKey('class-row-1A')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-2F MAW')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-2F ECO')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-GBS-9Z')), findsOneWidget);
    // A class with work carries the interactive tile inside its row, keyed the
    // way the Acties entry tiles are — so it is inspected and applied here.
    expect(find.byKey(const ValueKey('entry-group-2F ECO')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-GBS-9Z')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-1A')), findsNothing,
        reason: 'nothing is wrong with 1A, so there is nothing to act on');

    // The header counts the whole inventory and how much of it needs attention.
    expect(find.textContaining('4 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget);
  });

  testWidgets('each row carries three presence columns (#227)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('class-row-1A'));
    for (final system in const ['WISA', 'Smartschool', 'Office 365']) {
      expect(
        find.descendant(of: row, matching: find.text(system)),
        findsOneWidget,
      );
    }
    // A class that is right everywhere reads as three ticks and its group name.
    expect(
      find.descendant(
          of: row, matching: find.byIcon(Icons.check_circle_outline)),
      findsNWidgets(3),
    );
    expect(find.descendant(of: row, matching: find.text('GBS-1A')),
        findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Eerste jaar A')),
        findsOneWidget);
  });

  testWidgets(
      "a sub-group names the parent class's Office 365 group rather than one of "
      'its own (#227/#228)', (WidgetTester tester) async {
    // `2F ECO` and `2F MAW` are sub-groups of `2F`, and sub-groups get no group
    // of their own: both rows are served by the single `GBS-2F`. Four rows each
    // looking like they own a group is exactly what the issue asked us not to
    // show.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('deelgroep van 2F'), findsNWidgets(2));
    expect(find.text('nog geen groep voor 2F'), findsNWidgets(2));
    // `1A` owns its group, so it is not anybody's sub-group.
    expect(find.textContaining('deelgroep van 1A'), findsNothing);
  });

  testWidgets(
      'the attention filter is off by default and hides the classes that are '
      'in order when switched on (#227)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(_filter).value, isFalse,
        reason: "this tab's job is the full picture");
    expect(find.byKey(const ValueKey('class-row-1A')), findsOneWidget);

    await tester.tap(_filter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('class-row-1A')), findsNothing);
    expect(find.byKey(const ValueKey('entry-group-2F ECO')), findsOneWidget);

    await tester.tap(_filter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('class-row-1A')), findsOneWidget);
  });

  testWidgets(
      'a class that needs work is inspected and applied without leaving the '
      'tab (#227)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-2F ECO');
    expect(
      find.descendant(
        of: find.byKey(entry),
        matching: find.text('Maak de Office 365-groep GBS-2F voor klas 2F'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-2F ECO'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.graph.createdGroups, hasLength(1));
    expect(harness.graph.createdGroups.single['displayName'], 'GBS-2F');
  });

  testWidgets(
      'a passive session says it is read-only and renders static rows (#214)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ClassGroupsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(s2.controller.linked, isNull);
    expect(_readOnly, findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    // The stored classes are there, with their stored candidates marked exactly
    // as Acties marks them (#255).
    expect(find.byKey(const ValueKey('class-row-2B')), findsOneWidget);
    expect(
        find.textContaining('Deze klas bestaat in Smartschool'), findsWidgets);
    expect(find.textContaining('(manueel)'), findsWidgets);
    // Nothing interactive: a passive session has nothing to apply.
    expect(find.byKey(const ValueKey('entry-group-2B')), findsNothing);
  });

  testWidgets(
      'the inventory holds only classes of the schools we manage, described as '
      'ours (#205)', (WidgetTester tester) async {
    // WISA hands this session a sibling school's `1A` and `9Z` first and our own
    // `1A` last; only school 1 is managed. The sibling `1A` used to shadow ours,
    // so the proposal described the wrong school's class.
    _useTallWindow(tester);
    final harness = foreignClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('1A'), findsOneWidget);
    expect(find.text('9Z'), findsNothing);
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsOneWidget);
    expect(find.text('Onze eerste klas'), findsOneWidget);
    expect(find.textContaining('Klas van een andere school'), findsNothing);
  });

  testWidgets('classes sort by year, numerically (#227)',
      (WidgetTester tester) async {
    expect(compareClassNames('2A', '10A'), lessThan(0));
    expect(compareClassNames('2F', '2F ECO'), lessThan(0));
    expect(compareClassNames('OKAN', '3C'), greaterThan(0),
        reason: 'a non-numeric class sorts after every numbered year');
    expect(compareClassNames('3C', '3c'), 0);
  });
}
