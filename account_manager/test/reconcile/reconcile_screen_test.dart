import 'dart:async';

import 'package:account_core/account_core.dart' show Origin;
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

    // The freshness now renders as a dedicated box headed "Last sync", with one
    // row per system rather than a run-on line (#188).
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(find.text('Last sync'), findsOneWidget);
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
    expect(find.textContaining('by operator@school.example'), findsWidgets);
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
    expect(rowText('wisa'), contains('sync'));
    expect(rowText('wisa'), isNot(contains('drift check')));
    expect(rowText('smartschool'), contains('drift check'));
    expect(rowText('azure'), contains('drift check'));
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
    expect(rowText('wisa'), contains('sync · 09:14'));
    expect(rowText('wisa'), isNot(contains('/')));
    expect(rowText('wisa'), isNot(contains('gisteren')));

    // Yesterday and older are now distinguishable at a glance.
    expect(rowText('smartschool'), contains('gisteren 08:05'));
    expect(rowText('azure'), contains('15/08/${now.year - 1} 16:40'));
    // …and the operator is still named on every row.
    expect(rowText('azure'), contains('by operator@school.example'));
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
    expect(find.text('Last sync'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.textContaining('by operator@school.example'), findsWidgets);
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

  testWidgets(
      'the log panel copies a multi-entry selection one line per entry, keeps '
      'the error colour, and Copy all takes the whole buffer (#193)',
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

    // Copy all ignores the selection and takes the buffer, oldest first.
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
}
