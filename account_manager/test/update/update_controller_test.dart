import 'package:account_manager/src/update/update_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'update_fakes.dart';

void main() {
  group('start()', () {
    test('reads the running version and, by default, does not reach out',
        () async {
      // The debug/profile wiring: `main()` passes `autoCheck: kReleaseMode`, so
      // a `flutter run` checkout and every integration-test launch stay off the
      // network entirely.
      final backend = FakeUpdateBackend(version: '1.0.0');
      final controller = backend.controller();

      await controller.start();

      expect(controller.installedVersion, '1.0.0');
      expect(backend.feedCalls, 0);
      expect(controller.phase, UpdatePhase.idle);
    });

    test('an installed build checks on launch', () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
      );
      final controller = backend.controller(autoCheck: true);

      await controller.start();

      expect(backend.feedCalls, 1);
      expect(controller.phase, UpdatePhase.available);
      expect(controller.availableRelease!.version.toString(), '1.1.0');
      // Offered — and nothing more. The download has not started.
      expect(backend.downloads, 0);
      expect(backend.launched, isEmpty);
    });
  });

  group('check()', () {
    test('an older published release is not an update', () async {
      final backend = FakeUpdateBackend(
        version: '2.0.0',
        latest: fakeRelease('1.9.9'),
      );
      final controller = backend.controller();

      await controller.start();
      await controller.check();

      expect(controller.phase, UpdatePhase.upToDate);
      expect(controller.availableRelease, isNull);
      expect(controller.isOffering, isFalse);
    });

    test('the same version is not an update either', () async {
      final backend = FakeUpdateBackend(
        version: '1.4.2',
        latest: fakeRelease('1.4.2'),
      );
      final controller = backend.controller();

      await controller.start();
      await controller.check();

      expect(controller.phase, UpdatePhase.upToDate);
      expect(controller.message, contains('1.4.2'));
    });

    test('a repository with no release published yet is a non-event', () async {
      final backend = FakeUpdateBackend(version: '1.0.0');
      final controller = backend.controller();

      await controller.start();
      await controller.check();

      expect(controller.phase, UpdatePhase.upToDate);
      expect(controller.availableRelease, isNull);
    });

    test('an offline or failed check is silent: logged, never thrown',
        () async {
      // The acceptance criterion an operator on a train depends on. `check()`
      // must not throw, must not offer anything, and must leave the reason
      // somewhere it can be read on demand rather than pushed at anybody.
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        feedError: const SocketExceptionStub('Failed host lookup'),
      );
      final controller = backend.controller(autoCheck: true);

      await controller.start();

      expect(controller.phase, UpdatePhase.failed);
      expect(controller.availableRelease, isNull);
      expect(controller.isOffering, isFalse,
          reason: 'a failed check must not put a bar in front of the operator');
      expect(controller.message, contains('Failed host lookup'));
      expect(backend.logs.join('\n'), contains('controle mislukt'));
    });

    test('an unreadable own version declines to compare rather than guessing',
        () async {
      final backend = FakeUpdateBackend(
        version: null,
        latest: fakeRelease('9.9.9'),
      );
      final controller = backend.controller(autoCheck: true);

      await controller.start();

      expect(controller.installedVersion, isNull);
      expect(controller.phase, UpdatePhase.failed);
      // Never fetched: with nothing to compare against, "anything published is
      // newer" would be the wrong guess to make.
      expect(backend.feedCalls, 0);
      expect(controller.availableRelease, isNull);
    });

    test('a manual check re-reads a version that was not available at launch',
        () async {
      final backend = FakeUpdateBackend(version: null);
      final controller = backend.controller();
      await controller.start();
      expect(controller.installedVersion, isNull);

      backend.version = '1.0.0';
      backend.latest = fakeRelease('1.0.1');
      await controller.check();

      expect(controller.installedVersion, '1.0.0');
      expect(controller.phase, UpdatePhase.available);
    });

    test('notifies its listeners so the shell and Instellingen both move',
        () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
      );
      final controller = backend.controller();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.start();
      await controller.check();

      expect(notifications, greaterThan(0));
    });
  });

  group('apply()', () {
    test('downloads and launches the installer once the operator accepts',
        () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
      )..progress = <double>[0.5, 1.0];
      final controller = backend.controller(autoCheck: true);
      await controller.start();
      expect(backend.downloads, 0, reason: 'the offer alone downloads nothing');

      // The real launcher never returns — the process is replaced — so this
      // deliberately does not await to completion.
      unawaitedApply(controller);
      await pumpEventQueue();

      expect(backend.downloads, 1);
      expect(backend.launched, hasLength(1));
      expect(backend.launched.single.path, backend.downloadedFile.path);
      expect(controller.phase, UpdatePhase.applying);
    });

    test('does nothing at all when nothing is on offer', () async {
      // The consent gate from the other side: there is no state in which
      // apply() can act without a check having first produced an offer.
      final backend = FakeUpdateBackend(version: '1.0.0');
      final controller = backend.controller(autoCheck: true);
      await controller.start();

      await controller.apply();

      expect(backend.downloads, 0);
      expect(backend.launched, isEmpty);
    });

    test('a failed download is reported, not thrown', () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
        downloadError: StateError('de verbinding viel weg'),
      );
      final controller = backend.controller(autoCheck: true);
      await controller.start();

      await controller.apply();

      expect(controller.phase, UpdatePhase.failed);
      expect(controller.message, contains('de verbinding viel weg'));
      expect(backend.launched, isEmpty);
    });

    test('an installer that will not start says where it was put', () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
        runReturns: true,
      );
      final controller = backend.controller(autoCheck: true);
      await controller.start();

      await controller.apply();

      expect(controller.phase, UpdatePhase.failed);
      expect(controller.message, contains(backend.downloadedFile.path));
    });
  });

  group('dismiss()', () {
    test('puts the offer away without declining the version', () async {
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0'),
      );
      final controller = backend.controller(autoCheck: true);
      await controller.start();
      expect(controller.isOffering, isTrue);

      controller.dismiss();

      expect(controller.isOffering, isFalse);
      // Still on offer in Instellingen — dismissing the bar is not declining
      // the update.
      expect(controller.availableRelease, isNotNull);
      expect(controller.phase, UpdatePhase.available);
    });
  });

  /// The "what's new" decision (#395), stated as the issue's acceptance
  /// criteria: after an update the first launch has news, the second does not,
  /// a fresh install never does, an empty body is not news, and a failed read
  /// is silent.
  group('release notes', () {
    test('the first launch after an update has news', () async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest:
            fakeRelease('1.1.0', notes: '- Wachtwoordbladen tonen de WiFi.'),
      );
      final prefs = await fakePreferences(notesSeenVersion: '1.0.0');
      final controller =
          backend.controller(autoCheck: true, preferences: prefs);

      await controller.start();

      expect(controller.whatsNewPending, isTrue);
      expect(controller.releaseNotes!.version.toString(), '1.1.0');
      // And the offer bar stays out of it — this is not an update to apply.
      expect(controller.isOffering, isFalse);
      expect(controller.phase, UpdatePhase.upToDate);
    });

    test('closing it writes the marker, so the next launch is silent',
        () async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0', notes: 'iets nieuws'),
      );
      final prefs = await fakePreferences(notesSeenVersion: '1.0.0');
      final first = backend.controller(autoCheck: true, preferences: prefs);
      await first.start();
      expect(first.whatsNewPending, isTrue);

      await first.acknowledgeReleaseNotes();
      expect(first.whatsNewPending, isFalse);
      expect(prefs.releaseNotesSeenVersion, '1.1.0');

      // A restart, over the same bag.
      final second = backend.controller(autoCheck: true, preferences: prefs);
      await second.start();
      expect(second.whatsNewPending, isFalse,
          reason: 'never twice for one version');
      // Still readable on demand, which is what the Instellingen button opens.
      expect(second.releaseNotes, isNotNull);
    });

    test('a fresh install is seeded, not greeted', () async {
      // Nothing stored is not "show it": someone installing 1.1.0 for the first
      // time has everything, so there is nothing new to them.
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0', notes: 'iets nieuws'),
      );
      final prefs = await fakePreferences();
      final controller =
          backend.controller(autoCheck: true, preferences: prefs);

      await controller.start();

      expect(controller.whatsNewPending, isFalse);
      expect(prefs.releaseNotesSeenVersion, '1.1.0',
          reason: 'the baseline is recorded so the *next* version is news');
    });

    test('a release with an empty body is not news', () async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        latest: fakeRelease('1.1.0', notes: '   \n  '),
      );
      final controller = backend.controller(
        autoCheck: true,
        preferences: await fakePreferences(notesSeenVersion: '1.0.0'),
      );

      await controller.start();

      expect(controller.whatsNewPending, isFalse);
      expect(controller.releaseNotes, isNull,
          reason: 'an empty dialog is worse than no dialog');
    });

    test('an offline launch says nothing about notes either', () async {
      final backend = FakeUpdateBackend(
        version: '1.1.0',
        feedError: const SocketExceptionStub('Failed host lookup'),
      );
      final controller = backend.controller(
        autoCheck: true,
        preferences: await fakePreferences(notesSeenVersion: '1.0.0'),
      );

      await controller.start();

      expect(controller.whatsNewPending, isFalse);
      expect(controller.releaseNotes, isNull);
      expect(controller.phase, UpdatePhase.failed);
    });

    test('an operator who is behind gets the offer, not a retrospective',
        () async {
      // The published latest is *not* the running version, so its body is not
      // "what's new in what you are running" — it is what you would get.
      final backend = FakeUpdateBackend(
        version: '1.0.0',
        latest: fakeRelease('1.1.0', notes: 'iets nieuws'),
      );
      final controller = backend.controller(
        autoCheck: true,
        preferences: await fakePreferences(notesSeenVersion: '0.9.0'),
      );

      await controller.start();

      expect(controller.whatsNewPending, isFalse);
      expect(controller.releaseNotes, isNull);
      expect(controller.isOffering, isTrue);
    });

    test('skipping several versions shows only the current release', () async {
      // 1.0.0 → 1.3.0 in one jump: the dialog is 1.3.0's notes and the link
      // covers the rest, rather than three releases concatenated.
      final backend = FakeUpdateBackend(
        version: '1.3.0',
        latest: fakeRelease('1.3.0', notes: 'Wat 1.3.0 bracht.'),
      );
      final prefs = await fakePreferences(notesSeenVersion: '1.0.0');
      final controller =
          backend.controller(autoCheck: true, preferences: prefs);

      await controller.start();

      expect(controller.whatsNewPending, isTrue);
      expect(controller.releaseNotes!.notes, 'Wat 1.3.0 bracht.');
      expect(backend.feedCalls, 1,
          reason: 'no extra fetch for the ones between');
      await controller.acknowledgeReleaseNotes();
      expect(prefs.releaseNotesSeenVersion, '1.3.0');
    });

    test('a build whose own version cannot be read seeds nothing', () async {
      final backend = FakeUpdateBackend(
        version: null,
        latest: fakeRelease('1.1.0', notes: 'iets'),
      );
      final prefs = await fakePreferences();
      final controller =
          backend.controller(autoCheck: true, preferences: prefs);

      await controller.start();

      expect(controller.whatsNewPending, isFalse);
      expect(prefs.releaseNotesSeenVersion, isNull,
          reason: 'nothing is recorded against a version we cannot name');
    });
  });
}

/// Starts an apply without waiting for it, because the real installer launch
/// never returns.
void unawaitedApply(UpdateController controller) {
  // ignore: discarded_futures
  controller.apply();
}

/// A stand-in for the offline failure, so the test does not need `dart:io`.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub(this.message);
  final String message;
  @override
  String toString() => message;
}
