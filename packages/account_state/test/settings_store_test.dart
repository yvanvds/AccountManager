import 'dart:convert';
import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A representative config exercising both flags and every import-rule variant.
AppSettings _sampleSettings() => const AppSettings(
      schoolPrefix: 'SMA',
      debugMode: true,
      wisaRules: [
        DontImportClass('1A'),
        DontImportUserFromWisa('U42'),
        ReplaceInstitute(original: '001', replacement: '002'),
        MarkAsVirtual('VIRT'),
      ],
      smartschoolRules: [
        DiscardSmartschoolGroup('Archief'),
        NoSmartschoolSubgroups('Klassen'),
      ],
    );

void expectSameSettings(AppSettings a, AppSettings b) {
  expect(a.schoolPrefix, b.schoolPrefix);
  expect(a.debugMode, b.debugMode);
  expect(encodeRules(a.wisaRules, encodeWisaRule),
      equals(encodeRules(b.wisaRules, encodeWisaRule)));
  expect(encodeRules(a.smartschoolRules, encodeSmartschoolRule),
      equals(encodeRules(b.smartschoolRules, encodeSmartschoolRule)));
}

List<Map<String, dynamic>> encodeRules<T>(
        List<T> rules, Map<String, dynamic> Function(T) enc) =>
    rules.map(enc).toList();

void main() {
  group('AppSettings JSON', () {
    test('round-trips every field and rule variant', () {
      final original = _sampleSettings();
      final restored = AppSettings.fromJson(original.toJson());
      expectSameSettings(restored, original);
    });

    test('defaults fill in for a partial / older config', () {
      final settings = AppSettings.fromJson({'schoolPrefix': 'X'});
      expect(settings.schoolPrefix, 'X');
      expect(settings.debugMode, isFalse);
      expect(settings.wisaRules, isEmpty);
      expect(settings.smartschoolRules, isEmpty);
    });

    test('throws on an unknown rule type tag', () {
      expect(
        () => AppSettings.fromJson({
          'wisaRules': [
            {'type': 'bogus'}
          ],
        }),
        throwsFormatException,
      );
    });

    test('copyWith replaces only the given fields', () {
      const base = AppSettings(schoolPrefix: 'A', debugMode: true);
      final copy = base.copyWith(schoolPrefix: 'B');
      expect(copy.schoolPrefix, 'B');
      expect(copy.debugMode, isTrue);
    });
  });

  // The interface contract, run against both adapters.
  void settingsStoreContract(String name, SettingsStore Function() make) {
    group('$name (SettingsStore contract)', () {
      test('load returns defaults when nothing has been saved', () async {
        final settings = await make().load();
        expect(settings.schoolPrefix, isEmpty);
        expect(settings.debugMode, isFalse);
        expect(settings.wisaRules, isEmpty);
        expect(settings.smartschoolRules, isEmpty);
      });

      test('save then load round-trips the config', () async {
        final store = make();
        await store.save(_sampleSettings());
        expectSameSettings(await store.load(), _sampleSettings());
      });

      test('save replaces the previously stored value', () async {
        final store = make();
        await store.save(const AppSettings(schoolPrefix: 'first'));
        await store.save(const AppSettings(schoolPrefix: 'second'));
        expect((await store.load()).schoolPrefix, 'second');
      });
    });
  }

  settingsStoreContract('InMemorySettingsStore', InMemorySettingsStore.new);

  group('FileSettingsStore', () {
    late Directory tmp;
    late String path;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('account_state_settings');
      path = '${tmp.path}/config.json';
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    settingsStoreContract('file-backed', () => FileSettingsStore(path));

    test('persists across a fresh store on the same path', () async {
      await FileSettingsStore(path).save(_sampleSettings());
      expectSameSettings(
          await FileSettingsStore(path).load(), _sampleSettings());
    });

    test('load treats an empty file as defaults', () async {
      File(path).writeAsStringSync('');
      expect((await FileSettingsStore(path).load()).schoolPrefix, isEmpty);
    });

    test('creates parent directories on save', () async {
      final nested = '${tmp.path}/a/b/config.json';
      await FileSettingsStore(nested).save(const AppSettings());
      expect(File(nested).existsSync(), isTrue);
    });

    test('writes a human-readable JSON object', () async {
      await FileSettingsStore(path)
          .save(const AppSettings(schoolPrefix: 'SMA'));
      final decoded =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['schoolPrefix'], 'SMA');
    });
  });
}
