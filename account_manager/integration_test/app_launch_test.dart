// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:account_core/account_core.dart' show Address, Origin;
import 'package:account_manager/main.dart' as app;
import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/screens/actions_screen.dart';
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
import 'package:azure_api/azure_api.dart'
    show AzureCredentials, StaticAuthProvider;
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

    // The shell carries both the Reconcile and the new Actions destinations;
    // with no AAD config the reconcile screen renders its "not configured"
    // panel instead of bootstrapping.
    expect(find.text('Actions'), findsOneWidget);
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    expect(find.byType(ReconcileScreen), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
  });

  testWidgets(
      'the reconcile flow runs end-to-end: sign-in → sync → overview on '
      'Reconcile → actions via the Actions tab drill-down → dry-run → apply → '
      'unchanged re-sync (#154)', (WidgetTester tester) async {
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

    // Sync: all three systems pull, the overview renders on Reconcile — but the
    // pending actions do NOT (they moved to the Actions tab).
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.wisaSyncs, 1);
    expect(harness.ssSyncs, 1);
    expect(harness.azSyncs, 1);
    // The per-category overview renders on Reconcile from the rollups (#163):
    // students / staff / class-groups, the one fixture student summed with a
    // pending indicator.
    expect(find.text('Overview'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(find.text('2 openstaande acties'), findsOneWidget);
    expect(find.textContaining('Pending actions'), findsNothing);
    expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-')),
      findsNothing,
      reason: 'Reconcile no longer shows the flat pending-actions list',
    );

    // Switch to the Actions tab: the actions are browsed by the year → class
    // drill-down. Drill into 3C to build that class's action tile.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionsScreen), findsOneWidget);
    expect(find.text('Overzicht'), findsOneWidget);
    await tester.tap(find.text('School 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // Dry-run all from the header: the projected changes render, nothing writes.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-dry-run')));
    await tester.tap(find.byKey(const ValueKey('actions-dry-run')));
    await tester.pumpAndSettle();
    expect(find.text('Dry-run result'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply all: confirm the dialog, the Smartschool write happens for real.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);

    // Back on Reconcile, re-sync with unchanged WISA: the smart diff reports
    // "no changes needed" and leaves Smartschool / Azure unread.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no account changes needed'), findsWidgets);
    expect(harness.ssSyncs, 1);
    expect(harness.azSyncs, 1);
  });

  testWidgets(
      'while a sync runs the reconcile header shows a determinate progress bar '
      'that has advanced past the start end-to-end (#176)',
      (WidgetTester tester) async {
    // The real app over the offline harness, but the Azure pull parks on a gate
    // so the pass is frozen mid-flight — the moment the operator stares at the
    // busy bar during a long pull. It must read as a determinate bar that has
    // already stepped forward through the earlier stages, not a motionless
    // sweep that looks like a hung app.
    useTallWindow(tester);
    final gate = Completer<void>();
    final harness = ReconcileHarness(azureGate: gate);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // Idle: no progress bar at all.
    expect(find.byKey(const ValueKey('reconcile-progress')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    // WISA + Smartschool resolve on the microtask queue; the Azure pull parks
    // on the gate, freezing the pass with the busy bar on screen.
    await tester.pump();
    await tester.pump();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('reconcile-progress')),
    );
    expect(bar.value, isNotNull, reason: 'determinate, not a static sweep');
    expect(bar.value, greaterThan(0.0),
        reason: 'already advanced through the earlier stages');
    expect(bar.value, lessThan(1.0));
    expect(harness.controller.busy, isTrue);

    // Releasing the pull lets the pass finish; the bar disappears with busy.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-progress')), findsNothing);
    expect(harness.controller.busy, isFalse);
  });

  testWidgets(
      'a completed sync logs a terminal "Sync complete … Ready." line and the '
      'prominent last-sync freshness row renders end-to-end (#162)',
      (WidgetTester tester) async {
    // The real app composition over the offline harness, driven the way the
    // operator drives it. (Restart survival of the freshness line is covered by
    // the passive-session freshness scenario below and the widget test.)
    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // Before syncing there is no freshness row yet.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The terminal ready line is logged (newest-first in the log panel) so the
    // operator knows the pass finished, and it names the pending-action count.
    expect(
      find.textContaining('Sync complete — 4 pending action(s). Ready.'),
      findsOneWidget,
    );
    // The last-sync freshness now renders in its own prominent row.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('by operator@school.example'), findsOneWidget);

    // A second, unchanged re-sync logs the no-change ready line too.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sync complete — no account changes needed. Ready.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'the freshness line surfaces Smartschool and Azure as a drift check '
      'alongside the WISA sync, and a Check for drift advances only those two '
      '(#170)', (WidgetTester tester) async {
    // The real app over the offline harness: a first full sync stamps all three
    // systems, then Check for drift re-reads Smartschool/Azure at a later time
    // while WISA keeps its earlier sync stamp. The freshness line must show both
    // clauses throughout — the WISA sync time and the drift-checked pair.
    useTallWindow(tester);
    final harness = ReconcileHarness();
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

    // After the first full sync all three systems appear, split into the WISA
    // "Last sync" clause and the Smartschool/Azure "drift check" clause.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    Text freshnessText() => tester.widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('reconcile-freshness')),
            matching: find.byType(Text),
          ),
        );
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('drift check — Smartschool'), findsOneWidget);
    expect(freshnessText().data, contains('Azure'));

    // Check for drift re-pulls Smartschool and Azure at a later time; WISA is
    // not re-pulled, so its sync stamp stays put while the drift pair advances.
    final driftAt = kFixtureDate.add(const Duration(hours: 3));
    harness.ssResult = ssSnap(fetchedAt: driftAt);
    harness.azResult = azSnap(fetchedAt: driftAt);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();

    // The line still carries both clauses, and the underlying state proves the
    // drift pair advanced while WISA held its earlier sync time.
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('drift check — Smartschool'), findsOneWidget);
    final systems = harness.controller.syncState.systems;
    expect(systems[Origin.wisa]?.at, kFixtureDate);
    expect(systems[Origin.smartschool]?.at, driftAt);
    expect(systems[Origin.azure]?.at, driftAt);
  });

  testWidgets(
      'the operator decoded from the real loopback broker JWT names the last '
      'sync in the freshness line end-to-end (#169)',
      (WidgetTester tester) async {
    // The production sign-in path on a machine without the native WAM broker:
    // the *real* LoopbackAadBroker signs in and now decodes the operator UPN
    // from the JWT access token — the piece that was empty, which left the
    // freshness line without its "by …". Drive the real app with that broker
    // and a JWT-bearing provider, sync, and read the line the operator sees.
    useTallWindow(tester);
    final jwt = _jwt({'upn': 'yvan@school.example'});
    final session = SignInSession(
      LoopbackAadBroker(providerFactory: (_) => StaticAuthProvider(jwt)),
    );
    // Sign in through the real broker → the UPN is decoded off the JWT. This is
    // what production's bootstrap reads into syncedBy (`session.account ?? ''`,
    // covered by the bootstrap unit test); the harness stands in for that one
    // line so the render path can be exercised end-to-end.
    await session.tokenFor(graph);
    expect(session.account, 'yvan@school.example',
        reason: 'the loopback broker now resolves the operator UPN');
    final harness = ReconcileHarness(syncedBy: session.account ?? '');

    await tester.pumpWidget(AccountManagerApp(
      session: session,
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The freshness line names the signed-in operator…
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
    expect(find.textContaining('Last sync — WISA'), findsOneWidget);
    expect(find.textContaining('by yvan@school.example'), findsOneWidget);
    // …and the terminal "Sync complete" line names them too (#169).
    expect(
      find.textContaining('Operator: yvan@school.example'),
      findsOneWidget,
    );
  });

  testWidgets(
      'a sync whose shared-store persist stalls still finishes: Synchronise '
      're-enables and the timeout is surfaced in the log (#168)',
      (WidgetTester tester) async {
    // The real app over the offline harness, but the LinkedStore write hangs
    // (the ~9.6k-doc persist that wedged the pass). The controller must not stay
    // stuck in `linking` with Synchronise disabled forever — it times out the
    // persist, surfaces it, and returns to ready.
    useTallWindow(tester);
    final stalling = StallingLinkedStore();
    final harness = ReconcileHarness(
      controllerStore: stalling,
      persistTimeout: const Duration(milliseconds: 300),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    // Start the sync; while the persist hangs the pass is busy and Synchronise
    // is disabled.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pump();
    expect(harness.controller.busy, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNull,
    );

    // Let the persist timeout elapse (real wall-clock in the live binding), then
    // settle the resulting frame.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    // The persist was reached but hung; the pass recovered rather than wedging.
    expect(stalling.writeAttempted, isTrue);
    expect(harness.controller.busy, isFalse);
    // Synchronise is live again.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );
    // The operator sees the timeout in the log panel, not silence.
    expect(find.textContaining('timed out'), findsOneWidget);
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

    // The departed account is browsed on the Actions tab, under the
    // "Niet toegewezen" → "Overig" → "Zonder klas" bucket.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Niet toegewezen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar Overig'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Zonder klas'));
    await tester.tap(find.text('Zonder klas'));
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
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
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
    final allKinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind);
    expect(allKinds, isNot(contains('RemoveStudentFromAzure')),
        reason: 'the account is still in the group ⇒ Azure is kept');

    // Browse it on the Actions tab: because school 2 is one we do NOT manage,
    // its node is kept out of the drill-down (#178). The departed student is
    // re-bucketed to "Niet toegewezen" so its Smartschool cleanup stays
    // actionable — never surfacing a non-managed school node.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('School 2'), findsNothing,
        reason: 'a school we do not manage never appears in Actions (#178)');
    await tester.tap(find.text('Niet toegewezen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar Overig'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Zonder klas'));
    await tester.tap(find.text('Zonder klas'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('entry-student-${entry.targetId}')),
        findsOneWidget);

    // Apply all: the Smartschool departure writes against the recording SOAP
    // transport; Azure (Graph) is never called.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
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
      'the Actions drill-down hides a school the operator does not manage in '
      'Settings, re-bucketing its student to the leaver group (#178)',
      (WidgetTester tester) async {
    // A student enrolled in school 2, fully present in our Smartschool + Azure.
    // The WISA schools carry no MarkAsOurs flag, so ownership comes solely from
    // the Settings-derived managed set the applier is wired with — the exact
    // "persisted but never consumed" wiring #178 closes. Here only school 1 is
    // managed, so the school-2 student is groupOnly.
    useTallWindow(tester);
    final harness = managedSchoolsHarness(ourSchoolIds: const {1});
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

    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Overzicht'), findsOneWidget);
    // The non-managed school is not a node in the drill-down…
    expect(find.text('School 2'), findsNothing,
        reason: 'school 2 is not managed → no node in Actions');
    // …but the departed student's cleanup stays actionable under the leaver
    // bucket rather than vanishing entirely.
    expect(find.text('Niet toegewezen'), findsOneWidget);
  });

  testWidgets(
      'marking that same school as managed in Settings surfaces it in the '
      'Actions drill-down end-to-end (#178)', (WidgetTester tester) async {
    // The very same school-2 student, but now school 2 is one of ours: it must
    // appear as a school node and the student sits under it. Proves the managed
    // set from Settings — not the snapshot MarkAsOurs flags — drives which
    // schools show.
    useTallWindow(tester);
    final harness = managedSchoolsHarness(ourSchoolIds: const {1, 2});
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

    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('School 2'), findsOneWidget,
        reason: 'managing school 2 surfaces it in Actions (#178)');
    await tester.tap(find.text('School 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.text('3C'), findsWidgets);
  });

  testWidgets(
      'the Actions view splits Personeel and Leerlingen into tabs end-to-end: '
      'staff drill in one tab, students in the other (#179)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window: one student plus one WISA staff
    // member so both families have a rollup node. The Actions view must browse
    // them as two separate workflows — a horizontal tab bar with a per-family
    // drill-down — not one combined rollup.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
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

    // On the Actions tab the family tab bar carries both families.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('actions-tab-leerlingen')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-tab-personeel')), findsOneWidget);

    // Default Leerlingen tab: the student school node drills; the staff node
    // does not appear here.
    expect(
        find.byKey(const ValueKey('rollup-school-school|1')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-school-school|staff')), findsNothing);

    // Switch to Personeel and drill down to the staff member — the drill-down
    // is preserved within the tab, showing only staff.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-school-school|1')), findsNothing);
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
    expect(staffSchool, findsOneWidget);

    await tester.ensureVisible(staffSchool);
    await tester.tap(staffSchool);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('rollup-grade-grade|staff|Personeel')));
    await tester.pumpAndSettle();
    final staffClass = find
        .byKey(const ValueKey('rollup-class-class|staff|Personeel|Personeel'));
    await tester.ensureVisible(staffClass);
    await tester.tap(staffClass);
    await tester.pumpAndSettle();

    // The staff member's account is browsed inside the Personeel tab.
    expect(find.text('Anna Smit'), findsWidgets);
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
  });

  testWidgets(
      'the Passwords view generates a class password on demand and resets a '
      'staff password across its two tabs end-to-end (#180)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window: the Smartschool snapshot carries a
    // "Leerlingen" class tree and a "Personeel" group (seeded so the screen has
    // its tree without a full sync). The reworked Passwords view must generate a
    // fresh class password on demand (Leerlingen) and reset a staff password
    // (Personeel) — pushing both live through the recording backends.
    useTallWindow(tester);
    final harness = ReconcileHarness(ssInitial: passwordsSnap());
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Open the Passwords view: the two family tabs render.
    await tester.tap(find.text('Passwords'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passwords-tab-leerlingen')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passwords-tab-personeel')), findsOneWidget);

    // Leerlingen: pick the class, check a student's Smartschool target, then
    // generate on demand → confirm. The password is pushed live and queued.
    await tester.tap(find.byKey(const ValueKey('password-class-3C')));
    await tester.pumpAndSettle();
    expect(find.text('jane'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('passwords-cell-jane-smartschool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate-confirm')));
    await tester.pumpAndSettle();

    expect(harness.passwordBackends.smartschoolPushes, hasLength(1));
    expect(harness.passwordBackends.smartschoolPushes.single.$1, 'jane');
    expect(find.byKey(const ValueKey('passwords-message')), findsOneWidget);

    // Personeel: select a staff member and reset both passwords. The filter
    // TextField's blinking cursor keeps pumpAndSettle from settling, so drive
    // the dialog with explicit frames.
    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-staff-anna.smit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-staff-reset-both')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .tap(find.byKey(const ValueKey('passwords-staff-reset-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Both backends were pushed with one shared staff password.
    expect(
        harness.passwordBackends.smartschoolPushes
            .where((p) => p.$1 == 'anna.smit'),
        hasLength(1));
    expect(harness.passwordBackends.azurePushes, hasLength(1));
  });

  testWidgets(
      'the Passwords personeel tab defaults its filter to Voornaam and lists '
      'staff alphabetically end-to-end (#186)', (WidgetTester tester) async {
    // The real app, real fonts, real window: a "Personeel" group holding three
    // staff seeded out of alphabetical order across mixed casing. On opening the
    // personeel tab the filter selector must default to Voornaam and the list
    // must render sorted by the displayed "Voornaam Naam" name.
    useTallWindow(tester);
    final harness = ReconcileHarness(ssInitial: staffOrderSnap());
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Passwords'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    // The filter selector renders its default selection: Voornaam.
    expect(find.text('Voornaam'), findsOneWidget);

    // The tiles render top-to-bottom in alphabetical order: alice, Bob, Charlie.
    double y(String uid) =>
        tester.getTopLeft(find.byKey(ValueKey('passwords-staff-$uid'))).dy;
    expect(y('alice'), lessThan(y('bob')));
    expect(y('bob'), lessThan(y('charlie')));
  });

  testWidgets(
      'the Smartschool address action only fires on a real field drift and its '
      'diff shows the differing field, not an identical row (#153)',
      (WidgetTester tester) async {
    // WISA (country hardcoded 'BE', empty bus number → null) vs Smartschool
    // (free-text country, empty-string bus number). The student is in the same
    // class in both systems, so the address is the only possible drift.
    useTallWindow(tester);
    const wisaAddr = Address(
      street: 'Koophandelstraat',
      houseNumber: '32',
      postalCode: '3271', // WISA says 3271…
      city: 'Scherpenheuvel',
      country: 'BE',
    );
    const ssAddr = Address(
      street: 'Koophandelstraat',
      houseNumber: '32',
      houseNumberAdd: '', // empty vs WISA's null — must not count as drift
      postalCode: '3270', // …Smartschool still has 3270 (the real drift)
      city: 'Scherpenheuvel',
      country: 'België', // differs from 'BE' — must NOT drive the action
    );
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent(address: wisaAddr)]),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss')],
        accounts: [ssAccount(address: ssAddr)],
        memberships: [member('jane', '3C_ss')],
      ),
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

    // Browse the student on the Actions tab, drilling into her class (3C).
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('School 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();

    // The address action is present (postalCode really drifted).
    expect(find.text('Wijzig het adres in Smartschool'), findsWidgets);

    // Expand the student entry: the previously-hidden differing field shows,
    // and unchanged fields are not rendered as misleading "X → X" rows.
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final entryKey = ValueKey('entry-student-${entry.targetId}');
    await tester.ensureVisible(find.byKey(entryKey));
    await tester.tap(find.byKey(entryKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('postalCode: 3270 → 3271'), findsOneWidget);
    expect(find.textContaining('country'), findsNothing);
    expect(find.textContaining('street:'), findsNothing);
  });

  testWidgets(
      "a large class's actions virtualize in the real app: only a bounded "
      'number of entry tiles build, and scrolling loads more (#111/#154)',
      (WidgetTester tester) async {
    // A September-changeover-scale pending set (a thousand WISA-departed
    // accounts, all in one bucket) in the real, laid-out app. Drilling into the
    // class builds only the on-screen tiles through the lazy sliver list.
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

    // Browse them on the Actions tab: drill into their "Zonder klas" bucket.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Niet toegewezen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar Overig'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Zonder klas'));
    await tester.tap(find.text('Zonder klas'));
    await tester.pumpAndSettle();

    // All 1000 accounts sit in this one class, but only a small window builds.
    expect(harness.controller.classroomPendingEntries, hasLength(1000));
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
    final entries = harness.controller.classroomPendingEntries;
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
      'the operator drags the log divider to grow the log panel end-to-end '
      '(#152)', (WidgetTester tester) async {
    // The real app composition — real fonts, real window, real Column layout —
    // is where a resizable divider that "works" in a widget test can drift: the
    // handle sits between a flexible scroll area and the fixed-height panel.
    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reconcile'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('reconcile-log-panel'));
    final handle = find.byKey(const ValueKey('reconcile-log-resize'));
    expect(panel, findsOneWidget);
    expect(handle, findsOneWidget);

    // Opens at the default height, then dragging the handle up enlarges it by
    // the drag distance — the operator can read a multi-line Cosmos error.
    final double initial = tester.getSize(panel).height;
    expect(initial, 160);
    await tester.drag(handle, const Offset(0, -200),
        touchSlopX: 0, touchSlopY: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 360);
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
    expect(find.text('Overview'), findsOneWidget);
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

    // The overview lives on the Actions tab now — rendered straight from the
    // store, no Synchronise tapped.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
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
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
  });

  testWidgets(
      'a passive session renders the category overview on Reconcile from the '
      'stored rollups, with no pull and no link() (#163)',
      (WidgetTester tester) async {
    // Session 1 (offline harness) syncs and materializes the shared view — the
    // rollups the passive overview reads — into stores both sessions share.
    useTallWindow(tester);
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

    // The per-category overview renders straight from the stored rollups — no
    // Synchronise tapped, and link() is never called in a passive session.
    expect(find.text('Overview'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-category-staff')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-groups')),
        findsOneWidget);
    // The one fixture student is summed from the rollup with a pending indicator.
    expect(find.text('2 openstaande acties'), findsOneWidget);
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');
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

    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();

    // The class-group node is part of the shared overview on the Actions tab,
    // straight from the store — no Synchronise tapped.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('Klasgroepen'), findsWidgets);

    // Drilling into it lists the orphan Smartschool classes with their notice.
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions-groups-back')), findsOneWidget);
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

    // The shared per-system freshness line renders in its prominent row (#162)
    // straight from the store (who last synced each system — not this passive
    // session), proving it survives a restart.
    expect(find.byKey(const ValueKey('reconcile-freshness')), findsOneWidget);
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
    await tester.tap(find.text('Actions'));
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
      'creating an account captures its password into the shared queue, which '
      'the Passwords view surfaces as a printable sheet and drains on export '
      '(#105/#180)', (WidgetTester tester) async {
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
    expect(await harness.passwordQueue.load(), isEmpty);

    // Browse the create on the Actions tab, in the student's class.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('School 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(find.text('Maak een nieuw Smartschool account'), findsWidgets);

    // Apply all for real (against the recording SOAP transport): the create runs
    // and its minted password is captured into the shared queue.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Apply result'), findsOneWidget);
    final queued = await harness.passwordQueue.load();
    expect(queued, hasLength(1),
        reason: 'the created account\'s password landed in the queue');
    expect(queued.single.smartschoolPassword, isNotNull);

    // Switch to the Passwords view: the freshly captured account sheet is
    // surfaced as a printable student sheet (the reworked view no longer shows
    // a per-entry distribute card — the queue feeds the print/CSV exports).
    await tester.tap(find.text('Passwords'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    final exportBtn = find.byKey(const ValueKey('passwords-export-students'));
    expect(
      tester.widget<OutlinedButton>(exportBtn).onPressed,
      isNotNull,
      reason: 'the captured sheet enables the print export',
    );
    expect(find.text('Print leerling-wachtwoorden (1)'), findsOneWidget);

    // Exporting the sheet drains it from the shared queue (saved remainder is
    // empty) and disables the export again.
    await tester.tap(exportBtn);
    await tester.pumpAndSettle();
    expect(await harness.passwordQueue.load(), isEmpty);
    expect(
      tester.widget<OutlinedButton>(exportBtn).onPressed,
      isNull,
      reason: 'the queue is drained, so nothing left to print',
    );
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
    // The known-school list lives under the Wisa tab now (#140); open it and
    // bring the seeded school's checkbox into view before reading it.
    await openSettingsTab(tester, 'settings-tab-wisa');
    final ourBox = find.byKey(const ValueKey('settings-wisa-school-42-ours'));
    await tester.ensureVisible(ourBox);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(ourBox).value, isFalse);

    // Mark it managed and save (the Save action sits in the shared header).
    await tester.tap(ourBox);
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
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);

    // Fetch: both schools render by name in the grid, the stored password was
    // resolved.
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(fetcher.calls, 1);
    expect(fetcher.lastPassword, 'stored-pw');
    expect(find.text('Sint-Jan'), findsOneWidget);
    expect(find.text('Sint-Pieter'), findsOneWidget);

    // Mark one fetched school managed and save; it lands in the store with its
    // name, no id ever typed by hand.
    final picked = find.byKey(const ValueKey('settings-wisa-school-7-ours'));
    await tester.ensureVisible(picked);
    await tester.tap(picked);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await settings.store.load();
    final managed = saved.wisaSchools.firstWhere((p) => p.schoolId == 7);
    expect(managed.name, 'Sint-Pieter');
    expect(managed.ours, isTrue);
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

  testWidgets(
      'the Settings secret fields read "(alleen schrijven)" end-to-end, not '
      'the ungrammatical "(schrijf-alleen)" (#143)',
      (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams — real fonts,
    // real window, real tab navigation, which is where the rendered label copy
    // is exercised as the operator actually sees it.
    useTallWindow(tester);
    final settings = SettingsHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // WISA password label carries the corrected Dutch; the old calque is gone.
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(find.text('Wachtwoord (alleen schrijven)'), findsOneWidget);
    expect(find.text('Wachtwoord (schrijf-alleen)'), findsNothing);

    // Same for the Smartschool passphrase label.
    await openSettingsTab(tester, 'settings-tab-smartschool');
    expect(find.text('Passphrase (alleen schrijven)'), findsOneWidget);
    expect(find.text('Passphrase (schrijf-alleen)'), findsNothing);
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

  testWidgets(
      'the Actions Personeel classroom filters by name and by the '
      'only-with-actions toggle end-to-end, combining both (#187)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window over a passive session: three staff
    // seeded into the one synthetic Personeel class — two share the surname
    // "Smit" (one carrying an action, one not) and one has a distinct voornaam.
    // The operator narrows the list by name and by the has-actions toggle, and
    // the two filters combine.
    useTallWindow(tester);
    final store = await seededLinkedStore([
      matStaff(id: 't1', label: 'Anna Smit', withAction: true),
      matStaff(id: 't2', label: 'Bram Jansen', withAction: false),
      matStaff(id: 't3', label: 'Clara Smit', withAction: false),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Open the Actions tab (passive overview from the store), go to Personeel,
    // and drill into the single staff class.
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rollup-school-school|staff')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('rollup-grade-grade|staff|Personeel')));
    await tester.pumpAndSettle();
    final staffClass = find
        .byKey(const ValueKey('rollup-class-class|staff|Personeel|Personeel'));
    await tester.ensureVisible(staffClass);
    await tester.tap(staffClass);
    await tester.pumpAndSettle();

    // All three staff render, and the Personeel tab carries the name search.
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Bram Jansen'), findsOneWidget);
    expect(find.text('Clara Smit'), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-search')), findsOneWidget);

    // Search on the surname "Smit": both Smits match, Jansen drops out.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsOneWidget);
    expect(find.text('Bram Jansen'), findsNothing);

    // Combine with the only-with-actions toggle: only Anna keeps an action, so
    // Clara (name-matched but action-free) drops too.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    expect(find.text('Bram Jansen'), findsNothing);
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

/// An unsigned JWT (`header.payload.signature`) carrying [claims] — the real
/// loopback broker decodes the operator UPN off its payload (#169). The
/// signature is never verified, so a literal `sig` segment suffices.
String _jwt(Map<String, Object?> claims) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none', 'typ': 'JWT'})}.${seg(claims)}.sig';
}

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
