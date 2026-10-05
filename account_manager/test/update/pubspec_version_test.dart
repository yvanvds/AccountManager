import 'dart:io';

import 'package:account_manager/src/update/app_release.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';

/// `pubspec.yaml`'s `version:` is a bare semantic version, with no `+N` build
/// number (#440).
///
/// The build number used to be bumped by hand on every release and was read by
/// nothing — the installer, the tag check and the update check all compare on
/// the semantic version alone — so it was dropped rather than automated. This
/// is the check that keeps it dropped: the habit of typing `+7` on the next
/// bump is exactly the drift #440 removed, and this fails on the bump PR, in
/// the headless job, before anything is built. `docs/release-process.md` →
/// "There is no build number" says why.
void main() {
  test('pubspec.yaml declares a bare X.Y.Z, with no +N build number (#440)',
      () {
    // `flutter test` runs from the package root, so this is the app's own file.
    final File pubspec = File('pubspec.yaml');
    expect(pubspec.readAsStringSync(), contains('name: account_manager'),
        reason: 'expected to run from account_manager/');

    final RegExpMatch? line =
        RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true)
            .firstMatch(pubspec.readAsStringSync());
    expect(line, isNotNull, reason: 'no version: field in pubspec.yaml');
    final String declared = line!.group(1)!;

    // The value the release workflow claims a tag against and the update
    // check compares on: it has to parse as a version at all.
    final Version? version = parseReleaseTag(declared);
    expect(version, isNotNull,
        reason: '"$declared" is not a version the release check can compare');

    expect(version!.build, isEmpty,
        reason: 'pubspec.yaml declares "$declared": the +N build number was '
            'dropped in #440 because nothing reads it. Write a bare '
            '"${version.major}.${version.minor}.${version.patch}" — the '
            'version bump is what tells two releases apart.');
  });
}
