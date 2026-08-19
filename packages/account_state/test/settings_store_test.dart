import 'dart:convert';
import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A representative config exercising the flags, all three connection profiles
/// (including the work-date pair and the grade/year vocabulary), and every
/// import-rule variant.
AppSettings _sampleSettings() => AppSettings(
      schoolPrefix: 'SMA',
      debugMode: true,
      wisa: WisaConnection(
        server: 'db.example',
        port: '1521',
        database: 'WISA',
        username: 'svc',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 6, 30)),
        virtualWorkDate:
            WorkDateSetting(isNow: false, date: DateTime(2027, 9, 1)),
      ),
      smartschool: SmartschoolConnection(
        uri: 'https://school.smartschool.be',
        testUser: 'test.user',
        studentGroup: 'Leerlingen',
        staffGroup: 'Personeel',
        useGrades: true,
        useYears: true,
        grades: const ['graad 1', 'graad 2', 'graad 3'],
        years: const ['1', '2', '3', '4', '5', '6', '7'],
      ),
      azure: const AzureConnection(
        clientId: 'client-123',
        tenantId: 'tenant-456',
        domain: 'sma.onmicrosoft.com',
      ),
      wisaRules: const [
        DontImportClass('1A'),
        DontImportUserFromWisa('U42'),
        ReplaceInstitute(original: '001', replacement: '002'),
        MarkAsVirtual('VIRT'),
        MarkAsOurs('SMA'),
      ],
      smartschoolRules: const [
        DiscardSmartschoolGroup('Archief'),
        NoSmartschoolSubgroups('Klassen'),
      ],
      wisaSchools: const [
        WisaSchoolProfile(schoolId: 1, ours: true, prefix: 'SMA'),
        WisaSchoolProfile(schoolId: 2),
      ],
    );

void expectSameSettings(AppSettings a, AppSettings b) {
  expect(a.schoolPrefix, b.schoolPrefix);
  expect(a.debugMode, b.debugMode);
  expect(a.wisa, b.wisa);
  expect(a.smartschool, b.smartschool);
  expect(a.azure, b.azure);
  expect(encodeRules(a.wisaRules, encodeWisaRule),
      equals(encodeRules(b.wisaRules, encodeWisaRule)));
  expect(encodeRules(a.smartschoolRules, encodeSmartschoolRule),
      equals(encodeRules(b.smartschoolRules, encodeSmartschoolRule)));
  expect(a.wisaSchools, equals(b.wisaSchools));
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
      // A config predating the connection profiles loads with default ones.
      expect(settings.wisa, const WisaConnection());
      expect(settings.smartschool, SmartschoolConnection());
      expect(settings.azure, const AzureConnection());
    });

    test('models secrets as refs, never as values in the blob', () {
      // The model has no field to hold a secret value: the WISA password and
      // Smartschool passphrase are only ever a SecretRef, resolved out of band
      // through a SecretProvider. The blob carries the (non-sensitive) ref
      // names and no `password`/`passphrase` value key.
      final decoded = jsonDecode(jsonEncode(_sampleSettings().toJson()))
          as Map<String, dynamic>;
      final wisa = decoded['wisa'] as Map<String, dynamic>;
      final smartschool = decoded['smartschool'] as Map<String, dynamic>;
      expect(wisa['passwordRef'], 'wisa.password');
      expect(smartschool['passphraseRef'], 'smartschool.passphrase');
      expect(wisa.containsKey('password'), isFalse);
      expect(smartschool.containsKey('passphrase'), isFalse);
    });

    test('per-WISA-school ownership list round-trips through JSON', () {
      const original = AppSettings(
        wisaSchools: [
          WisaSchoolProfile(
              schoolId: 10, name: 'Sint-Jan', ours: true, prefix: 'KA'),
          WisaSchoolProfile(schoolId: 20, name: 'Sint-Pieter'),
        ],
      );
      final restored = AppSettings.fromJson(original.toJson());
      expect(restored.wisaSchools, original.wisaSchools);
      expect(restored.wisaSchools.first.name, 'Sint-Jan');
      expect(restored.wisaSchools.first.ours, isTrue);
      expect(restored.wisaSchools.first.prefix, 'KA');
      expect(restored.wisaSchools.last.name, 'Sint-Pieter');
      expect(restored.wisaSchools.last.ours, isFalse);
    });

    test('the WISA school code round-trips through JSON (#194)', () {
      const original = AppSettings(
        wisaSchools: [
          WisaSchoolProfile(
              schoolId: 10, code: 'ismaa', name: 'Sint-Jan', ours: true),
        ],
      );
      final restored = AppSettings.fromJson(original.toJson());
      expect(restored.wisaSchools, original.wisaSchools);
      expect(restored.wisaSchools.single.code, 'ismaa');
      expect(restored.wisaSchools.single.name, 'Sint-Jan');
    });

    test(
        'a school profile predating the persisted code loads with an empty '
        'name (#194)', () {
      // A pre-#194 document has only the one half, and it was filled from the
      // swapped `WisaSchool` of the day — so what sits under `name` is really
      // the short code, and the #208 migration moves it to `code`.
      final settings = AppSettings.fromJson({
        'wisaSchools': [
          {'schoolId': 42, 'name': 'ISMAA', 'ours': true, 'prefix': ''},
        ],
      });
      expect(settings.wisaSchools.single.code, 'ISMAA');
      expect(settings.wisaSchools.single.name, isEmpty);
    });

    test(
        'a settings document written before #208 loads with its code and name '
        'unswapped', () {
      // The pre-#208 layout: `code` held the long name and `name` the short
      // code. The absent `schemaVersion` is the marker that says so.
      final settings = AppSettings.fromJson({
        'wisaSchools': [
          {
            'schoolId': 25,
            'code': 'Instituut Sancta Maria-A',
            'name': 'ISMAA',
            'ours': true,
            'virtual': false,
            'prefix': '',
          },
        ],
      });
      final migrated = settings.wisaSchools.single;
      expect(migrated.code, 'ISMAA');
      expect(migrated.name, 'Instituut Sancta Maria-A');
      expect(migrated.ours, isTrue);
      // And it renders the way #204 specified, not inside out.
      expect(migrated.label, 'Instituut Sancta Maria-A (ISMAA)');
      expect(migrated.nameLabel, 'Instituut Sancta Maria-A');
    });

    test('a migrated profile is rewritten in the current layout, once', () {
      // Saving after a migration must not swap the halves a second time.
      final once = AppSettings.fromJson({
        'wisaSchools': [
          {
            'schoolId': 25,
            'code': 'Instituut Sancta Maria-A',
            'name': 'ISMAA',
          },
        ],
      });
      final twice = AppSettings.fromJson(once.toJson());
      expect(twice.wisaSchools, once.wisaSchools);
      expect(twice.wisaSchools.single.code, 'ISMAA');
      expect(
        (once.toJson()['wisaSchools'] as List).single,
        containsPair('schemaVersion', 2),
      );
    });

    test('copyWith preserves and can replace the school code (#194)', () {
      const profile =
          WisaSchoolProfile(schoolId: 10, code: 'ismaa', name: 'Sint-Jan');
      expect(profile.copyWith(ours: true).code, 'ismaa');
      expect(profile.copyWith(code: 'ismab').code, 'ismab');
    });

    test('managedWisaSchoolIds is the set of ours-flagged school ids (#178)',
        () {
      const settings = AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 10, name: 'A', ours: true),
          WisaSchoolProfile(schoolId: 20, name: 'B'),
          WisaSchoolProfile(schoolId: 30, name: 'C', ours: true),
        ],
      );
      expect(settings.managedWisaSchoolIds, {10, 30});
      expect(const AppSettings().managedWisaSchoolIds, isEmpty);
    });

    test('the per-school virtual mark round-trips through JSON (#203)', () {
      const original = AppSettings(
        wisaSchools: [
          WisaSchoolProfile(
              schoolId: 10,
              code: 'ismav',
              name: 'Virtuele school SMA',
              virtual: true),
          WisaSchoolProfile(schoolId: 20, name: 'Sint-Pieter', ours: true),
        ],
      );
      final restored = AppSettings.fromJson(original.toJson());
      expect(restored.wisaSchools, original.wisaSchools);
      expect(restored.wisaSchools.first.virtual, isTrue);
      expect(restored.wisaSchools.last.virtual, isFalse);
    });

    test('virtualWisaSchoolIds is the set of virtual-flagged school ids (#203)',
        () {
      const settings = AppSettings(
        wisaSchools: [
          WisaSchoolProfile(schoolId: 10, name: 'A', virtual: true),
          WisaSchoolProfile(schoolId: 20, name: 'B', ours: true),
          WisaSchoolProfile(schoolId: 30, name: 'C', ours: true, virtual: true),
        ],
      );
      expect(settings.virtualWisaSchoolIds, {10, 30});
      // The two marks are independent: managing a school says nothing about
      // which work date it is pulled with.
      expect(settings.managedWisaSchoolIds, {20, 30});
      expect(const AppSettings().virtualWisaSchoolIds, isEmpty);
    });

    test(
        'a settings document written before the virtual flag loads with every '
        'school non-virtual (#203)', () {
      // Pre-#203 is also pre-#208, so this document carries the swapped halves
      // and comes back through the migration.
      final settings = AppSettings.fromJson({
        'wisaSchools': [
          {
            'schoolId': 42,
            'code': 'Sint-Jan',
            'name': 'ISMAA',
            'ours': true,
            'prefix': '',
          },
        ],
      });
      expect(settings.wisaSchools.single.virtual, isFalse);
      expect(settings.virtualWisaSchoolIds, isEmpty);
      expect(settings.wisaSchools.single.code, 'ISMAA');
      expect(settings.wisaSchools.single.name, 'Sint-Jan');
    });

    test('copyWith preserves and can replace the virtual flag (#203)', () {
      const profile =
          WisaSchoolProfile(schoolId: 10, code: 'ismaa', virtual: true);
      expect(profile.copyWith(ours: true).virtual, isTrue);
      expect(profile.copyWith(virtual: false).virtual, isFalse);
    });

    test(
        'a school profile predating the persisted name loads with an empty '
        'name (#171)', () {
      final settings = AppSettings.fromJson({
        'wisaSchools': [
          {'schoolId': 42, 'ours': true, 'prefix': ''},
        ],
      });
      expect(settings.wisaSchools.single.schoolId, 42);
      expect(settings.wisaSchools.single.name, isEmpty);
      expect(settings.wisaSchools.single.ours, isTrue);
    });

    test('a config predating wisaSchools loads with an empty list', () {
      final settings = AppSettings.fromJson({'schoolPrefix': 'X'});
      expect(settings.wisaSchools, isEmpty);
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
      const base = AppSettings(
        schoolPrefix: 'A',
        debugMode: true,
        azure: AzureConnection(clientId: 'keep'),
      );
      final copy = base.copyWith(
        schoolPrefix: 'B',
        wisa: const WisaConnection(server: 'new-host'),
      );
      expect(copy.schoolPrefix, 'B');
      expect(copy.debugMode, isTrue);
      expect(copy.wisa.server, 'new-host');
      expect(copy.azure.clientId, 'keep');
    });
  });

  group('WorkDateSetting', () {
    final now = DateTime(2026, 7, 3);

    test('resolves to now when tracking the live date', () {
      const setting = WorkDateSetting(isNow: true);
      expect(setting.resolve(now), now);
    });

    test('resolves to the pinned date when not tracking now', () {
      final pinned = DateTime(2026, 6, 30);
      final setting = WorkDateSetting(isNow: false, date: pinned);
      expect(setting.resolve(now), pinned);
    });

    test('falls back to now when pinned but no date is set', () {
      const setting = WorkDateSetting(isNow: false);
      expect(setting.resolve(now), now);
    });

    test('round-trips through JSON', () {
      final setting =
          WorkDateSetting(isNow: false, date: DateTime(2026, 6, 30));
      expect(WorkDateSetting.fromJson(setting.toJson()), setting);
    });

    test('defaults to live-now with no pinned date from an empty map', () {
      final setting = WorkDateSetting.fromJson(const {});
      expect(setting.isNow, isTrue);
      expect(setting.date, isNull);
    });
  });

  group('connection profiles', () {
    test('WisaConnection round-trips including the work-date pair', () {
      final conn = WisaConnection(
        server: 'db',
        port: '1521',
        database: 'WISA',
        username: 'svc',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 6, 30)),
        virtualWorkDate: const WorkDateSetting(),
      );
      expect(WisaConnection.fromJson(conn.toJson()), conn);
    });

    test('SmartschoolConnection normalizes its label arrays to fixed length',
        () {
      final conn = SmartschoolConnection(
        grades: const ['  a  ', 'b'], // short + untrimmed
        years: const ['1', '2', '3', '4', '5', '6', '7', 'overflow'],
      );
      expect(conn.grades, ['a', 'b', '']); // padded to 3, trimmed
      expect(conn.years, ['1', '2', '3', '4', '5', '6', '7']); // capped at 7
    });

    test('SmartschoolConnection round-trips every field', () {
      final conn = SmartschoolConnection(
        uri: 'https://x',
        testUser: 'tu',
        studentGroup: 'S',
        staffGroup: 'P',
        useGrades: true,
        useYears: true,
        grades: const ['g1', 'g2', 'g3'],
        years: const ['1', '2', '3', '4', '5', '6', '7'],
      );
      expect(SmartschoolConnection.fromJson(conn.toJson()), conn);
    });

    test('AzureConnection round-trips and carries no secret ref', () {
      const conn = AzureConnection(
        clientId: 'c',
        tenantId: 't',
        domain: 'd.onmicrosoft.com',
      );
      expect(AzureConnection.fromJson(conn.toJson()), conn);
      expect(conn.toJson().keys, isNot(contains('passwordRef')));
    });

    test('a non-default SecretRef round-trips through the profile', () {
      const conn = WisaConnection(passwordRef: SecretRef('vault/wisa-pw'));
      expect(WisaConnection.fromJson(conn.toJson()).passwordRef,
          const SecretRef('vault/wisa-pw'));
    });
  });

  group('InMemorySecretProvider', () {
    const ref = SecretRef('wisa.password');

    test('reads null for an unconfigured ref', () async {
      expect(await InMemorySecretProvider().read(ref), isNull);
    });

    test('write then read returns the stored value', () async {
      final provider = InMemorySecretProvider();
      await provider.write(ref, 'hunter2');
      expect(await provider.read(ref), 'hunter2');
    });

    test('delete removes a stored value', () async {
      final provider = InMemorySecretProvider({ref: 'hunter2'});
      await provider.delete(ref);
      expect(await provider.read(ref), isNull);
    });

    test('is seeded from the initial map without aliasing it', () async {
      final seed = {ref: 'hunter2'};
      final provider = InMemorySecretProvider(seed);
      await provider.write(ref, 'changed');
      expect(seed[ref], 'hunter2'); // the caller's map is untouched
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
