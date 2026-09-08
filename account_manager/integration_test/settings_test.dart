// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:account_core/account_core.dart' show GroupType, Origin;
import 'package:account_manager/main.dart' as app;
import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart'
    show StoreEndpoints;
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:account_manager/src/settings/settings_bootstrap.dart'
    show SettingsServices;
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:account_state/account_state.dart'
    show
        AppSettings,
        AzureConnection,
        InMemorySecretProvider,
        LiveSettings,
        SecretRef,
        SmartschoolClassTree,
        WisaConnection,
        WisaSchoolProfile,
        WisaSchoolProfileLabel,
        WorkDateSetting;
import 'package:late_arrivals/late_arrivals.dart' show InMemoryJournalStore;
import 'package:smartschool_api/smartschool_api.dart'
    show DiscardSmartschoolGroup, SmartschoolConnector;
import 'package:wisa_api/wisa_api.dart'
    show
        DontImportClass,
        DontImportUserFromWisa,
        WisaImportRule,
        WisaSchool,
        WisaSnapshot,
        parseSchoolRow;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/reconcile/reconcile_fakes.dart';
import '../test/screens/settings_fakes.dart';
import 'support/e2e_support.dart';

/// End-to-end runs of the *real* app for **Instellingen** — the settings
/// screen: its tabs, the WISA school list, the Smartschool and WISA import
/// rules, and the connection coordinates on the Verbinding tab.
///
/// Split out of `app_launch_test.dart` in #421. Several of these relaunch the
/// app over settings written to disk by the previous launch, so a file of their
/// own is closer to what they were already doing; the two import-rule authoring
/// helpers below are used by nothing else. Helpers it shares with the other
/// end-to-end files live in `support/e2e_support.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  group('Instellingen', () {
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Acties'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Acties'));
      await tester.pumpAndSettle();
      final String id = harness.controller.pendingEntries
          .firstWhere((e) => e.family == 'student')
          .targetId;
      final Finder row = find.byKey(ValueKey('account-row-$id'));
      expect(find.descendant(of: row, matching: find.text('Zonder klas')),
          findsNothing,
          reason:
              'managing school 2 takes its student out of the leaver bucket');
      expect(
          find.descendant(of: row, matching: find.text('3C')), findsOneWidget);
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Acties'));
      await tester.pumpAndSettle();
      expect(find.text('School 25'), findsNothing,
          reason:
              'the numeric id is the last resort, not the rendering (#204)');
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
        wisa:
            wisaSnap(students: [wisaStudent(schoolId: 25)], schools: const []),
        smartschool: ssSnap(
            groups: const [], accounts: [ssAccount()], memberships: const []),
        azure: azSnap(users: [azUser()]),
        ourSchoolIds: const {25},
        schoolProfiles: migrated.wisaSchools,
      );
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Acties'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AppShell), findsOneWidget);

      // Open Settings; the stored document is read into the real, laid-out form.
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      // Open Settings; the seeded school renders in the real, laid-out form with
      // its managed switch off.
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      // Open Settings → Wisa tab; the fetch action is available for a valid config.
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
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
      final sibling =
          find.byKey(const ValueKey('settings-wisa-school-27-ours'));
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
        'the Settings/Algemeen werkdatum controls read clearly end-to-end: '
        'renamed virtual label + right-aligned switch instruction (#141)',
        (WidgetTester tester) async {
      // The real app composition over the in-memory settings seams — real fonts,
      // real window, real ListTile layout, which is exactly where a right-align
      // that "works" in a widget test can drift.
      useTallWindow(tester);
      final settings = SettingsHarness();
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      // Open Settings; the werkdatum controls sit on the default Algemeen tab.
      await tester.tap(railTab('Instellingen'));
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
      final instruction = find.descendant(
          of: tile, matching: find.text('volg de huidige datum'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await openSettingsTab(tester, 'settings-tab-smartschool');

      // The section is an editor now, not a read-only list.
      expect(find.text('Importregels'), findsOneWidget);
      expect(find.textContaining('alleen-lezen'), findsNothing);
      expect(find.byKey(const ValueKey('settings-ss-rules-empty')),
          findsOneWidget);

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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
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

      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      // The pull really was pruned by rules spelled nothing like the tree:
      // "Organisatie" and its subtree are gone, "Klassen" survives as a leaf, and
      // the connector never even asked Smartschool about the removed groups.
      expect(
        harness.app.smartschool.snapshot?.groups
            .map((g) => g.id.value)
            .toList(),
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // The operator opens Instellingen and finds the roots already named — the
      // document says what the pull is scoped to rather than leaving an empty box
      // that would mean "everything".
      await tester.tap(railTab('Instellingen'));
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

      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();
      expect(harness.controller.error, isNull);

      // The pull visited the two roots and nothing else — and never even asked
      // Smartschool about the beheerders subtree, which is a SOAP call per node
      // saved as well as an account kept out.
      expect(
        harness.app.smartschool.snapshot?.groups
            .map((g) => g.id.value)
            .toList(),
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
      await tester.tap(railTab('Acties'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // A first Synchroniseer pulls WISA with the stored werkdatum.
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();
      expect(wire.werkdatums, <String>['01/09/2025']);

      // Now the operator moves the werkdatum, the way they do: Instellingen →
      // Algemeen → Kies datum → Opslaan.
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
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
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('reconcile-drift')))
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
      const stored = AppSettings(
        wisa: WisaConnection(server: 'wisa.example', port: '9000'),
        wisaSchools: <WisaSchoolProfile>[
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      // School 2 is not ours yet, so its student is re-bucketed as a leaver and
      // their row names no class of ours.
      await tester.tap(railTab('Acties'));
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
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
      expect(find.byKey(const ValueKey('reconcile-relaunch-required')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('reconcile-drift')));
      await tester.pumpAndSettle();

      // …and the student is out of the leaver bucket, their row naming their own
      // class, with no relaunch anywhere in this test.
      await tester.tap(railTab('Acties'));
      await tester.pumpAndSettle();
      final Finder studentRow = find.byKey(ValueKey(studentRowKey()));
      await tester.ensureVisible(studentRow);
      expect(
          find.descendant(of: studentRow, matching: find.text('Zonder klas')),
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // A first pass, on the rules as they stand: the whole tree comes in.
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();
      expect(
        harness.app.smartschool.snapshot?.groups
            .map((g) => g.id.value)
            .toList(),
        <String>['SCH', 'ORG', 'HID', 'KLA', 'C1A'],
      );

      // The operator authors the rule that drops "Organisatie" and saves.
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
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
        harness.app.smartschool.snapshot?.groups
            .map((g) => g.id.value)
            .toList(),
        <String>['SCH', 'KLA', 'C1A'],
      );
      // …the notice is gone, because the pass applied it…
      expect(
        find.byKey(const ValueKey('reconcile-settings-pending')),
        findsNothing,
      );
      // …and the Log panel never claimed there was nothing to do, which is the
      // half of this bug the operator actually saw.
      expect(
          find.textContaining('geen accountwijzigingen nodig'), findsNothing);
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // A first Synchroniseer, on the rules as they stand: the whole roster comes
      // in, class 3C included.
      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
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
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('reconcile-drift')))
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
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('reconcile-drift')))
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // A first Synchroniseer, on the rules as they stand: the whole roster comes
      // in, class 3C included.
      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
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
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);

      // …and it survives a reload of the document, so the next session (and every
      // other operator) gets the same pull.
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // The production WISA pull runs on the document as stored: the surviving
      // rule still prunes 3C, and the retired one changes nothing (as it never
      // did).
      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // A first Synchroniseer: the whole roster comes in, class 3C included.
      await tester.tap(railTab('Synchronisatie'));
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
      await tester
          .tap(find.byKey(const ValueKey('alt-3C-DoNotImportFromWisa')));
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
      expect(harness.wisaSyncs, pulls,
          reason: 'the apply must not re-pull WISA');
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
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);

      // The operator reads the rule back off the *stored* document — what a
      // relaunch, and every other operator, gets.
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
      await tester.tap(find.byKey(const ValueKey('settings-reload')));
      await tester.pumpAndSettle();
      await openSettingsTab(tester, 'settings-tab-wisa');
      expect(find.text('Klas niet importeren uit WISA: 3C'), findsOneWidget);

      // …and that document still prunes the pull it is read for.
      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();

      // The operator opts class 3C out of the import — the apply that earns a rule.
      await openKlasgroepen(tester);
      final entry = find.byKey(const ValueKey('entry-group-3C'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('alt-3C-DoNotImportFromWisa')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('entry-apply-3C')));
      await tester.tap(find.byKey(const ValueKey('entry-apply-3C')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();
      expect(harness.controller.error, isNull);

      // Read it back off the *stored* document — what a relaunch, and every other
      // operator, gets.
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('settings-reload')));
      await tester.tap(find.byKey(const ValueKey('settings-reload')));
      await tester.pumpAndSettle();
      await openSettingsTab(tester, 'settings-tab-wisa');

      String cell(int index, String field) => tester
          .widget<Text>(
              find.byKey(ValueKey('settings-wisa-rule-$index-$field')))
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
      const stored = AppSettings(
        wisa: WisaConnection(server: 'wisa.example', port: '9000'),
        azure: AzureConnection(domain: 'oud.example'),
        wisaSchools: <WisaSchoolProfile>[
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
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      /// Opens Acties and selects the student's row, which puts the proposed
      /// `userPrincipalName` in the details pane beside it.
      Future<void> openStudentRow() async {
        await tester.tap(railTab('Acties'));
        await tester.pumpAndSettle();
        await selectAccount(
          tester,
          harness.controller.pendingEntries
              .firstWhere((e) => e.family == 'student')
              .targetId,
        );
      }

      // A first Synchroniseer, on the domain as it stands.
      await tester.tap(railTab('Synchronisatie'));
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
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
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

      expect(
          find.textContaining('geen accountwijzigingen nodig'), findsNothing);
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
      const stored = AppSettings(
        wisa: WisaConnection(server: 'wisa.example', port: '9000'),
        azure: AzureConnection(domain: 'oud.example'),
        wisaSchools: <WisaSchoolProfile>[
          WisaSchoolProfile(
              schoolId: 1, code: 'S1', name: 'Sint-Jan', ours: true),
        ],
      );
      final live = LiveSettings(stored);
      // The whole point: the pulls and the applier read `live`, the controller is
      // handed nothing. Constructing this harness is what used to throw.
      final harness =
          ReconcileHarness(modelsSettings: false, liveSettings: live);
      final settings = SettingsHarness(initial: stored, liveSettings: live);
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: settings.bootstrap,
        reconcileBootstrap: harness.bootstrap,
      ));
      await tester.pumpAndSettle();

      // The app is up and the screen the controller drives renders.
      expect(find.byType(AccountManagerApp), findsOneWidget);
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(find.byType(ReconcileScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reconcile-sync')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sync voltooid'), findsOneWidget);

      // Instellingen: the operator moves the school to a new Azure domain and
      // saves — a change that arms the link gate for a *wired* session (#264).
      await tester.tap(railTab('Instellingen'));
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
      await tester.tap(railTab('Synchronisatie'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reconcile-drift-blocked')), findsNothing);
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
        'Instellingen opens with an unreachable Cosmos, and the Verbinding tab '
        'writes a corrected connection.json to disk (#370)',
        (WidgetTester tester) async {
      // The failure this issue exists for, driven end to end in the real app. Every
      // backend coordinate used to be a compile-time constant, so an install
      // pointed at a Cosmos account that is gone (a typo'd endpoint, a decommissioned
      // resource group) had no way back: the settings document could not load, and
      // the screen that would fix it refused to render without one. A public build
      // has no `--dart-define` to fall back on either (#371).
      //
      // Only a full run proves the way out. The widget test binds the screen
      // directly; it cannot show that the rail still reaches Instellingen, that the
      // tab frame survives a failed bootstrap inside the real shell, or that the
      // bytes land in a real file on a real filesystem. Everything here is
      // therefore the real thing except the probe (which would need a live Azure)
      // and the store (which is *supposed* to be broken).
      useTallWindow(tester);

      // A throwaway connection.json, so the run cannot touch the operator's own
      // %APPDATA%. This is a real FileConnectionStore over a real file — the file
      // round-trip is half of what is being asserted.
      final Directory dir = Directory.systemTemp.createTempSync('am-conn-e2e-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final File connectionFile = File(
        '${dir.path}${Platform.pathSeparator}$connectionFileName',
      );

      // The install is pointed at an account that answers nothing.
      final broken = FailingSettingsStore();
      final probe = FakeConnectionProbe(const <ConnectionProbeResult>[
        ConnectionProbeResult(
          id: 'cosmos',
          label: 'Cosmos DB',
          ok: false,
          detail: 'Failed host lookup: weg.documents.azure.com',
        ),
        ConnectionProbeResult(id: 'vault', label: 'Key Vault', ok: true),
      ]);

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: () async => SettingsServices(
          store: broken,
          secrets: InMemorySecretProvider(const <SecretRef, String>{}),
        ),
        connection: ConnectionServices(
          store: FileConnectionStore(connectionFile),
          probe: probe.call,
        ),
      ));
      await tester.pumpAndSettle();

      // The rail still gets there — a failed settings bootstrap is not a locked
      // door.
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
      expect(broken.loads, 1, reason: 'the document was genuinely attempted');

      // …and it opens *on* Verbinding, so the operator does not have to know
      // which tab repairs this.
      final int selected = tester
          .widget<TabBar>(find.byKey(const ValueKey('settings-tabs')))
          .controller!
          .index;
      expect(selected, 5);

      // With no file yet, the fields show what the build shipped.
      final Finder cosmos =
          find.byKey(const ValueKey('settings-connection-cosmos-endpoint'));
      await tester.ensureVisible(cosmos);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(cosmos).controller!.text,
        StoreEndpoints.fromEnvironment().cosmosEndpoint,
      );
      expect(connectionFile.existsSync(), isFalse);

      // Test before committing: the typo costs a button press, not a relaunch.
      final Finder test =
          find.byKey(const ValueKey('settings-connection-test'));
      await tester.ensureVisible(test);
      await tester.tap(test);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Cosmos DB: niet bereikbaar'),
        findsOneWidget,
      );

      // Correct the account and save.
      const String fixed = 'https://hersteld.documents.azure.com:443/';
      await tester.enterText(cosmos, fixed);
      await tester.enterText(
        find.byKey(const ValueKey('settings-connection-cosmos-database')),
        'accountmanager-2',
      );
      probe.results = const <ConnectionProbeResult>[
        ConnectionProbeResult(id: 'cosmos', label: 'Cosmos DB', ok: true),
        ConnectionProbeResult(id: 'vault', label: 'Key Vault', ok: true),
      ];
      await tester.tap(test);
      await tester.pumpAndSettle();
      expect(find.textContaining('Cosmos DB: bereikbaar'), findsOneWidget);
      expect(probe.lastEndpoints!.cosmosEndpoint, fixed);

      final Finder save =
          find.byKey(const ValueKey('settings-connection-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // The bytes are on disk, under the documented keys — the whole coordinate
      // set, so the file is a complete answer rather than a fragment.
      expect(connectionFile.existsSync(), isTrue);
      final decoded =
          jsonDecode(connectionFile.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded[StoreEndpoints.cosmosEndpointKey], fixed);
      expect(decoded[StoreEndpoints.cosmosDatabaseKey], 'accountmanager-2');
      expect(
        decoded[StoreEndpoints.vaultUriKey],
        StoreEndpoints.fromEnvironment().vaultUri,
      );

      // The section now says where the values come from, and is honest about the
      // running session still talking to the old account.
      expect(find.textContaining(connectionFile.path), findsWidgets);
      expect(
        find.byKey(const ValueKey('settings-connection-relaunch')),
        findsOneWidget,
      );

      // A relaunch reads the corrected file back — the resolution order doing its
      // job on the same disk the save just wrote to.
      final ResolvedConnection next =
          await FileConnectionStore(connectionFile).read();
      expect(next.source, ConnectionSource.file);
      expect(next.endpoints.cosmosEndpoint, fixed);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'an install that cannot sign in at all reaches Instellingen and writes a '
        'working Azure AD app registration to disk (#384)',
        (WidgetTester tester) async {
      // The failure v1.0.0 shipped with, driven end to end in the real app. The
      // four AAD values came from `--dart-define` with no default, so an
      // *installed* build — which never meets a command line (#371) — had all four
      // empty, `isConfigured` false, and gated itself into "niet geconfigureerd"
      // on every screen including the only one that could have fixed it.
      //
      // Only a full run proves the way out. A widget test binds one screen; it
      // cannot show that the sign-in gate lets an unconfigured launch through at
      // all, that the rail still reaches Instellingen with every other screen
      // stood down, that the tab frame survives a null bootstrap inside the real
      // shell, or that the bytes land in a real file on a real filesystem. This is
      // the real thing throughout: real gate, real shell, real navigation, real
      // FileConnectionStore over a real file.
      useTallWindow(tester);

      // A throwaway connection.json, so the run cannot touch the operator's own
      // %APPDATA%.
      final Directory dir = Directory.systemTemp.createTempSync('am-aad-e2e-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final File file = File(
        '${dir.path}${Platform.pathSeparator}$connectionFileName',
      );

      // Exactly what `main()` builds on a fresh install: nothing is configured, so
      // `graph`, `reconcileBootstrap` and `settingsBootstrap` are all null — and
      // the connection seams are wired anyway, because they are the way out.
      var forgotten = 0;
      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: null,
        connection: ConnectionServices(
          store: FileConnectionStore(file),
          forgetTokens: () async => forgotten++,
        ),
      ));
      await tester.pumpAndSettle();

      // The gate did not block on an acquisition it has no client id to make, and
      // the landing screen says what is wrong and offers to take the operator
      // there rather than naming a command-line flag they cannot pass.
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('Niet geconfigureerd'), findsOneWidget);
      expect(find.textContaining('--dart-define'), findsNothing);
      final Finder toSettings =
          find.byKey(const ValueKey('reconcile-open-settings'));
      expect(toSettings, findsOneWidget);
      await tester.tap(toSettings);
      await tester.pumpAndSettle();

      // …and it lands on the tab that fixes it, without the operator having to
      // know which one that is.
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        tester
            .widget<TabBar>(find.byKey(const ValueKey('settings-tabs')))
            .controller!
            .index,
        5,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-aad-incomplete')))
            .data,
        contains('Aanmelden is nog niet mogelijk'),
      );
      expect(file.existsSync(), isFalse);

      // Type the app registration in, in the real window and the real font.
      Future<void> type(String key, String value) async {
        final Finder field = find.byKey(ValueKey(key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, value);
        await tester.pump();
      }

      await type('settings-aad-client-id', 'da407efb-e2e-test-client');
      await type('settings-aad-tenant-id', 'arcadia-tenant-id');
      await type('settings-aad-domain', 'arcadia.onmicrosoft.com');
      await type('settings-aad-school-prefix', 'GBS');

      final Finder save =
          find.byKey(const ValueKey('settings-connection-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // The bytes are on disk, under the documented keys, beside the endpoints —
      // one file, one save, a complete answer.
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded[AadAppConfig.clientIdKey], 'da407efb-e2e-test-client');
      expect(decoded[AadAppConfig.tenantIdKey], 'arcadia-tenant-id');
      expect(decoded[AadAppConfig.azureDomainKey], 'arcadia.onmicrosoft.com');
      expect(decoded[AadAppConfig.schoolPrefixKey], 'GBS');
      expect(
        decoded[StoreEndpoints.cosmosEndpointKey],
        StoreEndpoints.fromEnvironment().cosmosEndpoint,
      );

      // Nothing was cached to invalidate on a first install, so the tokens were
      // left alone — the drop is for a tenant that actually moved.
      expect(forgotten, 0);

      // The session is honest about still running on the client id it started
      // with…
      expect(
        find.byKey(const ValueKey('settings-connection-relaunch')),
        findsOneWidget,
      );

      // …and the next launch reads a configured app registration back off the
      // same disk, which is the whole claim: no rebuild, no command line.
      final ResolvedConnection next = await FileConnectionStore(file).read();
      expect(next.aadSource, ConnectionSource.file);
      expect(next.aad.isConfigured, isTrue);
      expect(next.aad.clientId, 'da407efb-e2e-test-client');
      expect(next.aad.tenantId, 'arcadia-tenant-id');

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a launch with a seed beside the executable resolves from it, names it '
        'in Instellingen, and saves over it into %APPDATA% (#387)',
        (WidgetTester tester) async {
      // The whole point of the issue, driven through the app's own entry point:
      // an install that has never been configured on this machine, with a
      // connection.json IT dropped into the install directory. Nothing is typed
      // and the coordinates are right.
      //
      // Only a full run states it. A unit test proves the layering over two temp
      // files and a widget test proves the source line, but neither can show that
      // `main()` resolves the seed *before* runApp, that the resolution survives
      // the real shell and the real rail, or that a save lands in the other file
      // on a real filesystem while the seed IT placed is left byte-for-byte alone.
      // That last one is the upgrade story: the seed is IT's file in a directory
      // the next upgrade or re-deploy rewrites, so a correction written there
      // would not outlive one.
      useTallWindow(tester);

      // Two throwaway directories standing in for `%APPDATA%\AccountManager\` and
      // the install directory, so the run cannot touch either real one.
      final Directory dir = Directory.systemTemp.createTempSync('am-seed-e2e-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File at(String sub) => File(
            '${dir.path}${Platform.pathSeparator}$sub'
            '${Platform.pathSeparator}$connectionFileName',
          );
      final File local = at('appdata');
      final File seed = at('install');

      // What IT drops beside the program. Endpoints only, deliberately: an AAD
      // block here would make the real entry point build a real broker and try to
      // sign in, which on a test machine means a browser window. The Azure AD half
      // of the seed is covered in the next case, in the real shell with a fake
      // broker.
      const StoreEndpoints seeded = StoreEndpoints(
        cosmosEndpoint: 'https://gezaaid.documents.azure.com:443/',
        cosmosDatabase: 'gezaaid-db',
        vaultUri: 'https://gezaaid-kv.vault.azure.net/',
        blobEndpoint: 'https://gezaaid.blob.core.windows.net',
        blobContainer: 'gezaaid-snapshots',
        signalrEndpoint: '',
        signalrHub: 'gezaaid-hub',
      );
      seed.parent.createSync(recursive: true);
      seed.writeAsStringSync(jsonEncode(seeded.toJson()));
      final String seedBefore = seed.readAsStringSync();

      // The real entry point, over this machine's store — plus throwaway
      // late-arrival stores (#409), so the run cannot read this operator's real
      // Smartschool password or roll off their real journal.
      await app.launchAccountManager(
        connection: FileConnectionStore(local, seed: seed),
        credentials: InMemoryOperatorCredentialStore(),
        journal: InMemoryJournalStore(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppShell), findsOneWidget);
      expect(local.existsSync(), isFalse, reason: 'nothing has been saved yet');

      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      // The coordinates on screen are the seed's, not the build's.
      final Finder cosmos =
          find.byKey(const ValueKey('settings-connection-cosmos-endpoint'));
      await tester.ensureVisible(cosmos);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(cosmos).controller!.text,
        seeded.cosmosEndpoint,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(
              const ValueKey('settings-connection-cosmos-database'),
            ))
            .controller!
            .text,
        seeded.cosmosDatabase,
      );

      // …and the tab says which of the two files answered, and where a save would
      // go instead. Without that, "I edited connection.json and nothing changed"
      // has no answer on any screen.
      final String source = tester
          .widget<Text>(
              find.byKey(const ValueKey('settings-connection-source')))
          .data!;
      expect(source, contains(seed.path));
      expect(source, contains(local.path));

      // The seed says nothing about Azure AD, so that half still reads as the
      // build's own (empty) default — the two halves report separately.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-aad-source')))
            .data,
        contains('standaardwaarde'),
      );

      // Correct one coordinate and save: this operator's machine now differs from
      // the fleet.
      await tester.enterText(
          cosmos, 'https://hersteld.documents.azure.com:443/');
      await tester.pump();
      final Finder save =
          find.byKey(const ValueKey('settings-connection-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // The bytes landed in %APPDATA%, and the seed is untouched.
      expect(local.existsSync(), isTrue);
      expect(seed.readAsStringSync(), seedBefore);
      final decoded =
          jsonDecode(local.readAsStringSync()) as Map<String, dynamic>;
      expect(
        decoded[StoreEndpoints.cosmosEndpointKey],
        'https://hersteld.documents.azure.com:443/',
      );
      // The whole answer, so what the seed supplied is preserved rather than
      // collapsing back to the build's defaults on the fields nobody touched.
      expect(decoded[StoreEndpoints.cosmosDatabaseKey], seeded.cosmosDatabase);
      expect(decoded[StoreEndpoints.vaultUriKey], seeded.vaultUri);

      // The next launch reads the correction over the seed — the resolution order
      // doing its job on the same disk the save just wrote to.
      final ResolvedConnection next =
          await FileConnectionStore(local, seed: seed).read();
      expect(next.source, ConnectionSource.file);
      expect(next.endpoints.cosmosEndpoint,
          'https://hersteld.documents.azure.com:443/');
      expect(next.endpoints.cosmosDatabase, seeded.cosmosDatabase);
      expect(next.seedLocation, seed.path);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a seeded app registration means a fresh install has nothing to type '
        '(#387)', (WidgetTester tester) async {
      // The other half of the issue, and the reason it was filed at all: since
      // #384 an unconfigured install cannot sign in until somebody types four
      // values, and #387 is what lets IT answer them once for a whole fleet.
      //
      // Driven in the real shell — real rail, real tab frame, real font, real
      // file on disk — rather than through `main()`, for one deliberate reason: a
      // configured app registration makes the real entry point build a real broker
      // and attempt an acquisition, which on a machine with no cached token means
      // opening a browser. The claim under test is what the operator sees and what
      // the *next* launch would resolve, and both are reachable without that.
      useTallWindow(tester);

      final Directory dir = Directory.systemTemp.createTempSync('am-seed-aad-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File at(String sub) => File(
            '${dir.path}${Platform.pathSeparator}$sub'
            '${Platform.pathSeparator}$connectionFileName',
          );
      final File local = at('appdata');
      final File seed = at('install');

      const AadAppConfig seededAad = AadAppConfig(
        clientId: 'gezaaide-client-id',
        tenantId: 'gezaaide-tenant-id',
        azureDomain: 'arcadia.onmicrosoft.com',
        schoolPrefix: 'GBS',
      );
      seed.parent.createSync(recursive: true);
      seed.writeAsStringSync(jsonEncode(seededAad.toJson()));

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        connection:
            ConnectionServices(store: FileConnectionStore(local, seed: seed)),
      ));
      await tester.pumpAndSettle();

      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      // Four fields, filled in by a file nobody on this machine wrote.
      String field(String key) =>
          tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
      final Finder clientId =
          find.byKey(const ValueKey('settings-aad-client-id'));
      await tester.ensureVisible(clientId);
      await tester.pumpAndSettle();
      expect(field('settings-aad-client-id'), seededAad.clientId);
      expect(field('settings-aad-tenant-id'), seededAad.tenantId);
      expect(field('settings-aad-domain'), seededAad.azureDomain);
      expect(field('settings-aad-school-prefix'), seededAad.schoolPrefix);

      // …and the tab says so, naming the file beside the program rather than the
      // one a save would write.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-aad-source')))
            .data,
        contains(seed.path),
      );

      // Nothing left to do: the "you cannot sign in yet" line is absent, and no
      // %APPDATA% file was created to make it so.
      expect(
          find.byKey(const ValueKey('settings-aad-incomplete')), findsNothing);
      expect(local.existsSync(), isFalse);

      // Which is the claim, stated the way the next launch would: `main()` reads
      // this and hands `config.graph` to the shell instead of gating on "niet
      // geconfigureerd".
      final ResolvedConnection resolved =
          await FileConnectionStore(local, seed: seed).read();
      expect(resolved.aad, seededAad);
      expect(resolved.aad.isConfigured, isTrue);
      expect(resolved.aadSource, ConnectionSource.seed);

      expect(tester.takeException(), isNull);
    });
  });
}
