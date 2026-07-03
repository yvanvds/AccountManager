import 'dart:io';

import 'package:account_manager/src/auth/auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final onWindows = Platform.isWindows;

  group('Dpapi', () {
    test(
      'protects and unprotects a payload round-trip',
      () {
        const marker = 'super-secret-refresh-token-value';
        const secret = '{"accessToken":"AT","refreshToken":"$marker"}';
        final ciphertext = Dpapi.protect(secret);
        expect(ciphertext, isNot(contains(marker)),
            reason: 'ciphertext must not leak the plaintext');
        expect(Dpapi.unprotect(ciphertext), secret);
      },
      skip: onWindows ? false : 'DPAPI is Windows-only',
    );

    test(
      'a tampered payload throws FormatException (the corrupt-cache signal)',
      () {
        final ciphertext = Dpapi.protect('payload');
        // Corrupt the tail of the blob (the ciphertext/MAC region — the
        // leading DPAPI header is not integrity-relevant everywhere).
        final i = ciphertext.length - 20;
        final tampered =
            ciphertext.replaceRange(i, i + 1, ciphertext[i] == 'A' ? 'B' : 'A');
        expect(() => Dpapi.unprotect(tampered), throwsFormatException);
        expect(
          () => Dpapi.unprotect('not base64 at all!'),
          throwsFormatException,
        );
      },
      skip: onWindows ? false : 'DPAPI is Windows-only',
    );
  });

  group('FileTokenCache', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('token-cache'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round-trips through a file it creates (directories included)', () {
      final cache = FileTokenCache('${dir.path}/auth/graph.token');
      return () async {
        expect(await cache.read(), isNull, reason: 'nothing stored yet');
        await cache.write('ciphertext-1');
        expect(await cache.read(), 'ciphertext-1');
        await cache.write('ciphertext-2');
        expect(await cache.read(), 'ciphertext-2');
        await cache.clear();
        expect(await cache.read(), isNull);
        await cache.clear(); // idempotent
      }();
    });

    test('an empty file reads as no cache', () async {
      final path = '${dir.path}/empty.token';
      File(path).writeAsStringSync('');
      expect(await FileTokenCache(path).read(), isNull);
    });
  });
}
