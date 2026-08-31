/// Fakes for the update layer (#371): a scripted release feed, a download that
/// never touches the network, and an installer launch that never starts a
/// process.
library;

import 'dart:async';
import 'dart:io';

import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:account_manager/src/update/app_release.dart';
import 'package:account_manager/src/update/update_controller.dart';
import 'package:pub_semver/pub_semver.dart';

/// A release with the shape the real feed produces, for tests that only care
/// about the version.
AppRelease fakeRelease(
  String version, {
  String notes = '',
  String? installer,
  String? pageUrl,
}) =>
    AppRelease(
      version: Version.parse(version),
      installerUrl: Uri.parse(
        installer ??
            'https://github.com/yvanvds/AccountManager/releases/download/'
                'v$version/$installerAssetPrefix$version$installerAssetSuffix',
      ),
      notes: notes,
      pageUrl: pageUrl ??
          'https://github.com/yvanvds/AccountManager/releases/tag/v$version',
    );

/// The whole update backend, scripted.
///
/// Every seam records what it was asked, so a test can assert not just what the
/// screen shows but what was *not* done — which is the interesting half here:
/// that nothing downloaded and nothing launched until the operator said so.
class FakeUpdateBackend {
  FakeUpdateBackend({
    this.version = '1.0.0',
    this.latest,
    this.feedError,
    this.downloadError,
    this.runReturns = false,
    this.runError,
  });

  /// What [UpdateServices.readVersion] answers; `null` models a build whose own
  /// version could not be read.
  String? version;

  /// What the feed answers, or `null` for "nothing published".
  AppRelease? latest;

  /// When set, the feed throws this instead of answering — the offline /
  /// rate-limited / 500 path.
  Object? feedError;

  /// When set, the download throws this.
  Object? downloadError;

  /// Whether the installer launch *returns* rather than taking the process
  /// away with it. The real one does not come back; a test that wants the
  /// "downloaded but would not start" path sets this.
  bool runReturns;

  /// When set, launching the installer throws this.
  Object? runError;

  int versionReads = 0;
  int feedCalls = 0;
  int downloads = 0;

  /// Every installer handed to the launcher — empty is the assertion that
  /// matters most: nothing was applied without consent.
  final List<File> launched = <File>[];

  /// Where the fake download claims to have written to.
  File downloadedFile = File('C:\\temp\\AccountManager-Setup-v9.9.9.exe');

  /// Progress fractions the download will report before it completes.
  List<double> progress = const <double>[];

  Future<String?> _readVersion() async {
    versionReads++;
    return version;
  }

  Future<AppRelease?> _feed() async {
    feedCalls++;
    final Object? error = feedError;
    if (error != null) throw error;
    return latest;
  }

  Future<File> _download(
    AppRelease release,
    void Function(double) onProgress,
  ) async {
    downloads++;
    final Object? error = downloadError;
    if (error != null) throw error;
    for (final double fraction in progress) {
      onProgress(fraction);
    }
    return downloadedFile;
  }

  Future<void> _run(File installer) {
    launched.add(installer);
    final Object? error = runError;
    if (error != null) return Future<void>.error(error);
    // The real launcher does not return — the process is replaced. A future
    // that never completes is the only faithful stand-in, and it leaves the
    // controller parked in `applying`, which is what a test should see.
    return runReturns ? Future<void>.value() : Completer<void>().future;
  }

  /// Everything the log sink was told, so a test can prove a failure was
  /// *reported* even though nothing was shown.
  final List<String> logs = <String>[];

  UpdateServices services({bool autoCheck = false}) => UpdateServices(
        readVersion: _readVersion,
        feed: _feed,
        download: _download,
        run: _run,
        autoCheck: autoCheck,
        log: logs.add,
      );

  UpdateController controller({
    bool autoCheck = false,
    LocalPreferences? preferences,
  }) =>
      UpdateController(
        services(autoCheck: autoCheck),
        preferences: preferences,
      );
}

/// A [LocalPreferences] over an in-memory bag, optionally pre-loaded — which is
/// how a test tells "a fresh install" apart from "a machine that has already
/// been shown version X" (#395).
Future<LocalPreferences> fakePreferences({String? notesSeenVersion}) async {
  final LocalPreferences preferences = LocalPreferences(
    InMemoryLocalPreferenceStore(<String, Object?>{
      if (notesSeenVersion != null) 'releaseNotesSeenVersion': notesSeenVersion,
    }),
  );
  await preferences.load();
  return preferences;
}
