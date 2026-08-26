/// What a published release looks like to the app, and how the GitHub Releases
/// API is asked about one (#371).
///
/// Deliberately the half of the update mechanism we own outright. The download,
/// the launch and the version comparison are all a few lines each; the part that
/// is genuinely likely to need changing — which repository, which asset naming
/// convention, what counts as "the latest" — is exactly this file, so it is
/// plain Dart over `package:http` rather than a callback handed to a package.
///
/// The repository is public, so the feed is queried **unauthenticated**: no
/// token is stored on an operator's machine, and the anonymous rate limit (60
/// requests per hour per IP) is orders of magnitude above one check per launch.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

/// The repository the releases are published to.
const String releaseOwner = 'yvanvds';
const String releaseRepo = 'AccountManager';

/// The installer asset's name, as the release workflow uploads it. Only the
/// shape matters here — the version in the middle varies per release.
///
/// Kept as a prefix/suffix pair rather than a full pattern so
/// [installerAssetUrl] can prefer the *right* asset while still accepting any
/// single `.exe` a future release happens to name differently.
const String installerAssetPrefix = 'AccountManager-Setup-v';
const String installerAssetSuffix = '.exe';

/// One published release: the version it carries and the installer to run.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.installerUrl,
    this.notes = '',
    this.pageUrl = '',
  });

  /// The release's semantic version, with the tag's leading `v` already gone.
  final Version version;

  /// Where the Windows installer for [version] can be downloaded from.
  final Uri installerUrl;

  /// The release notes, as written on the GitHub release.
  final String notes;

  /// The release's own page, for an operator who would rather read it there.
  final String pageUrl;

  @override
  String toString() => 'AppRelease($version, $installerUrl)';
}

/// Answers "is there a published release, and which?" — `null` when the
/// repository has none yet, or none carrying an installer.
///
/// A seam rather than a class so a test binds a closure and never touches the
/// network, and so the production implementation stays free to change shape.
typedef ReleaseFeed = Future<AppRelease?> Function();

/// Parses a release tag (`v1.2.3`, or a bare `1.2.3`) into a [Version].
///
/// Returns `null` rather than throwing on anything that is not a version: a tag
/// somebody pushed by hand must not be able to crash a launch-time check.
Version? parseReleaseTag(String tag) {
  final String trimmed = tag.trim();
  final String bare = trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
  try {
    return Version.parse(bare);
  } on FormatException {
    return null;
  }
}

/// Picks the Windows installer out of a release's asset list.
///
/// Prefers the asset the release workflow actually uploads
/// (`AccountManager-Setup-vX.Y.Z.exe`) and falls back to any single `.exe`, so a
/// release published by hand with a different name is still offerable. Returns
/// `null` when the release carries no installer at all — a source-only release
/// is not something to offer an operator.
Uri? installerAssetUrl(List<Map<String, dynamic>> assets) {
  Uri? parse(Map<String, dynamic> asset) {
    final Object? url = asset['browser_download_url'];
    return url is String ? Uri.tryParse(url) : null;
  }

  String nameOf(Map<String, dynamic> asset) {
    final Object? name = asset['name'];
    return name is String ? name : '';
  }

  for (final Map<String, dynamic> asset in assets) {
    final String name = nameOf(asset);
    if (name.startsWith(installerAssetPrefix) &&
        name.endsWith(installerAssetSuffix)) {
      final Uri? url = parse(asset);
      if (url != null) return url;
    }
  }
  for (final Map<String, dynamic> asset in assets) {
    if (nameOf(asset).toLowerCase().endsWith(installerAssetSuffix)) {
      final Uri? url = parse(asset);
      if (url != null) return url;
    }
  }
  return null;
}

/// Reads a `/releases/latest` payload into an [AppRelease].
///
/// Returns `null` when the payload is not a release we can offer: an
/// unparseable tag, or no installer asset. Split out from the HTTP call so the
/// parsing is unit-testable against a captured payload without a fake client.
AppRelease? releaseFromJson(Map<String, dynamic> json) {
  final Object? tag = json['tag_name'];
  if (tag is! String) return null;
  final Version? version = parseReleaseTag(tag);
  if (version == null) return null;

  final Object? rawAssets = json['assets'];
  final List<Map<String, dynamic>> assets = rawAssets is List
      ? rawAssets.whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];
  final Uri? installer = installerAssetUrl(assets);
  if (installer == null) return null;

  return AppRelease(
    version: version,
    installerUrl: installer,
    notes: json['body'] is String ? json['body'] as String : '',
    pageUrl: json['html_url'] is String ? json['html_url'] as String : '',
  );
}

/// The production [ReleaseFeed]: GitHub's `/releases/latest` for this repo.
///
/// `/releases/latest` already excludes drafts and pre-releases, which is the
/// behaviour wanted here — tagging a pre-release must not push it at every
/// operator — so no filtering of our own is needed.
class GitHubReleaseFeed {
  GitHubReleaseFeed({
    required http.Client client,
    this.owner = releaseOwner,
    this.repo = releaseRepo,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client;

  final http.Client _client;
  final String owner;
  final String repo;

  /// A launch-time check that hangs is a launch-time stall in everything but
  /// name, so the request is bounded even though nothing waits on it.
  final Duration timeout;

  Uri get endpoint =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  /// Fetches the latest release, or `null` when there is none to offer.
  ///
  /// Throws on a transport or server failure — the caller ([UpdateController])
  /// is what turns that into a logged, silent non-event.
  Future<AppRelease?> latest() async {
    final http.Response response = await _client.get(
      endpoint,
      headers: const <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ).timeout(timeout);

    // 404 is the honest answer for a repository that has published nothing yet,
    // not a failure to report.
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw http.ClientException(
        'GitHub answered ${response.statusCode} for $endpoint',
        endpoint,
      );
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    return releaseFromJson(decoded);
  }
}
