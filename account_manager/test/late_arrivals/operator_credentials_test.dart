import 'dart:convert';
import 'dart:io';

import 'package:account_manager/src/late_arrivals/operator_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

/// A reversible stand-in for DPAPI.
///
/// The unit suite runs on the Linux CI runner, where `crypt32.dll` does not
/// exist, so the real cipher cannot be exercised here — which is the entire
/// reason [EncryptedFileCredentialStore] takes one rather than reaching for it.
/// What *is* provable here is the contract the store owes whatever cipher it is
/// given: nothing reaches the file except what came out of `encrypt`, and a
/// payload `decrypt` rejects reads as "no login configured" rather than as a
/// crash. The real DPAPI round trip is driven by the full-app run on Windows.
String _fakeEncrypt(String plaintext) =>
    'cipher:${base64Encode(utf8.encode(plaintext))}';

String _fakeDecrypt(String ciphertext) {
  if (!ciphertext.startsWith('cipher:')) {
    throw const FormatException('not our ciphertext');
  }
  return utf8.decode(base64Decode(ciphertext.substring('cipher:'.length)));
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('am-operator-cred-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File credentialFile() => File(
        '${dir.path}${Platform.pathSeparator}'
        '$smartschoolOperatorCredentialFileName',
      );

  EncryptedFileCredentialStore store() => EncryptedFileCredentialStore(
        credentialFile(),
        encrypt: _fakeEncrypt,
        decrypt: _fakeDecrypt,
      );

  group('SmartschoolOperatorLogin (#409)', () {
    test('a username without a password cannot be signed in with', () {
      const half =
          SmartschoolOperatorLogin(username: 'ann.peeters', password: '');
      expect(half.isComplete, isFalse);
      expect(half.isEmpty, isFalse, reason: 'something was typed');
    });

    test(
        'a blank password field keeps the stored one, so a username can be '
        'corrected without retyping a secret', () {
      const stored = SmartschoolOperatorLogin(
        username: 'ann.peeters',
        password: 'geheim',
        mfa: 'JBSWY3DPEHPK3PXP',
      );
      final corrected = stored.merged(
        username: 'ann.peters',
        password: '',
        mfa: '',
      );
      expect(corrected.username, 'ann.peters');
      expect(corrected.password, 'geheim');
      expect(corrected.mfa, 'JBSWY3DPEHPK3PXP');
    });

    test('a typed password replaces the stored one', () {
      const stored = SmartschoolOperatorLogin(
        username: 'ann.peeters',
        password: 'oud',
      );
      final changed = stored.merged(
        username: 'ann.peeters',
        password: 'nieuw',
        mfa: '2010-05-15',
      );
      expect(changed.password, 'nieuw');
      expect(changed.mfa, '2010-05-15');
    });

    test('it never prints its own password', () {
      const login = SmartschoolOperatorLogin(
        username: 'ann.peeters',
        password: 'zeergeheim',
      );
      expect('$login', contains('ann.peeters'));
      expect('$login', isNot(contains('zeergeheim')));
    });
  });

  group('EncryptedFileCredentialStore (#409)', () {
    test('round-trips a login through the cipher', () async {
      const login = SmartschoolOperatorLogin(
        username: 'ann.peeters',
        password: 'zeergeheim',
        mfa: 'JBSWY3DPEHPK3PXP',
      );
      await store().write(login);

      final read = await store().read();
      expect(read, isNotNull);
      expect(read!.username, 'ann.peeters');
      expect(read.password, 'zeergeheim');
      expect(read.mfa, 'JBSWY3DPEHPK3PXP');
    });

    test('the password never reaches the file in the clear', () async {
      await store().write(const SmartschoolOperatorLogin(
        username: 'ann.peeters',
        password: 'zeergeheim',
        mfa: '2010-05-15',
      ));

      final String onDisk = credentialFile().readAsStringSync();
      expect(onDisk, isNot(contains('zeergeheim')));
      expect(onDisk, isNot(contains('2010-05-15')));
      // Not even the username, since the whole document is one ciphertext.
      expect(onDisk, isNot(contains('ann.peeters')));
      expect(onDisk, startsWith('cipher:'));
    });

    test('an install that was never configured reads as no login', () async {
      expect(await store().read(), isNull);
    });

    test('a payload the cipher rejects reads as no login, not as a crash',
        () async {
      // What another Windows user's file, another machine's file, or a
      // half-written one looks like from here.
      credentialFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('van iemand anders');
      expect(await store().read(), isNull);
    });

    test('an empty file reads as no login', () async {
      credentialFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('   ');
      expect(await store().read(), isNull);
    });

    test('decrypted rubbish reads as no login', () async {
      credentialFile()
        ..createSync(recursive: true)
        ..writeAsStringSync(_fakeEncrypt('["niet", "wat", "verwacht"]'));
      expect(await store().read(), isNull);
    });

    test('a cipher that throws leaves the previous credential intact',
        () async {
      await store().write(
        const SmartschoolOperatorLogin(username: 'ann', password: 'geheim'),
      );
      final broken = EncryptedFileCredentialStore(
        credentialFile(),
        encrypt: (_) => throw const FormatException('DPAPI protect failed'),
        decrypt: _fakeDecrypt,
      );

      await expectLater(
        broken.write(
          const SmartschoolOperatorLogin(username: 'jan', password: 'nieuw'),
        ),
        throwsA(isA<FormatException>()),
      );
      // The point: a failed encryption must not truncate the file to nothing,
      // which would silently un-configure a working desk.
      final read = await store().read();
      expect(read?.username, 'ann');
      expect(read?.password, 'geheim');
    });

    test('clear removes the file, so the desk is unconfigured again', () async {
      await store().write(
        const SmartschoolOperatorLogin(username: 'ann', password: 'geheim'),
      );
      await store().clear();
      expect(credentialFile().existsSync(), isFalse);
      expect(await store().read(), isNull);
    });

    test('clearing an install that has none is a no-op', () async {
      await store().clear();
      expect(await store().read(), isNull);
    });
  });

  group('smartschoolHostFrom (#409)', () {
    test('keeps the host the Presence login signs in against', () {
      expect(
        smartschoolHostFrom('https://arcadia.smartschool.be'),
        'arcadia.smartschool.be',
      );
      expect(smartschoolHostFrom('arcadia.smartschool.be'),
          'arcadia.smartschool.be');
      expect(
        smartschoolHostFrom('  https://arcadia.smartschool.be/index.php  '),
        'arcadia.smartschool.be',
      );
    });

    test('an unconfigured document has no host', () {
      expect(smartschoolHostFrom(''), '');
      expect(smartschoolHostFrom('   '), '');
    });

    test('it is not the SOAP connector short name', () {
      // `smartschoolSiteFrom` (reconcile_bootstrap.dart) strips the suffix
      // because the SOAP connector wants "arcadia"; handing that to the
      // Presence login would sign in against a host that does not exist.
      expect(
        smartschoolHostFrom('https://arcadia.smartschool.be'),
        isNot('arcadia'),
      );
    });
  });
}
