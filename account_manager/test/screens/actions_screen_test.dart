import 'dart:async';

import 'package:account_actions/account_actions.dart' show ActionOutcome;
import 'package:account_core/account_core.dart' show Address, Origin;
import 'package:account_manager/src/reconcile/reconcile_controller.dart'
    show ApplyScope, PendingAccountEntry, ReconcileController;
import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:account_manager/src/screens/system_indicator.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A wide, tall viewport: the list and the details pane side by side, which is
/// the layout #295 is about. Tall as well, so a pane's rows lay out without the
/// assertions tripping on the fold.
void _useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A window below the split breakpoint, where the two panes become one.
void _useNarrowWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(700, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder _row(String id) => find.byKey(ValueKey('account-row-$id'));

Finder _cell(String id, Origin system) =>
    find.byKey(ValueKey('account-cell-$id-${system.name}'));

SystemIndicatorState _cellState(
  WidgetTester tester,
  String id,
  Origin system,
) =>
    tester.widget<SystemIndicatorCell>(_cell(id, system)).state;

/// The linker's id for the account displayed as [label] — what every row,
/// cell and details block on this screen is keyed by.
String _idOf(ReconcileController controller, String label) =>
    controller.linkedAccounts.firstWhere((a) => a.label == label).id.value;

/// Selects one row of the flat list.
Future<void> _select(WidgetTester tester, String id) async {
  await tester.ensureVisible(_row(id));
  await tester.tap(_row(id));
  await tester.pumpAndSettle();
}

/// The one pending entry of the student family, whichever fixture raised it.
PendingAccountEntry _studentEntry(ReconcileController controller) =>
    controller.pendingEntries.firstWhere((e) => e.family == 'student');

/// A WISA-departed scenario: [count] Smartschool-only active accounts (no
/// WISA, no Azure), each raising the mutually-exclusive unregister/delete
/// choice (#110). They land in the "Zonder klas" bucket.
ReconcileHarness departedHarness({int count = 1}) => ReconcileHarness(
      wisa: wisaSnap(students: const []),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          for (var i = 0; i < count; i++)
            ssAccount(
              uid: 'user$i',
              accountId: '$i',
              mail: 'user$i@student.school.example',
            ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ActionsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('actions-only-with-actions')), findsNothing);
  });

  testWidgets('a failed bootstrap offers a retry, in Dutch (#253)',
      (WidgetTester tester) async {
    // The stand-in panels are as operator-facing as the list they replace, so
    // they speak the same language as it. The retry itself is the point of the
    // panel: a second attempt has to be one button away.
    var attempts = 0;
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: () async {
      attempts++;
      if (attempts == 1) throw StateError('geen verbinding');
      return ReconcileHarness().bootstrap();
    })));
    await tester.pumpAndSettle();

    expect(find.text('Kan het Acties-scherm niet openen'), findsOneWidget);
    final retry = find.byKey(const ValueKey('actions-bootstrap-retry'));
    expect(find.descendant(of: retry, matching: find.text('Probeer opnieuw')),
        findsOneWidget);

    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Kan het Acties-scherm niet openen'), findsNothing);
    // The screen behind the panel, named by the one line its header still
    // carries since #309 — the eyebrow, in the design system's own upper case.
    expect(find.text('ARCADIA · ACTIES'), findsOneWidget);
  });

  // --- The flat list itself (#295) -----------------------------------------

  testWidgets(
      'Acties opens on one flat list of accounts with three system '
      'indicators, and no jaar → klas drill-down (#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = appliedClassWorkHarness();
    // A sync on the Reconcile screen populates the shared controller; drive it
    // programmatically, then open the Actions tab over the same controller.
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // No tree: no "Overzicht" heading, no grade-year accordion, no class node.
    expect(find.text('Overzicht'), findsNothing);
    expect(find.text('Jaar 3'), findsNothing);
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsNothing);

    // Sam has the one piece of student work in this fixture (a stale Office
    // 365 display name), so under the default filter he is the list.
    final sam = _idOf(harness.controller, 'Sam Sels');
    expect(_row(sam), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-list')), findsOneWidget);

    // A row says who, where, and what each of the three systems thinks.
    expect(
      find.descendant(of: _row(sam), matching: find.text('Sam Sels')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row(sam), matching: find.text('3C')),
      findsOneWidget,
      reason: 'the class is on the row, not two clicks above it',
    );
    expect(_cellState(tester, sam, Origin.wisa), SystemIndicatorState.inOrder);
    expect(_cellState(tester, sam, Origin.smartschool),
        SystemIndicatorState.inOrder);
    expect(
        _cellState(tester, sam, Origin.azure), SystemIndicatorState.needsWork,
        reason: 'his pending work is an Azure write, and the cell says so');
  });

  testWidgets(
      'an account missing from a system reads red there, and a system filter '
      'is what finds them (#295/#298)', (WidgetTester tester) async {
    _useWideWindow(tester);
    // Two departed Smartschool-only students: no WISA record, no Azure account.
    final harness = departedHarness(count: 2);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    expect(_cellState(tester, id, Origin.wisa), SystemIndicatorState.missing);
    expect(_cellState(tester, id, Origin.azure), SystemIndicatorState.missing);
    expect(_cellState(tester, id, Origin.smartschool),
        SystemIndicatorState.needsWork,
        reason: 'the account is there and the departure write lands there');

    // "Sort by system" is a filter (#295): narrowing to Office 365 keeps
    // everyone that system has something to say about — here, the two missing
    // accounts — and dropping it back to "Alle" restores the list.
    await tester.tap(find.byKey(const ValueKey('actions-system-azure')));
    await tester.pumpAndSettle();
    expect(_row(id), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('actions-system-wisa')));
    await tester.pumpAndSettle();
    expect(_row(id), findsOneWidget, reason: 'missing from WISA counts too');
  });

  testWidgets(
      'a student who moved to a sibling group school reads blue in WISA, '
      'beside the red of one gone from the group (#392)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Jane is in sibling school 2 only (groupOnly, keep Office 365); Tom is in
    // no WISA school at all (absent, delete Office 365). Both still hold our
    // Smartschool and our Office 365 account, so WISA is the only cell that can
    // tell the two departures apart.
    final harness = siblingAndGoneHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final jane = _idOf(harness.controller, 'Jane Doe');
    final tom = _idOf(harness.controller, 'Tom Tomsen');
    expect(
      _cellState(tester, jane, Origin.wisa),
      SystemIndicatorState.elsewhere,
    );
    expect(_cellState(tester, tom, Origin.wisa), SystemIndicatorState.missing);

    // A WISA-only reading: the other two cells say what they always said.
    expect(
      _cellState(tester, jane, Origin.smartschool),
      SystemIndicatorState.needsWork,
      reason: 'our Smartschool departure is exactly the work blue implies',
    );
    expect(
      _cellState(tester, jane, Origin.azure),
      isNot(SystemIndicatorState.missing),
      reason: 'her Office 365 account is kept, and the cell must not deny it',
    );
    expect(
      _cellState(tester, tom, Origin.smartschool),
      SystemIndicatorState.needsWork,
    );

    // The details pane repeats the row's three cells, and must repeat this one.
    await _select(tester, jane);
    expect(
      tester
          .widget<SystemIndicatorCell>(
              find.byKey(ValueKey('account-detail-cell-$jane-wisa')))
          .state,
      SystemIndicatorState.elsewhere,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-detail-cell-$jane-wisa')),
        matching: find.byTooltip(
            'Niet meer in onze school, wel nog in een school van de groep'),
      ),
      findsOneWidget,
      reason: 'the tooltip is the legend: it is where blue says what it means',
    );
  });

  testWidgets('the system filter hides the rows that system is happy with',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Sam's Office 365 display name is stale; Tom's is right. With the work
    // filter off both are listed, and narrowing to Office 365 keeps only Sam.
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();

    final sam = _idOf(harness.controller, 'Sam Sels');
    final tom = _idOf(harness.controller, 'Tom Tas');
    expect(_row(sam), findsOneWidget);
    expect(_row(tom), findsOneWidget);
    expect(_cellState(tester, tom, Origin.azure), SystemIndicatorState.inOrder);

    await tester.tap(find.byKey(const ValueKey('actions-system-azure')));
    await tester.pumpAndSettle();
    expect(_row(sam), findsOneWidget);
    expect(_row(tom), findsNothing,
        reason: 'Office 365 has nothing to say about Tom');

    await tester.tap(find.byKey(const ValueKey('actions-system-alle')));
    await tester.pumpAndSettle();
    expect(_row(tom), findsOneWidget);
  });

  testWidgets(
      'the list sorts by name and by class, and the choice survives a '
      'selection (#295)', (WidgetTester tester) async {
    _useWideWindow(tester);
    // Three students in one situation across two classes: Sam and Sara in 3C,
    // Tom in 3D. By name that is Sam, Sara, Tom; by class it is 3C before 3D,
    // which puts Tom last either way — so the fixture is read by position, and
    // the two orders are told apart by the *class* column, not the names.
    final harness = crossClassSituationHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The list's own WISA cells, in tree order — one per row, so their keys
    // read out the order the rows are in. Scoped to the list, since the details
    // pane repeats the three cells of whatever is selected.
    List<String> labels() => tester
        .widgetList<SystemIndicatorCell>(find.descendant(
          of: find.byKey(const ValueKey('actions-list')),
          matching: find.byWidgetPredicate(
              (w) => w is SystemIndicatorCell && w.system == Origin.wisa),
        ))
        .map((c) => (c.key! as ValueKey<String>).value)
        .toList();

    final sam = _idOf(harness.controller, 'Sam Sels');
    final sara = _idOf(harness.controller, 'Sara Segers');
    final tom = _idOf(harness.controller, 'Tom Tas');

    // Naam is the default order.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('actions-sort-naam')))
          .selected,
      isTrue,
    );
    expect(labels(), <String>[
      'account-cell-$sam-wisa',
      'account-cell-$sara-wisa',
      'account-cell-$tom-wisa',
    ]);

    // By class, 3D comes after 3C — and the members of 3C keep their name
    // order, so a class of twenty never reshuffles between rebuilds.
    await tester.tap(find.byKey(const ValueKey('actions-sort-klas')));
    await tester.pumpAndSettle();
    expect(labels().last, 'account-cell-$tom-wisa');

    // Selecting a row leaves the order alone — it describes the list, not the
    // row.
    await _select(tester, sara);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('actions-sort-klas')))
          .selected,
      isTrue,
    );
    expect(labels().last, 'account-cell-$tom-wisa');
  });

  testWidgets(
      'the details pane shows every decision of the selected account, each '
      'under its own heading and stated once (#281/#283/#300/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Jane raises two decisions — an Azure rename and a Smartschool class move
    // — so this pins that both are on screen, once each, led by the system
    // they write to.
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final entry = _studentEntry(harness.controller);
    final id = entry.targetId;

    // Nothing selected: the pane says so and no decision is on screen.
    expect(find.byKey(const ValueKey('actions-detail-empty')), findsOneWidget);
    for (final summary in const <String>[
      'Wijzig de naam in Azure',
      'Wijzig de klas in Smartschool',
    ]) {
      expect(find.text(summary), findsNothing);
    }

    await _select(tester, id);

    final Finder pane = find.byKey(ValueKey('actions-detail-$id'));
    expect(pane, findsOneWidget);
    expect(find.byKey(const ValueKey('actions-detail-empty')), findsNothing);

    for (final (index, summary) in const <String>[
      'Wijzig de naam in Azure',
      'Wijzig de klas in Smartschool',
    ].indexed) {
      expect(
        find.descendant(of: pane, matching: find.text(summary)),
        findsOneWidget,
        reason: 'each decision is stated exactly once (#300)',
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('entry-choice-student-$id-$index')),
          matching: find.text(summary),
        ),
        findsOneWidget,
        reason: 'and it is the heading that groups the diff below it (#281)',
      );
    }
    // Each heading led by the system it writes to (#298).
    expect(find.descendant(of: pane, matching: find.text('Smartschool ·')),
        findsOneWidget);
    expect(find.descendant(of: pane, matching: find.text('Office 365 ·')),
        findsOneWidget);
    // The per-card apply pair is the only apply on this screen.
    expect(find.byKey(ValueKey('entry-apply-$id')), findsOneWidget);
    expect(find.byKey(ValueKey('entry-dry-run-$id')), findsOneWidget);
  });

  testWidgets(
      'the header is the eyebrow and nothing else, and still offers nothing '
      'that acts on the whole list (#309/#294)', (WidgetTester tester) async {
    // #309: the account list is the view, and everything stacked above it was
    // preamble charged to every visit. The title restated the eyebrow, the
    // count was four digits nobody can act on, the pointer at Klasgroepen
    // belonged on Klasgroepen and the freshness stamp describes the shared
    // state rather than this list.
    //
    // #294's half of the same header still holds: the global "Dry-run alles" /
    // "Alles toepassen" pair that wrote every pending action in every class off
    // one dialog is gone, and nothing replaces it. Every way to act on the work
    // is reached by opening it first.
    _useWideWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The one line that stays.
    expect(find.text('ARCADIA · ACTIES'), findsOneWidget);
    // …and the four that came off.
    expect(find.text('Acties'), findsNothing,
        reason: 'the title restated the eyebrow one line above it');
    expect(find.textContaining('openstaande actie'), findsNothing,
        reason: 'the count line is gone from this header');
    expect(find.byKey(const ValueKey('actions-class-attention')), findsNothing,
        reason: 'what Klasgroepen is holding is stated on Klasgroepen');
    expect(find.textContaining('Generatie'), findsNothing,
        reason:
            'the freshness stamp describes the shared state, not this list');

    expect(find.byKey(const ValueKey('actions-dry-run')), findsNothing);
    expect(find.byKey(const ValueKey('actions-apply')), findsNothing);
    expect(find.text('Dry-run alles'), findsNothing);
    expect(find.text('Alles toepassen'), findsNothing);
    // And the flat list adds no cohort header of its own — school-wide bulk
    // apply with its cohort visible first is #296's, not this layout's.
    expect(find.textContaining('in dezelfde situatie'), findsNothing);
  });

  testWidgets('the stripped header lifts the list toward the top (#309)',
      (WidgetTester tester) async {
    // The point of the removal, measured rather than asserted about: with the
    // title, the count, the pointer and the stamp gone, the search box and the
    // list start materially higher than the four lines they used to sit under.
    // The fixture carries class work as well, so the pointer at Klasgroepen
    // would have rendered under the old header — this is the worst case, not
    // the best one.
    _useWideWindow(tester);
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final double eyebrowBottom =
        tester.getBottomLeft(find.text('ARCADIA · ACTIES')).dy;
    final double searchTop =
        tester.getTopLeft(find.byKey(const ValueKey('actions-search'))).dy;

    // One `PlinkSpacing.s4` gap (the state notice is absent in this session)
    // rather than four text lines plus their spacing — which is what "the list
    // starts materially higher" concretely means.
    expect(searchTop - eyebrowBottom, lessThan(40),
        reason: 'nothing but spacing stands between the eyebrow and the box');
    // And a pin on the whole block above the list — eyebrow, search box, work
    // switch, sort and system chips, family tabs. It measured 422 when #309
    // landed, 366 once #310 put the box and the switch on one row, and 240
    // since #311 took the select-all bar out from under them; every line put
    // back into the header adds some 30 to that, and the bar alone was worth
    // 126, which is what this number is guarding. What the operator actually
    // gains from it is asserted at a real 1080p window in the integration
    // suite, in rows on screen.
    expect(tester.getTopLeft(find.byKey(const ValueKey('actions-list'))).dy,
        lessThan(260));
  });

  // --- The name box and the work-list switch on one row (#310) -------------

  testWidgets(
      'the name box and the work-list switch share one row, and the box is '
      'bounded rather than full-bleed (#310)', (WidgetTester tester) async {
    // Two controls that shape the same list, stacked as two full-width rows:
    // the box claimed the whole content width — well over 1200px here — for a
    // field that holds a name, and the switch cost a row of its own under it.
    _useWideWindow(tester);
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final Rect search =
        tester.getRect(find.byKey(const ValueKey('actions-search')));
    final Rect toggle =
        tester.getRect(find.byKey(const ValueKey('actions-only-with-actions')));
    final Rect label =
        tester.getRect(find.text('Toon enkel accounts met acties'));

    // One row: the switch and its label stand to the right of the box, and
    // every one of the three overlaps the others vertically instead of
    // stacking under them.
    expect(toggle.left, greaterThan(search.right));
    expect(label.left, greaterThan(toggle.right));
    expect(toggle.top, lessThan(search.bottom));
    expect(search.top, lessThan(toggle.bottom));
    expect(label.top, lessThan(search.bottom));

    // Bounded, not full-bleed: a fraction of the width it used to fill.
    final double paneWidth = tester.getSize(find.byType(ActionsScreen)).width;
    expect(paneWidth, greaterThan(1000), reason: 'a genuinely wide window');
    expect(search.width, lessThanOrEqualTo(380));
    expect(search.width, lessThan(paneWidth / 3));

    // And the row it saved: the filter chips follow the box by one spacing gap,
    // where a whole switch row used to stand between them.
    final Rect chips =
        tester.getRect(find.byKey(const ValueKey('actions-system-azure')));
    expect(chips.top - search.bottom, lessThan(24),
        reason: 'nothing but spacing separates the box from the chips');
  });

  testWidgets(
      'a window too narrow for both wraps the row instead of overflowing '
      '(#310)', (WidgetTester tester) async {
    // The failure mode a fixed-width box would have introduced. At 700px the
    // box, the switch and a 30-character label do not fit side by side, so the
    // switch takes a second run — and the box shrinks to what there is rather
    // than holding its cap and spilling.
    _useNarrowWindow(tester);
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final Rect search =
        tester.getRect(find.byKey(const ValueKey('actions-search')));
    final Rect toggle =
        tester.getRect(find.byKey(const ValueKey('actions-only-with-actions')));

    expect(toggle.top, greaterThanOrEqualTo(search.bottom),
        reason: 'the switch wrapped onto its own run');
    // Still capped, even on the run it now has to itself — a narrow window is
    // not a reason to give a name field 636px.
    expect(search.width, lessThanOrEqualTo(380));
    // Both stay inside the 700px window: nothing is clipped off the right.
    expect(search.right, lessThanOrEqualTo(700));
    expect(toggle.right, lessThanOrEqualTo(700));
    // Still one switch and one box, still operable.
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
              find.byKey(const ValueKey('actions-only-with-actions')))
          .value,
      isFalse,
    );
  });

  // --- School-wide apply-all, cohort first (#296) ---------------------------

  group('a decision can be applied across the whole school (#296)', () {
    /// The block-level "Toepassen op alle (N)" of the [index]-th decision on
    /// [id]'s card.
    Finder applyAll(String id, int index) =>
        find.byKey(ValueKey('decision-apply-all-student-$id-$index'));

    /// Which rows the flat list is showing right now, by account id.
    Set<String> listedRows(WidgetTester tester) => tester
        .widgetList<SystemIndicatorCell>(find.descendant(
          of: find.byKey(const ValueKey('actions-list')),
          matching: find.byWidgetPredicate(
              (w) => w is SystemIndicatorCell && w.system == Origin.wisa),
        ))
        .map((c) => (c.key! as ValueKey<String>)
            .value
            .replaceFirst('account-cell-', '')
            .replaceFirst('-wisa', ''))
        .toSet();

    int classMoves(ReconcileHarness harness) => harness.soap.soapActions
        .where((a) => a.endsWith('#saveUserToClass'))
        .length;

    /// The September rollover in miniature: three students moved up into `4A`
    /// while Smartschool still has all three in last year's `3C`, so every one
    /// of them needs the same class change — and Sam alone also carries a stale
    /// Office 365 display name, which is a decision #293 withholds from bulk.
    Future<ReconcileHarness> openRollover(WidgetTester tester) async {
      _useWideWindow(tester);
      final harness = rolloverHarness();
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets(
        'only the sanctioned decision offers it, and only when more than one '
        'account needs it (#293)', (WidgetTester tester) async {
      final harness = await openRollover(tester);
      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);

      // Sam's card, in dispatch order: the Office 365 rename, then the class
      // move. The move is the rollover action legacy granted
      // `canBeAppliedToAll`; the rename is a judgement call and is withheld.
      expect(
        harness.controller.pendingEntries
            .firstWhere((e) => e.target == 'Sam Sels')
            .choices
            .map((c) => c.situationId),
        <String>['ModifyAzureName', 'MoveToSmartschoolClassGroup'],
      );
      expect(applyAll(sam, 0), findsNothing,
          reason: 'a rename over the whole school is exactly what the sanction '
              'refuses');
      expect(applyAll(sam, 1), findsOneWidget);
      expect(
        find.descendant(
            of: applyAll(sam, 1), matching: find.text('Toepassen op alle (3)')),
        findsOneWidget,
      );
    });

    testWidgets('an account alone in its situation gets no apply-all',
        (WidgetTester tester) async {
      // Jane needs the very same class move, but she is the only one — and
      // "op alle (1)" says nothing the Toepassen button below it does not.
      _useWideWindow(tester);
      final harness = ReconcileHarness();
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      final id = _studentEntry(harness.controller).targetId;
      await _select(tester, id);

      expect(find.textContaining('Toepassen op alle'), findsNothing);
      expect(find.byKey(ValueKey('entry-apply-$id')), findsOneWidget);
    });

    testWidgets(
        'pressing it shows the cohort instead of writing it, whatever the '
        'search box was set to', (WidgetTester tester) async {
      final harness = await openRollover(tester);
      final sam = _idOf(harness.controller, 'Sam Sels');
      final sara = _idOf(harness.controller, 'Sara Segers');
      final tom = _idOf(harness.controller, 'Tom Tas');

      // The operator has been looking at Sam alone.
      await tester.enterText(
          find.byKey(const ValueKey('actions-search')), 'Sam');
      await tester.pumpAndSettle();
      expect(listedRows(tester), <String>{sam});

      await _select(tester, sam);
      await tester.ensureVisible(applyAll(sam, 1));
      await tester.tap(applyAll(sam, 1));
      await tester.pumpAndSettle();

      // The whole cohort is on screen — the count is school-wide, so the list
      // it is confirmed against has to be too.
      expect(listedRows(tester), <String>{sam, sara, tom});
      expect(
          find.byKey(const ValueKey('actions-cohort-banner')), findsOneWidget);
      expect(
        find.text('Wijzig de klas in Smartschool — 3 account(s) in de hele '
            'school'),
        findsOneWidget,
      );
      // The list's own controls stand down: they would either narrow the very
      // list the operator is being asked to confirm, or do nothing.
      expect(find.byKey(const ValueKey('actions-search')), findsNothing);
      expect(find.byKey(const ValueKey('actions-only-with-actions')),
          findsNothing);
      // The header used to restate that the list is one decision's cohort. It
      // says nothing at all since #309 — the banner above the list, asserted on
      // just above, is what describes the list the operator is confirming.
      expect(find.textContaining('de lijst toont'), findsNothing);

      // And nothing has been written.
      expect(
          harness.soap.soapActions.where((a) => a.contains('save')), isEmpty);
      expect(find.text('Resultaat van het toepassen'), findsNothing);
    });

    testWidgets('Annuleer gives the list and its controls back',
        (WidgetTester tester) async {
      final harness = await openRollover(tester);
      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      await tester.ensureVisible(applyAll(sam, 1));
      await tester.tap(applyAll(sam, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('actions-cohort-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('actions-cohort-banner')), findsNothing);
      expect(find.byKey(const ValueKey('actions-search')), findsOneWidget);
      expect(classMoves(harness), 0);
    });

    testWidgets(
        'the confirmation names that one decision, and the pass writes it for '
        'the whole cohort (#292/#234)', (WidgetTester tester) async {
      final harness = await openRollover(tester);
      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      await tester.ensureVisible(applyAll(sam, 1));
      await tester.tap(applyAll(sam, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('actions-cohort-apply')));
      await tester.pumpAndSettle();

      final Finder dialog = find.byType(AlertDialog);
      expect(find.text('Toepassen op 3 account(s)?'), findsOneWidget);
      expect(
        find.descendant(
            of: dialog, matching: find.textContaining('3 wijzigingen')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: dialog, matching: find.textContaining('Office 365')),
        findsNothing,
        reason: "summing every decision on every card would quote Sam's rename "
            'and then not write it',
      );

      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      expect(classMoves(harness), 3);
      expect(harness.graph.requests.where((r) => r.method == 'PATCH'), isEmpty,
          reason: 'the rename was never armed');
      expect(harness.controller.applyResults, hasLength(3));
      // The review is over: what it was built from has been written.
      expect(find.byKey(const ValueKey('actions-cohort-banner')), findsNothing);
      expect(find.byKey(const ValueKey('actions-search')), findsOneWidget);
    });

    testWidgets('a dry-run covers the same cohort and leaves it standing',
        (WidgetTester tester) async {
      final harness = await openRollover(tester);
      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      await tester.ensureVisible(applyAll(sam, 1));
      await tester.tap(applyAll(sam, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('actions-cohort-dry-run')));
      await tester.pumpAndSettle();

      expect(harness.controller.dryRunResults, hasLength(3));
      expect(classMoves(harness), 0);
      expect(find.text('Resultaat van de dry-run'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('actions-cohort-banner')), findsOneWidget,
          reason: 'the dry-run is what the operator reads before pressing the '
              'button beside it, so it must not dissolve the review');
    });
  });

  // --- No selection anywhere on the list (#311) ----------------------------

  group('the list offers no selection at all (#311)', () {
    /// Opens Acties over [harness] with the flat list on screen.
    Future<void> open(WidgetTester tester, ReconcileHarness harness) async {
      _useWideWindow(tester);
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();
    }

    /// Everything #297 put on the screen, asserted absent in one place.
    void expectNoSelection(WidgetTester tester) {
      expect(find.byKey(const ValueKey('actions-selection-bar')), findsNothing);
      expect(find.byKey(const ValueKey('actions-select-all')), findsNothing);
      expect(
          find.byKey(const ValueKey('actions-selection-clear')), findsNothing);
      expect(
          find.byKey(const ValueKey('actions-selection-scope')), findsNothing);
      expect(find.byKey(const ValueKey('actions-selection-dry-run')),
          findsNothing);
      expect(
          find.byKey(const ValueKey('actions-selection-apply')), findsNothing);
      expect(find.textContaining('Selecteer alle zichtbare'), findsNothing);
      expect(find.textContaining('geselecteerd'), findsNothing);
      // And no checkbox anywhere on the screen — the bar's select-all and the
      // per-row ticks were the only ones this view ever rendered.
      expect(find.byType(Checkbox), findsNothing);
    }

    testWidgets(
        'no bar above the list and no checkbox on a row that carries work',
        (WidgetTester tester) async {
      // The state #297's bar was loudest in: rows with applyable work, which is
      // when it rendered at all. Sam's Office 365 display name is stale; Tom is
      // in order everywhere.
      final harness = appliedClassWorkHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      expect(_row(sam), findsOneWidget, reason: 'he does carry work');
      expect(find.byKey(ValueKey('account-check-$sam')), findsNothing);
      expectNoSelection(tester);

      // Off the work list the settled accounts come back, and they have nothing
      // to tick either — nor a blank column where a checkbox used to be.
      await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
      await tester.pumpAndSettle();
      final tom = _idOf(harness.controller, 'Tom Tas');
      expect(_row(tom), findsOneWidget);
      expect(find.byKey(ValueKey('account-check-$tom')), findsNothing);
      expectNoSelection(tester);
    });

    testWidgets('nor over a whole rollover roster',
        (WidgetTester tester) async {
      // Three students sharing one decision is the case the bar was built for,
      // and the one where "Selecteer alle zichtbare (3)" was one press away from
      // staging every row the filter happened to be showing.
      final harness = rolloverHarness();
      await open(tester, harness);

      for (final label in <String>['Sam Sels', 'Sara Segers', 'Tom Tas']) {
        final id = _idOf(harness.controller, label);
        expect(_row(id), findsOneWidget);
        expect(find.byKey(ValueKey('account-check-$id')), findsNothing);
      }
      expectNoSelection(tester);

      // Selecting a row still opens its pane, which is the one thing a row was
      // ever meant to do.
      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      expect(find.byKey(ValueKey('actions-detail-$sam')), findsOneWidget);
      expectNoSelection(tester);
    });

    testWidgets(
        'the cohort review is the only bulk path left, and it still works '
        '(#296)', (WidgetTester tester) async {
      // #311 removes the *chosen* set, not the computed one. The sanctioned
      // decision still arms its school-wide review, still shows the cohort
      // before confirming, and still writes exactly it.
      final harness = rolloverHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      final Finder moveAll =
          find.byKey(ValueKey('decision-apply-all-student-$sam-1'));
      await tester.ensureVisible(moveAll);
      await tester.tap(moveAll);
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('actions-cohort-banner')), findsOneWidget);
      expectNoSelection(tester);

      await tester.tap(find.byKey(const ValueKey('actions-cohort-apply')));
      await tester.pumpAndSettle();
      expect(find.text('Toepassen op 3 account(s)?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      expect(
        harness.soap.soapActions
            .where((a) => a.endsWith('#saveUserToClass'))
            .length,
        3,
      );
    });

    testWidgets(
        'the September leavers sweep runs one account at a time from the pane',
        (WidgetTester tester) async {
      // The workflow #297 was written for, and what it costs now that the ticks
      // are gone: three Smartschool-only accounts, each raising the
      // unregister/delete either-or, resolved one pane at a time. Slower on
      // purpose — the safety of a destructive action is that it is never
      // applied to a set nobody opened.
      final harness = departedHarness(count: 3);
      await open(tester, harness);

      final ids = <String>[
        for (final e in harness.controller.pendingEntries)
          if (e.family == 'student') e.targetId,
      ];
      expect(ids, hasLength(3));

      await _select(tester, ids.first);
      expect(find.textContaining('Toepassen op alle'), findsNothing,
          reason: 'nobody presses one button that deletes every account the '
              'app believes has left');

      // The risky-action confirmation path from the pane is untouched: it names
      // the write, and only on Annuleer-free confirmation does anything happen.
      final Finder apply = find.byKey(ValueKey('entry-apply-${ids.first}'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      expect(harness.controller.applyResults, hasLength(1),
          reason: 'one account, because one account is what was opened');
      expect(harness.controller.applyResults!.single.targetId, ids.first);
      expect(
        harness.controller.applyResults!.map((r) => r.changes.summary).toSet(),
        <String>{'Schrijf de leerling uit in Smartschool'},
        reason: 'the default of that either/or is the non-destructive one',
      );
      // The other two are on the list beside him, each still its own decision
      // to make — which is exactly what removing the sweep costs, and buys.
      for (final id in ids.skip(1)) {
        expect(_row(id), findsOneWidget);
      }
    });
  });

  // --- What an apply leaves on the screen (#299) ---------------------------

  group('an apply updates the list and the pane in place (#299)', () {
    /// Applies every decision on the card the details pane is open on, through
    /// the confirmation the operator sees.
    Future<void> applyCard(WidgetTester tester, String id) async {
      final Finder apply = find.byKey(ValueKey('entry-apply-$id'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();
    }

    /// The "Toegepast" marker a held row carries once nothing is left on it.
    Finder done(String id) => find.byKey(ValueKey('account-done-$id'));

    /// Opens Acties over [harness] with the flat list on screen.
    Future<void> open(WidgetTester tester, ReconcileHarness harness) async {
      _useWideWindow(tester);
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'the account the pass settled stays in the filtered list, marked done, '
        'with the pane still on it', (WidgetTester tester) async {
      // Sam's stale Office 365 display name is his only work, and a real write
      // genuinely clears it — so the instant the pass ends he stops matching
      // "toon enkel accounts met acties" and the list would drop him, taking
      // the open pane and the verdict he was waiting for with him.
      final harness = appliedClassWorkHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      await applyCard(tester, sam);

      expect(harness.graph.requests.where((r) => r.method == 'PATCH'),
          hasLength(1));
      expect(
        harness.controller.pendingEntries.where((e) => e.targetId == sam),
        isEmpty,
        reason: 'the write settled his one decision',
      );

      // The filter never moved, and he is still on the list — marked as what
      // just happened to him, not as an account that was always in order.
      expect(
        tester
            .widget<Switch>(
                find.byKey(const ValueKey('actions-only-with-actions')))
            .value,
        isTrue,
      );
      expect(_row(sam), findsOneWidget,
          reason: 'a row that vanishes on the strength of its own success '
              'takes the verdict off the screen with it');
      expect(done(sam), findsOneWidget);
      expect(
          _cellState(tester, sam, Origin.azure), SystemIndicatorState.inOrder,
          reason: 'the indicators re-rendered in place off the refreshed view');

      // The pane never let go of him, and it says what the pass did — with no
      // re-selection, and no sync.
      expect(find.byKey(ValueKey('actions-detail-$sam')), findsOneWidget);
      expect(find.byKey(const ValueKey('actions-detail-empty')), findsNothing);
      final Finder verdict =
          find.byKey(ValueKey('entry-outcomes-student-$sam'));
      await tester.ensureVisible(verdict);
      expect(
        find.descendant(
            of: verdict, matching: find.text('Wijzig de naam in Azure')),
        findsOneWidget,
      );
    });

    testWidgets(
        'a pass where one write lands and another is refused keeps the row and '
        'shows both verdicts (#272/#283)', (WidgetTester tester) async {
      // The reported shape behind #272, on an account rather than a class: one
      // half of the card lands and the other is refused. A row that dropped out
      // on the strength of the half that worked would make the refusal
      // unreadable anywhere but the log panel on another screen.
      var calls = 0;
      final harness = rolloverHarness(applyGate: () async {
        if (++calls == 2) throw StateError('Smartschool weigerde de opdracht');
      });
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      await _select(tester, sam);
      await applyCard(tester, sam);

      // He keeps the decision that was refused, so the row stands on its own
      // work — and is emphatically not marked done.
      expect(_row(sam), findsOneWidget);
      expect(done(sam), findsNothing);
      expect(_cellState(tester, sam, Origin.smartschool),
          SystemIndicatorState.needsWork);
      expect(
          _cellState(tester, sam, Origin.azure), SystemIndicatorState.inOrder,
          reason: 'the rename landed, and the cell re-rendered in place');

      // The refusal sits under the question it answers (#283)…
      final Finder refused =
          find.byKey(ValueKey('entry-outcomes-student-$sam-0'));
      await tester.ensureVisible(refused);
      expect(
        find.descendant(
          of: refused,
          matching: find.textContaining('Smartschool weigerde de opdracht'),
        ),
        findsOneWidget,
      );
      // …and the half that landed keeps its own at card level, a settled
      // decision having no block left to sit in.
      final Finder settled =
          find.byKey(ValueKey('entry-outcomes-student-$sam'));
      await tester.ensureVisible(settled);
      expect(
        find.descendant(
            of: settled, matching: find.text('Wijzig de naam in Azure')),
        findsOneWidget,
      );
    });

    testWidgets('moving to an account the pass did not touch lets the row go',
        (WidgetTester tester) async {
      // Three students in one situation; applying Sam settles Sam alone. The
      // hold is a courtesy to somebody reading a verdict, not a second filter,
      // so it has to clear or the list accumulates finished rows.
      final harness = crossClassSituationHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      final sara = _idOf(harness.controller, 'Sara Segers');
      await _select(tester, sam);
      await applyCard(tester, sam);
      expect(_row(sam), findsOneWidget);

      await _select(tester, sara);
      expect(_row(sam), findsNothing);
      expect(find.byKey(ValueKey('actions-detail-$sara')), findsOneWidget);
    });

    testWidgets('a sort or a search lets the held rows go',
        (WidgetTester tester) async {
      // Both reshape the list, which is the operator saying they are done
      // reading the last pass — and the issue's own rule for when the hold must
      // clear, alongside the sync that clears it anyway.
      final harness = crossClassSituationHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      final sara = _idOf(harness.controller, 'Sara Segers');

      await _select(tester, sam);
      await applyCard(tester, sam);
      expect(_row(sam), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('actions-sort-klas')));
      await tester.pumpAndSettle();
      expect(_row(sam), findsNothing);

      await _select(tester, sara);
      await applyCard(tester, sara);
      expect(_row(sara), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('actions-search')), 'Sara');
      await tester.pumpAndSettle();
      expect(_row(sara), findsNothing,
          reason: 'she matches the needle and has no work left, so only the '
              'hold was keeping her on screen');
    });

    testWidgets(
        'a bulk pass holds every account it settled, and reading one does not '
        'drop the rest', (WidgetTester tester) async {
      // The pass a rollover really runs: one decision over a set of accounts,
      // all of them settling at once. Opening the second of them must not
      // delete the first out from under the tap that opened it.
      //
      // The pass is started on the controller rather than from a button,
      // because since #311 no affordance on this screen starts a multi-account
      // pass over a decision #293 withholds — and every decision the offline
      // fakes really *settle* is one of those. (The Smartschool fake takes a
      // write without folding it back into its snapshot, so the sanctioned
      // class move of #296 leaves its accounts pending and never reaches the
      // state this test is about.) It is the whole-card seam for the same
      // reason: since #326 the per-decision one refuses what #293 withholds,
      // and each of these three cards carries the rename alone. What #299 pins
      // here is what the screen does once a pass has written several accounts,
      // whichever button began it; the cohort review's own path is covered in
      // the #296 group above.
      final harness = crossClassSituationHarness();
      await open(tester, harness);

      final sam = _idOf(harness.controller, 'Sam Sels');
      final sara = _idOf(harness.controller, 'Sara Segers');
      final tom = _idOf(harness.controller, 'Tom Tas');

      final cohort = ReconcileController.situationCohorts(<PendingAccountEntry>[
        for (final e in harness.controller.pendingEntries)
          if (e.family == 'student') e,
      ]).single;
      expect(cohort.key, 'student|ModifyAzureName');
      expect(cohort.length, 3, reason: 'one decision, three accounts');
      await harness.controller
          .applyEntries(cohort.decisions.map((d) => d.entry).toList());
      await tester.pumpAndSettle();

      expect(harness.controller.applyResults, hasLength(3));
      for (final String id in <String>[sam, sara, tom]) {
        await tester.ensureVisible(_row(id));
        expect(_row(id), findsOneWidget);
        expect(done(id), findsOneWidget);
      }

      await _select(tester, sara);
      expect(_row(sam), findsOneWidget);
      expect(_row(tom), findsOneWidget);

      // Her own verdict is on her card, though she raises nothing any more.
      expect(find.text('Geen openstaande beslissingen voor dit account.'),
          findsOneWidget);
      final Finder verdict =
          find.byKey(ValueKey('entry-outcomes-student-$sara'));
      await tester.ensureVisible(verdict);
      expect(
        find.descendant(
            of: verdict, matching: find.text('Wijzig de naam in Azure')),
        findsOneWidget,
      );
    });
  });

  testWidgets('cancelling the apply dialog writes nothing (#154)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    await _select(tester, id);
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuleer'));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(find.text('Resultaat van het toepassen'), findsNothing);
  });

  group('the apply-confirmation dialog says what the pass really writes (#234)',
      () {
    // The sentence used to be hard-coded — "This writes N change(s) to
    // Smartschool and Azure AD" — for every action, so a single Graph PATCH on
    // one display name announced a write to a system it never touches. These
    // pin the sentence itself; the widget/e2e cases below prove the screen
    // feeds it the right scope.
    ApplyScope scope(List<Origin> systems, {Set<Origin> chained = const {}}) =>
        ApplyScope(systems: systems, chained: chained);

    test('one Azure change names Office 365 only', () {
      expect(
        applyConfirmationMessage(scope(<Origin>[Origin.azure])),
        'Dit schrijft 1 wijziging naar Office 365. Doe eerst een dry-run om '
        'de exacte wijzigingen te bekijken.',
      );
    });

    test('a mixed selection names each system it really targets', () {
      expect(
        applyConfirmationMessage(
          scope(<Origin>[Origin.azure, Origin.smartschool, Origin.azure]),
        ),
        startsWith('Dit schrijft 3 wijzigingen naar Smartschool en Office '
            '365.'),
      );
    });

    test('the WISA opt-out family claims no write at all', () {
      // DontImportStaffFromWisa & co carry Origin.wisa on their ChangeSet, but
      // WISA is read-only here: what they produce is an import rule.
      final message = applyConfirmationMessage(scope(<Origin>[Origin.wisa]));
      expect(message, contains('bewaart 1 importregel'));
      expect(message, contains('er wordt niets naar WISA geschreven'));
      expect(message, isNot(contains('schrijft 1 wijziging naar WISA')));
    });

    test('the rule is announced as permanent and shared (#276)', () {
      // The rule is written to the shared settings document, so it outlives the
      // session and every other operator inherits it. A sentence that read like
      // a one-run decision would be the operator's only warning before an
      // irreversible-by-one-click change.
      expect(
        applyConfirmationMessage(scope(<Origin>[Origin.wisa])),
        contains('bewaart 1 importregel blijvend voor iedereen'),
      );
    });

    test('a rule beside a real write is counted apart from it', () {
      expect(
        applyConfirmationMessage(scope(<Origin>[Origin.azure, Origin.wisa])),
        startsWith('Dit schrijft 1 wijziging naar Office 365 en bewaart 1 '
            'importregel blijvend voor iedereen (er wordt niets naar WISA '
            'geschreven).'),
      );
    });

    test('a chained follow-up names its system, without inflating the count',
        () {
      // A new student's Office 365 create writes Smartschool too (#230/#240).
      // Whether it runs is decided by the follow-up's own evaluate after the
      // first write, so it is named rather than counted.
      final message = applyConfirmationMessage(
        scope(<Origin>[Origin.azure], chained: <Origin>{Origin.smartschool}),
      );
      expect(message, startsWith('Dit schrijft 1 wijziging naar Office 365.'));
      expect(message,
          contains('Een vervolgactie kan ook naar Smartschool schrijven.'));
    });

    test('nothing selected claims nothing', () {
      expect(
        applyConfirmationMessage(ApplyScope.empty),
        startsWith('Dit schrijft niets.'),
      );
    });
  });

  /// A student who is in all three systems and in sync except for their Azure
  /// `displayName` — the exact report in #234: one `ModifyAzureName`, a single
  /// Graph `PATCH`, and nothing whatsoever for Smartschool.
  ReconcileHarness nameDriftHarness() => ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(wisaId: '1', classGroup: '3C')],
          schools: [wisaSchool(1)],
          classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
        ),
        smartschool: ssSnap(
          groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
          accounts: [ssAccount()],
          memberships: [member('jane', '3C_ss')],
        ),
        // displayName left empty — the one thing that differs from WISA.
        azure: azSnap(users: [azUser()]),
      );

  testWidgets(
      'applying one Azure-only action announces Office 365, not "Smartschool '
      'and Azure AD" (#234)', (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = nameDriftHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final entry = _studentEntry(harness.controller);
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
      reason: 'the fixture raises exactly the action the bug report names',
    );

    final id = entry.targetId;
    await _select(tester, id);
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(find.text('Toepassen voor ${entry.target}?'), findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching:
            find.textContaining('Dit schrijft 1 wijziging naar Office 365.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('Smartschool')),
      findsNothing,
      reason: 'the pass never touches Smartschool',
    );
  });

  testWidgets(
      'a departed student is one row with a unregister/delete choice in the '
      'details pane; picking delete applies delete (#110/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = departedHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    expect(_row(id), findsOneWidget);
    // The class column names the bucket a leaver falls into.
    expect(find.descendant(of: _row(id), matching: find.text('Zonder klas')),
        findsOneWidget);

    await _select(tester, id);

    final unregisterAlt = ValueKey('alt-$id-UnregisterStudentFromSmartschool');
    final deleteAlt = ValueKey('alt-$id-DeleteStudentFromSmartschool');
    expect(find.byKey(unregisterAlt), findsOneWidget);
    expect(find.byKey(deleteAlt), findsOneWidget);
    // An unregister carries no field diff, so the detail under the radios is
    // the lifecycle note — in Dutch, like the rest of the screen (#253).
    expect(find.text('Levenscyclusactie — geen wijzigingen per veld.'),
        findsOneWidget);

    await tester.tap(find.byKey(deleteAlt));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty,
        reason: 'delete is a real Smartschool write');
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Verwijder dit account uit Smartschool'));
    expect(summaries, isNot(contains('Schrijf de leerling uit in Smartschool')),
        reason: 'only the chosen alternative runs — never both');
  });

  testWidgets(
      'the flat list virtualizes: only a bounded number of rows build, and '
      'scrolling builds/unloads them (#111/#295)', (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = departedHarness(count: 2000);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // All 2000 are in one school-wide list — the thing the drill-down existed
    // to avoid rendering, and which a lazy builder renders fine.
    expect(harness.controller.pendingEntries, hasLength(2000));

    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('account-row-'),
    );
    List<String> built() => <String>[
          for (final e in rows.evaluate())
            (e.widget.key! as ValueKey<String>).value,
        ];

    final List<String> initial = built();
    expect(initial, isNotEmpty);
    expect(initial, hasLength(lessThan(200)),
        reason: 'virtualized: on-screen rows only, not all 2000');

    // Scrolling builds rows that were not there and unloads the ones that
    // scrolled far off-screen.
    await tester.drag(
      find.byKey(const ValueKey('actions-list')),
      const Offset(0, -20000),
    );
    await tester.pumpAndSettle();

    final List<String> after = built();
    expect(after, isNotEmpty);
    expect(after, hasLength(lessThan(200)));
    expect(after.toSet().intersection(initial.toSet()), isEmpty,
        reason: 'a different window of the list is built now');
    expect(find.byKey(ValueKey(initial.first)), findsNothing,
        reason: 'the first row unloaded once scrolled far off-screen');
  });

  // --- Personeel / Leerlingen family tabs (#179) ---------------------------

  testWidgets(
      'the Actions view splits staff and student accounts into Personeel and '
      'Leerlingen tabs, each listing only its own family (#179/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // One student (default fixture) plus one WISA staff member, so both
    // families carry a row.
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('actions-tab-leerlingen')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-tab-personeel')), findsOneWidget);

    // The counts are partitioned by family, and together they sum the total —
    // nothing dropped or double-counted.
    expect(harness.controller.staffPendingCount, greaterThan(0));
    expect(harness.controller.studentPendingCount, greaterThan(0));
    expect(
      harness.controller.staffPendingCount +
          harness.controller.studentPendingCount,
      harness.controller.totalPendingCount,
    );

    final student = _idOf(harness.controller, 'Jane Doe');
    final staff = _idOf(harness.controller, 'Anna Smit');

    // Default tab = Leerlingen.
    expect(_row(student), findsOneWidget);
    expect(_row(staff), findsNothing);

    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(_row(staff), findsOneWidget);
    expect(_row(student), findsNothing);
    // A staff member's "class" is the synthetic Personeel bucket.
    expect(find.descendant(of: _row(staff), matching: find.text('Personeel')),
        findsOneWidget);
  });

  testWidgets(
      'switching family tabs drops the selection, so each tab opens on its own '
      'list (#179/#295)', (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final student = _idOf(harness.controller, 'Jane Doe');
    await _select(tester, student);
    expect(find.byKey(ValueKey('actions-detail-$student')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('actions-detail-$student')), findsNothing,
        reason: 'a selection belongs to the list it was made in');
    expect(find.byKey(const ValueKey('actions-detail-empty')), findsOneWidget);
  });

  // --- The work-list filter and the name search (#187/#217/#226) -----------

  testWidgets(
      'the work-list filter is on by default, set in exactly one place, and '
      'gives the whole school back when switched off (#226/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Sam carries the one applyable student action; Tom is in order everywhere.
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(toggle, findsOneWidget,
        reason: 'the filter is not settable in two places');
    expect(tester.widget<Switch>(toggle).value, isTrue);

    final sam = _idOf(harness.controller, 'Sam Sels');
    final tom = _idOf(harness.controller, 'Tom Tas');
    expect(_row(sam), findsOneWidget);
    expect(_row(tom), findsNothing);

    // Switched off, the list is the whole school — which the drill-down could
    // never show, because a rollup only knew the accounts that raised
    // something.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(_row(sam), findsOneWidget);
    expect(_row(tom), findsOneWidget);
    expect(_cellState(tester, tom, Origin.wisa), SystemIndicatorState.inOrder);
    expect(_cellState(tester, tom, Origin.smartschool),
        SystemIndicatorState.inOrder);
    expect(_cellState(tester, tom, Origin.azure), SystemIndicatorState.inOrder);
  });

  testWidgets(
      'the name search matches any part of the name in any order and combines '
      'with the work-list filter (#187/#217/#226/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Three staff in the Personeel family: two share the surname "Smit" (one
    // with an action, one without) and one has a distinct voornaam.
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [
        wisaStaff(
            code: 'SMIT', wisaId: '42', firstName: 'Anna', lastName: 'Smit'),
        wisaStaff(
            code: 'JANS', wisaId: '43', firstName: 'Bram', lastName: 'Jansen'),
        wisaStaff(
            code: 'CSMI', wisaId: '44', firstName: 'Clara', lastName: 'Smit'),
      ]),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    final anna = _idOf(harness.controller, 'Anna Smit');
    final bram = _idOf(harness.controller, 'Bram Jansen');
    final clara = _idOf(harness.controller, 'Clara Smit');

    // The search box is on the list itself now, on both tabs — it used to live
    // inside an opened Personeel classroom (#187).
    final search = find.byKey(const ValueKey('actions-search'));
    expect(search, findsOneWidget);
    expect(_row(anna), findsOneWidget);
    expect(_row(bram), findsOneWidget);
    expect(_row(clara), findsOneWidget);

    // Search on the naam "Smit": both Smits match, Jansen drops.
    await tester.enterText(search, 'smit');
    await tester.pumpAndSettle();
    expect(_row(anna), findsOneWidget);
    expect(_row(clara), findsOneWidget);
    expect(_row(bram), findsNothing);

    // Search on the voornaam "Bram": only Jansen matches.
    await tester.enterText(search, 'bram');
    await tester.pumpAndSettle();
    expect(_row(bram), findsOneWidget);
    expect(_row(anna), findsNothing);

    // Both halves, in the stored order and reversed (#217): either way round
    // finds the one person. Reversed used to return nothing, because the needle
    // was matched as one contiguous substring of "Voornaam Naam".
    await tester.enterText(search, 'anna smit');
    await tester.pumpAndSettle();
    expect(_row(anna), findsOneWidget);
    expect(_row(clara), findsNothing);
    await tester.enterText(search, 'smit anna');
    await tester.pumpAndSettle();
    expect(_row(anna), findsOneWidget);
    expect(_row(clara), findsNothing);
    expect(_row(bram), findsNothing);

    // Every part must occur: parts taken from two different people match
    // neither, rather than matching both.
    await tester.enterText(search, 'anna jansen');
    await tester.pumpAndSettle();
    expect(
        find.text('Geen accounts die aan de filter voldoen.'), findsOneWidget);

    // The search survives a family tab change: the box stays on screen, so
    // clearing it under the operator would read as a bug.
    await tester.enterText(search, 'smit');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(search).controller!.text,
      'smit',
    );
  });

  testWidgets(
      'a school with nothing pending says so, rather than reading as an empty '
      'overview (#226/#295)', (WidgetTester tester) async {
    _useWideWindow(tester);
    // Tom alone: fully in sync in all three systems.
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(
              wisaId: '4', classGroup: '3D', firstName: 'Tom', name: 'Tas'),
        ],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('3D', adminCode: 'a4', schoolCode: '111')],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3D', code: '3D_ss', untis: '3D')],
        accounts: [
          ssAccount(
            uid: 'tom',
            accountId: '4',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        memberships: [member('tom', '3D_ss')],
      ),
      azure: azSnap(users: [
        azUser(
          id: 'az4',
          upn: 'tom.tas@student.school.example',
          employeeId: '4',
          displayName: 'Tom Tas',
          // His profile names the class WISA holds him in, so nothing is owed
          // there either (#359) — this school really is done.
          department: '3D',
        ),
      ]),
      ourSchoolIds: const {1},
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Geen openstaande acties — alles staat in orde.'),
        findsOneWidget);

    // Switched off, the account is right there with three green cells.
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    final tom = _idOf(harness.controller, 'Tom Tas');
    expect(_row(tom), findsOneWidget);
  });

  testWidgets(
      'the filter switch survives a Leerlingen ↔ Personeel tab change '
      '(#226)', (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse,
        reason: 'the mode outlives the tab it was set on');

    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });

  testWidgets(
      'an informational candidate colours no cell and puts no row in the work '
      'list, but is still readable in the details pane (#245/#255/#298)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Sam sits in the wrong Office 365 class group. The write belongs to the
    // class row on Klasgroepen — one `SyncAzureClassGroupMembers` per class
    // rather than one per student — so here it only diagnoses.
    final harness = azureClassMembershipHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final sam = _idOf(harness.controller, 'Sam Sels');
    final entry =
        harness.controller.pendingEntries.firstWhere((e) => e.targetId == sam);
    expect(entry.canApply, isFalse,
        reason: 'the fixture raises the informational candidate and no other');

    // Not in the work list: it is not work this screen can do.
    expect(_row(sam), findsNothing);

    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    expect(_row(sam), findsOneWidget);
    // Nothing is coloured by it — the rollover must not paint ~3000 rows orange
    // for work that happens somewhere else.
    expect(_cellState(tester, sam, Origin.azure), SystemIndicatorState.inOrder);

    // …and it is still readable in the details pane as context, named by the
    // system it concerns — with both apply affordances dead, because there is
    // nothing here for this screen to write.
    await _select(tester, sam);
    expect(find.text(entry.choices.single.selected.changes.summary),
        findsOneWidget);
    expect(find.text('Office 365 ·'), findsWidgets);
    expect(_cellState(tester, sam, Origin.azure), SystemIndicatorState.inOrder,
        reason: 'the row keeps its reading while the pane is open');
    expect(
      tester
          .widget<FilledButton>(find.byKey(ValueKey('entry-apply-$sam')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(ValueKey('entry-dry-run-$sam')))
          .onPressed,
      isNull,
    );
  });

  // --- The second group school a student is enrolled in (#334) -------------

  testWidgets(
      'a dual-enrolled student\'s card states the other school and its class, '
      'and a single-school card is untouched (#334)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Lies is in both group schools; Nele is in ours alone. Neither has any
    // work, so the line is the only difference between the two cards.
    final harness = dualEnrolmentDisplayHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();

    final lies = _idOf(harness.controller, 'Lies Vermeulen');
    final nele = _idOf(harness.controller, 'Nele Peeters');

    await _select(tester, lies);
    // The school is named as the WISA school list names it — long name and
    // short code — never invented from the id (#204/#208).
    expect(
      find.text('Ook ingeschreven in Instituut Sancta Maria-B (ISMAB), '
          'klas 3HWa'),
      findsOneWidget,
    );
    // Beside the class facts of the card, which stay our school's (INV-25).
    expect(
      find.descendant(
        of: find.byKey(ValueKey('actions-detail-$lies')),
        matching: find.text('3MWW1'),
      ),
      findsOneWidget,
    );

    await _select(tester, nele);
    expect(
        find.byKey(ValueKey('account-other-enrolment-$nele-0')), findsNothing,
        reason: 'one school, so there is nothing to say');
    expect(find.textContaining('Ook ingeschreven'), findsNothing);
  });

  // --- The Azure department schools of a staff record (#352) ---------------

  testWidgets(
      'a staff card names the schools its Azure department lists, under the '
      'Office 365 cell of the details pane alone (#352)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Anna is fully in step in all three systems; her `department` names our
    // school second, beside a sibling group school — the ordinary state, and the
    // whole discriminator between releasing her Office 365 account and deleting
    // it. Bram has no Office 365 account at all; Jane is a student, whose school
    // is `companyName` and not a list (INV-22).
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [
        wisaStudent()
      ], staff: [
        wisaStaff(),
        wisaStaff(
            code: 'JANS', wisaId: '43', firstName: 'Bram', lastName: 'Jansen'),
      ]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount(), ssStaffAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser(), azStaffUser(department: 'SSM,GBS')]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    final anna = _idOf(harness.controller, 'Anna Smit');
    final bram = _idOf(harness.controller, 'Bram Jansen');

    await _select(tester, anna);
    // The field's own content: its order, its casing, our own prefix included —
    // "ours alone" is what makes a deletion safe, so it is the reading the
    // operator most needs, and the release/delete split is the only thing
    // entitled to filter our prefix out.
    const String line = 'Scholen: SSM, GBS';
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-detail-cell-$anna-azure')),
        matching: find.text(line),
      ),
      findsOneWidget,
    );
    // Under Office 365 and nowhere else: not WISA, not Smartschool.
    expect(find.text(line), findsOneWidget);
    // And not on the collapsed row — on a Personeel list an extra line under
    // every card's third cell is noise, so the two sets of cells differ here.
    expect(
      find.descendant(
        of: _cell(anna, Origin.azure),
        matching: find.textContaining('Scholen'),
      ),
      findsNothing,
    );

    // No Office 365 account, so there is no field to quote.
    await _select(tester, bram);
    expect(find.textContaining('Scholen'), findsNothing);

    // A student is untouched: one exact `companyName`, no list to print.
    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    await _select(tester, _idOf(harness.controller, 'Jane Doe'));
    expect(find.textContaining('Scholen'), findsNothing);
  });

  // --- The list / detail split on a narrow window (#295) -------------------

  testWidgets(
      'on a narrow window the details replace the list, and Overzicht comes '
      'back (#295)', (WidgetTester tester) async {
    _useNarrowWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    // One pane: the list, and no empty details pane taking half of it.
    expect(_row(id), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-detail-empty')), findsNothing);
    expect(find.byKey(const ValueKey('actions-detail-back')), findsNothing);

    await _select(tester, id);

    // The details took the whole width; the list stood down.
    expect(find.byKey(ValueKey('actions-detail-$id')), findsOneWidget);
    expect(_row(id), findsNothing);
    final back = find.byKey(const ValueKey('actions-detail-back'));
    expect(back, findsOneWidget);

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(_row(id), findsOneWidget);
    expect(find.byKey(ValueKey('actions-detail-$id')), findsNothing);
  });

  testWidgets('a wide window shows both panes at once, with no back button',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    await _select(tester, id);

    expect(_row(id), findsOneWidget, reason: 'the list stays put beside it');
    expect(find.byKey(ValueKey('actions-detail-$id')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-detail-back')), findsNothing);
  });

  // --- Address diff in the details pane (#153) -----------------------------

  const wisaAddr = Address(
    street: 'Koophandelstraat',
    houseNumber: '32',
    postalCode: '3270',
    city: 'Scherpenheuvel',
    country: 'BE',
  );
  Address ssAddr({String postalCode = '3270'}) => Address(
        street: 'Koophandelstraat',
        houseNumber: '32',
        houseNumberAdd: '',
        postalCode: postalCode,
        city: 'Scherpenheuvel',
        country: 'België',
      );
  ReconcileHarness addressHarness(
          {required Address ss, required Address wisa}) =>
      ReconcileHarness(
        wisa: wisaSnap(students: [wisaStudent(address: wisa)]),
        smartschool: ssSnap(
          groups: [ssGroup('3C', code: '3C_ss')],
          accounts: [ssAccount(address: ss)],
          memberships: [member('jane', '3C_ss')],
        ),
      );

  testWidgets(
      'a real postalCode drift raises the address action and the details pane '
      'shows only the differing field (#153/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = addressHarness(ss: ssAddr(), wisa: wisaAddr);
    harness.wisaResult = wisaSnap(students: [
      wisaStudent(
        address: const Address(
          street: 'Koophandelstraat',
          houseNumber: '32',
          postalCode: '3271',
          city: 'Scherpenheuvel',
          country: 'BE',
        ),
      ),
    ]);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = _studentEntry(harness.controller).targetId;
    await _select(tester, id);

    expect(find.text('Wijzig het adres in Smartschool'), findsOneWidget);
    expect(find.textContaining('postalCode: 3270 → 3271'), findsOneWidget);
    expect(find.textContaining('street:'), findsNothing);
    expect(find.textContaining('city:'), findsNothing);
  });

  // --- Where the session's view came from ----------------------------------

  testWidgets(
      'a seeded session adopts the shared state and lists the whole school '
      'with no classroom read at all (#115/#287/#295)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    // Since #287 the cold seed is linked on open, so this session can act — and
    // it got there without asking any of the three systems for anything.
    expect(s2.controller.linked, isNotNull);
    expect(s2.controller.adoptedFrom?.syncedBy, 'operator@school.example');
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);

    // The list is right there, school-wide, with no class to open first.
    final id = _studentEntry(s2.controller).targetId;
    expect(_row(id), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsOneWidget);
  });

  testWidgets(
      'a session that adopted the shared state says whose sync it is working '
      'from, and its rows are the interactive ones (#287)',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    // Operator A syncs; operator B opens Acties five minutes later and never
    // presses Synchroniseer. Before #287 that second session got the
    // "nog niet gesynchroniseerd" read-only notice and static cards, after
    // minutes of WISA/Smartschool/Azure traffic were the only way out of it.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions-read-only')), findsNothing);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsOneWidget);
    expect(find.text('Gedeelde synchronisatie'), findsOneWidget);
    expect(find.textContaining('operator@school.example'), findsWidgets);
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    // Both passes stay within reach for an operator who wants something
    // fresher; taking one makes the view this session's own.
    final sync = find.byKey(const ValueKey('actions-shared-state-sync'));
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('actions-shared-state-drift')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();

    expect(s2.wisaSyncs, 1);
    expect(s2.controller.adoptedFrom, isNull);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsNothing);
  });

  // --- The one blocking notice a refused session gets (#214/#287/#295) -----

  final readOnly = find.byKey(const ValueKey('actions-read-only'));
  final readOnlySync = find.byKey(const ValueKey('actions-read-only-sync'));

  testWidgets(
      'a session that cannot seed shows one blocking notice and no list at '
      'all (#214/#287/#295)', (WidgetTester tester) async {
    _useWideWindow(tester);
    // A session with stored documents to read but no snapshots to link from:
    // nothing here can be chosen, dry-run or applied.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(harness.controller.linked, isNull);
    expect(readOnly, findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    // Since #287 the notice names *why* there is nothing to act on rather than
    // reporting the absence of a sync: this session holds no seeded snapshot to
    // build a view from, which is a thing only a pull can fix.
    expect(
      find.textContaining('Geen opgeslagen momentopname voor WISA, '
          'Smartschool en Azure AD'),
      findsOneWidget,
    );
    // …with the sync affordance right there, and live.
    expect(tester.widget<FilledButton>(readOnlySync).onPressed, isNotNull);

    // One notice, not a second way to browse (#295): the read-only account
    // cards of #214 are gone with the drill-down they hung under.
    expect(find.byKey(const ValueKey('actions-list')), findsNothing);
    expect(find.text('Jane Doe'), findsNothing);
    expect(
        find.byKey(const ValueKey('actions-only-with-actions')), findsNothing);
    expect(find.byKey(const ValueKey('actions-search')), findsNothing);
  });

  testWidgets(
      'a session whose sync failed is told the sync failed, not that it never '
      'ran (#214)', (WidgetTester tester) async {
    _useWideWindow(tester);
    // The second reproduction path of #214: the pass died before it could link
    // (the Azure delta-token failure of #213 was one such), so this session has
    // an error *and* no linked view. `_fail` leaves any previously linked view
    // untouched, so this wording is only ever reached when there was none.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store)
      ..wisaError = StateError('WISA host unreachable');
    await harness.controller.sync();
    expect(harness.controller.error, contains('WISA host unreachable'));
    expect(harness.controller.linked, isNull);

    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(readOnly, findsOneWidget);
    expect(find.textContaining('De laatste sync is mislukt'), findsOneWidget);
    expect(find.textContaining('nog niet gesynchroniseerd'), findsNothing);
  });

  testWidgets(
      "the read-only banner's sync is disabled and named when another operator "
      'holds the lease (#214/#108)', (WidgetTester tester) async {
    _useWideWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

    // Deliberately *not* a seeded session: since #287 one of those adopts the
    // shared state and gets the interactive list plus [SharedStateNotice]
    // instead. This is the session with nothing to build a view from, which is
    // the one the read-only banner is for.
    final s2 = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(readOnly, findsOneWidget);
    expect(tester.widget<FilledButton>(readOnlySync).onPressed, isNull);
    expect(find.textContaining('mieke@school'), findsOneWidget,
        reason: 'a dead button needs its reason on screen too');
  });

  // --- The freshness stamp -------------------------------------------------
  //
  // It used to sit above this list too. #309 took it off Acties — it is a
  // property of the shared state, not of this account list — so the four tests
  // that pinned its wording (#108/#192/#247) moved with it, to
  // `class_groups_screen_test.dart`, where the stamp still renders. What Acties
  // owes the removal is the assertion that it is gone, which is in the header
  // test above.

  testWidgets('the header carries no freshness stamp at all (#309)',
      (WidgetTester tester) async {
    // The worst case for the removal: a shared view stamped with everything the
    // line could have said — a generation, an operator, a werkdatum. None of it
    // reaches this screen.
    final store = await seededLinkedStore(
      <MaterializedAccount>[
        matAccount(id: 's1', label: 'Jane Doe', withAction: true),
      ],
      systemSyncs: <Origin, SystemSyncMeta>{
        Origin.wisa: SystemSyncMeta(
          syncedBy: 'operator@school.example',
          at: kFixtureDate,
          workDate: DateTime(2025, 9, 1),
        ),
      },
    );
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Generatie'), findsNothing);
    expect(find.textContaining('werkdatum'), findsNothing);
    expect(find.textContaining('operator@school.example'), findsNothing);
  });

  group('a pass runs behind a modal progress dialog (#243)', () {
    // A pass over an account's decisions is sequential, one connector
    // round-trip at a time. Its only feedback used to be greyed-out buttons
    // plus an indeterminate bar in a page header the operator had long scrolled
    // past — so a running pass was indistinguishable from a hung app, and
    // nothing named the action being written.
    //
    // The multi-*account* form of the pass lives on Klasgroepen's cohort header
    // since #295 took bulk apply off this screen; here a two-step pass is one
    // account's two decisions, which is what an entry apply runs.

    /// The text of one line of the progress dialog.
    String line(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    final Finder dialog = find.byKey(const ValueKey('actions-progress-dialog'));

    testWidgets(
        'an apply holds the operator in a non-dismissible dialog that names '
        'each action as it goes, and closes itself when the pass ends',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      // One fresh gate per action, so the pass can be walked step by step and
      // the text observed on each — the bug is precisely that nobody could see
      // what was being written.
      final gates = <Completer<void>>[];
      final harness = ReconcileHarness(applyGate: () async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      });
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      final entry = _studentEntry(harness.controller);
      final id = entry.targetId;
      final steps = <String>[
        for (final c in entry.choices)
          '${entry.target} — ${c.selected.changes.summary}',
      ];
      expect(steps, hasLength(2), reason: 'Jane raises two decisions');

      // Idle: no dialog.
      expect(dialog, findsNothing);

      await _select(tester, id);
      await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
      await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      // Parked on the first action: the dialog is up, headed as an apply, and
      // says how far along it is and on what.
      expect(dialog, findsOneWidget);
      expect(gates, hasLength(1));
      expect(find.text('Acties toepassen…'), findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 2');
      expect(line(tester, 'actions-progress-step'), steps[0]);

      // Determinate, and it is a real bar — the motionless indeterminate sweep
      // is exactly what this replaces (#176).
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('actions-progress-bar')),
      );
      expect(bar.value, 0.0);

      // Modal: tapping the barrier does not get rid of it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);

      // The second action: the text follows the pass.
      gates[0].complete();
      await tester.pumpAndSettle();
      expect(gates, hasLength(2));
      expect(dialog, findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 2 van 2');
      expect(line(tester, 'actions-progress-step'), steps[1]);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('actions-progress-bar')),
            )
            .value,
        0.5,
      );

      // The pass ends: the dialog closes by itself, leaving the results.
      gates[1].complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Resultaat van het toepassen'), findsOneWidget);
      expect(harness.controller.applyResults, hasLength(2));
    });

    testWidgets(
        'a dry-run gets the same dialog — just as slow, and it used to be just '
        'as silent', (WidgetTester tester) async {
      _useWideWindow(tester);
      final gate = Completer<void>();
      final harness = ReconcileHarness(applyGate: () => gate.future);
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      final id = _studentEntry(harness.controller).targetId;
      await _select(tester, id);

      // A dry-run needs no confirmation, so it goes straight into the pass.
      await tester.ensureVisible(find.byKey(ValueKey('entry-dry-run-$id')));
      await tester.tap(find.byKey(ValueKey('entry-dry-run-$id')));
      await tester.pumpAndSettle();

      expect(dialog, findsOneWidget);
      expect(find.text('Dry-run bezig…'), findsOneWidget);
      expect(find.text('Er wordt niets geschreven.'), findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 2');

      gate.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Resultaat van de dry-run'), findsOneWidget);
      expect(harness.soap.soapActions, isEmpty);
    });

    testWidgets('a pass whose writes fail still clears the dialog',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      // The worst case for a modal: the pass blows up. Leaving the dialog up
      // would lock the operator out of the app entirely, so its lifetime is
      // bound to the pass's future, not to anything observed about the results.
      final gate = Completer<void>();
      final harness = ReconcileHarness(applyGate: () async {
        await gate.future;
        throw StateError('Smartschool weigerde de schrijfactie');
      });
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      final id = _studentEntry(harness.controller).targetId;
      await _select(tester, id);
      await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
      await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(dialog, findsNothing,
          reason: 'a failed pass must not trap anyone');
      expect(find.text('Resultaat van het toepassen'), findsOneWidget);
      expect(
        harness.controller.applyResults!.map((r) => r.outcome),
        everyElement(ActionOutcome.failed),
      );
      expect(
        find.textContaining('Smartschool weigerde de schrijfactie'),
        findsWidgets,
      );
    });
  });

  // --- No pointer at Klasgroepen any more (#301 → #309) ---------------------

  testWidgets(
      'the header never points at Klasgroepen, however much that tab is '
      'holding (#309)', (WidgetTester tester) async {
    // #301 put the pointer on both action tabs so each said what the other was
    // holding. The Acties half is gone: what Klasgroepen is holding is stated
    // on Klasgroepen, where the mirror line — how many accounts Acties is
    // holding — stays (see `class_groups_screen_test.dart`). The asymmetry is
    // deliberate: that tab has the room, this one is a list of thousands.
    //
    // The fixture is the case that used to render the line: `3C` and `3D` are
    // both missing their Office 365 group, which is work only the other tab can
    // do.
    _useWideWindow(tester);
    final harness = appliedClassWorkHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // With nothing left on this screen reading the class inventory, it no
    // longer schedules the partition read that only ever fed the pointer.
    expect(harness.controller.groupDocs, isNull);
    expect(find.byKey(const ValueKey('actions-class-attention')), findsNothing);

    // …and once the inventory *is* loaded — the operator visited Klasgroepen,
    // which reads it through the same controller — the count is there to be
    // rendered and this screen still renders none of it.
    await harness.controller.loadGroups();
    await tester.pumpAndSettle();

    expect(harness.controller.classesNeedingAttention, 2);
    expect(find.byKey(const ValueKey('actions-class-attention')), findsNothing);
    expect(find.textContaining('aandacht op Klasgroepen'), findsNothing);
  });
}
