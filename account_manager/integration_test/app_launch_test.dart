// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:account_actions/account_actions.dart'
    show
        ActionOutcome,
        ReleaseStaffFromAzureSchool,
        RemoveStaffFromAzure,
        RemoveStaffFromSmartschool;
import 'package:account_core/account_core.dart' show Address, GroupType, Origin;
import 'package:account_manager/main.dart' as app;
import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:account_manager/src/screens/class_groups_screen.dart';
import 'package:account_manager/src/screens/home_screen.dart';
import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/screens/system_indicator.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        AzureConnection,
        ChangeSignal,
        CosmosThrottleGovernor,
        InMemoryLinkedStore,
        InMemorySettingsStore,
        InMemorySignalHub,
        LiveSettings,
        MaterializedAccount,
        SecretRef,
        SignalRConfig,
        SignalRRequest,
        SignalRResponse,
        SignalRSocket,
        SignalRSocketConnector,
        SignalRSubscriber,
        SignalRTransport,
        SmartschoolClassTree,
        StaticSignalRTokenProvider,
        WisaConnection,
        WisaSchoolProfile,
        WisaSchoolProfileLabel,
        WorkDateSetting,
        signalRRecordSeparator,
        staffPartition;
import 'package:azure_api/azure_api.dart'
    show AzureCredentials, StaticAuthProvider;
import 'package:smartschool_api/smartschool_api.dart'
    show DiscardSmartschoolGroup, SmartschoolConnector, SmartschoolSnapshot;
import 'package:wisa_api/wisa_api.dart'
    show
        DontImportClass,
        DontImportUserFromWisa,
        WisaImportRule,
        WisaSchool,
        WisaSnapshot,
        parseSchoolRow;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Authors one Smartschool import rule the way the operator does (#202): the
  /// **Toevoegen** menu, the rule type keyed [kind], then the group-name prompt.
  Future<void> addSmartschoolRule(
    WidgetTester tester,
    String kind,
    String groupName,
  ) async {
    final add = find.byKey(const ValueKey('settings-ss-rule-add'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-ss-rule-add-$kind')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-rule-name')),
      groupName,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-confirm')));
    await tester.pumpAndSettle();
  }

  /// Authors one WISA import rule the way the operator does (#273): the
  /// **Toevoegen** menu, the rule type keyed [kind], then the field prompt —
  /// one value per field, in order.
  Future<void> addWisaRule(
    WidgetTester tester,
    String kind,
    List<String> values,
  ) async {
    final add = find.byKey(const ValueKey('settings-wisa-rule-add'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-wisa-rule-add-$kind')));
    await tester.pumpAndSettle();
    for (var i = 0; i < values.length; i++) {
      await tester.enterText(
        find.byKey(ValueKey('settings-wisa-rule-value-$i')),
        values[i],
      );
    }
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-wisa-rule-confirm')));
    await tester.pumpAndSettle();
  }

  /// The linker's id of the account the flat Acties list shows as [label] —
  /// what its row, its cells and its details pane are keyed by (#295).
  String accountId(ReconcileHarness harness, String label) =>
      harness.controller.linkedAccounts
          .firstWhere((a) => a.label == label)
          .id
          .value;

  /// Selects one account in the flat Acties list, which is what puts its
  /// decisions in the details pane beside it (#295).
  Future<void> selectAccount(WidgetTester tester, String id) async {
    final Finder row = find.byKey(ValueKey('account-row-$id'));
    await tester.ensureVisible(row);
    await tester.tap(row);
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
    expect(find.text('Start'), findsOneWidget);

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

    // The Start placeholder is the first screen the operator lands on, and it
    // was the last one left in English (#265) — eyebrow and body both.
    expect(find.text('ARCADIA · ACCOUNTSYNCHRONISATIE'), findsOneWidget);
    expect(
      find.textContaining('Stemt gebruikersaccounts en klasgroepen op elkaar '
          'af tussen WISA, Smartschool en Azure AD / Office 365.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('te beginnen met aanmelden en het tabblad '
          'Synchronisatie.'),
      findsOneWidget,
    );
    expect(find.textContaining('Reconciles user accounts'), findsNothing);
    expect(find.textContaining('Phase C slice'), findsNothing);

    // Every destination on the rail names itself in the operator's language
    // (#257). The rail is read together with the heading it leads to, and it
    // used to read Home / Reconcile / Actions over pages titled in Dutch.
    for (final String label in <String>[
      'Start',
      'Synchronisatie',
      'Acties',
      'Klasgroepen',
      'Wachtwoorden',
      'Instellingen',
    ]) {
      expect(find.text(label), findsOneWidget,
          reason: '"$label" is the rail label for its destination');
    }

    // With no AAD config each screen renders its "not configured" panel
    // instead of bootstrapping — in Dutch on every one of them (#253/#257),
    // since a panel standing in for a view is as operator-facing as the view.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byType(ReconcileScreen), findsOneWidget);
    expect(find.text('Niet geconfigureerd'), findsOneWidget);

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionsScreen), findsOneWidget);
    expect(find.text('Niet geconfigureerd'), findsOneWidget);

    await tester.tap(find.text('Wachtwoorden'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    expect(find.text('Niet geconfigureerd'), findsOneWidget);

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Niet geconfigureerd'), findsOneWidget);
  });

  testWidgets(
      'the Synchronisatie tab names its own controls in the operator\'s '
      'language end-to-end, log panel and smart-diff notice included (#265)',
      (WidgetTester tester) async {
    // #257 renamed the rail destination and the heading under it, but not the
    // screen's own controls — so the tab read Dutch and the buttons on it read
    // English. Driven through the real shell on purpose: these strings are read
    // together with the rail label that leads to them, which is exactly the
    // composition a widget test of ReconcileScreen alone cannot see.
    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // The two buttons under the heading, and the explainer that names them in
    // prose — which #265 translated but could not assert, because the passive
    // store read moved the phase off `idle` before the operator's first frame
    // and the paragraph never reached the screen (fixed in #275).
    expect(find.text('Synchroniseer'), findsOneWidget);
    expect(find.text('Controleer op drift'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-explainer')), findsOneWidget);
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

    // Not one English label survives on the screen.
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

    // A sync heads the counts section the way the Acties tree heads its own —
    // and retires the introduction, the banner now having a pass to report on.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-explainer')), findsNothing);

    // A second pass over unchanged WISA raises the smart-diff notice, which
    // now says what the Log line beside it says (#258).
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('WISA is ongewijzigd sinds de vorige '
          'synchronisatie — geen accountwijzigingen nodig.'),
      findsWidgets,
    );
    expect(find.textContaining('no account changes needed'), findsNothing);
  });

  testWidgets(
      'the reconcile flow runs end-to-end: sign-in → sync → overview on '
      'Reconcile → actions via the Actions tab list → dry-run → apply → '
      'unchanged re-sync (#154/#295)', (WidgetTester tester) async {
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
    await tester.tap(find.text('Synchronisatie'));
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
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    // Scoped to her card: since #328 the fixture's two Smartschool-only classes
    // each propose a delete, so the class-groups card carries the same count.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reconcile-category-students')),
        matching: find.text('2 openstaande acties'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pending actions'), findsNothing);
    expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-')),
      findsNothing,
      reason: 'Reconcile no longer shows the flat pending-actions list',
    );

    // Switch to the Actions tab: since #295 the actions are one flat,
    // school-wide list of accounts — no jaar → klas tree to walk down.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionsScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.text('Jaar 3'),
      ),
      findsNothing,
      reason: 'the drill-down it replaces is gone',
    );
    // The header is one eyebrow and stops there (#309/#294): the count line is
    // gone, and so is the global "Dry-run alles" / "Alles toepassen" pair that
    // wrote every account in the school off one dialog. Whatever the operator
    // applies, they reach by opening it first.
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.textContaining('openstaande actie(s)'),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('actions-dry-run')), findsNothing);
    expect(find.byKey(const ValueKey('actions-apply')), findsNothing);
    expect(find.text('Dry-run alles'), findsNothing);
    expect(find.text('Alles toepassen'), findsNothing);

    // The one account with work is a row of the list, carrying its class and
    // its three system indicators; selecting it puts its decisions in the
    // details pane beside it, and dry-running from there writes nothing.
    final String id = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-row-$id')),
        matching: find.text('3C'),
      ),
      findsOneWidget,
    );
    await selectAccount(tester, id);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);
    await tester.ensureVisible(find.byKey(ValueKey('entry-dry-run-$id')));
    await tester.tap(find.byKey(ValueKey('entry-dry-run-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van de dry-run'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply it: confirm the dialog, the Smartschool write happens for real.
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);

    // Back on Reconcile, re-sync with unchanged WISA: the smart diff reports
    // "no changes needed" and leaves Smartschool / Azure unread.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    // The on-screen banner reads word for word the Log line beside it: #265
    // gave it the Dutch #258 had already written for the log.
    expect(
      find.textContaining('WISA is ongewijzigd sinds de vorige '
          'synchronisatie — geen accountwijzigingen nodig.'),
      findsWidgets,
    );
    expect(find.textContaining('no account changes needed'), findsNothing);
    expect(harness.ssSyncs, 1);
    expect(harness.azSyncs, 1);

    // The Log panel is one running account of everything this session did —
    // three pulls, a link, a dry-run, an apply, a second pass — and it reads in
    // one language from top to bottom (#258). Before this it switched halfway:
    // English pull/link/apply lines under the Dutch terminal line #253 wrote.
    expect(find.byKey(const ValueKey('reconcile-log-panel')), findsOneWidget);
    for (final String line in <String>[
      'WISA ophalen…',
      'Smartschool ophalen…',
      'Azure AD ophalen…',
      'WISA is ongewijzigd sinds de vorige synchronisatie — '
          'geen accountwijzigingen nodig.',
      'Gekoppeld: ',
      'Dry-run gestart voor ',
      'Dry-run klaar: ',
      'Toepassen gestart voor ',
      'Toepassen klaar: ',
      'Sync voltooid — ',
    ]) {
      expect(find.textContaining(line), findsWidgets, reason: line);
    }
    // …and not one entry the pass wrote is still the English it used to be.
    final List<String> logged =
        harness.log.entries.map((e) => e.message).toList();
    for (final String english in <String>[
      'Syncing ',
      'WISA sync done',
      'WISA is unchanged',
      'Checking ',
      'Linked: ',
      'Apply started',
      'Apply finished',
      'Dry-run started',
      'Dry-run finished',
    ]) {
      expect(
        logged.where((String m) => m.startsWith(english)),
        isEmpty,
        reason: english,
      );
    }
  });

  testWidgets(
      'a Synchroniseer over the production connectors fills the Log panel with '
      'Dutch to the bottom — the connector packages included (#266)',
      (WidgetTester tester) async {
    // #258 made the app layer's lines Dutch, which left the panel switching
    // language one layer *down*: `packages/wisa_api`, `smartschool_api` and
    // `azure_api` take an `ILog` at construction and bootstrap hands them this
    // very LogBuffer, so a single Synchroniseer still produced Dutch app lines
    // over English connector ones.
    //
    // All three pulls here are the **production** ones — a real WisaConnector,
    // SmartschoolConnector and AzureConnector over scripted wires — so what the
    // panel renders is what the packages themselves wrote, not a fixture.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisaTransport: RecordingWisaSoap(),
      smartschoolTransport: GroupTreeSoap(),
      azureTransport: StaleDeltaTokenGraph(),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reconcile-log-panel')), findsOneWidget);
    final List<String> logged =
        harness.log.entries.map((e) => e.message).toList();

    // One line from each of the three packages, exactly as it was written.
    for (final String line in <String>[
      // wisa_api — the school named by its short code, as since #208.
      'Klassen opgehaald uit S1.',
      '1 leerling(en) opgehaald uit S1.',
      '0 personeelsleden opgehaald uit S1.',
      // smartschool_api — the wire answers code 19 for every group.
      'Geen rechtstreekse accounts in School.',
      // azure_api — both managers, on the full-read path.
      'Azure: 0 groepen opgehaald voor "GBS".',
      'Azure: 1 gebruikers opgehaald voor "GBS".',
    ]) {
      expect(logged, contains(line), reason: line);
    }

    // …and they really are on screen, in the panel, under the app's own Dutch.
    expect(find.textContaining('leerling(en) opgehaald uit S1.'), findsWidgets);
    expect(find.textContaining('Geen rechtstreekse accounts in'), findsWidgets);
    expect(find.textContaining('gebruikers opgehaald voor'), findsWidgets);
    expect(find.textContaining('WISA opgehaald: '), findsWidgets);
    expect(find.textContaining('Gekoppeld: '), findsWidgets);

    // Not one entry of the pass — at any severity — is still the English the
    // connectors used to write.
    for (final String english in <String>[
      'Loading ',
      'succeeded.',
      'No direct accounts',
      'Added ',
      'Azure: loaded ',
      'Azure: delta for',
      'Connection Succeeded',
      'empty result',
    ]) {
      expect(
        logged.where((String m) => m.contains(english)),
        isEmpty,
        reason: english,
      );
    }
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

    await tester.tap(find.text('Synchronisatie'));
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

  /// Syncs on Reconcile and lands on the Actions tab, the way the operator gets
  /// to the apply affordances.
  Future<void> syncThenOpenActions(WidgetTester tester) async {
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
  }

  // The bulk affordance that stood where the Acties header's global "Alles
  // toepassen" used to (#294) comes in two shapes now: the Klasgroepen cohort
  // headers, which the class-inventory scenarios below drive directly, and — on
  // Acties since #296 — a per-decision "Toepassen op alle" that filters the flat
  // list down to its cohort before offering a confirmation. The run below is
  // that one, end to end.

  testWidgets(
      'a decision applied across the whole school shows its cohort first, and '
      'writes that decision alone end-to-end (#296)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over the real Smartschool and
    // Graph write paths. The September rollover in miniature: three students
    // moved up into `4A` while Smartschool still has all three in last year's
    // `3C`, so every one of them needs the same class change — and Sam alone
    // also has a stale Office 365 display name.
    //
    // Only a full run puts the two halves of #296 on screen in the order that
    // matters. The count on the button is resolved school-wide by the
    // controller, the rows it promises are rendered by the screen out of a
    // *filtered* list, and the write is decided a third time by the pass. This
    // walks it the way the operator does: narrow the list to one student, arm
    // the cohort from their card, and check that the other two are now on
    // screen — before anything is confirmed, let alone written.
    useTallWindow(tester);
    final harness = rolloverHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final String sam = accountId(harness, 'Sam Sels');
    final String sara = accountId(harness, 'Sara Segers');
    final String tom = accountId(harness, 'Tom Tas');
    Finder row(String id) => find.byKey(ValueKey('account-row-$id'));

    // The operator is looking at Sam alone.
    await tester.enterText(find.byKey(const ValueKey('actions-search')), 'Sam');
    await tester.pumpAndSettle();
    expect(row(sam), findsOneWidget);
    expect(row(sara), findsNothing);

    await selectAccount(tester, sam);

    // His card carries two decisions. Only the class move is sanctioned for a
    // school-wide pass (#293) — a rename is a judgement call — and the button
    // counts the school, not the search box.
    final Finder rename = find.byKey(ValueKey('decision-apply-all-student-'
        '$sam-0'));
    final Finder moveAll = find.byKey(ValueKey('decision-apply-all-student-'
        '$sam-1'));
    expect(rename, findsNothing);
    await tester.ensureVisible(moveAll);
    expect(
      find.descendant(
          of: moveAll, matching: find.text('Toepassen op alle (3)')),
      findsOneWidget,
    );

    // Pressing it writes nothing. It shows the cohort: the list is now the
    // three accounts the pass would touch, and the search box that was hiding
    // two of them has stood down.
    await tester.tap(moveAll);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('actions-cohort-banner')), findsOneWidget);
    expect(
      find.text('Wijzig de klas in Smartschool — 3 account(s) in de hele '
          'school'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('actions-search')), findsNothing);
    for (final id in <String>[sam, sara, tom]) {
      await tester.ensureVisible(row(id));
      expect(row(id), findsOneWidget);
    }
    expect(
        harness.soap.soapActions.where((a) => a.endsWith('#saveUserToClass')),
        isEmpty);

    // The confirmation names that one decision: three Smartschool writes, and
    // no claim on Office 365. Scoped to the dialog, because the cards behind it
    // lead each line with the system it writes to (#298).
    await tester.tap(find.byKey(const ValueKey('actions-cohort-apply')));
    await tester.pumpAndSettle();
    final Finder confirmation = find.byType(AlertDialog);
    expect(
      find.descendant(
          of: confirmation, matching: find.textContaining('3 wijzigingen')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: confirmation, matching: find.textContaining('Office 365')),
      findsNothing,
      reason: "summing every decision on every card would quote Sam's rename "
          'and then not write it',
    );

    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Three class moves against the real SOAP transport, each with its own
    // payload; not one Graph write, because the rename was never armed.
    expect(
      harness.soap.soapActions.where((a) => a.endsWith('#saveUserToClass')),
      hasLength(3),
    );
    expect(harness.graph.requests.where((r) => r.method == 'PATCH'), isEmpty);
    expect(harness.controller.applyResults, hasLength(3));
    expect(find.text('Resultaat van het toepassen'), findsWidgets);

    // The review is over — what it was built from has been written — so the
    // list has its own controls back.
    expect(find.byKey(const ValueKey('actions-cohort-banner')), findsNothing);
    expect(find.byKey(const ValueKey('actions-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a class our own WISA school does not have never becomes a move, and '
      'never joins the rollover cohort, end-to-end (#333)',
      (WidgetTester tester) async {
    // The same rollover as above, with the case the guard exists for mixed in.
    // Three students still sitting in last year's `3C` in Smartschool:
    //   Sam  → `4A`    ours, and Smartschool has the class already.
    //   Sara → `4B`    ours, and Smartschool has yet to be given the class.
    //   Tom  → `3HWa`  a class only the sibling group school has.
    //
    // Only a full run shows what the guard is actually protecting: the count on
    // "Toepassen op alle", the cohort the operator reviews behind it, and the
    // writes the confirmation then makes. A foreign class name that survives
    // `evaluate` does not merely produce one wrong row — it rides along with
    // every legitimate move on the same button.
    //
    // Tom's is a single WISA row, ours, naming another school's class, so #332
    // (which taught the resolver to read the row the linker chose) cannot help
    // here; and `3HWa` is in the Smartschool tree, so `resolveClass` finds it
    // and the write would go straight through. The WISA guard is the only thing
    // between it and a live account.
    useTallWindow(tester);
    final harness = foreignClassMoveHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final String sam = accountId(harness, 'Sam Sels');
    final String sara = accountId(harness, 'Sara Segers');
    final String tom = accountId(harness, 'Tom Tas');
    Finder row(String id) => find.byKey(ValueKey('account-row-$id'));

    List<String> kindsFor(String id) => harness.controller.pendingEntries
        .where((e) => e.family == 'student' && e.targetId == id)
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toList();

    // The two ours-classes moves stand, including the one Smartschool cannot
    // satisfy yet — suppressing *that* one is what over-tightening this guard
    // would look like, and it would gut the action every September.
    expect(kindsFor(sam), contains('MoveToSmartschoolClassGroup'));
    expect(
      kindsFor(sara),
      contains('MoveToSmartschoolClassGroup'),
      reason: '`4B` is ours; Smartschool simply has not been given it yet',
    );
    // The foreign one raises nothing at all — not a failing proposal, silence.
    expect(
      kindsFor(tom),
      isEmpty,
      reason: 'our WISA school has no `3HWa`, so there is nothing to propose',
    );

    // Nowhere in the pass does the foreign class reach a projected value.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .expand((a) => a.changes.fields)
          .expand((f) => <String?>[f.before, f.after]),
      isNot(contains('3HWa')),
    );

    // On screen, from Sam's card: the button counts the school, and it counts
    // two — the third student is not one short of a write, he is not in the
    // cohort at all.
    await selectAccount(tester, sam);
    final Finder moveAll =
        find.byKey(ValueKey('decision-apply-all-student-$sam-0'));
    await tester.ensureVisible(moveAll);
    expect(
      find.descendant(
          of: moveAll, matching: find.text('Toepassen op alle (2)')),
      findsOneWidget,
    );

    // Pressing it reviews before it writes: the cohort is Sam and Sara.
    await tester.tap(moveAll);
    await tester.pumpAndSettle();
    expect(
      find.text('Wijzig de klas in Smartschool — 2 account(s) in de hele '
          'school'),
      findsOneWidget,
    );
    for (final String id in <String>[sam, sara]) {
      await tester.ensureVisible(row(id));
      expect(row(id), findsOneWidget);
    }
    expect(row(tom), findsNothing);

    await tester.tap(find.byKey(const ValueKey('actions-cohort-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // One real Smartschool write, into `4A` and nothing else. Sara's class does
    // not exist in Smartschool yet, so hers fails loudly where an operator can
    // see it — which is the point of gating on WISA rather than on the tree:
    // the move is owed, and the missing class is a card of its own.
    expect(harness.soap.movedToClasses, <String>['4A_ss']);
    expect(
      harness.controller.applyResults!.map((r) => r.outcome),
      containsAll(<ActionOutcome>[ActionOutcome.applied, ActionOutcome.failed]),
    );
    expect(
      harness.controller.applyResults!
          .firstWhere((r) => r.outcome == ActionOutcome.failed)
          .error
          .toString(),
      contains('does not exist'),
    );
    expect(tester.takeException(), isNull);
  });

  // The complement of the run above went the other way (#311). #297 put a
  // checkbox on every row carrying work and a "Selecteer alle zichtbare (N)"
  // bar above the list, so one decision could be run over a hand-picked set —
  // and select-all made that set whatever the filter happened to be showing,
  // which is the objection that removed the global "Alles toepassen" in #294.
  // Worth a full run for the same reason its arrival was: the bar, the row
  // checkboxes and the vertical budget they cost are three different places,
  // and only the real app composes them — in the real fonts, in the real shell,
  // at a real window size.
  testWidgets(
      'Acties offers no selection at all, and the list starts higher for it '
      'end-to-end (#311)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The rollover roster: three students each carrying applyable work, which
    // is precisely when the bar rendered and every one of those rows carried a
    // tick.
    final harness = rolloverHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final String sam = accountId(harness, 'Sam Sels');
    final String sara = accountId(harness, 'Sara Segers');
    final String tom = accountId(harness, 'Tom Tas');

    // Three rows with work on them, and not one tick between them.
    for (final String id in <String>[sam, sara, tom]) {
      expect(find.byKey(ValueKey('account-row-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('account-check-$id')), findsNothing);
    }
    expect(find.byKey(const ValueKey('actions-selection-bar')), findsNothing);
    expect(find.byKey(const ValueKey('actions-select-all')), findsNothing);
    expect(find.byKey(const ValueKey('actions-selection-apply')), findsNothing);
    expect(find.textContaining('Selecteer alle zichtbare'), findsNothing);
    // No checkbox anywhere on the screen: those were the only ones Acties ever
    // rendered, so the whole affordance is gone rather than merely unreachable.
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.byType(Checkbox),
      ),
      findsNothing,
    );

    // What the removal buys, measured where it was spent. The bar was a
    // bordered block between the filter chips and the family tabs on every
    // visit, ticks or no ticks; with it gone nothing but the tabs and their
    // spacing stands between the last chip and the first row.
    final Finder list = find.byKey(const ValueKey('actions-list'));
    final double chipsBottom = tester
        .getRect(find.byKey(const ValueKey('actions-system-azure')))
        .bottom;
    expect(tester.getTopLeft(list).dy - chipsBottom, lessThan(80),
        reason: 'the bordered block alone was 126 logical pixels tall');
    // And the window it gives back: two thirds of a 1080p screen is the list
    // itself, on the view whose whole purpose is the list.
    expect(tester.getSize(list).height, greaterThan(1080 * 0.7));

    // And a row still does the one thing a row is for.
    await selectAccount(tester, sam);
    expect(find.byKey(ValueKey('actions-detail-$sam')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-selection-bar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an apply leaves the operator on the account they applied, reading its '
      'verdict, and lets the row go when they move on end-to-end (#299)',
      (WidgetTester tester) async {
    // The complaint #299 is about is a *composition* one, which is why it gets
    // a full run: the pass is the controller's, the refreshed rows and the
    // details pane are the screen's, and the failure was the seam between them
    // — an account settling its last decision fell out of the filtered list at
    // the exact moment its verdict arrived, so the pane the operator applied
    // from reverted to "kies een account" and a half-succeeded pass read like a
    // clean one. Only the real app puts the pass, the list, the pane and the
    // filters in one frame together.
    //
    // Three students each carry one stale Office 365 display name — work a real
    // Graph write genuinely clears — so a pass really does empty an account's
    // card, which is the whole precondition.
    useTallWindow(tester);
    final harness = crossClassSituationHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final String sam = accountId(harness, 'Sam Sels');
    final String sara = accountId(harness, 'Sara Segers');
    final String tom = accountId(harness, 'Tom Tas');
    Finder row(String id) => find.byKey(ValueKey('account-row-$id'));

    // Apply Sam's one decision from his open details pane.
    await selectAccount(tester, sam);
    final Finder apply = find.byKey(ValueKey('entry-apply-$sam'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // One real Graph PATCH, and it settled his card.
    expect(
        harness.graph.requests.where((r) => r.method == 'PATCH'), hasLength(1));
    expect(harness.controller.pendingEntries.where((e) => e.targetId == sam),
        isEmpty);

    // He is still on the list, under the work filter that no longer matches
    // him, marked as what just happened rather than as an account that was
    // always fine — and his two colleagues are untouched beside him.
    await tester.ensureVisible(row(sam));
    expect(row(sam), findsOneWidget);
    expect(find.byKey(ValueKey('account-done-$sam')), findsOneWidget);
    expect(find.byKey(ValueKey('account-done-$sara')), findsNothing);
    expect(
      tester
          .widget<SystemIndicatorCell>(
              find.byKey(ValueKey('account-cell-$sam-${Origin.azure.name}')))
          .state,
      SystemIndicatorState.inOrder,
      reason: 'the row re-rendered in place off the view the pass relinked',
    );

    // The pane is still his, with the verdict on the card — no re-selection,
    // no sync, and not merely the page-level section that reports the pass.
    expect(find.byKey(ValueKey('actions-detail-$sam')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-detail-empty')), findsNothing);
    final Finder verdict = find.byKey(ValueKey('entry-outcomes-student-$sam'));
    await tester.ensureVisible(verdict);
    expect(
      find.descendant(
          of: verdict, matching: find.text('Wijzig de naam in Azure')),
      findsOneWidget,
    );

    // Moving to an account the pass never touched is the operator done reading
    // it, so the held row lets go and the list is the work list again.
    await selectAccount(tester, sara);
    expect(row(sam), findsNothing);
    expect(row(sara), findsOneWidget);
    expect(row(tom), findsOneWidget);
    expect(find.byKey(ValueKey('actions-detail-$sara')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// Opens the Klasgroepen tab from the navigation rail (#227). The class
  /// inventory is a destination of its own now, not a node inside Acties.
  Future<void> openKlasgroepen(WidgetTester tester) async {
    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();
  }

  /// Syncs on Reconcile and lands on the Klasgroepen tab.
  Future<void> syncThenOpenKlasgroepen(WidgetTester tester) async {
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    await openKlasgroepen(tester);
  }

  /// The text of one line of the modal progress dialog.
  String progressLine(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  final Finder progressDialog =
      find.byKey(const ValueKey('actions-progress-dialog'));

  testWidgets(
      'an apply pass holds the operator in a modal progress dialog naming the '
      'action in flight, and clears when the pass ends (#243)',
      (WidgetTester tester) async {
    // The real app over the offline harness, with the pass parked one action at
    // a time. A rollover pass writes hundreds of accounts sequentially and runs
    // for minutes; its only feedback used to be greyed-out buttons and an
    // indeterminate bar in a page header the operator had scrolled past, and
    // nothing stopped them navigating away mid-write. Composition is the point
    // here: the dialog has to sit over the real shell, in the real font.
    //
    // Driven from one account's two decisions, which since #295 is the longest
    // pass Acties itself can start — the multi-account form lives on the
    // Klasgroepen cohort header until #296 brings it back here.
    useTallWindow(tester);
    final gates = <Completer<void>>[];
    final harness = ReconcileHarness(applyGate: () async {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    });
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final steps = <String>[
      for (final c in entry.choices)
        '${entry.target} — ${c.selected.changes.summary}',
    ];
    expect(steps, hasLength(2));
    await selectAccount(tester, entry.targetId);

    // Idle: no dialog.
    expect(progressDialog, findsNothing);

    final Finder apply = find.byKey(ValueKey('entry-apply-${entry.targetId}'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Parked on the first action: the dialog names how far along the pass is
    // and what is being written right now.
    expect(progressDialog, findsOneWidget);
    expect(gates, hasLength(1));
    expect(find.text('Acties toepassen…'), findsOneWidget);
    expect(progressLine(tester, 'actions-progress-count'), 'Actie 1 van 2');
    expect(progressLine(tester, 'actions-progress-step'), steps[0]);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('actions-progress-bar')),
          )
          .value,
      isNotNull,
      reason: 'determinate, not the motionless sweep this replaces',
    );

    // Modal: the barrier is there and a tap outside does not dismiss it, so the
    // operator cannot scroll or navigate away mid-write.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(progressDialog, findsOneWidget);

    // The text follows the pass onto the second decision.
    gates[0].complete();
    await tester.pumpAndSettle();
    expect(progressLine(tester, 'actions-progress-count'), 'Actie 2 van 2');
    expect(progressLine(tester, 'actions-progress-step'), steps[1]);

    // The pass finishes: the dialog closes by itself, leaving the results.
    gates[1].complete();
    await tester.pumpAndSettle();
    expect(progressDialog, findsNothing);
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a pass whose writes fail still clears the progress dialog (#243)',
      (WidgetTester tester) async {
    // The worst case for a modal: leaving it up after a failed pass would lock
    // the operator out of the whole app, so its lifetime is bound to the pass's
    // future rather than to anything observed about the results.
    useTallWindow(tester);
    final gate = Completer<void>();
    final harness = ReconcileHarness(applyGate: () async {
      await gate.future;
      throw StateError('Smartschool weigerde de schrijfactie');
    });
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    final String id = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, id);
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(progressDialog, findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(progressDialog, findsNothing);
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(
      find.textContaining('Smartschool weigerde de schrijfactie'),
      findsWidgets,
      reason: 'the failure is reported on the page, not behind a stuck modal',
    );
    // The app is usable again: the affordance is live and reachable.
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a completed sync logs a terminal "Sync voltooid … Klaar." line and the '
      'last-sync box renders a row per system end-to-end (#162/#188)',
      (WidgetTester tester) async {
    // The real app composition over the offline harness, driven the way the
    // operator drives it. (Restart survival of the box is covered by the
    // passive-session scenario below and the widget test.)
    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // Before syncing there is no last-sync box yet.
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The terminal ready line is logged (newest-first in the log panel) so the
    // operator knows the pass finished, and it names the pending-action count.
    expect(
      find.textContaining('Sync voltooid — 4 openstaande actie(s). Klaar.'),
      findsOneWidget,
    );
    // The last-sync freshness now renders as a dedicated box headed "Last sync"
    // with one row per system (#188).
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(find.text('Laatste synchronisatie'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-last-sync-smartschool')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-last-sync-azure')),
        findsOneWidget);
    expect(find.textContaining('door operator@school.example'), findsWidgets);

    // A second, unchanged re-sync logs the no-change ready line too.
    harness.wisaResult =
        wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
          'Sync voltooid — geen accountwijzigingen nodig. Klaar.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'the last-sync box shows WISA as a sync and Smartschool/Azure as drift '
      'checks per row, and a Check for drift advances only those two '
      '(#170/#188)', (WidgetTester tester) async {
    // The real app over the offline harness: a first full sync stamps all three
    // systems, then Check for drift re-reads Smartschool/Azure at a later time
    // while WISA keeps its earlier sync stamp. The box must show WISA as a sync
    // and Smartschool/Azure as drift checks — each on its own row — throughout.
    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Collect the text of one system's row.
    String rowText(String system) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(ValueKey('reconcile-last-sync-$system')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .join(' ');

    // After the first full sync all three systems appear on their own rows:
    // WISA as a sync, Smartschool and Azure as drift checks.
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(rowText('wisa'), contains('synchronisatie'));
    expect(rowText('wisa'), isNot(contains('driftcontrole')));
    expect(rowText('smartschool'), contains('driftcontrole'));
    expect(rowText('azure'), contains('driftcontrole'));

    // Check for drift re-pulls Smartschool and Azure at a later time; WISA is
    // not re-pulled, so its sync stamp stays put while the drift pair advances.
    final driftAt = kFixtureDate.add(const Duration(hours: 3));
    harness.ssResult = ssSnap(fetchedAt: driftAt);
    harness.azResult = azSnap(fetchedAt: driftAt);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();

    // The rows still carry the right kinds, and the underlying state proves the
    // drift pair advanced while WISA held its earlier sync time.
    expect(rowText('wisa'), contains('synchronisatie'));
    expect(rowText('smartschool'), contains('driftcontrole'));
    final systems = harness.controller.syncState.systems;
    expect(systems[Origin.wisa]?.at, kFixtureDate);
    expect(systems[Origin.smartschool]?.at, driftAt);
    expect(systems[Origin.azure]?.at, driftAt);
  });

  testWidgets(
      'the last-sync box dates a row that is not from today end-to-end: today '
      "stays time-only, yesterday reads 'gisteren', an older one carries the "
      'date (#192)', (WidgetTester tester) async {
    // The real app, real fonts, real window: the three systems are stamped on
    // three different calendar days. Time-only rendered all three identically,
    // so a WISA pull from last year was indistinguishable from this morning's
    // — the freshness check the operator makes before pressing
    // Synchronise. Composition matters here: the status shares its row with a
    // fixed-width name column and an icon, and a dated stamp is the longest
    // text that row has ever carried.
    useTallWindow(tester);
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 9, 14);
    final DateTime yesterday = DateTime(now.year, now.month, now.day - 1, 8, 5);
    final DateTime lastYear = DateTime(now.year - 1, 8, 15, 16, 40);
    final harness = ReconcileHarness(
      wisa: wisaSnap(fetchedAt: today),
      smartschool: ssSnap(fetchedAt: yesterday),
      azure: azSnap(fetchedAt: lastYear),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
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

    // Today: unchanged — the common case stays short.
    expect(rowText('wisa'), contains('09:14'));
    expect(rowText('wisa'), isNot(contains('/')));
    expect(rowText('wisa'), isNot(contains('gisteren')));

    // Yesterday and an older stamp are now readable as stale at a glance.
    expect(rowText('smartschool'), contains('gisteren 08:05'));
    expect(rowText('azure'), contains('15/08/${now.year - 1} 16:40'));

    // The longer status still lays out on one line per row in the real font:
    // the three rows stay stacked and none has collapsed into the next.
    double rowTop(String system) => tester
        .getTopLeft(find.byKey(ValueKey('reconcile-last-sync-$system')))
        .dy;
    expect(rowTop('wisa'), lessThan(rowTop('smartschool')));
    expect(rowTop('smartschool'), lessThan(rowTop('azure')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      "the Klasgroepen overview's freshness stamp carries the date once the "
      'shared state is no longer from today end-to-end (#192)',
      (WidgetTester tester) async {
    // A passive session over a shared view that was materialized in the past.
    // The header line used to read "Generatie 1 · 02:00 door …",
    // which is exactly as reassuring as a stamp from five minutes ago.
    //
    // Read on Klasgroepen since #309 took the stamp off Acties: it describes
    // the shared state rather than either list, and this is the action view
    // that still carries it.
    useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();

    // Derived independently of the production formatter: the store was stamped
    // at kFixtureDate, which the operator reads on their own clock.
    final DateTime t = kFixtureDate.toLocal();
    final String dm = '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}';
    final String hhmm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    expect(find.textContaining('Generatie 1 · $dm'), findsOneWidget);
    expect(find.textContaining('Generatie 1 · $hhmm'), findsNothing,
        reason: 'a stamp from a past day is never rendered as bare time');
  });

  testWidgets(
      'the operator decoded from the real loopback broker JWT names the last '
      'sync in the last-sync box end-to-end (#169)',
      (WidgetTester tester) async {
    // The production sign-in path on a machine without the native WAM broker:
    // the *real* LoopbackAadBroker signs in and now decodes the operator UPN
    // from the JWT access token — the piece that was empty, which left the
    // last-sync box without its "by …". Drive the real app with that broker
    // and a JWT-bearing provider, sync, and read the box the operator sees.
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The last-sync box names the signed-in operator on its rows…
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.textContaining('door yvan@school.example'), findsWidgets);
    // …and the terminal "Sync voltooid" line names them too (#169).
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

    await tester.tap(find.text('Synchronisatie'));
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
    expect(
      find.textContaining(
        'Het opslaan van het gedeelde overzicht duurde langer dan',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'a persist that Cosmos throttles with 429s still lands the whole shared '
      'view, and the operator sees it slow down rather than fail (#196)',
      (WidgetTester tester) async {
    // The real app, driven the way the operator drives it, over the *production*
    // Cosmos write path — a real HttpCosmosClient and CosmosLinkedStore — with
    // the account answering the middle of the write burst with 429s. Before the
    // fix this ended the pass with "Kon het gedeelde overzicht niet opslaan:
    // CosmosException(429 …)" and left the shared containers holding this sync's
    // accounts next to the previous sync's groups and rollups.
    useTallWindow(tester);
    final wire = ThrottlingCosmosWire(throttleFrom: 30, throttleUntil: 120);
    late final ReconcileHarness harness;
    // Production wires one governor into both the client (which reports every
    // 429) and the store (whose fan-out narrows), reporting into the operator
    // log — bootstrapReconcile does exactly this.
    final governor = CosmosThrottleGovernor(
      onReport: (m) => harness.log.addMessage(Origin.all, m),
    );
    harness = manyDepartedHarness(
      count: 300,
      controllerStore: cosmosLinkedStoreOver(wire, governor: governor),
    );

    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The persist is a few hundred real round trips; let the pass finish.
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
    while (harness.controller.busy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // The account really did throttle this burst.
    expect(wire.throttledResponses, greaterThan(0));

    // The pass finished normally: nothing failed, and the operator's log panel
    // carries the terminal ready line rather than a Cosmos error.
    expect(harness.controller.busy, isFalse);
    expect(
      find.textContaining('Kon het gedeelde overzicht niet opslaan'),
      findsNothing,
    );
    expect(
      harness.log.entries.where((e) => e.isError).map((e) => e.message),
      isEmpty,
    );
    expect(find.textContaining('Sync voltooid'), findsOneWidget);

    // Throttling was reported as progress, not silence (#196.5) — in Dutch
    // like the rest of the panel since #266.
    expect(
      harness.log.entries.map((e) => e.message),
      contains(contains('Cosmos beperkt het tempo')),
    );
    expect(
      harness.log.entries.map((e) => e.message),
      isNot(contains(contains('throttling'))),
    );

    // …and the shared state is *whole*: every account document landed, plus the
    // rollups and the generation bump that tell other operators to read them.
    expect(wire.docCount('linkedAccounts'), 300);
    expect(wire.docCount('rollups'), greaterThan(0));
    expect(wire.docCount('syncState'), greaterThan(0));
    expect(harness.controller.syncState.generation, greaterThan(0));
  });

  testWidgets(
      'a second pass that changed nothing offers the shared store no document '
      'writes at all (#200)', (WidgetTester tester) async {
    // The everyday pass, driven the way the operator drives it, over the
    // *production* Cosmos write path. Before the fix every pass rewrote the
    // whole view wholesale — ~4k account docs plus groups and rollups, nearly
    // all byte-identical to what was already stored — and that is the write
    // burst the serverless account answers with the 429s of #196. This account
    // never throttles, so what is measured here is purely how much the persist
    // offers it.
    useTallWindow(tester);
    // Throttling switched off: far beyond the writes this test makes.
    final wire = ThrottlingCosmosWire(throttleFrom: 1000000);
    final governor = CosmosThrottleGovernor();
    final harness = manyDepartedHarness(
      count: 120,
      controllerStore: cosmosLinkedStoreOver(wire, governor: governor),
    );

    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // The persist is a few hundred real round trips; let each pass finish.
    Future<void> runToIdle() async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      while (harness.controller.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    await runToIdle();

    // The first pass writes the whole view — there is nothing stored yet.
    expect(wire.writesTo('linkedAccounts'), 120);
    final int rollupWrites = wire.writesTo('rollups');
    expect(rollupWrites, greaterThan(0));
    final int generation = harness.controller.syncState.generation;

    // Now "Check for drift": the same three systems, the same linked view, so
    // every document materializes byte-identical to the one already stored.
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();
    await runToIdle();

    // Not one document rewritten…
    expect(wire.writesTo('linkedAccounts'), 120,
        reason: 'an unchanged pass must not re-offer the whole account set');
    expect(wire.writesTo('rollups'), rollupWrites);
    // …while the shared state is still whole, and the unconditional generation
    // bump still tells every passive session to re-read it (#116).
    expect(wire.docCount('linkedAccounts'), 120);
    expect(harness.controller.syncState.generation, greaterThan(generation));
    expect(
      harness.log.entries.where((e) => e.isError).map((e) => e.message),
      isEmpty,
    );
    // The operator is told the pass was a no-op rather than seeing silence —
    // in Dutch, like the rest of the panel, since #266.
    expect(
      harness.log.entries.map((e) => e.message),
      contains(contains('Opslaan van accounts: 120 ongewijzigd')),
    );
    expect(
      harness.log.entries.map((e) => e.message),
      isNot(contains(contains('Persisting'))),
    );
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The departed account is one row of the flat Actions list, filed under the
    // "Zonder klas" bucket a leaver falls into.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // One entry for the departed account (not two independent rows).
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    expect(entry.choices.single.isChoice, isTrue,
        reason: 'unregister vs delete collapse into a single choice');
    expect(find.byKey(ValueKey('account-row-$id')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-row-$id')),
        matching: find.text('Zonder klas'),
      ),
      findsOneWidget,
    );

    // Select it, choose delete (the non-default), apply just this row.
    await selectAccount(tester, id);
    await tester
        .tap(find.byKey(ValueKey('alt-$id-DeleteStudentFromSmartschool')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
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

    await tester.tap(find.text('Synchronisatie'));
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
    // the student has no class of ours, so the row files them under "Zonder
    // klas" and their Smartschool cleanup stays actionable (#178).
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('School 2'), findsNothing,
        reason: 'a school we do not manage never appears in Actions (#178)');
    final Finder row = find.byKey(ValueKey('account-row-${entry.targetId}'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Zonder klas')),
        findsOneWidget);

    // Apply the row: the Smartschool departure writes against the recording
    // SOAP transport; Azure (Graph) is never called.
    await selectAccount(tester, entry.targetId);
    await tester
        .ensureVisible(find.byKey(ValueKey('entry-apply-${entry.targetId}')));
    await tester.tap(find.byKey(ValueKey('entry-apply-${entry.targetId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);
    expect(harness.graph.requests, isEmpty, reason: 'Azure account is kept');
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
    expect(summaries, isNot(contains('Verwijder Azure account')));
  });

  testWidgets(
      'a student enrolled in two WISA schools gets one card, offering only the '
      'provisioning work (#318)', (WidgetTester tester) async {
    // The screenshot on the report: one card offering "Maak een nieuw Office
    // 365 account" *and* the Smartschool departure either/or — create this
    // student's account and unregister it in the same breath, for someone
    // enrolled with us right now. Two linked records carrying one
    // `LinkedAccountId`, because both of the person's WISA rows keyed on
    // `wisa:1`, and the card is assembled from that id.
    //
    // Driven end-to-end because the collapse is invisible below this level: the
    // linker's own records are individually coherent, and it is only where the
    // screen groups them by id that the contradiction appears.
    useTallWindow(tester);
    final harness = dualEnrolledHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // One person, one pending entry — and both of their schools on the record,
    // which is what makes the presence read `ours` instead of `groupOnly`.
    final students = harness.controller.pendingEntries
        .where((e) => e.family == 'student')
        .toList();
    expect(students, hasLength(1));
    final entry = students.single;

    // The contradiction itself: provisioning and departure can never both be
    // true of one account, and before #318 this entry carried all three.
    final kinds =
        entry.choices.expand((c) => c.alternatives).map((a) => a.kind).toList();
    expect(kinds, contains('AddStudentToAzure'));
    expect(kinds, isNot(contains('UnregisterStudentFromSmartschool')),
        reason: 'the student is enrolled with us — never offer to unregister');
    expect(kinds, isNot(contains('DeleteStudentFromSmartschool')));

    // One person, one linked record, carrying *both* of their schools — which
    // is what makes the presence read `ours` instead of `groupOnly`.
    expect(
      harness.controller.linked!.snapshot.accounts.single.wisaSchoolIds,
      const {1, 2},
    );

    // On screen: the row files them under **our** class — the placement comes
    // from the ours-school row, not from whichever school the concatenated pull
    // read first (the sibling's `4ECO` arrives ahead of our `3BO` here).
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final Finder row = find.byKey(ValueKey('account-row-${entry.targetId}'));
    expect(row, findsOneWidget);
    expect(
        find.descendant(of: row, matching: find.text('3BO')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('4ECO')), findsNothing);
    expect(find.descendant(of: row, matching: find.text('Zonder klas')),
        findsNothing);

    // …and the card offers the provisioning alone. The departure either/or is
    // the half that must never share a card with it.
    await selectAccount(tester, entry.targetId);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    expect(find.text('Schrijf de leerling uit in Smartschool'), findsNothing);
    expect(find.text('Verwijder dit account uit Smartschool'), findsNothing);
  });

  for (final MapEntry<String, bool> order in <String, bool>{
    'the sibling school\'s row first': true,
    'our own row first': false,
  }.entries) {
    testWidgets(
        'a dual-enrolled student keeps our Smartschool class, never the '
        'sibling school\'s, with ${order.key} end-to-end (#332)',
        (WidgetTester tester) async {
      // The real app, real fonts, real navigation. `Lies` is enrolled in both
      // group schools — one `wisaId`, two rows — and only school 1 is ours. Our
      // row puts her in `3MWW1`, where Smartschool already has her, so a correct
      // pass proposes no class move at all. The sibling's row names `3HWa`, a
      // class our school does not have.
      //
      // Before the fix the placement resolver ignored the row the linker had
      // chosen (#318) and re-read the student out of a first-wins id index over
      // the pooled snapshot: the card offered "Wijzig de klas in Smartschool —
      // class: 3MWW1 → 3HWa", and the cohort behind "Toepassen op alle" would
      // have carried that write along with a legitimate rollover pass.
      //
      // Both orderings run, because with our row read first a first-wins index
      // happens to answer correctly — only the pair proves the placement follows
      // the linker's choice rather than the pull order's luck.
      useTallWindow(tester);
      final harness = dualEnrolledClassMoveHarness(siblingFirst: order.value);
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();
      expect(harness.controller.error, isNull);

      // One person, both schools on the record — which is what makes her read
      // `ours` rather than `groupOnly`, so no departure competes for the card.
      expect(
        harness.controller.linked!.snapshot.accounts.single.wisaSchoolIds,
        const {1, 2},
      );

      // Not one class move is proposed anywhere in the pass, and the sibling's
      // class never reaches a projected value.
      final alternatives = harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives);
      expect(
        alternatives.map((a) => a.kind),
        isNot(contains('MoveToSmartschoolClassGroup')),
        reason: 'she is already in our 3MWW1 — nobody moves',
      );
      expect(
        alternatives
            .expand((a) => a.changes.fields)
            .expand((f) => <String?>[f.before, f.after]),
        isNot(contains('3HWa')),
        reason: 'a sibling school\'s class is never written into our systems',
      );

      // Browse it the way the operator does. She has no work of her own, so the
      // list is the whole school with the filter off.
      await tester.tap(find.text('Acties'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
      await tester.pumpAndSettle();
      expect(find.textContaining('3HWa'), findsNothing,
          reason: 'school 2 is not managed — its class names no row in the '
              'list, which shows the class each student is ours in');

      final String id = harness.controller.linkedAccounts.single.id.value;
      final Finder row = find.byKey(ValueKey('account-row-$id'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      expect(find.descendant(of: row, matching: find.text('3MWW1')),
          findsOneWidget);

      await selectAccount(tester, id);
      expect(find.text('Wijzig de klas in Smartschool'), findsNothing);
      // Since #334 the sibling's class *is* on the card — as the statement that
      // explains the second enrolment, and as nothing else. The two issues are
      // the same rule from both sides: the class we write comes from our row
      // (pinned above, over the whole pass), and the class we merely say comes
      // from theirs (INV-25).
      expect(
        find.text('Ook ingeschreven in Instituut Sancta Maria-B (ISMAB), '
            'klas 3HWa'),
        findsOneWidget,
      );
      expect(find.textContaining('3HWa'), findsOneWidget,
          reason: 'that one line is the whole of what it says on screen');
    });
  }

  testWidgets(
      'a card states the other group school a student is enrolled in, and a '
      'single-school card is untouched, end-to-end (#334)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Two students, neither with any
    // work: `Lies` is enrolled in both group schools (ours holds her in
    // `3MWW1`, the sibling in `3HWa`), `Nele` in ours alone.
    //
    // Only a full run shows what the line is for. It has to survive the whole
    // pipeline — the linker keeping both rows on one record, the materializer
    // naming the school off the WISA school list, the document, the card — and
    // it has to land where an operator reading a strange card will find it,
    // under the class facts it explains. A widget test renders the pane with a
    // document handed to it; it cannot show that the document ever carries this.
    useTallWindow(tester);
    final harness = dualEnrolmentDisplayHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // Neither of them has anything to do, so the list is the whole school.
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    final String lies = accountId(harness, 'Lies Vermeulen');
    final String nele = accountId(harness, 'Nele Peeters');

    await selectAccount(tester, lies);
    // Named as the WISA school list names it — the long name with its short
    // code — never invented from the school id (#204/#208).
    expect(
      find.text(
          'Ook ingeschreven in Instituut Sancta Maria-B (ISMAB), klas 3HWa'),
      findsOneWidget,
    );
    // Beside the class facts it qualifies, which stay our school's: the card
    // still leads with the class she is ours in (INV-25).
    expect(
      find.descendant(
        of: find.byKey(ValueKey('actions-detail-$lies')),
        matching: find.text('3MWW1'),
      ),
      findsOneWidget,
    );
    // And it stays a statement: the sibling's class reaches no proposal, no
    // projected value, nothing to apply anywhere in the pass.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .expand((a) => a.changes.fields)
          .expand((f) => <String?>[f.before, f.after]),
      isNot(contains('3HWa')),
    );

    // The ordinary student — same class, same three systems in step — reads
    // exactly as she did before the line existed.
    await selectAccount(tester, nele);
    expect(find.textContaining('Ook ingeschreven'), findsNothing);
    expect(find.textContaining('3HWa'), findsNothing);
  });

  testWidgets(
      'the Actions list hides a school the operator does not manage in '
      'Settings, re-bucketing its student to the leaver group (#178)',
      (WidgetTester tester) async {
    // A student enrolled in school 2, fully present in our Smartschool + Azure.
    // A WISA snapshot carries no ownership at all (#286), so it comes solely
    // from the Settings-derived managed set the applier is wired with — the
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
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    // The non-managed school is nowhere on the screen…
    expect(find.text('School 2'), findsNothing,
        reason: 'school 2 is not managed → its class never names a row');
    // …but the departed student's cleanup stays actionable, filed under the
    // leaver bucket rather than vanishing entirely.
    final String leaver = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-row-$leaver')),
        matching: find.text('Zonder klas'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'marking that same school as managed in Settings surfaces its students in '
      'the Actions list end-to-end (#178)', (WidgetTester tester) async {
    // The very same school-2 student, but now school 2 is one of ours: their
    // class must be browsable instead of sitting in the leaver bucket. Proves
    // the managed set from Settings drives which students show. The school
    // itself is no longer a node (#210),
    // so the proof is that the student's own class is reachable.
    useTallWindow(tester);
    final harness = managedSchoolsHarness(ourSchoolIds: const {1, 2});
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String id = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    final Finder row = find.byKey(ValueKey('account-row-$id'));
    expect(find.descendant(of: row, matching: find.text('Zonder klas')),
        findsNothing,
        reason: 'managing school 2 takes its student out of the leaver bucket');
    expect(find.descendant(of: row, matching: find.text('3C')), findsOneWidget);
    // The class the student reached still carries school 2's partition, which
    // is what the stored documents are keyed by.
    expect(
      harness.controller
          .studentChildrenOf(harness.controller.studentRollups.single)
          .single
          .school,
      '2',
    );
  });

  testWidgets(
      'the materialized view names a school by name and code end-to-end, never '
      '"School <id>", while the list shows no school at all (#204/#210)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. This session's WISA snapshot
    // carries no schools at all, so the school's identity can only come from
    // the operator's persisted Settings profile — exactly the case that used to
    // bake `School 25` into every materialized node. #210 took the school level
    // out of the drill-down, so that label now lives only in the shared
    // documents (which Cosmos partitions by school and Settings names) — it must
    // still be the "Instellingen → WISA" identity there, and nowhere on screen.
    useTallWindow(tester);
    final harness = namedSchoolHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('School 25'), findsNothing,
        reason: 'the numeric id is the last resort, not the rendering (#204)');
    expect(find.text('Instituut Sancta Maria-A (ISMAA)'), findsNothing,
        reason: 'the school level is nowhere in the Acties list (#210/#295)');

    // The stored school rollup — what the counters and the Cosmos documents are
    // keyed and labelled by — still carries the full identity.
    expect(harness.controller.schoolRollups.single.label,
        'Instituut Sancta Maria-A (ISMAA)');

    // And the student's row names their class, straight away.
    final String id = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-row-$id')),
        matching: find.text('3C'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'a settings document written before #208 materializes as '
      '"Instituut Sancta Maria-A (ISMAA)", not inside out',
      (WidgetTester tester) async {
    // The stored document has the long name under `code` and the short code
    // under `name` — the layout every profile persisted before the fix carries.
    // Read back through the real `AppSettings.fromJson`, the migration must put
    // each half right so the materialized school reads the way #204 specified
    // instead of "ISMAA (Instituut Sancta Maria-A)".
    useTallWindow(tester);
    final migrated = AppSettings.fromJson(<String, dynamic>{
      'wisaSchools': <Map<String, dynamic>>[
        <String, dynamic>{
          'schoolId': 25,
          'code': 'Instituut Sancta Maria-A',
          'name': 'ISMAA',
          'ours': true,
        },
      ],
    });
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent(schoolId: 25)], schools: const []),
      smartschool: ssSnap(
          groups: const [], accounts: [ssAccount()], memberships: const []),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: const {25},
      schoolProfiles: migrated.wisaSchools,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    // The label lives in the shared documents now that #210 took the school
    // level out of the tree — it must be neither inverted nor the bare id, and
    // it must not resurface as a node on screen.
    expect(harness.controller.schoolRollups.single.label,
        'Instituut Sancta Maria-A (ISMAA)');
    expect(find.text('ISMAA (Instituut Sancta Maria-A)'), findsNothing,
        reason: 'the inverted rendering #208 fixed must not come back');
    expect(find.text('School 25'), findsNothing);
    expect(find.text('Instituut Sancta Maria-A (ISMAA)'), findsNothing,
        reason: 'the school level is nowhere in the Acties list (#210/#295)');
  });

  testWidgets(
      'the Klasgroepen drill-down proposes only classes of the schools we '
      'manage end-to-end, never a sibling school\'s (#205)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. WISA hands this session class
    // groups from two schools — the sibling school's `1A` and `9Z` first, our
    // own `1A` last — and only school 1 is managed. Every one of them used to
    // be offered as "Voeg deze klas toe aan Smartschool", and the sibling `1A`
    // even shadowed ours, so the proposal described the wrong school's class.
    useTallWindow(tester);
    final harness = foreignClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // Our own populated class is the only class in the inventory…
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.text('1A'), findsOneWidget);
    // …reading as the create side of the either/or choice of #244.
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsOneWidget);
    // …and no class of the school we do not manage is anywhere near it.
    expect(find.text('9Z'), findsNothing,
        reason: 'creating another school\'s class is never ours to propose');

    // The surviving proposal describes *our* 1A, not the sibling class that
    // shares its name — on the row itself and in the create's diff.
    expect(find.text('Onze eerste klas'), findsOneWidget,
        reason: 'the inventory row names our class');
    await tester.tap(find.byKey(const ValueKey('entry-group-1A')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Onze eerste klas'), findsNWidgets(2));
    expect(find.textContaining('Klas van een andere school'), findsNothing);
  });

  testWidgets(
      'the Klasgroepen drill-down carries no class of a virtual school '
      'end-to-end, while its students keep their place (#209)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. School 99 is the operator's
    // "Virtuele school", ticked *both* beheerd and virtueel — which is why the
    // managed-school filter of #205 never kept it out. Its classes used to
    // reach the Klasgroepen list as an applyable "create this class in
    // Smartschool" proposal (1V) and an empty-class notice (9V): rows nobody
    // will ever act on, each one an invitation to create a defunct class.
    useTallWindow(tester);
    final harness = virtualClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // Only our own class is in the inventory; neither virtual class is anywhere
    // — not as an entry tile, and not as a plain row either.
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-1A')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-1V')), findsNothing,
        reason: 'creating a virtual school\'s class is never worth proposing');
    expect(find.byKey(const ValueKey('class-row-1V')), findsNothing);
    expect(find.byKey(const ValueKey('entry-group-9V')), findsNothing,
        reason: 'the empty-class notice for a virtual class is pure clutter');
    expect(find.byKey(const ValueKey('class-row-9V')), findsNothing);
    expect(find.textContaining('Virtuele klas'), findsNothing);
    expect(find.textContaining('Lege virtuele klas'), findsNothing);

    // Over on Acties: the virtual school's student is still imported and still
    // sits in the class their own WISA record names — dropping the class-group
    // records moved nobody. The list spans every managed school (#210/#295), so
    // the virtual school's 1V student is a row beside our own school's.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String inVirtual = harness.controller.linkedAccounts
        .firstWhere((a) => a.classroom == '1V')
        .id
        .value;
    final Finder virtualRow = find.byKey(ValueKey('account-row-$inVirtual'));
    expect(virtualRow, findsOneWidget);
    expect(find.descendant(of: virtualRow, matching: find.text('Jane Doe')),
        findsOneWidget);
  });

  testWidgets(
      'an empty class beside a sibling school\'s populated namesake keeps its '
      'empty-class notice end-to-end (#222/#329)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Our school 1 has an empty
    // `1A`; the sibling school 2 we do not manage has its own populated `1A`,
    // pulled by the same shared WISA credentials. Only ours is linked (#205), so
    // exactly one class reaches the Klasgroepen list — and it is empty.
    //
    // Before the fix the tally behind `containsStudents` pooled every school's
    // students under the bare class name, so the sibling's student made our
    // empty class read as populated: the list offered "Voeg deze klas toe aan
    // Smartschool", the applyable action that also enrols students into the
    // class it creates. This is the layer that sees it — the misclassification
    // needs two schools in one snapshot, which no single-resolver assertion
    // composes, and the flip is what the operator reads off the tile.
    useTallWindow(tester);
    final harness = siblingPopulatedClassHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // Our 1A is the only class in the inventory, and it reads as the empty one.
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-1A')), findsOneWidget);
    expect(find.textContaining('bevat nog geen leerlingen'), findsOneWidget);
    expect(
        find.textContaining('Voeg deze klas toe aan Smartschool'), findsNothing,
        reason: 'nobody of ours is in 1A — creating + enrolling is not due');

    // The notice is **context**, not one of two answers (#329): there is
    // nothing for this app to create, so the row states the instruction —
    // marked "(manueel)" — above the single thing it can do about the class.
    // It was the pre-selected half of a radio pair until then, which asked the
    // operator to choose between "delete this by hand" and "never import it".
    expect(find.textContaining('(keuze)'), findsNothing,
        reason: 'a diagnosis and a write are not two solutions');
    expect(find.textContaining('wacht tot ze leerlingen bevat. (manueel)'),
        findsOneWidget);
    expect(find.text('Negeer deze klas bij het importeren uit WISA'),
        findsOneWidget,
        reason: 'the lone proposal, stated plainly under the notice');

    // Expanding it shows the same two, in the same order, and no radios.
    await tester.tap(find.byKey(const ValueKey('entry-group-1A')));
    await tester.pumpAndSettle();
    expect(find.text('Kies één oplossing:'), findsNothing,
        reason: 'nothing to choose between');
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    expect(find.textContaining('wacht tot ze leerlingen bevat. (manueel)'),
        findsOneWidget,
        reason: 'the instruction survives the removal of the radio');
    expect(find.text('Negeer deze klas bij het importeren uit WISA'),
        findsOneWidget);
    expect(find.text('DontImportClass: ∅ → 1A'), findsOneWidget,
        reason: 'and the card shows exactly what pressing would write');

    // The card proposes; it does not interrogate. Toepassen is live because
    // there genuinely is a write here — what keeps it out of a *bulk* pass is
    // `canApplyToAll`, not the polarity of a pair (#293/#326).
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('entry-apply-1A')))
          .onPressed,
      isNotNull,
    );
    expect(
        harness.controller.groupPendingSituations
            .firstWhere((c) => c.key == 'group|class-import')
            .bulkApplyable,
        isEmpty);

    // And the pass itself never constructed the create-and-enrol action for it.
    final decisions =
        harness.controller.pendingEntries.expand((e) => e.choices);
    final kinds = decisions.expand((c) => c.alternatives).map((a) => a.kind);
    expect(kinds, contains('DoNotImportFromWisa'));
    expect(kinds, isNot(contains('AddToSmartschool')));
    expect(kinds, isNot(contains('CreateInSmartschool')),
        reason: 'the notice is never an alternative');
    expect(
      decisions.expand((c) => c.notices).map((a) => a.kind),
      contains('CreateInSmartschool'),
      reason: 'it is context on the decision instead',
    );
  });

  testWidgets(
      'a class Smartschool already has is never offered for creation '
      'end-to-end (#225)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Smartschool holds `2G` under
    // `2de Jaar` with the subgroup `2G LAT` under it — but the `2G` node is not
    // flagged as an official class, so the class link (which only ever adopts
    // official classes) passed it over. The WISA class then read as one nobody
    // had created, and the Klasgroepen list offered "Voeg deze klas toe aan
    // Smartschool": a write that asks Smartschool for a second class named
    // `2G`, which it either rejects or leaves standing beside the first.
    //
    // This is the layer that sees it: the wrong proposal is what the operator
    // reads off the tile and clicks, and the notice that replaces it has to
    // reach the same list through the linker, the dispatch, the materializer
    // and the drill-down.
    useTallWindow(tester);
    final harness = nonOfficialSmartschoolClassHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // `2G` is on the list, and it says the class is already there — not that it
    // needs creating.
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-2G')), findsOneWidget);
    expect(
      find.textContaining(
          'Deze klas bestaat in Smartschool maar is geen officiële klas'),
      findsOneWidget,
    );
    expect(
        find.textContaining('Voeg deze klas toe aan Smartschool'), findsNothing,
        reason:
            'Smartschool already has a 2G — creating a second is never due');
    expect(find.textContaining('bevat nog geen leerlingen'), findsNothing,
        reason: 'the empty-class advice is wrong for a provisioned class');

    // The pass never constructed either create action for it, and the notice
    // it raised instead is context on the one decision there is (#329) — never
    // an alternative, because the app cannot perform a hand edit in Smartschool.
    final decisions =
        harness.controller.pendingEntries.expand((e) => e.choices);
    final kinds = decisions.expand((c) => c.alternatives).map((a) => a.kind);
    expect(kinds, isNot(contains('AddToSmartschool')));
    expect(kinds, isNot(contains('CreateInSmartschool')));
    expect(kinds, isNot(contains('ClassExistsAsSmartschoolGroup')));
    expect(
      decisions.expand((c) => c.notices).map((a) => a.kind),
      contains('ClassExistsAsSmartschoolGroup'),
    );

    // The subgroup keeps its own, correct Smartschool-only notice: it is an
    // official class WISA has no counterpart for.
    expect(find.byKey(const ValueKey('entry-group-2G LAT')), findsOneWidget);

    // And the skip is no longer silent — the log names the group that was
    // passed over and why.
    final lines = harness.log.entries.map((e) => e.message).join('\n');
    expect(lines, contains('Klas "2G" niet gekoppeld'));
    expect(lines, contains('G2G'));
  });

  testWidgets(
      'a new class offers one either/or choice, and "apply to all" creates '
      'every class without blacklisting any end-to-end (#244)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over the real Smartschool
    // write path. Two brand-new WISA classes, neither known to Smartschool.
    //
    // Each used to carry "Voeg deze klas toe aan Smartschool" *and* "Negeer
    // deze klas bij het importeren uit WISA" as two independent to-dos, both
    // selected — so the situation header's **Apply to all** created every new
    // class of the year and then wrote a DontImportClass rule on the very name
    // it had just created. The class dropped out of the next WISA snapshot
    // while the group survived downstream, unmanaged.
    //
    // This is the layer that sees it: the contradiction is what the operator
    // reads off the bulk header and clicks, and the fix has to reach it through
    // the dispatch, the entry grouping and the drill-down.
    useTallWindow(tester);
    final harness = newClassChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // Both new classes are on the list, each reading as *one* choice…
    expect(find.byKey(const ValueKey('entry-group-1A')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-1B')), findsOneWidget);
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsNWidgets(2));
    // …and no row carries the opt-out as a line of its own: it is the
    // alternative the operator can switch to, not a second thing that also
    // runs. (The bulk header below names both sides of the one choice.)
    expect(find.text('Negeer deze klas bij het importeren uit WISA'),
        findsNothing);

    // The bulk header offers the one resolution for both classes.
    final key = harness.controller.groupPendingSituations
        .firstWhere((c) => c.label.startsWith('Voeg deze klas toe aan '
            'Smartschool'))
        .key;
    final bulk = find.byKey(ValueKey('situation-apply-$key'));
    await tester.ensureVisible(bulk);
    expect(
      find.textContaining('Voeg deze klas toe aan Smartschool / Negeer deze '
          'klas bij het importeren uit WISA'),
      findsOneWidget,
      reason: 'the header names one either/or, not two independent to-dos',
    );

    final pulls = harness.wisaSyncs;
    await tester.tap(bulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Both classes were created in Smartschool…
    final saved =
        harness.soap.soapActions.where((a) => a.endsWith('#saveClass')).length;
    expect(saved, 2);
    // …and the pass re-pulled nothing while doing it (#72; since #345 a rule
    // would not have re-pulled either). What proves none of them was
    // blacklisted on the way out is the summaries below.
    expect(harness.wisaSyncs, pulls);
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary).toList();
    expect(summaries.where((s) => s == 'Voeg deze klas toe aan Smartschool'),
        hasLength(2));
    expect(
      summaries,
      isNot(contains('Negeer deze klas bij het importeren uit WISA')),
      reason: 'the rule would drop the classes this same pass just created',
    );
  });

  testWidgets(
      'a class the #225 notice says to fix by hand survives "Alles toepassen" '
      'untouched end-to-end (#250/#329)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over the real Smartschool
    // write path. Four WISA classes: `1A`/`1B` are genuinely new, while `2G`
    // and `2H` already exist in Smartschool on groups that are not flagged as
    // official classes — the #225 shape, where the app offers no create and
    // tells the operator to make the group official by hand.
    //
    // Refusing the create left "Negeer deze klas bij het importeren uit WISA"
    // as the *only* member of the create-or-ignore either/or of #244, and a
    // choice of one is always the selected one. The bulk **Alles toepassen**
    // therefore wrote a DontImportClass rule on the very classes the notice
    // beside them had just said to align by hand: they dropped out of the next
    // WISA snapshot while the Smartschool groups stayed behind, unmanaged.
    //
    // #250 fixed it by making the notice the pre-selected half of a pair, and
    // #329 took that pair away again — an instruction to go and edit something
    // in Smartschool is not a resolution an apply can run, so it is context on
    // the card rather than one of two answers. The blacklist is therefore the
    // selected resolution of both rows once more, which makes this run the
    // proof that the *replacement* guard holds: `canApplyToAll == false`,
    // refused by every bulk affordance since #326.
    //
    // This is the layer that sees it. What a card states, which bulk subset a
    // class lands in, and what the button on that subset writes are three
    // different halves of the screen, composed by the dispatch, the entry
    // grouping and the drill-down — only a full run puts the notice and the
    // button that acts on it on screen together.
    useTallWindow(tester);
    final harness = namesakeClassChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    // Every class is on the list, and each namesake one still states the
    // hand-fix instruction — now marked "(manueel)", above the one thing this
    // app can actually do about the class.
    for (final id in const ['2G', '2H']) {
      final row = find.byKey(ValueKey('entry-group-$id'));
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining(
              'Deze klas bestaat in Smartschool maar is geen officiële klas'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('(manueel)')),
        findsOneWidget,
        reason: 'the notice reads as write-free from the inventory row',
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('Negeer deze klas bij het importeren uit WISA'),
        ),
        findsOneWidget,
        reason: 'and the single proposal is stated plainly, not as "(keuze)"',
      );
    }
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsNWidgets(2),
        reason: '1A and 1B are the ordinary new-class case, and keep their '
            'either/or: both halves of it write');

    // The namesake classes form a bulk cohort of their own. Pooling them with
    // the new classes would have filed them under a header offering to create
    // classes that already exist.
    const String namesakeKey = 'group|class-namesake';
    const String newKey = 'group|class-import';
    final cohorts = harness.controller.groupPendingSituations;
    expect(
      cohorts.firstWhere((c) => c.key == namesakeKey).decisions.length,
      2,
    );
    expect(cohorts.firstWhere((c) => c.key == newKey).decisions.length, 2);

    // Exact, not a substring: the new classes' own header ends in the same
    // words, because the blacklist is one half of *their* either/or.
    final namesakeHeader = find.text(
        'Negeer deze klas bij het importeren uit WISA — 2 klassen in dezelfde '
        'situatie');
    await tester.ensureVisible(namesakeHeader);
    expect(
      namesakeHeader,
      findsOneWidget,
      reason: 'the header names the one decision these two classes share',
    );

    // And it offers nothing to run. Since #292 the cohort is that one decision
    // rather than the whole card, and its resolution is withheld from every
    // bulk pass by #293 — so since #326 the pair is not rendered at all. Under
    // the old grouping the button was live, because the classes also need an
    // Office 365 group (#228): pressing a header that said "this class is
    // already there" wrote something else entirely.
    final pulls = harness.wisaSyncs;
    expect(find.byKey(const ValueKey('situation-apply-$namesakeKey')),
        findsNothing);
    expect(find.byKey(const ValueKey('situation-dry-run-$namesakeKey')),
        findsNothing,
        reason: 'nothing a bulk pass may write means nothing to press');
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        isEmpty,
        reason: 'Smartschool already holds 2G and 2H');

    // The two classes are still on the list, still asking for the hand repair.
    for (final id in const ['2G', '2H']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('entry-group-$id')),
          matching: find.textContaining(
              'Deze klas bestaat in Smartschool maar is geen officiële klas'),
        ),
        findsOneWidget,
      );
    }

    // And the fix did not simply silence the list: the other cohort still
    // creates the genuinely new classes, and blacklists neither.
    final newBulk = find.byKey(const ValueKey('situation-apply-$newKey'));
    await tester.ensureVisible(newBulk);
    await tester.tap(newBulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(2),
        reason: '1A and 1B are created; 2G and 2H are not touched');
    expect(
      harness.controller.applyResults!.map((r) => r.changes.summary),
      isNot(contains('Negeer deze klas bij het importeren uit WISA')),
      reason: 'the rule would drop the classes the app just said to repair',
    );
    // The summaries above are the proof that no rule was written; this is the
    // separate #72/#345 claim that a bulk create re-pulls nothing at all — not
    // for the creates, and not for a rule either (which since #345 filters the
    // snapshot in place rather than re-syncing).
    expect(harness.wisaSyncs, pulls);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Smartschool-namesake notice names the group\'s code end-to-end, it '
      'does not diff it (#306)', (WidgetTester tester) async {
    // The last bare-`before` field #305 left standing, in the real app. `2G` is
    // a WISA class Smartschool already carries on a group that is not flagged
    // official, so the app proposes no create and instead tells the operator to
    // repair the group by hand — an informational notice that writes nothing
    // (`canApply == false`). Under that heading its three fields read
    //
    //   name: 2G → 2G
    //   code: G2G → ∅
    //   officiële klas: nee → ja
    //
    // The outer two are the repair being asked for. The middle one is not a
    // value moving at all: the code is how the operator finds the group in
    // Smartschool, and through the before → after template it claims the notice
    // clears it.
    //
    // End-to-end rather than on the action alone, because the line the operator
    // reads is assembled across the whole path: the group dispatch's
    // `ChangeSet`, the collapse that lifts the notice onto the "negeer deze
    // klas" decision it is context for (#329), the block that states it above
    // that decision, and only then `fieldChangeLine`. "No cleared field
    // anywhere on this card" is also a claim about the page as composed — this
    // tab renders the second namesake class and the two ordinary new classes
    // beside it.
    useTallWindow(tester);
    final harness = namesakeClassChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    final entry = find.byKey(const ValueKey('entry-group-2G'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // The notice is context on the card, and it states the code as a fact.
    expect(
      find.textContaining(
          'Deze klas bestaat in Smartschool maar is geen officiële klas'),
      findsWidgets,
    );
    expect(find.text('code: G2G'), findsOneWidget);

    // The repair it *is* asking for still reads as the transition it is.
    expect(find.text('officiële klas: nee → ja'), findsOneWidget);

    // And the open card asks no question (#329): the instruction is stated,
    // marked "(manueel)", above the single write this app has for the class.
    final Finder card = find.byKey(const ValueKey('entry-group-2G'));
    expect(
        find.descendant(of: card, matching: find.text('Kies één oplossing:')),
        findsNothing);
    expect(
      find.descendant(
          of: card, matching: find.byIcon(Icons.radio_button_checked)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: card, matching: find.byIcon(Icons.radio_button_unchecked)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('dan wordt ze gekoppeld. (manueel)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('Negeer deze klas bij het importeren uit WISA'),
      ),
      findsOneWidget,
    );
    expect(find.text('DontImportClass: ∅ → 2G'), findsOneWidget);

    // And nothing on this page claims a field is being emptied — least of all
    // an action that cannot be applied.
    expect(find.textContaining('→ ∅'), findsNothing,
        reason: 'a notice that writes nothing clears nothing');
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        isEmpty,
        reason: 'opening a card writes nothing');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the badges count one pending item per either/or, so the Klasgroepen '
      'rollup agrees with the list the tab renders end-to-end (#251)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Two brand-new WISA classes,
    // each carrying the create-or-ignore either/or of #244 plus an Office 365
    // group to create: four decisions in all.
    //
    // The badge counted *actions*, so it read 6 — both halves of both choices —
    // while the list behind it offered four resolutions and Apply to all wrote
    // four. The overview and the list disagreed about how much work there was,
    // and since #226 that same count decides whether a node is in the tree at
    // all.
    //
    // This is the layer that sees it: the badge is derived from the persisted
    // rollups, the list from the live dispatch, and they are composed by
    // different halves of the screen — only a full run puts both on screen in
    // that order.
    useTallWindow(tester);
    final harness = newClassChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // The stored Klasgroepen aggregate — what every badge on the classes is
    // derived from — counts four decisions, never the six actions behind them.
    expect(harness.controller.groupRollup!.pendingCount, 4,
        reason: 'two classes × (one either/or + one Office 365 group)');
    expect(harness.controller.groupRollup!.pendingCount, isNot(6),
        reason: 'the badge used to count both halves of both choices');

    // Each student's own row carries one action and is badged once, so the
    // collapse did not simply deflate every count.
    final String inOneA = harness.controller.linkedAccounts
        .firstWhere((a) => a.classroom == '1A')
        .id
        .value;
    final Finder rowOneA = find.byKey(ValueKey('account-row-$inOneA'));
    await tester.ensureVisible(rowOneA);
    expect(
        find.descendant(of: rowOneA, matching: find.text('1')), findsOneWidget);

    // The number on the aggregate is exactly what a confirmed apply of the
    // Klasgroepen list would write — the claim the badge and the dialog used to
    // disagree on. Each class row carries its own share of it, badged once.
    await openKlasgroepen(tester);
    final groups = harness.controller.groupPendingEntries;
    expect(groups, hasLength(2));
    expect(harness.controller.applyScope(groups).systems, hasLength(4));
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsNWidgets(2));
    for (final klas in const ['1A', '1B']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('entry-group-$klas')),
          matching: find.text('2'),
        ),
        findsOneWidget,
        reason: 'one either/or plus one Office 365 group on each class',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a new hire is one pending item on the Personeel badge, not two '
      'end-to-end (#251/#248)', (WidgetTester tester) async {
    // The staff twin of the class case, and the crisp version of the count: two
    // freshly hired teachers, each raising the provision-or-ignore either/or of
    // #248 and nothing else. Two people, two decisions — the node read 4.
    useTallWindow(tester);
    final harness = newStaffChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    // Each hire is one row, badged once — never twice for the two halves of the
    // one either/or.
    for (final e in harness.controller.pendingEntries
        .where((e) => e.family == 'staff')) {
      final Finder row = find.byKey(ValueKey('account-row-${e.targetId}'));
      await tester.ensureVisible(row);
      expect(find.descendant(of: row, matching: find.text('1')), findsOneWidget,
          reason: 'one hire, one either/or');
      expect(find.descendant(of: row, matching: find.text('2')), findsNothing,
          reason: 'the opt-out is the alternative, never a second to-do');
    }

    // The Personeel tab badge is derived the same way and agrees.
    expect(harness.controller.staffPendingCount, 2);
    expect(harness.controller.applyableCount, 2,
        reason: 'an apply writes one resolution per hire');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a class without an Office 365 group is proposed once — named after the '
      'parent class — and applying it creates a unified group end-to-end '
      '(#228)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over the real Graph write
    // path. Our school runs `1A` (already provisioned as GBS-1A, with its
    // student in it) and the sub-grouped `2F` (`2F ECO` + `2F MAW`), which has
    // no group at all. Four linked class records, one missing group.
    //
    // This is the layer that sees the two things that matter: that the operator
    // gets **one** proposal rather than one per sub-group — the bare class name
    // is gone by the time an action sees a record, so a naive implementation
    // offers `GBS-2F ECO` and `GBS-2F MAW` — and that the write Graph receives
    // is a mail-enabled Microsoft 365 group, not the security group legacy made
    // for staff.
    useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openKlasgroepen(tester);

    // One proposal, named after the parent class `2F` — not `2F ECO`.
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(
      find.text('Maak de Office 365-groep GBS-2F voor klas 2F'),
      findsOneWidget,
    );
    expect(find.textContaining('GBS-2F ECO'), findsNothing,
        reason: 'sub-groups get no group of their own');
    expect(find.byKey(const ValueKey('entry-group-1A')), findsNothing,
        reason: 'GBS-1A exists and holds its student — nothing to propose');
    // …and the class is on the inventory all the same, ticked off (#227): the
    // sibling rows say whose group they share rather than each looking like a
    // class with a missing group of its own.
    expect(find.byKey(const ValueKey('class-row-1A')), findsOneWidget);
    expect(find.text('deelgroep van 2F'), findsNWidgets(2));

    // The group of a class that no longer exists reads as the one thing it
    // proposes since #327 — the delete — so its collapsed line is that summary,
    // bare: not "(keuze)", because there is nothing to choose between, and not
    // "(manueel)", because this one is applyable.
    expect(
      find.textContaining('Verwijder de Office 365-groep GBS-9Z'),
      findsWidgets,
    );
    expect(find.textContaining('Laat de Office 365-groep GBS-9Z staan'),
        findsNothing);
    expect(find.textContaining('(keuze)'), findsNothing);

    // Expand the class's row and apply just it.
    const entry = ValueKey('entry-group-2F ECO');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    const row = ValueKey('entry-apply-2F ECO');
    await tester.ensureVisible(find.byKey(row));
    await tester.tap(find.byKey(row));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);

    // Graph was asked for exactly one group, and for the right kind of group.
    expect(harness.graph.createdGroups, hasLength(1));
    final body = harness.graph.createdGroups.single;
    expect(body['displayName'], 'GBS-2F');
    expect(body['mailNickname'], 'GBS-2F');
    expect(body['groupTypes'], ['Unified']);
    expect(body['mailEnabled'], isTrue);
    expect(body['securityEnabled'], isFalse);

    // The one click also filled the group (#245). Graph creates a group empty,
    // so the create used to land an `GBS-2F` with nobody in it and the roster
    // waited for a second click; the applier now chains the membership write
    // against the relinked record — the only place the id Graph just minted
    // exists — and both sub-groups' students land in the one parent group.
    expect(
      harness.graph.batchedWrites,
      hasLength(2),
      reason: "both sub-groups' students belong to the one parent group",
    );
    expect(
      harness.graph.batchedWrites,
      everyElement(startsWith('POST /groups/az-group-1/members')),
    );
    expect(
      find.textContaining('Werk het ledenbestand van GBS-2F bij (2 toevoegen'),
      findsOneWidget,
      reason: 'the chained write is reported beside the create, not hidden',
    );

    // …so nothing about this class is left pending: no create, and no roster.
    final kinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toList();
    expect(kinds, isNot(contains('CreateAzureClassGroup')));
    expect(kinds, isNot(contains('SyncAzureClassGroupMembers')));
  });

  testWidgets(
      'applying a new class creates the Smartschool class **and** its Office '
      '365 group end-to-end (#272)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over both real write paths at
    // once. `5WW1` is in WISA only and has no `GBS-5WW1` group, so its card
    // carries two selected options — the #244 create-or-ignore either/or with
    // the create pre-selected, and the Office 365 create standing beside it.
    //
    // This is the layer the report needed and nothing had: every per-action
    // unit test passes while one of an entry's two options quietly does not
    // land, because "both options ran" is a claim about the *entry* — the
    // dispatch, the alternative collapse, the card's selection and the apply
    // loop composed — and only a full run puts all four together.
    useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    // Two decisions on one card, and the badge counts both.
    const entry = ValueKey('entry-group-5WW1');
    expect(
      find.descendant(
        of: find.byKey(entry),
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(entry),
        matching: find.text('Voeg deze klas toe aan Smartschool (keuze)'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    // The confirmation names both systems, because both are written.
    expect(find.textContaining('Smartschool'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Smartschool got its class…
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(1));
    // …and Graph got the Microsoft 365 group, filled by the roster write the
    // create chains (#245).
    expect(harness.graph.createdGroups, hasLength(1));
    final body = harness.graph.createdGroups.single;
    expect(body['displayName'], 'GBS-5WW1');
    expect(body['groupTypes'], ['Unified']);
    expect(harness.graph.batchedWrites, hasLength(2),
        reason: "the class's two students belong to the group it just made");

    // So the class owes nothing to anybody any more.
    final kinds = harness.controller.pendingEntries
        .where((e) => e.targetId == '5WW1')
        .expand((e) => e.choices)
        .map((c) => c.selected.kind)
        .toList();
    expect(kinds, isEmpty);
  });

  testWidgets(
      'a class written to Smartschool names the school year WISA was read at, '
      'end-to-end (#339)', (WidgetTester tester) async {
    // The reported loop, from the operator's side and through the real app:
    // pin the werkdatum to next 1 September in Instellingen, Synchroniseer, and
    // apply the class the pass proposes.
    //
    // WISA answers *as of* the werkdatum, so the institute number on that class
    // is next year's. Smartschool's `saveClass` documents that a write naming no
    // year adjusts "het huidige schooljaar" — the year Smartschool is in today,
    // which in August is still the running one. So the whole chain has to carry
    // the date: settings → the WISA pull → the werkdatum stamped on the
    // snapshot → the class write. Every link but the last was already there, and
    // no unit test can see that the last one is missing, because it is only
    // missing once the four are composed.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(
      wisaTransport: wire,
      liveSettings: live,
      // Smartschool holds only the root the classes hang under, so the class
      // WISA reports is genuinely missing and its parent genuinely resolves.
      smartschool: ssSnap(
        groups: [
          ssGroup(
            'Leerlingen',
            code: 'SCHOOL',
            official: false,
            type: GroupType.group,
          ),
        ],
        accounts: const [],
        memberships: const [],
      ),
      classTree: const SmartschoolClassTree(path: 'SCHOOL'),
      ourSchoolIds: const {1},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    // The pull really did ask WISA for next school year.
    expect(wire.werkdatums, <String>['01/09/2026']);

    const entry = ValueKey('entry-group-3C');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-3C'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The class landed — and it named the year it came from, so next year's
    // institute number is written onto next year and the running year is left
    // as it is.
    expect(harness.soap.savedClassSchoolYears, <String>['2026-9-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an Office 365 create Graph refuses says so on the class card, and can '
      'be run again from it end-to-end (#272)', (WidgetTester tester) async {
    // The reported run. Both options are dispatched; Graph refuses the group
    // create with the `403 Authorization_RequestDenied` of #216, the Smartschool
    // half lands, and the operator — who applied one class out of an inventory
    // — is left believing the Office 365 group "never lands".
    //
    // Only a full run shows why: the refusal was recorded twice, and both
    // records are off screen. The log line is on the Synchronisatie tab, and the
    // outcome rows are in a page-level section under the whole inventory. The
    // verdict now sits on the card the operator pressed.
    useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    harness.graph.refuseGroupCreates = true;
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    const entry = ValueKey('entry-group-5WW1');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The Smartschool half still landed — a refused action never aborts the
    // rest of the pass.
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(1));
    expect(harness.graph.createdGroups, isEmpty);

    // …and the card says exactly what happened to each half, with the reason
    // Graph gave. Since #283 each verdict sits with the decision it answers:
    // the refusal under the create that is still offered, the Smartschool half
    // — whose decision the write settled — at card level.
    final refused = find.byKey(const ValueKey('entry-outcomes-group-5WW1-0'));
    final settled = find.byKey(const ValueKey('entry-outcomes-group-5WW1'));
    await tester.ensureVisible(settled);
    expect(
      find.descendant(
          of: refused, matching: find.text('Resultaat van de vorige poging')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: refused,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    // Both on the one card, on screen together — the whole point of #272, which
    // #283 splits without losing.
    for (final block in <Finder>[refused, settled]) {
      expect(find.descendant(of: find.byKey(entry), matching: block),
          findsOneWidget);
    }

    // The create is still offered, and running it again against a tenant that
    // allows it lands the group.
    harness.graph.refuseGroupCreates = false;
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.graph.createdGroups, hasLength(1));
    expect(harness.graph.createdGroups.single['displayName'], 'GBS-5WW1');
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(1),
        reason: 'the Smartschool class was already there — no second create');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a membership batch Graph refuses names what Graph said, on the card '
      'and in the log, end-to-end (#330)', (WidgetTester tester) async {
    // The reported run, from the operator's side. `SSM-1A` turned out to be a
    // group whose membership Graph will not manage (#331), so all 38 of its
    // changes bounced at once — and the whole of what came back was
    // *"38 of 38 membership change(s) failed"*, contradicted by a log claiming
    // 21 members had been added and 17 removed.
    //
    // Only a full run puts the two records side by side. The count is composed
    // by the action, the reason travels from the connector's per-sub-request
    // `$batch` results through the applier into the card's outcome block, and
    // the log line is written by a connector the action never speaks to and
    // read on a different screen. Every one of those layers was passing its own
    // tests while the operator was told a number and a lie.
    useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    harness.graph.refuseMembershipWrites = true;
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    const entry = ValueKey('entry-group-1A');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('entry-apply-1A'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Both writes were attempted — one add, one remove — and both were refused.
    expect(harness.graph.batchedWrites, hasLength(2));

    // The card still counts, and now also says why: Graph's status, its error
    // code and its message, on the card the operator pressed.
    final failure = find.descendant(
      of: find.byKey(entry),
      matching: find.textContaining('2 of 2 membership change(s) on GBS-1A '
          'failed'),
    );
    expect(failure, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(entry),
        matching: find.textContaining('400 Request_BadRequest: Adding or '
            'removing members is not supported for this group.'),
      ),
      findsOneWidget,
      reason: 'the line an operator can act on, or paste into a search',
    );

    // And the log agrees with the card instead of contradicting it: the refusal
    // is red, it counts what actually landed…
    final errors =
        harness.log.entries.where((e) => e.isError).map((e) => e.message);
    expect(
      errors,
      containsAll(<Matcher>[
        allOf(
          contains('0 van 1 leden toegevoegd aan groep az-GBS-1A'),
          contains('1 mislukt: 400 Request_BadRequest'),
        ),
        allOf(
          contains('0 van 1 leden verwijderd uit groep az-GBS-1A'),
          contains('1 mislukt: 400 Request_BadRequest'),
        ),
      ]),
    );
    // …no line anywhere claims the batch went through…
    expect(
      harness.log.entries.map((e) => e.message),
      everyElement(isNot(contains('in batch'))),
      reason: 'the unconditional success line is what made the log lie',
    );
    // …and each refused member is named, so a *partial* failure could be traced
    // to the accounts it hit rather than to a count.
    expect(
      harness.log.entries.map((e) => e.message),
      containsAll(<Matcher>[
        contains('az1 → 400 Request_BadRequest'),
        contains('az2 → 400 Request_BadRequest'),
      ]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a card raising two decisions groups each one\'s fields under its own '
      'heading end-to-end (#281)', (WidgetTester tester) async {
    // `5WW1` is new to Smartschool *and* has no Office 365 group, so one card
    // asks the operator two independent questions. The body used to answer them
    // in one interleaved run: both summaries pooled in the subtitle, then the
    // Office 365 field diff, then "Kies één oplossing:" with its radios, then
    // the Smartschool option's diff. Nothing said which diff belonged to which
    // decision, or that "pick one of these two" covered only half the card.
    //
    // Asserted end-to-end rather than on the widget alone: what a decision
    // block *is* is decided by `entryDetail`, but which decisions a card raises
    // is decided by the dispatch, the alternative collapse and the inventory
    // composing — and a heading that groups nothing is exactly the bug.
    useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    const entry = ValueKey('entry-group-5WW1');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();

    // Two decisions, two blocks — the Office 365 create first, because
    // `collapseAlternatives` emits the lone actions ahead of the either/ors.
    final office365 = find.byKey(const ValueKey('entry-choice-group-5WW1-0'));
    final smartschool = find.byKey(const ValueKey('entry-choice-group-5WW1-1'));
    expect(office365, findsOneWidget);
    expect(smartschool, findsOneWidget);

    // The lone action is headed by what it does, and the fields under that
    // heading are the group it would create.
    expect(
      find.descendant(
        of: office365,
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: office365, matching: find.text('groupTypes: ∅ → Unified')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: office365,
        matching: find.text('description: ∅ → 5e jaar Wetenschappen-Wiskunde'),
      ),
      findsNothing,
      reason: "the Smartschool class's fields belong to the other decision",
    );
    expect(
      find.descendant(
          of: office365, matching: find.text('Kies één oplossing:')),
      findsNothing,
      reason: 'there is nothing to pick between here',
    );

    // The either/or is headed by its question, and the diff below the radios is
    // the Smartschool class the selected half would create.
    expect(
      find.descendant(
          of: smartschool, matching: find.text('Kies één oplossing:')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: smartschool,
          matching: find.text('Negeer deze klas bij het importeren uit WISA')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: smartschool,
        matching: find.text('description: ∅ → 5e jaar Wetenschappen-Wiskunde'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: smartschool, matching: find.text('groupTypes: ∅ → Unified')),
      findsNothing,
      reason: "the Office 365 group's fields belong to the other decision",
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'after a pass, a card raising two decisions still reads as two and loses '
      'no verdict end-to-end (#283)', (WidgetTester tester) async {
    // #281 gave each of `5WW1`'s two decisions a block of its own; the verdict
    // lines went on pooling below both of them, saying what happened without
    // saying to which question. Splitting them is not the mechanical move it
    // looks like, and that is what this run is here for:
    //
    // - a **dry-run** settles nothing, so both decisions survive it and each
    //   one must claim exactly its own verdict — never the other's;
    // - an **apply** settles the half that lands, so that decision is gone from
    //   the card the relink builds. Its verdict has no block left to sit in and
    //   would silently vanish — losing exactly what #272 exists to show. The
    //   reported run is that case: Smartschool lands, Graph refuses the group,
    //   and both verdicts have to stay readable side by side.
    //
    // Only a full run puts it together: which decisions a card raises is
    // decided by the dispatch, the alternative collapse and the relink after
    // the write, and "the verdict went missing" is a claim about what survives
    // that relink.
    useTallWindow(tester);
    final harness = newClassNeedingBothWritesHarness();
    harness.graph.refuseGroupCreates = true;
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    const entry = ValueKey('entry-group-5WW1');
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();

    // A dry-run first: two decisions, two verdicts, one under each heading.
    final dryRun = find.byKey(const ValueKey('entry-dry-run-5WW1'));
    await tester.ensureVisible(dryRun);
    await tester.tap(dryRun);
    await tester.pumpAndSettle();

    final office365 = find.byKey(const ValueKey('entry-outcomes-group-5WW1-0'));
    final smartschool =
        find.byKey(const ValueKey('entry-outcomes-group-5WW1-1'));
    await tester.ensureVisible(smartschool);
    expect(
      find.descendant(
        of: office365,
        matching: find.text('Maak de Office 365-groep GBS-5WW1 voor klas 5WW1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: office365,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsNothing,
      reason: "the Smartschool write is the other decision's verdict",
    );
    expect(
      find.descendant(
          of: smartschool,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    expect(
        find.byKey(const ValueKey('entry-outcomes-group-5WW1')), findsNothing,
        reason: 'a dry-run settles no decision, so nothing is left over');

    // Now the real pass. Graph refuses the group; Smartschool takes the class.
    final apply = find.byKey(const ValueKey('entry-apply-5WW1'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(1));
    expect(harness.graph.createdGroups, isEmpty);

    // The refusal stays with the decision that still asks the question…
    final decision = find.byKey(const ValueKey('entry-choice-group-5WW1-0'));
    await tester.ensureVisible(decision);
    expect(
      find.descendant(
          of: decision,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: decision,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsNothing,
    );

    // …and the half that landed keeps its verdict at card level, with the
    // reason it has no decision above it. Nothing went missing.
    final settled = find.byKey(const ValueKey('entry-outcomes-group-5WW1'));
    await tester.ensureVisible(settled);
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Overige resultaten van de vorige poging')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: settled,
        matching: find.text('Deze acties staan niet meer open op deze kaart.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: settled,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );
    // One card, both halves of the story.
    for (final block in <Finder>[decision, settled]) {
      expect(find.descendant(of: find.byKey(entry), matching: block),
          findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an expanded card states its summary once and its member counts as '
      'counts end-to-end (#300)', (WidgetTester tester) async {
    // The reported card, in the real app: `1A` exists everywhere and carries
    // one decision, the Office 365 roster write. It read
    //
    //   Werk het ledenbestand van GBS-1A bij (1 toevoegen, 1 verwijderen)
    //   **Werk het ledenbestand van GBS-1A bij (1 toevoegen, 1 verwijderen)**
    //   leden toevoegen: ∅ → 1
    //   leden verwijderen: ∅ → 1
    //
    // — the collapsed preview and the #281 decision heading saying the same
    // sentence one line apart, and two quantities pushed through the
    // before/after diff template.
    //
    // Asserted end-to-end rather than on the widget alone, because both halves
    // are claims about *composition*. "Once" is a count over the whole card as
    // the inventory builds it, and this tab also renders a same-situation bulk
    // header carrying that identical summary — a widget test scoped to one row
    // cannot see that the page as a whole still reads correctly. And the count
    // shape starts in the dispatch's `ChangeSet`, travels through the
    // alternative collapse, and only becomes a line of text in the tile.
    useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    const String summary =
        'Werk het ledenbestand van GBS-1A bij (1 toevoegen, 1 verwijderen)';
    final Finder row = find.byKey(const ValueKey('class-row-1A'));
    expect(
        find.descendant(of: row, matching: find.text(summary)), findsOneWidget);

    final Finder tile = find.byKey(const ValueKey('entry-group-1A'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // Once, still — the decision's heading replaced the preview instead of
    // joining it, and it is the heading that stayed: it groups the diff under
    // it and it still names the system the write lands in (#281/#298).
    expect(
      find.descendant(of: row, matching: find.text(summary)),
      findsOneWidget,
      reason: 'the card said it twice, one line above the other',
    );
    final Finder block = find.byKey(const ValueKey('entry-choice-group-1A-0'));
    expect(find.descendant(of: block, matching: find.text(summary)),
        findsOneWidget);
    expect(find.descendant(of: block, matching: find.text('Office 365 ·')),
        findsOneWidget);

    // The numbers under it read as the quantities they are.
    expect(
        find.descendant(of: block, matching: find.text('leden toevoegen: 1')),
        findsOneWidget);
    expect(
        find.descendant(of: block, matching: find.text('leden verwijderen: 1')),
        findsOneWidget);
    expect(find.textContaining('∅ →'), findsNothing,
        reason: 'a count is not a field whose old value was empty');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an Office 365 group Graph already holds under our address is adopted, '
      'and the create stops being offered end-to-end (#280)',
      (WidgetTester tester) async {
    // The loop #272 made visible. Office 365 already holds `5WW1`'s group — it
    // answers on `GBS-5WW1@student.school.example` — but somebody renamed its
    // display name, and the pull is `startswith(displayName,'GBS')` and nothing
    // else. So the group was invisible to every sync, the linker kept proposing
    // the create, and every apply died on the create's own pre-create guard
    // (`mailNickname eq` sees exactly what the pull cannot) with advice to sync
    // again that provably could not help.
    //
    // Only a full run can show the fix: the back-fill lives in the production
    // Azure pull, the adoption has to survive `link()`'s Azure-group match, and
    // "the create is no longer offered" is a claim about the class card the
    // dispatch, the inventory and the shell compose together. A scripted Azure
    // snapshot would beg the question by handing the app the group it is
    // supposed to go and find.
    useTallWindow(tester);
    final harness = renamedClassGroupHarness();
    final azureWire = harness.azureTransport! as RenamedClassGroupGraph;
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    // The pull did ask the prefix-scoped list first, and it did come back
    // blind — so the group can only have arrived on the targeted read.
    expect(azureWire.groupListReads, greaterThanOrEqualTo(1));
    expect(azureWire.nicknameLookups, ["mailNickname in ('GBS-5WW1')"],
        reason: 'only the address the pull could not account for is asked '
            'about — the bounded pull stays bounded');

    // The class is on the inventory carrying its group, and what it needs is
    // the roster, not a create: the adopted group holds one of the two
    // students.
    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-5WW1')), findsOneWidget);
    expect(
      find.textContaining(
          'Werk het ledenbestand van GBS-5WW1 bij (1 toevoegen'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Maak de Office 365-groep GBS-5WW1'),
      findsNothing,
      reason: 'the group exists — offering to make it is the whole bug',
    );

    List<String> kindsFor5WW1() => harness.controller.pendingEntries
        .where((e) => e.targetId == '5WW1')
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toList();
    expect(kindsFor5WW1(), isNot(contains('CreateAzureClassGroup')));
    expect(kindsFor5WW1(), contains('SyncAzureClassGroupMembers'));

    // …and it stays gone. "Synchroniseer Azure opnieuw" is what the refusal
    // used to advise and what nothing could satisfy; a second pass now adopts
    // the group again rather than re-offering the create.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    await openKlasgroepen(tester);

    expect(
      find.textContaining('Maak de Office 365-groep GBS-5WW1'),
      findsNothing,
    );
    expect(kindsFor5WW1(), isNot(contains('CreateAzureClassGroup')));
    expect(harness.graph.createdGroups, isEmpty,
        reason: 'no duplicate group was ever written');
    expect(azureWire.createdGroups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Klasgroepen tab is a full class inventory with a presence column '
      'per system, and highlights the classes that need work end-to-end '
      '(#227)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation, real rail. Our school runs
    // `1A` — correct in all three systems — and the sub-grouped `2F`
    // (`2F ECO` + `2F MAW`), which has no Office 365 group; `GBS-9Z` is the
    // group of a class that is gone.
    //
    // This is the layer that sees what the issue is about. The inventory is
    // composed from the *stored* documents (which only the materializer fills)
    // while the interactive halves come from the live dispatch, and the tab has
    // to be reachable from the shell at all — three different halves of the app
    // that only a full run puts on screen together. The motivating bug (#225's
    // `2G`) was invisible precisely because every row in the old list was a
    // change; a row that is right has to be on screen for a wrong one to stand
    // out.
    useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);
    expect(find.byType(ClassGroupsScreen), findsOneWidget);

    // Every class is a row — `1A` included, which raises nothing at all and so
    // had no stored document whatsoever before this issue.
    final healthy = find.byKey(const ValueKey('class-row-1A'));
    expect(healthy, findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-2F MAW')), findsOneWidget);
    final needsWork = find.byKey(const ValueKey('entry-group-2F ECO'));
    expect(needsWork, findsOneWidget);
    expect(find.byKey(const ValueKey('entry-group-GBS-9Z')), findsOneWidget);
    expect(find.textContaining('4 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget);

    // Three presence columns, and a class that is right everywhere reads as
    // three ticks plus the name of its Office 365 group.
    for (final system in const ['WISA', 'Smartschool', 'Office 365']) {
      expect(find.descendant(of: healthy, matching: find.text(system)),
          findsOneWidget);
    }
    expect(
      find.descendant(
          of: healthy, matching: find.byIcon(Icons.check_circle_outline)),
      findsNWidgets(3),
    );
    expect(find.descendant(of: healthy, matching: find.text('GBS-1A')),
        findsOneWidget);
    // The Office 365 column is per *class*: both sub-groups of `2F` name the one
    // group they share instead of each looking like a class missing its own.
    expect(find.text('deelgroep van 2F'), findsNWidgets(2));

    // The rows that need work are highlighted; the one that does not is not.
    final BuildContext context = tester.element(find.byType(ClassGroupsScreen));
    final ColorScheme colors = Theme.of(context).colorScheme;
    Color borderOf(String klas) {
      final Container box =
          tester.widget<Container>(find.byKey(ValueKey('class-row-$klas')));
      return ((box.decoration! as BoxDecoration).border! as Border).top.color;
    }

    expect(borderOf('2F ECO'), colors.primary);
    expect(
      borderOf('1A'),
      isNot(colors.primary),
      reason: 'a class that is in order must not read as one that needs work',
    );

    // The filter mirrors the Acties switch but starts **off** — the full
    // picture is this tab's job (#226/#227).
    final filter = find.byKey(const ValueKey('class-groups-only-attention'));
    expect(tester.widget<Switch>(filter).value, isFalse);
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(healthy, findsNothing);
    expect(needsWork, findsOneWidget);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(healthy, findsOneWidget);

    // And the same list is not maintained in two places: no class is a row of
    // the Acties list, which holds accounts only.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-groups')), findsNothing);
    expect(find.byKey(const ValueKey('class-row-1A')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Klasgroepen says what Acties is holding and following the line lands '
      'there, while Acties points back at nothing end-to-end (#301/#309)',
      (WidgetTester tester) async {
    // The real app, real rail, real navigation — which is the whole of #301.
    // Acties covers people and Klasgroepen covers classes, so "is everything as
    // expected?" is only answerable by visiting both, and nothing prompted the
    // operator to. The rollover is where that bites: the Smartschool class
    // change is per student on Acties while the Office 365 roster write is one
    // action per class here, so a clean Acties list can sit above a pile of
    // stale rosters.
    //
    // #309 made the pointer one-way. Acties is a list of thousands whose header
    // was five lines of preamble before anything actionable, so the line about
    // the *other* tab came off it; Klasgroepen has the room and keeps the
    // mirror. The asymmetry is the decision, and this run pins both halves of
    // it.
    //
    // Only a full run can show either. The two counts are derived on the shared
    // controller, rendered by two screens that never see each other, and the
    // link has to reach across the shell that keeps both alive — three halves a
    // widget test of either screen structurally cannot put together.
    //
    // The fixture in miniature: `3C` and `3D` both lack their Office 365 group
    // (two classes), and of the two students only Sam's Office 365 display name
    // is stale (one account).
    useTallWindow(tester);
    final harness = appliedClassWorkHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);
    expect(find.byType(ClassGroupsScreen), findsOneWidget);

    // The tab states its own inventory, and beside it what the other one is
    // holding — one derivation on the shared controller, so the pointer cannot
    // contradict the list it points at.
    expect(find.textContaining('2 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget);
    final Finder toAccounts =
        find.byKey(const ValueKey('class-groups-account-attention'));
    expect(toAccounts, findsOneWidget);
    expect(find.text('1 account(s) vragen ook aandacht op Acties.'),
        findsOneWidget);

    // Following it lands on Acties, on the one account it counted, still under
    // that screen's own work filter.
    await tester.ensureVisible(toAccounts);
    await tester.tap(toAccounts);
    await tester.pumpAndSettle();
    expect(find.byType(ActionsScreen), findsOneWidget);
    final String sam = accountId(harness, 'Sam Sels');
    final String tom = accountId(harness, 'Tom Tas');
    expect(find.byKey(ValueKey('account-row-$sam')), findsOneWidget);
    expect(find.byKey(ValueKey('account-row-$tom')), findsNothing);

    // …and there is no line back. Two classes really are waiting — the shared
    // controller says so, on this very session, with the inventory already read
    // by the tab we came from — and Acties states none of it.
    expect(harness.controller.classesNeedingAttention, 2);
    expect(find.byKey(const ValueKey('actions-class-attention')), findsNothing);
    expect(find.textContaining('aandacht op Klasgroepen'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Acties header is one line, and the account list starts near the top '
      'of a real window end-to-end (#309)', (WidgetTester tester) async {
    // The reason the header was stripped, at the size it was costing something.
    // On a 1080p window the eyebrow, the title, the count line, the pointer at
    // Klasgroepen and the freshness stamp — plus the search box, the work
    // switch and the filter chips under them — pushed the list into the lower
    // half of the screen: two or three accounts at a time, on the view whose
    // whole purpose is the list.
    //
    // A widget test cannot answer this. It renders the screen at whatever
    // viewport it likes, in Ahem, outside the shell — so it can say the header
    // has one line but not where the list ends up for the operator. This runs
    // the real app in the real fonts at the real window size and measures it:
    // the list top moved from 575 to 373 of 1080, from below the halfway mark
    // to inside the top third — to 325 once #310 folded the work-list switch
    // onto the search box's own row, and to 218 once #311 took the select-all
    // bar out from between the chips and the list.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final harness = appliedClassWorkHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // The header is the eyebrow, and the four lines that used to follow it are
    // nowhere on the screen.
    expect(find.text('ARCADIA · ACTIES'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.text('Acties'),
      ),
      findsNothing,
      reason: 'the title restated the eyebrow; the rail label is not it',
    );
    expect(find.textContaining('openstaande actie(s)'), findsNothing);
    expect(find.byKey(const ValueKey('actions-class-attention')), findsNothing);
    expect(find.textContaining('Generatie'), findsNothing);

    // The list starts inside the top quarter of the window instead of below the
    // middle of it — measured in the real font, in the real shell, with the
    // real rail beside it.
    final Finder list = find.byKey(const ValueKey('actions-list'));
    expect(tester.getTopLeft(list).dy, lessThan(1080 / 4));
    // Which is the same statement from the operator's side: the list, not the
    // preamble above it, gets the majority of the window it is the point of.
    expect(tester.getSize(list).height, greaterThan(1080 * 0.7));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Acties name box is a name-sized box beside the work-list switch on '
      'a real window, and folds instead of overflowing when the window '
      'narrows end-to-end (#310)', (WidgetTester tester) async {
    // A widget test renders these controls at whatever viewport it likes, in a
    // test font, outside the shell. Both halves of #310 are about the real
    // thing: how much of a *1920px window with the rail beside it* a name field
    // was claiming, and whether the row folds or spills when that window is
    // dragged narrow. The fold in particular runs through the real text metrics
    // of a 30-character Dutch label — the exact place a fixed-width box would
    // have overflowed in the app but not in Ahem.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final harness = appliedClassWorkHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final Finder searchFinder = find.byKey(const ValueKey('actions-search'));
    final Finder toggleFinder =
        find.byKey(const ValueKey('actions-only-with-actions'));
    Rect search = tester.getRect(searchFinder);
    Rect toggle = tester.getRect(toggleFinder);

    // One row: the switch and its label stand to the right of the box and
    // overlap it vertically, rather than sitting on a row of their own.
    expect(toggle.left, greaterThan(search.right));
    expect(toggle.top, lessThan(search.bottom));
    expect(search.top, lessThan(toggle.bottom));
    final Rect label =
        tester.getRect(find.text('Toon enkel accounts met acties'));
    expect(label.left, greaterThan(toggle.right));
    expect(label.top, lessThan(search.bottom));

    // Name-sized, not window-sized. The Acties pane is the full 1920 minus the
    // navigation rail, and the box used to be exactly that wide.
    final double paneWidth = tester.getSize(find.byType(ActionsScreen)).width;
    expect(paneWidth, greaterThan(1500),
        reason: 'the rail leaves the pane most of a 1920px window');
    expect(search.width, lessThanOrEqualTo(380));
    expect(search.width, lessThan(paneWidth / 4),
        reason: 'the box stops a long way short of the content width');

    // Now drag the window narrow — narrower than the box, the switch and the
    // label side by side. The switch takes a second run and nothing overflows.
    tester.view.physicalSize = const Size(900, 1080);
    await tester.pumpAndSettle();
    search = tester.getRect(searchFinder);
    toggle = tester.getRect(toggleFinder);
    expect(toggle.top, greaterThanOrEqualTo(search.bottom),
        reason: 'the row folded rather than spilling off the right');
    expect(search.width, lessThanOrEqualTo(380));
    expect(search.right, lessThanOrEqualTo(900));
    expect(toggle.right, lessThanOrEqualTo(900));
    expect(tester.takeException(), isNull);

    // And it is still the working switch, not a decoration that survived the
    // fold: flipping it here gives the whole school back (#226).
    final String tom = accountId(harness, 'Tom Tas');
    expect(find.byKey(ValueKey('account-row-$tom')), findsNothing);
    await tester.ensureVisible(toggleFinder);
    await tester.pumpAndSettle();
    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('account-row-$tom')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Klasgroepen inventory is searchable by class name and description, '
      'composing with the attention switch end-to-end (#262)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation, real rail, real keyboard
    // input. The search is a filter over the *composed* inventory: the rows
    // come from the stored documents, the interactive halves and the "same
    // situation" bulk headers from the live dispatch, and the switch is a
    // second filter over the same list — a widget test sees the row builder,
    // not what a needle does to all four of those at once.
    //
    // Our school runs `1A` ("Eerste jaar A"), the sub-grouped `2F`
    // (`2F ECO` + `2F MAW`, both "Tweede jaar F") and the leftover `GBS-9Z`.
    useTallWindow(tester);
    final harness = azureClassGroupHarness(withStaleGroup: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    final search = find.byKey(const ValueKey('class-groups-search'));
    final filter = find.byKey(const ValueKey('class-groups-only-attention'));
    Finder row(String klas) => find.byKey(ValueKey('class-row-$klas'));
    Future<void> type(String needle) async {
      await tester.ensureVisible(search);
      await tester.enterText(search, needle);
      await tester.pumpAndSettle();
    }

    expect(search, findsOneWidget);
    expect(row('1A'), findsOneWidget);
    expect(row('2F ECO'), findsOneWidget);
    expect(row('GBS-9Z'), findsOneWidget);

    // By name: one class out of the whole inventory, which is the question the
    // operator arrived with ("is `1A` right?") and used to answer by scrolling.
    await type('1a');
    expect(row('1A'), findsOneWidget);
    expect(row('2F ECO'), findsNothing);
    expect(row('2F MAW'), findsNothing);
    expect(row('GBS-9Z'), findsNothing);

    // By description — "tweede" is in no class *name* at all, and a class is
    // looked up by what it teaches as often as by its code.
    await type('tweede');
    expect(row('2F ECO'), findsOneWidget);
    expect(row('2F MAW'), findsOneWidget);
    expect(row('1A'), findsNothing);

    // Per-part and order-independent, exactly like the two Personeel searches
    // (#187/#215/#217), and one needle may span name and description.
    await type('maw tweede');
    expect(row('2F MAW'), findsOneWidget);
    expect(row('2F ECO'), findsNothing);

    // Nothing matched says so — and not in the words of an inventory that was
    // never synced, nor of a school where everything is in order.
    await type('1a tweede');
    expect(
        find.text('Geen klassen die aan de filter voldoen.'), findsOneWidget);
    expect(find.textContaining('Nog geen klasinventaris'), findsNothing);
    expect(find.textContaining('Elke klas staat in orde'), findsNothing);

    // The two filters compose (#262): the switch narrows what the search left.
    // `2F ECO` carries the missing-group work; `2F MAW` shares that group and
    // so asks nothing of its own.
    await type('2f');
    expect(row('2F ECO'), findsOneWidget);
    expect(row('2F MAW'), findsOneWidget);
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(row('2F ECO'), findsOneWidget);
    expect(row('2F MAW'), findsNothing);
    expect(row('GBS-9Z'), findsNothing,
        reason: 'it needs attention, but the search is still on');

    // Clearing the box restores the inventory the switch still governs.
    await tester.ensureVisible(search);
    await tester.tap(find.byKey(const ValueKey('class-groups-search-clear')));
    await tester.pumpAndSettle();
    expect(row('GBS-9Z'), findsOneWidget);
    expect(row('1A'), findsNothing, reason: 'the switch survives the clear');
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(row('1A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Klasgroepen lists only class-shaped Office 365 groups, and a stale one '
      'is deleted from its own row end-to-end (#271)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation, real rail. Our school runs
    // `1A`, correct everywhere; Office 365 still holds `GBS-9Z` and `GBS-8Y`,
    // the groups of two classes that stopped running, plus four prefixed groups
    // that were never classes at all (`GBS - GOK`, `GBS-OKAN`,
    // `GBS - Leerlingenraad`, `GBS - Frans - 3D`).
    //
    // This is the layer that sees what the issue is about. The inventory is
    // composed from the *stored* documents while the card's controls come from
    // the live dispatch, the bulk headers from a third derivation, and the row
    // only disappears once the write, the relink and the store patch have all
    // landed — halves of the app that only a full run puts on screen together.
    // And the action under test is destructive: a widget test rendering the row
    // in isolation cannot show that the whole tab still offers no bulk pass
    // over these groups now that the delete is each row's selected resolution
    // (#327).
    useTallWindow(tester);
    final harness = staleClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);
    expect(find.byType(ClassGroupsScreen), findsOneWidget);

    Finder row(String klas) => find.byKey(ValueKey('class-row-$klas'));

    // A prefixed group that is not class-shaped is not a class group, so it is
    // in no class inventory. Each of these was a row before #271 — carrying a
    // ✓ and no action anybody could take.
    for (final name in const [
      'GBS - GOK',
      'GBS-OKAN',
      'GBS - Leerlingenraad',
      'GBS - Frans - 3D',
    ]) {
      expect(row(name), findsNothing, reason: '$name is not a class');
    }
    // The class-shaped leftovers stay listed: those are old classes, and seeing
    // them is the point.
    expect(row('1A'), findsOneWidget);
    expect(row('GBS-9Z'), findsOneWidget);
    expect(row('GBS-8Y'), findsOneWidget);
    expect(find.textContaining('3 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget);

    // Both stale groups share one situation, so the tab collects them under a
    // bulk header — and that header offers no bulk pass at all, because the
    // delete withholds the #293 sanction and #326 taught the header to read it.
    // A bulk affordance here would take two mailboxes, Teams and file libraries
    // on one click, and since #327 the delete is each row's *selected*
    // resolution rather than a radio away.
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
    expect(find.textContaining('Alles toepassen ('), findsNothing,
        reason: 'a bulk pass over stale groups must write nothing at all');

    // The row proposes exactly one thing — no radios, no "laat de groep staan"
    // no-op to read past (#327).
    final entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(
      find.text('Verwijder de Office 365-groep GBS-9Z van de verdwenen '
          'klas 9Z'),
      findsWidgets,
    );
    expect(find.textContaining('Laat de Office 365-groep GBS-9Z staan'),
        findsNothing);
    expect(find.byKey(const ValueKey('alt-GBS-9Z-DeleteAzureClassGroup')),
        findsNothing,
        reason: 'a lone action renders no radio at all');
    expect(find.text('Kies één oplossing:'), findsNothing);
    // What the delete takes with it, on the card, before anything is pressed.
    expect(find.text('leden: 21'), findsOneWidget);
    expect(find.text('postvak, Teams en bestanden: verdwijnen mee'),
        findsOneWidget);
    expect(harness.graph.deletedGroups, isEmpty,
        reason: 'opening a card writes nothing');

    final apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(harness.graph.deletedGroups, isEmpty,
        reason: 'the confirmation dialog is still standing');
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Exactly the one group the operator picked — and the row is gone with it,
    // rather than lingering claiming a group that no longer exists.
    expect(harness.graph.deletedGroups, ['az-GBS-9Z']);
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(row('GBS-9Z'), findsNothing);
    expect(row('GBS-8Y'), findsOneWidget,
        reason: 'the class beside it was never selected');
    expect(row('1A'), findsOneWidget);

    // And a class that still runs is offered no delete at all.
    expect(find.byKey(const ValueKey('alt-1A-DeleteAzureClassGroup')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a stale group the delete cannot address keeps its lone "(manueel)" '
      'notice end-to-end (#327)', (WidgetTester tester) async {
    // The other side of #327. `GBS-9Z` is stale exactly as above, but the
    // tenant handed us no object id for it, so there is nothing to address a
    // `DELETE /groups/` to. That is the one case where "leave it standing" is
    // not a no-op dressed as a choice but the honest whole content of the row —
    // and it must survive as the informational, "(manueel)"-marked notice it
    // always was, with no apply of its own.
    //
    // End-to-end because the claim spans three surfaces a widget test sees
    // separately: the collapsed row line (composed from the *stored* candidate
    // document), the expanded card (from the live dispatch), and the tab's
    // bulk header — plus the entry-level Toepassen button, which is gated on
    // the whole card rather than on this decision.
    useTallWindow(tester);
    final harness = staleClassGroupHarness(idlessStaleGroup: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    // The collapsed row states the situation and marks it as hand work.
    expect(find.textContaining('Laat de Office 365-groep GBS-9Z staan'),
        findsWidgets);
    expect(find.textContaining('(manueel)'), findsWidgets);
    expect(find.textContaining('(keuze)'), findsNothing,
        reason: 'a lone notice is not a choice');

    final Finder entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // No delete on offer, and nothing on the card can write.
    expect(find.textContaining('Verwijder de Office 365-groep GBS-9Z'),
        findsNothing);
    expect(find.text('Kies één oplossing:'), findsNothing);
    expect(find.text('leden: 21'), findsOneWidget,
        reason: 'the notice still states what the group holds');
    final Finder apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(harness.graph.deletedGroups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a whole cohort of stale groups set to delete still arms no bulk pass, '
      'end-to-end (#326/#327)', (WidgetTester tester) async {
    // The reported hole, in the real app. `GBS-9Z` and `GBS-8Y` are the Office
    // 365 groups of two classes that stopped running, so Klasgroepen files them
    // under one "same situation" header. That header counted
    // `PendingDecision.canApply` — "does the selected option write anything" —
    // and never the #293 sanction the action itself declares. So what kept a
    // delete off the bulk path was not the sanction at all: it was the
    // *polarity* of the pair, the notice being pre-selected. Two flipped radios
    // and the header read "Alles toepassen (2)", one confirmation away from
    // taking two mailboxes, two Teams and two file libraries.
    //
    // #327 then removed the pair outright, so the delete is now the selected
    // resolution of every stale row from the moment the tab opens — the state
    // that used to take four taps to reach is the *default*. Which makes #326's
    // guard the only thing standing between this cohort and one press.
    //
    // Only a full run can see it. The cards are rendered per row from the live
    // dispatch; the header is a separate derivation over the whole tab, above
    // the inventory rather than beside the rows it acts on. A widget test that
    // renders the header in isolation is handed a cohort somebody else built,
    // which is precisely the seam that drifted.
    useTallWindow(tester);
    final harness = staleClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    // Both rows are set to a delete out of the box (#327), and the header
    // offers nothing: the sanction is a property of the action, not of how many
    // rows happen to be set to it. Since #326 the pair is *absent* rather than
    // dead at (0) — a disabled button invites the operator to go and make it
    // live, which is the very move this guards against.
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget,
        reason: 'the cohort is still named; only the bulk pair is withdrawn');
    expect(find.textContaining('Alles toepassen ('), findsNothing,
        reason: 'a cohort of selected deletes must never arm a bulk pass');
    expect(find.text('Dry-run alles'), findsNothing);

    // Each row really is set to its delete — the state that used to need a
    // flipped radio on every one of them.
    for (final String id in const <String>['GBS-9Z', 'GBS-8Y']) {
      final Finder entry = find.byKey(ValueKey('entry-group-$id'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      final Finder rowApply = find.byKey(ValueKey('entry-apply-$id'));
      await tester.ensureVisible(rowApply);
      expect(tester.widget<FilledButton>(rowApply).onPressed, isNotNull);
      expect(find.textContaining('Verwijder de Office 365-groep $id'),
          findsWidgets);
      // Collapse again so the next row is reachable on the same page.
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Alles toepassen ('), findsNothing);
    expect(harness.graph.deletedGroups, isEmpty);

    // What the operator kept is the per-row path: one group at a time, from the
    // card that shows what the write would do.
    final Finder entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final Finder apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.graph.deletedGroups, ['az-GBS-9Z']);
    expect(find.byKey(const ValueKey('class-row-GBS-8Y')), findsOneWidget,
        reason: 'the group beside it proposes the same delete, and still '
            'stands — one press, one group');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the class groups the legacy app left behind offer their delete too, '
      'end-to-end (#312)', (WidgetTester tester) async {
    // The reported bug, in the real app. Our school runs `1A`; Office 365 still
    // holds two groups of classes that stopped running, and neither is shaped
    // the way *this* port creates one:
    //
    //   GBS-9Z            a plain security group with no address — how the
    //                     legacy WPF app made every class group, and how
    //                     `SSM-3ECO`, `SSM-3MRP`, `SSM-3MWW` … sit in the live
    //                     tenant today;
    //   Klas van juf An   renamed by hand in the portal, still answering on
    //                     `GBS-8Y@…`.
    //
    // The linker orphans both, so both were Klasgroepen rows — each with a grey
    // ✓ and no action anybody could take, the exact state #271 set out to
    // remove. Only a full run shows that: the inventory is composed from the
    // *stored* documents while the either/or radios come from the live
    // dispatch, the bulk header from a third derivation, and "the tab still
    // writes nothing by default" is a claim about the page as composed.
    useTallWindow(tester);
    final harness = legacyStaleClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    Finder row(String klas) => find.byKey(ValueKey('class-row-$klas'));

    expect(row('1A'), findsOneWidget);
    expect(row('GBS-9Z'), findsOneWidget);
    expect(row('Klas van juf An'), findsOneWidget);
    expect(find.textContaining('3 klas(sen), waarvan 2 aandacht vragen'),
        findsOneWidget,
        reason: 'both leftovers now ask something instead of showing a ✓');

    // Widened, not loosened: the delete is not bulk-sanctioned, so the tab
    // offers no bulk pass over these groups at all (#293/#326) even though it
    // is now each row's selected resolution (#327).
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
    expect(find.textContaining('Alles toepassen ('), findsNothing);

    // The renamed group is its class's group by the address it answers on
    // (#280), so its row carries the delete under the name somebody typed over
    // it.
    final renamed = find.byKey(const ValueKey('entry-group-Klas van juf An'));
    await tester.ensureVisible(renamed);
    await tester.tap(renamed);
    await tester.pumpAndSettle();
    expect(
      find.text('Verwijder de Office 365-groep Klas van juf An van de '
          'verdwenen klas 8Y'),
      findsWidgets,
    );
    await tester.tap(renamed);
    await tester.pumpAndSettle();

    // The security group's own row: 21 members still in it, and no line
    // claiming an address, because it has none.
    final entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(
      find.text('Verwijder de Office 365-groep GBS-9Z van de verdwenen '
          'klas 9Z'),
      findsWidgets,
    );
    expect(find.text('leden: 21'), findsOneWidget);
    expect(find.text('mail: '), findsNothing,
        reason: 'a security group has no address, so no line states one');

    final apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Exactly the one group the operator pressed on, and its row goes with it.
    expect(harness.graph.deletedGroups, ['az-GBS-9Z']);
    expect(row('GBS-9Z'), findsNothing);
    expect(row('Klas van juf An'), findsOneWidget,
        reason: 'the group beside it was never applied');
    expect(row('1A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a Smartschool class WISA does not have proposes its delete and nothing '
      'else, end-to-end (#313/#328)', (WidgetTester tester) async {
    // The reported bug, in the real app. Our school runs `1A`; Smartschool
    // still carries `9Z` and `8Y`, two official classes WISA has no counterpart
    // for. Each row's whole content used to be
    //
    //   Deze klas bestaat in Smartschool maar niet in WISA. Verwijder ze
    //   manueel als ze niet meer nodig is. (manueel)
    //
    // — an instruction to go and repeat the same judgement by hand in
    // Smartschool's own UI, with `Toepassen` dead on the row. #313 put a delete
    // beside it, and #328 dropped the "laat deze klas staan" half: that option
    // and "doe niets" are the same act, and the operator performs the second by
    // not pressing Toepassen. What the half also *said* — that a lagging WISA
    // snapshot is the common cause — survives as a line on the card.
    //
    // Only a full run shows it: the inventory is composed from the *stored*
    // documents while the card's controls come from the live dispatch, the
    // same-situation bulk header from a third derivation, and "no bulk pass
    // over a cohort of selected deletes" is a claim about the page as composed.
    // The write itself has to travel the real Smartschool connector — a
    // `delClass` addressed to the class **code**, not the name on screen.
    useTallWindow(tester);
    final harness = smartschoolLeftoverClassHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    Finder row(String klas) => find.byKey(ValueKey('class-row-$klas'));

    expect(row('1A'), findsOneWidget);
    expect(row('9Z'), findsOneWidget);
    expect(row('8Y'), findsOneWidget);
    expect(find.textContaining('Verwijder ze manueel'), findsNothing,
        reason: 'the app has the API to act on this; it stops delegating');

    // Both rows are set to a delete out of the box (#328), and the header
    // offers nothing: the sanction is a property of the action, not of how many
    // rows happen to be set to it (#293/#326). A bulk affordance here would
    // take two classes with every membership and subgroup under them.
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
    expect(find.textContaining('Alles toepassen ('), findsNothing);
    expect(find.text('Dry-run alles'), findsNothing);

    final entry = find.byKey(const ValueKey('entry-group-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // One proposal, no radios, no no-op to read past.
    expect(
      find.text('Verwijder de klas 9Z uit Smartschool — ze bestaat niet in '
          'WISA'),
      findsWidgets,
    );
    expect(find.textContaining('Laat deze klas staan'), findsNothing);
    expect(find.byKey(const ValueKey('alt-9Z-DeleteSmartschoolClass')),
        findsNothing,
        reason: 'a lone action renders no radio at all');
    expect(find.text('Kies één oplossing:'), findsNothing);

    // The class's facts, the caution the dropped default used to carry, and the
    // inventory of what goes — all on the card, before anything is pressed.
    expect(find.text('code: C9Z'), findsOneWidget);
    expect(find.text('omschrijving: Zesde jaar Z'), findsOneWidget);
    expect(
      find.text('WISA: kent deze klas (nog) niet — vroeg in het schooljaar '
          'loopt WISA achter, controleer daar of ze bestaat voor je ze '
          'verwijdert'),
      findsOneWidget,
      reason: 'the card warns; it does not offer waiting as a resolution',
    );
    expect(find.text('lidmaatschappen en subgroepen: verdwijnen mee'),
        findsOneWidget);
    expect(find.textContaining('→ ∅'), findsNothing,
        reason: 'the inventory of what goes is stated, never diffed');
    expect(harness.soap.deletedClasses, isEmpty,
        reason: 'opening a card writes nothing');

    final apply = find.byKey(const ValueKey('entry-apply-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(harness.soap.deletedClasses, isEmpty,
        reason: 'the confirmation dialog is still standing');
    expect(find.textContaining('9Z'), findsWidgets,
        reason: 'the dialog names the class it is about to take');
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Exactly the one class the operator pressed on, addressed by its code, and
    // its row goes with it.
    expect(harness.soap.deletedClasses, ['C9Z']);
    expect(row('9Z'), findsNothing);
    expect(row('8Y'), findsOneWidget,
        reason: 'the class beside it proposes the same delete, and still '
            'stands — one press, one class');
    expect(row('1A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a Smartschool leftover the delete cannot address keeps its lone '
      '"(manueel)" notice end-to-end (#328)', (WidgetTester tester) async {
    // The other side of #328. `9Z` is a leftover exactly as above, but
    // Smartschool handed us no class code for it, so there is nothing to
    // address a `delClass` to. That is the one case where "leave it standing"
    // is not a no-op dressed as a choice but the honest whole content of the
    // row — and it must survive as the informational, "(manueel)"-marked notice
    // it always was, with no apply of its own.
    //
    // End-to-end because the claim spans three surfaces a widget test sees
    // separately: the collapsed row line (composed from the *stored* candidate
    // document), the expanded card (from the live dispatch), and the tab's bulk
    // header — plus the entry-level Toepassen button, which is gated on the
    // whole card rather than on this decision.
    useTallWindow(tester);
    final harness = smartschoolLeftoverClassHarness(codelessLeftover: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    // The collapsed row states the situation and marks it as hand work.
    expect(find.textContaining('Laat deze klas staan'), findsWidgets);
    expect(find.textContaining('(manueel)'), findsWidgets);
    expect(find.textContaining('(keuze)'), findsNothing,
        reason: 'a lone notice is not a choice');

    final Finder entry = find.byKey(const ValueKey('entry-group-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // No delete on offer, and nothing on the card can write.
    expect(find.textContaining('Verwijder de klas 9Z uit Smartschool'),
        findsNothing);
    expect(find.text('Kies één oplossing:'), findsNothing);
    expect(find.textContaining('controleer daar of ze bestaat'), findsNothing,
        reason: 'nothing is proposed here, so there is nothing to caution '
            'against pressing');
    expect(find.text('omschrijving: Zesde jaar Z'), findsOneWidget,
        reason: 'the notice still states what the class is');
    final Finder apply = find.byKey(const ValueKey('entry-apply-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(harness.soap.deletedClasses, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a stale group\'s card states its facts end-to-end, it does not diff '
      'them (#305/#327)', (WidgetTester tester) async {
    // The reported card, in the real app. `GBS-9Z` is the group of a class that
    // stopped running, still holding its 21 members. Its card read
    //
    //   Laat de Office 365-groep GBS-9Z staan — klas 9Z bestaat niet meer …
    //   mail: GBS-9Z@student.school.example → ∅
    //   leden: 21 → ∅
    //
    // — a heading promising the group stays, over two lines saying its address
    // and its 21 members are going away. Since #327 that heading is gone with
    // the no-op it named, and the card leads with the delete; the fields are
    // the inventory of what goes with the group, which is a statement, not a
    // diff against an empty half.
    //
    // End-to-end rather than on the widget alone, because the shape has to
    // survive the whole path the operator's card is built from: the group
    // dispatch's `ChangeSet`, the collapse into one decision, the choice
    // heading, and only then a line of text in the tile. And "no arrow
    // anywhere" is a claim about the page as composed — this tab also renders a
    // same-situation bulk header over the two stale groups, which a row-scoped
    // widget test cannot see.
    useTallWindow(tester);
    final harness = staleClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    final entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // The card's only heading is the delete's own summary, and under it the
    // inventory of what the delete takes.
    expect(
      find.text('Verwijder de Office 365-groep GBS-9Z van de verdwenen '
          'klas 9Z'),
      findsWidgets,
    );
    expect(find.textContaining('Laat de Office 365-groep GBS-9Z staan'),
        findsNothing);
    expect(find.text('mail: GBS-9Z@student.school.example'), findsOneWidget);
    expect(find.text('leden: 21'), findsOneWidget);
    expect(find.text('postvak, Teams en bestanden: verdwijnen mee'),
        findsOneWidget);
    expect(find.textContaining('→ ∅'), findsNothing,
        reason: 'the inventory of what goes is stated, never diffed — and no '
            'other card on this page diffs against an empty half either');
    expect(harness.graph.deletedGroups, isEmpty,
        reason: 'reading a card writes nothing on its own');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      "a student's Office 365 class group is reported on their own account "
      'end-to-end, pointing at the one class-level write (#245)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Both classes already have
    // their group and are in sync with Smartschool, so the Azure roster is the
    // only work: Jane is missing from her own GBS-1A, and Sam — who moved to
    // 1B — is missing from GBS-1B while still sitting in GBS-1A.
    //
    // This is the layer that sees what the issue is actually about: whether an
    // operator who opens *one* student finds their class-group placement there
    // at all. The Klasgroepen row and the account row are two projections of the
    // same dispatch, composed by different screens, and only a full-app run
    // shows both and proves the write is offered exactly once.
    useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The class rows still carry the single applyable write, on both classes.
    await openKlasgroepen(tester);
    // (Both classes raise the same kind of action, so the tab also renders a
    // "same situation" bulk header carrying the first one's summary — hence
    // findsWidgets rather than findsOneWidget.)
    expect(
      find.textContaining('Werk het ledenbestand van GBS-1A bij '
          '(1 toevoegen, 1 verwijderen)'),
      findsWidgets,
    );
    expect(
      find.textContaining('Werk het ledenbestand van GBS-1B bij (1 toevoegen'),
      findsWidgets,
    );

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // Nothing applyable hangs off either class's *students*, so the work list
    // holds neither — the switch is what turns the view into the inventory an
    // operator answering a phone call browses (#226).
    final String samId = accountId(harness, 'Sam Sels');
    final String janeId = accountId(harness, 'Jane Doe');
    expect(find.byKey(ValueKey('account-row-$samId')), findsNothing);
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Sam: one line, naming both groups, in the details pane beside his row.
    await selectAccount(tester, samId);
    expect(
      find.textContaining(
          'Zit in de verkeerde Office 365-klasgroep: GBS-1A in plaats van '
          'GBS-1B'),
      findsOneWidget,
    );

    // Jane: the plain "missing from her own group" reading, one row away — no
    // going back out to an overview in between.
    await selectAccount(tester, janeId);
    expect(
      find.textContaining('Ontbreekt in de Office 365-klasgroep GBS-1A'),
      findsOneWidget,
    );

    // And the account view offers no second write for the same fact: only the
    // two class-level syncs are applyable anywhere.
    final applyable = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .where((a) => a.canApply)
        .map((a) => a.kind)
        .toList();
    expect(applyable,
        ['SyncAzureClassGroupMembers', 'SyncAzureClassGroupMembers']);
  });

  testWidgets(
      'a class group Graph will not manage is diagnosed, not proposed for a '
      'write that always fails, end-to-end (#331)',
      (WidgetTester tester) async {
    // The reported bug, in the real app. `GBS-1A` is a mail-enabled security
    // group — Exchange Online masters its membership, so Graph refuses every
    // add and every remove. The class card offered "Werk het ledenbestand van
    // GBS-1A bij", the operator pressed Toepassen, all 38 changes failed, and
    // the identical proposal was back on the next pass. Forever.
    //
    // End-to-end because the claim spans surfaces a unit test sees one at a
    // time: the class card in Klasgroepen (composed from the stored candidate
    // document plus the live dispatch), the per-student row in Acties (a second
    // projection of the same dispatch), and the Graph transport underneath —
    // which must stay untouched even while the operator reads and expands.
    useTallWindow(tester);
    final harness = unmanageableClassGroupHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    // The doomed proposal is gone from the screen entirely — not merely failing
    // more legibly than it used to (#330).
    expect(
        find.textContaining('Werk het ledenbestand van GBS-1A'), findsNothing,
        reason: 'no write may be offered on a group Graph refuses');
    expect(
      find.textContaining(
          'De Office 365-groep GBS-1A is een mail-enabled beveiligingsgroep'),
      findsWidgets,
    );
    expect(find.textContaining('(manueel)'), findsWidgets);
    expect(find.textContaining('(keuze)'), findsNothing,
        reason: 'a lone notice is not a choice');

    // The card states the shape, the address and how far the roster has drifted
    // while nobody could write to it — and offers no apply of its own.
    final Finder entry = find.byKey(const ValueKey('entry-group-1A'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('type: mail-enabled beveiligingsgroep'), findsOneWidget);
    expect(find.textContaining('niet gesynchroniseerd: 1 toe te voegen'),
        findsOneWidget);
    final Finder apply = find.byKey(const ValueKey('entry-apply-1A'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);

    // Nothing anywhere in the app is willing to write to this group.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .where((a) => a.canApply)
          .map((a) => a.kind)
          .toList(),
      isEmpty,
    );
    expect(harness.graph.batchedWrites, isEmpty);

    // And the student who is missing from it is told where the remedy lives,
    // instead of being sent to a class card that no longer offers one.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await selectAccount(tester, accountId(harness, 'Joe Sels'));
    expect(
      find.textContaining('Ontbreekt in de Office 365-klasgroep GBS-1A'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Die groep wordt in Exchange Online beheerd'),
      findsOneWidget,
    );
    expect(find.textContaining('Werk het ledenbestand van klas 1A bij'),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the very same class on a Microsoft 365 group still gets its roster '
      'write end-to-end (#331)', (WidgetTester tester) async {
    // The control, and the reason the guard is narrow: one class, one student
    // missing, one address — the *only* difference from the test above is
    // `groupTypes: ["Unified"]` instead of `securityEnabled: true`. If the guard
    // ever widened to "anything mail-enabled" or "anything security-enabled" it
    // would silence the write on the 371 groups that work, and this is what
    // would say so.
    useTallWindow(tester);
    final harness = unmanageableClassGroupHarness(manageable: true);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);

    expect(
      find.textContaining('Werk het ledenbestand van GBS-1A bij (1 toevoegen'),
      findsWidgets,
    );
    expect(find.textContaining('mail-enabled beveiligingsgroep'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a system cell means "work you can do on this screen": the class that '
      'carries the Office 365 roster write says so, the students it diagnoses '
      'do not, end-to-end (#298)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation, real rail. Same #245 fixture:
    // every class exists in all three systems and is in sync with Smartschool,
    // so the *only* work anywhere is the Azure roster — which is exactly the
    // state that used to render three ticks and say nothing.
    //
    // Only a full-app run puts both halves of the rule on screen at once. The
    // Klasgroepen cells are composed from the stored documents plus the live
    // dispatch, the Acties cards from a second projection of that same
    // dispatch, and the rule is that the two must disagree about who owns the
    // write: the class does, the ~3000 students do not.
    useTallWindow(tester);
    final harness = azureClassMembershipHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);
    expect(harness.controller.error, isNull);
    expect(find.byType(ClassGroupsScreen), findsOneWidget);

    SystemIndicatorState cellOf(String klas, Origin system) => tester
        .widget<SystemIndicatorCell>(
          find.byKey(ValueKey('class-cell-$klas-${system.name}')),
        )
        .state;

    // `1A` is present in all three systems, so the old reading was three ticks.
    // Under #298 the Office 365 cell carries the pending roster write while the
    // other two stay green.
    expect(cellOf('1A', Origin.wisa), SystemIndicatorState.inOrder);
    expect(cellOf('1A', Origin.smartschool), SystemIndicatorState.inOrder);
    expect(cellOf('1A', Origin.azure), SystemIndicatorState.needsWork);
    expect(cellOf('1B', Origin.azure), SystemIndicatorState.needsWork);

    // The three states are distinguishable without colour too — the icon
    // changes shape, so a monochrome screenshot still reads.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('class-cell-1A-azure')),
        matching: find.byIcon(Icons.pending_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('class-cell-1A-wisa')),
        matching: find.byIcon(Icons.check_circle_outline),
      ),
      findsOneWidget,
    );

    // And the row's own line names the system it writes to, so the cell and the
    // card agree instead of the operator having to infer it from a group name.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('class-row-1A')),
        matching: find.text('Office 365 ·'),
      ),
      findsOneWidget,
    );

    // The students the same fact is reported on are informational only, so
    // nothing over on Acties turns orange for them: their rows still carry the
    // diagnosis in the details pane, and colour no cell at all.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final String janeId = accountId(harness, 'Jane Doe');
    await selectAccount(tester, janeId);

    expect(
      find.textContaining('Ontbreekt in de Office 365-klasgroep GBS-1A'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SystemIndicatorCell>(
              find.byKey(ValueKey('account-cell-$janeId-azure')))
          .state,
      SystemIndicatorState.inOrder,
      reason: 'an informational candidate colours no indicator',
    );
    final studentWork = harness.controller.pendingEntries
        .where((e) => e.family == 'student')
        .expand(workSystemsOfEntry)
        .toList();
    expect(
      studentWork,
      isEmpty,
      reason: 'Office 365 class membership is a property of the group, so the '
          'write is one per class on Klasgroepen — colouring it per student '
          'would paint the whole school orange at the rollover',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a session that cannot seed gets one blocking notice on Acties and no '
      'list to browse end-to-end (#214/#287/#295)',
      (WidgetTester tester) async {
    // Session 1 syncs and materializes the shared view; session 2 is the real
    // app over those stores holding no seeded snapshot, so it cannot link and
    // has nothing to act on.
    //
    // Acties used to answer that by rendering the stored documents as inert
    // account cards under the same drill-down (#214). That was a second way to
    // browse the same data, one the operator can do nothing with — so since
    // #295 the notice is the whole screen, and its Synchroniseer is the one
    // thing on it.
    useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await azureClassMembershipHarness(
      store: snapshots,
      linkedStore: linkedStore,
    ).controller.sync();

    final resumed = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a session with nothing to link');
    expect(find.byKey(const ValueKey('actions-read-only')), findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('actions-read-only-sync')))
          .onPressed,
      isNotNull,
    );

    // One notice, and nothing behind it: no list, no controls, no inert cards.
    expect(find.byKey(const ValueKey('actions-list')), findsNothing);
    expect(
        find.byKey(const ValueKey('actions-only-with-actions')), findsNothing);
    expect(find.byKey(const ValueKey('actions-search')), findsNothing);
    expect(find.text('Sam Sels'), findsNothing);
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the flat Acties list spans every managed school end-to-end, with no '
      'school level to guess at (#210/#295)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Two managed schools whose
    // years overlap: school 1 holds 1A and 3C, school 2 holds 1B and the
    // non-numeric OKAN. The WISA school split is administrative — operators
    // treat both as one school — so every student is in one list, each row
    // naming their own class, and no school appears anywhere.
    useTallWindow(tester);
    final harness = twoSchoolHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Jaar 1'), findsNothing);
    expect(find.text('School 1'), findsNothing);
    expect(find.text('School 2'), findsNothing);
    expect(find.text('Overige klassen'), findsNothing);

    // One row per student, whichever school they are enrolled in, each naming
    // their own class. Sorted by class, the two schools interleave — which is
    // the point: the operator never has to guess a school first.
    await tester.tap(find.byKey(const ValueKey('actions-sort-klas')));
    await tester.pumpAndSettle();
    for (final klas in const <String>['1A', '1B', '3C', 'OKAN']) {
      final String id = harness.controller.linkedAccounts
          .firstWhere((a) => a.classroom == klas)
          .id
          .value;
      final Finder row = find.byKey(ValueKey('account-row-$id'));
      await tester.ensureVisible(row);
      expect(
          find.descendant(of: row, matching: find.text(klas)), findsOneWidget);
    }

    // The stored rollups keep their school partitions all the same — the
    // flattening is presentation only.
    expect(harness.controller.studentRollups.first.accountCount, 2);
    expect(
      harness.controller
          .studentChildrenOf(harness.controller.studentRollups.first)
          .map((r) => r.school),
      <String>['1', '2'],
    );
  });

  testWidgets(
      'the Acties filter collapses the list to the work list end-to-end: the '
      'accounts with nothing to do are gone, the switch is set once and '
      'survives a tab change (#226/#295)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Four students across three
    // classes of two managed schools; exactly one of them (Sam, in 3C) sits in
    // the wrong Smartschool class, so exactly one of them carries work.
    //
    // This is the layer that sees it: the list is joined from the linked view
    // and the derived account documents, the switch lives above the family tab
    // bar and has to outlive a tab change, and "which rows render" is a
    // whole-page composition question that a widget test of one section
    // structurally cannot answer.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [
          wisaStudent(wisaId: '1', classGroup: '1C', classSubGroup: '00'),
          wisaStudent(
              wisaId: '2', classGroup: '1C', classSubGroup: '00', schoolId: 2),
          wisaStudent(wisaId: '3', classGroup: '3C'),
          wisaStudent(wisaId: '4', classGroup: '3D'),
        ],
        schools: [wisaSchool(1), wisaSchool(2)],
        classGroups: [
          wisaClassGroup('1C', adminCode: 'a1', schoolCode: '111'),
          wisaClassGroup('1C', adminCode: 'a2', schoolCode: '222', schoolId: 2),
          wisaClassGroup('3C', adminCode: 'a3', schoolCode: '111'),
          wisaClassGroup('3D', adminCode: 'a4', schoolCode: '111'),
        ],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('1C', code: '1C_ss'),
          ssGroup('2B', code: '2B_ss'),
          ssGroup('3C', code: '3C_ss'),
          ssGroup('3D', code: '3D_ss'),
        ],
        accounts: [
          ssAccount(),
          ssAccount(
            uid: 'jan',
            accountId: '2',
            mail: 'jan.peeters@student.school.example',
            givenName: 'Jan',
            surname: 'Peeters',
          ),
          ssAccount(
            uid: 'sam',
            accountId: '3',
            mail: 'sam.sels@student.school.example',
            givenName: 'Sam',
            surname: 'Sels',
          ),
          ssAccount(
            uid: 'tom',
            accountId: '4',
            mail: 'tom.tas@student.school.example',
            givenName: 'Tom',
            surname: 'Tas',
          ),
        ],
        memberships: [
          member('jane', '1C_ss'),
          member('jan', '1C_ss'),
          // Sam's WISA class is 3C; Smartschool still has him in 2B.
          member('sam', '2B_ss'),
          member('tom', '3D_ss'),
        ],
      ),
      // Every Azure account already carries the WISA display name, so the only
      // student action the pass raises anywhere is Sam's class move. (The WISA
      // fixture names every student "Jane Doe"; the rows are addressed by id,
      // so only the class each of them sits in matters here.)
      azure: azSnap(users: [
        azUser(displayName: 'Jane Doe'),
        azUser(
          id: 'az2',
          upn: 'jan.peeters@student.school.example',
          employeeId: '2',
          displayName: 'Jane Doe',
        ),
        azUser(
          id: 'az3',
          upn: 'sam.sels@student.school.example',
          employeeId: '3',
          displayName: 'Jane Doe',
        ),
        azUser(
          id: 'az4',
          upn: 'tom.tas@student.school.example',
          employeeId: '4',
          displayName: 'Jane Doe',
        ),
      ]),
      ourSchoolIds: const {1, 2},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The stored overview really does hold a mix — one class with work, three
    // without — so the absence assertions below mean something.
    final pendingByClass = <String, int>{
      for (final r in harness.controller.studentRollups)
        for (final c in harness.controller.studentChildrenOf(r))
          '${c.school}|${c.classroom}': c.pendingCount,
    };
    expect(pendingByClass['1|3C'], greaterThan(0));
    expect(pendingByClass['1|3D'], 0);
    expect(pendingByClass['1|1C'], 0);
    expect(pendingByClass['2|1C'], 0);

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // One switch, on the Acties tab itself, already on.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    // The WISA fixture names every student "Jane Doe", so the rows are told
    // apart by the class each of them sits in.
    String rowOf(String klas) => harness.controller.linkedAccounts
        .firstWhere((a) => a.classroom == klas)
        .id
        .value;
    final String sam = rowOf('3C');
    final String tom = rowOf('3D');

    // The 3C student is the only account with work, so they are the whole list.
    expect(find.byKey(ValueKey('account-row-$sam')), findsOneWidget);
    expect(find.byKey(ValueKey('account-row-$tom')), findsNothing,
        reason: 'an account with nothing to do is not in the work list');
    expect(find.byKey(ValueKey('account-row-${rowOf('1C')}')), findsNothing);

    // The switch is a mode, not a per-list setting: it outlives a tab change.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(find.byKey(ValueKey('account-row-$tom')), findsNothing);

    // Switched off, the whole school is back — every student, three green
    // cells on the ones that need nothing.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    for (final klas in const <String>['1C', '3C', '3D']) {
      final Finder row = find.byKey(ValueKey('account-row-${rowOf(klas)}'));
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
    }
    expect(
      tester
          .widget<SystemIndicatorCell>(
              find.byKey(ValueKey('account-cell-$tom-smartschool')))
          .state,
      SystemIndicatorState.inOrder,
    );
  });

  testWidgets(
      'a sync whose shared write fails still leaves Acties showing the view it '
      'just linked, never the previous generation end-to-end (#289/#295)',
      (WidgetTester tester) async {
    // The real app, real navigation. The bug is a composition one: the derived
    // caches were dropped on the far side of the store write, so a Cosmos write
    // that timed out or threw left the operator looking at documents read for
    // the generation before, standing in front of the freshly linked view.
    // Only an end-to-end run navigates the way that shows it: sync, look,
    // sync again over a store that refuses the write, and look again.
    useTallWindow(tester);
    final inner = InMemoryLinkedStore();
    final harness = ReconcileHarness(
      linkedStore: inner,
      // The first sync lands generation 1 so there is something to drill into;
      // every write after it throws.
      controllerStore: StallingLinkedStore(
        inner: inner,
        failWith: StateError('cosmos down'),
        healthyWrites: 1,
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The student the shared view just materialized, in the class it names.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String id = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-row-$id')),
        matching: find.text('3C'),
      ),
      findsOneWidget,
    );

    // WISA moves the student out of 3C, and the operator re-syncs — but the
    // shared store refuses the write.
    harness.wisaResult = wisaSnap(
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
      students: [wisaStudent(classGroup: '3D')],
    );
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Kon het gedeelde overzicht niet opslaan'),
      findsWidgets,
      reason: 'the write really did fail',
    );

    // Back on Acties: the row reads the class the fresh link gives it, not the
    // one the generation before the failed write still says. Before the fix the
    // screen was still joined to that previous generation's documents.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String moved = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    final Finder movedRow = find.byKey(ValueKey('account-row-$moved'));
    await tester.ensureVisible(movedRow);
    expect(find.descendant(of: movedRow, matching: find.text('3D')),
        findsOneWidget);
    expect(
        find.descendant(of: movedRow, matching: find.text('3C')), findsNothing);
    // …and the session is still perfectly usable: it holds the view it linked.
    expect(harness.controller.linked, isNotNull);
  });

  testWidgets(
      'applying an account\'s work takes it off the counts and, once the '
      'operator moves on, out of the Acties work list, without a re-sync '
      'end-to-end (#236/#295/#299)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. The counts are re-derived from
    // the materialized rollups, which only a sync used to rewrite, so work that
    // had just been applied kept being advertised — and the work-list filter
    // reads that same count.
    //
    // This is the layer that sees it: the header count, the tab badges and the
    // list are three projections composed by different halves of the screen,
    // and the bug is precisely that they disagree. Only a run that syncs,
    // applies and looks again puts them all on screen in that order.
    useTallWindow(tester);
    final harness = appliedClassWorkHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // Sam's stale Office 365 name is the only student work: he is the whole
    // work list, and the class groups carry four writes of their own.
    final String sam = accountId(harness, 'Sam Sels');
    final String tom = accountId(harness, 'Tom Tas');
    expect(find.byKey(ValueKey('account-row-$sam')), findsOneWidget);
    expect(find.byKey(ValueKey('account-row-$tom')), findsNothing);
    expect(harness.controller.groupRollup!.pendingCount, 4);

    // Select him and apply that one entry, confirmation dialog and all.
    await selectAccount(tester, sam);
    final applyEntry = find.byKey(ValueKey('entry-apply-$sam'));
    await tester.ensureVisible(applyEntry);
    await tester.tap(applyEntry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsWidgets);
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
      reason: 'the live list drops the work immediately — it always did',
    );

    // His badge is gone with the work behind it. The row itself is still on
    // screen, and only because #299 holds a just-applied account there long
    // enough for its verdict to be read — marked as what happened, not badged.
    final Finder samRow = find.byKey(ValueKey('account-row-$sam'));
    expect(samRow, findsOneWidget);
    expect(find.byKey(ValueKey('account-done-$sam')), findsOneWidget);
    expect(find.descendant(of: samRow, matching: find.text('1')), findsNothing,
        reason: 'the row used to come back still badged 1');

    // Reshaping the list is the operator moving on, so the hold lets go — and
    // the work list is empty, with no sync between.
    await tester.tap(find.byKey(const ValueKey('actions-sort-klas')));
    await tester.pumpAndSettle();
    expect(samRow, findsNothing);
    expect(find.text('Geen openstaande acties — alles staat in orde.'),
        findsOneWidget);
    // …while the work nobody touched is untouched: a re-derivation of what
    // changed, not a blanket reset.
    expect(harness.controller.groupRollup!.pendingCount, 4);

    // Off the filter, Sam is back in the inventory — ticked off rather than
    // badged, and his Office 365 cell is green.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(samRow);
    expect(find.descendant(of: samRow, matching: find.text('1')), findsNothing);
    expect(find.descendant(of: samRow, matching: find.byIcon(Icons.check)),
        findsOneWidget);
    expect(
      tester
          .widget<SystemIndicatorCell>(
              find.byKey(ValueKey('account-cell-$sam-azure')))
          .state,
      SystemIndicatorState.inOrder,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      "another operator's apply reaches a running session live, with no "
      're-sync end-to-end (#254)', (WidgetTester tester) async {
    // The shared half of #236, at the layer it is actually felt. #236 fixed the
    // badges of the session that ran the apply and deliberately wrote nothing
    // back, so every *other* operator's Acties panel kept offering work that had
    // already been applied until somebody ran a full Synchroniseer.
    //
    // Only a two-session run can see that: one session applies, and the bug is
    // what the *other* one is still showing. So operator A is an offline
    // session over the shared stores, and operator B is the real app — real
    // fonts, real navigation — reading the same shared view over the same
    // realtime fan-out, and never syncing or linking at all. B cannot link, so
    // since #295 Acties offers it one blocking notice; what it *does* still
    // read passively is the Synchronisatie overview, and that is where the
    // stale offer showed.
    useTallWindow(tester);
    final hub = InMemorySignalHub();
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();

    // Operator A materializes the shared view: Sam's stale Office 365 name is
    // the one piece of student work anywhere, and it sits in 3C.
    final operatorA = appliedClassWorkHarness(
      store: snapshots,
      linkedStore: linkedStore,
      hub: hub,
      syncedBy: 'jan@school.example',
    );
    await operatorA.controller.sync();

    // Deliberately holding no seeded snapshot: since #287 a session that does
    // adopts the shared state, and this scenario is about what a session with
    // *only* the shared documents keeps being offered.
    final operatorB = ReconcileHarness(linkedStore: linkedStore, hub: hub);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: operatorB.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // B is offered the work — read from the shared documents, with no pull and
    // no link() of its own.
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(find.text('1 openstaande actie'), findsOneWidget);

    // A applies it. B is nudged over the realtime fan-out and refetches the one
    // shard that moved.
    await operatorA.controller.applyEntry(
      operatorA.controller.pendingEntries
          .singleWhere((e) => e.family == 'student'),
    );
    await tester.pumpAndSettle();

    // B has stopped offering work that is already done.
    expect(find.text('1 openstaande actie'), findsNothing,
        reason: 'B used to keep advertising it until someone re-synced');
    expect(operatorB.wisaSyncs, 0, reason: 'the nudge never triggers a pull');
    expect(operatorB.controller.linked, isNull,
        reason: 'link() is never called in a passive session');

    // The stored document itself moved with the rollup — the write-back
    // patched both, so the next session to adopt the shared state links a view
    // with the work already gone.
    expect(
      (await linkedStore.readClassroom(school: '1', classroom: '3C'))
          .expand((a) => a.candidates),
      isEmpty,
    );

    // …and Acties gives B the one blocking notice it owes a session that
    // cannot link, rather than a second, inert way to browse the same rows.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('actions-read-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // The Acties bulk-apply end-to-end runs of #252 (a classroom's "Alles
  // toepassen" stops at that classroom) and #292 (a bulk apply covers one
  // decision everywhere it occurs) went with the affordance they drove: #295
  // took bulk apply off the Acties screen, which lands with per-decision apply
  // only, and #296 gives it back school-wide with its cohort visible first.
  // Both rules still run end-to-end over the Klasgroepen cohort headers above
  // — see the namesake-class scenario, where two cohorts of one decision each
  // prove that a header writes the decision it names and no other.

  testWidgets(
      'a single-group class whose name another school shares raises no class '
      'change, and "00" never reaches a class name end-to-end (#221)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Two managed schools each have
    // their own single-group `1C` — one `SyncKlas` row, `KLASGROEP = 00`, and
    // (because `ADMINGROEP` is only unique within a school) a different
    // `ADMINGROEP` each. Both students already sit in the Smartschool `1C`
    // their WISA record names, so the correct pass proposes nothing.
    //
    // Before the fix the two schools' admin codes pooled under the bare name
    // `1C`, the class read as sub-grouped, and each student's `KLASGROEP` was
    // appended verbatim: every student of both classes was offered "Wijzig de
    // klas in Smartschool — 1C → 1C 00", a move into a class that exists
    // nowhere. This is the layer that sees it: the misclassification needs two
    // schools in one snapshot, which no single-resolver assertion composes.
    useTallWindow(tester);
    final harness = subGroupSentinelHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Not one class move is proposed anywhere in the pass, and no projected
    // change carries the sentinel.
    final alternatives = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives);
    expect(
      alternatives.map((a) => a.kind),
      isNot(contains('MoveToSmartschoolClassGroup')),
      reason: 'both classes are single-group — nobody moves',
    );
    expect(
      alternatives
          .expand((a) => a.changes.fields)
          .expand((f) => <String?>[f.before, f.after]),
      isNot(contains('1C 00')),
      reason: 'the "no sub-groups" sentinel is never part of a class name',
    );

    // Browse it the way the operator does: both schools' students are rows of
    // the one list, each naming the class their own WISA record does.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    // Nobody has work, so the list is the whole school with the filter off.
    await tester.tap(find.byKey(const ValueKey('actions-only-with-actions')));
    await tester.pumpAndSettle();
    expect(find.text('1C 00'), findsNothing,
        reason: 'the sentinel never names a class in the list either');

    // Each school's student in turn: on screen, in `1C`, with no class-change
    // row in their details pane.
    for (final school in <String>['1', '2']) {
      final String id = harness.controller.linkedAccounts
          .firstWhere((a) => a.school == school)
          .id
          .value;
      final Finder row = find.byKey(ValueKey('account-row-$id'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      expect(
          find.descendant(of: row, matching: find.text('1C')), findsOneWidget);

      await selectAccount(tester, id);
      expect(find.text('Wijzig de klas in Smartschool'), findsNothing,
          reason: 'school $school\'s 1C is single-group — no move is due');
      expect(find.textContaining('1C 00'), findsNothing);
    }
  });

  testWidgets(
      'the stamboeknummer waits for the class move end-to-end: the card offers '
      'only the move, the pass sends no saveUser, and the number follows once '
      'the new career row exists (#338)', (WidgetTester tester) async {
    // The real app, real navigation, real writes over the recording SOAP wire.
    // The rollover case that damaged 66 of 66 students last summer: Jane moves
    // up from `4NW2` to `5ADB` and, with it, from one of the group's schools to
    // the other, so WISA (werkdatum already in the new year) reports the *new*
    // institute number while Smartschool still carries the old one.
    //
    // A schoolloopbaan keeps one stamnummer per row and `saveUser` writes it to
    // the *last* row, so a save before the move stamps next year's number onto
    // the row of the year she is still sitting in — silently, because the class
    // change then creates the new row and inherits the value, leaving the new
    // year right and the running year wrong. Only a full run shows the thing
    // that has to be true: what the card offers, and which SOAP calls one click
    // sends, in what order.
    useTallWindow(tester);
    SmartschoolSnapshot smartschoolWith(String classCode) => ssSnap(
          groups: [
            ssGroup('4NW2', code: '4nw2_ss'),
            ssGroup('5ADB', code: '5adb_ss'),
          ],
          accounts: [ssAccount(stemId: 2200123)],
          memberships: [member('jane', classCode)],
        );
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(classGroup: '5ADB', stemId: '2300033')],
      ),
      smartschool: smartschoolWith('4nw2_ss'),
      azure: azSnap(users: [azUser(displayName: 'Jane Doe')]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    // Her card carries the move and says nothing at all about the
    // stamboeknummer — there is no row to apply out of order, in any order.
    final String id = accountId(harness, 'Jane Doe');
    await selectAccount(tester, id);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);
    expect(
      find.text('Wijzig het stamboeknummer in Smartschool'),
      findsNothing,
      reason: 'the running year\'s career row is still the last one',
    );

    // Applying the whole card is therefore one write, and it is the move.
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.soap.movedToClasses, <String>['5adb_ss']);
    expect(
      harness.soap.savedStamboeknummers,
      isEmpty,
      reason: 'no saveUser may precede the move that creates the new row',
    );

    // Smartschool now has her in `5ADB`; the operator re-reads it the way they
    // do after a rollover pass — **Controleer op drift**, which re-pulls
    // Smartschool and Azure without touching the WISA roster.
    harness.ssResult = smartschoolWith('5adb_ss');
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // The move is settled, so the number is offered — and now it lands on the
    // new year's row, which is the last one.
    await selectAccount(tester, id);
    expect(find.text('Wijzig de klas in Smartschool'), findsNothing);
    expect(find.text('Wijzig het stamboeknummer in Smartschool'), findsWidgets);

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.soap.savedStamboeknummers, <String>['2300033']);
    expect(
      harness.soap.soapActions.indexWhere((a) => a.endsWith('#saveUser')),
      greaterThan(
        harness.soap.soapActions
            .indexWhere((a) => a.endsWith('#saveUserToClass')),
      ),
      reason: 'the move creates the row the number is written to',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a successful class move settles on the card end-to-end: the move stops '
      'being offered and the stamboeknummer is released, with no second pull '
      'of Smartschool (#341)', (WidgetTester tester) async {
    // The real app, real navigation, real writes over the recording SOAP wire.
    // The same rollover student as the run above — Jane moves up from `4NW2`
    // into `5ADB` — but this one is about the screen *after* the write.
    //
    // The incremental refresh (#72) exists so an applied action disappears
    // without a re-sync, and it did that by splicing the written record back
    // into the snapshot. A move writes no field of the account, though: the
    // record comes back exactly as it went in, so the memberships kept saying
    // `4NW2`, the placement resolver kept reading the old class out of them,
    // and the move an operator had just applied was still on the card — still
    // bulk-applyable — while the stamboeknummer queued behind it (#338) stayed
    // deferred. Only a full run shows it: the SOAP wire says the write landed,
    // and the very next frame contradicts it.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(classGroup: '5ADB', stemId: '2300033')],
      ),
      smartschool: ssSnap(
        groups: [
          ssGroup('4NW2', code: '4nw2_ss'),
          ssGroup('5ADB', code: '5adb_ss'),
        ],
        accounts: [ssAccount(stemId: 2200123)],
        memberships: [member('jane', '4nw2_ss')],
      ),
      azure: azSnap(users: [azUser(displayName: 'Jane Doe')]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    final String id = accountId(harness, 'Jane Doe');
    await selectAccount(tester, id);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // Apply the card, then never touch Synchronisatie again: whatever the
    // operator sees from here on is the incremental refresh's own account of
    // what it just wrote.
    final int pullsBefore = harness.ssSyncs;
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.soap.movedToClasses, <String>['5adb_ss']);

    // The card reports the move as done rather than re-raising it, and the
    // write it was holding back is on screen — no **Controleer op drift** in
    // between.
    await selectAccount(tester, id);
    expect(
      find.text('Deze acties staan niet meer open op deze kaart.'),
      findsOneWidget,
      reason: 'the applied move settled instead of coming back as pending',
    );
    expect(
      find.text('Wijzig het stamboeknummer in Smartschool'),
      findsWidgets,
      reason: 'the move is settled, so #338 stands the stem write up again',
    );

    // And the operator's second click writes the number without re-running the
    // move it already applied.
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.soap.savedStamboeknummers, <String>['2300033']);
    expect(harness.soap.movedToClasses, <String>['5adb_ss'],
        reason: 'a settled move is not written a second time');
    expect(harness.ssSyncs, pullsBefore,
        reason: 'both passes ran off the spliced snapshot, not a re-pull');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Actions view splits Personeel and Leerlingen into tabs end-to-end: '
      'staff in one tab, students in the other (#179/#295)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window: one student plus one WISA staff
    // member so both families have a row. The Actions view must browse them as
    // two separate workflows — a horizontal tab bar with a per-family list —
    // not one combined list.
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // On the Actions tab the family tab bar carries both families.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('actions-tab-leerlingen')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-tab-personeel')), findsOneWidget);

    // Default Leerlingen tab: the student is a row, the staff member is not.
    final String student = accountId(harness, 'Jane Doe');
    final String staff = accountId(harness, 'Anna Smit');
    expect(find.byKey(ValueKey('account-row-$student')), findsOneWidget);
    expect(find.byKey(ValueKey('account-row-$staff')), findsNothing);

    // Switch to Personeel: only staff, and the class column names the
    // synthetic Personeel bucket they sit in.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('account-row-$student')), findsNothing);
    final Finder staffRow = find.byKey(ValueKey('account-row-$staff'));
    expect(staffRow, findsOneWidget);
    expect(find.descendant(of: staffRow, matching: find.text('Anna Smit')),
        findsOneWidget);
    expect(find.descendant(of: staffRow, matching: find.text('Personeel')),
        findsOneWidget);

    // And their decisions open in the details pane beside the list.
    await selectAccount(tester, staff);
    expect(find.byKey(ValueKey('actions-detail-$staff')), findsOneWidget);
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
    await tester.tap(find.text('Wachtwoorden'));
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
      'the Passwords personeel tab searches staff by any part of the name, in '
      'either order, with no field picker end-to-end (#186/#215)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window: a "Personeel" group holding three
    // staff seeded out of alphabetical order across mixed casing (alice Bravo /
    // Bob Alpha / Charlie Zulu). The tab used to pair its filter box with a
    // Naam / Voornaam / Gebruiker dropdown, so a fragment of the wrong half of
    // the name returned an empty list with no hint why. One box now matches any
    // part of the full name, and the list still renders alphabetically.
    useTallWindow(tester);
    final harness = ReconcileHarness(ssInitial: staffOrderSnap());
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wachtwoorden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    // One full-width search box; the field picker and its options are gone.
    final filter = find.byKey(const ValueKey('passwords-staff-filter'));
    expect(filter, findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-filter-field')),
        findsNothing);
    expect(find.text('Voornaam'), findsNothing);
    expect(find.text('Gebruiker'), findsNothing);

    // The tiles render top-to-bottom in alphabetical order: alice, Bob, Charlie.
    double y(String uid) =>
        tester.getTopLeft(find.byKey(ValueKey('passwords-staff-$uid'))).dy;
    expect(y('alice'), lessThan(y('bob')));
    expect(y('bob'), lessThan(y('charlie')));

    // The focused field's blinking cursor never settles, so pump frames.
    Future<void> search(String needle) async {
      await tester.enterText(filter, needle);
      await tester.pump();
    }

    // A surname fragment in the other casing — the search the old default
    // (Voornaam) answered with an empty list.
    await search('BRAV');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-bob')), findsNothing);
    expect(find.byKey(const ValueKey('passwords-staff-charlie')), findsNothing);

    // Both halves typed surname-first, the order the tile does not display in.
    await search('bravo alice');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-bob')), findsNothing);

    // Parts from two different people match neither.
    await search('alice zulu');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsNothing);
    expect(find.byKey(const ValueKey('passwords-staff-charlie')), findsNothing);

    // Clearing the box brings the whole list back, still in order.
    await search('');
    expect(y('alice'), lessThan(y('bob')));
    expect(y('bob'), lessThan(y('charlie')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a refused Office 365 password reset tells the operator which permission '
      'is missing instead of showing a raw GraphException end-to-end (#216)',
      (WidgetTester tester) async {
    // The real app, real fonts, real window — and the *production* password
    // write path (real ConnectorPasswordBackends → real AzureConnector) over a
    // Graph that answers the way the tenant did: the user lookup succeeds, the
    // passwordProfile PATCH comes back 403 Authorization_RequestDenied because
    // the app registration only ever had User.ReadWrite.All. The operator used
    // to read "Reset mislukt: GraphException(403 (Authorization_RequestDenied))"
    // and had to go dig in the log panel to learn it was a rights problem.
    useTallWindow(tester);
    final denied = PasswordWriteDeniedGraph();
    final harness =
        ReconcileHarness(ssInitial: passwordsSnap(), passwordGraph: denied);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wachtwoorden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    // The fixture's staff account (uid anna.smit) is named Jane Doe. Reset the
    // Office 365 password only, so the whole reset rides on the refused write.
    await tester.tap(find.byKey(const ValueKey('passwords-staff-anna.smit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-staff-reset-o365')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .tap(find.byKey(const ValueKey('passwords-staff-reset-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Graph really was asked, and really refused.
    expect(denied.refusedWrites, hasLength(1));

    // What the operator reads on the screen: who it was for, and the two
    // directory-side causes — no exception class, no status code.
    final message = tester.widget<Text>(
      find.byKey(const ValueKey('passwords-message')),
    );
    final String shown = message.data!;
    expect(shown, contains('Geen rechten'));
    expect(shown, contains('Jane Doe'));
    expect(shown, contains('User-PasswordProfile.ReadWrite.All'));
    expect(shown, isNot(contains('GraphException')));
    expect(shown, isNot(contains('403')));

    // No sheet is handed over for a password that was never set.
    expect(harness.passwordWrites, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Passwords view prints the queued sheets as a real PDF and opens it '
      'for printing end-to-end (#195)', (WidgetTester tester) async {
    // The real app, real fonts, real window. Printing used to drop browser-
    // printable HTML into %TEMP% and leave the operator to go find it and print
    // from a browser. It is a real PDF now, written outside temp and handed
    // straight to the platform viewer — so drive it the way the operator does:
    // pick the class, tick the whole column, generate, then press Print.
    useTallWindow(tester);
    final harness = ReconcileHarness(ssInitial: passwordsSnap());
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wachtwoorden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('password-class-3C')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-bulk-smartschool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate-confirm')));
    await tester.pumpAndSettle();

    // Both students of 3C were pushed, so both are queued for printing.
    expect(harness.passwordBackends.smartschoolPushes, hasLength(2));
    final printButton = find.byKey(const ValueKey('passwords-export-students'));
    await tester.ensureVisible(printButton);
    expect(tester.widget<OutlinedButton>(printButton).onPressed, isNotNull);

    await tester.tap(printButton);
    await tester.pumpAndSettle();

    // One real PDF document, one page per queued student, under a .pdf name.
    expect(harness.passwordWrites, hasLength(1));
    final String name = harness.passwordWrites.single.$1;
    final List<int> bytes = harness.passwordWrites.single.$2;
    expect(name, 'leerling-wachtwoorden.pdf');
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(
      RegExp(r'/Type\s*/Page(?!s)').allMatches(latin1.decode(bytes)),
      hasLength(2),
      reason: 'one page per student, as the sheets are handed out per person',
    );

    // It was opened for printing, and the operator is told where it went.
    expect(harness.passwordOpens, hasLength(1));
    expect(harness.passwordOpens.single, endsWith(name));
    expect(find.byKey(const ValueKey('passwords-message')), findsOneWidget);
    expect(find.textContaining('geopend'), findsOneWidget);

    // The queue drained only after the export succeeded, so the button is spent.
    expect(tester.widget<OutlinedButton>(printButton).onPressed, isNull);
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Browse the student on the Actions tab and select her row: the
    // previously-hidden differing field shows in the details pane, and
    // unchanged fields are not rendered as misleading "X → X" rows.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    await selectAccount(tester, entry.targetId);

    // The address action is present (postalCode really drifted).
    expect(find.text('Wijzig het adres in Smartschool'), findsWidgets);
    expect(find.textContaining('postalCode: 3270 → 3271'), findsOneWidget);
    expect(find.textContaining('country'), findsNothing);
    expect(find.textContaining('street:'), findsNothing);
  });

  testWidgets(
      'the flat Acties list virtualizes in the real app: only a bounded number '
      'of rows build, and scrolling loads more (#111/#295)',
      (WidgetTester tester) async {
    // A September-changeover-scale pending set (a thousand WISA-departed
    // accounts) in the real, laid-out app. The drill-down existed partly to
    // avoid rendering this; the flat list builds only the on-screen rows.
    useTallWindow(tester);
    final harness = manyDepartedHarness(count: 1000);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // All 1000 accounts are in this one school-wide list, but only a small
    // window builds.
    expect(harness.controller.pendingEntries, hasLength(1000));
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
        reason: 'virtualized: on-screen rows only, not all 1000');

    // Scrolling loads rows that were not built and unloads the ones that
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
    expect(find.byKey(ValueKey(initial.first)), findsNothing);
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

    await tester.tap(find.text('Synchronisatie'));
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
      'a resumed session trusts the stored state: Synchroniseer pulls no '
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-sync')), findsOneWidget);

    // Drive Synchronise from the real UI: WISA is re-read for the smart diff,
    // but Smartschool and Azure are trusted from the store — no connector pull.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(resumed.wisaSyncs, 1);
    expect(resumed.ssSyncs, 0, reason: 'Smartschool seeded from the store');
    expect(resumed.azSyncs, 0, reason: 'Azure seeded from the store');
    expect(find.text('Overzicht'), findsOneWidget);
  });

  testWidgets(
      'a passive session renders the materialized overview with no pull and no '
      'link() (#115/#295)', (WidgetTester tester) async {
    // Session 1 (offline harness) syncs and materializes the shared view into a
    // LinkedStore both sessions share.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 is the real app over the same stores. It never syncs, and holds
    // no seeded snapshot to adopt from either (#287) — so this stays the purely
    // passive read #115 is about.
    final resumed = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    // The stored rollups render on Synchronisatie, straight from the store and
    // with no Synchronise tapped.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(find.textContaining('openstaande actie'), findsWidgets);
    expect(resumed.controller.hasOverview, isTrue);
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');

    // Acties has nothing to act on, so it is the one blocking notice (#295) —
    // never a second, inert way to browse the same documents.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('actions-read-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-list')), findsNothing);
    expect(find.text('Jane Doe'), findsNothing);
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

    // Session 2 is the real app over the same stores. It never syncs, and holds
    // no seeded snapshot to adopt from either (#287) — so this stays the purely
    // passive read #163 is about.
    final resumed = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // The per-category overview renders straight from the stored rollups — no
    // Synchronise tapped, and link() is never called in a passive session.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-students')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-category-staff')), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-category-groups')),
        findsOneWidget);
    // The one fixture student is summed from the rollup with a pending
    // indicator on her own card (the class-groups card carries the same count
    // since #328, so the finder is scoped rather than global).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reconcile-category-students')),
        matching: find.text('2 openstaande acties'),
      ),
      findsOneWidget,
    );
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
  });

  testWidgets(
      'a passive session surfaces pending group actions on Klasgroepen '
      'with no pull and no link() (#119)', (WidgetTester tester) async {
    // Session 1 (offline harness) syncs and materializes the shared view. The
    // fixture's two Smartschool-only classes (2B, 3C) each raise the
    // orphan-class delete of #313 — the group-action family — which since #328
    // is the lone proposal on such a row.
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    // Session 2 is the real app over the same stores. It never syncs, and holds
    // no seeded snapshot to adopt from either (#287) — so this stays the purely
    // passive read #119 is about.
    final resumed = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    // The class inventory renders straight from the store — no Synchronise
    // tapped — on its own tab, listing the orphan Smartschool classes with the
    // delete each of them proposes (#227).
    await openKlasgroepen(tester);

    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-2B')), findsOneWidget);
    expect(find.textContaining('Verwijder de klas 2B uit Smartschool'),
        findsWidgets);
    // …all without a single connector pull or link().
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(resumed.controller.linked, isNull);
  });

  testWidgets(
      'a passive session says it is read-only on both action screens, and its '
      'Synchroniseer turns the very same accounts interactive end-to-end '
      '(#214/#295)', (WidgetTester tester) async {
    // Session 1 syncs and materializes the shared view; session 2 is the real
    // app over the same stores and never syncs — the everyday passive session
    // that opened Acties to look at the pending work. Both screens used to swap
    // their interactive tiles for static bullet text with no gesture handler
    // and say nothing about it, which reads as an interactive screen whose taps
    // stopped working rather than as a view of the shared state.
    useTallWindow(tester);
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();

    // Deliberately holding no seeded snapshot: since #287 a session that does
    // adopts the shared state and its tiles are interactive from the first
    // frame (covered by its own scenario below). This is the session that has
    // nothing to build a view from.
    final resumed = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: resumed.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(resumed.controller.linked, isNull);

    final readOnly = find.byKey(const ValueKey('actions-read-only'));
    final accountRows = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('account-row-'));

    // Acties: one blocking notice, and nothing behind it (#295).
    expect(readOnly, findsOneWidget);
    // Since #287 the notice names what is missing rather than reporting the
    // absence of a sync: there is no snapshot here to build a view from.
    expect(
      find.textContaining('Geen opgeslagen momentopname'),
      findsOneWidget,
    );
    expect(accountRows, findsNothing,
        reason: 'nothing here is actionable — that is the point');

    // The Klasgroepen tab: static rows, and they say so — the same
    // announcement, keyed per view since #227 put the two on different tabs.
    await openKlasgroepen(tester);
    expect(
        find.byKey(const ValueKey('class-groups-read-only')), findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // Take the offered way out, from the notice itself: WISA is pulled and the
    // session links.
    final sync = find.byKey(const ValueKey('actions-read-only-sync'));
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(resumed.wisaSyncs, 1);
    expect(resumed.controller.linked, isNotNull);

    // The very same accounts are interactive now: a real list, no notice, no
    // locks — which is what the operator expected the first time round.
    expect(readOnly, findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(accountRows, findsWidgets);
    final String id = resumed.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, id);
    expect(find.byKey(ValueKey('entry-apply-$id')), findsOneWidget);
  });

  testWidgets(
      'the second operator of the day starts from the shared synced state: '
      'Acties, Klasgroepen and Synchronisatie are all usable without pulling '
      'anything (#287)', (WidgetTester tester) async {
    // The everyday case this issue is about. Operator A syncs — minutes of WISA
    // SOAP per school, the Smartschool group walk and the Azure read. Operator B
    // launches the real app five minutes later onto the same shared stores.
    //
    // This is the layer that sees it: the seeding happens in the screens'
    // bootstrap, the notice replaces a different widget on each of three tabs,
    // and only a full-app run puts an operator in front of the result. Before
    // #287 B was read-only everywhere until they repeated A's whole pull.
    useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(
      store: snapshots,
      linkedStore: linkedStore,
      syncedBy: 'jan@school.example',
    ).controller.sync();

    final operatorB = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: operatorB.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Synchronisatie says whose pull this session is working from — and both
    // passes stay available for an operator who wants something fresher.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-adopted')), findsOneWidget);
    expect(find.textContaining('jan@school.example'), findsWidgets);
    expect(find.byKey(const ValueKey('reconcile-seed-refused')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reconcile-sync')))
          .onPressed,
      isNotNull,
    );

    // Klasgroepen: the inventory is live, not a wall of static rows, and it
    // says where the view came from.
    await openKlasgroepen(tester);
    expect(find.byKey(const ValueKey('class-groups-read-only')), findsNothing);
    expect(find.byKey(const ValueKey('class-groups-shared-state')),
        findsOneWidget);
    expect(find.text('Gedeelde synchronisatie'), findsOneWidget);

    // Acties: the list is there and its rows are the interactive ones —
    // choices, dry-run, apply — with the same notice above them.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String seeded = operatorB.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, seeded);

    expect(find.byKey(const ValueKey('actions-read-only')), findsNothing);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(find.byKey(ValueKey('entry-apply-$seeded')), findsOneWidget);

    // The whole of it without one connector round-trip, and without touching
    // the shared view: no generation bump, so no client is asked to refetch.
    expect(operatorB.wisaSyncs, 0);
    expect(operatorB.ssSyncs, 0);
    expect(operatorB.azSyncs, 0);
    expect((await linkedStore.readSyncState()).generation, 1);
    expect(tester.takeException(), isNull);
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // The shared per-system last-sync box renders (#162/#188) straight from the
    // store (who last synced each system — not this passive session), proving it
    // survives a restart.
    expect(find.byKey(const ValueKey('reconcile-last-sync')), findsOneWidget);
    expect(find.text('Laatste synchronisatie'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);
    expect(find.textContaining('door operator@school.example'), findsWidgets);

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
    await tester.tap(find.text('Synchronisatie'));
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
    // Read on Klasgroepen: since #309 that is the action view carrying the
    // shared state's freshness stamp, which is what this run watches move.
    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();

    // The overview rendered at generation 1 and the subscriber connected.
    expect(find.textContaining('Generatie 1'), findsOneWidget);
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
    // …and the refreshed shared state reached the UI: the freshness stamp above
    // the list names the generation the nudge announced.
    expect(find.textContaining('Generatie 2'), findsOneWidget);
    expect(find.textContaining('Generatie 1'), findsNothing);

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

    await tester.tap(find.text('Synchronisatie'));
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
      'an id collision is named on Synchronisatie and in the log, and the one '
      'card it corrupts is still reachable (#319)',
      (WidgetTester tester) async {
    // Two records on one LinkedAccountId. Constructed through the resolver:
    // #318 removed the one known way a snapshot produces this, and INV-24 is
    // the guard for the cause nobody has found yet. Driven through the real
    // app, on the real window, the way the operator meets it.
    useTallWindow(tester);
    final harness = idCollisionHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The overview names the collision, open, with a line per colliding record
    // — no tap, because there is nothing here for the operator to decide.
    final tile = find.byKey(const ValueKey('id-collision-p-shared'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: tile, matching: find.textContaining('Koppelingsfout')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.textContaining('WISA W1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.textContaining('WISA W2')),
      findsOneWidget,
    );

    // …and the log panel says it too, which is the surface that still works
    // when the colliding records have no Smartschool account to hang a card on.
    expect(
      harness.log.entries
          .map((e) => e.message)
          .where((m) => m.contains('Koppelingsfout') && m.contains('p-shared')),
      hasLength(1),
    );

    // The damage itself: both records became one document id, so Acties shows
    // the single card the warning is about. Left as-is deliberately — #319
    // makes the collision visible, it does not decide how to merge the records.
    expect(
      harness.controller.linkedAccounts
          .where((a) => a.id.value == 'p-shared')
          .length,
      2,
    );
  });

  testWidgets(
      'an admin co-account gets its own card instead of merging its actions '
      'onto the student\'s (#323)', (WidgetTester tester) async {
    // The live cause of the #319 card, and nothing about it is constructed: the
    // deliberate admin + normal account pair INV-23 keeps, both carrying the
    // student's WISA id as `accountId`. Both records preferred the natural key
    // `wisa:1`, so the resolver handed them one LinkedAccountId and the
    // materializer gave the single surviving document the union of both
    // records' candidates. Driven through the real app because the union is
    // only legible as what the operator reads: one card claiming the student is
    // in all three systems above a choice that only exists when they are gone.
    useTallWindow(tester);
    final harness = coAccountHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The mail collision is still reported — that one is real, and accepting it
    // stays the operator's call (#109). The id collision is simply not there:
    // no overview tile, no log line.
    expect(
      find.byKey(const ValueKey('dup-warning-jane.doe@student.school.example')),
      findsOneWidget,
    );
    expect(find.textContaining('Koppelingsfout'), findsNothing);
    expect(
      harness.log.entries
          .map((e) => e.message)
          .where((m) => m.contains('Koppelingsfout')),
      isEmpty,
    );
    expect(harness.controller.linkIdCollisions, isEmpty);

    // Two cards on Acties, one per Smartschool account, each with its own id.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String student = accountId(harness, 'Jane Doe');
    final String coAccount = accountId(harness, 'Jane Doe-beheer');
    expect(student, isNot(coAccount));
    expect(find.byKey(ValueKey('account-row-$student')), findsOneWidget);
    expect(find.byKey(ValueKey('account-row-$coAccount')), findsOneWidget);

    // The presence chips now describe each record on its own: the student is in
    // all three systems, the co-account exists in Smartschool alone.
    SystemIndicatorState cell(String id, Origin system) => tester
        .widget<SystemIndicatorCell>(
            find.byKey(ValueKey('account-cell-$id-${system.name}')))
        .state;
    expect(cell(student, Origin.wisa), isNot(SystemIndicatorState.missing));
    expect(cell(coAccount, Origin.wisa), SystemIndicatorState.missing);
    expect(cell(coAccount, Origin.azure), SystemIndicatorState.missing);

    // And the decisions are split the way the records are. The student's pane
    // holds only her own Azure work; the leaver either/or — which can only
    // exist for an account that is gone from WISA — is on the co-account's
    // pane, where it belongs. That pairing on one card is the whole of #319.
    await selectAccount(tester, student);
    expect(find.byKey(ValueKey('actions-detail-$student')), findsOneWidget);
    expect(find.text('Wijzig de naam in Azure'), findsWidgets);
    expect(find.text('Verwijder dit account uit Smartschool'), findsNothing);

    await selectAccount(tester, coAccount);
    expect(find.byKey(ValueKey('actions-detail-$coAccount')), findsOneWidget);
    expect(find.text('Verwijder dit account uit Smartschool'), findsWidgets);
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(await harness.passwordQueue.load(), isEmpty);

    // Browse the create on the Actions tab and select the student's row.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final String createId = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, createId);
    expect(find.text('Maak een nieuw Smartschool account'), findsWidgets);

    // Apply the row for real (against the recording SOAP transport): the create
    // runs and its minted password is captured into the shared queue.
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$createId')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$createId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    final queued = await harness.passwordQueue.load();
    expect(queued, hasLength(1),
        reason: 'the created account\'s password landed in the queue');
    expect(queued.single.smartschoolPassword, isNotNull);

    // Switch to the Passwords view: the freshly captured account sheet is
    // surfaced as a printable student sheet (the reworked view no longer shows
    // a per-entry distribute card — the queue feeds the print/CSV exports).
    await tester.tap(find.text('Wachtwoorden'));
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
    await tester.tap(find.text('Instellingen'));
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
    await tester.tap(find.text('Instellingen'));
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
      'the Settings view marks a WISA school virtual end-to-end, and the mark '
      'survives a "Scholen ophalen" refresh (#203)',
      (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams. One school is
    // known (managed, code-less) and a refresh is wired, so the whole operator
    // flow runs: mark virtual → refresh the list → save.
    useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 99, name: 'Virtuele school SMA', code: 'ismav'),
    ]);
    final settings = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
        wisaSchools: [WisaSchoolProfile(schoolId: 99, ours: true)],
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

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');

    // The school renders with its own virtual toggle, off, next to the managed
    // one — in the real, laid-out three-column grid with the real fonts.
    final virtualBox =
        find.byKey(const ValueKey('settings-wisa-school-99-virtual'));
    await tester.ensureVisible(virtualBox);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(virtualBox).value, isFalse);

    // Mark it virtual, then refresh the school list: the mark must survive the
    // merge that backfills the code.
    await tester.tap(virtualBox);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.text('ismav'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(virtualBox).value, isTrue);

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // The virtual mark landed in the settings document, alongside (not instead
    // of) the managed mark — this is what the sync reads to pick the virtual
    // work date for this school.
    final saved = await settings.store.load();
    expect(saved.wisaSchools.single.schoolId, 99);
    expect(saved.wisaSchools.single.virtual, isTrue);
    expect(saved.wisaSchools.single.ours, isTrue);
    expect(saved.virtualWisaSchoolIds, {99});
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
      WisaSchool(id: 3, name: 'Sint-Jan', code: 'SJ'),
      WisaSchool(id: 7, name: 'Sint-Pieter', code: 'SP'),
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
    await tester.tap(find.text('Instellingen'));
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
      'the Settings view identifies WISA schools by their code end-to-end, '
      'never showing the id twice (#194)', (WidgetTester tester) async {
    // The real app composition, real navigation and real fonts over the
    // in-memory settings seams. One school is stored from before #194 (name,
    // no code); the fetch backfills the code and the grid must lead with it.
    useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    // `SMAGetInst`'s CSV DESCRIPTION column (the short code) lands on `code`.
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 7, name: 'Sint-Pieter', code: 'ismab'),
    ]);
    final settings = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
        wisaSchools: [
          WisaSchoolProfile(schoolId: 7, name: 'Sint-Pieter', ours: true),
        ],
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

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');

    // Before the fetch: the stored name leads, the id is the secondary line and
    // appears exactly once.
    final tile = find.byKey(const ValueKey('settings-wisa-school-7-ours'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tile, matching: find.text('Sint-Pieter')),
        findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('id: 7')),
        findsOneWidget);
    expect(find.text('School 7'), findsNothing);

    // Fetch: the code fills the second line in place of the id, so the id no
    // longer shows at all.
    final button = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tile, matching: find.text('ismab')),
        findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('Sint-Pieter')),
        findsOneWidget);
    expect(find.text('id: 7'), findsNothing);

    // Saving persists the code, so a restart keeps identifying it by code.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    final saved = await settings.store.load();
    expect(saved.wisaSchools.single.code, 'ismab');
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets(
      'the Settings grid names a school parsed from the real SMAGetInst CSV '
      'end-to-end — long name on top, short code beneath (#208)',
      (WidgetTester tester) async {
    // The whole path, with no hand-built `WisaSchool` anywhere: real CSV rows →
    // the real `parseSchoolRow` → the real fetch/merge → the real grid, in the
    // real app with real fonts and layout. A fixture that agrees with the bug
    // cannot hide here, because the halves come from the CSV itself.
    useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    // Verbatim rows 11-12 of packages/wisa_api/test/fixtures/sma_get_inst.csv,
    // itself redacted from a live WISA pull. Columns: ID,NAME,DESCRIPTION.
    final fetcher = FakeWisaSchoolFetcher(<WisaSchool>[
      parseSchoolRow('25,Instituut Sancta Maria-A,ISMAA'),
      parseSchoolRow('27,Instituut Sancta Maria-B,ISMAB'),
    ]);
    // A settings document persisted before #208, read back through the real
    // load path: it stored the long name under `code` and the code under
    // `name`, and must render the right way up all the same.
    final legacy = AppSettings.fromJson(<String, dynamic>{
      'wisa': const WisaConnection(server: 'db.school.example', port: '1433')
          .toJson(),
      'wisaSchools': <Map<String, dynamic>>[
        <String, dynamic>{
          'schoolId': 25,
          'code': 'Instituut Sancta Maria-A',
          'name': 'ISMAA',
          'ours': true,
        },
      ],
    });
    final settings = SettingsHarness(
      initial: legacy,
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');

    // Which line is which, not merely which strings are present: the title is
    // the long name and the subtitle the short code.
    final tile = find.byKey(const ValueKey('settings-wisa-school-25-ours'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    String titleOf(Finder f) =>
        (tester.widget<CheckboxListTile>(f).title! as Text).data!;
    String subtitleOf(Finder f) =>
        (tester.widget<CheckboxListTile>(f).subtitle! as Text).data!;
    expect(titleOf(tile), 'Instituut Sancta Maria-A');
    expect(subtitleOf(tile), 'ISMAA');
    expect(find.text('School 25'), findsNothing);

    // A fetch off the real CSV rows reaches the same rendering, and adds the
    // sibling school the same way up.
    final button = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(titleOf(tile), 'Instituut Sancta Maria-A');
    expect(subtitleOf(tile), 'ISMAA');
    final sibling = find.byKey(const ValueKey('settings-wisa-school-27-ours'));
    await tester.ensureVisible(sibling);
    await tester.pumpAndSettle();
    expect(titleOf(sibling), 'Instituut Sancta Maria-B');
    expect(subtitleOf(sibling), 'ISMAB');

    // Saving writes the halves onto the fields that claim them, so the next
    // load needs no migration.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    final saved = await settings.store.load();
    final ismaa = saved.wisaSchools.firstWhere((p) => p.schoolId == 25);
    expect(ismaa.code, 'ISMAA');
    expect(ismaa.name, 'Instituut Sancta Maria-A');
    expect(ismaa.ours, isTrue, reason: 'the managed mark survived the merge');
    expect(ismaa.label, 'Instituut Sancta Maria-A (ISMAA)');
  });

  testWidgets(
      'a sync names the WISA-scholen grid end-to-end — no Scholen ophalen, no '
      'Opslaan (#207)', (WidgetTester tester) async {
    // The reported journey in the real app: the operator opens Instellingen →
    // WISA and sees "School 25", because the stored document predates the
    // profile's `code`/`name` fields and the grid consults no snapshot. One
    // ordinary sync must be enough to fix that — the pull already loads every
    // school. Both bootstraps share the one settings document, exactly as the
    // real app's two Cosmos-backed stores do.
    useTallWindow(tester);
    final settings = SettingsHarness(
      initial: AppSettings.fromJson(<String, dynamic>{
        'wisa': const WisaConnection(server: 'db.school.example', port: '1433')
            .toJson(),
        // The legacy shape: a school id and a managed flag, nothing else.
        'wisaSchools': <Map<String, dynamic>>[
          <String, dynamic>{'schoolId': 25, 'ours': true},
        ],
      }),
      // No fetcher is wired, so "Scholen ophalen" cannot run at all — whatever
      // names the grid must have arrived without it.
    );
    final reconcile = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 25)],
        // Verbatim rows 11-12 of the redacted-from-live SMAGetInst fixture,
        // through the real parser, so the halves are whatever WISA really says.
        schools: <WisaSchool>[
          parseSchoolRow('25,Instituut Sancta Maria-A,ISMAA'),
          parseSchoolRow('27,Instituut Sancta Maria-B,ISMAB'),
        ],
      ),
      smartschool: ssSnap(
          groups: const [], accounts: [ssAccount()], memberships: const []),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: const {25},
      settingsStore: settings.store,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: reconcile.bootstrap,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    // Before any sync: the bug, in the real grid.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    final tile = find.byKey(const ValueKey('settings-wisa-school-25-ours'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    String titleOf(Finder f) =>
        (tester.widget<CheckboxListTile>(f).title! as Text).data!;
    expect(titleOf(tile), 'School 25');
    expect(tester.widget<CheckboxListTile>(tile).subtitle, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
              find.byKey(const ValueKey('settings-wisa-fetch-schools')))
          .onPressed,
      isNull,
      reason: 'no fetcher is wired: the names cannot come from this button',
    );

    // One ordinary sync on the Reconcile view.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Back to Settings and re-read the document — no Opslaan was ever pressed.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(titleOf(tile), 'Instituut Sancta Maria-A');
    expect((tester.widget<CheckboxListTile>(tile).subtitle! as Text).data,
        'ISMAA');
    expect(find.text('School 25'), findsNothing);

    // The repair landed in the document itself — and touched only the two
    // derived halves: the managed mark is still the operator's, and the sync
    // did not add the sibling school the pull also carried.
    final saved = await settings.store.load();
    expect(saved.wisaSchools.single.schoolId, 25);
    expect(saved.wisaSchools.single.name, 'Instituut Sancta Maria-A');
    expect(saved.wisaSchools.single.code, 'ISMAA');
    expect(saved.wisaSchools.single.ours, isTrue);
    expect(saved.wisaSchools.single.virtual, isFalse);
  });

  testWidgets(
      'a drift check ends like a sync end-to-end: a terminal "Driftcontrole '
      'voltooid" line, and the WISA-scholen grid named by the roster it had to '
      'pull (#303)', (WidgetTester tester) async {
    // The companion of the #207 journey above, for the operator whose first
    // pass of the session is **Controleer op drift** rather than
    // **Synchroniseer**. Both asymmetries #303 records show up here in the real
    // app: the pass used to end on its "Gekoppeld: …" summary with nothing
    // saying it had finished, and — although this branch really does pull WISA,
    // because the session holds no roster yet — it left the grid on "School 25".
    useTallWindow(tester);
    final settings = SettingsHarness(
      initial: AppSettings.fromJson(<String, dynamic>{
        'wisa': const WisaConnection(server: 'db.school.example', port: '1433')
            .toJson(),
        'wisaSchools': <Map<String, dynamic>>[
          <String, dynamic>{'schoolId': 25, 'ours': true},
        ],
      }),
    );
    final reconcile = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 25)],
        schools: <WisaSchool>[
          parseSchoolRow('25,Instituut Sancta Maria-A,ISMAA'),
        ],
      ),
      smartschool: ssSnap(
          groups: const [], accounts: [ssAccount()], memberships: const []),
      azure: azSnap(users: [azUser()]),
      ourSchoolIds: const {25},
      settingsStore: settings.store,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: reconcile.bootstrap,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();

    // The Log panel says the pass is over, and says which pass it was.
    expect(find.textContaining('Driftcontrole voltooid — '), findsOneWidget);
    expect(find.textContaining('Klaar.'), findsWidgets);
    expect(
      find.textContaining('Sync voltooid'),
      findsNothing,
      reason: 'no sync ran — the closing line must not claim one did',
    );
    // It pulled WISA (nothing was in hand), so the freshness box carries the
    // roster this pass fetched for itself.
    expect(reconcile.wisaSyncs, 1);
    expect(
        find.byKey(const ValueKey('reconcile-last-sync-wisa')), findsOneWidget);

    // …and having pulled it, the pass repaired the stored school profiles with
    // it — the real grid, re-read from the document, with no Opslaan pressed.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('settings-wisa-school-25-ours'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect((tester.widget<CheckboxListTile>(tile).title! as Text).data,
        'Instituut Sancta Maria-A');
    expect((tester.widget<CheckboxListTile>(tile).subtitle! as Text).data,
        'ISMAA');
    expect(find.text('School 25'), findsNothing);
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.text('Instellingen'));
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

    await tester.tap(find.text('Instellingen'));
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
    expect(find.text('Start'), findsOneWidget);
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
    expect(find.text('Kon je niet aanmelden'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);

    await tester.tap(find.text('Probeer opnieuw'));
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
      'the Actions list filters by any part of the name in any order and by the '
      'only-with-actions switch end-to-end, combining both '
      '(#187/#217/#226/#295)', (WidgetTester tester) async {
    // The real app, real fonts, real window, real keyboard. Three staff: two
    // share the surname "Smit" — Anna is a fresh hire with work, Clara is
    // already in every system — and Bram has a distinct voornaam. The operator
    // narrows the list by name and by the has-actions switch, and the two
    // filters combine.
    //
    // The search box used to live inside an opened Personeel classroom; since
    // #295 it is the flat list's own lookup, on both family tabs.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [
        wisaStaff(
            code: 'SMIT', wisaId: '42', firstName: 'Anna', lastName: 'Smit'),
        wisaStaff(
            code: 'JANS', wisaId: '43', firstName: 'Bram', lastName: 'Jansen'),
        wisaStaff(
            code: 'CSMI', wisaId: '44', firstName: 'Clara', lastName: 'Smit'),
      ]),
      // Clara alone is fully provisioned, so she is the account the work-list
      // filter has to drop while the name search keeps her.
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          ssStaffAccount(
            uid: 'clara.smit',
            accountId: 'CSMI',
            mail: 'clara.smit@school.example',
            givenName: 'Clara',
            surname: 'Smit',
            fax: '0044',
          ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: [
        azStaffUser(
          id: 'az-clara',
          upn: 'clara.smit@school.example',
          employeeId: '44',
          displayName: 'Smit Clara',
          givenName: 'Clara',
          surname: 'Smit',
        ),
      ]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Open the Actions tab. The work-list filter is on by default since #226
    // and sits above the family tab bar; this test starts from the full list.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Go to Personeel — the switch survives the tab change (#226).
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);

    final String anna = accountId(harness, 'Anna Smit');
    final String bram = accountId(harness, 'Bram Jansen');
    final String clara = accountId(harness, 'Clara Smit');
    Finder rowOf(String id) => find.byKey(ValueKey('account-row-$id'));

    // All three staff render, under the list's own search box.
    expect(rowOf(anna), findsOneWidget);
    expect(rowOf(bram), findsOneWidget);
    expect(rowOf(clara), findsOneWidget);
    final search = find.byKey(const ValueKey('actions-search'));
    expect(search, findsOneWidget);

    // Search on the surname "Smit": both Smits match, Jansen drops out.
    await tester.enterText(search, 'smit');
    await tester.pumpAndSettle();
    expect(rowOf(anna), findsOneWidget);
    expect(rowOf(clara), findsOneWidget);
    expect(rowOf(bram), findsNothing);

    // Both halves of one name, typed in the stored order and reversed (#217).
    // Reversed is the half of the time the operator misremembers which way
    // round the name is stored; it used to return an empty list, because the
    // needle was matched as one contiguous substring of "Voornaam Naam".
    await tester.enterText(search, 'anna smit');
    await tester.pumpAndSettle();
    expect(rowOf(anna), findsOneWidget);
    expect(rowOf(clara), findsNothing);
    await tester.enterText(search, 'smit anna');
    await tester.pumpAndSettle();
    expect(rowOf(anna), findsOneWidget);
    expect(rowOf(clara), findsNothing);
    expect(rowOf(bram), findsNothing);

    // Every part must occur, so parts taken from two different people match
    // neither — the operator sees the filter-empty line, not both of them.
    await tester.enterText(search, 'anna jansen');
    await tester.pumpAndSettle();
    expect(
        find.text('Geen accounts die aan de filter voldoen.'), findsOneWidget);

    // Back to "Smit", then combine with the work-list switch back on: only
    // Anna keeps an action, so Clara (name-matched but action-free) drops too.
    await tester.enterText(search, 'smit');
    await tester.pumpAndSettle();
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(rowOf(anna), findsOneWidget);
    expect(rowOf(clara), findsNothing);
    expect(rowOf(bram), findsNothing);
  });

  testWidgets(
      'the operator drag-selects two log lines and copies them one per line, '
      'then Alles kopiëren takes the whole buffer end-to-end (#193)',
      (WidgetTester tester) async {
    // The real app composition — real fonts, real window, real text layout —
    // is where a "selectable" log panel drifts: the line metrics a drag is
    // resolved against come from the real font, and the copy path runs through
    // the real SelectionArea/shortcut plumbing, not a widget-test stub.
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

    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // A real pass fills the panel; then a known tail so the drag has stable
    // line contents to land on (the harness clock is fixed at 00:00:00).
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.log.entries, isNotEmpty);
    harness.log
      ..addError(Origin.smartschool, 'Set-Password failed: rc=42')
      ..addMessage(Origin.azure, 'Ready.');
    await tester.pumpAndSettle();

    // Newest first, so the two lines just added are the top two on screen.
    final Finder block = find.byKey(const ValueKey('reconcile-log-text'));
    expect(block, findsOneWidget);
    final List<String> onScreen =
        tester.widget<Text>(block).textSpan!.toPlainText().split('\n');
    expect(onScreen.first, '00:00:00  [azure]  Ready.');
    expect(onScreen[1], '00:00:00  [smartschool]  Set-Password failed: rc=42');

    // Drag across those two lines with the mouse and hit Ctrl+C.
    final Rect rect = tester.getRect(block);
    final double lineHeight = rect.height / onScreen.length;
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
    expect(copied.single, '${onScreen.first}\n${onScreen[1]}');

    // Alles kopiëren reaches past what is laid out: the whole buffer, oldest
    // first.
    await tester.tap(find.byKey(const ValueKey('reconcile-log-copy-all')));
    await tester.pumpAndSettle();
    expect(copied.last, harness.log.toPlainText());
    expect(copied.last.split('\n'), hasLength(harness.log.entries.length));
    expect(copied.last.split('\n').length, greaterThan(2));
    expect(copied.last, endsWith('00:00:00  [azure]  Ready.'));
  });

  testWidgets(
      'the operator right-clicks one log line and Regel kopiëren puts just '
      'that message on the clipboard end-to-end (#197)',
      (WidgetTester tester) async {
    // Grabbing a single message was already possible after #193 - a
    // triple-click selects one paragraph, which is one entry - but nothing on
    // screen said so. The affordance is a context-menu entry whose target is
    // resolved from the paragraph line the pointer landed on, so it has to be
    // driven through the real app: the real font decides where the second row
    // starts, and the menu itself goes through the real overlay.
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

    useTallWindow(tester);
    final harness = ReconcileHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();

    // A real pass fills the panel, then a known short tail so the row the
    // click lands on has stable contents and cannot soft-wrap (the harness
    // clock is fixed at 00:00:00).
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.log.entries, isNotEmpty);
    harness.log
      ..clear()
      ..addMessage(Origin.wisa, 'Sync done.')
      ..addError(Origin.smartschool, 'Set-Password failed: rc=42')
      ..addMessage(Origin.azure, 'Ready.');
    await tester.pumpAndSettle();

    // Newest first, so the error is the middle of the three rendered lines.
    final Finder block = find.byKey(const ValueKey('reconcile-log-text'));
    expect(block, findsOneWidget);
    final List<String> onScreen =
        tester.widget<Text>(block).textSpan!.toPlainText().split('\n');
    expect(onScreen, hasLength(3));
    expect(onScreen[1], '00:00:00  [smartschool]  Set-Password failed: rc=42');

    // Right-click that middle line with the mouse.
    final Rect rect = tester.getRect(block);
    final double lineHeight = rect.height / onScreen.length;
    final TestGesture click = await tester.startGesture(
      Offset(rect.left + 8, rect.top + lineHeight * 1.5),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await click.up();
    await tester.pumpAndSettle();

    // The affordance is on screen, and it takes exactly the entry under the
    // pointer: one line, neither neighbour, no trailing newline.
    expect(find.text('Regel kopiëren'), findsOneWidget);
    await tester.tap(find.text('Regel kopiëren'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, onScreen[1]);
    expect(copied.single, isNot(contains('\n')));
  });

  testWidgets(
      'the Settings view authors the two Smartschool import rules end-to-end, '
      "and the saved rules prune the next pull's group tree (#202)",
      (WidgetTester tester) async {
    // The real app composition over the in-memory settings seams — real fonts,
    // real navigation, real layout. Until now the Smartschool tab rendered its
    // rules under a section literally headed "Importregels (alleen-lezen)" with
    // no way to create one, so in practice there were no rules at all and the
    // whole group tree — organisational subtrees included — came in on every
    // pull. Drive the editor the way the operator does, then hand the *saved*
    // rules to the production connector exactly as bootstrapReconcile does
    // (`ssConnector.sync(rules: settings.smartschoolRules)`).
    useTallWindow(tester);
    final settings = SettingsHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-smartschool');

    // The section is an editor now, not a read-only list.
    expect(find.text('Importregels'), findsOneWidget);
    expect(find.textContaining('alleen-lezen'), findsNothing);
    expect(
        find.byKey(const ValueKey('settings-ss-rules-empty')), findsOneWidget);

    // Author one rule of each type, then save the document.
    await addSmartschoolRule(tester, 'discardGroup', 'Organisatie');
    await addSmartschoolRule(tester, 'noSubgroups', 'Klassen');
    expect(find.textContaining('Smartschool-groep negeren: Organisatie'),
        findsOneWidget);
    expect(find.textContaining('Geen subgroepen: Klassen'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // They landed in the settings document on the codec's existing wire shape.
    final saved = await settings.store.load();
    expect(saved.toJson()['smartschoolRules'], <Map<String, dynamic>>[
      {'type': 'discardSmartschoolGroup', 'groupName': 'Organisatie'},
      {'type': 'noSmartschoolSubgroups', 'groupName': 'Klassen'},
    ]);

    // …and the next pull really is pruned by them: the production connector,
    // over a scripted SOAP wire, handed nothing but what Settings persisted.
    final wire = GroupTreeSoap();
    final snapshot = await SmartschoolConnector.fromParts(
      site: 'school',
      accessCode: 'ac',
      transport: wire,
    ).sync(rules: saved.smartschoolRules);

    // "Organisatie" and its subtree are gone; "Klassen" survives without its
    // children. Only the root and Klassen remain.
    expect(snapshot.groups.map((g) => g.id.value).toList(),
        <String>['SCH', 'KLA']);
    // And the pruning happened before the account reads, so the connector never
    // even asked Smartschool about the removed groups.
    expect(wire.accountCodes, <String>['SCH', 'KLA']);
  });

  testWidgets(
      'a Smartschool import rule fires however the operator spelled it, and a '
      'rule that matches nothing says so in the log (#241)',
      (WidgetTester tester) async {
    // The whole loop the operator lives: author the rules in Instellingen, then
    // Synchronise and read the Log panel. The rules used to be matched against
    // the group tree with a raw `==`, so a rule typed in lower case — or one
    // carrying the spacing of a name pasted out of Smartschool — quietly did
    // nothing at all, and looked exactly like a rule that had matched a subtree
    // which was already empty. Both halves are checked end-to-end here: the
    // differently-spelled rules really prune the pull, and the third rule
    // (a typo) is named in the panel instead of vanishing.
    useTallWindow(tester);
    final settings = SettingsHarness();
    final wire = GroupTreeSoap();
    // The next session's reconcile stack, whose Smartschool pull is the
    // production connector over that wire; its rules are picked up from the
    // settings document below, as bootstrapReconcile picks them up on open.
    final harness = ReconcileHarness(smartschoolTransport: wire);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-smartschool');

    // Smartschool spells them `Organisatie` and `Klassen`; the operator does
    // not, and never had a reason to think it mattered. The third rule names a
    // group Smartschool does not carry at all.
    await addSmartschoolRule(tester, 'discardGroup', 'organisatie');
    await addSmartschoolRule(tester, 'noSubgroups', 'KLASSEN');
    await addSmartschoolRule(tester, 'discardGroup', 'Sportclub');
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await settings.store.load();
    expect(saved.smartschoolRules, hasLength(3));
    harness.smartschoolRules = saved.smartschoolRules;

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The pull really was pruned by rules spelled nothing like the tree:
    // "Organisatie" and its subtree are gone, "Klassen" survives as a leaf, and
    // the connector never even asked Smartschool about the removed groups.
    expect(
      harness.app.smartschool.snapshot?.groups.map((g) => g.id.value).toList(),
      <String>['SCH', 'KLA'],
    );
    expect(wire.accountCodes, <String>['SCH', 'KLA']);

    // …and the rule that matched nothing is named in the Log panel, so the
    // typo is visible rather than silent.
    expect(
      find.textContaining(
        'Importregel "Sportclub" kwam bij deze ophaalbeurt met geen enkele '
        'Smartschool-groep overeen',
      ),
      findsOneWidget,
    );
    // …in Dutch, like every other line of the pass around it (#266).
    expect(find.textContaining('matched no Smartschool group'), findsNothing);
    // The two that did fire are not reported — that is the distinction the
    // operator could not make before.
    expect(find.textContaining('Importregel "organisatie"'), findsNothing);
    expect(find.textContaining('Importregel "KLASSEN"'), findsNothing);
  });

  testWidgets(
      'the Smartschool pull is scoped to the roots Instellingen names, so a '
      'beheerder account never becomes a staff record (#351)',
      (WidgetTester tester) async {
    // As reported on the live platform: several staff members keep a second,
    // admin-featured Smartschool account that shares the mail of their normal
    // one. That is intended and must stay — but the pull walked the *whole*
    // group forest and asked every node for its accounts, so the admin account
    // came in too. The student/staff split happens far downstream, in the
    // linker, on `Basisrol` alone, at which point it is indistinguishable from
    // a real staff member: it became a `LinkedStaff` of its own, took the
    // Office 365 user off the real record by mail (so Anna was offered "Maak
    // een nieuw Office 365 account" for an account that plainly exists), and —
    // having no WISA counterpart — read as *departed*, which since #349 offers
    // to delete the very Azure account it had just captured.
    //
    // Only a full run puts that on screen. The pull, the link, the dispatch and
    // two screens are all involved, and so is the second half of the change:
    // scoping drops out-of-root groups from the snapshot, so the official class
    // sitting under Beheerders no longer seeds a Klasgroepen orphan (#52/#225).
    useTallWindow(tester);
    // A tenant tree with the two managed roots and a third beside them. The
    // beheerders subtree comes *first*, which is what put its account ahead of
    // the real one in snapshot order and let it claim the shared mail.
    const String tree = '<groups>'
        '<group><name>School</name><type>G</type><code>SCH</code>'
        '<visible>1</visible><children>'
        '<group><name>Beheerders</name><type>G</type><code>BEH</code>'
        '<visible>1</visible><children>'
        '<group><name>9Z</name><type>K</type><code>C9Z</code>'
        '<visible>1</visible><isOfficial>1</isOfficial></group>'
        '</children></group>'
        '<group><name>Leerlingen</name><type>G</type><code>LLN</code>'
        '<visible>1</visible><children>'
        '<group><name>1A</name><type>K</type><code>C1A</code>'
        '<visible>1</visible><isOfficial>1</isOfficial></group>'
        '</children></group>'
        '<group><name>Personeel</name><type>G</type><code>PERS</code>'
        '<visible>1</visible></group>'
        '</children></group></groups>';
    final wire = GroupTreeSoap(
      tree: tree,
      accounts: <String, String>{
        // Anna's real account: the WISA staff code as internal number, her
        // zero-padded wisaId in `fax`, in step with WISA and Azure.
        'PERS': '[{"voornaam":"Anna","naam":"Smit",'
            '"gebruikersnaam":"anna.smit","internnummer":"SMIT",'
            '"status":"actief","basisrol":"13","geslacht":"f",'
            '"emailadres":"anna.smit@school.example","fax":"0042",'
            '"stamboeknummer":"0",'
            '"groups":[{"id":"201","code":"PERS","name":"Personeel"}]}]',
        // Her admin account: same mail, no WISA counterpart, a teacher
        // Basisrol like every beheerder here carries.
        'BEH': '[{"voornaam":"Anna","naam":"Smit (beheer)",'
            '"gebruikersnaam":"anna.smit.admin","internnummer":"SMITADM",'
            '"status":"actief","basisrol":"13","geslacht":"f",'
            '"emailadres":"anna.smit@school.example","fax":"",'
            '"stamboeknummer":"0",'
            '"groups":[{"id":"301","code":"BEH","name":"Beheerders"}]}]',
      },
    );
    // One LiveSettings for both bootstraps, exactly as `main()` wires them, so
    // what Instellingen saves is what the next pull is scoped by (#238/#246).
    final live = LiveSettings();
    final harness = ReconcileHarness(
      smartschoolTransport: wire,
      liveSettings: live,
      ourSchoolIds: const {1},
      wisa: wisaSnap(
        students: const [],
        staff: [wisaStaff()],
        schools: [wisaSchool(1)],
      ),
      // Her Office 365 account, `department` naming our school and ours alone —
      // the shape that makes the departure branch offer to delete it outright.
      azure: azSnap(users: [azStaffUser(department: 'GBS')]),
    );
    final settings = SettingsHarness(liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // The operator opens Instellingen and finds the roots already named — the
    // document says what the pull is scoped to rather than leaving an empty box
    // that would mean "everything".
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-smartschool');
    final Finder roots = find.byKey(const ValueKey('settings-ss-roots'));
    await tester.ensureVisible(roots);
    expect(tester.widget<TextField>(roots).controller!.text,
        'Leerlingen, Personeel');

    // They retype them the way anyone types a list, and it still names the same
    // two groups: the roots are matched on the normalized name (#241), not raw.
    await tester.enterText(roots, 'leerlingen,  personeel ');
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect((await settings.store.load()).smartschoolRoots,
        <String>['leerlingen', 'personeel']);

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pull visited the two roots and nothing else — and never even asked
    // Smartschool about the beheerders subtree, which is a SOAP call per node
    // saved as well as an account kept out.
    expect(
      harness.app.smartschool.snapshot?.groups.map((g) => g.id.value).toList(),
      <String>['LLN', 'C1A', 'PERS'],
    );
    expect(wire.accountCodes, <String>['LLN', 'C1A', 'PERS']);
    expect(
      harness.app.smartschool.snapshot?.accounts.map((a) => a.uid).toList(),
      <String>['anna.smit'],
    );
    // …and the pass says so, so a scoped pull is never a silently short one.
    expect(
      harness.log.entries.map((e) => e.message),
      contains('De ophaalbeurt is beperkt tot: Leerlingen, Personeel.'),
    );

    // One staff record, holding all three systems: the Office 365 user is on
    // the real account, because nothing else was there to claim it by mail.
    final staff = harness.controller.linked!.snapshot.staff;
    expect(staff, hasLength(1));
    expect(staff.single.smartschool?.uid, 'anna.smit');
    expect(staff.single.wisa, isNotNull);
    expect(staff.single.azure?.id, 'az-staff');

    // Nothing anywhere in the pass proposes the four things the phantom record
    // used to: two Smartschool removals aimed at a live, wanted admin account,
    // the Azure delete aimed at a real staff member's account, and the create
    // that fired on the real record once its Azure user had been taken.
    final kinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toSet();
    expect(kinds, isNot(contains('RemoveStaffFromAzure')));
    expect(kinds, isNot(contains('RemoveStaffFromSmartschool')));
    expect(kinds, isNot(contains('DeactivateStaffInSmartschool')));
    expect(kinds, isNot(contains('AddStaffToAzure')));

    // And that is what the operator sees on the tab they reported this from.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    final Finder toggle =
        find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.textContaining('beheer'), findsNothing,
        reason: 'the admin account is no longer a person on this list');
    expect(find.text('Maak een nieuw Office 365 account'), findsNothing,
        reason: 'her account exists — it was simply attached to the wrong '
            'record');
    expect(find.text('Verwijder Azure account'), findsNothing);

    // The second half of the change: an out-of-root group is gone from the
    // snapshot, so the official class under Beheerders no longer reads as a
    // Smartschool class WISA has never heard of. The in-root one still does —
    // scoping narrows what we look at, it does not blunt what we find there.
    await openKlasgroepen(tester);
    expect(find.byKey(const ValueKey('class-row-1A')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-9Z')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a werkdatum saved in Instellingen reaches the very next Synchroniseer, '
      'and Check for drift refuses until it has (#238)',
      (WidgetTester tester) async {
    // The whole loop the operator lives, end-to-end in the real app: sync,
    // change the werkdatum in Instellingen, save, sync again — and read back
    // which date WISA was actually asked for. Both bootstraps share **one**
    // LiveSettings, exactly as `main()` wires them; before #238 they each held
    // their own frozen copy, so a saved werkdatum reached the connector only
    // after a relaunch and nothing on screen said so.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // A first Synchroniseer pulls WISA with the stored werkdatum.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(wire.werkdatums, <String>['01/09/2025']);

    // Now the operator moves the werkdatum, the way they do: Instellingen →
    // Algemeen → Kies datum → Opslaan.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    final pick = find.byKey(const ValueKey('settings-workdate-pick'));
    await tester.ensureVisible(pick);
    await tester.pumpAndSettle();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('15'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect(
      (await settings.store.load()).wisa.workDate.date,
      DateTime(2025, 9, 15),
    );

    // Back on Reconcile the change is *visible*: Check for drift is disabled
    // and says why. A drift pass never re-reads WISA, so running one now would
    // relink against the roster the change never reached and publish that to
    // every other operator.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reconcile-drift-blocked')),
      findsOneWidget,
    );
    expect(
      find.text('WISA-instellingen gewijzigd — synchroniseer eerst.'),
      findsOneWidget,
    );
    final OutlinedButton drift = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('reconcile-drift')),
    );
    expect(drift.onPressed, isNull);
    // Synchroniseer stays available — it is the way out.
    final FilledButton syncButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('reconcile-sync')),
    );
    expect(syncButton.onPressed, isNotNull);

    // Pressing it pulls WISA with the werkdatum just saved — no relaunch — and
    // the drift check is offered again.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(wire.werkdatums, <String>['01/09/2025', '15/09/2025']);
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('reconcile-drift')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'marking a school beheerd in Instellingen surfaces its students without '
      'a relaunch (#246)', (WidgetTester tester) async {
    // The headline symptom of #246, driven the way the operator lives it: the
    // Actions drill-down hides a school's students, they tick **beheerd** in
    // Instellingen, save, and come back. Before #246 the applier's managed-school
    // set was captured when `bootstrapReconcile` assembled the stack, so the
    // student stayed in the leaver bucket until the app was relaunched — with
    // nothing on screen to explain why.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: const WisaConnection(server: 'wisa.example', port: '9000'),
      wisaSchools: const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 1, code: 'S1', name: 'Sint-Jan', ours: true),
        WisaSchoolProfile(schoolId: 2, code: 'S2', name: 'Sint-Pieter'),
      ],
    );
    final live = LiveSettings(stored);
    // One student, enrolled in school 2 and fully present in our Smartschool +
    // Azure. A WISA snapshot carries no ownership (#286), so who is managed can
    // only come from the settings document — the #178 wiring, now live.
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(schoolId: 2)],
        schools: [wisaSchool(1), wisaSchool(2)],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azUser()]),
      liveSettings: live,
    );
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // School 2 is not ours yet, so its student is re-bucketed as a leaver and
    // their row names no class of ours.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    String studentRowKey() =>
        'account-row-${harness.controller.pendingEntries.firstWhere((e) => e.family == 'student').targetId}';
    expect(
      find.descendant(
        of: find.byKey(ValueKey(studentRowKey())),
        matching: find.text('Zonder klas'),
      ),
      findsOneWidget,
    );

    // Instellingen → Wisa → tick "beheerd" for Sint-Pieter → Opslaan.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    final ours = find.byKey(const ValueKey('settings-wisa-school-2-ours'));
    await tester.ensureVisible(ours);
    await tester.pumpAndSettle();
    await tester.tap(ours);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect((await settings.store.load()).managedWisaSchoolIds, const {1, 2});

    // Back on Reconcile, Check for drift is offered: ownership is applied when
    // the view is relinked, not when WISA is pulled, so the #238 gate — which
    // guards the WISA pull inputs — must not stand in the way here.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(find.byKey(const ValueKey('reconcile-relaunch-required')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();

    // …and the student is out of the leaver bucket, their row naming their own
    // class, with no relaunch anywhere in this test.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final Finder studentRow = find.byKey(ValueKey(studentRowKey()));
    await tester.ensureVisible(studentRow);
    expect(find.descendant(of: studentRow, matching: find.text('Zonder klas')),
        findsNothing);
    expect(find.descendant(of: studentRow, matching: find.text('3C')),
        findsOneWidget);
  });

  testWidgets(
      'a Smartschool import rule saved in Instellingen prunes the very next '
      'Synchroniseer, and the screen says so meanwhile (#246/#259)',
      (WidgetTester tester) async {
    // #241's end-to-end proved the rules work; it had to hand-carry the saved
    // document into the reconcile harness itself, because the running pull had
    // closed over the bootstrap one. Nothing is handed over here — the two
    // bootstraps share one LiveSettings, exactly as `main()` wires them.
    //
    // And the pass driven here is the one the operator actually reaches for.
    // Until #259 this journey ended in the reported bug: #99's smart sync left
    // Smartschool alone because the session already held it, so Synchroniseer
    // pulled WISA, found it unchanged and reported "geen accountwijzigingen
    // nodig" — over the rule the operator had just saved. Only Check for drift
    // adopted it, and nothing on screen said so.
    useTallWindow(tester);
    final wire = GroupTreeSoap();
    final live = LiveSettings(const AppSettings());
    final settings = SettingsHarness(liveSettings: live);
    final harness =
        ReconcileHarness(smartschoolTransport: wire, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // A first pass, on the rules as they stand: the whole tree comes in.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      harness.app.smartschool.snapshot?.groups.map((g) => g.id.value).toList(),
      <String>['SCH', 'ORG', 'HID', 'KLA', 'C1A'],
    );

    // The operator authors the rule that drops "Organisatie" and saves.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-smartschool');
    await addSmartschoolRule(tester, 'discardGroup', 'Organisatie');
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect(
      (await settings.store.load()).smartschoolRules.single,
      isA<DiscardSmartschoolGroup>(),
    );

    // Back on Reconcile the screen names the save that is still waiting — the
    // silence #259 closed. Nothing is refused: an import rule is not a WISA
    // pull input, so #238's drift gate stays open too.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(
      find.byKey(const ValueKey('reconcile-settings-pending')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Instellingen voor Smartschool gewijzigd'),
      findsOneWidget,
    );

    // The operator presses **Synchroniseer**, the pass they reach for.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The pull it just ran is the pruned one. No drift check, no hand-off, no
    // relaunch.
    expect(
      harness.app.smartschool.snapshot?.groups.map((g) => g.id.value).toList(),
      <String>['SCH', 'KLA', 'C1A'],
    );
    // …the notice is gone, because the pass applied it…
    expect(
      find.byKey(const ValueKey('reconcile-settings-pending')),
      findsNothing,
    );
    // …and the Log panel never claimed there was nothing to do, which is the
    // half of this bug the operator actually saw.
    expect(find.textContaining('geen accountwijzigingen nodig'), findsNothing);
    expect(
      find.textContaining(
        'Smartschool-instellingen gewijzigd — Smartschool wordt opnieuw '
        'opgehaald.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'a WISA import rule on the shared settings document prunes the very next '
      'Synchroniseer, and Check for drift refuses until it has (#263)',
      (WidgetTester tester) async {
    // The reported bug, driven end-to-end over the *production* WISA pull.
    // `bootstrapReconcile` seeded the shared `WisaImportRules` holder from the
    // document it read at startup and nothing ever published a saved document
    // back into it, so a WISA import rule on the settings document reached the
    // pull only after a relaunch — and nothing on screen said so.
    //
    // Both bootstraps share one LiveSettings, exactly as `main()` wires them,
    // and every step after the shared-store write is the operator's own: open
    // Instellingen, press **Herladen**, read the rule back, press
    // **Synchroniseer**.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // A first Synchroniseer, on the rules as they stand: the whole roster comes
    // in, class 3C included.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 1 klassen.',
      ),
      findsOneWidget,
    );

    // Instellingen → Wisa carries no import rule yet.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(
      find.byKey(const ValueKey('settings-wisa-rules-empty')),
      findsOneWidget,
    );

    // Another operator writes one into the shared settings document — the WISA
    // rules are read-only in this view, so the store is where they arrive.
    await settings.store.save(stored.copyWith(
      wisaRules: const <WisaImportRule>[DontImportClass('3C')],
    ));

    // The operator pulls it into this session with **Herladen**, the affordance
    // the view offers for exactly that, and reads it back on the Wisa tab.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(
      find.text('Klas niet importeren uit WISA: 3C'),
      findsOneWidget,
    );

    // Back on Reconcile the change is *visible*: a drift pass never re-reads
    // WISA, so running one now would relink the roster the rule never reached
    // and publish that to every other operator.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reconcile-drift-blocked')),
      findsOneWidget,
    );
    expect(
      find.text('WISA-instellingen gewijzigd — synchroniseer eerst.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('reconcile-drift')))
          .onPressed,
      isNull,
    );

    // Pressing Synchroniseer pulls WISA with the rule — no relaunch — and the
    // roster it landed is the pruned one.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 0 klassen.',
      ),
      findsOneWidget,
    );
    // …and the drift check is offered again.
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('reconcile-drift')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'a WISA import rule authored in Instellingen prunes the very next '
      'Synchroniseer (#273)', (WidgetTester tester) async {
    // #263 wired a *persisted* WISA rule through to the pull, but nothing in the
    // app could put one there: the Wisa tab's rule list was titled "Importregels
    // (alleen-lezen)" and `_collect` handed `base.wisaRules` straight back, so
    // the only authoring surface was the Cosmos settings document itself. #263's
    // own end-to-end had to write the rule into the shared store behind the UI's
    // back for exactly that reason.
    //
    // Nothing is written behind anyone's back here. Every step is the operator's
    // own — Instellingen → Wisa → **Toevoegen** → *Klas niet importeren* → 3C →
    // **Opslaan** → **Synchroniseer** — over the production WISA pull.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // A first Synchroniseer, on the rules as they stand: the whole roster comes
    // in, class 3C included.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 1 klassen.',
      ),
      findsOneWidget,
    );

    // Instellingen → Wisa: no rule yet, and an editor to author one in.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(
      find.byKey(const ValueKey('settings-wisa-rules-empty')),
      findsOneWidget,
    );
    expect(find.textContaining('alleen-lezen'), findsNothing);

    // The operator authors the rule that drops 3C, and saves.
    await addWisaRule(tester, 'dontImportClass', <String>['3C']);
    expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // It landed on the settings document, on the wire shape #263's pull reads.
    final saved = await settings.store.load();
    expect(saved.wisaRules.single, isA<DontImportClass>());
    expect((saved.wisaRules.single as DontImportClass).className, '3C');

    // Back on Reconcile the save is *visible*: a drift pass never re-reads WISA,
    // so running one now would relink the roster the rule never reached.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reconcile-drift-blocked')),
      findsOneWidget,
    );
    expect(
      find.text('WISA-instellingen gewijzigd — synchroniseer eerst.'),
      findsOneWidget,
    );

    // Synchroniseer pulls WISA with the authored rule — no relaunch, no
    // hand-carried document — and the roster it landed is the pruned one.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 0 klassen.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);

    // …and it survives a reload of the document, so the next session (and every
    // other operator) gets the same pull.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);
  });

  testWidgets(
      'a settings document carrying the retired MarkAsOurs rule still loads, '
      'and the dead rule is gone from the view and the next save (#286)',
      (WidgetTester tester) async {
    // `MarkAsOurs` was a rule an operator could author and that then silently
    // did nothing — ownership comes from the WISA-scholen list, which wins as
    // soon as it holds one school. #286 deleted it. The shared settings document
    // is what every operator and every older build writes into, so one that
    // still carries the tag has to load rather than take the app down; the entry
    // is ignored, and the rules that *do* something are untouched.
    //
    // The document can only be introduced as raw JSON now that the type is gone
    // — which is exactly how it comes back from Cosmos.
    useTallWindow(tester);
    final stored = AppSettings.fromJson(<String, dynamic>{
      'wisaRules': <dynamic>[
        <String, dynamic>{'type': 'markAsOurs', 'schoolCode': 'ISMAA'},
        <String, dynamic>{'type': 'dontImportClass', 'className': '3C'},
      ],
    }).copyWith(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // The production WISA pull runs on the document as stored: the surviving
    // rule still prunes 3C, and the retired one changes nothing (as it never
    // did).
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 0 klassen.',
      ),
      findsOneWidget,
    );

    // Instellingen → Wisa lists the live rule and nothing about "beheerd" —
    // there is no rule kind left to render, and no dead row to puzzle over.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);
    expect(find.textContaining('Markeer als beheerd'), findsNothing);
    // Toevoegen cannot author one either.
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-wisa-rule-add')));
    await tester.tap(find.byKey(const ValueKey('settings-wisa-rule-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-wisa-rule-add-markAsOurs')),
        findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Saving rewrites the document without it, so the next operator to open it
    // never sees the dead entry again.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    final saved = await settings.store.load();
    expect(saved.wisaRules.single, isA<DontImportClass>());
    expect(
      (saved.toJson()['wisaRules'] as List<dynamic>)
          .map((dynamic r) => (r as Map<String, dynamic>)['type']),
      <String>['dontImportClass'],
    );
  });

  testWidgets(
      'a settings document carrying the retired MarkAsVirtual rule migrates its '
      'mark to the WISA-scholen grid, and the virtuele werkdatum still reaches '
      'the pull (#277)', (WidgetTester tester) async {
    // The risk this issue names: the mark is live configuration, and losing it
    // is seasonally invisible — the school simply pulls with the ordinary
    // werkdatum and fails to produce next year's students months later. So the
    // proof runs end-to-end over the *production* WISA pull: the migrated mark
    // has to put the virtuele werkdatum on the wire for that school, show up as
    // the grid's own (unlocked) checkbox, and survive the next save with no rule
    // left behind.
    //
    // The document can only be introduced as raw JSON now that the type is gone
    // — which is exactly how it comes back from Cosmos.
    useTallWindow(tester);
    final stored = AppSettings.fromJson(<String, dynamic>{
      'wisaRules': <dynamic>[
        <String, dynamic>{'type': 'markAsVirtual', 'schoolCode': 'V'},
        <String, dynamic>{'type': 'dontImportClass', 'className': 'OKAN'},
      ],
      'wisaSchools': <dynamic>[
        const WisaSchoolProfile(schoolId: 1, code: 'S1', name: 'School 1')
            .toJson(),
        const WisaSchoolProfile(
          schoolId: 99,
          code: 'V',
          name: 'Virtuele school',
          ours: true,
        ).toJson(),
      ],
    }).copyWith(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
        virtualWorkDate:
            WorkDateSetting(isNow: false, date: DateTime(2025, 10, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap(schools: const <(int, String, String)>[
      (1, 'School 1', 'S1'),
      (99, 'Virtuele school', 'V'),
    ]);
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The capability is untouched: school 99 still went out on the virtuele
    // werkdatum, the ordinary school on the ordinary one — and the Log panel
    // names both, exactly as it did while the rule existed.
    expect(wire.werkdatums, <String>['01/09/2025', '01/10/2025']);
    expect(
      find.textContaining(
        'WISA ophalen met werkdatum 01/09/2025; virtuele werkdatum '
        '01/10/2025 voor V.',
      ),
      findsOneWidget,
    );

    // Instellingen → Wisa: the mark now lives on the grid's own checkbox, and
    // that checkbox is editable — the #273 lock existed only because a rule
    // could contradict it.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await openSettingsTab(tester, 'settings-tab-wisa');
    final virtualBox =
        find.byKey(const ValueKey('settings-wisa-school-99-virtual'));
    await tester.ensureVisible(virtualBox);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(virtualBox).value, isTrue);
    expect(tester.widget<CheckboxListTile>(virtualBox).onChanged, isNotNull);
    expect(find.text('virtueel (importregel)'), findsNothing);

    // The rules list keeps the rule that does something and says nothing about
    // virtueel; Toevoegen cannot author one either.
    expect(find.text('Klas niet importeren uit WISA: OKAN'), findsOneWidget);
    expect(find.textContaining('Markeer als virtueel'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-wisa-rule-add')));
    await tester.tap(find.byKey(const ValueKey('settings-wisa-rule-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-wisa-rule-add-markAsVirtual')),
        findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Saving writes the mark where the grid keeps it and drops the rule for
    // good, so the migration runs once and the next operator sees one surface.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    final saved = await settings.store.load();
    expect(saved.virtualWisaSchoolIds, <int>{99});
    expect(saved.wisaRules.single, isA<DontImportClass>());
    expect(
      (saved.toJson()['wisaRules'] as List<dynamic>)
          .map((dynamic r) => (r as Map<String, dynamic>)['type']),
      <String>['dontImportClass'],
    );
  });

  testWidgets(
      'a DontImportFromWisa apply writes its rule to the shared settings '
      'document, where it outlives the session and is removable (#276)',
      (WidgetTester tester) async {
    // The reported bug, driven end-to-end over the *production* WISA pull. A
    // `DontImportFromWisa` apply only ever grew the process-lifetime
    // `WisaImportRules` holder, so the exclusion it earned did not merely
    // evaporate on relaunch — it oscillated. The apply drops the class (or the
    // retired staff member) from this run's snapshot, the Office 365 side keeps
    // surfacing (#269) so the operator deletes it, and the next launch rebuilds
    // the holder empty: WISA still reports the record, nothing exists
    // downstream, and the app proposes creating it. The rule was also invisible
    // in Instellingen, so it could neither be seen nor undone.
    //
    // Every step here is the operator's own — Klasgroepen → the class → *Negeer
    // deze klas* → **Toepassen**, then Instellingen → **Herladen** → Wisa —
    // and the reload is what stands in for the relaunch: it is the stored
    // document coming back, which is all any other operator or session ever
    // sees.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    final wire = RecordingWisaSoap();
    // The cold store every other session seeds from, so this run can check what
    // the apply left in it (#347).
    final snapshots = InMemorySnapshotStore();
    final harness = ReconcileHarness(
      wisaTransport: wire,
      liveSettings: live,
      settingsStore: settings.store,
      store: snapshots,
      // Smartschool holds only the root a new class would hang under, so WISA's
      // `3C` is genuinely absent downstream and raises the #244 either/or.
      smartschool: ssSnap(
        groups: [
          ssGroup(
            'Leerlingen',
            code: 'SCHOOL',
            official: false,
            type: GroupType.group,
          ),
        ],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
      classTree: const SmartschoolClassTree(path: 'SCHOOL'),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // A first Synchroniseer: the whole roster comes in, class 3C included.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 1 klassen.',
      ),
      findsOneWidget,
    );

    // Klasgroepen offers the class as one either/or; the operator switches it
    // to the opt-out.
    await openKlasgroepen(tester);
    final entry = find.byKey(const ValueKey('entry-group-3C'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('alt-3C-DoNotImportFromWisa')));
    await tester.pumpAndSettle();

    // The confirmation says outright that this is permanent and shared — the
    // operator's one chance to know a standing, group-wide decision is what the
    // button commits them to.
    await tester.ensureVisible(find.byKey(const ValueKey('entry-apply-3C')));
    await tester.tap(find.byKey(const ValueKey('entry-apply-3C')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('bewaart 1 importregel blijvend voor iedereen'),
      findsOneWidget,
    );
    // What the apply costs, measured on both sides of the seam: the WISA syncer
    // and the SOAP wire underneath it.
    final pulls = harness.wisaSyncs;
    final queries = wire.queries.length;
    // When the roster in the cold store was fetched, to check the write-back
    // below does not restamp it (#347).
    final pulledAt = snapshots.peek(Origin.wisa)!.fetchedAt;
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The apply is free (#345). An import rule never reaches WISA — it is a
    // client-side filter the connector applies once the rows are already in
    // hand — so the applier runs that filter over the snapshot it holds instead
    // of re-pulling klassen/leerlingen/personeel for every school to obtain the
    // same roster minus one class. That re-pull is what made a single "niet
    // importeren" apply take 20+ seconds on the real scholengroep, paid again
    // per record when several were ignored in one pass.
    expect(harness.wisaSyncs, pulls, reason: 'the apply must not re-pull WISA');
    expect(wire.queries.length, queries,
        reason: 'and nothing went out on the SOAP wire either');

    // The patch is not merely cheap, it is the same answer: the class is gone
    // from the view the operator is looking at, exactly as the re-pull left it.
    expect(find.byKey(const ValueKey('entry-group-3C')), findsNothing);

    // It landed on the settings document, on the wire shape #263's pull reads.
    final saved = await settings.store.load();
    expect(saved.wisaRules.single, isA<DontImportClass>());
    expect((saved.wisaRules.single as DontImportClass).className, '3C');
    expect(harness.controller.error, isNull);

    // …and so did the corrected roster (#347). Snapshot persistence lives
    // inside the syncer, which the patch above deliberately bypasses, so
    // without the end-of-pass write-back the stored copy would still carry
    // `3C` — and the next operator to launch the app seeds from that copy,
    // which `WisaSnapshot.fromJson` filters not at all, and is offered the very
    // rule this pass just wrote.
    final storedWisa =
        WisaSnapshot.fromJson(snapshots.peek(Origin.wisa)!.payload);
    expect(storedWisa.classGroups.map((g) => g.name), isNot(contains('3C')));
    // The write-back is not a fetch, so the stored freshness still belongs to
    // the pull (#345) — a cold seed must not read as newer than its data.
    expect(snapshots.peek(Origin.wisa)!.fetchedAt, pulledAt);

    // The snapshot in hand already reflects the rule — the apply filtered it in
    // place — so **Controleer op drift** must not now refuse over the document
    // that apply just wrote (#238).
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);

    // The operator reads the rule back off the *stored* document — what a
    // relaunch, and every other operator, gets.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);

    // …and that document still prunes the pull it is read for.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'WISA opgehaald: 1 leerling(en), 0 personeelsleden, 0 klassen.',
      ),
      findsWidgets,
    );

    // A rule applied in error is undone where every other rule is: the #273
    // editor, which now owns this one too.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');
    final remove = find.byKey(const ValueKey('settings-wisa-rule-0-remove'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect((await settings.store.load()).wisaRules, isEmpty);
  });

  testWidgets(
      'a persisted WISA import rule says who added it, when, and for whom '
      '(#285)', (WidgetTester tester) async {
    // The settings document is shared across operators on purpose (#276), and
    // that only works if a rule somebody else added last month is legible to
    // whoever opens the panel next. A `DontImportUserFromWisa` stores a bare
    // WISA code and a `DontImportClass` a bare class name, so a colleague's rule
    // used to appear as a string with no indication of who added it, when, or
    // which human it refers to — mechanically removable (#273), but with no way
    // to tell what you would be undoing. Worse, the people these rules are about
    // eventually disappear from WISA entirely, so resolving the code against the
    // current roster for display would give a blank exactly when the name is
    // needed most.
    //
    // Driven end-to-end because the payoff is a rendering: the three fields have
    // to survive an apply, a store round-trip, a **Herladen**, and the real
    // Instellingen layout — and the same columns have to serve a rule that
    // predates #285, which must read "onbekend" rather than blank.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
      // A rule from before #285: on the document, with no provenance at all.
      // It matches no staff member in the fixture, so it changes no pull.
      wisaRules: const <WisaImportRule>[DontImportUserFromWisa('OUD')],
    );
    final live = LiveSettings(stored);
    final settings = SettingsHarness(
      initial: stored,
      liveSettings: live,
      operatorName: 'operator@school.example',
    );
    final harness = ReconcileHarness(
      wisaTransport: RecordingWisaSoap(),
      liveSettings: live,
      settingsStore: settings.store,
      smartschool: ssSnap(
        groups: [
          ssGroup(
            'Leerlingen',
            code: 'SCHOOL',
            official: false,
            type: GroupType.group,
          ),
        ],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
      classTree: const SmartschoolClassTree(path: 'SCHOOL'),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The operator opts class 3C out of the import — the apply that earns a rule.
    await openKlasgroepen(tester);
    final entry = find.byKey(const ValueKey('entry-group-3C'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('alt-3C-DoNotImportFromWisa')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('entry-apply-3C')));
    await tester.tap(find.byKey(const ValueKey('entry-apply-3C')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Read it back off the *stored* document — what a relaunch, and every other
    // operator, gets.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-wisa');

    String cell(int index, String field) => tester
        .widget<Text>(find.byKey(ValueKey('settings-wisa-rule-$index-$field')))
        .data!;

    // The columns are named, with the timestamp getting one of its own rather
    // than hiding in a tooltip: with no free-text reason on the record, *when*
    // is what lets someone reconstruct the context later.
    expect(
      find.byKey(const ValueKey('settings-wisa-rules-header')),
      findsOneWidget,
    );
    expect(find.text('Toegevoegd op'), findsOneWidget);

    // Rule 1 is the one the apply just earned: the class it was about, the
    // instant, and the operator who decided it.
    expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);
    expect(cell(1, 'subject'), '3C');
    expect(cell(1, 'added-by'), 'operator@school.example');
    expect(cell(1, 'added-at'), contains('${DateTime.now().year}'));

    // Rule 0 predates #285 and says so, in all three columns. A blank would read
    // like nobody did it; "onbekend" says the record is missing.
    expect(cell(0, 'subject'), 'onbekend');
    expect(cell(0, 'added-at'), 'onbekend');
    expect(cell(0, 'added-by'), 'onbekend');

    // A rule typed by hand in #273's editor is stamped the same way. The name is
    // the one field this surface cannot know — it holds no WISA snapshot to
    // resolve a code against — so it records nothing rather than guessing.
    await addWisaRule(tester, 'dontImportClass', <String>['OKAN']);
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect(cell(2, 'added-by'), 'operator@school.example');
    expect(cell(2, 'added-at'), contains('${DateTime.now().year}'));
    expect(cell(2, 'subject'), 'onbekend');

    // …and all of it is on the shared document, not just on this screen.
    final saved = await settings.store.load();
    final earned = saved.provenanceOf(const DontImportClass('3C'))!;
    expect(earned.subject, '3C');
    expect(earned.addedBy, 'operator@school.example');
    expect(earned.addedAt, isNotNull);
    expect(saved.provenanceOf(const DontImportUserFromWisa('OUD')), isNull);
    expect(
      saved.provenanceOf(const DontImportClass('OKAN'))!.addedBy,
      'operator@school.example',
    );
  });

  testWidgets(
      'an Azure domain saved in Instellingen re-links the very next '
      'Synchroniseer, with no pull behind it (#264)',
      (WidgetTester tester) async {
    // The reported bug, driven the way the operator lives it. #259 gave the two
    // pulls their own settings fingerprints; the domain has no pull at all —
    // only `link()` reads it, through `ApplierSettings.studentConfig` — so with
    // WISA unchanged the smart sync returned before `_relink()` and the saved
    // domain was adopted by **Check for drift** alone, while Synchroniseer
    // reported "geen accountwijzigingen nodig" over it.
    //
    // Only this layer sees the whole thing: the save is made in Instellingen,
    // the two bootstraps share one LiveSettings exactly as `main()` wires them,
    // and what has to change is a UPN the operator reads off an Acties tile.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: const WisaConnection(server: 'wisa.example', port: '9000'),
      azure: const AzureConnection(domain: 'oud.example'),
      wisaSchools: const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 1, code: 'S1', name: 'Sint-Jan', ours: true),
      ],
    );
    final live = LiveSettings(stored);
    // A new intake: one WISA student with no Office 365 account yet, so the
    // pass proposes creating one — and names the UPN it would create.
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        schools: [wisaSchool(1)],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss')],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      liveSettings: live,
    );
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    /// Opens Acties and selects the student's row, which puts the proposed
    /// `userPrincipalName` in the details pane beside it.
    Future<void> openStudentRow() async {
      await tester.tap(find.text('Acties'));
      await tester.pumpAndSettle();
      await selectAccount(
        tester,
        harness.controller.pendingEntries
            .firstWhere((e) => e.family == 'student')
            .targetId,
      );
    }

    // A first Synchroniseer, on the domain as it stands.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await openStudentRow();
    expect(
      find.textContaining(
          'userPrincipalName: ∅ → jane.doe@student.oud.example'),
      findsOneWidget,
    );

    // Instellingen → Azure → the school moves to its new domain → Opslaan.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-azure');
    await tester.enterText(
      find.byKey(const ValueKey('settings-az-domain')),
      'nieuw.example',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect((await settings.store.load()).azure.domain, 'nieuw.example');

    // Back on Reconcile the screen names the save that is still waiting — and
    // names it as the *link*, because no pull is involved. Nothing is refused:
    // the domain is not a WISA pull input, so #238's drift gate stays open.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(
      find.byKey(const ValueKey('reconcile-settings-pending')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Instellingen voor de koppeling gewijzigd'),
      findsOneWidget,
    );

    // The operator presses **Synchroniseer**, the pass they reach for. WISA
    // comes back unchanged, which is exactly the case that used to end here.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    expect(find.textContaining('geen accountwijzigingen nodig'), findsNothing);
    expect(
      find.byKey(const ValueKey('reconcile-settings-pending')),
      findsNothing,
    );
    expect(
      find.textContaining('Koppelingsinstellingen gewijzigd — de koppeling '
          'wordt opnieuw berekend.'),
      findsOneWidget,
    );

    // …and the account the pass would create now carries the saved domain, with
    // no drift check, no hand-off and no relaunch anywhere in this test.
    await openStudentRow();
    expect(
      find.textContaining(
          'userPrincipalName: ∅ → jane.doe@student.nieuw.example'),
      findsOneWidget,
    );
    expect(
      find.textContaining('jane.doe@student.oud.example'),
      findsNothing,
    );
  });

  testWidgets(
      'a reconcile stack assembled with no settings holder still launches, '
      'syncs and drifts, and arms none of the settings gates (#274)',
      (WidgetTester tester) async {
    // `ReconcileController` has documented a null [liveSettings] since #238 —
    // "the harnesses that do not model settings at all; the gate is then never
    // armed and drift behaves exactly as before" — and #274 found that mode had
    // never once been entered: the constructor stamped its WISA fingerprint from
    // a helper that fell back to the very `late` field being assigned, so an
    // unwired controller threw `LateInitializationError` and the app never
    // reached its first frame.
    //
    // Only this layer proves the mode is real end to end: the app is launched
    // over a stack built without the holder, the operator saves in Instellingen
    // and comes back, and the two passes are pressed for real.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: const WisaConnection(server: 'wisa.example', port: '9000'),
      azure: const AzureConnection(domain: 'oud.example'),
      wisaSchools: const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 1, code: 'S1', name: 'Sint-Jan', ours: true),
      ],
    );
    final live = LiveSettings(stored);
    // The whole point: the pulls and the applier read `live`, the controller is
    // handed nothing. Constructing this harness is what used to throw.
    final harness = ReconcileHarness(modelsSettings: false, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    // The app is up and the screen the controller drives renders.
    expect(find.byType(AccountManagerApp), findsOneWidget);
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byType(ReconcileScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sync voltooid'), findsOneWidget);

    // Instellingen: the operator moves the school to a new Azure domain and
    // saves — a change that arms the link gate for a *wired* session (#264).
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    await openSettingsTab(tester, 'settings-tab-azure');
    await tester.enterText(
      find.byKey(const ValueKey('settings-az-domain')),
      'nieuw.example',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect((await settings.store.load()).azure.domain, 'nieuw.example');

    // Back on Synchronisatie nothing nags and nothing is refused: a controller
    // with no document to compare against holds no opinion about a save.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
    expect(
      find.byKey(const ValueKey('reconcile-settings-pending')),
      findsNothing,
    );

    // …and **Check for drift** is genuinely live, not merely un-nagged: the pass
    // runs and advances the two systems it re-reads.
    final driftAt = kFixtureDate.add(const Duration(hours: 3));
    harness.ssResult = ssSnap(fetchedAt: driftAt);
    harness.azResult = azSnap(fetchedAt: driftAt);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();

    final systems = harness.controller.syncState.systems;
    expect(systems[Origin.wisa]?.at, kFixtureDate);
    expect(systems[Origin.smartschool]?.at, driftAt);
    expect(systems[Origin.azure]?.at, driftAt);
  });

  testWidgets(
      'a Synchroniseer says in the Log panel which werkdatum it pulled, and '
      'names the virtuele werkdatum where a virtual school used it (#239)',
      (WidgetTester tester) async {
    // The operator's actual predicament: Acties is empty for the new intake and
    // nothing anywhere in the app names the school year the view describes, so
    // a pull that landed on last year's roster is indistinguishable from a class
    // that went missing. The pass now says what it asked WISA for, in the same
    // panel the skipped namesakes (#225), the skipped students (#230) and the
    // unmatched import rules (#241) report into — and this drives the real app
    // over the *production* WISA pull, so the line is checked against what
    // actually went out on the wire.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
        virtualWorkDate:
            WorkDateSetting(isNow: false, date: DateTime(2025, 10, 1)),
      ),
      wisaSchools: const <WisaSchoolProfile>[
        WisaSchoolProfile(
          schoolId: 99,
          code: 'V',
          name: 'Virtuele school',
          virtual: true,
        ),
      ],
    );
    final wire = RecordingWisaSoap(schools: const <(int, String, String)>[
      (1, 'School 1', 'S1'),
      (99, 'Virtuele school', 'V'),
    ]);
    final harness = ReconcileHarness(
      wisaTransport: wire,
      liveSettings: LiveSettings(stored),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Both dates really went out — the ordinary school on the werkdatum, the
    // virtual one on the virtuele werkdatum.
    expect(wire.werkdatums, <String>['01/09/2025', '01/10/2025']);
    // …and the Log panel names them, in the wire's own dd/MM/yyyy, beside the
    // school that used the second one.
    expect(find.byKey(const ValueKey('reconcile-log-panel')), findsOneWidget);
    expect(
      find.textContaining(
        'WISA ophalen met werkdatum 01/09/2025; virtuele werkdatum '
        '01/10/2025 voor V.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      "the Klasgroepen overview's freshness stamp names the werkdatum the "
      'shared view was pulled with, and holds it across a settings save (#247)',
      (WidgetTester tester) async {
    // #239 put the werkdatum in the Log panel, which is a *session* diagnostic:
    // it is gone when the app closes, and a passive operator reading the shared
    // view never saw it at all. The date is a per-pass input the whole
    // materialized view depends on, so it belongs beside "wie synchroniseerde,
    // wanneer" — and it has to name the pull, not the setting, because #238
    // made those two able to disagree. Driven over the *production* WISA pull
    // and the real Instellingen form, so the date on screen is the one that
    // really went on the wire.
    useTallWindow(tester);
    final stored = AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    );
    final live = LiveSettings(stored);
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    final settings = SettingsHarness(initial: stored, liveSettings: live);
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      settingsBootstrap: settings.bootstrap,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(wire.werkdatums, <String>['01/09/2025']);

    // The overview names the school year it describes, in the wire's own
    // dd/MM/yyyy, on the same line as the generation and the operator. Read on
    // Klasgroepen since #309 took the stamp off Acties.
    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Generatie 1 · ', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining('· werkdatum 01/09/2025', skipOffstage: false),
      findsOneWidget,
    );

    // The operator moves the werkdatum in Instellingen and saves. That is the
    // *next* pull's input; the view on Klasgroepen is still the one pulled as
    // of 01/09/2025 and must keep saying so.
    await tester.tap(find.text('Instellingen'));
    await tester.pumpAndSettle();
    final pick = find.byKey(const ValueKey('settings-workdate-pick'));
    await tester.ensureVisible(pick);
    await tester.pumpAndSettle();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('15'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('· werkdatum 01/09/2025', skipOffstage: false),
      findsOneWidget,
      reason: 'the stamp describes the pull, not the pending setting',
    );
    expect(
      find.textContaining('15/09/2025', skipOffstage: false),
      findsNothing,
    );

    // Only the Synchroniseer moves it — the same pass that moves the roster.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(wire.werkdatums, <String>['01/09/2025', '15/09/2025']);

    await tester.tap(find.text('Klasgroepen'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('· werkdatum 15/09/2025', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets(
      'an Azure re-pull whose stored delta token Graph refuses still '
      'finishes, on a full re-read that leaves a usable token behind, and '
      'reads as the clean pass it was (#213/#229)',
      (WidgetTester tester) async {
    // The real app over the *production* Azure pull — a real AzureConnector
    // behind the real azureSyncer — with Graph answering a resume from the
    // stored token the way it answered the operator:
    // `400 Request_UnsupportedQuery — DeltaLink older than 30 days is not
    // supported.` The exception used to propagate out of the connector into
    // ReconcileController._fail, so the whole pass produced no linked state at
    // all; and because a failed pass deliberately leaves the stored snapshot
    // alone, every later pass re-sent the same dead token. Nothing short of
    // wiping the stored Azure document got the operator out of it.
    useTallWindow(tester);
    final azureWire = StaleDeltaTokenGraph();
    final harness = ReconcileHarness(
      azureTransport: azureWire,
      // Last night's snapshot, with the token that has since gone stale.
      azureInitial: azSnap(
        fetchedAt: DateTime.now().subtract(const Duration(hours: 15)),
        deltaToken: 'DEADTOKEN',
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // Yesterday's session: WISA + Smartschool pull, the seeded Azure snapshot
    // is reused untouched (its token is not spent yet).
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);

    // Today: the operator flips a school **beheerd** in Instellingen, so the
    // next Synchroniseer re-pulls Azure (#259) — incrementally, from the token
    // the session holds. That is the pass a refusal can still happen on:
    // **Controleer op drift** drops the stored token by design since #316, so
    // it never sends one to be refused.
    harness.markSchoolManaged(1);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // The pass finished instead of dying: no inline failure, not busy, and the
    // overview the operator came for is on screen.
    expect(harness.controller.error, isNull);
    expect(harness.controller.busy, isFalse);
    expect(find.text('Overzicht'), findsOneWidget);

    // The dead token was tried exactly once and then given up on, and the
    // fallback was the $filter-scoped bulk read (PAIN-2 holds while recovering).
    expect(azureWire.resumeTokens, <String>['DEADTOKEN']);
    expect(azureWire.bulkReads, 1);
    expect(
      azureWire.requests
          .lastWhere((r) => r.url.path.endsWith('/users'))
          .url
          .queryParameters[r'$filter'],
      isNotNull,
    );

    // The snapshot is complete (not the stale one held over) and carries a
    // fresh token…
    expect(harness.app.azure.snapshot?.users.map((u) => u.upn),
        <String>['jane.doe@student.school.example']);
    expect(harness.app.azure.snapshot?.deltaToken, 'FRESH-DELTA-TOKEN');

    // …and the operator is told why the full read happened, with the rejected
    // token's age — the diagnostic that says whether Graph expired a genuinely
    // old token or the app had stopped advancing it.
    // …in Dutch since #266, the age in Dutch units with it.
    expect(find.textContaining('Graph weigerde het bewaarde deltatoken'),
        findsOneWidget);
    expect(find.textContaining('bewaard 15u'), findsOneWidget);
    expect(
      find.textContaining('Graph rejected the stored delta token'),
      findsNothing,
    );

    // …and that is *all* the operator sees about it (#229). The recovery
    // worked, so nothing in the panel is red: the transport used to log the raw
    // Graph failure with addError right below the explanation, which made a
    // pass that fully recovered read as a broken one.
    expect(
      harness.log.entries.where((e) => e.isError).map((e) => e.message),
      isEmpty,
    );
    // Nor does any line — at any severity, on screen or in the buffer — carry
    // the resume token itself, which the operator pastes into issues.
    expect(
      harness.log.entries.map((e) => e.message),
      everyElement(isNot(contains('DEADTOKEN'))),
    );
    expect(find.textContaining('DEADTOKEN'), findsNothing);
    // The transport line survives as an ordinary detail rather than being
    // dropped, so what Graph actually answered is still there to read.
    expect(
      harness.log.entries.map((e) => e.message),
      contains(allOf(
        contains('users/delta'),
        // The Graph body verbatim, with the client's own Dutch clause on it
        // (#266) rather than the English "(handled — …)" it used to append.
        contains('DeltaLink older than 30 days'),
        contains('(afgehandeld — de synchronisatie herstelt hiervan)'),
      )),
    );

    // A second such pass resumes from that fresh token: the recovery restored
    // incremental syncing rather than condemning the app to full reads.
    harness.markSchoolManaged(2);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, <String>['DEADTOKEN', 'FRESH-DELTA-TOKEN']);
    expect(azureWire.bulkReads, 1, reason: 'no second full read');
    expect(harness.controller.error, isNull);
  });

  testWidgets(
      "a transferred student's existing Office 365 account is found by "
      'employeeId and repaired, never duplicated (#224)',
      (WidgetTester tester) async {
    // The real app over the *production* Azure pull — a real AzureConnector
    // behind the real azureSyncer — with Graph answering the way the tenant
    // answered for Ambre Kalenga Alfio: the school-scoped `$filter` finds
    // nothing (no `companyName`, another school's `department`), so before the
    // fix the account was simply absent from the snapshot and Acties →
    // Leerlingen offered "Maak een nieuw Office 365 account". Applying that
    // created a *second* account, silently: `createPrincipalName` resolves the
    // UPN collision by suffixing, so the create succeeds.
    //
    // Only this layer sees the whole thing: the back-fill needs the WISA
    // snapshot the same pass pulled, the linker needs the row it produces, and
    // the repair the operator should see instead is a different action family
    // than the one that was offered.
    useTallWindow(tester);
    final azureWire = TransferredAccountGraph();
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        schools: [wisaSchool(1)],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss')],
        accounts: [ssAccount(accountId: 'W7')],
        memberships: [member('jane', '3C_ss')],
      ),
      azureTransport: azureWire,
      ourSchoolIds: const {1},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The bounded pull stayed bounded (PAIN-2): one `$filter` bulk read, plus
    // one targeted lookup for the single id it could not account for.
    expect(azureWire.bulkReads, 1);
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('W7')"]);

    // The account the school filter cannot see is in the snapshot, and the
    // linker joined it to the WISA student by employeeId alone.
    expect(harness.app.azure.snapshot?.users.map((u) => u.id),
        <String>['az-transferred']);
    final linked = harness.controller.linked!.snapshot.accounts.single;
    expect(linked.wisa, isNotNull);
    expect(linked.azure?.id, 'az-transferred');

    // Nothing anywhere in the pass proposes creating an account.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind),
      isNot(contains('AddStudentToAzure')),
    );

    // And that is what the operator sees: browse Acties → Leerlingen the way
    // they did when they reported this.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await selectAccount(
      tester,
      harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'student')
          .targetId,
    );

    expect(find.text('Maak een nieuw Office 365 account'), findsNothing,
        reason: 'the account already exists — creating one duplicates it');
    // The repair that adopts it. Stamping our `companyName` is what makes the
    // adoption stick: without it the account stays invisible to the next
    // sync's `$filter`, and the whole problem recurs every pass.
    expect(find.text('Wijzig de school in Azure'), findsOneWidget);
  });

  testWidgets(
      "a moved staff member's existing Office 365 account is found by "
      'employeeId, so Acties → Personeel never offers a duplicate (#231)',
      (WidgetTester tester) async {
    // The staff half of #224, over the *production* Azure pull — a real
    // AzureConnector behind the real azureSyncer. Anna Smit moved in from a
    // sibling group school, so her account carries our `employeeId` (her WISA
    // id, never her staff `code`) but a `department` still naming the school she
    // came from. Neither leg of the connector's `$filter` matches it, so before
    // the fix she was simply absent from the Azure snapshot and Acties →
    // Personeel offered "Maak een nieuw Office 365 account" — which on apply
    // created a second account, silently, because `createPrincipalName`
    // resolves the UPN collision by suffixing.
    //
    // Only this layer sees the whole thing: the back-fill needs the *staff* half
    // of the WISA snapshot the same pass pulled (`managedStaffEmployeeIds`), the
    // linker needs the row it produces, and what the operator should be offered
    // instead is a different action entirely.
    useTallWindow(tester);
    final azureWire = TransferredAccountGraph(
      // wisaStaff()'s default wisaId — the staff Azure bridge is
      // `wisaId ≡ employeeId`, so the staff code 'SMIT' is *not* the key.
      employeeId: '42',
      upn: 'smit.anna@other.example',
      displayName: 'Smit Anna',
      department: 'OTHER - Wiskunde',
    );
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azureTransport: azureWire,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The bounded pull stayed bounded (PAIN-2): one `$filter` bulk read, plus
    // one targeted lookup for the single staff id it could not account for.
    expect(azureWire.bulkReads, 1);
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('42')"]);

    // The account the school filter cannot see is in the snapshot, and the
    // linker joined it to the WISA staff record by employeeId alone.
    expect(harness.app.azure.snapshot?.users.map((u) => u.id),
        <String>['az-transferred']);
    final linked = harness.controller.linked!.snapshot.staff.single;
    expect(linked.wisa, isNotNull);
    expect(linked.azure?.id, 'az-transferred');

    // Nothing anywhere in the pass proposes creating an Azure account.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind),
      isNot(contains('AddStaffToAzure')),
    );

    // And that is what the operator sees: browse Acties → Personeel the way
    // they did when they reported this.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    await selectAccount(
      tester,
      harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'staff')
          .targetId,
    );

    expect(find.text('Maak een nieuw Office 365 account'), findsNothing,
        reason: 'the account already exists — creating one duplicates it');
    // The record is now WISA + Azure, so the only thing left to build is the
    // Smartschool side — the proposal the adoption unlocks, reading as the
    // create side of the #248 choice it shares with the WISA opt-out.
    expect(find.text('Kies één oplossing:'), findsOneWidget);
    expect(find.text('Maak een nieuw Smartschool account'), findsOneWidget);
  });

  testWidgets(
      "an admin co-account does not take the staff member's Office 365 "
      'account away from her (#354)', (WidgetTester tester) async {
    // The pair INV-23 keeps, in its staff shape: Anna Smit has an admin account
    // next to her normal one, and it carries her mail. Both records claim that
    // mail, so the Azure user's UPN points at the pair rather than at one
    // record, and the linker took the first with a free slot — snapshot order,
    // with the admin account first. Because a mail target was found, the strong
    // `employeeId ≡ wisaId` bridge never ran.
    //
    // Only the whole app shows what that costs: her real record then looks
    // Azure-less, so Acties → Personeel offers to *create* the Office 365
    // account she already has — the same silent duplicate #231 is about,
    // reached from an entirely ordinary pair of accounts.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          // The admin account: her mail, no WISA counterpart, and first in the
          // snapshot. Named apart so the two cards are distinguishable.
          ssStaffAccount(
            uid: 'anna.smit-beheer',
            accountId: 'SMITADM',
            surname: 'Smit-beheer',
          ),
          ssStaffAccount(),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: [azStaffUser()]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The Azure user sits on the WISA-anchored record — the one whose
    // `accountId` is her staff code and whose `wisaId` is the Azure
    // `employeeId` — not on the admin account that merely shares her mail.
    final staff = harness.controller.linked!.snapshot.staff;
    final anna = staff.singleWhere((s) => s.wisa != null);
    expect(anna.smartschool?.uid, 'anna.smit');
    expect(anna.azure?.id, 'az-staff');
    expect(
      staff.singleWhere((s) => s.wisa == null).azure,
      isNull,
      reason: 'the admin co-account has no Azure account of its own',
    );
    // Both accounts are still kept and the mail collision is still reported —
    // INV-13/INV-23 are untouched; only the attachment moved.
    expect(staff.map((s) => s.smartschool?.uid),
        <String?>['anna.smit-beheer', 'anna.smit']);
    expect(
      find.byKey(const ValueKey('dup-warning-anna.smit@school.example')),
      findsOneWidget,
    );

    // Nowhere in the pass is an Azure account proposed for her.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind),
      isNot(contains('AddStaffToAzure')),
    );

    // And that is what the operator reads on Acties → Personeel: her three
    // systems agree, so she has no card there at all. Before the fix she had
    // one, offering the Office 365 account she was holding all along.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('account-row-${anna.id.value}')), findsNothing,
        reason: 'nothing is pending for her — all three systems agree');
    expect(find.text('Maak een nieuw Office 365 account'), findsNothing,
        reason: 'she already has one — creating another duplicates it');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      "a moved staff member's Azure department is left exactly as the other "
      'software wrote it (#237)', (WidgetTester tester) async {
    // The counterpart of the #231 test above, one pass later: Anna Smit's
    // record is now complete (WISA + Smartschool + Azure), so the modify branch
    // is live, and her `department` still reads `GBS,SSM` — the comma-separated
    // list of the schools she is active at, maintained by other software and
    // read-only from here. Our prefix being second in it is the ordinary state,
    // not a defect.
    //
    // #233 briefly shipped a repair for this. It fired on any list our prefix
    // did not lead, and its rewrite split on a ` - ` a comma list has none of,
    // so one apply turned `SSM,GBS` into `GBS` and deleted the sibling school's
    // claim. This is the layer that proves the operator is no longer offered
    // that: the whole pass must raise nothing and write nothing.
    useTallWindow(tester);
    final azureWire = TransferredAccountGraph(
      employeeId: '42',
      upn: 'smit.anna@other.example',
      displayName: 'Smit Anna',
      // The harness school is `GBS`, so this is the destructive case exactly:
      // we are on the list, just not first.
      department: 'SSM,GBS',
    );
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        // Her Smartschool mail already matches the adopted UPN, so nothing else
        // about this staff member is out of step either.
        accounts: [ssStaffAccount(mail: 'smit.anna@other.example')],
        memberships: const [],
      ),
      azureTransport: azureWire,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // She is in the snapshot — found by the #231 back-fill, since the
    // school-scoped `$filter` leg is `startswith(department, …)` and her list
    // does not lead with us.
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('42')"]);
    final linked = harness.controller.linked!.snapshot.staff.single;
    expect(linked.wisa, isNotNull);
    expect(linked.smartschool, isNotNull);
    expect(linked.azure?.id, 'az-transferred');
    expect(harness.app.azure.snapshot!.users.single.department, 'SSM,GBS');

    // Nothing anywhere in the pass proposes touching the school field — this
    // staff member is fully synced, so she raises no to-do at all.
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind),
      isNot(contains('ModifyStaffAzureSchool')),
    );
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'staff'),
      isEmpty,
    );

    // And the operator sees it: Acties has no staff work to show.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.text('Wijzig de school in Azure'), findsNothing);

    // No write reached Azure, so the list the other software maintains is
    // exactly as it was.
    expect(
      harness.graph.requests.where((r) => r.method == 'PATCH'),
      isEmpty,
      reason: 'department belongs to the software that maintains the list',
    );
  });

  testWidgets(
      'an Office 365 rename reaches the app even when our school is second on '
      "a staff member's department list (#268)", (WidgetTester tester) async {
    // The cost of the read being narrower than the domain rule, one pass after
    // #237: Anna Smit's `department` reads `SSM,GBS`, so the school-scoped
    // `$filter` cannot see her (`startswith`) and Graph has no `contains` to
    // widen it with. That leaves the delta walk — which filters in Dart, and so
    // is under no such limit — as the only leg that can carry a change to her
    // account into the app.
    //
    // It applied the server-side narrowing anyway. So when an administrator
    // renamed her Office 365 sign-in, the delta row was dropped, her *previous*
    // row survived untouched in the snapshot, and the app went on believing
    // Smartschool's copy of the address was still right. Nothing looked missing
    // — that is what made it invisible.
    //
    // Only this layer sees it: it needs the stored token and the previous
    // snapshot to make the pass incremental, the linker to join her by
    // `employeeId` once the UPN stops matching, and the dispatch to turn the
    // drift into the to-do the operator should have been given.
    useTallWindow(tester);
    final azureWire = SharedDepartmentStaffGraph(
      // Renamed in Azure since the stored token; everything else unchanged.
      changed: azStaffUser(upn: 'anna.smit2@school.example'),
    );
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        // Smartschool still holds the address that was correct last pass.
        accounts: [ssStaffAccount()],
        memberships: const [],
      ),
      azureTransport: azureWire,
      // Last night's snapshot: her account as it stood, and the token this pass
      // resumes from.
      azureInitial: azSnap(deltaToken: 'AZ-TOKEN', users: [azStaffUser()]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // Yesterday's session: the seeded Azure snapshot is reused untouched, its
    // token unspent.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);

    // Today: the operator flips a school **beheerd** in Instellingen, so the
    // next Synchroniseer re-pulls Azure (#259) — incrementally, from the stored
    // token. That is the pass this bug lives on: **Controleer op drift** re-reads
    // in full since #316, and a full read is not what the delta walk has to
    // survive.
    harness.markSchoolManaged(1);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pass really was the incremental one, and the delta walk really was
    // the only leg that could have delivered her: no bulk read ran, and the
    // `employeeId` back-fill asked about nobody (she was already accounted for
    // by the previous snapshot, which is exactly why it cannot save this case).
    expect(azureWire.resumeTokens, <String>['AZ-TOKEN']);
    expect(azureWire.bulkReads, 0);
    expect(azureWire.employeeIdLookups, isEmpty);

    // The rename landed. Before the fix this still read the old address.
    expect(harness.app.azure.snapshot!.users.single.upn,
        'anna.smit2@school.example');

    // And the operator is told what it means: Smartschool's copy is now stale.
    final linked = harness.controller.linked!.snapshot.staff.single;
    expect(linked.azure?.id, 'az-staff',
        reason: 'joined by employeeId once the UPN stopped matching');
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    await selectAccount(
      tester,
      harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'staff')
          .targetId,
    );
    expect(find.text('Wijzig het e-mailadres in Smartschool'), findsOneWidget);
  });

  testWidgets(
      'an edit made by hand in Office 365 shows up on the very next incremental '
      'Azure pull, with the rest of the account intact (#288)',
      (WidgetTester tester) async {
    // The report: an administrator renames someone in the Entra portal, the
    // operator presses Controleer op drift, and nothing happens — the log says
    // `0 gewijzigd` and the action list is unchanged. Only restarting the app
    // (which re-seeds from the shared cold store) ever surfaced the edit, and by
    // then the delta walk that dropped it had already advanced the token, so the
    // change was never offered again.
    //
    // The cause is one query option: the request that *mints* the token carried
    // no `$select`, so every resumed row came back as `{id, <what changed>}`.
    // Read as a whole user such a row names no school, and the connector's
    // client-side prefix test dropped it.
    //
    // (The report came from **Controleer op drift**, which was the only pass
    // that re-read Azure at the time. Since #316 that button drops the token and
    // re-reads in full, so the incremental pass this bug lives on is reached the
    // way the sync below reaches it — the walk itself is unchanged.)
    //
    // Only this layer sees the whole thing: it needs the stored token and the
    // seeded snapshot to make the pass incremental, the merge to keep the record
    // whole, the linker to join the merged row, and the dispatch to turn the
    // drift into the to-do the operator should have been handed.
    useTallWindow(tester);
    final azureWire = HandEditedUserGraph(
      // Exactly what Graph sends for a display-name edit: the object id and the
      // properties that changed. No UPN, no employeeId, no companyName.
      row: <String, dynamic>{
        'id': 'az1',
        'displayName': 'Janneke Doe',
        'givenName': 'Janneke',
      },
    );
    final harness = ReconcileHarness(
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
      azureTransport: azureWire,
      // Last night's snapshot: her account exactly in step with WISA, and the
      // token this pass resumes from.
      azureInitial: azSnap(
        deltaToken: 'AZ-TOKEN',
        users: [azUser(displayName: 'Jane Doe')],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // Yesterday's session: the seeded Azure snapshot is reused untouched, its
    // token unspent, and the student has nothing to do.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
      reason: 'the account starts in step with WISA, so the drift below is '
          'entirely the hand-edit',
    );

    // Today: the operator flips a school **beheerd** in Instellingen, so the
    // next Synchroniseer re-pulls Azure (#259) — incrementally, from the stored
    // token. Since #316 that is the pass which resumes a delta at all;
    // **Controleer op drift** re-reads in full, and a sparse resumed row is
    // precisely what a full read never has to cope with.
    harness.markSchoolManaged(1);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pass really was the incremental one, so the sparse resumed row really
    // was the only thing that could have carried the edit: no bulk read ran and
    // the `employeeId` back-fill asked about nobody.
    expect(azureWire.resumeTokens, <String>['AZ-TOKEN']);
    expect(azureWire.bulkReads, 0);
    expect(azureWire.employeeIdLookups, isEmpty);

    // The edit landed — and nothing else moved. Before the fix this row was
    // dropped whole; upserted raw it would instead have blanked the UPN and the
    // `employeeId → wisaId` bridge the linker joins on.
    expect(
      harness.app.azure.snapshot!.users.single,
      azUser(displayName: 'Janneke Doe', givenName: 'Janneke'),
    );

    // And the operator is handed the one to-do it means: put the WISA name back
    // on the Office 365 account. Exactly one — a blanked record would have
    // raised "Wijzig de school in Azure" beside it.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final entry = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
    );
    await selectAccount(tester, entry.targetId);
    expect(find.text('Wijzig de naam in Azure'), findsOneWidget);
  });

  testWidgets(
      'an ordinary Synchroniseer spends the stored delta token once the Azure '
      'copy has aged, so the incremental pull has a caller again (#320)',
      (WidgetTester tester) async {
    // #316 made **Controleer op drift** a full re-read — right for drift, and it
    // left `/users/delta` with almost no caller. An ordinary Synchroniseer
    // skipped Azure whenever a snapshot was in hand, so the only route left into
    // the delta walk was a saved Azure pull input ("the operator flipped a
    // school beheerd"). Every drift pass minted a resume token that nothing ever
    // spent, and the machinery PAIN-2 exists for — the walk, the sparse-row
    // merge (#288), the rejected-token recovery (#213) — ran in production only
    // in that one corner.
    //
    // Only the end-to-end run proves the route is real: the aged seed has to
    // reach the SystemState through bootstrap, the controller has to decide from
    // its age, the production `azureSyncer` has to hand the *stored token* to a
    // real AzureConnector, and what the walk brings back has to survive the link
    // and land in Acties as a to-do the operator can read.
    useTallWindow(tester);
    final azureWire = HandEditedUserGraph(
      // The hand-edit Graph reports as a sparse row: object id plus what
      // changed. Only a resumed walk can carry it — the bulk read and the
      // `employeeId` back-fill both answer empty on this wire.
      row: <String, dynamic>{
        'id': 'az1',
        'displayName': 'Janneke Doe',
        'givenName': 'Janneke',
      },
    );
    final harness = ReconcileHarness(
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
      azureTransport: azureWire,
      // The cold seed this session opens on: last night's Azure, her account
      // still in step with WISA, the resume token unspent — and old enough that
      // the next Synchroniseer refreshes it.
      azureInitial: azSnap(
        fetchedAt: kFixtureDate.subtract(const Duration(hours: 12)),
        deltaToken: 'AZ-TOKEN',
        users: [azUser(displayName: 'Jane Doe')],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // No settings change, no drift button — the button the operator presses all
    // day.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The stored token was spent, and the pass really was the incremental one:
    // no `$filter`-scoped bulk read ran.
    expect(azureWire.resumeTokens, <String>['AZ-TOKEN']);
    expect(azureWire.bulkReads, 0);

    // …and the pass explains itself in the panel the operator reads, so a delta
    // refresh and the drift button's full re-read stay distinguishable after the
    // fact (#316's other half).
    expect(find.textContaining('Azure AD wordt incrementeel bijgewerkt.'),
        findsWidgets);
    expect(find.textContaining('volledig opnieuw gelezen'), findsNothing);

    // What the walk carried is in the snapshot, merged onto the record it
    // updates rather than replacing it.
    expect(
      harness.app.azure.snapshot!.users.single,
      azUser(displayName: 'Janneke Doe', givenName: 'Janneke'),
    );

    // And it reached the operator as the one to-do it means: put the WISA name
    // back on the Office 365 account.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final aged = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      aged.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
    );
    await selectAccount(tester, aged.targetId);
    expect(find.text('Wijzig de naam in Azure'), findsOneWidget);
  });

  testWidgets(
      'Controleer op drift re-reads Azure in full, so a stale field no delta '
      'could ever report is repaired and the phantom action goes away (#316)',
      (WidgetTester tester) async {
    // The report (#315): Acties offers `Office 365 · Wijzig de school in Azure`
    // for a student whose Azure account already carries the school — and the
    // proposal survives **Controleer op drift**, pass after pass, because the
    // pass ran the ordinary incremental pull. `/users/delta` reports what
    // changed *since our token*, which is precisely not "what does Azure hold
    // right now": an edit older than the token, or one an earlier walk dropped,
    // is unreachable forever. The only things that ever forced a full read were
    // accidents (a token Graph refused, #213; a changed prefix, #246), neither
    // of which an operator can ask for.
    //
    // Only this layer sees it: it needs the seeded snapshot and its token to
    // make the pass incremental, the production Azure pull to decide which leg
    // to take, the linker to rebuild the record, and the action engine to stop
    // offering the write — which is the thing the operator was actually looking
    // at.
    useTallWindow(tester);
    // Graph holds her with our school on it; the app's stored copy says another.
    // Everything else about the account is in step, so the school is the only
    // thing this pass can be about.
    final azureWire = DriftedUserGraph(user: azUser(displayName: 'Jane Doe'));
    final harness = ReconcileHarness(
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
      azureTransport: azureWire,
      // Last night's snapshot, holding the school she was at *before* the
      // transfer — and the token whose walks all missed the correction.
      azureInitial: azSnap(
        deltaToken: 'AZ-TOKEN',
        users: [azUser(displayName: 'Jane Doe', companyName: 'SBE')],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // The seeded Azure snapshot is reused untouched, its token unspent — so the
    // linked view is built on the stale copy, exactly as the operator's was.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);
    expect(azureWire.bulkReads, 0);

    // And there is the phantom, on screen, the way it was reported.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final stale = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      stale.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de school in Azure'],
    );
    await selectAccount(tester, stale.targetId);
    expect(find.text('Wijzig de school in Azure'), findsOneWidget);

    // So the operator does the one thing the screen offers for exactly this:
    // Controleer op drift.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pass asked Azure what it holds *now*: the stored token was not sent,
    // the `$filter`-scoped bulk read ran, and a fresh token was left behind. The
    // delta this wire would have answered reports nothing at all, so before
    // #316 every one of these passes was a no-op.
    expect(azureWire.resumeTokens, isEmpty);
    expect(azureWire.bulkReads, 1);
    expect(harness.app.azure.snapshot?.deltaToken, 'AZ-NEXT');
    expect(harness.app.azure.snapshot?.users.single.companyName, 'GBS');

    // Which is the whole point: the action the operator was staring at is gone,
    // and no PATCH that would have changed nothing is offered for bulk apply.
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
    );
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Wijzig de school in Azure'), findsNothing);

    // And the log says which kind of pass it was, so the two are still
    // distinguishable afterwards — the diagnostic #315 went without.
    expect(
      harness.log.entries.map((e) => e.message),
      contains('Azure AD volledig opnieuw gelezen — 1 account(s).'),
    );
  });

  testWidgets(
      'a delta row that hands an account to another school stops the app '
      'proposing writes against it (#317)', (WidgetTester tester) async {
    // The report: Graph says an account moved out of our school and the snapshot
    // goes on insisting it is ours. `_walkDelta` merges the sparse row onto the
    // record we hold and then keeps it only if the merged record still passes
    // the school test — and when it does not, the row was simply thrown away.
    // Applied as an upsert, "thrown away" means *nothing happens*: our own copy
    // survives with the `companyName` it had, and every later pass reaches the
    // same verdict about the same row, so the contradiction never resolves.
    //
    // Two students in one pass, because the fix has two legs that have to agree:
    //
    // - **Jane** is gone from the group — no WISA anywhere, no Smartschool — and
    //   another school has claimed her Office 365 account. While our stale copy
    //   still carries `GBS`, `RemoveStudentFromAzure` evaluates true, so Acties
    //   offers a **delete** against an account SSM now owns. That is the danger
    //   the snapshot hygiene is really about.
    // - **Tom** is still ours in WISA; the same claim landed on his account by
    //   mistake. He leaves on the delta leg and comes straight back on the
    //   `employeeId` back-fill (#224) — with the record as Graph holds it, so
    //   what the operator is offered is putting *our* school back.
    //
    // Only this layer sees it: it needs the seeded snapshot and its token to make
    // the pass incremental, the production Azure pull to run both legs in one
    // pass, the linker to rebuild both records, and the action engine to turn the
    // result into what Acties shows.
    useTallWindow(tester);
    final azureWire = SchoolMovedUserGraph(
      // Exactly what Graph sends when other software rewrites one property.
      rows: <Map<String, dynamic>>[
        <String, dynamic>{'id': 'az1', 'companyName': 'SSM'},
        <String, dynamic>{'id': 'az2', 'companyName': 'SSM'},
      ],
      // Tom's account as Graph holds it — the answer to the targeted lookup the
      // pass makes for the id WISA still places here.
      backfill: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'az2',
          'userPrincipalName': 'tom.peeters@student.school.example',
          'employeeId': '2',
          'displayName': 'Tom Peeters',
          'givenName': 'Tom',
          'surname': 'Peeters',
          'companyName': 'SSM',
          // Graph answers the whole `$select`, job title included (#358) — so
          // the row that lands is the account SSM holds, wrong school and
          // right kind of pupil, and this pass is about the school alone.
          'jobTitle': 'LeerlingSec',
          'accountEnabled': true,
        },
      ],
    );
    final tomAzure = azUser(
      id: 'az2',
      upn: 'tom.peeters@student.school.example',
      employeeId: '2',
      displayName: 'Tom Peeters',
      givenName: 'Tom',
      surname: 'Peeters',
    );
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        // Jane is not here at all; Tom is, in 3C.
        students: [
          wisaStudent(
            wisaId: '2',
            classGroup: '3C',
            firstName: 'Tom',
            name: 'Peeters',
          ),
        ],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
        accounts: [
          ssAccount(
            uid: 'tom',
            accountId: '2',
            mail: 'tom.peeters@student.school.example',
            givenName: 'Tom',
            surname: 'Peeters',
          ),
        ],
        memberships: [member('tom', '3C_ss')],
      ),
      azureTransport: azureWire,
      // Last night's snapshot: both accounts still stamped with our school, and
      // the token this pass resumes from.
      azureInitial: azSnap(
        deltaToken: 'AZ-TOKEN',
        users: [azUser(displayName: 'Jane Doe'), tomAzure],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // Yesterday's session: the seeded Azure snapshot is reused untouched, its
    // token unspent — so the linked view is built on the stale copies.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);

    // And there is the dangerous one, on screen: a delete proposed for an
    // account we no longer own. Tom has nothing to do — he is in step.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final phantom = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      phantom.choices.map((c) => c.selected.changes.summary),
      <String>['Verwijder Azure account'],
    );
    await selectAccount(tester, phantom.targetId);
    expect(find.text('Verwijder Azure account'), findsOneWidget);

    // Today: the operator flips a school **beheerd** in Instellingen, so the next
    // Synchroniseer re-pulls Azure (#259) — incrementally, from the stored token.
    // Since #316 that is the pass which resumes a delta at all; Controleer op
    // drift re-reads in full, and a full read never sees this row.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    harness.markSchoolManaged(1);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pass really was the incremental one, so the delta walk really was the
    // only thing that could have carried the news — and the back-fill asked
    // about exactly the id WISA still places here, never about Jane.
    expect(azureWire.resumeTokens, <String>['AZ-TOKEN']);
    expect(azureWire.bulkReads, 0);
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('2')"]);

    // Jane is out of the snapshot; Tom is back in it, as Graph holds him.
    expect(harness.app.azure.snapshot!.users.single,
        tomAzure.copyWith(companyName: 'SSM'));

    // Which is what the operator sees. The delete against SSM's account is gone
    // — and it is gone because the record is, not because some other rule
    // happened to mask it.
    expect(
        harness.controller.linked!.snapshot.accounts
            .where((a) => a.azure?.id == 'az1'),
        isEmpty);
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Verwijder Azure account'), findsNothing);

    // And Tom's account, which Graph really did move, is now offered the repair
    // it needs instead of being silently believed to be fine.
    final repair = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      repair.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de school in Azure'],
    );
    await selectAccount(tester, repair.targetId);
    expect(find.text('Wijzig de school in Azure'), findsOneWidget);

    // The Log panel counts what happened, so a pass that handed accounts over is
    // distinguishable from an uneventful one afterwards.
    expect(
      harness.log.entries.map((e) => e.message),
      contains('Azure: delta voor "GBS" — 0 gewijzigd, 0 verwijderd, '
          '2 niet langer van onze school.'),
    );
  });

  testWidgets(
      'an ordinary Synchroniseer repairs an adopted transfer record, so the '
      'phantom goes away without Controleer op drift (#322)',
      (WidgetTester tester) async {
    // The residue of #315, found while driving it. Jane transferred in from a
    // sibling group school, so her Office 365 account carries *their* prefix and
    // no prefix-scoped read of ours has ever returned it: the app holds her only
    // because an earlier pass adopted her by `employeeId` (#224). Since then
    // somebody put our school on the account in the Entra portal — before the
    // token this session resumes from was minted — so `/users/delta` has nothing
    // to say about her, on this pass and on every later one.
    //
    // The back-fill was the one leg that could still repair her, and it asked
    // only about ids *no user in the snapshot carried* — so the record it had
    // adopted marked its own id accounted for and it never asked again. A full
    // read has no such blind spot (the record is simply absent from the bulk
    // result, so it is re-read every pass), which is why **Controleer op drift**
    // fixed it since #316 and the button the operator presses all day did not.
    //
    // Only this layer shows what that cost: the seeded snapshot and its token
    // make the pass incremental, the production Azure pull decides which legs
    // run, the linker rebuilds the record, and the action engine is what was
    // offering `Wijzig de school in Azure` for a PATCH that would change nothing.
    useTallWindow(tester);
    final azureWire = SchoolMovedUserGraph(
      // The resumed walk reports nothing at all — the correction is older than
      // our token. This is the whole shape of the bug.
      rows: const <Map<String, dynamic>>[],
      // Her account as Graph holds it *now*, the answer to the targeted lookup.
      backfill: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'az1',
          'userPrincipalName': 'jane.doe@student.school.example',
          'employeeId': '1',
          'displayName': 'Jane Doe',
          'companyName': 'GBS',
          // The `$select` reads it since #358, so the back-fill's row carries
          // it — and it is already right, leaving the school the one thing this
          // pass has to repair.
          'jobTitle': 'LeerlingSec',
          'accountEnabled': true,
        },
      ],
    );
    final harness = ReconcileHarness(
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
      azureTransport: azureWire,
      // The adopted copy, as the pass that first took her in left it: the school
      // she came from, and the token whose walks all missed the correction.
      azureInitial: azSnap(
        deltaToken: 'AZ-TOKEN',
        users: [azUser(displayName: 'Jane Doe', companyName: 'SBE')],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // The seeded Azure snapshot is reused untouched, its token unspent — so the
    // linked view is built on the adopted copy, exactly as the operator's was.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);
    expect(azureWire.bulkReads, 0);

    // And there is the phantom, on screen, the way it was reported.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final stale = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      stale.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de school in Azure'],
    );
    await selectAccount(tester, stale.targetId);
    expect(find.text('Wijzig de school in Azure'), findsOneWidget);

    // Now the ordinary pass. A saved Azure pull input moves (#259) — the
    // operator flips a school beheerd — so Synchroniseer re-pulls Azure
    // **incrementally**, which is the leg that used to be unable to help.
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    harness.markSchoolManaged(1);
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-sync')));
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // No full read anywhere: the stored token was spent and the `$filter` bulk
    // read never ran, so the repair provably came from the back-fill asking
    // about an id the snapshot already held.
    expect(azureWire.resumeTokens, <String>['AZ-TOKEN']);
    expect(azureWire.bulkReads, 0);
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('1')"]);

    // …and what it brought back is Graph's record, not the one we adopted.
    expect(harness.app.azure.snapshot!.users.single,
        azUser(displayName: 'Jane Doe'));

    // Which is the point: the action the operator was staring at is gone, from
    // the button they press all day rather than the expensive one.
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
    );
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Wijzig de school in Azure'), findsNothing);

    // The Log panel says which leg did it, so an adoption that repaired a record
    // stays distinguishable from one that added a new one.
    expect(
      harness.log.entries.map((e) => e.message),
      contains('Azure: 1 account(s) bijgewerkt met de volledige gegevens uit '
          'de employeeId-opzoeking.'),
    );
  });

  testWidgets(
      'a staff member who left WISA still gets their Office 365 account '
      'proposed for cleanup (#269/#349)', (WidgetTester tester) async {
    // The other half of #268, and the worse one. Anna Smit has left the school:
    // WISA no longer lists her and her Smartschool account is already gone. Her
    // Office 365 account is not — and our prefix sits *second* in the comma list
    // other software maintains on `department` (`SSM,GBS`, #237).
    //
    // Both reads that could surface her fail at once. The bulk `$filter` asks
    // `startswith(department,'GBS')` and cannot see her, which #268 ruled cannot
    // be widened (Graph has no `contains`). And the `employeeId` back-fill (#231)
    // is fed from the *current* WISA snapshot, so the pass that drops her from
    // WISA is the pass it stops asking about her.
    //
    // The shape of the failure is what makes it dangerous: she does not linger as
    // a to-do the operator ignores, she *vanishes*. No LinkedStaff record is
    // built, RemoveStaffFromAzure (which needs `azure != null`) is never
    // evaluated, and the account lives on with nothing but Office 365 itself to
    // show for it.
    //
    // The trigger is the drift pass itself: since #316 it re-reads Azure in
    // full, which discards the previous user list — the very list that had been
    // carrying her. (Before that the same loss only arrived by accident, when
    // Graph refused an aged token; this snapshot still carries one, and the
    // pass no longer even sends it.)
    //
    // Only this layer sees the whole thing: the Azure pull has to remember her
    // from the snapshot it already holds, the linker has to keep the row it
    // produces as an Azure-only staff record (INV-22), and the operator has to be
    // handed the cleanup in Acties → Personeel.
    //
    // **What that cleanup is changed in #349.** Her `department` reads
    // `SSM,GBS`: she is gone from WISA group-wide, but the list a *sibling*
    // school maintains still names them. The account may not be deleted on that
    // evidence — `department` is neither ours to write nor guaranteed current
    // (#237), and destroying a live account of another school of the group is
    // the loss #340 exists to prevent. So our own entry is struck out instead
    // and the account is left standing, which is also what makes the group-wide
    // outcome right: she drops out of *our* Azure pull, SSM's own instance then
    // sees an account naming nobody but them, and the last school to release her
    // is the one that deletes it.
    //
    // Everything this test is actually about is unchanged: the delta recovery,
    // the targeted `employeeId` lookup that is the only leg left, the record
    // surviving as an Azure-only LinkedStaff, and the operator being handed
    // something to do about it.
    useTallWindow(tester);
    final azureWire = DepartedStaffGraph();
    final harness = ReconcileHarness(
      // Gone from WISA…
      wisa: wisaSnap(students: const [], staff: const []),
      // …and gone from Smartschool, so only Azure still holds her.
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
        memberships: const [],
      ),
      azureTransport: azureWire,
      // Last night's snapshot: her account as the previous pass left it, and a
      // token that has since aged out.
      azureInitial: azSnap(deltaToken: 'AZ-STALE', users: [azStaffUser()]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    // Yesterday's session: the seeded Azure snapshot is reused untouched, its
    // token unspent.
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(azureWire.resumeTokens, isEmpty);

    // Today: Check for drift, which is what re-reads Azure.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The pass really was the losing one: it re-read in full, so the previous
    // user list is gone. The stored token was not resumed from at all (#316) —
    // dropping it is what makes this the full read, and the snapshot it came
    // with still goes in, which is the only reason she survives below.
    expect(azureWire.resumeTokens, isEmpty);
    expect(azureWire.bulkReads, 1);

    // She came back on the only leg left — one targeted lookup for an id WISA no
    // longer names, remembered from the snapshot the app already held.
    expect(azureWire.employeeIdLookups, <String>["employeeId in ('42')"]);
    expect(harness.app.azure.snapshot?.users.map((u) => u.id),
        <String>['az-staff']);

    // The linker keeps her as an Azure-only staff record (INV-22: `department`
    // still names us), which is the record the deletion is raised on.
    final linked = harness.controller.linked!.snapshot.staff.single;
    expect(linked.wisa, isNull);
    expect(linked.smartschool, isNull);
    expect(linked.azure?.id, 'az-staff');

    // And that is what the operator sees: Acties → Personeel, the way they
    // would look.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    await selectAccount(
      tester,
      harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'staff')
          .targetId,
    );
    expect(find.text('Haal onze school uit het Office 365 account'),
        findsOneWidget);
    expect(find.text('Verwijder Azure account'), findsNothing,
        reason: "the department list still names a sibling school (#349)");
  });

  testWidgets(
      'the apply-confirmation dialog names the system the pass really writes, '
      'in Dutch (#234)', (WidgetTester tester) async {
    // The report, reproduced through the real app: a student whose WISA name
    // differs from their Azure displayName raises exactly one action —
    // ModifyAzureName, a single Graph PATCH — and the confirmation used to
    // announce it as "This writes 1 change(s) to Smartschool and Azure AD".
    // Both halves of that were wrong: the wrong systems, and English on a Dutch
    // screen.
    //
    // This is the layer that sees it. The sentence is assembled from the
    // *selected* option of every choice the operator's drill-down left standing
    // (#110/#244/#248), so what it claims depends on the dispatch, the entry
    // grouping and the per-row selection all agreeing — a widget test of the
    // dialog in isolation would only ever prove the formatter.
    useTallWindow(tester);
    final harness = ReconcileHarness(
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
      // displayName left empty — the single thing out of step with WISA.
      azure: azSnap(users: [azUser()]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
      reason: 'the account holds exactly the action the report names',
    );
    final id = entry.targetId;
    await selectAccount(tester, id);
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();

    // One system, the one the action targets, under a Dutch title with Dutch
    // buttons.
    final dialog = find.byType(AlertDialog);
    Finder inDialog(Finder matching) =>
        find.descendant(of: dialog, matching: matching);
    expect(find.text('Toepassen voor ${entry.target}?'), findsOneWidget);
    expect(
      inDialog(find.textContaining('Dit schrijft 1 wijziging naar '
          'Office 365.')),
      findsOneWidget,
    );
    expect(inDialog(find.textContaining('Smartschool')), findsNothing,
        reason: 'nothing in this pass goes near Smartschool');
    expect(inDialog(find.text('Annuleer')), findsOneWidget);
    expect(inDialog(find.text('Toepassen')), findsOneWidget);

    // And confirming really does write only there: one Graph PATCH, no SOAP.
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(
      harness.graph.requests.where((r) => r.method == 'PATCH'),
      hasLength(1),
    );
    expect(harness.soap.soapActions, isEmpty);
  });

  testWidgets(
      'a WISA-only student reaches Acties under their own class, and one '
      'apply provisions both of their accounts (#230)',
      (WidgetTester tester) async {
    // The new-intake case the operator reported as "they never get offered the
    // account creates". Two halves, and only a run of the real app covers both.
    //
    // That they show up at all is the first half: a student present only in
    // WISA has no Smartschool and no Azure record, so every join the linker
    // makes is empty, and the managed-school filter (#178) drops exactly this
    // shape of record when the school is *not* flagged as ours. Here it is, so
    // they must land under their real class — not "Zonder klas", not
    // "Niet toegewezen", not nowhere.
    //
    // The second half is what the panel offers. Provisioning is a chain:
    // AddStudentToSmartschool builds its account with the Azure UPN as the
    // `mail`, so it evaluates false until the Office 365 account exists, and the
    // dispatcher — a pure function of the current record — can only ever offer
    // the first link. The operator used to have to apply, notice the relink, and
    // apply again. Now the State layer runs the follow-up against the freshly
    // relinked record, so the one click the operator makes provisions the
    // student end to end.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        schools: [wisaSchool(1)],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss')],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Browse Acties → Leerlingen the way the operator did when they reported
    // this: the student's row names their own class.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    final Finder row = find.byKey(ValueKey('account-row-$id'));
    expect(find.descendant(of: row, matching: find.text('Jane Doe')),
        findsOneWidget,
        reason: 'a student with no downstream account is still listed');
    expect(find.descendant(of: row, matching: find.text('3C')), findsOneWidget,
        reason: 'under their own class — not "Zonder klas", not nowhere');

    // Apply that one row.
    await selectAccount(tester, id);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();

    // The confirmation names the chained system before the write (#234). The
    // visible action targets Office 365, but this apply goes on to create the
    // Smartschool account its chain unlocks, and the operator is told so — as a
    // follow-up that *may* run (its own evaluate decides), never as a second
    // counted change.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Dit schrijft 1 wijziging naar '
            'Office 365. Een vervolgactie kan ook naar Smartschool '
            'schrijven.'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);

    // Both accounts exist now, off that single click, and both writes are
    // reported — the second is a real write the operator must see, not a
    // silent extra.
    expect(
      harness.controller.applyResults!.map((r) => r.changes.summary),
      <String>[
        'Maak een nieuw Office 365 account',
        'Maak een nieuw Smartschool account',
      ],
    );
    expect(
      harness.controller.applyResults!.map((r) => r.outcome.name),
      everyElement('applied'),
    );
    expect(harness.graph.createdUsers.single['employeeId'], 'W7');
    expect(harness.soap.soapActions.any((a) => a.contains('saveUser')), isTrue);

    // The Smartschool account carries the UPN that actually landed — the whole
    // reason the follow-up runs against the relinked record instead of the
    // projection the first action described.
    final linked = harness.controller.linked!.snapshot.accounts.single;
    expect(linked.azure, isNotNull);
    expect(linked.smartschool?.mail, linked.azure?.upn);

    // And both writes are in the log the operator reads.
    final messages = harness.log.entries.map((e) => e.message);
    expect(messages, contains(contains('Maak een nieuw Office 365 account')));
    expect(messages, contains(contains('Maak een nieuw Smartschool account')));
  });

  testWidgets(
      'a freshly provisioned student is not then offered a move into the class '
      'the create just put them in (#342)', (WidgetTester tester) async {
    // The sibling of the #341 rollover run, from the other end of the account
    // lifecycle: a new intake rather than a class change.
    //
    // `AddStudentToSmartschool` does not only create — it writes the account
    // into its class straight after (#55), the way legacy chained the move
    // after the create. But the record it hands back is the account it built,
    // which says nothing about that membership, so the incremental refresh
    // (#72) spliced in a student sitting in no class at all: the placement
    // resolver read `currentClass` as null, `MoveToSmartschoolClassGroup`
    // evaluated true, and the very next frame proposed a move into the class
    // Smartschool had *just* been told to put them in. Idempotent, so harmless
    // to apply — but this is the bulk card the whole September intake cohort is
    // applied from, and since #338 an open move also holds back the
    // stamboeknummer write.
    //
    // Only the real app shows it: the create and its placement are two SOAP
    // writes inside one chained apply, and what the operator then sees is
    // whatever the refresh believes about a snapshot it patched itself.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        // The class has to be one of *ours* or the create declines to place at
        // all (#333) — the same guard the standalone move applies.
        classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
        schools: [wisaSchool(1)],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    // One click provisions both accounts (#230) — and places the Smartschool
    // one.
    final String id = accountId(harness, 'Jane Doe');
    await selectAccount(tester, id);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    final int pullsBefore = harness.ssSyncs;
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.soap.movedToClasses, <String>['3C_ss'],
        reason: 'the create placed the account it just made');

    // Back on the card, with no Synchronisatie in between: the student is in
    // their class as far as the app is concerned, so there is nothing left to
    // propose.
    await selectAccount(tester, id);
    expect(
      find.text('Wijzig de klas in Smartschool'),
      findsNothing,
      reason: 'the class the create wrote is the class Smartschool has',
    );
    expect(
      find.text('Deze acties staan niet meer open op deze kaart.'),
      findsOneWidget,
      reason: 'the provisioning settled instead of raising a follow-up',
    );
    expect(harness.ssSyncs, pullsBefore,
        reason: 'the card ran off the spliced snapshot, not a re-pull');
    expect(harness.soap.movedToClasses, <String>['3C_ss'],
        reason: 'and no second placement was written');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a class placement that blows up leaves the Smartschool create reported '
      'as done, with the class named as the part that failed (#343)',
      (WidgetTester tester) async {
    // The hole #342 left in the same path. `AddStudentToSmartschool` places its
    // new account straight after creating it (#55), and that step is
    // best-effort: a `moveUserToClass` that comes back *false* is shrugged off
    // and the standalone move catches the student next pass. But the step ran
    // inside the create's own `try`, so a placement that **threw** — a dropped
    // connection, a gateway error, unreadable XML — unwound into the create's
    // `catch` and was reported as a failed create, for an account `saveUser`
    // had already made.
    //
    // What the operator then saw is the reason this is an app-level test: the
    // applier splices nothing on a failure, so the card went on offering "Maak
    // een nieuw Smartschool account" for an account that existed, and pressing
    // Toepassen again wrote `saveUser` a second time for the same uid. The
    // error message pointed at the create, not at the placement.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
        schools: [wisaSchool(1)],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );
    // `saveUser` succeeds; only the placement behind it comes apart on the
    // wire. A refusal code would take the other branch — this is the one that
    // used to escape.
    harness.soap.throwFor = (String action) =>
        action.endsWith('#saveUserToClass')
            ? StateError('502 Bad Gateway')
            : null;
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);

    final String id = accountId(harness, 'Jane Doe');
    await selectAccount(tester, id);
    final int pullsBefore = harness.ssSyncs;
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Both creates are reported as done — the Smartschool one included, because
    // the account it made is real.
    expect(
      harness.controller.applyResults!.map((r) => r.outcome),
      everyElement(ActionOutcome.applied),
      reason: 'the create is this action\'s success criterion (INV-41); a '
          'best-effort placement may not fail it however it declines',
    );
    expect(find.textContaining('Mislukt —'), findsNothing);

    // And the placement that did not happen is on screen, naming the class, so
    // the swallowed exception is not a silent one — there is no log sink on
    // that path.
    expect(
      find.textContaining('klasplaatsing in 3C is mislukt'),
      findsWidgets,
      reason: 'a bare "gelukt" for a write that half happened is the trip to '
          'the log panel #272 exists to remove',
    );
    expect(find.textContaining('502 Bad Gateway'), findsWidgets,
        reason: 'with the cause Smartschool gave, which decides what to do');
    expect(
      harness.controller.applyResults!
          .expand((r) => r.warnings)
          .where((w) => w.contains('3C')),
      hasLength(1),
    );
    expect(
      harness.log.entries.where((e) => e.isError).map((e) => e.message),
      contains(contains('klasplaatsing in 3C is mislukt')),
      reason: 'the pass an operator reconstructs later must carry it too',
    );

    // The account exists in Smartschool, so it exists in the snapshot: the
    // create is not offered a second time, and the class move — this path's
    // safety net — is what the card asks for instead.
    await selectAccount(tester, id);
    expect(
      harness.controller.linked!.snapshot.accounts.single.smartschool,
      isNotNull,
      reason: 'a create reported as failed spliced nothing, and the card then '
          'offered saveUser for the same uid all over again',
    );
    expect(
      find.text('Wijzig de klas in Smartschool'),
      findsOneWidget,
      reason: 'the student really is in no class, so the move is the fix',
    );
    expect(
      harness.soap.soapActions.where((a) => a.endsWith('#saveUser')),
      hasLength(1),
      reason: 'exactly one create went out for this student',
    );
    expect(harness.soap.movedToClasses, isEmpty,
        reason: 'the placement never landed, so nothing may claim it did');
    expect(harness.ssSyncs, pullsBefore,
        reason: 'the card ran off the spliced snapshot, not a re-pull');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a WISA-only staff member is provisioned by one apply in Acties → '
      'Personeel (#240)', (WidgetTester tester) async {
    // The staff twin of the #230 student case, and the same two-pass friction:
    // AddStaffToSmartschool builds its account with the Azure UPN as the `mail`,
    // so it evaluates false until the Office 365 account exists, and the
    // dispatch — a pure function of the record as it stands — can only ever
    // offer the first link. The operator had to apply, notice the relink, and
    // apply again; Acties → Personeel never showed the full provisioning intent.
    //
    // Only a run of the real app covers the whole path: the staff member has to
    // reach the synthetic "Personeel" tree at all, the tile has to offer the
    // create, and the follow-up has to run against the record the *relink*
    // produced — `createPrincipalName` suffixes on a UPN collision, so the
    // Smartschool account must carry the UPN that landed, not the projection.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: const [],
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Browse Acties → Personeel: the staff member is a row of that tab's list,
    // with the first link of the chain offered and only that one.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'staff');
    final id = entry.targetId;
    final Finder row = find.byKey(ValueKey('account-row-$id'));
    expect(find.descendant(of: row, matching: find.text('Anna Smit')),
        findsOneWidget,
        reason: 'a staff member with no downstream account is still listed');

    // Apply that one row. Its decision reads as the either/or of #248: the WISA
    // opt-out this family also raises is its alternative, not a second to-do.
    await selectAccount(tester, id);
    expect(find.text('Kies één oplossing:'), findsOneWidget);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    expect(find.text('Maak een nieuw Smartschool account'), findsNothing,
        reason: 'the dispatch can only see the first link of the chain');
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);

    // Both accounts exist now, off that single click, and both writes are
    // reported — the second is a real write the operator must see, not a silent
    // extra. And *only* those two: the WISA ignore rule this family also raises
    // is the alternative of the same choice since #248, so it no longer rides
    // along on the apply that just provisioned her.
    expect(
      harness.controller.applyResults!.map((r) => r.changes.summary),
      <String>[
        'Maak een nieuw Office 365 account',
        'Maak een nieuw Smartschool account',
      ],
    );
    expect(
      harness.controller.applyResults!.map((r) => r.outcome.name),
      everyElement('applied'),
    );
    expect(harness.graph.createdUsers.single['employeeId'], '42',
        reason: 'the staff Azure bridge is wisaId, never the staff code');
    expect(harness.soap.soapActions.any((a) => a.contains('saveUser')), isTrue);

    // The Smartschool account carries the UPN that actually landed, and the
    // WISA staff `code` as its accountId (the staff Smartschool bridge).
    final linked = harness.controller.linked!.snapshot.staff.single;
    expect(linked.azure, isNotNull);
    expect(linked.smartschool?.mail, linked.azure?.upn);
    expect(linked.smartschool?.accountId, 'SMIT');

    // And both writes are in the log the operator reads.
    final messages = harness.log.entries.map((e) => e.message);
    expect(messages, contains(contains('Maak een nieuw Office 365 account')));
    expect(messages, contains(contains('Maak een nieuw Smartschool account')));
  });

  testWidgets(
      'a new staff member offers one either/or choice, and applying it '
      'provisions every hire without blacklisting any end-to-end (#248)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation, over the real Graph and
    // Smartschool write paths. Two freshly hired teachers, present in WISA only.
    //
    // Each used to carry "Maak een nieuw Office 365 account" *and* "Negeer dit
    // account bij het importeren uit WISA" as two independent to-dos, both
    // selected — so one click provisioned the teacher end to end (the #240
    // chain) and then wrote a DontImportUserFromWisa rule on the very code it
    // had just provisioned. The rule set is persisted and re-applied on every
    // WISA pull, so the next sync dropped the staff member the operator had
    // just given two accounts, and those accounts went unmanaged.
    //
    // This is the layer that sees it: the contradiction is what the operator
    // reads off Acties → Personeel and clicks, and the fix has to reach it
    // through the dispatch, the entry grouping and the drill-down.
    useTallWindow(tester);
    final harness = newStaffChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Browse Acties → Personeel, where the operator met this.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    // Both new hires are rows, each badged once — the either/or is one
    // decision, never two independent to-dos.
    final entries = harness.controller.pendingEntries
        .where((e) => e.family == 'staff')
        .toList();
    expect(entries, hasLength(2));
    for (final e in entries) {
      final Finder row = find.byKey(ValueKey('account-row-${e.targetId}'));
      await tester.ensureVisible(row);
      expect(
          find.descendant(of: row, matching: find.text('1')), findsOneWidget);
    }

    // Selecting one offers both readings as radios, the create pre-selected —
    // and the opt-out is only ever the alternative, never a line of its own.
    await selectAccount(tester, entries.first.targetId);
    expect(find.text('Kies één oplossing:'), findsOneWidget);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    expect(find.text('Negeer dit account bij het importeren uit WISA'),
        findsOneWidget);

    // Provision both, one deliberate apply each — since #295 Acties applies per
    // decision and nothing else, and #296 is what brings the school-wide bulk
    // pass back with its cohort visible first.
    final pulls = harness.wisaSyncs;
    final summaries = <String>[];
    final outcomes = <String>[];
    for (final e in entries) {
      await selectAccount(tester, e.targetId);
      final Finder apply = find.byKey(ValueKey('entry-apply-${e.targetId}'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();
      // Each pass clears the previous one's results, so the verdicts are
      // collected as they land.
      summaries.addAll(
          harness.controller.applyResults!.map((r) => r.changes.summary));
      outcomes
          .addAll(harness.controller.applyResults!.map((r) => r.outcome.name));
    }

    // Both teachers were provisioned end to end — Office 365 and, off the #240
    // chain, Smartschool…
    expect(harness.graph.createdUsers, hasLength(2));
    expect(summaries.where((s) => s == 'Maak een nieuw Office 365 account'),
        hasLength(2));
    expect(summaries.where((s) => s == 'Maak een nieuw Smartschool account'),
        hasLength(2));
    // …and not one of them was blacklisted on the way out. A
    // DontImportUserFromWisa rule re-pulls WISA, so an untouched pull count is
    // the proof.
    expect(
      summaries,
      isNot(contains('Negeer dit account bij het importeren uit WISA')),
      reason: 'the rule would drop the hires this same pass just provisioned',
    );
    expect(harness.wisaSyncs, pulls);
    expect(outcomes, everyElement('applied'));
  });

  testWidgets(
      'a card owing two Office 365 writes keeps both after one apply, and '
      're-offers neither (#321)', (WidgetTester tester) async {
    // Found while working #315, on the apply side rather than the read side. A
    // whole-card pass resolves **every** action once, up front, from the
    // pre-apply linked view, and each Azure modify projects its mutated record
    // as `_az.copyWith(…)` off that same frozen record. So the second write's
    // snapshot splice put the first write's field back to the value it had
    // before the pass: Graph held both PATCHes, the in-memory record held one,
    // and the relink behind the pass re-raised an action for a change Azure
    // already carried — the contradicted record being also what the shared
    // store publishes to the other operators.
    //
    // Only a run of the real app covers the whole of it: the card the operator
    // reads, the confirmation they answer, the pass, the relink behind it, and
    // the list that has to stop offering what was just written.
    useTallWindow(tester);
    final harness = twoAzureWritesHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // Her card owes two Office 365 writes and nothing else: the display name
    // WISA disagrees with, and the school her account does not carry.
    final String id = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, id);
    expect(find.text('Wijzig de naam in Azure'), findsOneWidget);
    expect(find.text('Wijzig de school in Azure'), findsOneWidget);

    // Apply the whole card, confirmation and all.
    final Finder apply = find.byKey(ValueKey('entry-apply-$id'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // Two real Graph PATCHes went out…
    expect(
      harness.graph.requests.where((r) => r.method == 'PATCH'),
      hasLength(2),
    );
    // …and the record the app holds carries both of them. Before the fix it
    // carried the school alone, with the display name back at its pre-apply
    // value.
    final user = harness.app.azure.snapshot!.users.single;
    expect(user.displayName, 'Jane Doe');
    expect(user.companyName, 'GBS');

    // Which is what the operator sees: both writes reported on her card, and
    // nothing left to apply on it — the re-offered rename is gone.
    expect(find.byKey(ValueKey('actions-detail-$id')), findsOneWidget);
    final Finder verdict = find.byKey(ValueKey('entry-outcomes-student-$id'));
    await tester.ensureVisible(verdict);
    expect(
      find.descendant(
          of: verdict, matching: find.text('Wijzig de naam in Azure')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: verdict, matching: find.text('Wijzig de school in Azure')),
      findsOneWidget,
    );
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
    );
    expect(find.byKey(ValueKey('entry-apply-$id')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a moved-up pupil whose Office 365 job title is wrong is repaired end to '
      'end, so the licensing group finally admits them (#358)',
      (WidgetTester tester) async {
    // The report: Office 365 grants the student licence through a dynamic group
    // whose rule reads *two* fields —
    //
    //     (user.companyName -eq "<PREFIX>") and (user.jobTitle -eq "LeerlingSec")
    //
    // — and nothing in this port ever read, compared or wrote `jobTitle`. The
    // live audit found four pupils WISA lists in our secondary school whose
    // account still carries the `LeerlingBas` a basisschool stamped on it years
    // ago. All four hold no licence, and no pass the app made could say why.
    //
    // Jane below is one of them: her account is in step in every other respect,
    // so the job title is the only thing this run can be about. Only the real
    // app covers the whole of it — the pull that has to *read* a field the
    // `$select` never asked for, the linker rebuilding the record, the action
    // the operator reads off the card, the confirmation they answer, the Graph
    // PATCH, and the relink that has to stop offering what was just written.
    useTallWindow(tester);
    final harness = ReconcileHarness(
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
      azure: azSnap(
        users: [
          azUser(displayName: 'Jane Doe', jobTitle: 'LeerlingBas'),
        ],
      ),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    // Her card owes exactly one write, and it is the one that gets her licensed.
    final entry = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student');
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de functietitel in Azure'],
    );
    final String id = entry.targetId;
    await selectAccount(tester, id);
    expect(find.text('Wijzig de functietitel in Azure'), findsOneWidget);

    // Apply it, confirmation and all.
    final Finder apply = find.byKey(ValueKey('entry-apply-$id'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // One real Graph PATCH went out, carrying that field and nothing else: her
    // `companyName` was already right, and a one-field correction must not turn
    // into a rewrite of the record.
    final patches =
        harness.graph.requests.where((r) => r.method == 'PATCH').toList();
    expect(patches, hasLength(1));
    expect(
      jsonDecode(patches.single.body!),
      <String, dynamic>{'jobTitle': 'LeerlingSec'},
    );

    // The record the app holds carries both halves of the rule now — which is
    // the whole point: the dynamic group can finally see her.
    final user = harness.app.azure.snapshot!.users.single;
    expect(user.jobTitle, 'LeerlingSec');
    expect(user.companyName, 'GBS');

    // And the operator sees the write reported on her card, with nothing left
    // to apply on it.
    final Finder verdict = find.byKey(ValueKey('entry-outcomes-student-$id'));
    await tester.ensureVisible(verdict);
    expect(
      find.descendant(
          of: verdict, matching: find.text('Wijzig de functietitel in Azure')),
      findsOneWidget,
    );
    expect(
      harness.controller.pendingEntries.where((e) => e.family == 'student'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a newly provisioned student is created with both halves of the '
      'licensing rule, and is not then asked to repair one (#358)',
      (WidgetTester tester) async {
    // The other end of #358: every account this port ever created landed with a
    // blank `jobTitle`, fell outside the licensing group, and stayed unlicensed
    // until somebody assigned a licence by hand.
    //
    // The run has to reach past the create itself. What `createUser` sends and
    // what the applier splices back into the snapshot are two different things,
    // and if the projected record forgot the field, the relink behind the very
    // same apply would raise the repair against an account that had just been
    // created correctly — the operator's first sight of the new student being a
    // correction to a write the app had made seconds earlier.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(
        students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
        schools: [wisaSchool(1)],
        classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
      ),
      smartschool: ssSnap(
        groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
        accounts: const [],
        memberships: const [],
      ),
      azure: azSnap(users: const []),
      ourSchoolIds: const {1},
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    final String id = harness.controller.pendingEntries
        .singleWhere((e) => e.family == 'student')
        .targetId;
    await selectAccount(tester, id);
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);
    final Finder apply = find.byKey(ValueKey('entry-apply-$id'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The account Graph was actually asked to make satisfies the rule on both
    // fields. Before the fix the second one was simply absent from the body.
    final created = harness.graph.createdUsers.single;
    expect(created['companyName'], 'GBS');
    expect(created['jobTitle'], 'LeerlingSec');

    // …and so does the record the pass spliced in, so the pupil the app just
    // provisioned is not immediately offered a repair of the app's own write.
    expect(harness.app.azure.snapshot!.users.single.jobTitle, 'LeerlingSec');
    expect(find.text('Wijzig de functietitel in Azure'), findsNothing);
    expect(
      harness.controller.pendingEntries
          .expand((e) => e.choices)
          .map((c) => c.selected.changes.summary),
      isNot(contains('Wijzig de functietitel in Azure')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Personeel lists our own school, and a colleague at a sibling group '
      'school is left out without being proposed for deletion (#340)',
      (WidgetTester tester) async {
    // As reported: Acties → Personeel listed 2574 people — the whole
    // scholengroep's personeel, because the shared WISA credentials walk every
    // school and `SmaSyncPer` carried no school of origin at all. The tab was
    // unusable as a work list and the Synchronisatie "Personeel" tile counted
    // the same group-wide set.
    //
    // The fix has to narrow the *view* and nothing upstream of it, and only a
    // run of the real app puts both halves of that on screen at once. Carla
    // below is the reason: she left us for a sibling school that still employs
    // her, so WISA still returns her — which is the sole thing standing between
    // her Smartschool and Office 365 accounts and a proposed deletion. Narrow
    // the pull, or the linker's staff pass, and every one of those records loses
    // its WISA half and the app starts offering to delete the accounts of people
    // the group still employs. The Personeel list shrinking and the removals
    // staying silent are one behaviour, and this is the layer that sees it.
    useTallWindow(tester);
    final harness = ReconcileHarness(
      // School 1 is ours; school 7 is a sibling school of the group.
      ourSchoolIds: const {1},
      wisa: wisaSnap(
        students: const [],
        schools: [wisaSchool(1), wisaSchool(7)],
        staff: [
          // Ours, fully in sync across the three systems.
          wisaStaff(),
          // A teacher of the sibling school and nothing to do with us — the
          // shape 2500-odd of those 2574 rows had.
          wisaStaff(
            code: 'VERB',
            wisaId: '77',
            firstName: 'Bert',
            lastName: 'Vermeer',
            schoolIds: const {7},
          ),
          // The one that makes the pull load-bearing: she taught here until
          // recently, so we still hold both her accounts, and WISA now places
          // her at the sibling school alone.
          wisaStaff(
            code: 'DEGRC',
            wisaId: '78',
            firstName: 'Carla',
            lastName: 'De Groote',
            schoolIds: const {7},
          ),
        ],
      ),
      smartschool: ssSnap(
        groups: const [],
        accounts: [
          ssStaffAccount(),
          ssStaffAccount(
            uid: 'carla.degroote',
            accountId: 'DEGRC',
            mail: 'carla.degroote@school.example',
            givenName: 'Carla',
            surname: 'De Groote',
            fax: '0078',
          ),
        ],
        memberships: const [],
      ),
      azure: azSnap(users: [
        azStaffUser(),
        // Bert's account exists in the shared tenant and the connector's
        // `employeeId` back-fill (#231) adopts it, because that back-fill asks
        // about every staff member the group-wide WISA pull returned. His
        // `department` names his own school, which is what says it is not ours.
        azStaffUser(
          id: 'az-vermeer',
          upn: 'bert.vermeer@school.example',
          employeeId: '77',
          displayName: 'Vermeer Bert',
          givenName: 'Bert',
          surname: 'Vermeer',
          department: 'SSM',
        ),
        azStaffUser(
          id: 'az-degroote',
          upn: 'carla.degroote@school.example',
          employeeId: '78',
          displayName: 'De Groote Carla',
          givenName: 'Carla',
          surname: 'De Groote',
        ),
      ]),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();
    expect(harness.controller.error, isNull);

    // The Synchronisatie overview tile counts our own personeel: Anna and
    // Carla, not Bert. It read the group-wide number before.
    final Finder tile = find.byKey(const ValueKey('reconcile-category-staff'));
    await tester.ensureVisible(tile);
    expect(find.descendant(of: tile, matching: find.text('PERSONEEL')),
        findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);

    // The drop is said out loud, so a colleague an operator cannot find reads as
    // "filtered by the managed-school flags in Instellingen" rather than as a
    // pull that never returned them.
    expect(
      harness.log.entries.map((e) => e.message),
      contains('1 personeelslid/-leden overgeslagen: niet in een school die we '
          'beheren.'),
    );

    // And that is what Acties → Personeel shows.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    // Anna has no work at all, so turn off the "alleen met acties" switch and
    // look at the whole personeel roster — which is what the operator counting
    // 2574 was looking at.
    final Finder toggle =
        find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Carla De Groote'), findsOneWidget,
        reason: 'we still hold both her accounts, so her situation is ours');
    expect(find.text('Bert Vermeer'), findsNothing,
        reason: 'a teacher of a school we do not manage is none of our work');

    // Carla is the load-bearing case, and what she is *offered* changed in
    // #349. She left us for a sibling school the group still employs her at, so
    // her Smartschool account here is ours to clean up — that much used to be
    // impossible to express, because both staff removals were gated on `wisa ==
    // null`.
    //
    // Her Office 365 account is a different matter, and the #340 guarantee is
    // unchanged: WISA still places her somewhere in the group, so nothing may
    // delete it. Our claim is struck out of the `department` list instead and
    // the account stands. A narrower WISA pull would have left her `wisa` null
    // and, with the list naming us, taken the account outright.
    final staff = harness.controller.linked!.snapshot.staff;
    final carla = staff.singleWhere((s) => s.wisa?.code.value == 'DEGRC');
    expect(carla.wisa, isNotNull);
    expect(carla.smartschool, isNotNull);
    expect(carla.azure, isNotNull);
    expect(carla.hasLeftGroup, isFalse, reason: 'the group still employs her');
    expect(
      harness.controller.linked!.staffActions
          .whereType<RemoveStaffFromSmartschool>()
          .map((a) => a.target.wisa?.code.value),
      <String>['DEGRC'],
    );
    expect(
      harness.controller.linked!.staffActions.whereType<RemoveStaffFromAzure>(),
      isEmpty,
      reason: 'deleting it would destroy the account of somebody WISA can see '
          'is still employed by the group (#340)',
    );
    expect(
      harness.controller.linked!.staffActions
          .whereType<ReleaseStaffFromAzureSchool>()
          .map((a) => a.describeChanges().fields.single.after),
      <String>['SSM'],
      reason: "our prefix struck out, the sibling school's entry kept verbatim",
    );

    // Bert's record is kept whole behind the filter — dropped from the view, not
    // from the link, which is exactly what keeps his Office 365 account safe.
    // The dispatch, still running over the *unfiltered* snapshot, does raise the
    // Smartschool create-or-blacklist either/or on him…
    final bert = staff.singleWhere((s) => s.wisa?.code.value == 'VERB');
    expect(bert.wisa, isNotNull);
    expect(bert.azure?.id, 'az-vermeer');
    expect(bert.belongsToOurSchool, isFalse);
    expect(
      harness.controller.linked!.staffActions
          .where((a) => a.target.id == bert.id),
      hasLength(2),
    );
    // …and the view drops it on the floor, which is the half that matters here.
    // These entries are not only what the list renders: they are the Personeel
    // badge's count and, through the school-wide "Toepassen op alle", what one
    // press would write. Left in, that press would have offered to provision the
    // whole scholengroep — for people who appear in no list being confirmed.
    expect(
      harness.controller.pendingEntries
          .where((e) => e.family == 'staff')
          .map((e) => e.target),
      <String>['Carla De Groote'],
      reason: 'the one person of ours with work — never Bert, whose school we '
          'do not manage',
    );
    expect(harness.controller.staffPendingCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a teacher HR never took out of service can be retired end-to-end (#349)',
      (WidgetTester tester) async {
    // The situation the command exists for, through the real app. WISA's staff
    // export carries no employment status, so Anna — who will not be hired
    // again, but whose dienstverband nobody closed — arrives in every pull in
    // step with all three systems. Nothing about her is pending, and before
    // #349 nothing ever could be.
    useTallWindow(tester);
    final settings = InMemorySettingsStore(const AppSettings());
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssStaffAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azStaffUser(department: 'GBS')]),
      settingsStore: settings,
      liveSettings: LiveSettings(const AppSettings()),
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenActions(tester);
    expect(harness.controller.error, isNull);

    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(harness.controller.staffPendingCount, 0,
        reason: 'she looks exactly like a colleague who is staying');

    // She has no work, so she is behind the "alleen met acties" switch.
    final Finder toggle =
        find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final String id = harness.controller.linked!.snapshot.staff.single.id.value;
    await selectAccount(tester, id);

    // The command is the only thing on her card, and it says what it is for.
    expect(find.text('Geen openstaande beslissingen voor dit account.'),
        findsOneWidget);
    expect(find.text('Uit dienst'), findsOneWidget);
    final Finder retire = find.byKey(ValueKey('actions-retire-apply-$id'));
    await tester.ensureVisible(retire);
    await tester.tap(retire);
    await tester.pumpAndSettle();

    // One confirmation, naming every system this single press reaches.
    expect(find.text('Anna Smit uit dienst?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // The rule, the Smartschool account and the Office 365 account, off one
    // press — and the rule is what keeps the next sync from proposing to build
    // her accounts back.
    expect(
      harness.controller.applyResults!.map((r) => r.outcome),
      everyElement(ActionOutcome.applied),
    );
    expect(
      harness.soap.soapActions.any((a) => a.contains('setAccountStatus')),
      isTrue,
    );
    expect(harness.graph.requests.any((r) => r.method == 'DELETE'), isTrue);
    expect(
      (await settings.load())
          .wisaRules
          .whereType<DontImportUserFromWisa>()
          .single
          .userCode,
      'SMIT',
      reason: 'the rule outlives the process, or the next launch proposes '
          'building her accounts back (#276)',
    );
    expect(harness.controller.linked!.snapshot.staff, isEmpty);
    expect(harness.controller.staffPendingCount, 0,
        reason: 'nothing is proposed to re-create her');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Office 365 cell of a staff card names the schools its Azure '
      'department lists, and a session that never pulled reads the same list '
      '(#352)', (WidgetTester tester) async {
    // The reading that makes the "uit dienst" decision above legible. The two
    // Office 365 halves of a departure are mutually exclusive by construction
    // and this one field is the whole discriminator: with a sibling school still
    // in the list Anna's account is *released*, with ours alone it is *deleted*.
    // Until now the app decided on a field the operator could not see anywhere.
    //
    // Only a full run shows it works. The list has to survive the whole pipeline
    // — the linker (whose `LinkedStaff.azure` is the narrow interface and
    // carries no `department` at all), the materializer, the document, the
    // shared store, a second session's adoption, and the card — and land in the
    // one cell it explains. A widget test renders the pane over a document
    // handed to it; it cannot show that the document ever carries this.
    useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();

    // Operator A pulls: Anna is in step in all three systems, and `department`
    // names our school second beside a sibling group school — the ordinary
    // state, not an edge case (#268).
    await ReconcileHarness(
      wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
      smartschool: ssSnap(
        groups: const [],
        accounts: [ssStaffAccount()],
        memberships: const [],
      ),
      azure: azSnap(users: [azStaffUser(department: 'SSM,GBS')]),
      store: snapshots,
      linkedStore: linkedStore,
      syncedBy: 'jan@school.example',
    ).controller.sync();

    // It is on the stored document, which is what makes the rest of this
    // possible: the transient record it was read off does not outlive the pass.
    final List<MaterializedAccount> stored = await linkedStore.readClassroom(
      school: staffPartition,
      classroom: 'Personeel',
    );
    expect(stored.single.departmentSchools, ['SSM', 'GBS']);

    // Operator B launches the real app onto the shared stores and never pulls.
    final operatorB = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: operatorB.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // She is in step everywhere, so she sits behind the work-list filter.
    final Finder toggle =
        find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    final String anna = accountId(operatorB, 'Anna Smit');
    await selectAccount(tester, anna);

    // Under the Office 365 tag, in the field's own order and casing, with our
    // own prefix left in: "ours alone" is the state that makes a deletion safe,
    // so it is exactly the one worth confirming on screen.
    const String line = 'Scholen: SSM, GBS';
    expect(
      find.descendant(
        of: find.byKey(ValueKey('account-detail-cell-$anna-azure')),
        matching: find.text(line),
      ),
      findsOneWidget,
    );
    expect(find.text(line), findsOneWidget,
        reason: 'the details pane only — an extra line per collapsed card on a '
            'Personeel roster is noise, and the two share one widget');

    // Read by an operator who pulled nothing: no connector round-trip anywhere
    // in this session, and the shared view untouched.
    expect(operatorB.wisaSyncs, 0);
    expect(operatorB.ssSyncs, 0);
    expect(operatorB.azSyncs, 0);
    // And it stays a reading: `department` is maintained by other software and
    // is not ours to write (#237), so nothing in the pass proposes touching it.
    expect(
      operatorB.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .expand((a) => a.changes.fields)
          .map((f) => f.field),
      isNot(contains('department')),
    );
    expect(tester.takeException(), isNull);
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
