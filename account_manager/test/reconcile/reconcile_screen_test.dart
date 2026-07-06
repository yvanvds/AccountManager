import 'dart:async';

import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Gives the reconcile screen a tall viewport so the below-the-fold sections
/// (overview, duplicate warnings) are laid out without scrolling. The body is a
/// lazy [CustomScrollView], so a tall window keeps these presence-only
/// assertions honest. Width is left at the default 800.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

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
      'sync renders the category overview and keeps the pending actions off '
      'Reconcile; an unchanged re-sync shows the no-changes banner (#154/#163)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // Idle: the explainer is shown, no overview yet.
    expect(find.text('Overview'), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The per-category overview renders on Reconcile from the rollups (#163):
    // students / staff / class-groups, each with a pending indicator.
    expect(find.text('Overview'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-category-staff')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-groups')),
        findsOneWidget);
    expect(find.text('LEERLINGEN'), findsOneWidget); // PlinkBadge uppercases
    // The one fixture student's applyable actions surface as a pending indicator.
    expect(find.text('2 openstaande acties'), findsOneWidget);

    // …but the pending actions moved to the Actions tab: neither the title, the
    // global apply, nor any entry tile is on the Reconcile screen (#154).
    expect(find.textContaining('Pending actions'), findsNothing);
    expect(find.byKey(const ValueKey('actions-apply')), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-apply')), findsNothing);
    expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-')),
      findsNothing,
    );

    // A second sync with unchanged WISA: the no-changes banner.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.textContaining('no account changes needed'), findsWidgets);
  });

  testWidgets(
      'while a sync runs the header shows a determinate progress bar that has '
      'advanced past the start (#176)', (WidgetTester tester) async {
    final gate = Completer<void>();
    final harness = ReconcileHarness(azureGate: gate);
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // Idle: no progress bar.
    expect(find.byKey(const ValueKey('reconcile-progress')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    // WISA + Smartschool resolve on the microtask queue; the Azure pull parks
    // on the gate, freezing the pass mid-flight so the busy bar is observable.
    await tester.pump();
    await tester.pump();

    final barFinder = find.byKey(const ValueKey('reconcile-progress'));
    expect(barFinder, findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(barFinder);
    // Determinate — not the old motionless indeterminate sweep — and already
    // stepped forward through the earlier stages (#176).
    expect(bar.value, isNotNull);
    expect(bar.value, greaterThan(0.0));
    expect(bar.value, lessThan(1.0));

    // Releasing the pull lets the pass finish; the bar disappears with busy.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-progress')), findsNothing);
  });

  testWidgets(
      'a lease held by another operator disables sync/drift and names them '
      '(#108)', (WidgetTester tester) async {
    final linkedStore = InMemoryLinkedStore();
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
    final harness = ReconcileHarness(linkedStore: linkedStore);

    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsOneWidget);
    expect(find.textContaining('mieke@school'), findsOneWidget);

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

    // No sync yet → no freshness row.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The freshness now sits in its own prominent row (#162), not trailing the
    // buttons.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(
      find.textContaining('by operator@school.example'),
      findsOneWidget,
    );
  });

  testWidgets(
      'the freshness line surfaces Smartschool and Azure as a drift check next '
      'to the WISA sync time (#170)', (WidgetTester tester) async {
    // Distinct fetch times per system so the line shows the WISA sync time and
    // the (later) Smartschool/Azure drift-check times side by side.
    final wisaAt = kFixtureDate.add(const Duration(hours: 1));
    final ssAt = kFixtureDate.add(const Duration(hours: 1, minutes: 3));
    final azAt = kFixtureDate.add(const Duration(hours: 1, minutes: 4));
    final harness = ReconcileHarness(
      wisa: wisaSnap(fetchedAt: wisaAt),
      smartschool: ssSnap(fetchedAt: ssAt),
      azure: azSnap(fetchedAt: azAt),
    );
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // One row, three systems, split into a "Last sync" clause (WISA) and a
    // "drift check" clause (Smartschool · Azure).
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('drift check — Smartschool'), findsOneWidget);
    // Azure rides in the same (single) freshness Text.
    final freshness = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('reconcile-freshness')),
        matching: find.byType(Text),
      ),
    );
    expect(freshness.data, contains('Azure'));
    expect(freshness.data, contains('Smartschool'));
    expect(freshness.data, contains('WISA'));
  });

  testWidgets('the last-sync line survives a restart / passive session (#162)',
      (WidgetTester tester) async {
    // Session 1 syncs and persists freshness to the shared store.
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    // Session 2 opens fresh over the same store — no sync — and reads the
    // overview back (loadOverview on bootstrap).
    final passive = ReconcileHarness(linkedStore: linkedStore);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: passive.bootstrap)));
    await tester.pumpAndSettle();

    expect(passive.wisaSyncs, 0, reason: 'a passive session pulls nothing');
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(
      find.textContaining('by operator@school.example'),
      findsOneWidget,
    );
  });

  testWidgets(
      'a passive session renders the category overview from the stored rollups '
      'with no live linked view (#163)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // Session 1 syncs and materializes the rollups into the shared store.
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    // Session 2 opens fresh over the same store — no sync — and reads the
    // overview back (loadOverview on bootstrap).
    final passive = ReconcileHarness(linkedStore: linkedStore);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: passive.bootstrap)));
    await tester.pumpAndSettle();

    // The overview renders from the rollups alone — link() was never called.
    expect(passive.controller.linked, isNull,
        reason: 'a passive session never links');
    expect(passive.wisaSyncs, 0, reason: 'a passive session pulls nothing');
    expect(find.text('Overview'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-category-staff')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-groups')),
        findsOneWidget);
    // The one fixture student is summed from the rollup, with a pending indicator.
    expect(find.text('2 openstaande acties'), findsOneWidget);
  });

  testWidgets(
      'a "syncing" signal disables sync/drift and names the owner; '
      '"synced" re-enables (#116)', (WidgetTester tester) async {
    final hub = InMemorySignalHub();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    final passive = ReconcileHarness(linkedStore: linkedStore, hub: hub);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: passive.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );

    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
    await hub
        .publisher()
        .publish(const ChangeSignal.syncStarted(owner: 'mieke@school'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsOneWidget);
    expect(find.textContaining('mieke@school'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('reconcile-drift')))
          .onPressed,
      isNull,
    );

    await linkedStore.releaseLease(owner: 'mieke@school');
    await hub
        .publisher()
        .publish(const ChangeSignal.syncEnded(owner: 'mieke@school'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'a duplicate-mail warning drills down to its accounts; accepting demotes '
      'it and revoking restores it (#109)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    final harness = dupMailHarness(linkedStore: linkedStore);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    const mail = 'shared@school.example';
    final tile = find.byKey(const ValueKey('dup-warning-$mail'));
    expect(tile, findsOneWidget);
    expect(find.textContaining('Dubbele mail "$mail"'), findsOneWidget);

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('admin · student'), findsOneWidget);
    expect(find.textContaining('user · student'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dup-accept-$mail')));
    await tester.pumpAndSettle();
    expect(await linkedStore.readDecisions(), hasLength(1));
    expect(find.textContaining('geaccepteerd'), findsWidgets);
    expect(find.byKey(const ValueKey('dup-accept-$mail')), findsNothing);
    expect(find.byKey(const ValueKey('dup-revoke-$mail')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dup-revoke-$mail')));
    await tester.pumpAndSettle();
    expect(await linkedStore.readDecisions(), isEmpty);
    expect(find.byKey(const ValueKey('dup-accept-$mail')), findsOneWidget);
  });

  testWidgets(
      'dragging the divider handle grows the log panel and clamps to a min '
      '(#152)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('reconcile-log-panel'));
    final handle = find.byKey(const ValueKey('reconcile-log-resize'));
    expect(panel, findsOneWidget);
    expect(handle, findsOneWidget);

    final double initial = tester.getSize(panel).height;
    expect(initial, 160);

    await tester.drag(handle, const Offset(0, -120),
        touchSlopX: 0, touchSlopY: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 280);

    await tester.drag(handle, const Offset(0, 2000),
        touchSlopX: 0, touchSlopY: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 64);
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
