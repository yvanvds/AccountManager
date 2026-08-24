import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

/// #349 — the "medewerker uit dienst" affordance on the Personeel details pane.
///
/// The command is deliberately absent from the pending list, so the *only* way
/// an operator can reach it is this block. These tests are what prove it is
/// reachable at all, that it is reachable for nobody it should not be, and that
/// one press really performs the retirement end to end through the real screen.
Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void _useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A teacher the school still employs on paper: present and in step in all
/// three systems, so she raises no decision and her row only appears once the
/// "alleen met acties" filter is off.
ReconcileHarness employedHarness({String department = 'GBS'}) =>
    ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssStaffAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azStaffUser(department: department)]),
    );

/// Opens Acties over [harness], switches to Personeel, drops the
/// "alleen met acties" filter and selects the one staff row.
Future<String> _openTheTeacher(
  WidgetTester tester,
  ReconcileHarness harness,
) async {
  await harness.controller.sync();
  await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
  await tester.pumpAndSettle();
  // She has no pending work at all — that is the whole situation — so the
  // default filter hides her.
  await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
  await tester.pumpAndSettle();

  final id = harness.controller.linked!.snapshot.staff.single.id.value;
  await tester.ensureVisible(find.byKey(ValueKey('account-row-$id')));
  await tester.tap(find.byKey(ValueKey('account-row-$id')));
  await tester.pumpAndSettle();
  return id;
}

void main() {
  testWidgets('a teacher WISA still reports as employed can be retired',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = employedHarness();

    final id = await _openTheTeacher(tester, harness);

    // Nothing is pending for her, and yet the command is there — which is the
    // entire point of #349.
    expect(find.text('Geen openstaande beslissingen voor dit account.'),
        findsOneWidget);
    expect(find.byKey(ValueKey('actions-retire-$id')), findsOneWidget);
    expect(find.text('Medewerker uit dienst'), findsOneWidget);
  });

  testWidgets('the block warns what it is for before anything is pressed',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = employedHarness();

    await _openTheTeacher(tester, harness);

    expect(find.text('Uit dienst'), findsOneWidget);
    expect(
      find.textContaining('WISA meldt dit personeelslid nog als in dienst'),
      findsOneWidget,
    );
  });

  testWidgets('a student is never offered it', (WidgetTester tester) async {
    // The command is staff-only: a student's departure is an ordinary decision
    // on their card, and WISA closes their enrolment properly.
    _useWideWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final id = harness.controller.linked!.snapshot.accounts.single.id.value;
    await tester.ensureVisible(find.byKey(ValueKey('account-row-$id')));
    await tester.tap(find.byKey(ValueKey('account-row-$id')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('actions-retire-$id')), findsNothing);
    expect(find.text('Medewerker uit dienst'), findsNothing);
  });

  testWidgets('cancelling the confirmation writes nothing',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = employedHarness();
    final id = await _openTheTeacher(tester, harness);

    await tester.tap(find.byKey(ValueKey('actions-retire-apply-$id')));
    await tester.pumpAndSettle();
    // The confirmation names the person, which is the safety property the whole
    // one-record design rests on: nobody confirms a retirement without reading
    // whose it is.
    final label = harness.controller.linkedAccounts
        .firstWhere((a) => a.id.value == id)
        .label;
    expect(find.text('$label uit dienst?'), findsOneWidget);

    await tester.tap(find.text('Annuleer'));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(harness.graph.requests, isEmpty);
    expect(harness.controller.linked!.snapshot.staff, hasLength(1));
  });

  testWidgets('confirming retires her across all three systems',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = employedHarness();
    final id = await _openTheTeacher(tester, harness);

    await tester.tap(find.byKey(ValueKey('actions-retire-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(
      harness.soap.soapActions.any((a) => a.contains('setAccountStatus')),
      isTrue,
    );
    expect(harness.graph.requests.any((r) => r.method == 'DELETE'), isTrue);
    // She is gone from the view, and the block that retired her with her.
    expect(harness.controller.linked!.snapshot.staff, isEmpty);
    expect(find.byKey(ValueKey('actions-retire-$id')), findsNothing);
  });

  testWidgets('the dry-run beside it performs no write',
      (WidgetTester tester) async {
    _useWideWindow(tester);
    final harness = employedHarness();
    final id = await _openTheTeacher(tester, harness);

    await tester.tap(find.byKey(ValueKey('actions-retire-dry-run-$id')));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(harness.graph.requests, isEmpty);
    expect(harness.controller.linked!.snapshot.staff, hasLength(1));
    // Still on screen: a dry run settles nothing, so the command stays offered.
    expect(find.byKey(ValueKey('actions-retire-$id')), findsOneWidget);
  });
}
