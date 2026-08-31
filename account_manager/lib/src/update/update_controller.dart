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

import '../settings/local_preferences.dart';
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
  UpdateController(this.services, {LocalPreferences? preferences})
      : preferences = preferences ?? LocalPreferences.inMemory();

  final UpdateServices services;

  /// This machine's own remembered state (#394), which is where the "notes last
  /// seen for version X" marker lives (#395).
  ///
  /// **Machine-local, deliberately.** The shared Cosmos settings document is the
  /// wrong side of that line: put the marker there and the first operator to
  /// close the dialog closes it for every colleague. It also has to survive the
  /// update that produced it, which `%APPDATA%\AccountManager\preferences.json`
  /// does — the installer never touches that directory (see
  /// `docs/release-process.md`).
  ///
  /// Defaults to a session-only bag, so a controller built without one still
  /// works and simply forgets at exit.
  final LocalPreferences preferences;

  UpdatePhase _phase = UpdatePhase.idle;
  String? _installedVersion;
  Version? _parsedInstalledVersion;
  AppRelease? _available;
  AppRelease? _latest;
  Version? _notesSeen;
  bool _whatsNewPending = false;
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

  /// The release notes **of the version now running** (#395), or `null` when
  /// there are none to read.
  ///
  /// `null` covers every honest reason at once: no check has answered yet, the
  /// check failed or was offline, the published latest is a *different* version
  /// from the one running (the operator is behind, and the news to give them is
  /// the update itself), or the release was published with an empty body. Each
  /// of those renders the same — no dialog, no button — because in each of them
  /// there is genuinely nothing to show.
  ///
  /// Only ever the current release's notes, never an accumulation of the ones
  /// skipped in between. An operator jumping 1.0.1 → 1.0.4 gets 1.0.4's notes
  /// and the GitHub link, which is where the full history already lives; a
  /// dialog that concatenated three releases would be the one nobody reads.
  AppRelease? get releaseNotes {
    final AppRelease? latest = _latest;
    final Version? current = _parsedInstalledVersion;
    if (latest == null || current == null) return null;
    if (latest.version != current) return null;
    return latest.notes.trim().isEmpty ? null : latest;
  }

  /// Whether the shell should be showing **Wat is er nieuw** right now (#395).
  ///
  /// True for exactly one launch: the first one after an update to a version
  /// whose notes this machine has not seen. [acknowledgeReleaseNotes] is what
  /// takes it down, and it writes the marker before it does — so a crash between
  /// the dialog opening and the operator closing it costs one repeat, never a
  /// dialog that keeps coming back.
  bool get whatsNewPending => _whatsNewPending;

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
    await _seedReleaseNotesBaseline();
    if (!services.autoCheck) return;
    await check();
  }

  /// Establishes what this machine has already been told about (#395), and — on
  /// an install that has never recorded anything — seeds it with the running
  /// version.
  ///
  /// The seeding is the acceptance criterion "a fresh install never shows it",
  /// and it has to be done this way round. Treating "nothing stored" as "show
  /// it" would greet someone installing v1.0.4 for the first time with a list of
  /// changes to an app they have never seen; there is nothing new to them,
  /// because all of it is. So the first launch records where it starts and says
  /// nothing, and the *second* version this install runs is the first one it
  /// announces.
  ///
  /// Never throws. A preference file that cannot be read or written costs the
  /// dialog, not the launch.
  Future<void> _seedReleaseNotesBaseline() async {
    final Version? current = _parsedInstalledVersion;
    if (current == null) return;
    try {
      final String? stored = preferences.releaseNotesSeenVersion;
      if (stored == null) {
        _notesSeen = current;
        await preferences.setReleaseNotesSeenVersion(current.toString());
        return;
      }
      _notesSeen = parseReleaseTag(stored);
    } on Object catch (e) {
      _log('Update: kon de gelezen-releasenotitie niet bijhouden: $e');
    }
  }

  /// Decides whether [latest] is news for this machine, given the running
  /// [current] version.
  ///
  /// Four ways to be silent, and the issue names each: the feed answered with a
  /// version that is not the one running (an operator who is *behind* gets the
  /// update offer, not a retrospective); the release carries no body; this
  /// machine has already seen this version's notes; or nothing was ever recorded
  /// because the version could not be read.
  void _considerReleaseNotes(AppRelease? latest, Version current) {
    if (latest == null || latest.version != current) return;
    if (latest.notes.trim().isEmpty) return;
    final Version? seen = _notesSeen;
    if (seen == null || seen >= current) return;
    _set(() => _whatsNewPending = true);
    _log('Update: releasenotities van $current zijn nieuw op deze machine.');
  }

  /// Marks this version's notes as read on this machine, and takes the dialog
  /// down (#395).
  ///
  /// Called when the operator closes **Wat is er nieuw**. Writing the marker is
  /// what makes "never twice for one version" true across restarts; clearing the
  /// flag is what makes it true within one session.
  Future<void> acknowledgeReleaseNotes() async {
    final Version? current = _parsedInstalledVersion;
    _set(() => _whatsNewPending = false);
    if (current == null) return;
    _notesSeen = current;
    try {
      await preferences.setReleaseNotesSeenVersion(current.toString());
    } on Object catch (e) {
      _log('Update: kon niet bewaren dat $current gelezen is: $e');
    }
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
      // Kept whatever the comparison says: when it *is* the running version,
      // its body is the "what's new" for the build the operator is in (#395),
      // which is the common case immediately after an update.
      _latest = latest;
      _considerReleaseNotes(latest, current);
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
