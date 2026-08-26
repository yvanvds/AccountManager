/// The production wiring behind the update check (#371): where the running
/// version is read from, how an installer is fetched, and how it is launched.
///
/// Held apart from [UpdateController] on purpose — this is the only file in the
/// update layer that touches the real filesystem, the real network and a real
/// process, so everything above it stays drivable from a test with no network
/// and no `%TEMP%` write.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'app_release.dart';
import 'update_controller.dart';

/// The switches the auto-update hands the installer.
///
/// - `/SILENT` — no wizard, just a progress window. Not `/VERYSILENT`: an
///   operator who just pressed **Bijwerken** should see that something is
///   happening while their app disappears.
/// - `/NOCANCEL` — cancelling half-way through a file replacement is how an
///   install ends up in two versions at once.
/// - `/NORESTART` — never reboot the machine; a per-user install has no reason
///   to and an operator mid-sync very much has a reason not to.
/// - `/RELAUNCH=1` — read by the script's own `WantsRelaunch` check, which is
///   what starts the new version back up. A plain `postinstall` entry is
///   skipped in silent mode, so without this the app would update and then not
///   come back.
const List<String> silentInstallArguments = <String>[
  '/SILENT',
  '/NOCANCEL',
  '/NORESTART',
  '/RELAUNCH=1',
];

/// Where a downloaded installer is parked before it is run.
const String updateDownloadFolder = 'AccountManager-update';

/// The running build's version, as `pubspec.yaml` declared it.
///
/// Read from the Windows executable's own version resource, which the Flutter
/// tool populates from `pubspec.yaml` at build time — verified on a real
/// `flutter build windows` release tree, where the `version.json` asset that
/// serves this purpose on other platforms is **not** written. That keeps
/// `pubspec.yaml` the single source of truth without a code-generation step:
/// the same field feeds the exe resource, the release tag check and this.
///
/// Returns `null` rather than throwing when the resource cannot be read (a
/// headless test process, a platform with no such resource). The controller
/// treats an unknown version as "cannot compare" and declines to offer
/// anything, which is the safe reading.
Future<String?> readInstalledVersion() async {
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final String version = info.version.trim();
    return version.isEmpty ? null : version;
  } on Object {
    return null;
  }
}

/// Downloads [release]'s installer into `%TEMP%\AccountManager-update\`.
///
/// Streamed to disk rather than buffered: the installer is tens of megabytes and
/// there is no reason to hold all of it in the heap of an app that is about to
/// exit. The file is named after the release so a retry cannot pick up a
/// half-written download of a different version.
Future<File> downloadRelease(
  AppRelease release,
  void Function(double fraction) onProgress, {
  http.Client? client,
  Directory? into,
}) async {
  final http.Client httpClient = client ?? http.Client();
  final bool ownsClient = client == null;
  try {
    final Directory dir = into ??
        Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          '$updateDownloadFolder',
        );
    dir.createSync(recursive: true);

    final String name = release.installerUrl.pathSegments.isEmpty
        ? '$installerAssetPrefix${release.version}$installerAssetSuffix'
        : release.installerUrl.pathSegments.last;
    final File target = File('${dir.path}${Platform.pathSeparator}$name');
    // A leftover from an interrupted attempt is not a resumable download.
    if (target.existsSync()) target.deleteSync();

    final http.StreamedResponse response =
        await httpClient.send(http.Request('GET', release.installerUrl));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'De download antwoordde ${response.statusCode}.',
        release.installerUrl,
      );
    }

    final int? total = response.contentLength;
    var received = 0;
    final IOSink sink = target.openWrite();
    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) onProgress(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return target;
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// Launches [installer] silently and ends this process.
///
/// The exit is the point, not an afterthought: Inno Setup is about to replace
/// the executable this code is running from, and `CloseApplications=yes` in the
/// script is the belt to this pair of braces. Detached, so the installer
/// outlives the process that started it.
Future<void> runInstallerAndExit(File installer) async {
  await Process.start(
    installer.path,
    silentInstallArguments,
    mode: ProcessStartMode.detached,
  );
  // Give the child a moment to actually be running before the parent goes away.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(0);
}

/// The update seams for a real install (#371).
///
/// [autoCheck] is what decides whether a launch reaches out by itself; `main()`
/// passes `kReleaseMode` so a checkout being developed against — and every
/// integration-test launch — stays offline.
UpdateServices productionUpdateServices({
  required bool autoCheck,
  http.Client? client,
}) {
  final http.Client httpClient = client ?? http.Client();
  return UpdateServices(
    readVersion: readInstalledVersion,
    feed: GitHubReleaseFeed(client: httpClient).latest,
    download: (AppRelease release, void Function(double) onProgress) =>
        downloadRelease(release, onProgress, client: httpClient),
    run: runInstallerAndExit,
    autoCheck: autoCheck,
  );
}
