import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import 'settings_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A tall viewport so the long settings form lays out without needing to scroll
/// every field into view before entering text.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Switches the settings view to the tab with [tabKey] (#140: the config is now
/// split across Algemeen / Wisa / Smartschool / Azure tabs).
Future<void> _openTab(WidgetTester tester, String tabKey) async {
  await tester.tap(find.byKey(ValueKey(tabKey)));
  await tester.pumpAndSettle();
}

/// Authors one Smartschool import rule through the editor (#202): opens the
/// **Toevoegen** menu, picks the rule type keyed [kind], types [groupName] into
/// the prompt and confirms — exactly what the operator does.
Future<void> _addSmartschoolRule(
  WidgetTester tester,
  String kind,
  String groupName,
) async {
  final add = find.byKey(const ValueKey('settings-ss-rule-add'));
  await tester.ensureVisible(add);
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

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-save')), findsNothing);
  });

  testWidgets('populates the form from the stored document',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: AppSettings(
        schoolPrefix: 'GBS',
        wisa: const WisaConnection(server: 'db.school.example', port: '1433'),
        smartschool: SmartschoolConnection(studentGroup: 'Leerlingen'),
        azure: const AzureConnection(domain: 'school.onmicrosoft.com'),
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Algemeen is the default tab.
    expect(find.text('GBS'), findsOneWidget);

    // Each connector's config lives under its own tab now (#140).
    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('db.school.example'), findsOneWidget);

    await _openTab(tester, 'settings-tab-smartschool');
    expect(find.text('Leerlingen'), findsOneWidget);

    await _openTab(tester, 'settings-tab-azure');
    expect(find.text('school.onmicrosoft.com'), findsOneWidget);
  });

  testWidgets('the settings view exposes the four config tabs',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    for (final key in const <String>[
      'settings-tab-algemeen',
      'settings-tab-wisa',
      'settings-tab-smartschool',
      'settings-tab-azure',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
  });

  testWidgets('edit → save round-trips a profile field to the store',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: const AppSettings(schoolPrefix: 'OLD'),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('settings-school-prefix')),
      'NEW',
    );
    await _openTab(tester, 'settings-tab-wisa');
    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-server')),
      'wisa.host',
    );
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.schoolPrefix, 'NEW');
    expect(saved.wisa.server, 'wisa.host');
  });

  testWidgets('Smartschool group paths and useGrades round-trip',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-student-group')),
      'Leerlingen/2025',
    );
    await tester.tap(find.byKey(const ValueKey('settings-ss-use-grades')));
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-grade-0')),
      'Graad 1',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.smartschool.studentGroup, 'Leerlingen/2025');
    expect(saved.smartschool.useGrades, isTrue);
    expect(saved.smartschool.grades.first, 'Graad 1');
  });

  testWidgets('a stored secret is never echoed back into the UI',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final harness = SettingsHarness(
      secrets: {passwordRef: 'super-secret-value'},
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // The value is nowhere in the rendered tree, and the field is empty.
    expect(find.text('super-secret-value'), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('settings-wisa-password')),
    );
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
  });

  testWidgets(
      'typing a secret writes it through the provider but not into the blob',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    const passphraseRef = SecretRef('smartschool.passphrase');
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-password')),
      'new-wisa-pw',
    );
    await _openTab(tester, 'settings-tab-smartschool');
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-passphrase')),
      'new-passphrase',
    );
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // Written through the SecretProvider seam…
    expect(await harness.secrets.read(passwordRef), 'new-wisa-pw');
    expect(await harness.secrets.read(passphraseRef), 'new-passphrase');
    // …and NOT serialized into the settings document.
    final saved = await harness.store.load();
    expect(saved.toJson().toString(), isNot(contains('new-wisa-pw')));
    expect(saved.toJson().toString(), isNot(contains('new-passphrase')));

    // The fields are cleared after a successful save (never re-shown).
    await _openTab(tester, 'settings-tab-wisa');
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('settings-wisa-password')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('leaving the secret blank on save keeps the stored value',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final harness = SettingsHarness(
      secrets: {passwordRef: 'existing-pw'},
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('settings-school-prefix')),
      'GBS',
    );
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // The untouched secret survives the save.
    expect(await harness.secrets.read(passwordRef), 'existing-pw');
  });

  testWidgets('reload discards unsaved edits and re-reads the store',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: const AppSettings(schoolPrefix: 'STORED'),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('settings-school-prefix')),
      'DIRTY',
    );
    await tester.pump();
    expect(find.text('DIRTY'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-reload')));
    await tester.pumpAndSettle();

    expect(find.text('DIRTY'), findsNothing);
    expect(find.text('STORED'), findsOneWidget);
  });

  testWidgets(
      'the stored known-school list renders by name in a grid on open, no '
      're-fetch (#171)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // Two schools already persisted (with names): one managed, one not. Opening
    // the tab shows the complete list by name — no fetch needed.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42, name: 'Sint-Jan', ours: true),
          WisaSchoolProfile(schoolId: 43, name: 'Sint-Pieter'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('Sint-Jan'), findsOneWidget);
    expect(find.text('Sint-Pieter'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-wisa-school-42-ours')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('settings-wisa-school-43-ours')),
        findsOneWidget);
    // The managed one shows ticked, the other not.
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-42-ours')))
            .value,
        isTrue);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-43-ours')))
            .value,
        isFalse);
  });

  testWidgets('toggling a WISA school\'s "ours" flag round-trips to the store',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42, name: 'Sint-Jan'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // The seeded (unmanaged) school renders with its checkbox off.
    final ourBox = find.byKey(const ValueKey('settings-wisa-school-42-ours'));
    expect(ourBox, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(ourBox).value, isFalse);

    // Flip it on and save.
    await tester.tap(ourBox);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.schoolId, 42);
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets(
      'each school cell carries a virtual toggle, independent of the managed '
      'one, and marking it round-trips to the store (#203)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // One school is managed but not virtual, the other virtual but unmanaged —
    // the two marks are separate facts about the same school.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42, name: 'Sint-Jan', ours: true),
          WisaSchoolProfile(
              schoolId: 99, name: 'Virtuele school SMA', virtual: true),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    final virtual42 =
        find.byKey(const ValueKey('settings-wisa-school-42-virtual'));
    final virtual99 =
        find.byKey(const ValueKey('settings-wisa-school-99-virtual'));
    expect(virtual42, findsOneWidget);
    expect(virtual99, findsOneWidget);
    // Managed ≠ virtual, in both directions.
    expect(tester.widget<CheckboxListTile>(virtual42).value, isFalse);
    expect(tester.widget<CheckboxListTile>(virtual99).value, isTrue);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-99-ours')))
            .value,
        isFalse);

    // Mark the managed school virtual too and save.
    await tester.tap(virtual42);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.virtualWisaSchoolIds, {42, 99});
    // Flipping "virtueel" left the managed marks exactly as they were.
    expect(saved.managedWisaSchoolIds, {42});
  });

  testWidgets('clearing the virtual mark round-trips to the store (#203)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42, name: 'Sint-Jan', virtual: true),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    await tester
        .tap(find.byKey(const ValueKey('settings-wisa-school-42-virtual')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.virtual, isFalse);
    expect(saved.virtualWisaSchoolIds, isEmpty);
  });

  testWidgets('a refetch preserves the virtual mark (#203)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 99, name: 'Virtuele school SMA', code: 'ismav'),
    ]);
    // Marked virtual on a previous run, stored without a code.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
        wisaSchools: [WisaSchoolProfile(schoolId: 99, virtual: true)],
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    await tester.tap(find.byKey(const ValueKey('settings-wisa-fetch-schools')));
    await tester.pumpAndSettle();

    // "Scholen ophalen" backfilled the code and kept the virtual mark ticked.
    expect(find.text('ismav'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-99-virtual')))
            .value,
        isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.code, 'ismav');
    expect(saved.wisaSchools.single.virtual, isTrue);
  });

  testWidgets('a freshly fetched school is not virtual until marked (#203)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 3, name: 'Sint-Jan', code: 'SJ'),
    ]);
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    await tester.tap(find.byKey(const ValueKey('settings-wisa-fetch-schools')));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-3-virtual')))
            .value,
        isFalse,
        reason: 'a new school pulls with the ordinary work date until marked');
  });

  testWidgets('a profile stored without a name falls back to "School <id>"',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // A profile predating the persisted name (#171): the row still renders.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [WisaSchoolProfile(schoolId: 9)],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('School 9'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-wisa-school-9-ours')),
        findsOneWidget);
  });

  testWidgets(
      'a school cell is titled by its WISA code with the long name beneath '
      '(#194)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // The code (`ismaa`) is how the schools are identified day to day, so it
    // leads; the long name is the secondary line and the numeric id is gone.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42, code: 'ismaa', name: 'Sint-Jan'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    final tile = find.byKey(const ValueKey('settings-wisa-school-42-ours'));
    expect(tile, findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('ismaa')),
        findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('Sint-Jan')),
        findsOneWidget);
    expect(find.text('id: 42'), findsNothing);
    expect(find.text('School 42'), findsNothing);
  });

  testWidgets(
      'a school known only by its id shows that id once, not twice (#194)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // Neither code nor name stored: the id is the only identifier left, so it
    // must appear exactly once instead of as both title and subtitle.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [WisaSchoolProfile(schoolId: 9)],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('School 9'), findsOneWidget);
    expect(find.text('id: 9'), findsNothing);
  });

  testWidgets(
      'a code-less profile falls back to the name, with the id as the '
      'secondary line (#194)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // Written before #194: name but no code. The name leads and the id is the
    // secondary line — still no duplication.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [WisaSchoolProfile(schoolId: 43, name: 'Sint-Pieter')],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('Sint-Pieter'), findsOneWidget);
    expect(find.text('id: 43'), findsOneWidget);
    expect(find.text('School 43'), findsNothing);
  });

  testWidgets('fetch backfills the school code and save persists it (#194)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    // `SMAGetInst` puts the short code in the CSV DESCRIPTION column, which the
    // connector untangles onto `WisaSchool.code` (#208).
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 7, name: 'Sint-Pieter', code: 'ismab'),
    ]);
    // Stored before #194: managed, named, but with no code.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
        wisaSchools: [
          WisaSchoolProfile(schoolId: 7, name: 'Sint-Pieter', ours: true),
        ],
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('ismab'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-wisa-fetch-schools')));
    await tester.pumpAndSettle();

    // The code now sits under the name and the managed mark survived the merge.
    expect(find.text('ismab'), findsOneWidget);
    expect(find.text('Sint-Pieter'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-7-ours')))
            .value,
        isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.code, 'ismab');
    expect(saved.wisaSchools.single.name, 'Sint-Pieter');
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets('no manual add-by-id UI remains (#171)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // No schools yet — the empty note shows.
    expect(find.byKey(const ValueKey('settings-wisa-schools-empty')),
        findsOneWidget);
    // The add-by-id field/button are gone.
    expect(
        find.byKey(const ValueKey('settings-wisa-school-add')), findsNothing);
    expect(find.byKey(const ValueKey('settings-wisa-school-add-btn')),
        findsNothing);
    expect(find.text('Toevoegen'), findsNothing);
  });

  testWidgets(
      'the fetch-schools action is disabled with a hint until the WISA config '
      'is valid (#142)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // A blank WISA profile (no server/port) — config is not yet valid.
    final harness = SettingsHarness(
      fetchWisaSchools: FakeWisaSchoolFetcher(const []).call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    final button = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull,
        reason: 'no valid config yet ⇒ fetch disabled');
    expect(
        find.byKey(const ValueKey('settings-wisa-fetch-hint')), findsOneWidget);
  });

  testWidgets(
      'fetch merges the school list by name, mark one → save persists name + '
      'ours, new schools unmanaged (#171)', (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 3, name: 'Sint-Jan', code: 'SJ'),
      WisaSchool(id: 7, name: 'Sint-Pieter', code: 'SP'),
    ]);
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // A valid config lights the fetch button up.
    final button = find.byKey(const ValueKey('settings-wisa-fetch-schools'));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    expect(
        find.byKey(const ValueKey('settings-wisa-fetch-hint')), findsNothing);

    await tester.tap(button);
    await tester.pumpAndSettle();

    // The fetcher ran (with the stored password resolved) and both schools now
    // render by name in the grid, unmanaged by default.
    expect(fetcher.calls, 1);
    expect(fetcher.lastPassword, 'stored-pw');
    expect(fetcher.lastConnection?.server, 'db.school.example');
    expect(find.text('Sint-Jan'), findsOneWidget);
    expect(find.text('Sint-Pieter'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-7-ours')))
            .value,
        isFalse,
        reason: 'a freshly fetched school is unmanaged until marked');

    // Mark one managed; save persists both the name and the ours flag.
    await tester.tap(find.byKey(const ValueKey('settings-wisa-school-7-ours')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.length, 2);
    final managed = saved.wisaSchools.firstWhere((p) => p.schoolId == 7);
    expect(managed.name, 'Sint-Pieter');
    expect(managed.ours, isTrue);
    final other = saved.wisaSchools.firstWhere((p) => p.schoolId == 3);
    expect(other.name, 'Sint-Jan');
    expect(other.ours, isFalse);
  });

  testWidgets(
      'refetch preserves the existing ours mark and fills in the name (#171)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    const passwordRef = SecretRef('wisa.password');
    final fetcher = FakeWisaSchoolFetcher(const <WisaSchool>[
      WisaSchool(id: 7, name: 'Sint-Pieter', code: 'SP'),
    ]);
    // Id 7 is already managed from a previous run, but stored without a name.
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisa: WisaConnection(server: 'db.school.example', port: '1433'),
        wisaSchools: [WisaSchoolProfile(schoolId: 7, ours: true)],
      ),
      secrets: {passwordRef: 'stored-pw'},
      fetchWisaSchools: fetcher.call,
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // Before the refetch it renders by id (no stored name) and stays ticked.
    expect(find.text('School 7'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-wisa-fetch-schools')));
    await tester.pumpAndSettle();

    // The refetch fills in the name and keeps the managed mark.
    expect(find.text('Sint-Pieter'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('settings-wisa-school-7-ours')))
            .value,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.schoolId, 7);
    expect(saved.wisaSchools.single.name, 'Sint-Pieter');
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets('accumulated import rules render read-only',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: AppSettings(
        wisaRules: <WisaImportRule>[
          const DontImportClass('OKAN'),
          const MarkAsVirtual('VIRT'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // WISA import rules live under the Wisa tab now (#140).
    await _openTab(tester, 'settings-tab-wisa');
    expect(find.textContaining('OKAN'), findsOneWidget);
    expect(find.textContaining('VIRT'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('settings-wisa-rules-empty')), findsNothing);
  });

  testWidgets(
      'the secret fields read "(alleen schrijven)", not the ungrammatical '
      '"(schrijf-alleen)" (#143)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // WISA password label (on the Wisa tab).
    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('Wachtwoord (alleen schrijven)'), findsOneWidget);
    expect(find.text('Wachtwoord (schrijf-alleen)'), findsNothing);

    // Smartschool passphrase label (on the Smartschool tab).
    await _openTab(tester, 'settings-tab-smartschool');
    expect(find.text('Passphrase (alleen schrijven)'), findsOneWidget);
    expect(find.text('Passphrase (schrijf-alleen)'), findsNothing);
  });

  testWidgets(
      'the virtual werkdatum field is labelled "Werkdatum Virtuele '
      'School" (#141)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The werkdatum controls live on the default Algemeen tab (#140).
    expect(find.text('Werkdatum Virtuele School'), findsOneWidget);
    expect(find.text('Virtuele werkdatum'), findsNothing);
  });

  testWidgets(
      'the werkdatum switch tile right-aligns "volg de huidige datum" next to '
      'its switch, not the field label (#141)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Scope everything to the primary werkdatum switch tile.
    final tile = find.byKey(const ValueKey('settings-workdate-is-now'));
    expect(tile, findsOneWidget);

    final label = find.descendant(of: tile, matching: find.text('Werkdatum'));
    final instruction =
        find.descendant(of: tile, matching: find.text('volg de huidige datum'));
    final switchWidget =
        find.descendant(of: tile, matching: find.byType(Switch));
    expect(label, findsOneWidget);
    expect(instruction, findsOneWidget);
    expect(switchWidget, findsOneWidget);

    // The instruction is a separate widget (not merged into the field label),
    // right-aligned into the right portion of the tile so it reads against the
    // switch (currently off ⇒ today's date is *not* followed).
    final tileLeft = tester.getTopLeft(tile).dx;
    final tileCenter = tester.getCenter(tile).dx;
    final instrCenter = tester.getCenter(instruction).dx;
    expect(instrCenter, greaterThan(tileCenter),
        reason: 'the instruction sits in the right portion, by the switch');

    // And it hugs the trailing switch: nearer the switch than the tile's left
    // edge where the field label lives.
    final switchLeft = tester.getTopLeft(switchWidget).dx;
    final instrRight = tester.getTopRight(instruction).dx;
    expect(switchLeft - instrRight, lessThan(instrCenter - tileLeft),
        reason: 'the instruction hugs the switch, away from the field label');
  });

  // ---------------------------------------------------------------------------
  // Smartschool import-rule editor (#202)
  // ---------------------------------------------------------------------------

  testWidgets(
      'the Smartschool import rules are an editor now, not an "alleen-lezen" '
      'list (#202)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    expect(find.text('Importregels'), findsOneWidget);
    expect(find.textContaining('alleen-lezen'), findsNothing);
    // Nothing configured yet, and the add affordance is there to change that.
    expect(
        find.byKey(const ValueKey('settings-ss-rules-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-ss-rule-add')), findsOneWidget);
  });

  testWidgets('Toevoegen offers exactly the two legacy rule types (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-add')));
    await tester.pumpAndSettle();

    // The Dutch labels the legacy ImportRuleSelectDialog offered.
    expect(find.text('Negeer groep'), findsOneWidget);
    expect(find.text('Negeer subgroepen'), findsOneWidget);
  });

  testWidgets(
      'authoring both rule types round-trips through the existing codec (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    await _addSmartschoolRule(tester, 'discardGroup', 'Organisatie');
    await _addSmartschoolRule(tester, 'noSubgroups', 'Klassen');

    // Both render in the list before the save.
    expect(find.textContaining('Smartschool-groep negeren: Organisatie'),
        findsOneWidget);
    expect(find.textContaining('Geen subgroepen: Klassen'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-ss-rules-empty')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.smartschoolRules, hasLength(2));
    expect(
      (saved.smartschoolRules[0] as DiscardSmartschoolGroup).groupName,
      'Organisatie',
    );
    expect(
      (saved.smartschoolRules[1] as NoSmartschoolSubgroups).groupName,
      'Klassen',
    );
    // …on the wire shape the codec already defined — no new tags (#202).
    expect(saved.toJson()['smartschoolRules'], <Map<String, dynamic>>[
      {'type': 'discardSmartschoolGroup', 'groupName': 'Organisatie'},
      {'type': 'noSmartschoolSubgroups', 'groupName': 'Klassen'},
    ]);
  });

  testWidgets('editing a rule rewrites its group name, keeping its type (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: AppSettings(
        smartschoolRules: <SmartschoolImportRule>[
          const DiscardSmartschoolGroup('Oude naam'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    expect(find.textContaining('Smartschool-groep negeren: Oude naam'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-0-edit')));
    await tester.pumpAndSettle();
    // The prompt opens on the current name, so fixing a typo is a correction
    // rather than a re-entry.
    expect(find.text('Oude naam'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-rule-name')),
      'Nieuwe naam',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    final rule = saved.smartschoolRules.single;
    expect(rule, isA<DiscardSmartschoolGroup>());
    expect((rule as DiscardSmartschoolGroup).groupName, 'Nieuwe naam');
  });

  testWidgets('removing a rule drops it from the saved document (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: AppSettings(
        smartschoolRules: <SmartschoolImportRule>[
          const DiscardSmartschoolGroup('Organisatie'),
          const NoSmartschoolSubgroups('Klassen'),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-1-remove')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Geen subgroepen: Klassen'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.smartschoolRules, hasLength(1));
    expect(
      (saved.smartschoolRules.single as DiscardSmartschoolGroup).groupName,
      'Organisatie',
    );
  });

  testWidgets('a rule cannot be saved without a group name (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness();
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-smartschool');
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-add')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('settings-ss-rule-add-discardGroup')));
    await tester.pumpAndSettle();

    FilledButton confirm() => tester.widget<FilledButton>(
          find.byKey(const ValueKey('settings-ss-rule-confirm')),
        );
    // Empty, then blank-only: a rule with no group name matches nothing, so it
    // is refused rather than silently doing no work.
    expect(confirm().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-rule-name')),
      '   ',
    );
    await tester.pump();
    expect(confirm().onPressed, isNull);

    // A real name arms it; cancelling still leaves the list untouched.
    await tester.enterText(
      find.byKey(const ValueKey('settings-ss-rule-name')),
      'Organisatie',
    );
    await tester.pump();
    expect(confirm().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('settings-ss-rule-cancel')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('settings-ss-rules-empty')), findsOneWidget);
  });

  testWidgets('the WISA rule list stays read-only (#202)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: AppSettings(
        wisaRules: <WisaImportRule>[const DontImportClass('OKAN')],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    expect(find.text('Importregels (alleen-lezen)'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-ss-rule-add')), findsNothing);
  });
}
