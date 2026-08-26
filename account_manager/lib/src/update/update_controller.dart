/// The in-app update check and the consented apply (#371).
///
/// Three properties this is built around, because they are the ones an update
/// mechanism gets wrong in ways an operator pays for:
///
/// - **Never blocking.** [UpdateController.start] is fired and forgotten from
///   the shell's `initState`; nothing on screen waits on it, and the request
///   itself is bounded by a timeout so a hung endpoint cannot become a hung
///   launch in slow motion.
/// - **Silent on failure.** Every failure path here is caught, written to the
///   log sink, and left on [UpdateController.message] for whoever opens
///   Instellingen. No dialog, no snackbar, no banner: an operator working
///   offline is doing something legitimate, not something to be interrupted.
/// - **Never applied without consent.** [UpdateController.apply] is reached from
///   a button and from nothing else — no timer, no "check" path, no branch of
///   [UpdateController.check] calls it. A surprise restart in the middle of a
///   sync is the failure mode this exists to rule out.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

import 'app_release.dart';

/// Where the update check has got to — what the Versie section and the shell's
/// offer bar both render from.
enum UpdatePhase {
  /// Nothing has been asked yet.
  idle,

  /// A check is in flight.
  checking,

  /// The check came back and this build is the newest published one.
  upToDate,

  /// A newer release is published and waiting for the operator to accept it.
  available,

  /// The operator accepted; the installer is coming down.
  downloading,

  /// The installer is downloaded and being handed to Windows.
  applying,

  /// The check or the apply failed. Reported on demand, never pushed.
  failed,
}

/// Downloads [release]'s installer, reporting progress as a 0..1 fraction where
/// the server declared a content length.
typedef ReleaseDownloader = Future<File> Function(
  AppRelease release,
  void Function(double fraction) onProgress,
);

/// Hands the downloaded [installer] to Windows and ends this process so the
/// installer can replace the files underneath it.
///
/// Returns only if the handover failed — a successful one does not come back.
typedef InstallerRunner = Future<void> Function(File installer);

/// Where a diagnostic goes when nothing is shown on screen.
typedef UpdateLog = void Function(String message);

/// The seams the update layer is assembled from (#371).
///
/// Shaped like [ConnectionServices] next door: production wiring in `main()`,
/// fakes in tests, and nothing in between that reaches for a real network or a
/// real process.
class UpdateServices {
  const UpdateServices({
    required this.readVersion,
    required this.feed,
    required this.download,
    required this.run,
    this.autoCheck = true,
    this.log,
  });

  /// The running build's version, as `pubspec.yaml` declared it, or `null` when
  /// it cannot be read.
  final Future<String?> Function() readVersion;

  /// Where the latest published release is looked up.
  final ReleaseFeed feed;

  /// How an accepted release is fetched.
  final ReleaseDownloader download;

  /// How a fetched installer is launched.
  final InstallerRunner run;

  /// Whether a launch checks by itself.
  ///
  /// Off for a debug or profile build (see `main()`): those are checkouts being
  /// developed against, not installs to update, and leaving it on would mean
  /// every `flutter run` and every integration-test launch reaching out to
  /// api.github.com. The manual **Controleren op updates** button in
  /// Instellingen still works either way.
  final bool autoCheck;

  /// Where failures are written. Defaults to [debugPrint].
  final UpdateLog? log;
}

/// The update check's state, and the two operations that move it.
class UpdateController extends ChangeNotifier {
  UpdateController(this.services);

  final UpdateServices services;

  UpdatePhase _phase = UpdatePhase.idle;
  String? _installedVersion;
  Version? _parsedInstalledVersion;
  AppRelease? _available;
  String _message = '';
  double _progress = 0;
  bool _dismissed = false;
  bool _busy = false;

  /// Where the check has got to.
  UpdatePhase get phase => _phase;

  /// The running build's version as text, or `null` while unknown.
  ///
  /// Unknown is not the same as absent: it is what a build whose version
  /// resource could not be read reports, and it is why [check] declines to
  /// compare rather than guessing that anything published is newer.
  String? get installedVersion => _installedVersion;

  /// The newer release on offer, or `null` when there is none.
  AppRelease? get availableRelease => _available;

  /// The last thing worth telling an operator who asks — including the reason a
  /// check failed. Rendered in Instellingen; never pushed at anybody.
  String get message => _message;

  /// Download progress as a 0..1 fraction while [phase] is
  /// [UpdatePhase.downloading].
  double get progress => _progress;

  /// Whether the operator waved the offer away for this session.
  bool get dismissed => _dismissed;

  /// Whether the shell should be offering this update right now.
  bool get isOffering =>
      !_dismissed &&
      _available != null &&
      (_phase == UpdatePhase.available ||
          _phase == UpdatePhase.downloading ||
          _phase == UpdatePhase.applying);

  /// Whether an operation is in flight, so the buttons can disable themselves.
  bool get busy => _busy;

  void _log(String text) => (services.log ?? debugPrint)(text);

  void _set(VoidCallback mutate) {
    mutate();
    notifyListeners();
  }

  /// Resolves the running version and — on a build that checks by itself —
  /// looks for a newer release.
  ///
  /// Never throws and never blocks its caller into anything: the shell calls
  /// this with `unawaited` from `initState`, so the first frame is already on
  /// screen while this is in flight.
  Future<void> start() async {
    await _readVersion();
    if (!services.autoCheck) return;
    await check();
  }

  Future<void> _readVersion() async {
    try {
      final String? version = await services.readVersion();
      _set(() {
        _installedVersion = version;
        _parsedInstalledVersion =
            version == null ? null : parseReleaseTag(version);
      });
    } on Object catch (e) {
      _log('Update: kon de eigen versie niet lezen: $e');
      _set(() {
        _installedVersion = null;
        _parsedInstalledVersion = null;
      });
    }
  }

  /// Asks the feed whether a newer release is published.
  ///
  /// Never throws: a failed or offline check writes to the log, parks the reason
  /// on [message], and leaves the app exactly as it was.
  Future<void> check() async {
    if (_busy) return;
    // The version is read once; a manual check on a build that started before
    // it resolved should still get one rather than declining forever.
    if (_installedVersion == null) await _readVersion();

    final Version? current = _parsedInstalledVersion;
    if (current == null) {
      _set(() {
        _phase = UpdatePhase.failed;
        _message = 'De versie van deze build kon niet gelezen worden, dus er '
            'kan niet vergeleken worden met wat er gepubliceerd is.';
      });
      _log('Update: geen leesbare eigen versie — controle overgeslagen.');
      return;
    }

    _set(() {
      _busy = true;
      _phase = UpdatePhase.checking;
      _message = '';
    });
    try {
      final AppRelease? latest = await services.feed();
      if (latest == null) {
        _set(() {
          _phase = UpdatePhase.upToDate;
          _available = null;
          _message = 'Er is nog geen release gepubliceerd.';
        });
        return;
      }
      if (latest.version > current) {
        _set(() {
          _phase = UpdatePhase.available;
          _available = latest;
          _message = 'Versie ${latest.version} is beschikbaar.';
        });
        _log('Update: ${latest.version} beschikbaar (nu $current).');
      } else {
        _set(() {
          _phase = UpdatePhase.upToDate;
          _available = null;
          _message = 'Deze versie ($current) is de nieuwste.';
        });
      }
    } on Object catch (e) {
      // The whole point of the silent path: no dialog, no banner, no stall.
      _log('Update: controle mislukt: $e');
      _set(() {
        _phase = UpdatePhase.failed;
        _available = null;
        _message = 'De controle op updates is niet gelukt: $e';
      });
    } finally {
      _set(() => _busy = false);
    }
  }

  /// Downloads the offered installer and hands it to Windows.
  ///
  /// Only ever reached from a button the operator pressed. Nothing in [start] or
  /// [check] calls this, and there is no timer that could.
  Future<void> apply() async {
    final AppRelease? release = _available;
    if (release == null || _busy) return;

    _set(() {
      _busy = true;
      _phase = UpdatePhase.downloading;
      _progress = 0;
      _message = 'Versie ${release.version} wordt gedownload…';
    });
    try {
      final File installer = await services.download(
        release,
        (double fraction) => _set(() => _progress = fraction.clamp(0.0, 1.0)),
      );
      _set(() {
        _phase = UpdatePhase.applying;
        _message = 'Het installatieprogramma wordt gestart. De app sluit '
            'zichzelf en komt terug in versie ${release.version}.';
      });
      await services.run(installer);
      // Reached only when the handover failed to take the process down with it.
      _set(() {
        _phase = UpdatePhase.failed;
        _message = 'Het installatieprogramma is gedownload naar '
            '${installer.path}, maar startte niet. Voer het handmatig uit.';
      });
      _log(
          'Update: installer gedownload maar niet gestart (${installer.path}).');
    } on Object catch (e) {
      _log('Update: bijwerken mislukt: $e');
      _set(() {
        _phase = UpdatePhase.failed;
        _message = 'Bijwerken is niet gelukt: $e';
      });
    } finally {
      _set(() => _busy = false);
    }
  }

  /// Waves the offer away for this session. The Versie section still has it —
  /// dismissing an offer is not the same as declining the version.
  void dismiss() => _set(() => _dismissed = true);
}
