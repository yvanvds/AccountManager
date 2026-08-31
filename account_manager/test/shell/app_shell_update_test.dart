import 'package:account_manager/src/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../update/update_fakes.dart';

/// The shell's update offer (#371).
///
/// The bar is a strip of chrome above the rail, so what matters here is that it
/// is *absent* in every state but one — a build that never checks, a check that
/// failed, and a check that came back up to date must all render identically.
Widget _wrap(Widget child) => MaterialApp(home: child);

Finder get _bar => find.byKey(const ValueKey('update-offer'));
Finder get _apply => find.byKey(const ValueKey('update-offer-apply'));
Finder get _dismiss => find.byKey(const ValueKey('update-offer-dismiss'));
Finder get _dialog => find.byKey(const ValueKey('release-notes-dialog'));

void main() {
  testWidgets('a build with no update mechanism shows no bar at all',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const AppShell()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(_bar, findsNothing);
  });

  testWidgets('a launch on the newest version shows no bar',
      (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '2.0.0',
      latest: fakeRelease('2.0.0'),
    );
    await tester.pumpWidget(
      _wrap(AppShell(update: backend.services(autoCheck: true))),
    );
    await tester.pumpAndSettle();

    expect(backend.feedCalls, 1, reason: 'it did check');
    expect(_bar, findsNothing, reason: 'and found nothing to say');
  });

  testWidgets('an offline launch is silent — no bar, no dialog, no exception',
      (WidgetTester tester) async {
    // The criterion an operator without network depends on: the app comes up
    // exactly as it always does.
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      feedError: StateError('Failed host lookup: api.github.com'),
    );
    await tester.pumpWidget(
      _wrap(AppShell(update: backend.services(autoCheck: true))),
    );
    await tester.pumpAndSettle();

    expect(_bar, findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a newer release is offered above the rail, and applies on accept',
      (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      latest: fakeRelease('1.1.0'),
    );
    await tester.pumpWidget(
      _wrap(AppShell(update: backend.services(autoCheck: true))),
    );
    await tester.pumpAndSettle();

    expect(_bar, findsOneWidget);
    expect(find.textContaining('1.1.0'), findsWidgets);
    // Offered, not applied: nothing has been downloaded or launched.
    expect(backend.downloads, 0);
    expect(backend.launched, isEmpty);

    await tester.tap(_apply);
    await tester.pump();

    expect(backend.downloads, 1);
    expect(backend.launched, hasLength(1));
  });

  testWidgets('Later puts the bar away and leaves the app working',
      (WidgetTester tester) async {
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      latest: fakeRelease('1.1.0'),
    );
    await tester.pumpWidget(
      _wrap(AppShell(update: backend.services(autoCheck: true))),
    );
    await tester.pumpAndSettle();
    expect(_bar, findsOneWidget);

    await tester.tap(_dismiss);
    await tester.pumpAndSettle();

    expect(_bar, findsNothing);
    expect(backend.downloads, 0);
    expect(backend.launched, isEmpty);
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('the bar never blocks the first frame',
      (WidgetTester tester) async {
    // `start()` is fired from initState and awaited by nobody: the rail is on
    // screen on the very first pump, before the check has answered.
    final backend = FakeUpdateBackend(
      version: '1.0.0',
      latest: fakeRelease('1.1.0'),
    );
    await tester.pumpWidget(
      _wrap(AppShell(update: backend.services(autoCheck: true))),
    );

    // One frame only — no settle.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(_bar, findsNothing);

    await tester.pumpAndSettle();
    expect(_bar, findsOneWidget);
  });

  /// **Wat is er nieuw** (#395) — the one thing the check may put on screen by
  /// itself, and therefore the one that has to be provably absent everywhere
  /// else.
  group('the release-notes dialog', () {
    testWidgets('appears once after an update and never blocks the shell',
        (WidgetTester tester) async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest:
            fakeRelease('1.1.0', notes: '## Nieuw\n\n- De WiFi op de bladen'),
      );
      final prefs = await fakePreferences(notesSeenVersion: '1.0.0');
      await tester.pumpWidget(_wrap(AppShell(
        update: backend.services(autoCheck: true),
        preferences: prefs,
      )));
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
      // The shell is behind it, whole: this is a dialog to close, not a gate.
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(_bar, findsNothing, reason: 'there is nothing to update to');
      expect(find.textContaining('##'), findsNothing,
          reason: 'the Markdown is rendered, not echoed');

      await tester.tap(find.byKey(const ValueKey('release-notes-close')));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(prefs.releaseNotesSeenVersion, '1.1.0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not come back on the next launch of the same version',
        (WidgetTester tester) async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0', notes: 'iets nieuws'),
      );
      final prefs = await fakePreferences(notesSeenVersion: '1.0.0');

      Future<void> launch() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_wrap(AppShell(
          update: backend.services(autoCheck: true),
          preferences: prefs,
        )));
        await tester.pumpAndSettle();
      }

      await launch();
      expect(_dialog, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('release-notes-close')));
      await tester.pumpAndSettle();

      await launch();
      expect(_dialog, findsNothing);
    });

    testWidgets('a fresh install never sees it', (WidgetTester tester) async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0', notes: 'iets nieuws'),
      );
      final prefs = await fakePreferences();
      await tester.pumpWidget(_wrap(AppShell(
        update: backend.services(autoCheck: true),
        preferences: prefs,
      )));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(prefs.releaseNotesSeenVersion, '1.1.0');
    });

    testWidgets('an empty release body shows nothing at all',
        (WidgetTester tester) async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0'),
      );
      await tester.pumpWidget(_wrap(AppShell(
        update: backend.services(autoCheck: true),
        preferences: await fakePreferences(notesSeenVersion: '1.0.0'),
      )));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('an offline launch shows nothing at all',
        (WidgetTester tester) async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        feedError: StateError('Failed host lookup: api.github.com'),
      );
      await tester.pumpWidget(_wrap(AppShell(
        update: backend.services(autoCheck: true),
        preferences: await fakePreferences(notesSeenVersion: '1.0.0'),
      )));
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
