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

    expect(find.text('GBS'), findsOneWidget);
    expect(find.text('db.school.example'), findsOneWidget);
    expect(find.text('Leerlingen'), findsOneWidget);
    expect(find.text('school.onmicrosoft.com'), findsOneWidget);
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

    await tester.enterText(
      find.byKey(const ValueKey('settings-wisa-password')),
      'new-wisa-pw',
    );
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

    expect(find.textContaining('OKAN'), findsOneWidget);
    expect(find.textContaining('VIRT'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-rules-empty')), findsNothing);
  });
}
