import 'package:account_manager/src/screens/settings_screen.dart';
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:account_manager/src/update/update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../update/update_fakes.dart';
import 'settings_fakes.dart';

/// The **Versie** section of Instellingen → Verbinding (#371).
///
/// It sits on the Verbinding tab for the reason that tab exists at all: it must
/// be readable on an install whose settings document will not load, because
/// "which version is this operator on?" is the first question a broken install
/// raises.
Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _openVerbinding(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('settings-tab-verbinding')));
  await tester.pumpAndSettle();
}

String _noteText(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Future<void> _pumpSettings(
  WidgetTester tester, {
  UpdateController? update,
}) async {
  _useTallWindow(tester);
  await tester.pumpWidget(_wrap(SettingsScreen(
    bootstrap: SettingsHarness().bootstrap,
    connection: ConnectionServices(store: InMemoryConnectionStore()),
    update: update,
  )));
  await tester.pumpAndSettle();
  await _openVerbinding(tester);
}

void main() {
  testWidgets('the app displays its own version', (WidgetTester tester) async {
    final backend = FakeUpdateBackend(version: '1.4.2');
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);

    expect(_noteText(tester, 'settings-version-current'), contains('1.4.2'));
  });

  testWidgets(
      'a build whose version cannot be read says so, and offers no '
      'invented number', (WidgetTester tester) async {
    final backend = FakeUpdateBackend(version: null);
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);

    expect(_noteText(tester, 'settings-version-current'), contains('onbekend'));
  });

  testWidgets(
      'a build with no update mechanism renders the section without a '
      'check button', (WidgetTester tester) async {
    await _pumpSettings(tester);

    // Present rather than absent: the section is where the version lives, and a
    // build that cannot update still has one.
    expect(
      find.byKey(const ValueKey('settings-version-current')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-version-check')), findsNothing);
    expect(find.byKey(const ValueKey('settings-version-apply')), findsNothing);
  });

  testWidgets('the manual check reports being up to date',
      (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '2.0.0',
      latest: fakeRelease('2.0.0'),
    );
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);
    expect(
      _noteText(tester, 'settings-version-status'),
      contains('nog niet gecontroleerd'),
    );

    await tester.tap(find.byKey(const ValueKey('settings-version-check')));
    await tester.pumpAndSettle();

    expect(backend.feedCalls, 1);
    expect(_noteText(tester, 'settings-version-status'), contains('nieuwste'));
    expect(find.byKey(const ValueKey('settings-version-apply')), findsNothing);
  });

  testWidgets('a failed check is readable here and nowhere else',
      (WidgetTester tester) async {
    // The other half of "silent on failure": silent does not mean lost. The
    // reason has to be findable by an operator who goes looking for it.
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      feedError: StateError('Failed host lookup: api.github.com'),
    );
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);
    await tester.tap(find.byKey(const ValueKey('settings-version-check')));
    await tester.pumpAndSettle();

    expect(
      _noteText(tester, 'settings-version-status'),
      contains('Failed host lookup'),
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('settings-version-apply')), findsNothing);
  });

  testWidgets(
      'a newer release is offered with its notes, and applies only on '
      'the button', (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      latest: fakeRelease('1.2.0', notes: 'Wachtwoordbladen tonen nu de WiFi.'),
    );
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);
    await tester.tap(find.byKey(const ValueKey('settings-version-check')));
    await tester.pumpAndSettle();

    expect(_noteText(tester, 'settings-version-status'), contains('1.2.0'));
    expect(
      _noteText(tester, 'settings-version-notes'),
      contains('Wachtwoordbladen'),
    );
    // Checking downloads nothing.
    expect(backend.downloads, 0);
    expect(backend.launched, isEmpty);

    final Finder apply = find.byKey(const ValueKey('settings-version-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pump();

    expect(backend.downloads, 1);
    expect(backend.launched, hasLength(1));
  });

  testWidgets(
      'the notes of the running version are re-openable from here (#395)',
      (WidgetTester tester) async {
    // The decision this issue asked for: a dismissed **Wat is er nieuw** is
    // recoverable, from the section that already answers "which version am I
    // running?".
    final backend = FakeUpdateBackend(
      version: '1.2.0',
      latest: fakeRelease('1.2.0', notes: '## Nieuw\n\n- De WiFi op de bladen'),
    );
    final controller = backend.controller(
      preferences: await fakePreferences(notesSeenVersion: '1.2.0'),
    );
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);
    await tester.tap(find.byKey(const ValueKey('settings-version-check')));
    await tester.pumpAndSettle();

    final Finder open =
        find.byKey(const ValueKey('settings-version-notes-open'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('release-notes-dialog')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('release-notes-version')))
          .data,
      'Versie 1.2.0',
    );
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('a version with no notes offers nothing to re-open',
      (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '1.2.0',
      latest: fakeRelease('1.2.0'),
    );
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.start();

    await _pumpSettings(tester, update: controller);
    await tester.tap(find.byKey(const ValueKey('settings-version-check')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-version-notes-open')),
      findsNothing,
    );
  });
}
