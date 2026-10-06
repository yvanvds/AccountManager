/// Opt-in live check (#454): the certificate chain Smartschool serves today
/// anchors in the *embedded* roots alone — the situation of a freshly installed
/// PC whose Windows store has never fetched GlobalSign's roots.
///
/// Skipped unless `SMARTSCHOOL_SITE` is set (the tenant subdomain, as in
/// `.smartschool.env`; `tool/live-tests.ps1 -Only smartschool` sets it), so a
/// plain `flutter test` stays offline. Read-only by construction, per the
/// live-testing policy: one TLS handshake and nothing after it — no credential
/// is read, no request is sent.
library;

import 'dart:io';

import 'package:account_manager/src/tls/bundled_roots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final site = (Platform.environment['SMARTSCHOOL_SITE'] ?? '').trim();
  final skipReason = site.isEmpty
      ? 'SMARTSCHOOL_SITE not set; skipping the live TLS anchor check.'
      : null;

  group('bundled roots against the live Smartschool host', skip: skipReason,
      () {
    // `.smartschool.env` carries the subdomain; a full host name works too.
    final host = site.contains('.') ? site : '$site.smartschool.be';
    const timeout = Duration(seconds: 30);

    Future<void> handshake(SecurityContext context) async {
      final socket = await SecureSocket.connect(
        host,
        443,
        context: context,
        timeout: timeout,
      );
      socket.destroy();
    }

    test('the served chain anchors in the embedded roots alone', () async {
      final context = SecurityContext(withTrustedRoots: false);
      trustBundledRoots(context);
      try {
        await handshake(context);
      } on HandshakeException catch (e) {
        fail(
          'The TLS handshake with $host failed against the bundled roots alone '
          '($e). Smartschool\'s certificate chain no longer anchors in the '
          'embedded GlobalSign set, so a freshly installed PC would fail to '
          'reach it again (#454): refresh the bundle in '
          'account_manager/lib/src/tls/bundled_roots.dart — see '
          'docs/release-process.md, "Bundled TLS roots".',
        );
      }
    });

    test('control: with no roots at all the same handshake is refused',
        () async {
      // Proves the check above is not vacuous — that a context without the
      // bundle really does reject this host, as the fresh PC in #454 did.
      await expectLater(
        handshake(SecurityContext(withTrustedRoots: false)),
        throwsA(isA<HandshakeException>()),
      );
    });
  });
}
