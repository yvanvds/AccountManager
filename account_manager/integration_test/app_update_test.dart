// BuildContext lookups after `pumpAndSettle` are safe in tests: the tree is
// still mounted and the tester drives the frames synchronously.
// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/settings/connection_config.dart';
import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:account_manager/src/update/app_release.dart'
    show parseReleaseTag;
import 'package:account_manager/src/update/update_bootstrap.dart'
    show readInstalledVersion;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/screens/settings_fakes.dart';
import '../test/update/update_fakes.dart';
import 'support/e2e_support.dart';

/// End-to-end runs of the *real* app for **app updates** — the release check,
/// the offer bar, and the "what is new" notes after an install (#371, #395).
///
/// Split out of `app_launch_test.dart` in #421. This area brings release and
/// version fakes of its own (`FakeUpdateBackend`, `fakeRelease`, and the
/// installed-version reader below) and shares nothing else with the rest of the
/// suite, so it earns its own launch. Helpers it shares with the other
/// end-to-end files live in `support/e2e_support.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('app updates', () {
    testWidgets(
        'the running build reads the version pubspec.yaml declared (#371)',
        (WidgetTester tester) async {
      // The one claim in this issue that only a real engine can settle. The
      // version is read from the Windows executable's own version resource, which
      // the Flutter tool populates from `pubspec.yaml` — and the `version.json`
      // asset that serves this purpose elsewhere is *not* written into a Windows
      // bundle, so a headless widget test cannot tell whether the production
      // reader works. It is also the whole basis of the update check: a build that
      // cannot say what it is cannot be compared against what is published.
      final String? version = await readInstalledVersion();
      expect(
        version,
        isNotNull,
        reason: 'the exe version resource could not be read on the real engine',
      );
      expect(parseReleaseTag(version!), isNotNull,
          reason: '"$version" is not a version the release check can compare');

      // And it is genuinely the single source of truth, not a constant that
      // happens to agree today.
      final File? pubspec = _findAppPubspec();
      expect(pubspec, isNotNull,
          reason: 'no account_manager/pubspec.yaml found above '
              '${Directory.current.path}');
      final RegExpMatch? declared =
          RegExp(r'^version:\s*([^\s+]+)', multiLine: true)
              .firstMatch(pubspec!.readAsStringSync());
      expect(declared, isNotNull);
      expect(version, declared!.group(1));
    });

    testWidgets(
        'a launch on an installed build offers the newer release, shows its own '
        'version in Instellingen, and applies only on consent (#371)',
        (WidgetTester tester) async {
      // The user-visible flow end to end in the real app. A widget test can pump
      // the shell or the Settings screen; it cannot show that the offer survives
      // the sign-in gate, that it sits above a real navigation rail without
      // pushing it off-screen, that the rail still reaches Instellingen with the
      // bar on stage, or that the Versie section lays out in the real font on the
      // same tab the connection coordinates live on.
      useTallWindow(tester);

      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest:
            fakeRelease('1.4.0', notes: 'Wachtwoordbladen tonen nu de WiFi.'),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        update: backend.services(autoCheck: true),
      ));
      await tester.pumpAndSettle();

      // Offered above the rail, without a dialog and without having interrupted
      // the launch: the shell is fully usable underneath it.
      expect(find.byKey(const ValueKey('update-offer')), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('update-offer-message')))
            .data,
        contains('1.4.0'),
      );
      // Offered is not applied.
      expect(backend.downloads, 0);
      expect(backend.launched, isEmpty);

      // The rail still works with the bar up, and Instellingen states which build
      // this is — on the Verbinding tab, beside where the backend it talks to is
      // configured (#370).
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openSettingsTab(tester, 'settings-tab-verbinding');

      final Finder current =
          find.byKey(const ValueKey('settings-version-current'));
      await tester.ensureVisible(current);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(current).data, contains('1.0.0'));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-version-status')))
            .data,
        contains('1.4.0'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-version-notes')))
            .data,
        contains('Wachtwoordbladen'),
      );

      // Consent, and only then: the installer is fetched and handed to Windows.
      final Finder apply = find.byKey(const ValueKey('update-offer-apply'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pump();

      expect(backend.downloads, 1);
      expect(backend.launched, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'an offline launch never mentions the update check at all (#371)',
        (WidgetTester tester) async {
      // An operator without network has to be able to work. Only a full launch
      // shows that a failed check leaves *the whole app* exactly as it was —
      // no bar, no dialog, no stalled first frame.
      useTallWindow(tester);
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        feedError: StateError('Failed host lookup: api.github.com'),
      );

      await tester.pumpWidget(AccountManagerApp(
        session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
        graph: graph,
        settingsBootstrap: SettingsHarness().bootstrap,
        connection: ConnectionServices(store: InMemoryConnectionStore()),
        update: backend.services(autoCheck: true),
      ));

      // The rail is on stage before the check has answered — nothing waited.
      await tester.pump();
      await tester.pump();
      expect(find.byType(NavigationRail), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-offer')), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);

      // The reason is not lost, only unpushed: it is readable on demand.
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openSettingsTab(tester, 'settings-tab-verbinding');
      final Finder status =
          find.byKey(const ValueKey('settings-version-status'));
      await tester.ensureVisible(status);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(status).data, contains('Failed host lookup'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the first launch after an update shows the release notes once, survives '
        'the restart, and stays re-openable in Instellingen (#395)',
        (WidgetTester tester) async {
      // Every acceptance criterion of #395 in one real run, and each of them needs
      // this level. The dialog is pushed onto the *real* navigator from a
      // post-frame callback over a shell that is already on stage; the Markdown is
      // laid out in the real Plink faces inside a real `AlertDialog` whose width a
      // widget test's stand-in font would misreport; and "survives an update" is a
      // claim about a file on disk read back by a whole new widget tree, which is
      // exactly what a restart is.
      useTallWindow(tester);

      final Directory dir = Directory.systemTemp.createTempSync('am-whats-new');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final File prefsFile = File(
        '${dir.path}${Platform.pathSeparator}$localPreferencesFileName',
      );
      // A machine that has been running 1.0.0 — not a fresh install, which is the
      // case that must stay silent and is covered at the unit level.
      prefsFile.writeAsStringSync(jsonEncode(<String, Object?>{
        'releaseNotesSeenVersion': '1.0.0',
      }));

      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease(
          '1.1.0',
          notes: '## Wat is er veranderd\n\n'
              '- Wachtwoordbladen tonen nu de **WiFi**.\n'
              '- De uitschrijvingsdatum wordt onthouden.\n',
          pageUrl: 'https://example.test/releases/v1.1.0',
        ),
      );
      final List<Uri> opened = <Uri>[];

      Future<void> launch() async {
        // A fresh `LocalPreferences` over the same file each time — a restart.
        final prefs = LocalPreferences(FileLocalPreferenceStore(prefsFile));
        await prefs.load();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(AccountManagerApp(
          session: SignInSession(FakeBroker(silent: (_) => fakeToken('AT'))),
          graph: graph,
          settingsBootstrap: SettingsHarness().bootstrap,
          connection: ConnectionServices(store: InMemoryConnectionStore()),
          update: backend.services(autoCheck: true),
          preferences: prefs,
          openReleaseLink: (Uri url) async => opened.add(url),
        ));
        await tester.pumpAndSettle();
      }

      final Finder dialog = find.byKey(const ValueKey('release-notes-dialog'));

      // --- The launch that follows the update. --------------------------------
      await launch();

      expect(dialog, findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('release-notes-version')))
            .data,
        'Versie 1.1.0',
        reason: 'the notes are the running version, not the offered one',
      );
      // Non-blocking: the whole shell is behind it, and there is no update to
      // apply, so the #371 offer bar stays away.
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(const ValueKey('update-offer')), findsNothing);

      // Rendered as Markdown, not echoed as source — the reason the issue asks
      // for a reader at all.
      expect(find.textContaining('##', findRichText: true), findsNothing);
      expect(find.textContaining('- Wachtwoordbladen', findRichText: true),
          findsNothing);
      expect(find.textContaining('Wachtwoordbladen', findRichText: true),
          findsWidgets);

      // The link points at the release's own page.
      await tester.tap(find.byKey(const ValueKey('release-notes-page')));
      await tester.pumpAndSettle();
      expect(opened, <Uri>[Uri.parse('https://example.test/releases/v1.1.0')]);

      await tester.tap(find.byKey(const ValueKey('release-notes-close')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      // Written where an update cannot reach it: `%APPDATA%`, not the install
      // directory the installer replaces.
      expect(
        (jsonDecode(prefsFile.readAsStringSync())
            as Map<String, dynamic>)['releaseNotesSeenVersion'],
        '1.1.0',
      );

      // --- Restart. Same version, so nothing to say. --------------------------
      await launch();
      expect(dialog, findsNothing, reason: 'never twice for one version');
      expect(find.byType(NavigationRail), findsOneWidget);

      // --- But recoverable, where the version already lives. ------------------
      await tester.tap(railTab('Instellingen'));
      await tester.pumpAndSettle();
      await openSettingsTab(tester, 'settings-tab-verbinding');
      final Finder reopen =
          find.byKey(const ValueKey('settings-version-notes-open'));
      await tester.ensureVisible(reopen);
      await tester.pumpAndSettle();
      await tester.tap(reopen);
      await tester.pumpAndSettle();

      expect(dialog, findsOneWidget);
      expect(find.textContaining('Wachtwoordbladen', findRichText: true),
          findsWidgets);
      await tester.tap(find.byKey(const ValueKey('release-notes-close')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}

/// The Flutter app's own `pubspec.yaml`, found by walking up from wherever the
/// test process happens to have been started.
File? _findAppPubspec() {
  Directory? dir = Directory.current;
  for (var depth = 0; dir != null && depth < 8; depth++) {
    for (final String candidate in <String>[
      '${dir.path}${Platform.pathSeparator}pubspec.yaml',
      '${dir.path}${Platform.pathSeparator}account_manager'
          '${Platform.pathSeparator}pubspec.yaml',
    ]) {
      final File file = File(candidate);
      if (file.existsSync() &&
          file.readAsStringSync().contains('name: account_manager')) {
        return file;
      }
    }
    final Directory parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}
