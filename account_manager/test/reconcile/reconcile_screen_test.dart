import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ReconcileScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-sync')), findsNothing);
  });

  testWidgets('a failed bootstrap shows the error with a working retry',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    var attempts = 0;
    await tester.pumpWidget(_wrap(ReconcileScreen(
      bootstrap: () async {
        attempts++;
        if (attempts == 1) {
          throw const ReconcileConfigException(
            'The WISA password (secret "wisa.password") is not set in the '
            'Key Vault.',
          );
        }
        return harness.services;
      },
    )));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not prepare the reconcile screen'),
      findsOneWidget,
    );
    expect(find.textContaining('wisa.password'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reconcile-bootstrap-retry')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const ValueKey('reconcile-sync')), findsOneWidget);
  });

  testWidgets('a retry that fails again visibly reports the new attempt',
      (WidgetTester tester) async {
    // A fast repeat failure re-renders an identical panel, which reads as a
    // dead button — the attempt note is the feedback that the retry ran.
    await tester.pumpWidget(_wrap(ReconcileScreen(
      bootstrap: () async =>
          throw const ReconcileConfigException('driver missing'),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('(Attempt'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-bootstrap-retry')));
    await tester.pumpAndSettle();

    expect(find.textContaining('(Attempt 2 failed.)'), findsOneWidget);
  });

  testWidgets(
      'sync → overview → pending actions → dry-run → apply → unchanged banner',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // Idle: the explainer is shown, no overview yet.
    expect(find.text('Linked overview'), findsNothing);

    // 1. Sync: all three systems pull, the linked overview and pending
    //    actions render.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.text('Linked overview'), findsOneWidget);
    expect(find.text('WISA'), findsOneWidget);
    expect(find.text('SMARTSCHOOL'), findsOneWidget); // PlinkBadge uppercases
    expect(find.textContaining('Pending actions'), findsOneWidget);
    expect(find.text('Jane Doe'), findsWidgets);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // The log panel carries the sync trail (its list virtualizes, so the
    // older entries sit past the viewport — hence skipOffstage: false).
    expect(
      find.textContaining('Syncing WISA', skipOffstage: false),
      findsOneWidget,
    );

    // 2. Dry-run: results section appears, nothing written.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-dry-run')));
    await tester.tap(find.byKey(const ValueKey('reconcile-dry-run')));
    await tester.pumpAndSettle();

    expect(find.text('Dry-run result'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // 3. Apply: confirmation dialog, then the write happens.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-apply')));
    await tester.tap(find.byKey(const ValueKey('reconcile-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Apply pending actions?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);

    // 4. A second sync with unchanged WISA: the no-changes banner. The view
    //    is scrolled down after the apply, so bring the button back first.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.textContaining('no account changes needed'), findsWidgets);
  });

  testWidgets('cancelling the apply dialog writes nothing',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-apply')));
    await tester.tap(find.byKey(const ValueKey('reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(find.text('Apply result'), findsNothing);
  });

  testWidgets(
      'a lease held by another operator disables sync/drift and names them '
      '(#108)', (WidgetTester tester) async {
    final linkedStore = InMemoryLinkedStore();
    // A different operator is mid-sync when this session opens.
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
    final harness = ReconcileHarness(linkedStore: linkedStore);

    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // The lock indicator names the holder…
    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsOneWidget);
    expect(find.textContaining('mieke@school'), findsOneWidget);

    // …and both heavy actions are disabled.
    final sync = tester.widget<FilledButton>(
      find.byKey(const ValueKey('reconcile-sync')),
    );
    final drift = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('reconcile-drift')),
    );
    expect(sync.onPressed, isNull);
    expect(drift.onPressed, isNull);
  });

  testWidgets('the header shows the shared per-system freshness (#108)',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Who/when synced each system, read from the shared store.
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(
      find.textContaining('by operator@school.example'),
      findsOneWidget,
    );
  });

  testWidgets(
      "a generation bump refetches the passive session's overview "
      '(#108)', (WidgetTester tester) async {
    final linkedStore = InMemoryLinkedStore();
    final snapshots = InMemorySnapshotStore();

    // Session 1 materializes generation 1.
    final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
    await s1.controller.sync();

    // Session 2 renders the shared overview passively.
    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ReconcileScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Generatie 1'), findsOneWidget);

    // Session 1 re-syncs a change → generation 2. The realtime layer (#116)
    // will call onStoreChanged on the bump; here we drive it directly.
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

  testWidgets('the log panel clears on demand', (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Syncing WISA', skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('No messages yet.'), findsOneWidget);
  });
}
