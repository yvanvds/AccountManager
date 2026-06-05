import 'dart:convert';

import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryTokenCache', () {
    test('read/write/clear lifecycle', () async {
      final cache = InMemoryTokenCache();
      expect(await cache.read(), isNull);
      await cache.write('payload');
      expect(await cache.read(), 'payload');
      await cache.clear();
      expect(await cache.read(), isNull);
    });
  });

  group('EncryptedTokenCache', () {
    test('inner cache only ever sees ciphertext; read decrypts it', () async {
      final inner = InMemoryTokenCache();
      // A trivial reversible cipher stands in for the platform DPAPI /
      // secure-storage transform the Flutter app supplies.
      final cache = EncryptedTokenCache(
        inner: inner,
        encrypt: (p) => base64.encode(utf8.encode(p)),
        decrypt: (c) => utf8.decode(base64.decode(c)),
      );

      await cache.write('{"access_token":"secret"}');

      // At rest, the inner store holds ciphertext, not the plaintext token.
      final atRest = await inner.read();
      expect(atRest, isNot(contains('access_token')));
      expect(atRest, base64.encode(utf8.encode('{"access_token":"secret"}')));

      // Round-trip restores the original.
      expect(await cache.read(), '{"access_token":"secret"}');
    });

    test('read returns null when nothing is stored', () async {
      final cache = EncryptedTokenCache(
        inner: InMemoryTokenCache(),
        encrypt: (p) => p,
        decrypt: (c) => c,
      );
      expect(await cache.read(), isNull);
    });

    test('clear wipes the inner store', () async {
      final inner = InMemoryTokenCache();
      final cache = EncryptedTokenCache(
        inner: inner,
        encrypt: (p) => p,
        decrypt: (c) => c,
      );
      await cache.write('x');
      await cache.clear();
      expect(await inner.read(), isNull);
    });
  });
}
