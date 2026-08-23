import 'dart:async';

import 'package:account_core/account_core.dart' show Origin;
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
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
      find.text('Kan het Synchronisatie-scherm niet openen'),
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

    expect(find.textContaining('(Poging'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-bootstrap-retry')));
    await tester.pumpAndSettle();

    expect(find.textContaining('(Poging 2 mislukt.)'), findsOneWidget);
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
    expect(find.text('Overzicht'), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The per-category overview renders on Reconcile from the rollups (#163):
    // students / staff / class-groups, each with a pending indicator.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-category-staff')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-groups')),
        findsOneWidget);
    expect(find.text('LEERLINGEN'), findsOneWidget); // PlinkBadge uppercases
    // The one fixture student's applyable actions surface as a pending indicator.
    expect(find.text('2 openstaande acties'), findsOneWidget);

    // …but the pending actions moved to the Actions tab: neither the title, an
    // apply affordance, nor any entry tile is on the Reconcile screen (#154).
    expect(find.textContaining('Pending actions'), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-apply')), findsNothing);
    for (final String prefix in <String>['entry-', 'situation-']) {
      expect(
        find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(prefix)),
        findsNothing,
        reason: 'no "$prefix" affordance belongs on Synchronisatie',
      );
    }

    // A second sync with unchanged WISA: the no-changes banner.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('geen accountwijzigingen nodig'),
      findsWidgets,
    );
  });

  testWidgets(
      'the screen names its own controls in the operator\'s language, like the '
      'rail and heading above them (#265)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // The two buttons under the heading, and the explainer that names them in
    // prose — which #265 could translate but not assert, because the phase it
    // was gated on moved off `idle` before the first frame (fixed in #275).
    expect(find.text('Synchroniseer'), findsOneWidget);
    expect(find.text('Controleer op drift'), findsOneWidget);
    expect(
      find.textContaining('Synchroniseer haalt WISA op en vergelijkt het met '
          'de vorige momentopname'),
      findsOneWidget,
    );

    // The log panel's own chrome, empty state included.
    expect(find.text('Logboek'), findsOneWidget);
    expect(find.text('Alles kopiëren'), findsOneWidget);
    expect(find.text('Wissen'), findsOneWidget);
    expect(find.text('Nog geen berichten.'), findsOneWidget);

    // Nothing English is left on the screen's own chrome.
    for (final String english in <String>[
      'Synchronise',
      'Check for drift',
      'Overview',
      'Log',
      'Copy all',
      'Clear',
      'No messages yet.',
    ]) {
      expect(find.text(english), findsNothing,
          reason: '"$english" is the English label #265 replaced');
    }

    // And the counts heading, once a sync has produced one.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.text('Overzicht'), findsOneWidget);
  });

  testWidgets(
      'the screen explains its two buttons until a pass has run — in a passive '
      'session that only read the shared overview too (#275)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // An overview another operator's sync materialized. Opening the screen
    // reads it (`loadOverview`) without running anything, which is precisely
    // the read that used to claim the pass phase `ready` and, because it
    // resolves on the microtask queue, swallowed the explainer before the
    // operator's first frame.
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    final harness = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    final explainer = find.byKey(const ValueKey('reconcile-explainer'));
    // The stored overview renders — and so does the only thing on the screen
    // that says what the two buttons above it do.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(explainer, findsOneWidget);
    expect(
      find.textContaining('Gebruik "Controleer op drift" wanneer accounts via '
          'een ander programma zijn aangepast.'),
      findsOneWidget,
    );

    // Once this session has actually run a pass, the banner goes back to
    // reporting on that pass rather than repeating the introduction.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(explainer, findsNothing);
  });

  testWidgets(
      'a session that adopted the shared state says so, and one that could not '
      'says why (#287)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // The seeded launch: it inherits the colleague's pull and says whose.
    final adopting = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: adopting.bootstrap)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-adopted')), findsOneWidget);
    expect(
      find.textContaining('werkt met de gedeelde synchronisatie'),
      findsOneWidget,
    );
    expect(find.textContaining('operator@school.example'), findsWidgets);
    expect(find.byKey(const ValueKey('reconcile-seed-refused')), findsNothing);
    expect(adopting.wisaSyncs, 0);
    // Both buttons stay exactly as available as they were.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('reconcile-drift')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'a session that could not adopt the shared state surfaces one blocking '
      'reason (#287)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    // The launch with nothing seeded: the shared overview is readable, but
    // there is no snapshot to build a view from.
    final refused = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: refused.bootstrap)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-adopted')), findsNothing);
    expect(
        find.byKey(const ValueKey('reconcile-seed-refused')), findsOneWidget);
    expect(
      find.textContaining('Geen opgeslagen momentopname'),
      findsOneWidget,
      reason: 'a refused session owes the operator exactly one reason',
    );
    expect(refused.wisaSyncs, 0);
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

  testWidgets(
      'the header shows the shared per-system last-sync box with a row per '
      'system (#108/#188)', (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // No sync yet → no box.
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The freshness now renders as a dedicated box headed "Laatste
    // synchronisatie", with one row per system rather than a run-on line
    // (#188).
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(find.text('Laatste synchronisatie'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-last-sync-smartschool')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-last-sync-azure')),
        findsOneWidget);
    expect(find.text('WISA'), findsOneWidget);
    expect(find.text('Smartschool'), findsOneWidget);
    expect(find.text('Azure'), findsOneWidget);
    // Each row names the operator who last synced it.
    expect(find.textContaining('door operator@school.example'), findsWidgets);
  });

  testWidgets(
      'the last-sync box shows WISA as a sync and Smartschool/Azure as drift '
      'checks, each on its own row (#170/#188)', (WidgetTester tester) async {
    // Distinct fetch times per system so WISA carries its sync time and the
    // (later) Smartschool/Azure rows carry their drift-check times.
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

    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);

    // Collect the text of one system's row.
    String rowText(String system) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(ValueKey('reconcile-last-sync-$system')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .join(' ');

    // WISA is the sync; Smartschool and Azure are drift checks — each on its
    // own row, no longer packed into one wrapped sentence.
    expect(rowText('wisa'), contains('synchronisatie'));
    expect(rowText('wisa'), isNot(contains('driftcontrole')));
    expect(rowText('smartschool'), contains('driftcontrole'));
    expect(rowText('azure'), contains('driftcontrole'));
  });

  testWidgets(
      'the last-sync box dates a stamp that is not from today: today stays '
      "time-only, yesterday reads 'gisteren', an older one carries the date "
      '(#192)', (WidgetTester tester) async {
    // Three systems stamped on three different calendar days, pinned against
    // the clock the row renders with. Time-only made all three read identically
    // (`sync · 09:14`), which is exactly how an operator ends up
    // reconciling against a snapshot that is days old.
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 9, 14);
    final DateTime yesterday = DateTime(now.year, now.month, now.day - 1, 8, 5);
    final DateTime lastYear = DateTime(now.year - 1, 8, 15, 16, 40);
    final harness = ReconcileHarness(
      wisa: wisaSnap(fetchedAt: today),
      smartschool: ssSnap(fetchedAt: yesterday),
      azure: azSnap(fetchedAt: lastYear),
    );
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    String rowText(String system) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(ValueKey('reconcile-last-sync-$system')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .join(' ');

    // Today: unchanged, still the short time-only form.
    expect(rowText('wisa'), contains('synchronisatie · 09:14'));
    expect(rowText('wisa'), isNot(contains('/')));
    expect(rowText('wisa'), isNot(contains('gisteren')));

    // Yesterday and older are now distinguishable at a glance.
    expect(rowText('smartschool'), contains('gisteren 08:05'));
    expect(rowText('azure'), contains('15/08/${now.year - 1} 16:40'));
    // …and the operator is still named on every row.
    expect(rowText('azure'), contains('door operator@school.example'));
  });

  testWidgets('the last-sync box survives a restart / passive session (#162)',
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
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(find.text('Laatste synchronisatie'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.textContaining('door operator@school.example'), findsWidgets);
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
    expect(find.text('Overzicht'), findsOneWidget);
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
      'an id collision is named on the overview, open, with both records '
      '(#319)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = idCollisionHarness();
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('id-collision-p-shared'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    expect(
      find.descendant(
          of: tile, matching: find.textContaining('Koppelingsfout')),
      findsOneWidget,
    );

    // Shown open, with no tap: there is nothing to decide, so the two records
    // have to be readable straight away or the notice says nothing useful.
    expect(
      find.descendant(of: tile, matching: find.textContaining('WISA W1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.textContaining('WISA W2')),
      findsOneWidget,
    );
  });

  testWidgets('an ordinary sync shows no collision notice (#319)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Koppelingsfout'), findsNothing);
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
      find.textContaining('WISA ophalen', skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(find.text('Wissen'));
    await tester.pumpAndSettle();

    expect(find.text('Nog geen berichten.'), findsOneWidget);
  });

  testWidgets(
      'the log panel copies a multi-entry selection one line per entry, keeps '
      'the error colour, and Alles kopiëren takes the whole buffer (#193)',
      (WidgetTester tester) async {
    final List<String> copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copied.add(args['text']! as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // A known buffer: the harness clock is fixed, so every stamp is 00:00:00.
    harness.log
      ..clear()
      ..addMessage(Origin.wisa, 'alpha')
      ..addError(Origin.smartschool, 'beta')
      ..addMessage(Origin.azure, 'gamma');
    await tester.pumpAndSettle();

    // Rendered newest first as one selectable paragraph.
    final Finder block = find.byKey(const ValueKey('reconcile-log-text'));
    expect(block, findsOneWidget);
    final Text rendered = tester.widget<Text>(block);
    expect(
      rendered.textSpan!.toPlainText(),
      '00:00:00  [azure]  gamma\n'
      '00:00:00  [smartschool]  beta\n'
      '00:00:00  [wisa]  alpha',
    );

    // The error entry keeps its error colour while selectable; the others are
    // left on the panel's base style.
    final ColorScheme colors = Theme.of(tester.element(block)).colorScheme;
    final List<TextSpan> spans =
        ((rendered.textSpan! as TextSpan).children ?? const <InlineSpan>[])
            .cast<TextSpan>();
    expect(
      spans.firstWhere((TextSpan s) => s.text!.contains('beta')).style?.color,
      colors.error,
    );
    expect(
      spans.firstWhere((TextSpan s) => s.text!.contains('gamma')).style,
      isNull,
    );

    // Drag the mouse across the first two rendered lines, then Ctrl+C: the two
    // entries land on the clipboard one per line, not run together.
    final Rect rect = tester.getRect(block);
    final double lineHeight = rect.height / 3;
    final TestGesture drag = await tester.startGesture(
      Offset(rect.left + 1, rect.top + lineHeight * 0.5),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(Offset(rect.right - 1, rect.top + lineHeight * 1.5));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(
      copied.single,
      '00:00:00  [azure]  gamma\n00:00:00  [smartschool]  beta',
    );

    // Alles kopiëren ignores the selection and takes the buffer, oldest first.
    await tester.tap(find.byKey(const ValueKey('reconcile-log-copy-all')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(2));
    expect(
      copied.last,
      '00:00:00  [wisa]  alpha\n'
      '00:00:00  [smartschool]  beta\n'
      '00:00:00  [azure]  gamma',
    );

    // Both actions are dead while there is nothing to copy.
    harness.log.clear();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
              find.byKey(const ValueKey('reconcile-log-copy-all')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
      'right-clicking a log line offers Regel kopiëren and copies exactly '
      'that entry (#197)', (WidgetTester tester) async {
    final List<String> copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copied.add(args['text']! as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    // A known buffer: the harness clock is fixed, so every stamp is 00:00:00.
    harness.log
      ..clear()
      ..addMessage(Origin.wisa, 'alpha')
      ..addError(Origin.smartschool, 'beta')
      ..addMessage(Origin.azure, 'gamma');
    await tester.pumpAndSettle();

    // Rendered newest first, so "beta" is the middle of three lines.
    final Finder block = find.byKey(const ValueKey('reconcile-log-text'));
    final Rect rect = tester.getRect(block);
    final double lineHeight = rect.height / 3;

    await _rightClickAt(
      tester,
      Offset(rect.left + 8, rect.top + lineHeight * 1.5),
    );

    expect(find.text('Regel kopiëren'), findsOneWidget);
    await tester.tap(find.text('Regel kopiëren'));
    await tester.pumpAndSettle();

    // Exactly the one entry under the pointer — no timestamp of its
    // neighbours, and no trailing newline.
    expect(copied, hasLength(1));
    expect(copied.single, '00:00:00  [smartschool]  beta');

    // The empty space under the last line has no entry to copy, so the menu
    // there offers only what the framework itself contributes.
    await _rightClickAt(tester, Offset(rect.left + 8, rect.bottom + 24));
    expect(find.text('Regel kopiëren'), findsNothing);
  });

  testWidgets(
      'Regel kopiëren takes the whole entry when the message soft-wraps over '
      'several rows (#197)', (WidgetTester tester) async {
    final List<String> copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copied.add(args['text']! as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final harness = ReconcileHarness();
    await tester.pumpWidget(
      _wrap(ReconcileScreen(bootstrap: harness.bootstrap)),
    );
    await tester.pumpAndSettle();

    final Finder block = find.byKey(const ValueKey('reconcile-log-text'));

    // One short entry first: its height is one rendered row.
    harness.log
      ..clear()
      ..addMessage(Origin.wisa, 'short');
    await tester.pumpAndSettle();
    final double oneRow = tester.getRect(block).height;

    // Now a long entry that cannot fit the panel's width. It is added last, so
    // it renders first (newest first) and the short one sits underneath it.
    final String long = 'Set-Password failed for ${'a' * 400}';
    harness.log.addError(Origin.smartschool, long);
    await tester.pumpAndSettle();

    final Rect rect = tester.getRect(block);
    // It really did wrap: the paragraph is taller than the two entries would
    // be if each took a single row.
    expect(rect.height, greaterThan(oneRow * 2));

    // Right-click the *second* rendered row. That row is a continuation of
    // the first (wrapped) entry, so a per-line action that divided the hit by
    // a row height would hand back the second entry, "short". Counting
    // newlines gives back the entry the row actually belongs to.
    await _rightClickAt(
      tester,
      Offset(rect.left + 8, rect.top + oneRow * 1.5),
    );

    expect(find.text('Regel kopiëren'), findsOneWidget);
    await tester.tap(find.text('Regel kopiëren'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, '00:00:00  [smartschool]  $long');
  });
}

/// A right-click (secondary mouse button) at a global [at], which is what puts
/// the panel's selection context menu on screen (#197).
Future<void> _rightClickAt(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}
