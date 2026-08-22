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
import 'package:account_manager/src/screens/class_groups_screen.dart';
import 'package:account_manager/src/screens/home_screen.dart';
import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        AzureConnection,
        ChangeSignal,
        CosmosThrottleGovernor,
        InMemoryLinkedStore,
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
        StaticSignalRTokenProvider,
        WisaConnection,
        WisaSchoolProfile,
        WisaSchoolProfileLabel,
        WorkDateSetting,
        signalRRecordSeparator;
import 'package:azure_api/azure_api.dart'
    show AzureCredentials, StaticAuthProvider;
import 'package:smartschool_api/smartschool_api.dart'
    show DiscardSmartschoolGroup, SmartschoolConnector;
import 'package:wisa_api/wisa_api.dart'
    show DontImportClass, WisaImportRule, WisaSchool, parseSchoolRow;
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
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionsScreen), findsOneWidget);
    // Scoped to this screen: since #265 the Synchronisatie tab heads its own
    // counts section "Overzicht" too, and the shell keeps a visited screen
    // alive in the IndexedStack.
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.text('Overzicht'),
      ),
      findsOneWidget,
    );
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
    expect(find.text('Resultaat van de dry-run'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply all: confirm the dialog, the Smartschool write happens for real.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
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

  /// Two departed Smartschool-only students with different names, each raising
  /// the unregister/delete choice — a two-action pass whose steps are told
  /// apart by the account they name. [gate] parks every action so the pass can
  /// be observed frozen exactly where the operator waits (#243).
  ReconcileHarness twoDepartedHarness(Future<void> Function() gate) =>
      ReconcileHarness(
        applyGate: gate,
        wisa: wisaSnap(students: const []),
        smartschool: ssSnap(
          groups: const [],
          accounts: [
            ssAccount(
              uid: 'user0',
              accountId: '0',
              mail: 'user0@student.school.example',
              givenName: 'Jan',
              surname: 'Peeters',
            ),
            ssAccount(
              uid: 'user1',
              accountId: '1',
              mail: 'user1@student.school.example',
              givenName: 'Sofie',
              surname: 'Claes',
            ),
          ],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
      );

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
      'account and action in flight, and clears when the pass ends (#243)',
      (WidgetTester tester) async {
    // The real app over the offline harness, with the pass parked one action at
    // a time. An "Apply to all" over a September situation group writes
    // hundreds of accounts sequentially and runs for minutes; its only feedback
    // used to be greyed-out buttons and an indeterminate bar in a page header
    // the operator had scrolled past, and nothing stopped them navigating away
    // mid-write. Composition is the point here: the dialog has to sit over the
    // real shell, in the real font, above a page that is still scrollable.
    useTallWindow(tester);
    final gates = <Completer<void>>[];
    final harness = twoDepartedHarness(() async {
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

    // Idle: no dialog.
    expect(progressDialog, findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Parked on the first action: the dialog names how far along the pass is
    // and whose account is being written right now.
    expect(progressDialog, findsOneWidget);
    expect(gates, hasLength(1));
    expect(find.text('Acties toepassen…'), findsOneWidget);
    expect(progressLine(tester, 'actions-progress-count'), 'Actie 1 van 2');
    expect(progressLine(tester, 'actions-progress-step'),
        startsWith('Jan Peeters —'));
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

    // The text follows the pass onto the second account.
    gates[0].complete();
    await tester.pumpAndSettle();
    expect(progressLine(tester, 'actions-progress-count'), 'Actie 2 van 2');
    expect(progressLine(tester, 'actions-progress-step'),
        startsWith('Sofie Claes —'));

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
    final harness = twoDepartedHarness(() async {
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

    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
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
    // The app is usable again: the affordances are live and reachable.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
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
      "the Actions overview's freshness stamp carries the date once the shared "
      'state is no longer from today end-to-end (#192)',
      (WidgetTester tester) async {
    // A passive session over a shared view that was materialized in the past.
    // The header line used to read "Generatie 1 · 02:00 door …",
    // which is exactly as reassuring as a stamp from five minutes ago.
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

    await tester.tap(find.text('Acties'));
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

    // The departed account is browsed on the Actions tab, under the
    // "Niet toegewezen" → "Zonder klas" bucket (#210 dropped the always-empty
    // grade level between them).
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Niet toegewezen'));
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
    // its node is kept out of the drill-down (#178). The departed student is
    // re-bucketed to "Niet toegewezen" so its Smartschool cleanup stays
    // actionable — never surfacing a non-managed school node.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('School 2'), findsNothing,
        reason: 'a school we do not manage never appears in Actions (#178)');
    await tester.tap(find.text('Niet toegewezen'));
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

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
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
    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    // Scoped to this screen — the Synchronisatie tab behind it has an
    // "Overzicht" heading of its own since #265.
    expect(
      find.descendant(
        of: find.byType(ActionsScreen),
        matching: find.text('Overzicht'),
      ),
      findsOneWidget,
    );
    // The non-managed school is not a node in the drill-down…
    expect(find.text('School 2'), findsNothing,
        reason: 'school 2 is not managed → no node in Actions');
    // …but the departed student's cleanup stays actionable under the leaver
    // bucket rather than vanishing entirely.
    expect(find.text('Niet toegewezen'), findsOneWidget);
  });

  testWidgets(
      'marking that same school as managed in Settings surfaces its students in '
      'the Actions drill-down end-to-end (#178)', (WidgetTester tester) async {
    // The very same school-2 student, but now school 2 is one of ours: their
    // class must be browsable instead of sitting in the leaver bucket. Proves
    // the managed set from Settings — not the snapshot MarkAsOurs flags —
    // drives which students show. The school itself is no longer a node (#210),
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
    expect(find.text('Niet toegewezen'), findsNothing,
        reason: 'managing school 2 takes its student out of the leaver bucket');
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.text('3C'), findsWidgets);
    // The class the student reached still carries school 2's partition, which
    // is what the per-class read targets.
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
      '"School <id>", while the drill-down shows no school at all (#204/#210)',
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
        reason: 'no school node survives in the student tree (#210)');

    // The stored school rollup — what the counters and the Cosmos documents are
    // keyed and labelled by — still carries the full identity.
    expect(harness.controller.schoolRollups.single.label,
        'Instituut Sancta Maria-A (ISMAA)');

    // And the year drills straight to the student's class.
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.text('3C'), findsWidgets);
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
        reason: 'no school node survives in the student tree (#210)');
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
    // records moved nobody.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    // The merged first year spans both managed schools (#210), so the virtual
    // school's 1V sits beside our own 1A under it.
    final yearNode = find.byKey(const ValueKey('rollup-grade-grades|1'));
    await tester.ensureVisible(yearNode);
    await tester.tap(yearNode);
    await tester.pumpAndSettle();
    final classNode = find.byKey(const ValueKey('rollup-class-class|99|1|1V'));
    await tester.ensureVisible(classNode);
    await tester.tap(classNode);
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsWidgets);
  });

  testWidgets(
      'an empty class beside a sibling school\'s populated namesake stays the '
      'read-only empty notice end-to-end (#222)', (WidgetTester tester) async {
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

    // The notice leads the either/or choice of #244 — the "ignore this class"
    // opt-out is its alternative, not a second to-do — so the collapsed row
    // reads as a choice, and the opt-out is not on it.
    expect(find.textContaining('(keuze)'), findsOneWidget);
    expect(find.textContaining('(manueel)'), findsNothing);
    expect(find.textContaining('Negeer deze klas bij het importeren uit WISA'),
        findsNothing,
        reason: 'blacklisting is the alternative, not a second to-do');

    // Expanding it offers both readings as radios, the notice pre-selected —
    // and the entry has nothing to apply until the operator picks the opt-out.
    await tester.tap(find.byKey(const ValueKey('entry-group-1A')));
    await tester.pumpAndSettle();
    expect(find.text('Kies één oplossing:'), findsOneWidget);
    expect(find.text('Negeer deze klas bij het importeren uit WISA'),
        findsOneWidget);
    // The pre-selected notice writes nothing, and the detail under the radios
    // says so in Dutch (#253) — it used to read "(manual — not applied
    // automatically)" on an otherwise Dutch screen.
    expect(
      find.textContaining('(manueel — wordt niet automatisch toegepast)'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('entry-apply-1A')))
          .onPressed,
      isNull,
      reason: 'there is nothing to write for an empty class',
    );

    // And the pass itself never constructed the create-and-enrol action for it.
    final kinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toList();
    expect(kinds, contains('CreateInSmartschool'));
    expect(kinds, isNot(contains('AddToSmartschool')));
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
    // is manual — there is nothing here for the app to write.
    final kinds = harness.controller.pendingEntries
        .expand((e) => e.choices)
        .expand((c) => c.alternatives)
        .map((a) => a.kind)
        .toList();
    expect(kinds, contains('ClassExistsAsSmartschoolGroup'));
    expect(kinds, isNot(contains('AddToSmartschool')));
    expect(kinds, isNot(contains('CreateInSmartschool')));

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
    final key = harness.controller.groupPendingEntries
        .firstWhere((e) => e.targetId == '1A')
        .situationKey;
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
    // …and not one of them was blacklisted on the way out. A DontImportClass
    // rule re-pulls WISA, so an untouched pull count is the proof.
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
      'untouched end-to-end (#250)', (WidgetTester tester) async {
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
    // This is the layer that sees it. Which half of a choice is pre-selected,
    // which bulk subset a class lands in, and what the button on that subset
    // writes are three different halves of the screen, composed by the
    // dispatch, the entry grouping and the drill-down — only a full run puts
    // the notice and the button that acts on it on screen together.
    useTallWindow(tester);
    final harness = namesakeClassChoiceHarness();
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: harness.bootstrap,
    ));
    await tester.pumpAndSettle();
    await syncThenOpenKlasgroepen(tester);

    // Every class is on the list, and each namesake one reads as the hand-fix
    // notice — the resolution that is pre-selected for it.
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
    expect(find.text('Voeg deze klas toe aan Smartschool (keuze)'),
        findsNWidgets(2),
        reason: '1A and 1B are the ordinary new-class case');
    expect(
        find.text('Negeer deze klas bij het importeren uit WISA'), findsNothing,
        reason: 'the opt-out is an alternative to pick, never a to-do that '
            'also runs');

    // The namesake classes form a bulk subset of their own. Pooling them with
    // the new classes would have filed them under a header offering to create
    // classes that already exist.
    final namesakeKey = harness.controller.groupPendingEntries
        .firstWhere((e) => e.targetId == '2G')
        .situationKey;
    final newKey = harness.controller.groupPendingEntries
        .firstWhere((e) => e.targetId == '1A')
        .situationKey;
    expect(namesakeKey, isNot(newKey));

    final namesakeBulk = find.byKey(ValueKey('situation-apply-$namesakeKey'));
    await tester.ensureVisible(namesakeBulk);
    expect(
      find.textContaining('dan wordt ze gekoppeld. / Negeer deze klas bij '
          'het importeren uit WISA'),
      findsOneWidget,
      reason: 'the header names one either/or led by the hand-fix notice',
    );

    // Run that whole subset. It is not a no-op — each class still needs its
    // Office 365 group (#228), which is a decision of its own — but nothing it
    // writes touches the class's import: no Smartschool class is created, and
    // no DontImportClass rule is written.
    final pulls = harness.wisaSyncs;
    await tester.tap(namesakeBulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(
      harness.controller.applyResults!.map((r) => r.changes.summary),
      isNot(contains('Negeer deze klas bij het importeren uit WISA')),
      reason: 'the rule would drop the classes the app just said to repair',
    );
    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        isEmpty,
        reason: 'Smartschool already holds 2G and 2H');
    // A DontImportClass rule re-pulls WISA, so an untouched pull count is the
    // proof that none was written.
    expect(harness.wisaSyncs, pulls);

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

    // And the fix did not simply silence the list: the other subset still
    // creates the genuinely new classes, and blacklists neither.
    final newBulk = find.byKey(ValueKey('situation-apply-$newKey'));
    await tester.ensureVisible(newBulk);
    await tester.tap(newBulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(2));
    expect(
      harness.controller.applyResults!.map((r) => r.changes.summary),
      isNot(contains('Negeer deze klas bij het importeren uit WISA')),
    );
    expect(harness.wisaSyncs, pulls);
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

    // Each student's own class carries one action and is badged once, so the
    // collapse did not simply deflate every count.
    final jaar1 = find.byKey(const ValueKey('rollup-grade-grades|1'));
    await tester.ensureVisible(jaar1);
    await tester.tap(jaar1);
    await tester.pumpAndSettle();
    final klas1A = find.byKey(const ValueKey('rollup-class-class|1|1|1A'));
    await tester.ensureVisible(klas1A);
    expect(
        find.descendant(of: klas1A, matching: find.text('1')), findsOneWidget);

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
    //
    // The Personeel tree is the deeper one (school → jaar → klas), so this also
    // proves the collapse survives every level of the aggregation rather than
    // only the leaf the operator drills into.
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
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
    await tester.ensureVisible(staffSchool);
    await tester.tap(staffSchool);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('rollup-grade-grade|staff|Personeel')));
    await tester.pumpAndSettle();

    final staffClass = find
        .byKey(const ValueKey('rollup-class-class|staff|Personeel|Personeel'));
    await tester.ensureVisible(staffClass);
    expect(find.descendant(of: staffClass, matching: find.text('2')),
        findsOneWidget,
        reason: 'two hires, one either/or each');
    expect(
        find.descendant(of: staffClass, matching: find.text('4')), findsNothing,
        reason: 'the opt-out is the alternative, never a second to-do');

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

    // The group of a class that no longer exists reads as the either/or it
    // became in #271 — leave it standing (the default) or delete it — so the
    // collapsed line is marked "(keuze)" rather than "(manueel)".
    expect(
      find.textContaining('Laat de Office 365-groep GBS-9Z staan'),
      findsWidgets,
    );
    expect(find.textContaining('(keuze)'), findsWidgets);

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
    // Graph gave.
    final verdict = find.byKey(const ValueKey('entry-outcomes-group-5WW1'));
    await tester.ensureVisible(verdict);
    expect(
      find.descendant(
          of: verdict, matching: find.text('Resultaat van de vorige poging')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: verdict,
          matching: find.textContaining('Authorization_RequestDenied')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: verdict,
          matching: find.text('Voeg deze klas toe aan Smartschool')),
      findsOneWidget,
    );

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

    // And the same list is not maintained in two places: the Klasgroepen node
    // has left the Acties drill-down.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-groups')), findsNothing);
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
    // composed from the *stored* documents while the either/or radios come from
    // the live dispatch, the bulk headers from a third derivation, and the row
    // only disappears once the write, the relink and the store patch have all
    // landed — halves of the app that only a full run puts on screen together.
    // And the action under test is destructive: a widget test rendering the row
    // in isolation cannot show that "Alles toepassen" over the whole tab leaves
    // every one of these groups alone.
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
    // bulk header — and it counts **zero** writes, because leaving the group
    // standing is the default of the pair. A destructive default here would
    // take two mailboxes, Teams and file libraries on one click.
    expect(find.text('Klassen in dezelfde situatie'), findsOneWidget);
    final bulkApply = find.textContaining('Alles toepassen (');
    expect(tester.widget<Text>(bulkApply).data, 'Alles toepassen (0)');
    expect(
      tester
          .widget<FilledButton>(find.ancestor(
            of: bulkApply,
            matching: find.byType(FilledButton),
          ))
          .onPressed,
      isNull,
      reason: 'a bulk pass over stale groups must write nothing at all',
    );

    // The row itself carries the either/or, with the delete as the half the
    // operator has to reach for.
    final entry = find.byKey(const ValueKey('entry-group-GBS-9Z'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(
      find.text('Laat de Office 365-groep GBS-9Z staan — klas 9Z bestaat niet '
          'meer in WISA of Smartschool'),
      findsWidgets,
    );
    final delete =
        find.byKey(const ValueKey('alt-GBS-9Z-DeleteAzureClassGroup'));
    expect(delete, findsOneWidget);
    final apply = find.byKey(const ValueKey('entry-apply-GBS-9Z'));
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull,
        reason:
            'nothing is applyable while the default is "leave it standing"');

    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.ensureVisible(apply);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
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
    // hides them — the switch is what turns the view into the inventory an
    // operator answering a phone call browses (#226).
    expect(find.byKey(const ValueKey('rollup-grade-grades|1')), findsNothing);
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // The year is opened once and stays open across both drill-downs: since
    // #235 pressing Overzicht comes back to the grade-year it was opened from.
    final yearNode = find.byKey(const ValueKey('rollup-grade-grades|1'));
    await tester.ensureVisible(yearNode);
    await tester.tap(yearNode);
    await tester.pumpAndSettle();

    // Sam, in 1B: one line, naming both groups, and marked as a manual fix.
    await tester
        .ensureVisible(find.byKey(const ValueKey('rollup-class-class|1|1|1B')));
    await tester.tap(find.byKey(const ValueKey('rollup-class-class|1|1|1B')));
    await tester.pumpAndSettle();
    expect(find.text('Sam Sels'), findsOneWidget);
    expect(
      find.textContaining(
          'Zit in de verkeerde Office 365-klasgroep: GBS-1A in plaats van '
          'GBS-1B'),
      findsOneWidget,
    );
    expect(find.textContaining('(manueel)'), findsWidgets,
        reason: 'the class row performs the write, so this one diagnoses');

    // Jane, in 1A: the plain "missing from her own group" reading. Overzicht
    // lands back on the still-open year, with her class already listed.
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('rollup-class-class|1|1|1A')));
    await tester.tap(find.byKey(const ValueKey('rollup-class-class|1|1|1A')));
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsOneWidget);
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
      'a passive session marks the same informational candidate "(manueel)" on '
      'the account card end-to-end (#255)', (WidgetTester tester) async {
    // The same #245 fixture, read the way most operators meet it: session 1
    // syncs and materializes the shared view, session 2 is the real app over
    // those stores and never syncs, so Acties renders stored documents as static
    // cards (#214) instead of interactive tiles.
    //
    // This is the layer that sees the bug. The two renderings are different
    // widgets fed by different pipelines — the interactive tile reads live
    // `PendingChoice`s, the passive card reads `CandidateAction`s round-tripped
    // through the store's JSON — and only a full-app run puts an operator in
    // front of the passive one. There Sam's line used to read as ordinary due
    // work beside a badge counting it 0, with no way to tell "the app will do
    // this" from "you must do this by hand".
    useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await azureClassMembershipHarness(
      store: snapshots,
      linkedStore: linkedStore,
    ).controller.sync();

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

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // Nothing applyable hangs off the students, so the work list hides their
    // classes until the inventory toggle is flipped (#226) — exactly the state
    // in which the unmarked line was most misleading.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final yearNode = find.byKey(const ValueKey('rollup-grade-grades|1'));
    await tester.ensureVisible(yearNode);
    await tester.tap(yearNode);
    await tester.pumpAndSettle();
    final klas1B = find.byKey(const ValueKey('rollup-class-class|1|1|1B'));
    await tester.ensureVisible(klas1B);
    await tester.tap(klas1B);
    await tester.pumpAndSettle();

    // The card is the passive one — locked, no interactive entry tile — and
    // Sam's one line now says the operator has to fix this by hand.
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');
    expect(find.byKey(const ValueKey('actions-read-only')), findsOneWidget);
    expect(find.text('Sam Sels'), findsOneWidget);
    expect(
      find.textContaining('Zit in de verkeerde Office 365-klasgroep: GBS-1A '
          'in plaats van GBS-1B'),
      findsOneWidget,
    );
    expect(find.textContaining('(manueel)'), findsOneWidget,
        reason: 'the class row performs the write, so this card diagnoses');
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
  });

  testWidgets(
      'the Acties drill-down opens on grade-years merged across the managed '
      'schools end-to-end, with no school level to guess at (#210)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Two managed schools whose
    // years overlap: school 1 holds 1A and 3C, school 2 holds 1B and the
    // non-numeric OKAN. The WISA school split is administrative — operators
    // treat both as one school — so the overview must open on the years, and a
    // class must be findable by name without first guessing its school.
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
    expect(find.text('Jaar 1'), findsOneWidget);
    expect(find.text('Jaar 3'), findsOneWidget);
    expect(find.text('School 1'), findsNothing);
    expect(find.text('School 2'), findsNothing);
    // The synthetic non-numeric bucket is renamed rather than read as the
    // nonsensical "Jaar Overig" next to the real years.
    expect(find.text('Overige klassen'), findsOneWidget);
    expect(find.text('Jaar Overig'), findsNothing);

    // The merged first year carries both schools' first-year classes and their
    // combined account count.
    expect(harness.controller.studentRollups.first.accountCount, 2);
    await tester.tap(find.text('Jaar 1'));
    await tester.pumpAndSettle();
    expect(find.text('1A'), findsOneWidget);
    expect(find.text('1B'), findsOneWidget);

    // Opening the school-2 class still targets school 2's own partition — the
    // flattening is presentation only, the documents stay partitioned by school.
    await tester.ensureVisible(find.text('1B'));
    await tester.tap(find.text('1B'));
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom?.school, '2');
    expect(harness.controller.classroomAccounts, hasLength(1));
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
  });

  testWidgets(
      'the Acties filter collapses the drill-down to the work list end-to-end: '
      'ticked-off classes and whole ticked-off years are gone, the switch is '
      'set once and survives a tab change (#226)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Four students across three
    // classes of two managed schools; exactly one of them (Sam, in 3C) sits in
    // the wrong Smartschool class, so exactly one class carries work.
    //
    // This is the layer that sees it: the tree the operator browses is built
    // from the stored rollups by two projections one tab apart, the switch
    // lives above the family tab bar and has to outlive a tab change, and
    // "which nodes render" is a whole-page composition question that a widget
    // test of one section structurally cannot answer.
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
      // fixture names every student "Jane Doe"; the tree is browsed by node,
      // not by person, so only the class each of them sits in matters here.)
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

    // Jaar 1's two classes are both done, so the whole year is gone; Jaar 3
    // stays because one of its classes is not.
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|1')), findsNothing,
        reason: 'both of Jaar 1\'s classes are done — the year goes with them');
    // …and the operator is told why a year they expected is missing.
    expect(find.byKey(const ValueKey('actions-filter-hidden')), findsOneWidget);

    // Inside the surviving year, the ticked-off class is gone too.
    await tester.tap(find.byKey(const ValueKey('rollup-grade-grades|3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3C')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|3|3D')), findsNothing,
        reason: 'a class with nothing to do is not rendered under the filter');

    // The switch is a mode, not a per-list setting: it outlives a tab change.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(find.byKey(const ValueKey('rollup-grade-grades|1')), findsNothing);

    // Switched off, the full inventory is back — every year, every class. Jaar
    // 3 was left open above and, being visible under either filter setting,
    // stays open across the switch (#235), so its ticked-off class simply
    // reappears beside the one with work.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-grade-grades|1')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-filter-hidden')), findsNothing);
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3C')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3D')),
        findsOneWidget);
  });

  testWidgets(
      'the Acties tree is a single-open accordion whose grade-year survives a '
      'drill into a class end-to-end (#235)', (WidgetTester tester) async {
    // The real app, real fonts, real navigation. This bug is a composition one:
    // while a class is open the drill-down is not built at all, so the
    // expansion held inside the ExpansionTiles died with them and **Overzicht**
    // came back to a fully collapsed tree. Only an end-to-end run navigates the
    // way that breaks it — a widget test of the tree alone never leaves it.
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

    final jaar1 = find.byKey(const ValueKey('rollup-grade-grades|1'));
    final jaar3 = find.byKey(const ValueKey('rollup-grade-grades|3'));
    final klas1A = find.byKey(const ValueKey('rollup-class-class|1|1|1A'));
    final klas3C = find.byKey(const ValueKey('rollup-class-class|1|3|3C'));

    // Open Jaar 1…
    await tester.ensureVisible(jaar1);
    await tester.tap(jaar1);
    await tester.pumpAndSettle();
    expect(klas1A, findsOneWidget);

    // …then Jaar 3: one open node per level, so Jaar 1 shuts behind it.
    await tester.ensureVisible(jaar3);
    await tester.tap(jaar3);
    await tester.pumpAndSettle();
    expect(klas3C, findsOneWidget);
    expect(klas1A, findsNothing,
        reason: 'several years could stand open at once before #235');

    // Drill into 3C and press Overzicht: the year the operator came from is
    // still open, with its class in view rather than behind a re-expand.
    await tester.ensureVisible(klas3C);
    await tester.tap(klas3C);
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom?.classroom, '3C');
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(klas3C, findsOneWidget,
        reason: 'the tree used to come back fully collapsed');
    expect(klas1A, findsNothing);
    expect(harness.controller.expandedPath, <String>['rollup-grade-grades|3']);
  });

  testWidgets(
      'applying a class\'s work updates its Acties badge on the way back to '
      'the overview, without a re-sync end-to-end (#236)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. The badges are read from the
    // materialized rollups, which only a sync used to rewrite, so a class whose
    // work had just been applied kept advertising it — and since #226 that same
    // stale count decides whether the class is in the tree at all.
    //
    // This is the layer that sees it: the overview and the drilled-in list are
    // two projections composed by different halves of the screen, and the bug is
    // precisely that they disagree. Only a run that syncs, drills in, applies,
    // and comes back out puts both on screen in that order.
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

    final jaar3 = find.byKey(const ValueKey('rollup-grade-grades|3'));
    final klas3C = find.byKey(const ValueKey('rollup-class-class|1|3|3C'));

    // Sam's stale Office 365 name is the only student work: 3C carries it,
    // badged 1, and the class groups carry four writes of their own.
    await tester.ensureVisible(jaar3);
    await tester.tap(jaar3);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: klas3C, matching: find.text('1')), findsOneWidget);
    expect(harness.controller.groupRollup!.pendingCount, 4);

    // Drill into 3C and apply that one entry, confirmation dialog and all.
    await tester.ensureVisible(klas3C);
    await tester.tap(klas3C);
    await tester.pumpAndSettle();
    final entry = harness.controller.classroomPendingEntries.single;
    await tester.tap(find.byKey(ValueKey('entry-student-${entry.targetId}')));
    await tester.pumpAndSettle();
    final applyEntry = find.byKey(ValueKey('entry-apply-${entry.targetId}'));
    await tester.ensureVisible(applyEntry);
    await tester.tap(applyEntry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsWidgets);
    expect(harness.controller.classroomPendingEntries, isEmpty,
        reason: 'the live list drops the work immediately — it always did');

    // Overzicht: the class is done, so under the work-list filter it is gone,
    // and with 3D already clean the whole year goes with it.
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(klas3C, findsNothing,
        reason: 'the class used to come back still badged 1');
    expect(jaar3, findsNothing);
    // …while the work nobody touched is untouched: a re-derivation of what
    // changed, not a blanket reset.
    expect(harness.controller.groupRollup!.pendingCount, 4);

    // Off the filter, the class is back in the inventory — now ticked off
    // rather than badged, with no sync between.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(jaar3);
    if (klas3C.evaluate().isEmpty) {
      await tester.tap(jaar3);
      await tester.pumpAndSettle();
    }
    expect(find.descendant(of: klas3C, matching: find.text('1')), findsNothing);
    expect(find.descendant(of: klas3C, matching: find.byIcon(Icons.check)),
        findsOneWidget);
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
    // fonts, real navigation, real rollup tree — reading the same shared view
    // over the same realtime fan-out, and never syncing or linking at all.
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

    final operatorB = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
      hub: hub,
    );
    await tester.pumpWidget(AccountManagerApp(
      session: SignInSession(_FakeBroker(silent: (_) => _token('AT'))),
      graph: graph,
      reconcileBootstrap: operatorB.bootstrap,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    final jaar3 = find.byKey(const ValueKey('rollup-grade-grades|3'));
    final klas3C = find.byKey(const ValueKey('rollup-class-class|1|3|3C'));

    // B is offered the work, badged 1 — read from the shared documents, with no
    // pull and no link() of its own.
    await tester.ensureVisible(jaar3);
    await tester.tap(jaar3);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: klas3C, matching: find.text('1')), findsOneWidget);

    // A applies it. B is nudged over the realtime fan-out and refetches the one
    // shard that moved.
    await operatorA.controller.applyEntry(
      operatorA.controller.pendingEntries
          .singleWhere((e) => e.family == 'student'),
    );
    await tester.pumpAndSettle();

    // Under the work-list filter the finished class is gone, and with 3D already
    // clean the whole year goes with it — the panel has stopped offering work
    // that is already done.
    expect(klas3C, findsNothing,
        reason: 'B used to keep advertising it until someone re-synced');
    expect(jaar3, findsNothing);
    expect(operatorB.wisaSyncs, 0, reason: 'the nudge never triggers a pull');
    expect(operatorB.controller.linked, isNull,
        reason: 'link() is never called in a passive session');

    // Off the filter the class is back on the inventory, ticked off rather than
    // badged — B's drill-down agrees with the store it just re-read.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(jaar3);
    if (klas3C.evaluate().isEmpty) {
      await tester.tap(jaar3);
      await tester.pumpAndSettle();
    }
    expect(find.descendant(of: klas3C, matching: find.text('1')), findsNothing);
    expect(find.descendant(of: klas3C, matching: find.byIcon(Icons.check)),
        findsOneWidget);

    // …and drilling in shows the card with nothing left to do on it.
    await tester.ensureVisible(klas3C);
    await tester.tap(klas3C);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('actions-read-only')), findsOneWidget);
    expect(find.text('Sam Sels'), findsOneWidget);
    expect(
      operatorB.controller.classroomAccounts!.expand((a) => a.candidates),
      isEmpty,
      reason: 'the stored document itself dropped the applied candidate',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a classroom\'s bulk "Alles toepassen" writes only that classroom, '
      'leaving the identical situation in another class pending (#252)',
      (WidgetTester tester) async {
    // The real app, real fonts, real navigation. Three students share one
    // situation — a stale Office 365 display name — but they are split across
    // two classes: Sam and Sara in 3C, Tom in 3D.
    //
    // This is the layer that sees it. The bulk header is built over *one*
    // class's entries and counts them, while the pass behind it re-resolved the
    // situation key against the whole linked view — so the operator drilled
    // into 3C, read "Alles toepassen (2)", and wrote three accounts including
    // one in a class they never opened. Only a run that drills into a class,
    // presses the class's own bulk button, and then comes back out to look at
    // the other class puts both sides on screen in that order.
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

    final jaar3 = find.byKey(const ValueKey('rollup-grade-grades|3'));
    final klas3C = find.byKey(const ValueKey('rollup-class-class|1|3|3C'));
    final klas3D = find.byKey(const ValueKey('rollup-class-class|1|3|3D'));

    // Two classes, both carrying the same student work: 3C badged 2, 3D 1.
    await tester.ensureVisible(jaar3);
    await tester.tap(jaar3);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: klas3C, matching: find.text('2')), findsOneWidget);
    expect(
        find.descendant(of: klas3D, matching: find.text('1')), findsOneWidget);

    // Drill into 3C. Its bulk header counts this class, and only this class.
    await tester.ensureVisible(klas3C);
    await tester.tap(klas3C);
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom?.classroom, '3C');
    expect(find.text('Sam Sels'), findsWidgets);
    expect(find.text('Sara Segers'), findsWidgets);
    expect(find.text('Tom Tas'), findsNothing,
        reason: 'the operator is looking at 3C — Tom is not on this page');

    final key = harness.controller.classroomPendingEntries.first.situationKey;
    final bulk = find.byKey(ValueKey('situation-apply-$key'));
    await tester.ensureVisible(bulk);
    // The header line the count sits on is Dutch, like the rest of the screen
    // (#253) — the operator-facing language everywhere in this app.
    expect(
        find.textContaining('2 accounts in dezelfde situatie'), findsOneWidget);
    expect(
        find.descendant(of: bulk, matching: find.text('Alles toepassen (2)')),
        findsOneWidget);

    // The confirmation quotes the same two writes the label counts (#234) —
    // the mismatch that surfaced this said "3 wijzigingen" here.
    await tester.tap(bulk);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 wijzigingen'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsWidgets);
    expect(harness.controller.applyResults, hasLength(2));
    final patched = harness.graph.requests
        .where((r) => r.method == 'PATCH')
        .map((r) => r.url.path)
        .toList();
    expect(patched, hasLength(2),
        reason: 'two accounts written, not every account group-wide');
    expect(patched.any((p) => p.endsWith(kSam3C)), isTrue);
    expect(patched.any((p) => p.endsWith(kSara3C)), isTrue);
    expect(patched.any((p) => p.endsWith(kTom3D)), isFalse,
        reason: "Tom's class was never opened, so it must not be written");

    // Overzicht: 3C is done and drops out under the work filter, while 3D still
    // stands there badged 1 — its identical situation is untouched, waiting for
    // someone to open it.
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(jaar3);
    if (klas3D.evaluate().isEmpty) {
      await tester.tap(jaar3);
      await tester.pumpAndSettle();
    }
    expect(klas3C, findsNothing, reason: 'the class the operator cleared');
    expect(
        find.descendant(of: klas3D, matching: find.text('1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

    // Browse it the way the operator does: the merged first year holds both
    // schools' `1C`, each still keyed to its own school partition. The year is
    // opened once — since #235 Overzicht comes back to it still open.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    final yearNode = find.byKey(const ValueKey('rollup-grade-grades|1'));
    await tester.ensureVisible(yearNode);
    await tester.tap(yearNode);
    await tester.pumpAndSettle();
    expect(find.text('1C 00'), findsNothing,
        reason: 'the sentinel never names a class in the drill-down either');

    // Each school's class in turn: opened, and carrying no class-change row.
    for (final school in <String>['1', '2']) {
      if (harness.controller.selectedClassroom != null) {
        await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
        await tester.pumpAndSettle();
      }
      final classNode = find.byKey(ValueKey('rollup-class-class|$school|1|1C'));
      expect(classNode, findsOneWidget);
      await tester.ensureVisible(classNode);
      await tester.tap(classNode);
      await tester.pumpAndSettle();

      // The drill-down really opened (both the populated and the empty branch
      // render this header), so the absence assertions below mean something.
      expect(
          find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
      expect(harness.controller.selectedClassroom?.school, school);
      expect(find.text('Wijzig de klas in Smartschool'), findsNothing,
          reason: 'school $school\'s 1C is single-group — no move is due');
      expect(find.textContaining('1C 00'), findsNothing);
    }
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

    // Default Leerlingen tab: the merged grade-year node drills (#210); the
    // staff node does not appear here.
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-school-school|staff')), findsNothing);

    // Switch to Personeel and drill down to the staff member — the drill-down
    // is preserved within the tab, showing only staff.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsNothing);
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

    // Browse the student on the Actions tab, drilling into her class (3C).
    await tester.tap(find.text('Acties'));
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

    await tester.tap(find.text('Synchronisatie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
    await tester.pumpAndSettle();

    // Browse them on the Actions tab: drill into their "Zonder klas" bucket.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Niet toegewezen'));
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
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Overzicht'), findsOneWidget);
    // The stored view projects to the same school-less tree a syncing session
    // renders (#210).
    expect(find.text('Jaar 3'), findsOneWidget);
    expect(find.text('School 1'), findsNothing);
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(resumed.controller.linked, isNull,
        reason: 'link() is never called in a passive session');

    // Drill down: grade-year → classroom.
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

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // The account overview is there, straight from the store — no Synchronise
    // tapped.
    expect(find.text('Overzicht'), findsOneWidget);

    // And so is the class inventory, on its own tab, listing the orphan
    // Smartschool classes with their notice (#227).
    await openKlasgroepen(tester);

    expect(find.byType(ClassGroupsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('class-row-2B')), findsOneWidget);
    expect(
        find.textContaining('Deze klas bestaat in Smartschool'), findsWidgets);
    // …all without a single connector pull or link().
    expect(resumed.wisaSyncs, 0);
    expect(resumed.ssSyncs, 0);
    expect(resumed.azSyncs, 0);
    expect(resumed.controller.linked, isNull);
  });

  testWidgets(
      'a passive Acties drill-down says it is read-only in both trees, and its '
      'Synchroniseer turns the very same class interactive end-to-end (#214)',
      (WidgetTester tester) async {
    // Session 1 syncs and materializes the shared view; session 2 is the real
    // app over the same stores and never syncs — the everyday passive session
    // that opened Acties to look at the pending work. Both drill-downs used to
    // swap their interactive tiles for static bullet text with no gesture
    // handler and say nothing about it, which reads as an interactive screen
    // whose taps stopped working rather than as a view of the shared state.
    useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

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

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(resumed.controller.linked, isNull);

    final readOnly = find.byKey(const ValueKey('actions-read-only'));
    final pendingTiles = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('entry-'));
    expect(readOnly, findsNothing,
        reason: 'the browsable overview is not the read-only surface');

    // The Klasgroepen tab: static rows, and they say so — the same
    // announcement, keyed per view since #227 put the two on different tabs.
    await openKlasgroepen(tester);
    final klasgroepenReadOnly =
        find.byKey(const ValueKey('class-groups-read-only'));
    expect(klasgroepenReadOnly, findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(pendingTiles, findsNothing);
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();

    // The classroom tree: the same announcement, and the cards themselves carry
    // the muted lock rather than passing for tappable rows.
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(readOnly, findsOneWidget);
    expect(find.textContaining('nog niet gesynchroniseerd'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(pendingTiles, findsNothing,
        reason: 'nothing in this class is actionable — that is the point');

    // Take the offered way out, from the banner itself: WISA is pulled, the
    // session links, and the freshly persisted view closes the drill-down.
    final sync = find.byKey(const ValueKey('actions-read-only-sync'));
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(resumed.wisaSyncs, 1);
    expect(resumed.controller.linked, isNotNull);
    expect(readOnly, findsNothing);

    // The very same class is interactive now: real entry tiles, no notice, no
    // locks — which is what the operator expected the first time round.
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(readOnly, findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(pendingTiles, findsWidgets);
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
    await tester.tap(find.text('Acties'));
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

    // Browse the create on the Actions tab, in the student's class.
    await tester.tap(find.text('Acties'));
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
      'the Actions Personeel classroom filters by any part of the name in any '
      'order and by the top-level only-with-actions switch end-to-end, '
      'combining both (#187/#217/#226)', (WidgetTester tester) async {
    // The real app, real fonts, real window over a passive session: three staff
    // seeded into the one synthetic Personeel class — two share the surname
    // "Smit" (one carrying an action, one not) and one has a distinct voornaam.
    // The operator narrows the list by name and by the has-actions switch, and
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

    // Open the Actions tab (passive overview from the store). The global filter
    // is on by default since #226 and sits above the family tab bar; this test
    // is about the name search, so start from the full inventory.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Go to Personeel — the switch survives the tab change (#226) — and drill
    // into the single staff class.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
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

    // Both halves of one name, typed in the stored order and reversed (#217).
    // Reversed is the half of the time the operator misremembers which way
    // round the name is stored; it used to return an empty list, because the
    // needle was matched as one contiguous substring of "Voornaam Naam".
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'anna smit');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit anna');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    expect(find.text('Bram Jansen'), findsNothing);

    // Every part must occur, so parts taken from two different people match
    // neither — the operator sees the filter-empty line, not both of them.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'anna jansen');
    await tester.pump();
    expect(
        find.text('Geen accounts die aan de filter voldoen.'), findsOneWidget);

    // Back to "Smit", then combine with the global only-with-actions switch
    // back on: only Anna keeps an action, so Clara (name-matched but
    // action-free) drops too.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit');
    await tester.pump();
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    expect(find.text('Bram Jansen'), findsNothing);
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
    // Azure. The WISA schools carry no `MarkAsOurs` flag, so who is managed can
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
    // their class is nowhere in the tree.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Niet toegewezen'), findsOneWidget);
    expect(find.text('Jaar 3'), findsNothing);

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

    // …and the student is out of the leaver bucket and browsable under their
    // own class, with no relaunch anywhere in this test.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(find.text('Niet toegewezen'), findsNothing);
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.text('3C'), findsWidgets);
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
        schools: [wisaSchool(1, ours: true)],
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

    /// Opens Acties → Jaar 3 → 3C and expands the student's pending row, which
    /// is where the proposed `userPrincipalName` is written out.
    Future<void> openStudentRow() async {
      await tester.tap(find.text('Acties'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jaar 3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3C'));
      await tester.pumpAndSettle();
      final id = harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'student')
          .targetId;
      final row = find.byKey(ValueKey('entry-student-$id'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
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
      "the Acties overview's freshness stamp names the werkdatum the shared "
      'view was pulled with, and holds it across a settings save (#247)',
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
    // dd/MM/yyyy, on the same line as the generation and the operator.
    await tester.tap(find.text('Acties'));
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
    // *next* pull's input; the view on Acties is still the one pulled as of
    // 01/09/2025 and must keep saying so.
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

    await tester.tap(find.text('Acties'));
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

    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('· werkdatum 15/09/2025', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets(
      'a Check for drift whose stored Azure delta token Graph refuses still '
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

    // Today: Check for drift, which is what re-reads Azure.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
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

    // A second drift check resumes from that fresh token: the recovery restored
    // incremental syncing rather than condemning the app to full reads.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
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
        schools: [wisaSchool(1, ours: true)],
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
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);

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
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
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
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);

    expect(find.text('Maak een nieuw Office 365 account'), findsNothing,
        reason: 'the account already exists — creating one duplicates it');
    // The record is now WISA + Azure, so the only thing left to build is the
    // Smartschool side — the proposal the adoption unlocks, reading as the
    // create side of the #248 choice it shares with the WISA opt-out.
    expect(find.text('Maak een nieuw Smartschool account (keuze)'),
        findsOneWidget);
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

    // Today: Check for drift, which is what re-reads Azure — incrementally,
    // from the stored token.
    await tester.ensureVisible(find.byKey(const ValueKey('reconcile-drift')));
    await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
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
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
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
    expect(find.text('Wijzig het e-mailadres in Smartschool'), findsOneWidget);
  });

  testWidgets(
      'a staff member who left WISA still gets their Office 365 account '
      'proposed for deletion (#269)', (WidgetTester tester) async {
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
    // The unavoidable trigger is here too: the stored delta token is past Graph's
    // 30-day window, so this pass recovers with a full read (#213) and the
    // previous user list — which had been carrying her — is discarded.
    //
    // Only this layer sees the whole thing: the Azure pull has to remember her
    // from the snapshot it already holds, the linker has to keep the row it
    // produces as an Azure-only staff record (INV-22), and the operator has to be
    // handed the deletion in Acties → Personeel.
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

    // The pass really was the losing one: the stale token was sent and refused,
    // so the recovery re-read in full and the previous user list is gone.
    expect(azureWire.resumeTokens, <String>['AZ-STALE']);
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

    // And that is what the operator sees: Acties → Personeel, drilled the way
    // they would.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
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
    expect(find.text('Verwijder Azure account'), findsOneWidget);
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
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
      reason: 'the class holds exactly the action the report names',
    );
    final id = entry.targetId;
    await tester.ensureVisible(find.byKey(ValueKey('entry-student-$id')));
    await tester.tap(find.byKey(ValueKey('entry-student-$id')));
    await tester.pumpAndSettle();
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
        schools: [wisaSchool(1, ours: true)],
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
    // this: the student is under their own year and class.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
    expect(find.text('Jane Doe'), findsWidgets,
        reason: 'a student with no downstream account is still listed');
    expect(find.text('Maak een nieuw Office 365 account'), findsOneWidget);

    // Apply that one row.
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    await tester.ensureVisible(find.byKey(ValueKey('entry-student-$id')));
    await tester.tap(find.byKey(ValueKey('entry-student-$id')));
    await tester.pumpAndSettle();
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

    // Browse Acties → Personeel: the staff member is under the synthetic staff
    // school, with the first link of the chain offered and only that one.
    await tester.tap(find.text('Acties'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
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
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
    expect(find.text('Anna Smit'), findsWidgets,
        reason: 'a staff member with no downstream account is still listed');
    // …reading as the create side of the either/or choice of #248: the WISA
    // opt-out this family also raises is its alternative, not a second to-do.
    expect(
        find.text('Maak een nieuw Office 365 account (keuze)'), findsOneWidget);
    expect(find.text('Maak een nieuw Smartschool account'), findsNothing,
        reason: 'the dispatch can only see the first link of the chain');

    // Apply that one row.
    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'staff');
    final id = entry.targetId;
    await tester.ensureVisible(find.byKey(ValueKey('entry-staff-$id')));
    await tester.tap(find.byKey(ValueKey('entry-staff-$id')));
    await tester.pumpAndSettle();
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
      'a new staff member offers one either/or choice, and "apply to all" '
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
    final staffSchool =
        find.byKey(const ValueKey('rollup-school-school|staff'));
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
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);

    // Both new hires are on the list, each reading as *one* choice…
    expect(find.text('Anna Smit'), findsWidgets);
    expect(find.text('Bram Jansen'), findsWidgets);
    expect(find.text('Maak een nieuw Office 365 account (keuze)'),
        findsNWidgets(2));
    // …and no row carries the opt-out as a line of its own: it is the
    // alternative the operator can switch to, not a second thing that also
    // runs. (The bulk header below names both sides of the one choice.)
    expect(find.text('Negeer dit account bij het importeren uit WISA'),
        findsNothing);

    // Expanding one offers both readings as radios, the create pre-selected.
    final entries = harness.controller.pendingEntries
        .where((e) => e.family == 'staff')
        .toList();
    expect(entries, hasLength(2));
    final first = find.byKey(ValueKey('entry-staff-${entries.first.targetId}'));
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('Kies één oplossing:'), findsOneWidget);
    expect(find.text('Negeer dit account bij het importeren uit WISA'),
        findsOneWidget);
    await tester.tap(first);
    await tester.pumpAndSettle();

    // The bulk header offers the one resolution for both hires.
    final key = entries.first.situationKey;
    final bulk = find.byKey(ValueKey('situation-apply-$key'));
    await tester.ensureVisible(bulk);
    expect(
      find.textContaining('Maak een nieuw Office 365 account / Negeer dit '
          'account bij het importeren uit WISA'),
      findsOneWidget,
      reason: 'the header names one either/or, not two independent to-dos',
    );

    final pulls = harness.wisaSyncs;
    await tester.tap(bulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    // Both teachers were provisioned end to end — Office 365 and, off the #240
    // chain, Smartschool…
    expect(harness.graph.createdUsers, hasLength(2));
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary).toList();
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
    expect(
      harness.controller.applyResults!.map((r) => r.outcome.name),
      everyElement('applied'),
    );
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
