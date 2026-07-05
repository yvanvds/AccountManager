import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
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

  testWidgets('toggling a WISA school\'s "ours" flag round-trips to the store',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = SettingsHarness(
      initial: const AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 42),
        ],
      ),
    );
    await tester
        .pumpWidget(_wrap(SettingsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _openTab(tester, 'settings-tab-wisa');
    // The seeded (unmanaged) school renders with its switch off.
    final ourSwitch =
        find.byKey(const ValueKey('settings-wisa-school-42-ours'));
    expect(ourSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(ourSwitch).value, isFalse);

    // Flip it on and save.
    await tester.tap(ourSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.schoolId, 42);
    expect(saved.wisaSchools.single.ours, isTrue);
  });

  testWidgets('adding a WISA school by id appends a managed entry',
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

    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-school-add')),
      '7',
    );
    await tester
        .tap(find.byKey(const ValueKey('settings-wisa-school-add-btn')));
    await tester.pumpAndSettle();

    // The new row appears, defaults to managed, and saves.
    expect(find.byKey(const ValueKey('settings-wisa-school-7-ours')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final saved = await harness.store.load();
    expect(saved.wisaSchools.single.schoolId, 7);
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
}
