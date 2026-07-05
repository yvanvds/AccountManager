import 'package:account_core/account_core.dart' show Address;
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Gives the reconcile screen a tall viewport so the below-the-fold sections
/// (overview, pending actions, results) are laid out without scrolling. The
/// body is now a lazy [CustomScrollView] (#111), so — unlike the old eager
/// `SingleChildScrollView` — off-screen slivers are not built; a tall window
/// keeps these presence-only assertions honest without a scroll on every one.
/// Width is left at the default 800 so horizontal layout is unchanged.
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
    _useTallWindow(tester);
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
    _useTallWindow(tester);
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

  testWidgets(
      'a "syncing" signal disables sync/drift and names the owner; '
      '"synced" re-enables (#116)', (WidgetTester tester) async {
    final hub = InMemorySignalHub();
    final linkedStore = InMemoryLinkedStore();
    // A first session leaves an overview so the passive screen has something to
    // sit on (no hub, so it does not publish into this test).
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    final passive = ReconcileHarness(linkedStore: linkedStore, hub: hub);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: passive.bootstrap)));
    await tester.pumpAndSettle();

    // No lock yet — both heavy actions are live.
    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );

    // Another operator takes the lease and broadcasts that it is syncing.
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
    await hub
        .publisher()
        .publish(const ChangeSignal.syncStarted(owner: 'mieke@school'));
    await tester.pumpAndSettle();

    // The screen names the owner and disables both heavy actions — no reload.
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

    // They finish: release + broadcast → the screen re-enables.
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

  testWidgets('a "changed" signal alone refetches the passive overview (#116)',
      (WidgetTester tester) async {
    final hub = InMemorySignalHub();
    final linkedStore = InMemoryLinkedStore();
    final snapshots = InMemorySnapshotStore();

    // Session 1 materializes generation 1 and broadcasts on the shared hub.
    final s1 =
        ReconcileHarness(store: snapshots, linkedStore: linkedStore, hub: hub);
    await s1.controller.sync();

    // Session 2 renders the shared overview passively, on the same hub.
    final s2 = await ReconcileHarness.resume(
        store: snapshots, linkedStore: linkedStore, hub: hub);
    await tester.pumpWidget(_wrap(ReconcileScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Generatie 1'), findsOneWidget);

    // Session 1 re-syncs a change → generation 2. Unlike the #108 test above,
    // nothing here calls onStoreChanged directly — the signal alone drives it.
    s1.wisaResult = wisaSnap(
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
      students: [wisaStudent(classGroup: '3D')],
    );
    await s1.controller.sync();
    await tester.pumpAndSettle();

    expect(find.textContaining('Generatie 2'), findsOneWidget);
    expect(find.textContaining('Generatie 1'), findsNothing);
  });

  testWidgets(
      'the drill-down surfaces the Klasgroepen node and opens the group '
      'detail (#119)', (WidgetTester tester) async {
    final linkedStore = InMemoryLinkedStore();
    final snapshots = InMemorySnapshotStore();

    // Session 1 syncs and materializes the shared view (the fixture's two
    // Smartschool-only classes raise the informational orphan notice).
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 renders the shared overview passively.
    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ReconcileScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    // The group node sits in the drill-down beside the school tree.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-groups')), findsOneWidget);
    expect(find.text('Klasgroepen'), findsWidgets);

    // Opening it lists the orphan classes with their notice — no pull, no link.
    // Bring it fully into view first: the draggable log divider (#152) is a
    // touch larger than the old hairline, so this bottom-of-fold node can sit
    // right on the panel boundary at the default window size.
    await tester.ensureVisible(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-groups-back')), findsOneWidget);
    expect(find.text('2B'), findsWidgets);
    expect(
        find.textContaining('Deze klas bestaat in Smartschool'), findsWidgets);
    expect(s2.controller.linked, isNull);

    // Back to the overview.
    await tester.tap(find.byKey(const ValueKey('reconcile-groups-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-groups')), findsOneWidget);
  });

  /// Builds a reconcile screen over a WISA-departed scenario: [count]
  /// Smartschool-only active accounts (no WISA, no Azure), each raising the
  /// mutually-exclusive unregister/delete choice (#110).
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

  testWidgets(
      'a departed student renders one entry with a unregister/delete choice; '
      'picking delete applies delete, not unregister (#110)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = departedHarness();
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // One entry for the departed account (not two independent rows).
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    final entryKey = ValueKey('entry-student-$id');
    expect(find.byKey(entryKey), findsOneWidget);

    // Expand it to reveal the choice.
    await tester.ensureVisible(find.byKey(entryKey));
    await tester.tap(find.byKey(entryKey));
    await tester.pumpAndSettle();

    // Both mutually-exclusive resolutions are offered as one choice.
    final unregisterAlt = ValueKey('alt-$id-UnregisterStudentFromSmartschool');
    final deleteAlt = ValueKey('alt-$id-DeleteStudentFromSmartschool');
    expect(find.byKey(unregisterAlt), findsOneWidget);
    expect(find.byKey(deleteAlt), findsOneWidget);

    // Pick delete (the non-default), then apply this one entry.
    await tester.tap(find.byKey(deleteAlt));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty,
        reason: 'delete is a real Smartschool write');
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Verwijder dit account uit Smartschool'));
    expect(summaries, isNot(contains('Schrijf de leerling uit in Smartschool')),
        reason: 'only the chosen alternative runs — never both');
  });

  testWidgets(
      'a same-situation subset offers a bulk apply that respects each row\'s '
      'choice (#110)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = departedHarness(count: 2);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The two departed accounts are grouped into one "same situation" subset
    // with a bulk affordance.
    expect(
        find.textContaining('accounts in the same situation'), findsOneWidget);
    final key = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .situationKey;
    final bulkApply = ValueKey('situation-apply-$key');
    expect(find.byKey(bulkApply), findsOneWidget);

    await tester.ensureVisible(find.byKey(bulkApply));
    await tester.tap(find.byKey(bulkApply));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    // Two accounts, two writes (one chosen resolution each) — not four.
    expect(harness.controller.applyResults, hasLength(2));
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

    // The collision is surfaced as one line (not accepted yet).
    const mail = 'shared@school.example';
    final tile = find.byKey(const ValueKey('dup-warning-$mail'));
    expect(tile, findsOneWidget);
    expect(find.textContaining('Dubbele mail "$mail"'), findsOneWidget);

    // Drilling down lists the colliding accounts (uid + type + role).
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('admin · student'), findsOneWidget);
    expect(find.textContaining('user · student'), findsOneWidget);

    // Accept it → persisted decision, demoted (accept becomes revoke).
    await tester.tap(find.byKey(const ValueKey('dup-accept-$mail')));
    await tester.pumpAndSettle();
    expect(await linkedStore.readDecisions(), hasLength(1));
    expect(find.textContaining('geaccepteerd'), findsWidgets);
    expect(find.byKey(const ValueKey('dup-accept-$mail')), findsNothing);
    expect(find.byKey(const ValueKey('dup-revoke-$mail')), findsOneWidget);

    // Revoke it → decision gone, the warning is un-demoted again.
    await tester.tap(find.byKey(const ValueKey('dup-revoke-$mail')));
    await tester.pumpAndSettle();
    expect(await linkedStore.readDecisions(), isEmpty);
    expect(find.byKey(const ValueKey('dup-accept-$mail')), findsOneWidget);
  });

  testWidgets(
      'a large pending set virtualizes: only a bounded number of entry tiles '
      'build, and scrolling builds/unloads them (#111)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = manyDepartedHarness(count: 2000);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // All 2000 accounts are one pending entry each (one situation subset).
    expect(harness.controller.pendingEntries, hasLength(2000));

    // The lazy SliverList builds only the on-screen tiles — nowhere near 2000.
    final entryTiles = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-'),
    );
    final builtInitially = entryTiles.evaluate().length;
    expect(builtInitially, greaterThan(0));
    expect(
      builtInitially,
      lessThan(200),
      reason: 'virtualized: on-screen tiles only, not all 2000',
    );

    // A far-off entry is not built yet…
    final entries = harness.controller.pendingEntries;
    final firstKey = ValueKey('entry-student-${entries.first.targetId}');
    final lastKey = ValueKey('entry-student-${entries.last.targetId}');
    expect(find.byKey(lastKey), findsNothing);

    // …scrolling to it builds it on demand (and unloads the top of the list).
    await tester.scrollUntilVisible(
      find.byKey(lastKey),
      5000,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 200,
    );
    expect(find.byKey(lastKey), findsOneWidget);
    expect(
      find.byKey(firstKey),
      findsNothing,
      reason: 'the first tile unloaded once scrolled far off-screen',
    );
  });

  testWidgets(
      'dragging the divider handle grows the log panel and clamps to a min '
      '(#152)', (WidgetTester tester) async {
    // A fixed, comfortably tall window so the drag has room to grow the panel
    // before hitting the "leave room for the content" cap.
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

    // Opens at the default height.
    final double initial = tester.getSize(panel).height;
    expect(initial, 160);

    // Dragging the handle up grows the log area by the drag distance. Slop is
    // zeroed so the whole offset lands as one reported delta.
    await tester.drag(handle, const Offset(0, -120),
        touchSlopX: 0, touchSlopY: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 280);

    // Dragging far down clamps to the sensible minimum, never collapsing away.
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

  // --- Address sync (#153) -------------------------------------------------
  // A WISA address (country hardcoded to 'BE', empty bus number → null) and its
  // Smartschool counterpart (free-text country, empty-string bus number). The
  // student sits in the same class in both systems, so the *only* possible
  // pending action for her is the address change.
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
      'an address differing only on country / empty bus number raises NO '
      'address action (#153)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = addressHarness(ss: ssAddr(), wisa: wisaAddr);
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The spurious "identical before/after" address action must not appear at
    // all (other unrelated fixture actions may exist — we assert on this one).
    expect(find.text('Wijzig het adres in Smartschool'), findsNothing);
    final labels =
        harness.controller.pendingEntries.map((e) => e.situationLabel);
    expect(
      labels.any((l) => l.contains('Wijzig het adres in Smartschool')),
      isFalse,
      reason: 'country-only / empty-bus-number drift is not a real change',
    );
  });

  testWidgets(
      'a real postalCode drift raises the address action and its expanded diff '
      'shows the differing field, not an identical row (#153)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness =
        addressHarness(ss: ssAddr(postalCode: '3270'), wisa: wisaAddr);
    // wisaAddr.postalCode is 3270; bump WISA to 3271 so only postalCode drifts.
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
    await tester
        .pumpWidget(_wrap(ReconcileScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.text('Wijzig het adres in Smartschool'), findsWidgets);

    // Expand the student entry to reveal the per-field diff.
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final entryKey = ValueKey('entry-student-${entry.targetId}');
    await tester.ensureVisible(find.byKey(entryKey));
    await tester.tap(find.byKey(entryKey));
    await tester.pumpAndSettle();

    // The previously-hidden differing field is now visible…
    expect(
      find.textContaining('postalCode: 3270 → 3271'),
      findsOneWidget,
    );
    // …and the fields that did not change are not shown as misleading
    // "Koophandelstraat 32 → Koophandelstraat 32" identical rows.
    expect(find.textContaining('street:'), findsNothing);
    expect(find.textContaining('city:'), findsNothing);
  });
}
