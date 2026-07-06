import 'dart:convert';
import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

PasswordEntry _accountEntry() => const PasswordEntry(
      personId: PersonId('p-1'),
      kind: PasswordAccountKind.account,
      accountName: 'jan.jansen',
      displayName: 'Jan Jansen',
      mail: 'jan.jansen@example.org',
      classGroup: '1A',
      smartschoolPassword: 'Sa2b!x',
      azurePassword: 'Ku9d?y',
    );

PasswordEntry _coAccountEntry() => const PasswordEntry(
      personId: PersonId('p-2'),
      kind: PasswordAccountKind.coAccount,
      accountName: 'els.peeters',
      displayName: 'Els Peeters',
      classGroup: '1A',
      coAccountPasswords: <int, String>{1: 'Sa2b!x', 3: 'Ku9d?y'},
    );

void expectSameEntry(PasswordEntry a, PasswordEntry b) {
  expect(a.toJson(), equals(b.toJson()));
}

void main() {
  group('PasswordEntry JSON', () {
    test('round-trips a fully-populated account entry', () {
      final restored = PasswordEntry.fromJson(_accountEntry().toJson());
      expectSameEntry(restored, _accountEntry());
      expect(restored.personId, const PersonId('p-1'));
    });

    test('round-trips a co-account entry with null optionals', () {
      final restored = PasswordEntry.fromJson(_coAccountEntry().toJson());
      expectSameEntry(restored, _coAccountEntry());
      expect(restored.kind, PasswordAccountKind.coAccount);
      expect(restored.mail, isNull);
    });

    test('omits null optionals from the serialized map', () {
      final json = _coAccountEntry().toJson();
      expect(json.containsKey('mail'), isFalse);
      expect(json.containsKey('azurePassword'), isFalse);
    });

    test('round-trips co-account passwords keyed by slot (#180)', () {
      final restored = PasswordEntry.fromJson(_coAccountEntry().toJson());
      expect(restored.coAccountPasswords, {1: 'Sa2b!x', 3: 'Ku9d?y'});
      expectSameEntry(restored, _coAccountEntry());
    });

    test('an account entry serializes no coAccountPasswords key', () {
      expect(
          _accountEntry().toJson().containsKey('coAccountPasswords'), isFalse);
      expect(_accountEntry().coAccountPasswords, isEmpty);
    });

    test('throws on an unknown kind tag', () {
      expect(
        () => PasswordEntry.fromJson({
          'personId': 'p',
          'kind': 'bogus',
          'accountName': 'a',
          'displayName': 'b',
        }),
        throwsFormatException,
      );
    });
  });

  void queueContract(String name, PasswordQueueStore Function() make) {
    group('$name (PasswordQueueStore contract)', () {
      test('load returns an empty queue when nothing is saved', () async {
        expect(await make().load(), isEmpty);
      });

      test('save then load round-trips the queue', () async {
        final store = make();
        final entries = [_accountEntry(), _coAccountEntry()];
        await store.save(entries);
        final loaded = await store.load();
        expect(loaded, hasLength(2));
        expectSameEntry(loaded[0], _accountEntry());
        expectSameEntry(loaded[1], _coAccountEntry());
      });

      test('save replaces the whole queue', () async {
        final store = make();
        await store.save([_accountEntry()]);
        await store.save([_coAccountEntry()]);
        final loaded = await store.load();
        expect(loaded, hasLength(1));
        expect(loaded.single.personId, const PersonId('p-2'));
      });
    });
  }

  queueContract('InMemoryPasswordQueueStore', InMemoryPasswordQueueStore.new);

  group('InMemoryPasswordQueueStore isolation', () {
    test('mutating the caller list after save does not affect the store',
        () async {
      final store = InMemoryPasswordQueueStore();
      final entries = [_accountEntry()];
      await store.save(entries);
      entries.clear();
      expect(await store.load(), hasLength(1));
    });

    test('mutating a loaded list does not affect the store', () async {
      final store = InMemoryPasswordQueueStore([_accountEntry()]);
      final loaded = await store.load();
      loaded.clear();
      expect(await store.load(), hasLength(1));
    });
  });

  group('FilePasswordQueueStore', () {
    late Directory tmp;
    late String path;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('account_state_pwq');
      path = '${tmp.path}/passwords.json';
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    queueContract('file-backed', () => FilePasswordQueueStore(path));

    test('persists across a fresh store on the same path', () async {
      await FilePasswordQueueStore(path).save([_accountEntry()]);
      final loaded = await FilePasswordQueueStore(path).load();
      expect(loaded, hasLength(1));
      expectSameEntry(loaded.single, _accountEntry());
    });

    test('load treats an empty file as an empty queue', () async {
      File(path).writeAsStringSync('');
      expect(await FilePasswordQueueStore(path).load(), isEmpty);
    });

    test('writes a JSON array', () async {
      await FilePasswordQueueStore(path).save([_accountEntry()]);
      final decoded = jsonDecode(File(path).readAsStringSync());
      expect(decoded, isA<List<dynamic>>());
      expect(decoded, hasLength(1));
    });
  });
}
