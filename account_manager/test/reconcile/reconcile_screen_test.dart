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
