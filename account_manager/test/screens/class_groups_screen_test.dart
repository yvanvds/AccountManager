import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/screens/class_groups_screen.dart';
import 'package:account_manager/src/screens/system_indicator.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        InMemoryLinkedStore,
        LiveSettings,
        MaterializedAccount,
        SystemSyncMeta,
        WisaConnection,
        WorkDateSetting;
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
final Finder _search = find.byKey(const ValueKey('class-groups-search'));

Finder _row(String klas) => find.byKey(ValueKey('class-row-$klas'));

/// What one row's cell says about one system (#298).
SystemIndicatorState _cell(
  WidgetTester tester,
  String klas,
  core.Origin system,
) =>
    tester
        .widget<SystemIndicatorCell>(
          find.byKey(ValueKey('class-cell-$klas-${system.name}')),
        )
        .state;

/// Types [needle] into the inventory search box and settles.
Future<void> _type(WidgetTester tester, String needle) async {
  await tester.enterText(_search, needle);
  await tester.pumpAndSettle();
}

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
    for (final system in const <core.Origin>[
      core.Origin.wisa,
      core.Origin.smartschool,
      core.Origin.azure,
    ]) {
      expect(_cell(tester, '1A', system), SystemIndicatorState.inOrder);
    }
  });

  testWidgets(
      'a class that is present everywhere but carries a pending Office 365 '
      'write says so on its Office 365 cell (#298)',
      (WidgetTester tester) async {
    // The screenshot in the issue: `1A` exists in WISA, Smartschool and Office
    // 365 and is carrying an Azure roster write, so it used to render three
    // ticks with nothing on the card saying the pending work was an Azure one.
    _useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_cell(tester, '1A', core.Origin.wisa), SystemIndicatorState.inOrder);
    expect(_cell(tester, '1A', core.Origin.smartschool),
        SystemIndicatorState.inOrder);
    expect(
      _cell(tester, '1A', core.Origin.azure),
      SystemIndicatorState.needsWork,
      reason: 'the class is carrying a stale Office 365 roster',
    );

    // And the line itself names the system it writes to, so the card and the
    // cell tell the same story.
    expect(
      find.descendant(of: _row('1A'), matching: find.text('Office 365 ·')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('1A'),
        matching: find.textContaining('Werk het ledenbestand van GBS-1A bij'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'a class with no Office 365 group reads missing, not pending '
      '(#298)', (WidgetTester tester) async {
    // Missing beats work pending: `2F ECO` is in WISA and Smartschool and has
    // no group at all, and the create it raises is exactly the work of making
    // one. The cell must say the group is absent, not that it needs a tweak.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_cell(tester, '2F ECO', core.Origin.wisa),
        SystemIndicatorState.inOrder);
    expect(_cell(tester, '2F ECO', core.Origin.smartschool),
        SystemIndicatorState.inOrder);
    expect(_cell(tester, '2F ECO', core.Origin.azure),
        SystemIndicatorState.missing);
  });

  testWidgets(
      'an informational-only class colours no cell, and still lights its row '
      '(#298)', (WidgetTester tester) async {
    // `GBS-9Z` is the group of a class that stopped running. Its decision is an
    // either/or whose default half is the "laat staan" notice (#271), so there
    // is no write pending and the Office 365 cell stays green — while the row
    // itself is highlighted, because `needsAttention` counts the notice and on
    // this screen the notice *is* the work (#225/#250).
    _useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_cell(tester, 'GBS-9Z', core.Origin.azure),
        SystemIndicatorState.inOrder);
    expect(_cell(tester, 'GBS-9Z', core.Origin.wisa),
        SystemIndicatorState.missing);
    expect(_cell(tester, 'GBS-9Z', core.Origin.smartschool),
        SystemIndicatorState.missing);

    final ColorScheme colors =
        Theme.of(tester.element(_row('GBS-9Z'))).colorScheme;
    final Container box = tester.widget<Container>(_row('GBS-9Z'));
    expect(
      ((box.decoration! as BoxDecoration).border! as Border).top.color,
      colors.primary,
      reason: 'the row still asks something of the operator',
    );
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
      'a new class applied from its row lands in Smartschool *and* Office 365 '
      '(#272)', (WidgetTester tester) async {
    // `5WW1` is in WISA only and has no Office 365 group, so its row carries
    // two selected options — one per system. Both must run off the one
    // **Toepassen**.
    _useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-5WW1');
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(1));
    expect(harness.graph.createdGroups, hasLength(1));
    expect(harness.graph.createdGroups.single['displayName'], 'GBS-5WW1');
  });

  testWidgets(
      'a refused Office 365 create says so on the class row itself, and stays '
      'there to be run again (#272)', (WidgetTester tester) async {
    // The reported shape: the Smartschool half lands, Graph refuses the group
    // create, and the operator — who applied one class out of an inventory —
    // sees nothing about it. The verdict used to live only in a log panel on
    // another screen and a results section below the whole list.
    _useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    harness.graph.refuseGroupCreates = true;
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-5WW1');
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The row's own verdict, on the row, naming the reason Graph gave — under
    // the decision it is the verdict of, since #283.
    final refused = find.byKey(const ValueKey('entry-outcomes-group-5WW1-0'));
    expect(refused, findsOneWidget);
    expect(
      find.descendant(
          of: refused, matching: find.text('Resultaat van de vorige poging')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: refused,
        matching: find.textContaining('Mislukt — Maak de Office 365-groep '
            'GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: refused,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsOneWidget,
    );
    // …beside the half that did land, so the operator reads one card, not two
    // halves of the story in two places. That half settled its own decision, so
    // the card no longer raises it and its verdict is reported at card level
    // (#283) — on the same card, on screen at the same time.
    final settled = find.byKey(const ValueKey('entry-outcomes-group-5WW1'));
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    for (final block in <Finder>[refused, settled]) {
      expect(
        find.descendant(of: find.byKey(entry), matching: block),
        findsOneWidget,
        reason: 'both verdicts stay readable together on the one card',
      );
    }

    // The pass summary stops claiming everything was written.
    expect(
      find.text('1 gelukt, 1 mislukt. Een mislukte actie schreef niets en '
          'blijft openstaan.'),
      findsOneWidget,
    );

    // And the create is still there to run again.
    expect(
      find.descendant(
        of: find.byKey(entry),
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsWidgets,
    );
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
  });

  testWidgets(
      'an open row states its summary once, and its member counts as counts '
      '(#300)', (WidgetTester tester) async {
    // Class `1A` raises one decision: the Office 365 roster write. Collapsed,
    // the row previews it; since #281 the expanded body leads that decision
    // with the very same sentence, so opening the row printed it twice, one
    // line directly above the other. And the roster numbers went through the
    // before/after template — "leden toevoegen: ∅ → 1" — which claims a field
    // used to be empty and is becoming 1, true of nothing that happens here.
    _useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const String summary =
        'Werk het ledenbestand van GBS-1A bij (1 toevoegen, 1 verwijderen)';
    const ValueKey<String> block = ValueKey('entry-choice-group-1A-0');

    // Collapsed, the preview says it — once.
    expect(find.descendant(of: _row('1A'), matching: find.text(summary)),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('entry-group-1A')));
    await tester.pumpAndSettle();

    // Open, it is still said once: the decision's heading takes the preview's
    // place rather than joining it.
    expect(
      find.descendant(of: _row('1A'), matching: find.text(summary)),
      findsOneWidget,
      reason: 'the heading replaces the collapsed preview, it does not repeat '
          'it',
    );
    expect(
      find.descendant(of: find.byKey(block), matching: find.text(summary)),
      findsOneWidget,
      reason: 'and the surviving half is the heading, which groups the diff '
          'below it',
    );
    // It is still led by the system it writes to (#298) — with the preview
    // gone, this heading is the only thing on the card that says so.
    expect(
      find.descendant(
          of: find.byKey(block), matching: find.text('Office 365 ·')),
      findsOneWidget,
    );

    // And the numbers read as the quantities they are.
    expect(find.text('leden toevoegen: 1'), findsOneWidget);
    expect(find.text('leden verwijderen: 1'), findsOneWidget);
    expect(find.textContaining('∅ →'), findsNothing,
        reason: 'a count is not a field whose old value was empty');
  });

  testWidgets(
      'a row with two decisions puts each one\'s fields under its own heading '
      '(#281)', (WidgetTester tester) async {
    // `5WW1` is new to Smartschool *and* has no Office 365 group, so its row
    // raises two independent decisions. They used to interleave: both summaries
    // pooled in the subtitle, then the Office 365 field diff, then "Kies één
    // oplossing:" with its radios, then the Smartschool diff — so which diff
    // belonged to which decision was anybody's guess.
    _useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('entry-group-5WW1')));
    await tester.pumpAndSettle();

    // Two decisions, two blocks — the Office 365 create first, because
    // `collapseAlternatives` emits the lone actions ahead of the either/ors.
    const office365 = ValueKey('entry-choice-group-5WW1-0');
    const smartschool = ValueKey('entry-choice-group-5WW1-1');

    // The either/or leads with its question, and the fields under it are the
    // Smartschool class it would create — never the Office 365 group's.
    expect(
      find.descendant(
          of: find.byKey(smartschool),
          matching: find.text('Kies één oplossing:')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(smartschool),
        matching: find.text('description: ∅ → 5e jaar Wetenschappen-Wiskunde'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byKey(smartschool),
          matching: find.text('groupTypes: ∅ → Unified')),
      findsNothing,
    );

    // The lone action leads with what it does, and carries its own diff.
    expect(
      find.descendant(
        of: find.byKey(office365),
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byKey(office365),
          matching: find.text('groupTypes: ∅ → Unified')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(office365),
        matching: find.text('description: ∅ → 5e jaar Wetenschappen-Wiskunde'),
      ),
      findsNothing,
    );
    // "Kies één oplossing:" covers half the card, and says so by sitting in
    // that half only.
    expect(
      find.descendant(
          of: find.byKey(office365),
          matching: find.text('Kies één oplossing:')),
      findsNothing,
    );
  });

  testWidgets(
      "a row with two decisions puts each one's verdict under its own heading "
      '(#283)', (WidgetTester tester) async {
    // A dry-run settles nothing, so both of `5WW1`'s decisions are still on the
    // row afterwards and each one can be asked what happened to it. The verdict
    // lines used to pool in one block below both decisions, exactly the way the
    // field diffs did before #281.
    _useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('entry-group-5WW1')));
    await tester.pumpAndSettle();
    final dryRun = find.byKey(const ValueKey('entry-dry-run-5WW1'));
    await tester.ensureVisible(dryRun);
    await tester.tap(dryRun);
    await tester.pumpAndSettle();

    final office365 = find.byKey(const ValueKey('entry-outcomes-group-5WW1-0'));
    final smartschool =
        find.byKey(const ValueKey('entry-outcomes-group-5WW1-1'));

    // Each decision reports its own write, and only its own.
    expect(
      find.descendant(
          of: office365,
          matching: find.text('Resultaat van de vorige dry-run')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: office365,
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: office365,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsNothing,
    );
    expect(
      find.descendant(
          of: smartschool,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: smartschool,
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsNothing,
    );

    // Nothing is left over: both decisions are still on the row, so the
    // card-level block has nothing to report and does not render at all.
    expect(
        find.byKey(const ValueKey('entry-outcomes-group-5WW1')), findsNothing,
        reason: 'a dry-run settles no decision, so no verdict is orphaned');
  });

  testWidgets(
      'a verdict whose decision succeeded is still reported on the row (#283)',
      (WidgetTester tester) async {
    // The reported run, read the way #283 asks for it. The Smartschool half
    // lands — so its decision is gone from the row the relink builds and its
    // verdict has no block left to sit in — while the Office 365 half is
    // refused and keeps its decision. Both have to stay readable side by side.
    _useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    harness.graph.refuseGroupCreates = true;
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-5WW1');
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The refusal sits under the decision that still asks the question…
    final decision = find.byKey(const ValueKey('entry-choice-group-5WW1-0'));
    expect(
      find.descendant(
          of: decision,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsOneWidget,
    );
    // …and nothing else does. The half that landed is not this decision's
    // verdict, so it does not appear under its heading.
    expect(
      find.descendant(
          of: decision,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsNothing,
    );

    // The half that landed keeps its verdict at card level, and the card says
    // why it has no decision above it.
    final settled = find.byKey(const ValueKey('entry-outcomes-group-5WW1'));
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Overige resultaten van de vorige poging')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: settled,
        matching: find.text('Deze acties staan niet meer open op deze kaart.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: settled,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsNothing,
    );
  });

  testWidgets(
      'a passive session says it is read-only and renders static rows (#214)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    // Deliberately *not* a seeded session: since #287 one of those adopts the
    // shared state and its rows really are interactive (covered below). This is
    // the session holding no snapshot to build a view from at all.
    final s2 = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(_wrap(ClassGroupsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(s2.controller.linked, isNull);
    expect(_readOnly, findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    // The stored classes are there, with their stored candidates marked exactly
    // as Acties marks them (#255).
    expect(find.byKey(const ValueKey('class-row-2B')), findsOneWidget);
    // A Smartschool class WISA does not have is an either/or since #313, so the
    // stored row reads as the choice it is — on its pre-selected half, which is
    // the notice that writes nothing.
    expect(find.textContaining('ze bestaat in Smartschool maar niet in WISA'),
        findsWidgets);
    expect(find.textContaining('(keuze)'), findsWidgets);
    // Nothing interactive: a passive session has nothing to apply.
    expect(find.byKey(const ValueKey('entry-group-2B')), findsNothing);
  });

  testWidgets(
      'a seeded session works from the shared sync instead, and says so (#287)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // The same two operators, except this one launched onto a cold store a
    // colleague had already filled — which is the everyday case.
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

    // The inventory is live rather than static, and the notice says where the
    // view came from instead of demanding a sync for it.
    expect(s2.controller.linked, isNotNull);
    expect(_readOnly, findsNothing);
    expect(find.byKey(const ValueKey('class-groups-shared-state')),
        findsOneWidget);
    expect(find.text('Gedeelde synchronisatie'), findsOneWidget);
    expect(find.textContaining('operator@school.example'), findsWidgets);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(find.byKey(const ValueKey('entry-group-2B')), findsOneWidget);
    // And not one connector was asked for anything.
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);
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

  testWidgets(
      'the search finds a class by its name and by its description (#262)',
      (WidgetTester tester) async {
    // The fixture: `1A` ("Eerste jaar A"), the two sub-groups of `2F` (both
    // "Tweede jaar F") and the stale `GBS-9Z`.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_search, findsOneWidget);
    expect(_row('1A'), findsOneWidget);
    expect(_row('2F ECO'), findsOneWidget);

    // By name: the one class asked about, out of the whole inventory.
    await _type(tester, '1a');
    expect(_row('1A'), findsOneWidget);
    expect(_row('2F ECO'), findsNothing);
    expect(_row('2F MAW'), findsNothing);
    expect(_row('GBS-9Z'), findsNothing);

    // By description — a class is looked up by what it teaches as often as by
    // its code, and "eerste" appears in no class *name* at all.
    await _type(tester, 'tweede');
    expect(_row('2F ECO'), findsOneWidget);
    expect(_row('2F MAW'), findsOneWidget);
    expect(_row('1A'), findsNothing);

    // Per-part and order-independent, like the two Personeel searches
    // (#187/#215/#217): both parts must occur, in either order, and one needle
    // may span the name and the description.
    await _type(tester, 'maw tweede');
    expect(_row('2F MAW'), findsOneWidget);
    expect(_row('2F ECO'), findsNothing);

    // Clearing brings the whole inventory back.
    await tester.tap(find.byKey(const ValueKey('class-groups-search-clear')));
    await tester.pumpAndSettle();
    expect(_row('1A'), findsOneWidget);
    expect(_row('2F ECO'), findsOneWidget);
    expect(_row('GBS-9Z'), findsOneWidget);
  });

  testWidgets('the search composes with the attention switch (#262)',
      (WidgetTester tester) async {
    // `2F ECO` needs work (no Office 365 group for `2F`); `2F MAW` shares that
    // group and so asks nothing itself.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _type(tester, '2f');
    expect(_row('2F ECO'), findsOneWidget);
    expect(_row('2F MAW'), findsOneWidget);
    expect(_row('1A'), findsNothing);

    // The switch narrows what the search left, rather than replacing it.
    await tester.tap(_filter);
    await tester.pumpAndSettle();
    expect(_row('2F ECO'), findsOneWidget);
    expect(_row('2F MAW'), findsNothing);
    expect(_row('1A'), findsNothing,
        reason: 'the search is still on while the switch filters');

    // And the search still narrows what the switch left.
    await _type(tester, '1a');
    expect(
        find.text('Geen klassen die aan de filter voldoen.'), findsOneWidget);
  });

  testWidgets(
      'a search that matches nothing says so, and says something else '
      'than an empty inventory (#262)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Two parts taken from two different classes match neither.
    await _type(tester, '1a tweede');
    expect(_row('1A'), findsNothing);
    expect(
        find.text('Geen klassen die aan de filter voldoen.'), findsOneWidget);
    expect(find.textContaining('Nog geen klasinventaris'), findsNothing,
        reason: 'the sync ran and the school has classes — only the needle '
            'found none');
    expect(find.textContaining('Elke klas staat in orde'), findsNothing,
        reason: 'a typo must not read as a statement about the school');

    // While the "nothing needs attention" line is still the one shown when it
    // is the switch, not the search, that empties the list.
    await _type(tester, '');
    await tester.tap(_filter);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('entry-group-2F ECO')));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-2F ECO'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Elke klas staat in orde'), findsOneWidget);
  });

  testWidgets(
      'a bulk header offers only the classes the search left standing (#262)',
      (WidgetTester tester) async {
    // `1A` and `1B` both need their Office 365 roster updated, so the tab
    // collects them into one "same situation" header that acts on both.
    _useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);

    // Narrowed to one class, the bulk affordance is gone: a button that says it
    // acts on "exactly the classes it names" must not write to a class the
    // operator has filtered off the screen.
    await _type(tester, '1a');
    expect(_row('1A'), findsOneWidget);
    expect(_row('1B'), findsNothing);
    expect(find.text('Klassen in dezelfde situatie'), findsNothing);

    await _type(tester, 'eerste jaar');
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
  });

  testWidgets(
      'a prefixed Office 365 group that is not a class is not in the '
      'inventory (#271)', (WidgetTester tester) async {
    // Every one of these carries the school prefix and was a Klasgroepen row
    // before #271 — a ✓ and no action anybody could take, in a list that is
    // meant to be a class inventory.
    _useTallWindow(tester);
    final harness =
        azureClassGroupHarness(withStaleGroup: true, withNonClassGroups: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    for (final name in const [
      'GBS - GOK',
      'GBS-OKAN',
      'GBS - Leerlingenraad',
      'GBS - Frans - 3D',
    ]) {
      expect(_row(name), findsNothing, reason: '$name is not a class');
    }
    // The class-shaped leftover stays: those are old classes, and the operator
    // wants to see them.
    expect(_row('GBS-9Z'), findsOneWidget);
    expect(find.textContaining('4 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget);
  });

  testWidgets(
      'a stale class group offers a delete, and leaving it alone is the '
      'default (#271)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-GBS-9Z');
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();

    // Two radios, one choice — never two independent to-dos.
    final leave =
        find.byKey(const ValueKey('alt-GBS-9Z-AzureClassGroupWithoutClass'));
    final delete =
        find.byKey(const ValueKey('alt-GBS-9Z-DeleteAzureClassGroup'));
    expect(leave, findsOneWidget);
    expect(delete, findsOneWidget);
    expect(
      find.text('Verwijder de Office 365-groep GBS-9Z van de verdwenen '
          'klas 9Z'),
      findsOneWidget,
    );

    // The default is the informational half, so nothing is applyable until the
    // operator deliberately picks the delete.
    final apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull,
        reason: 'a delete must never be the pre-selected resolution');

    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);

    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.graph.deletedGroups, ['az-GBS-9Z']);
    expect(_row('GBS-9Z'), findsNothing,
        reason: 'the relink drops the group the operator just removed');
    expect(_row('1A'), findsOneWidget, reason: 'no other class was touched');
  });

  testWidgets('a class that still exists is offered no delete (#271)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('entry-group-2F ECO')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('alt-2F ECO-DeleteAzureClassGroup')),
      findsNothing,
    );
    expect(find.textContaining('Verwijder de Office 365-groep'), findsNothing,
        reason: '2F is a running class — deleting its group is not on offer');
  });

  testWidgets(
      'a bulk header over stale groups offers no bulk pass at all, and is '
      'narrowed by the search (#262/#271/#326)', (WidgetTester tester) async {
    // `GBS-9Z` and `GBS-8Y` share the stale-group situation, so the tab collects
    // them into one header — the surface where a destructive default would do
    // the most damage.
    _useTallWindow(tester);
    final harness = staleClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget,
        reason: 'the cohort is still worth naming; only the pair is withdrawn');
    // Neither half of this either/or may be written in bulk — the notice
    // because it writes nothing, the delete because #293 withholds it — so the
    // header carries no pair rather than a dead "Alles toepassen (0)" the
    // operator can go and make live (#326).
    expect(find.textContaining('Alles toepassen ('), findsNothing);
    expect(find.text('Dry-run alles'), findsNothing);

    // Narrowed to one class, the bulk affordance is gone altogether — a delete
    // must not be able to reach a class the operator filtered off the screen.
    await _type(tester, '9z');
    expect(_row('GBS-9Z'), findsOneWidget);
    expect(_row('GBS-8Y'), findsNothing);
    expect(find.text('Klassen in dezelfde situatie'), findsNothing);
    expect(harness.graph.deletedGroups, isEmpty);
  });

  testWidgets(
      'the stale-group card states the group\'s facts instead of diffing them '
      '(#305)', (WidgetTester tester) async {
    // `GBS-9Z` is the group of a class that stopped running, still holding its
    // 21 members. Under the heading "Laat de Office 365-groep GBS-9Z staan"
    // its two fields read
    //
    //   mail: GBS-9Z@student.school.example → ∅
    //   leden: 21 → ∅
    //
    // — the address and the members going away, which is precisely what the
    // *other* radio does and what this one promises not to.
    _useTallWindow(tester);
    final harness = staleClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('entry-group-GBS-9Z')));
    await tester.pumpAndSettle();

    expect(find.text('mail: GBS-9Z@student.school.example'), findsOneWidget);
    expect(find.text('leden: 21'), findsOneWidget);
    expect(find.textContaining('→ ∅'), findsNothing,
        reason: 'the option that writes nothing clears nothing');

    // The delete beside it names the same facts — the inventory of what goes,
    // not three fields each being emptied. "verdwijnen mee" was never a value.
    await tester
        .tap(find.byKey(const ValueKey('alt-GBS-9Z-DeleteAzureClassGroup')));
    await tester.pumpAndSettle();

    expect(find.text('mail: GBS-9Z@student.school.example'), findsOneWidget);
    expect(find.text('leden: 21'), findsOneWidget);
    expect(find.text('postvak, Teams en bestanden: verdwijnen mee'),
        findsOneWidget);
    expect(find.textContaining('→ ∅'), findsNothing);
  });

  // --- The Smartschool leftovers (#313) --------------------------------------

  testWidgets(
      'a Smartschool class WISA does not have offers a delete, and leaving it '
      'alone is the default (#313)', (WidgetTester tester) async {
    // Until #313 this row's whole content was "Verwijder ze manueel als ze niet
    // meer nodig is" — an instruction to go and do it by hand in Smartschool,
    // the dead end #271 removed on the Office 365 side.
    _useTallWindow(tester);
    final harness = smartschoolLeftoverClassHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    const entry = ValueKey('entry-group-9Z');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();

    // Two radios, one choice — never two independent to-dos.
    final leave =
        find.byKey(const ValueKey('alt-9Z-DoNotImportFromSmartschool'));
    final delete = find.byKey(const ValueKey('alt-9Z-DeleteSmartschoolClass'));
    expect(leave, findsOneWidget);
    expect(delete, findsOneWidget);
    expect(
      find.text('Laat deze klas staan — ze bestaat in Smartschool maar niet '
          'in WISA'),
      findsWidgets,
    );
    expect(find.textContaining('Verwijder ze manueel'), findsNothing);
    // The notice states the class instead of instructing; the code is how the
    // operator finds it in Smartschool.
    expect(find.text('code: C9Z'), findsOneWidget);
    expect(find.textContaining('→ ∅'), findsNothing,
        reason: 'the option that writes nothing clears nothing');

    // The default is the informational half, so nothing is applyable until the
    // operator deliberately picks the delete.
    final apply = find.byKey(const ValueKey('entry-apply-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull,
        reason: 'a delete must never be the pre-selected resolution');

    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(
      find.text('Verwijder de klas 9Z uit Smartschool — ze bestaat niet in '
          'WISA'),
      findsWidgets,
    );
    expect(find.text('lidmaatschappen en subgroepen: verdwijnen mee'),
        findsOneWidget);

    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.soap.deletedClasses, ['C9Z'],
        reason: 'addressed by the class code, not its name');
    expect(_row('9Z'), findsNothing,
        reason: 'the relink drops the class the operator just removed');
    expect(_row('8Y'), findsOneWidget,
        reason: 'the class beside it was never selected');
    expect(_row('1A'), findsOneWidget, reason: 'no other class was touched');
  });

  testWidgets(
      'a flipped radio never arms the bulk header over Smartschool leftovers '
      '(#293/#313/#326)', (WidgetTester tester) async {
    // `9Z` and `8Y` share the situation, so the tab collects them into one
    // header — the surface where a destructive default would do the most
    // damage, and the reason the delete withholds `canApplyToAll`.
    _useTallWindow(tester);
    final harness = smartschoolLeftoverClassHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
    expect(find.textContaining('Alles toepassen ('), findsNothing,
        reason: 'neither resolution of this situation is bulk-sanctioned');

    // Flipping the rows to the delete used to *arm* the header: it counted the
    // selected option's `canApply` and nothing else, so two flipped radios read
    // "Alles toepassen (2)" and one press took both classes — every membership
    // and subgroup with them — on an action whose own class says no bulk
    // affordance may offer it (#326).
    for (final String id in const <String>['9Z', '8Y']) {
      final entry = find.byKey(ValueKey('entry-group-$id'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      final delete = find.byKey(ValueKey('alt-$id-DeleteSmartschoolClass'));
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Alles toepassen ('), findsNothing,
        reason: 'the sanction is a property of the action, not of how many '
            'rows happen to be set to it');
    expect(find.text('Dry-run alles'), findsNothing);
    expect(harness.soap.deletedClasses, isEmpty);

    // …and the per-row apply is untouched: one class at a time, from the card
    // that shows what the write would do.
    final apply = find.byKey(const ValueKey('entry-apply-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
  });

  testWidgets('a class WISA still has is offered no Smartschool delete (#313)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = smartschoolLeftoverClassHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(_row('1A'), findsOneWidget);
    expect(find.byKey(const ValueKey('alt-1A-DeleteSmartschoolClass')),
        findsNothing);
    expect(find.textContaining('Verwijder de klas 1A uit Smartschool'),
        findsNothing,
        reason: '1A is a running class — deleting it is not on offer');
  });

  testWidgets('classes sort by year, numerically (#227)',
      (WidgetTester tester) async {
    expect(compareClassNames('2A', '10A'), lessThan(0));
    expect(compareClassNames('2F', '2F ECO'), lessThan(0));
    expect(compareClassNames('OKAN', '3C'), greaterThan(0),
        reason: 'a non-numeric class sorts after every numbered year');
    expect(compareClassNames('3C', '3c'), 0);
  });

  // --- The pointer at Acties (#301) -----------------------------------------

  testWidgets(
      'the Klasgroepen header says how many accounts are waiting on Acties '
      '(#301)', (WidgetTester tester) async {
    // The mirror of the line Acties carries at this tab. Sam's Office 365
    // display name is stale, so exactly one *account* asks something — while
    // both classes ask something here.
    _useTallWindow(tester);
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(harness.controller.accountsNeedingAttention, 1);
    expect(
      find.text('1 account(s) vragen ook aandacht op Acties.'),
      findsOneWidget,
    );
    // Accounts, not actions: the whole view holds three pending cards, two of
    // which are the classes on this very list.
    expect(harness.controller.totalPendingCount, 3);
  });

  testWidgets('…and says nothing at all when no account needs anything (#301)',
      (WidgetTester tester) async {
    // Every student in this fixture is right everywhere a *person* can be; the
    // only thing outstanding is the Office 365 group of `2F`, which is this
    // tab's own work.
    _useTallWindow(tester);
    final harness = azureClassGroupHarness();
    await harness.controller.sync();
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(harness.controller.accountsNeedingAttention, 0);
    expect(
      find.byKey(const ValueKey('class-groups-account-attention')),
      findsNothing,
    );
    expect(find.textContaining('aandacht op Acties'), findsNothing);
  });

  // --- The freshness stamp above the inventory ------------------------------
  //
  // These four came over from `actions_screen_test.dart` when #309 stripped the
  // Acties header down to its eyebrow. The stamp is a property of the shared
  // state rather than of either list, and this is now the only action view that
  // renders it — so this is where its wording is pinned.

  testWidgets(
      "a generation bump refetches the passive Klasgroepen overview's "
      'freshness (#108)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    final snapshots = InMemorySnapshotStore();

    final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
    await s1.controller.sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ClassGroupsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Generatie 1'), findsOneWidget);

    s1.wisaResult = wisaSnap(
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
      students: [wisaStudent(classGroup: '3D')],
    );
    await s1.controller.sync();
    await s2.controller.onStoreChanged(2);
    await tester.pumpAndSettle();

    expect(find.textContaining('Generatie 2'), findsOneWidget);
    expect(find.textContaining('Generatie 1'), findsNothing);
  });

  testWidgets(
      'the freshness stamp carries the date once the shared state is no longer '
      'from today (#192)', (WidgetTester tester) async {
    // The shared view was materialized at kFixtureDate, a past day. Time-only
    // rendered that as "Generatie 1 · 02:00 door …" —
    // indistinguishable from a view materialized minutes ago, the same
    // confusion #192 fixes on the Reconcile last-sync box.
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Derived here rather than through the production formatter, so this pins
    // the rendered text instead of restating the implementation.
    final DateTime t = kFixtureDate.toLocal();
    final String dm = '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}';
    final String hhmm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';

    expect(find.textContaining('Generatie 1 · $dm'), findsOneWidget);
    expect(find.textContaining('Generatie 1 · $hhmm'), findsNothing,
        reason: 'a stamp from a past day is never rendered as bare time');
  });

  testWidgets(
      'the freshness stamp names the werkdatum the roster was pulled with '
      '(#247)', (WidgetTester tester) async {
    // "Wie synchroniseerde, wanneer" says when the pass ran, never which school
    // year it describes — and WISA answers *as of* a date, so a pull made on
    // the wrong side of the rollover reads here exactly like a class that went
    // missing (#239). The stamp comes off the shared per-system record, so this
    // passive session reads the date without having run the pull.
    _useTallWindow(tester);
    final store = await seededLinkedStore(
      <MaterializedAccount>[
        matAccount(id: 's1', label: 'Jane Doe', withAction: true),
      ],
      systemSyncs: <core.Origin, SystemSyncMeta>{
        core.Origin.wisa: SystemSyncMeta(
          syncedBy: 'operator@school.example',
          at: kFixtureDate,
          workDate: DateTime(2025, 9, 1),
        ),
      },
    );
    final harness = ReconcileHarness(linkedStore: store);
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // In the wire's own dd/MM/yyyy, the way the Log panel's pull line and the
    // `Werkdatum` SOAP parameter both spell it.
    expect(find.textContaining('· werkdatum 01/09/2025'), findsOneWidget);
  });

  testWidgets(
      'a shared view synced before the werkdatum was recorded renders the '
      'stamp unchanged (#247)', (WidgetTester tester) async {
    // The store in production already holds views written without it, and a
    // Smartschool/Azure-only stamp never has one. Neither may invent a date,
    // and neither may lose the "wie, wanneer" half over its absence.
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.textContaining('werkdatum'), findsNothing);
    expect(
      find.textContaining('Generatie 1'),
      findsOneWidget,
      reason: 'the who/when half stands on its own',
    );
  });

  testWidgets(
      'the stamp names the werkdatum the stored view was pulled with, not the '
      'one Instellingen now holds (#247)', (WidgetTester tester) async {
    // The disagreement the issue is about. #238 made the werkdatum live, so
    // between a save and the next Synchroniseer the setting says one school
    // year and the installed roster is another. Driven over the *production*
    // WISA pull, so the date on screen is the one that really went out.
    _useTallWindow(tester);
    final live = LiveSettings(AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    ));
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    await harness.controller.sync();
    expect(wire.werkdatums, <String>['01/09/2025']);

    // The operator moves the werkdatum to the new school year and saves. Until
    // they sync, the overview below is still the old year's.
    live.publish(AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9, 1)),
      ),
    ));

    await tester
        .pumpWidget(_wrap(ClassGroupsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.textContaining('· werkdatum 01/09/2025'), findsOneWidget);
    expect(find.textContaining('01/09/2026'), findsNothing,
        reason: 'a saved werkdatum describes the next pull, not this view');
  });
}
