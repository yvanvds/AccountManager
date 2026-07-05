// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:account_manager/main.dart' as app;
import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/screens/home_screen.dart';
import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        ChangeSignal,
        InMemoryLinkedStore,
        InMemorySignalHub,
        SecretRef,
        SignalRConfig,
        SignalRRequest,
        SignalRResponse,
        SignalRSocket,
        SignalRSocketConnector,
        SignalRSubscriber,
        SignalRTransport,
        StaticSignalRTokenProvider,
        WisaConnection,
        WisaSchoolProfile,
        signalRRecordSeparator;
import 'package:azure_api/azure_api.dart' show AzureCredentials;
import 'package:wisa_api/wisa_api.dart' show WisaSchool;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:plink_design_system/plink_design_system.dart';

import '../test/reconcile/reconcile_fakes.dart';
import '../test/screens/settings_fakes.dart';

/// End-to-end runs of the *real* app in the real engine, with the Plink fonts
/// bundled by the design-system package. This is the layer that catches
/// "renders in a widget test but not in the real app" bugs the widget test
/// structurally can't — real fonts, real window, real navigation.
///
/// All scenarios live in this one file on purpose: `flutter test
/// integration_test -d windows` starts a fresh app process per test *file*, and
/// the Windows embedder cannot bring up a second process in one invocation
/// ("log reader stopped"). Keeping every case here means a single process and a
/// single `flutter test integration_test` run covers them all.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final graph = AadResource.graph(AzureCredentials(
    clientId: 'client-123',
    tenantId: 'tenant-abc',
    azureDomain: 'school.example',
    schoolPrefix: 'GBS',
  ));

  /// Gives the app a tall viewport so the reconcile screen's below-the-fold
  /// sections lay out without scrolling. The body is a lazy [CustomScrollView]
  /// (#111), so off-screen slivers are not built; a tall window keeps the
  /// presence-only assertions honest. Reset after each test.
  void useTallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Switches the Settings view to the tab with [tabKey] (#140: config is split
  /// across Algemeen / Wisa / Smartschool / Azure tabs).
  Future<void> openSettingsTab(WidgetTester tester, String tabKey) async {
    await tester.tap(find.byKey(ValueKey(tabKey)));
    await tester.pumpAndSettle();
  }

  testWidgets('the app launches into the Plink-themed Home shell',
      (WidgetTester tester) async {
    // The real main(): with no --dart-define config, AAD is not configured, so
    // the sign-in gate reveals the shell directly.
    app.main();
    await tester.pumpAndSettle();

    // The real navigation shell and its Home destination rendered.
    expect(find.byType(AccountManagerApp), findsOneWidget);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);

    // Wrapped in the Plink design system: MaterialApp carries both the paper
    // and ink themes, and this app's per-product accent is layered on.
    final MaterialApp material =
        tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.theme, isNotNull);
    expect(material.darkTheme, isNotNull);

    final BuildContext context = tester.element(find.byType(HomeScreen));
    final PlinkProductAccent? accent =
        Theme.of(context).extension<PlinkProductAccent>();
    expect(accent?.accent, kProductAccent);

    // The bundled brand display font (Fraunces) resolved for the headline,
    // proving the design system's fonts ship with the app.
    final TextStyle? display = Theme.of(context).textTheme.displaySmall;
    expect(display?.fontFamily, contains('Fraunces'));
    expect(find.text('Account Manager'), findsOneWidget);

    // The shell carries the Reconcile destination; with no AAD config the
    // screen renders its "not configured" panel instead of bootstrapping.
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    expect(find.byType(ReconcileScreen), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
  });

  testWidgets(
      'the reconcile flow runs end-to-end: sign-in → sync → overview → '
      'actions → dry-run → apply → unchanged re-sync',
      (WidgetTester tester) async {
    // The real app composition — shell, navigation, theme — over the offline
    // reconcile harness (scripted syncers + recording transports), driven the
    // way the operator drives it.
    useTallWindow(tester);
    final harness = ReconcileHarness();
    final broker = _FakeBroker(silent: (_) => _token('AT'));
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(broker),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);

    // Open the reconcile screen; the stack bootstraps lazily.
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-sync')), findsOneWidget);

    // Sync: all three systems pull, the overview + pending actions render.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.wisaSyncs, 1);
    expect(harness.ssSyncs, 1);
    expect(harness.azSyncs, 1);
    expect(find.text('Linked overview'), findsOneWidget);
    expect(find.textContaining('Pending actions'), findsOneWidget);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // Dry-run: the projected changes render and nothing is written.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-dry-run')));
    await tester.tap(find.byKey(const ValueKey('reconcile-dry-run')));
    await tester.pumpAndSettle();
    expect(find.text('Dry-run result'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply: confirm the dialog, the Smartschool write happens for real
    // (against the recording transport).
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-apply')));
    await tester.tap(find.byKey(const ValueKey('reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);

    // Re-sync with unchanged WISA: the smart diff reports "no changes
    // needed" and leaves Smartschool / Azure unread.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no account changes needed'), findsWidgets);
    expect(harness.ssSyncs, 1);
    expect(harness.azSyncs, 1);
  });

  testWidgets(
      'the pending list groups one entry per account and applies the chosen '
      'alternative: choose delete → delete, not unregister (#110)',
      (WidgetTester tester) async {
    // A WISA-departed student: a Smartschool-only active account (no WISA, no
    // Azure) whose dispatcher yields the mutually-exclusive unregister/delete
    // resolutions — the exact situation #110 fixes.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const []),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          ssAccount(
            uid: 'jane',
            accountId: '1',
            mail: 'jane.doe@student.school.example',
          ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // One entry for the departed account (not two independent rows).
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    expect(entry.choices.single.isChoice, isTrue,
        reason: 'unregister vs delete collapse into a single choice');
    expect(find.byKey(ValueKey('entry-student-$id')), findsOneWidget);

    // Expand the entry, choose delete (the non-default), apply just this row.
    await tester.ensureVisible(find.byKey(ValueKey('entry-student-$id')));
    await tester.tap(find.byKey(ValueKey('entry-student-$id')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(ValueKey('alt-$id-DeleteStudentFromSmartschool')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Verwijder dit account uit Smartschool'));
    expect(summaries, isNot(contains('Schrijf de leerling uit in Smartschool')),
        reason: 'only the chosen resolution ran — never both');
  });

  testWidgets(
      'a student who left our school but stayed in the group shows the '
      'Smartschool departure and keeps Azure end-to-end (#134)',
      (WidgetTester tester) async {
    // The student is still in our Smartschool + Azure, but their WISA record now
    // sits only in a sibling group school we do not manage. The dispatcher must
    // raise the Smartschool departure while keeping Azure — never a removal.
    useTallWindow(tester);
    final harness = movedToSiblingHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The departed student is a pending entry carrying the unregister/delete
    // choice — and no Azure removal anywhere in the pending set.
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    expect(entry.choices.single.isChoice, isTrue);
    expect(find.byKey(ValueKey('entry-student-${entry.targetId}')),
        findsOneWidget);
    final allKinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind);
    expect(allKinds, isNot(contains('RemoveStudentFromAzure')),
        reason: 'the account is still in the group ⇒ Azure is kept');

    // Apply for real: the Smartschool departure writes against the recording
    // SOAP transport; Azure (Graph) is never called.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-apply')));
    await tester.tap(find.byKey(const ValueKey('reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);
    expect(harness.graph.requests, isEmpty, reason: 'Azure account is kept');
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
    expect(summaries, isNot(contains('Verwijder Azure account')));
  });

  testWidgets(
      'a large pending set virtualizes in the real app: only a bounded number '
      'of entry tiles build, and scrolling loads more (#111)',
      (WidgetTester tester) async {
    // A September-changeover-scale pending set (a thousand WISA-departed
    // accounts) in the real, laid-out app. The old eager Column built every
    // tile up front; the lazy CustomScrollView builds only the on-screen ones.
    useTallWindow(tester);
    final harness = manyDepartedHarness(count: 1000);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // All 1000 accounts are pending, but only a small window of tiles is built.
    expect(harness.controller.pendingEntries, hasLength(1000));
    final entryTiles = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-'),
    );
    final builtInitially = entryTiles.evaluate().length;
    expect(builtInitially, greaterThan(0));
    expect(builtInitially, lessThan(200),
        reason: 'virtualized: on-screen tiles only, not all 1000');

    // A far-off entry is not built until scrolled to.
    final entries = harness.controller.pendingEntries;
    final lastKey = ValueKey('entry-student-${entries.last.targetId}');
    expect(find.byKey(lastKey), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(lastKey),
      5000,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 200,
    );
    expect(find.byKey(lastKey), findsOneWidget);
  });

  testWidgets(
      'a resumed session trusts the stored state: Synchronise pulls no '
      'Smartschool/Azure (#107)', (WidgetTester tester) async {
    // Session 1 (offline harness over a shared cold-snapshot store): a full
    // sync persists all three connector snapshots.
    final store = InMemorySnapshotStore();
    await ReconcileHarness(store: store).controller.sync();

    // Session 2 is the real app, freshly bootstrapped over the *same* store —
    // its SystemStates seed from what session 1 persisted.
    final resumed = await ReconcileHarness.resume(store: store);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-sync')), findsOneWidget);

    // Drive Synchronise from the real UI: WISA is re-read for the smart diff,
    // but Smartschool and Azure are trusted from the store — no connector pull.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(resumed.wisaSyncs, 1);
    expect(resumed.ssSyncs, 0, reason: 'Smartschool seeded from the store');
    expect(resumed.azSyncs, 0, reason: 'Azure seeded from the store');
    expect(find.text('Linked overview'), findsOneWidget);
  });

  testWidgets(
      'a passive session renders the materialized overview and drills into a '
      'classroom with no pull and no link() (#115)',
      (WidgetTester tester) async {
    // Session 1 (offline harness) syncs and materializes the shared view into a
    // LinkedStore both sessions share.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 is the real app over the same stores. It never syncs.
    final resumed = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // The overview rendered straight from the store — no Synchronise tapped.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('School 1'), findsOneWidget);
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');

    // Drill down: school → grade-year → classroom.
    await tester.tap(find.text('School 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();

    // The classroom's account doc renders — still with no connector pull.
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-classroom-back')), findsOneWidget);
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
  });

  testWidgets(
      'a passive session surfaces pending group actions in the drill-down '
      'with no pull and no link() (#119)', (WidgetTester tester) async {
    // Session 1 (offline harness) syncs and materializes the shared view. The
    // fixture's two Smartschool-only classes (2B, 3C) raise the informational
    // orphan-class notice — the group-action family.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 is the real app over the same stores. It never syncs.
    final resumed = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // The class-group node is part of the shared overview, straight from the
    // store — no Synchronise tapped.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('Klasgroepen'), findsWidgets);

    // Drilling into it lists the orphan Smartschool classes with their notice.
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-groups-back')), findsOneWidget);
    expect(
        find.textContaining('Deze klas bestaat in Smartschool'), findsWidgets);
    // …all without a single connector pull or link().
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(resumed.controller.linked, isNull);
  });

  testWidgets(
      'a passive session shows the shared freshness and, while another '
      'operator holds the sync lease, disables Synchronise (#108)',
      (WidgetTester tester) async {
    // Session 1 (offline harness) syncs, materializing the shared view and
    // stamping per-system freshness into the LinkedStore both sessions share.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();
    // A different operator is mid-sync, holding the coarse sync/drift lease.
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

    // Session 2 is the real app over the same stores. It never syncs.
    final resumed = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // The shared per-system freshness line renders (who last synced each
    // system, from the store — not this passive session).
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('by operator@school.example'), findsOneWidget);

    // The lock is surfaced by name and Synchronise/Check-for-drift are disabled
    // so two operators cannot sync at once.
    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsOneWidget);
    expect(find.textContaining('mieke@school'), findsOneWidget);
    final sync = tester.widget<FilledButton>(
      find.byKey(const ValueKey('reconcile-sync')),
    );
    expect(sync.onPressed, isNull);
    expect(resumed.wisaSyncs, 0,
        reason: 'a blocked passive session never pulls');
  });

  testWidgets(
      'a SignalR "syncing" signal disables Synchronise live and names the '
      'owner; "synced" re-enables it (#116)', (WidgetTester tester) async {
    // Session 1 (offline harness) materializes the shared view. No hub here, so
    // it does not publish into this scenario.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 is the real app over the same stores, wired to a shared realtime
    // hub — the SignalR fan-out other operators broadcast onto.
    final hub = InMemorySignalHub();
    final resumed = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
      hub: hub,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // Nothing locked yet — Synchronise is live.
    expect(find.byKey(const ValueKey('reconcile-sync-lock')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );

    // Another operator takes the lease and broadcasts "syncing" — the running
    // app receives it live and locks, without any reload or re-pull.
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
    expect(resumed.wisaSyncs, 0, reason: 'the nudge never triggers a pull');

    // They finish: "synced" is broadcast → the app re-enables Synchronise live.
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
      'the live SignalR subscriber decodes a pushed wire signal and the '
      'running app catches up over it (#124)', (WidgetTester tester) async {
    // Session 1 (offline harness) materializes generation 1 into shared stores
    // (the student sits in 3C).
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
    await s1.controller.sync();

    // Session 2 is the real app, its ReconcileController driven by the *real*
    // SignalRSubscriber — the production receive code — over a fake WebSocket +
    // negotiate. This proves the wire→ChangeSignal→controller→UI path end to
    // end, with only the live Azure socket faked (that leg is /live-tests only).
    final connector = _FakeSignalRConnector();
    final subscriber = SignalRSubscriber(
      config: const SignalRConfig(
        endpoint: 'https://demo.service.signalr.net',
        hub: 'reconcile',
      ),
      tokens: const StaticSignalRTokenProvider('tok'),
      transport: _FakeNegotiateTransport(),
      connector: connector,
      // No timers left pending at settle: pings and reconnect are pushed far out
      // and the subscriber is closed before the test ends.
      pingInterval: const Duration(hours: 1),
      reconnectDelay: const Duration(hours: 1),
    );
    addTearDown(subscriber.close);

    final resumed = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
      subscriber: subscriber,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // The overview rendered at generation 1 and the subscriber connected.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(resumed.controller.syncState.generation, 1);
    final socket = connector.sockets.single;
    socket.serverSend('{}$signalRRecordSeparator'); // handshake ack
    await tester.pumpAndSettle();

    // Session 1 moves the student to 3D and re-syncs → the store is at
    // generation 2. Session 2 has not seen it yet.
    s1.wisaResult = wisaSnap(
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
      students: [wisaStudent(classGroup: '3D')],
    );
    await s1.controller.sync();
    expect((await linkedStore.readSyncState()).generation, 2);
    expect(resumed.controller.syncState.generation, 1,
        reason: 'no nudge received yet');

    // A writer broadcasts the viewChanged as a real SignalR invocation frame.
    // The running app decodes it off the socket and catches up — no reload.
    socket.serverSend(
      '{"type":1,"target":"signal","arguments":'
      '[{"kind":"viewChanged","generation":2}]}$signalRRecordSeparator',
    );
    await tester.pumpAndSettle();

    expect(resumed.controller.syncState.generation, 2,
        reason: 'the app caught up from the decoded wire signal alone');
    // Drill down to prove the refreshed rollups reached the UI: 3D now exists.
    await tester.tap(find.text('School 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.text('3D'), findsOneWidget);

    await subscriber.close();
  });

  testWidgets(
      'a duplicate-mail warning drills down and is accepted end-to-end (#109)',
      (WidgetTester tester) async {
    // Two Smartschool accounts share one mail (INV-23) — the deliberate
    // admin+user collision the operator accepts. The whole run is offline over
    // the recording transports, driven the way the operator drives it.
    useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    final harness = dupMailHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The collision surfaces one warning line in the real, laid-out app.
    const mail = 'shared@school.example';
    final tile = find.byKey(const ValueKey('dup-warning-$mail'));
    expect(tile, findsOneWidget);
    expect(find.textContaining('Dubbele mail "$mail"'), findsOneWidget);

    // Drilling it down lists the colliding accounts…
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('admin · student'), findsOneWidget);
    expect(find.textContaining('user · student'), findsOneWidget);

    // …and accepting persists a decision to the shared store and demotes it.
    await tester.tap(find.byKey(const ValueKey('dup-accept-$mail')));
    await tester.pumpAndSettle();
    final decisions = await linkedStore.readDecisions();
    expect(decisions, hasLength(1));
    expect(harness.controller.duplicateWarnings.single.accepted, isTrue);
    expect(find.byKey(const ValueKey('dup-revoke-$mail')), findsOneWidget);
  });

  testWidgets(
      'creating an account captures its password into the Passwords view, which '
      'distributes it out of the shared queue (#105)',
      (WidgetTester tester) async {
    // A brand-new student: present in WISA and Azure but not yet in Smartschool,
    // so the dispatcher yields exactly one AddStudentToSmartschool — an
    // account-creating apply that mints (and must capture) a password.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()]),
      azure: azSnap(users: [azUser()]),
      smartschool: ssSnap(accounts: const [], memberships: const []),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Reconcile → sync → the create is pending. The queue starts empty.
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.text('Maak een nieuw Smartschool account'), findsWidgets);
    expect(await harness.passwordQueue.load(), isEmpty);

    // Apply it for real (against the recording SOAP transport): the create runs
    // and its minted password is captured into the shared queue.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-apply')));
    await tester.tap(find.byKey(const ValueKey('reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Apply result'), findsOneWidget);
    final queued = await harness.passwordQueue.load();
    expect(queued, hasLength(1),
        reason: 'the created account\'s password landed in the queue');
    expect(queued.single.smartschoolPassword, isNotNull);

    // Switch to the Passwords view: the freshly captured sheet is listed in the
    // real, laid-out app.
    await tester.tap(find.text('Passwords'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Smartschool:'), findsOneWidget);

    // Mark it distributed → it drains from the shared queue (saved remainder is
    // empty) and the view falls back to the all-distributed state.
    await tester.tap(find.byIcon(Icons.done_all));
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsNothing);
    expect(find.byKey(const ValueKey('passwords-empty')), findsOneWidget);
    expect(await harness.passwordQueue.load(), isEmpty);
  });

  testWidgets(
      'the Settings view edits a profile field and a secret, saving both '
      'against the fakes — the secret through the provider, never into the blob '
      '(#106)', (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams. The store
    // already holds a partial config (the #99 seed) with a stale prefix.
    useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final settings = SettingsHarness(
      initial: const AppSettings(
        schoolPrefix: 'OLD',
        wisa: WisaConnection(server: 'old.host'),
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);

    // Open Settings; the stored document is read into the real, laid-out form.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // The app-wide prefix shows on the default Algemeen tab.
    expect(find.text('OLD'), findsOneWidget);

    // Edit the app-wide prefix on Algemeen…
    await tester.enterText(
      find.byKey(const ValueKey('settings-school-prefix')),
      'GBS-KA',
    );
    // …then the WISA connection + secret on the Wisa tab (#140).
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(find.text('old.host'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-server')),
      'wisa.new.host',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-password')),
      'typed-secret',
    );
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // The profile edits landed in the store…
    final saved = await settings.store.load();
    expect(saved.schoolPrefix, 'GBS-KA');
    expect(saved.wisa.server, 'wisa.new.host');
    // …the secret went through the provider, not into the settings document…
    expect(await settings.secrets.read(passwordRef), 'typed-secret');
    expect(saved.toJson().toString(), isNot(contains('typed-secret')));
    // …and the secret field (still on the Wisa tab) was cleared, never echoing
    // the value back.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('settings-wisa-password')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets(
      'the Settings view marks a WISA school as "ours" end-to-end, persisting '
      'the ownership flag to the store (#133)', (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams. The store
    // already knows one group school (id 42), not yet managed.
    useTallWindow(tester);
    final settings = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [WisaSchoolProfile(schoolId: 42)],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Open Settings; the seeded school renders in the real, laid-out form with
    // its managed switch off.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // The managed-school list lives under the Wisa tab now (#140); open it and
    // bring the seeded school's switch into view before reading it.
    await openSettingsTab(tester, 'settings-tab-wisa');
    final ourSwitch =
        find.byKey(const ValueKey('settings-wisa-school-42-ours'));
    await tester.ensureVisible(ourSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(ourSwitch).value, isFalse);

    // Mark it managed and save (the Save action sits in the shared header).
    await tester.tap(ourSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // The ownership flag landed in the store.
    final saved = await settings.store.load();
    expect(saved.wisaSchools.single.schoolId, 42);
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets(
      'the Settings view fetches the WISA school list and persists the picked '
      'selection end-to-end, no id typed by hand (#142)',
      (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams. The store
    // holds a valid WISA connection profile and the password sits in the vault,
    // so the fetch action lights up. The fetcher is faked (offline) but wired
    // exactly like production — real screen, real navigation, real layout.
    useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 3, name: 'Sint-Jan', description: 'SJ'),
      WisaSchool(id: 7, name: 'Sint-Pieter', description: 'SP'),
    ]);
    final settings = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Open Settings → Wisa tab; the fetch action is available for a valid config.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');
    final button = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);

    // Fetch: both schools render by name, the stored password was resolved.
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(fetcher.calls, 1);
    expect(fetcher.lastPassword, 'stored-pw');
    expect(find.text('Sint-Jan'), findsOneWidget);
    expect(find.text('Sint-Pieter'), findsOneWidget);

    // Pick one returned school and save; the selection lands in the store with
    // no id ever typed by hand.
    final picked = find.byKey(const ValueKey('settings-wisa-fetched-school-7'));
    await tester.ensureVisible(picked);
    await tester.tap(picked);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await settings.store.load();
    expect(saved.wisaSchools.single.schoolId, 7);
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets(
      'the Settings/Algemeen werkdatum controls read clearly end-to-end: '
      'renamed virtual label + right-aligned switch instruction (#141)',
      (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams — real fonts,
    // real window, real ListTile layout, which is exactly where a right-align
    // that "works" in a widget test can drift.
    useTallWindow(tester);
    final settings = SettingsHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Open Settings; the werkdatum controls sit on the default Algemeen tab.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // The virtual field carries the clearer label, and the old one is gone.
    expect(find.text('Werkdatum Virtuele School'), findsOneWidget);
    expect(find.text('Virtuele werkdatum'), findsNothing);

    // The "volg de huidige datum" instruction is right-aligned against its
    // switch, not merged into the field label on the left.
    final tile = find.byKey(const ValueKey('settings-workdate-is-now'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    final label = find.descendant(of: tile, matching: find.text('Werkdatum'));
    final instruction =
        find.descendant(of: tile, matching: find.text('volg de huidige datum'));
    final switchWidget =
        find.descendant(of: tile, matching: find.byType(Switch));
    expect(label, findsOneWidget);
    expect(instruction, findsOneWidget);
    expect(switchWidget, findsOneWidget);
    final tileLeft = tester.getTopLeft(tile).dx;
    final tileCenter = tester.getCenter(tile).dx;
    final instrCenter = tester.getCenter(instruction).dx;
    expect(instrCenter, greaterThan(tileCenter),
        reason: 'the instruction sits in the right portion, by the switch');
    final switchLeft = tester.getTopLeft(switchWidget).dx;
    final instrRight = tester.getTopRight(instruction).dx;
    expect(switchLeft - instrRight, lessThan(instrCenter - tileLeft),
        reason: 'the instruction hugs the switch, away from the field label');
  });

  testWidgets('silent sign-in leads straight into the shell',
      (WidgetTester tester) async {
    final broker = _FakeBroker(silent: (_) => _token('AT'));
    await tester.pumpWidget(
      AccountManagerApp(session: SignInSession(broker), graph: graph),
    );
    await tester.pumpAndSettle();

    expect(broker.silentCalls, ['graph']);
    expect(broker.interactiveCalls, isEmpty);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('interactive fallback then retry reaches the shell',
      (WidgetTester tester) async {
    var attempts = 0;
    final broker = _FakeBroker(
      silent: (_) => null,
      interactive: (_) {
        attempts++;
        if (attempts == 1) {
          throw const AadBrokerException('offline', code: 'broker_error');
        }
        return _token('AT');
      },
    );
    await tester.pumpWidget(
      AccountManagerApp(session: SignInSession(broker), graph: graph),
    );
    await tester.pumpAndSettle();

    // First attempt failed → the failure panel renders in the real app.
    expect(find.text('Could not sign in'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('an unavailable native broker falls through to interactive',
      (WidgetTester tester) async {
    // The real composition on the dev laptop: the native WAM broker reports
    // `broker_unavailable`, so the chain falls through to the interactive
    // (loopback) broker, which signs in and reveals the shell.
    final native = _FakeBroker(
      silent: (_) => throw const AadBrokerException(
        'not built',
        code: 'broker_unavailable',
      ),
      interactive: (_) => throw const AadBrokerException(
        'not built',
        code: 'broker_unavailable',
      ),
    );
    final loopback = _FakeBroker(interactive: (_) => _token('AT'));
    final session = SignInSession(CompositeBroker([native, loopback]));

    await tester.pumpWidget(AccountManagerApp(session: session, graph: graph));
    await tester.pumpAndSettle();

    expect(loopback.interactiveCalls, ['graph']);
    expect(find.byType(AppShell), findsOneWidget);
  });
}

/// A broker scripted per test — a fake WAM broker so no live tenant is touched.
class _FakeBroker implements AadBroker {
  _FakeBroker({this.silent, this.interactive});

  BrokerToken? Function(AadResource resource)? silent;
  BrokerToken Function(AadResource resource)? interactive;
  final List<String> silentCalls = <String>[];
  final List<String> interactiveCalls = <String>[];

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async {
    silentCalls.add(resource.id);
    return silent?.call(resource);
  }

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    interactiveCalls.add(resource.id);
    final result = interactive?.call(resource);
    if (result == null) {
      throw const AadBrokerException('no interactive token');
    }
    return result;
  }
}

BrokerToken _token(String v) => BrokerToken(
      accessToken: v,
      expiresOn: DateTime.now().toUtc().add(const Duration(hours: 1)),
      account: 'operator@school.example',
    );

/// A negotiate transport that hands back a scripted client URL + token, so the
/// real [SignalRSubscriber] gets past negotiate with no network (#124).
class _FakeNegotiateTransport implements SignalRTransport {
  @override
  Future<SignalRResponse> send(SignalRRequest request) async => SignalRResponse(
        statusCode: 200,
        body: '{"url":"wss://demo.service.signalr.net/client",'
            '"accessToken":"ct"}',
      );
}

/// A fake WebSocket connector that records the sockets it opens so the test can
/// push server frames in — the one leg faked so the receive loop runs offline.
class _FakeSignalRConnector implements SignalRSocketConnector {
  final List<_FakeSignalRSocket> sockets = <_FakeSignalRSocket>[];

  @override
  Future<SignalRSocket> connect(Uri url) async {
    final socket = _FakeSignalRSocket();
    sockets.add(socket);
    return socket;
  }
}

class _FakeSignalRSocket implements SignalRSocket {
  final StreamController<String> _incoming = StreamController<String>();

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) {}

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  void serverSend(String frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
  }
}
