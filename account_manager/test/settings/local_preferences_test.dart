/// The per-operator, per-machine preference bag (#394).
///
/// Two properties carry the feature: a value the operator confirmed with is
/// still there after a restart, and nothing about this file may ever be able to
/// take a launch down. The rest is the extension contract — an unknown key
/// written by another build survives a save from this one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('am-prefs-test');
    file =
        File('${dir.path}${Platform.pathSeparator}$localPreferencesFileName');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('the remembered uitschrijvingsdatum', () {
    test('a fresh install remembers nothing', () async {
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));
      await prefs.load();

      expect(prefs.lastDeletionDate, isNull);
      expect(file.existsSync(), isFalse, reason: 'a read writes nothing');
    });

    test('survives a restart — a second load reads the first save', () async {
      final first = LocalPreferences(FileLocalPreferenceStore(file));
      await first.load();
      await first.setLastDeletionDate(DateTime(2026, 3, 14));

      // A whole new process's worth of state, over the same file.
      final second = LocalPreferences(FileLocalPreferenceStore(file));
      await second.load();

      expect(second.lastDeletionDate, DateTime(2026, 3, 14));
    });

    test('is stored date-only, so the default cannot drift by hours', () async {
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 3, 14, 17, 42, 9));

      final reloaded = LocalPreferences(FileLocalPreferenceStore(file));
      await reloaded.load();

      expect(reloaded.lastDeletionDate, DateTime(2026, 3, 14));
    });

    test('the in-memory store remembers for the session', () async {
      final prefs = LocalPreferences.inMemory();
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 6, 30));

      expect(prefs.lastDeletionDate, DateTime(2026, 6, 30));
    });
  });

  group('the release-notes marker (#395)', () {
    test('a fresh install has recorded nothing', () async {
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));
      await prefs.load();

      expect(prefs.releaseNotesSeenVersion, isNull);
    });

    test('survives a restart, because an update is what triggers the dialog',
        () async {
      // The criterion that decides where this lives: the installer replaces
      // `%LOCALAPPDATA%\Programs\AccountManager` and never touches `%APPDATA%`,
      // so a marker in this file outlives the very update it exists to
      // recognise.
      final first = LocalPreferences(FileLocalPreferenceStore(file));
      await first.load();
      await first.setReleaseNotesSeenVersion('1.2.0');

      final second = LocalPreferences(FileLocalPreferenceStore(file));
      await second.load();

      expect(second.releaseNotesSeenVersion, '1.2.0');
    });

    test('a blank or non-string value reads as nothing recorded', () async {
      file.writeAsStringSync('{"releaseNotesSeenVersion": "  "}');
      final blank = LocalPreferences(FileLocalPreferenceStore(file));
      await blank.load();
      expect(blank.releaseNotesSeenVersion, isNull);

      file.writeAsStringSync('{"releaseNotesSeenVersion": 120}');
      final wrongType = LocalPreferences(FileLocalPreferenceStore(file));
      await wrongType.load();
      expect(wrongType.releaseNotesSeenVersion, isNull);
    });

    test('it lives beside the date rather than replacing it', () async {
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 3, 14));
      await prefs.setReleaseNotesSeenVersion('1.2.0');

      final reloaded = LocalPreferences(FileLocalPreferenceStore(file));
      await reloaded.load();

      expect(reloaded.lastDeletionDate, DateTime(2026, 3, 14));
      expect(reloaded.releaseNotesSeenVersion, '1.2.0');
    });
  });

  group('the bag never takes a launch down', () {
    test('a file that is not JSON reads as nothing remembered', () async {
      file.writeAsStringSync('this is not json {{{');
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));

      await prefs.load();

      expect(prefs.lastDeletionDate, isNull);
    });

    test('a JSON array (not an object) reads as nothing remembered', () async {
      file.writeAsStringSync('[1, 2, 3]');
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));

      await prefs.load();

      expect(prefs.lastDeletionDate, isNull);
    });

    test('an empty file reads as nothing remembered', () async {
      file.writeAsStringSync('   \n');
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));

      await prefs.load();

      expect(prefs.lastDeletionDate, isNull);
    });

    test('a value that is not a date reads as nothing remembered', () async {
      file.writeAsStringSync('{"lastDeletionDate": "geen datum"}');
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));

      await prefs.load();

      expect(prefs.lastDeletionDate, isNull);
    });

    test('a directory where the file should be does not throw', () async {
      Directory(file.path).createSync(recursive: true);
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));

      await prefs.load();
      // And a save over it is best effort, not an exception into the UI.
      await prefs.setLastDeletionDate(DateTime(2026, 3, 14));

      expect(prefs.lastDeletionDate, DateTime(2026, 3, 14),
          reason: 'the session keeps its answer even when the disk refuses it');
    });
  });

  group('the bag is extensible (what #395 and later keys rely on)', () {
    test('a key this build does not know survives a save', () async {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{'somethingFromAnotherBuild': 'keep me'}),
      );
      final prefs = LocalPreferences(FileLocalPreferenceStore(file));
      await prefs.load();

      await prefs.setLastDeletionDate(DateTime(2026, 3, 14));

      final Object? written = jsonDecode(file.readAsStringSync());
      expect(written, isA<Map<String, dynamic>>());
      expect(
        (written! as Map<String, dynamic>)['somethingFromAnotherBuild'],
        'keep me',
        reason: 'two builds sharing one machine must not erase each other',
      );
      expect((written as Map<String, dynamic>)['lastDeletionDate'], isNotNull);
    });

    test('the store is named so the operator can find the file', () {
      expect(
        FileLocalPreferenceStore(file).location,
        endsWith(localPreferencesFileName),
      );
      expect(
        InMemoryLocalPreferenceStore().location,
        contains(localPreferencesFileName),
      );
    });
  });
}
