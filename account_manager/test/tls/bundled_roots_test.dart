/// The embedded GlobalSign roots (#454): each loads, each is the certificate
/// its documentation says it is, and none is anywhere near expiry.
///
/// The fingerprint and expiry checks read the PEM themselves — a minimal DER
/// walk and a textbook SHA-256 — rather than pull in a dependency for five
/// certificates. Both are self-checking: the fingerprints they must reproduce
/// were verified against the Windows store, the Mozilla bundle and GlobalSign's
/// repository when the roots were embedded, so a bug in either helper fails the
/// suite instead of hiding in it.
library;

import 'dart:convert' show ascii, base64, latin1, utf8;
import 'dart:io' show SecurityContext;
import 'dart:typed_data';

import 'package:account_manager/src/tls/bundled_roots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bundled roots', () {
    test("are GlobalSign's five TLS roots, Smartschool's anchor R3 first", () {
      expect(bundledRoots.map((r) => r.name), <String>[
        'GlobalSign Root CA - R3',
        'GlobalSign Root CA - R6',
        'GlobalSign ECC Root CA - R5',
        'GlobalSign Root R46',
        'GlobalSign Root E46',
      ]);
    });

    for (final root in bundledRoots) {
      group(root.name, () {
        test('loads into an empty SecurityContext', () {
          final context = SecurityContext(withTrustedRoots: false);
          expect(
            () => context.setTrustedCertificatesBytes(utf8.encode(root.pem)),
            returnsNormally,
          );
        });

        test('is the certificate its documented SHA-256 names', () {
          expect(_hex(_sha256(_derOf(root.pem))), root.sha256);
        });

        test('is a self-issued root named for itself', () {
          final facts = _X509Facts.parse(_derOf(root.pem));
          expect(facts.subject, facts.issuer);
          expect(latin1.decode(facts.subject), contains(root.name));
        });

        test('documents the expiry the certificate carries', () {
          final facts = _X509Facts.parse(_derOf(root.pem));
          expect(facts.notAfter, root.notAfter);
          expect(facts.notBefore.isBefore(DateTime.now()), isTrue);
        });

        test('expires more than a year from today', () {
          final horizon = DateTime.now().toUtc().add(const Duration(days: 365));
          expect(
            root.notAfter.isAfter(horizon),
            isTrue,
            reason: '${root.name} expires on ${root.expires}: refresh the '
                'bundle (docs/release-process.md, "Bundled TLS roots").',
          );
        });
      });
    }

    test('trustBundledRoots tolerates roots the context already holds', () {
      // On every up-to-date machine the default context already carries R3
      // from the Windows store, so a duplicate must be a no-op, not a throw.
      final context = SecurityContext(withTrustedRoots: false);
      trustBundledRoots(context);
      expect(() => trustBundledRoots(context), returnsNormally);
    });

    test('trustBundledRoots applies on top of the platform roots', () {
      // The startup shape: `withTrustedRoots: true` reads the same stores the
      // default context does, without touching the process-wide one here.
      final context = SecurityContext(withTrustedRoots: true);
      expect(() => trustBundledRoots(context), returnsNormally);
    });
  });
}

/// The DER bytes inside one PEM block.
Uint8List _derOf(String pem) {
  final body = pem
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return base64.decode(body);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// The handful of X.509 facts the tests compare against the documentation.
///
/// RFC 5280 §4.1: `Certificate ::= SEQUENCE { tbsCertificate, ... }` and
/// `TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
/// signature, issuer, validity SEQUENCE { notBefore, notAfter }, subject,
/// ... }`.
class _X509Facts {
  const _X509Facts({
    required this.issuer,
    required this.subject,
    required this.notBefore,
    required this.notAfter,
  });

  final Uint8List issuer;
  final Uint8List subject;
  final DateTime notBefore;
  final DateTime notAfter;

  static _X509Facts parse(Uint8List der) {
    final certificate = _Tlv.at(der, 0);
    final tbs = _Tlv.at(der, certificate.contentStart);
    var serial = _Tlv.at(der, tbs.contentStart);
    if (serial.tag == 0xa0) serial = _Tlv.at(der, serial.end); // [0] version
    expect(serial.tag, 0x02, reason: 'serialNumber is an INTEGER');
    final signature = _Tlv.at(der, serial.end);
    final issuer = _Tlv.at(der, signature.end);
    final validity = _Tlv.at(der, issuer.end);
    final subject = _Tlv.at(der, validity.end);
    final notBefore = _Tlv.at(der, validity.contentStart);
    final notAfter = _Tlv.at(der, notBefore.end);
    return _X509Facts(
      issuer: der.sublist(issuer.start, issuer.end),
      subject: der.sublist(subject.start, subject.end),
      notBefore: _time(der, notBefore),
      notAfter: _time(der, notAfter),
    );
  }

  /// UTCTime (`YYMMDDHHMMSSZ`, tag 0x17, where 50–99 means 19xx) or
  /// GeneralizedTime (`YYYYMMDDHHMMSSZ`, tag 0x18).
  static DateTime _time(Uint8List der, _Tlv t) {
    expect(t.tag, anyOf(0x17, 0x18), reason: 'a Time');
    var text = ascii.decode(der.sublist(t.contentStart, t.end));
    if (t.tag == 0x17) {
      text = (int.parse(text.substring(0, 2)) >= 50 ? '19' : '20') + text;
    }
    expect(text, endsWith('Z'), reason: 'a UTC Time');
    int at(int from) => int.parse(text.substring(from, from + 2));
    return DateTime.utc(
      int.parse(text.substring(0, 4)),
      at(4),
      at(6),
      at(8),
      at(10),
      at(12),
    );
  }
}

/// One DER tag-length-value: where it starts, where its content starts, where
/// it ends.
class _Tlv {
  const _Tlv(this.tag, this.start, this.contentStart, this.end);

  final int tag;
  final int start;
  final int contentStart;
  final int end;

  static _Tlv at(Uint8List bytes, int start) {
    final tag = bytes[start];
    var i = start + 1;
    var length = bytes[i++];
    if ((length & 0x80) != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var k = 0; k < count; k++) {
        length = (length << 8) | bytes[i++];
      }
    }
    return _Tlv(tag, start, i, i + length);
  }
}

const int _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask;

/// FIPS 180-4 SHA-256 on the VM's 64-bit ints, masked to 32 bits throughout.
Uint8List _sha256(Uint8List message) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final padded = BytesBuilder()
    ..add(message)
    ..addByte(0x80);
  while (padded.length % 64 != 56) {
    padded.addByte(0);
  }
  padded.add(
    (ByteData(8)..setUint64(0, message.length * 8)).buffer.asUint8List(),
  );
  final data = padded.toBytes();

  final w = List<int>.filled(64, 0);
  for (var offset = 0; offset < data.length; offset += 64) {
    final block = ByteData.sublistView(data, offset, offset + 64);
    for (var i = 0; i < 16; i++) {
      w[i] = block.getUint32(i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & _mask & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    h[0] = (h[0] + a) & _mask;
    h[1] = (h[1] + b) & _mask;
    h[2] = (h[2] + c) & _mask;
    h[3] = (h[3] + d) & _mask;
    h[4] = (h[4] + e) & _mask;
    h[5] = (h[5] + f) & _mask;
    h[6] = (h[6] + g) & _mask;
    h[7] = (h[7] + hh) & _mask;
  }

  final digest = ByteData(32);
  for (var i = 0; i < 8; i++) {
    digest.setUint32(i * 4, h[i]);
  }
  return digest.buffer.asUint8List();
}
