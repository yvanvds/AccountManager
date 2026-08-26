import 'dart:convert';

import 'package:account_manager/src/update/app_release.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pub_semver/pub_semver.dart';

/// A `/releases/latest` payload with only the fields the feed reads.
Map<String, dynamic> _payload({
  String tag = 'v1.2.3',
  List<String> assets = const <String>['AccountManager-Setup-v1.2.3.exe'],
  String body = 'Wat er veranderd is.',
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'html_url': 'https://github.com/yvanvds/AccountManager/releases/tag/$tag',
      'body': body,
      'assets': <Map<String, dynamic>>[
        for (final String name in assets)
          <String, dynamic>{
            'name': name,
            'browser_download_url':
                'https://github.com/yvanvds/AccountManager/releases/download/'
                    '$tag/$name',
          },
      ],
    };

void main() {
  group('parseReleaseTag', () {
    test('accepts the tag shape the release workflow pushes', () {
      expect(parseReleaseTag('v1.2.3'), Version(1, 2, 3));
      expect(parseReleaseTag('1.2.3'), Version(1, 2, 3));
      expect(parseReleaseTag('  v0.9.0 '), Version(0, 9, 0));
    });

    test('answers null for anything that is not a version', () {
      // A tag pushed by hand must not be able to take a launch down.
      expect(parseReleaseTag('nightly'), isNull);
      expect(parseReleaseTag('v'), isNull);
      expect(parseReleaseTag(''), isNull);
      expect(parseReleaseTag('v1.2'), isNull);
    });

    test('orders numerically, not lexically', () {
      // The bug a hand-rolled comparison ships with: "1.0.10" < "1.0.9" as
      // strings, so an update check quietly stops offering anything after the
      // tenth patch.
      expect(parseReleaseTag('v1.0.10')! > parseReleaseTag('v1.0.9')!, isTrue);
      expect(parseReleaseTag('v1.10.0')! > parseReleaseTag('v1.9.0')!, isTrue);
    });
  });

  group('installerAssetUrl', () {
    test('prefers the asset the release workflow uploads', () {
      final Uri? url = installerAssetUrl(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'source.zip',
          'browser_download_url': 'https://example.test/source.zip',
        },
        <String, dynamic>{
          'name': 'AccountManager-Setup-v1.2.3.exe',
          'browser_download_url': 'https://example.test/setup.exe',
        },
        <String, dynamic>{
          'name': 'something-else.exe',
          'browser_download_url': 'https://example.test/other.exe',
        },
      ]);
      expect(url, Uri.parse('https://example.test/setup.exe'));
    });

    test('falls back to any .exe so a hand-published release still works', () {
      final Uri? url = installerAssetUrl(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Installer.exe',
          'browser_download_url': 'https://example.test/installer.exe',
        },
      ]);
      expect(url, Uri.parse('https://example.test/installer.exe'));
    });

    test('answers null when the release carries no installer', () {
      expect(installerAssetUrl(const <Map<String, dynamic>>[]), isNull);
      expect(
        installerAssetUrl(<Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'notes.md',
            'browser_download_url': 'https://example.test/notes.md',
          },
        ]),
        isNull,
      );
    });
  });

  group('releaseFromJson', () {
    test('reads the version, the installer and the notes', () {
      final AppRelease? release = releaseFromJson(_payload());
      expect(release, isNotNull);
      expect(release!.version, Version(1, 2, 3));
      expect(release.installerUrl.toString(), endsWith('-v1.2.3.exe'));
      expect(release.notes, 'Wat er veranderd is.');
      expect(release.pageUrl, contains('/releases/tag/v1.2.3'));
    });

    test('declines a release with no installer to offer', () {
      // A source-only release is not something to put in front of an operator:
      // accepting it would have nothing to download.
      expect(releaseFromJson(_payload(assets: const <String>[])), isNull);
    });

    test('declines an unparseable tag', () {
      expect(releaseFromJson(_payload(tag: 'nightly-2026-08-01')), isNull);
    });
  });

  group('GitHubReleaseFeed', () {
    test('asks the public unauthenticated endpoint for this repo', () async {
      late http.Request seen;
      final feed = GitHubReleaseFeed(
        client: MockClient((http.Request request) async {
          seen = request;
          return http.Response(jsonEncode(_payload()), 200);
        }),
      );

      final AppRelease? release = await feed.latest();

      expect(seen.url.host, 'api.github.com');
      expect(seen.url.path, '/repos/yvanvds/AccountManager/releases/latest');
      // No credential on an operator's machine — the repository is public and
      // the anonymous rate limit is far above one check per launch.
      expect(seen.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')));
      expect(release!.version, Version(1, 2, 3));
    });

    test('a repository with no release yet is null, not an error', () async {
      final feed = GitHubReleaseFeed(
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(await feed.latest(), isNull);
    });

    test('a server or rate-limit failure throws for the caller to swallow',
        () async {
      final feed = GitHubReleaseFeed(
        client: MockClient((_) async => http.Response('rate limited', 403)),
      );
      await expectLater(feed.latest(), throwsA(isA<http.ClientException>()));
    });
  });
}
