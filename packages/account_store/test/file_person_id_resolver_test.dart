import 'dart:convert';
import 'dart:io';

import 'package:account_core/account_core.dart';
import 'package:account_store/account_store.dart';
import 'package:test/test.dart';

void main() {
  group('FilePersonIdResolver', () {
    late Directory tmp;
    late String path;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('account_store_test');
      path = '${tmp.path}/person_ids.json';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('mints a non-empty PersonId for an unseen key', () async {
      final resolver = await FilePersonIdResolver.load(path);
      final id = resolver.resolve('wisa:123');
      expect(id, isA<PersonId>());
      expect(id.value, isNotEmpty);
    });

    test('returns the same id for the same key within a run', () async {
      final resolver = await FilePersonIdResolver.load(path);
      expect(
          resolver.resolve('wisa:123'), equals(resolver.resolve('wisa:123')));
    });

    test('returns different ids for different keys', () async {
      final resolver = await FilePersonIdResolver.load(path);
      expect(resolver.resolve('a'), isNot(equals(resolver.resolve('b'))));
    });

    test('round-trips: a fresh run reuses the persisted id', () async {
      final first = await FilePersonIdResolver.load(path);
      final id = first.resolve('wisa:123');

      final second = await FilePersonIdResolver.load(path);
      expect(second.resolve('wisa:123'), equals(id));
    });

    test('mints exactly once per key, even across repeated resolves', () async {
      var mints = 0;
      String counter() => 'id-${mints++}';
      final resolver = await FilePersonIdResolver.load(path, mintId: counter);

      resolver.resolve('a');
      resolver.resolve('a');
      resolver.resolve('a');

      expect(mints, equals(1));
      expect(resolver.resolve('a'), equals(const PersonId('id-0')));
    });

    test('a later run reuses persisted ids and only mints for new keys',
        () async {
      var mints = 0;
      String counter() => 'id-${mints++}';

      final first = await FilePersonIdResolver.load(path, mintId: counter);
      first.resolve('a'); // mints id-0

      final second = await FilePersonIdResolver.load(path, mintId: counter);
      final a = second.resolve('a'); // reused — no mint
      final b = second.resolve('b'); // mints id-1

      expect(a, equals(const PersonId('id-0')));
      expect(b, equals(const PersonId('id-1')));
      expect(mints, equals(2));
    });

    test('persists a JSON object mapping keys to ids', () async {
      final resolver = await FilePersonIdResolver.load(path);
      final id = resolver.resolve('wisa:123');

      final decoded =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(decoded, equals({'wisa:123': id.value}));
    });

    test('creates parent directories on first persist', () async {
      final nested = '${tmp.path}/a/b/c/person_ids.json';
      final resolver = await FilePersonIdResolver.load(nested);
      resolver.resolve('k');
      expect(File(nested).existsSync(), isTrue);
    });
  });
}
