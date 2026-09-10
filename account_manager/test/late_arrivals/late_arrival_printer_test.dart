/// The transport half of the late-arrival ticket (#406, #424).
///
/// The pure package proves what the ticket *says*; this proves the two things
/// it cannot: that the ESC/POS bytes reach the printer inside an IPP
/// `Print-Job` on port 631, and that a printer which is not there costs a piece
/// of paper rather than a registration.
///
/// No hardware anywhere. The IPP tests bind an ephemeral loopback **HTTPS**
/// listener holding a self-signed certificate — the shape of the real
/// TM-m30III — and read the request back off it, which exercises the real
/// [IppTicketTransport] end to end; the behavioural tests bind a fake so a
/// failure can be summoned on demand.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:account_manager/src/late_arrivals/ipp.dart';
import 'package:account_manager/src/late_arrivals/late_arrival_printer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

import 'self_signed_printer_certificate.dart';

/// A [TicketTransport] that records what it was asked to send, and can be made
/// to fail or to hang.
class _FakeTransport implements TicketTransport {
  _FakeTransport({this.failWith, this.gate});

  /// Thrown instead of sending, when set.
  final Object? failWith;

  /// When set, every send waits on this before completing — which is how "the
  /// scanner is free while the ticket is still coming out" is asserted.
  final Completer<void>? gate;

  final List<List<int>> sent = <List<int>>[];
  final List<String> hosts = <String>[];
  final List<int> ports = <int>[];

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    hosts.add(host);
    ports.add(port);
    sent.add(List<int>.of(bytes));
  }
}

LateArrivalRecord _record({
  String name = 'Lotte Peeters',
  String className = '3STW',
  DateTime? scannedAt,
}) {
  final DateTime at = scannedAt ?? DateTime(2026, 9, 7, 8, 14);
  return LateArrivalRecord(
    id: '2026-09-07-0003',
    day: SchoolDay.of(at),
    sequence: 3,
    scannedAt: at,
    smartschoolUid: 'lotte.peeters',
    wisaId: '123456',
    displayName: name,
    className: className,
    internalUserId: 4711,
    classGroupId: 298,
    reasonLabel: 'Verkeer',
    reasonIsValid: true,
    motivation: composeMotivation(at, 'Verkeer'),
    status: LateArrivalStatus.pending,
  );
}

void main() {
  group('a machine with no printer', () {
    test('reports itself disabled rather than broken', () {
      // An office laptop draining yesterday's queue (#403) has no printer, and
      // nagging about it every scan would train the operator to ignore the one
      // banner that matters.
      final printer = LateArrivalPrinter(host: '  ');
      addTearDown(printer.dispose);
      expect(printer.isConfigured, isFalse);
      expect(printer.status.value.state, LateArrivalPrintState.disabled);
      expect(printer.status.value.isFailure, isFalse);
      expect(printer.status.value.message, contains('geen ticketprinter'));
    });

    test('printing is a silent no-op', () async {
      final transport = _FakeTransport();
      final printer = LateArrivalPrinter(host: '', transport: transport);
      addTearDown(printer.dispose);
      printer.printRecord(_record());
      await printer.settled;
      expect(transport.sent, isEmpty);
      expect(printer.status.value.state, LateArrivalPrintState.disabled);
    });
  });

  group('what goes to the printer', () {
    test('is the ticket for that record, at the IPP port', () async {
      final transport = _FakeTransport();
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
        logo: defaultTicketLogo,
      );
      addTearDown(printer.dispose);

      final LateArrivalRecord record = _record();
      printer.printRecord(record);
      await printer.settled;

      expect(transport.hosts, <String>['10.0.0.31']);
      // 631, not 9100 (#424): the school's TM-m30III accepts a connection on
      // 9100 and then throws the bytes away.
      expect(transport.ports, <int>[ippPrintPort]);
      expect(ippPrintPort, 631);
      expect(
        transport.sent.single,
        composeTicketForRecord(record, logo: defaultTicketLogo),
      );
    });

    test('carries the scan time, not the time the printer was reached',
        () async {
      // The ticket is the teacher's evidence of *when* the student was at the
      // desk; a slow printer must not be able to move that minute.
      final gate = Completer<void>();
      final transport = _FakeTransport(gate: gate);
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      printer.printRecord(_record(scannedAt: DateTime(2026, 9, 7, 8, 4)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await printer.settled;

      expect(
        transport.sent.single,
        containsAllInOrder(encodeCp1252('08:04')),
      );
    });

    test('the host is trimmed, so a pasted address still resolves', () async {
      final transport = _FakeTransport();
      final printer = LateArrivalPrinter(
        host: '  printer-balie.school.local\t',
        transport: transport,
      );
      addTearDown(printer.dispose);
      printer.printRecord(_record());
      await printer.settled;
      expect(transport.hosts, <String>['printer-balie.school.local']);
    });
  });

  group('fire and forget', () {
    test('printing returns before the ticket has gone anywhere', () async {
      // The acceptance criterion: the next scan must be possible while the
      // ticket is still coming out. `printRecord` returns `void` and this
      // proves it does not secretly wait.
      final gate = Completer<void>();
      final transport = _FakeTransport(gate: gate);
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      printer.printRecord(_record());
      // Still nothing on the wire, and the caller is already here.
      expect(transport.sent, isEmpty);
      expect(printer.status.value.state, LateArrivalPrintState.printing);

      // …and the next student can be registered meanwhile.
      printer.printRecord(_record(name: 'Sam Willems'));
      expect(transport.sent, isEmpty);

      gate.complete();
      await printer.settled;
      expect(transport.sent, hasLength(2));
      expect(printer.status.value.state, LateArrivalPrintState.idle);
    });

    test('tickets come out in the order the students were scanned', () async {
      final transport = _FakeTransport();
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      for (final String name in <String>['Eerste', 'Tweede', 'Derde']) {
        printer.printRecord(_record(name: name));
      }
      await printer.settled;

      expect(transport.sent, hasLength(3));
      expect(_contains(transport.sent[0], encodeCp1252('Eerste')), isTrue);
      expect(_contains(transport.sent[1], encodeCp1252('Tweede')), isTrue);
      expect(_contains(transport.sent[2], encodeCp1252('Derde')), isTrue);
    });
  });

  group('a printer that is not there', () {
    test('surfaces a clear error naming the address, and does not throw',
        () async {
      final transport = _FakeTransport(
        failWith: const SocketException('connection refused'),
      );
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      // The registration is already journalled by the time this runs; nothing
      // here may escape into the scan flow.
      printer.printRecord(_record());
      await printer.settled;

      final LateArrivalPrintStatus status = printer.status.value;
      expect(status.state, LateArrivalPrintState.failed);
      expect(status.isFailure, isTrue);
      expect(status.message, contains('10.0.0.31:$ippPrintPort'));
      // …and it says the registration still stands, which is the half the
      // operator has to believe before carrying on.
      expect(status.message, contains('registratie is bewaard'));
      expect(status.error, isA<SocketException>());
    });

    test('is announced to a listener, so the desk sees it without polling',
        () async {
      final transport = _FakeTransport(failWith: 'dead');
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      final List<LateArrivalPrintState> seen = <LateArrivalPrintState>[];
      void listener() => seen.add(printer.status.value.state);
      printer.status.addListener(listener);
      addTearDown(() => printer.status.removeListener(listener));

      printer.printRecord(_record());
      await printer.settled;

      expect(seen, <LateArrivalPrintState>[
        LateArrivalPrintState.printing,
        LateArrivalPrintState.failed,
      ]);
    });

    test('does not poison the queue: the next ticket still prints', () async {
      // A printer somebody switched off and on again must not need an app
      // restart to start working.
      var fail = true;
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: _ConditionalTransport(() => fail),
      );
      addTearDown(printer.dispose);

      printer.printRecord(_record());
      await printer.settled;
      expect(printer.status.value.state, LateArrivalPrintState.failed);

      fail = false;
      printer.printRecord(_record());
      await printer.settled;
      expect(printer.status.value.state, LateArrivalPrintState.idle);
    });

    test('a ticket that cannot even be composed is reported, not thrown',
        () async {
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: _FakeTransport(),
        // Wider than the 80 mm roll: the composer refuses it rather than
        // letting the printer clip it silently.
        logo: TicketLogo.fromArt(<String>['#' * (ticketPrintWidthDots + 1)]),
      );
      addTearDown(printer.dispose);

      printer.printRecord(_record());
      await printer.settled;
      expect(printer.status.value.state, LateArrivalPrintState.failed);
      expect(printer.status.value.message, contains('registratie is bewaard'));
    });
  });

  group('printTestTicket', () {
    test('takes the same path a real ticket does', () async {
      final transport = _FakeTransport();
      final printer = LateArrivalPrinter(
        host: '10.0.0.31',
        transport: transport,
      );
      addTearDown(printer.dispose);

      printer.printTestTicket(now: DateTime(2026, 9, 7, 9, 30));
      await printer.settled;

      expect(transport.ports, <int>[ippPrintPort]);
      expect(
        transport.sent.single,
        composeLateArrivalTicket(
          displayName: 'Testticket',
          className: 'Balie',
          scannedAt: DateTime(2026, 9, 7, 9, 30),
          logo: null,
        ),
      );
    });
  });

  group('the IPP Print-Job request', () {
    // Encoding only — no socket. The wire format is fiddly enough that a
    // mis-ordered attribute or a wrong length prefix is the likeliest way this
    // breaks, and none of that needs a listener to catch.
    test('is an IPP/1.1 Print-Job carrying the document verbatim', () {
      final Uint8List request = buildIppPrintJobRequest(
        printerUri: 'ipps://10.0.0.31:631/ipp/print',
        requestingUserName: 'arcadia-account-manager',
        document: const <int>[0x1B, 0x40, 0x41],
        requestId: 7,
      );

      expect(request.sublist(0, 2), <int>[0x01, 0x01], reason: 'IPP/1.1');
      expect(request.sublist(2, 4), <int>[0x00, 0x02], reason: 'Print-Job');
      expect(request.sublist(4, 8), <int>[0, 0, 0, 7], reason: 'request-id');
      expect(request[8], 0x01, reason: 'operation-attributes-tag');
      // The document is the last thing in the buffer, byte for byte, and the
      // end-of-attributes tag is what separates it from the attributes.
      expect(request.sublist(request.length - 4), <int>[
        0x03,
        0x1B,
        0x40,
        0x41,
      ]);
    });

    test('names charset first and natural-language second, as RFC 8011 wants',
        () {
      // Not pedantry: embedded IPP servers reject a group whose first two
      // attributes are anything else, and the failure looks like "the printer
      // ignores us".
      final Uint8List request = buildIppPrintJobRequest(
        printerUri: 'ipps://10.0.0.31:631/ipp/print',
        requestingUserName: 'desk',
        document: const <int>[0x00],
      );
      final String wire = latin1.decode(request);
      expect(
        wire.indexOf('attributes-charset'),
        lessThan(wire.indexOf('attributes-natural-language')),
      );
      expect(
        wire.indexOf('attributes-natural-language'),
        lessThan(wire.indexOf('printer-uri')),
      );
    });

    test('declares the ticket as an opaque byte stream', () {
      // `application/octet-stream` is what tells the printer to hand the bytes
      // to the print engine instead of trying to interpret them — which is how
      // the ESC/POS layout survives the transport swap unchanged.
      final Uint8List request = buildIppPrintJobRequest(
        printerUri: 'ipps://10.0.0.31:631/ipp/print',
        requestingUserName: 'desk',
        document: const <int>[0x00],
      );
      final String wire = latin1.decode(request);
      expect(wire, contains('document-format'));
      expect(wire, contains('application/octet-stream'));
      expect(wire, contains('ipps://10.0.0.31:631/ipp/print'));
    });

    test('the printer-uri says ipps, because the request travels over TLS', () {
      expect(
        ippsPrinterUri(host: 'printer.local', port: 631, path: '/ipp/print'),
        'ipps://printer.local:631/ipp/print',
      );
    });

    group('reading the answer', () {
      test('successful-ok is bytes 2-3 being zero', () {
        expect(ippStatusOf(_ippResponse(0x0000)), ippSuccessfulOk);
        expect(isIppSuccess(ippStatusOf(_ippResponse(0x0000))), isTrue);
      });

      test('the whole successful-* range counts as printed', () {
        // 0x0001 is successful-ok-ignored-or-substituted-attributes: the paper
        // came out, some attribute was quietly dropped. Not a student's problem.
        expect(isIppSuccess(ippStatusOf(_ippResponse(0x0001))), isTrue);
        expect(isIppSuccess(ippStatusOf(_ippResponse(0x00ff))), isTrue);
      });

      test('a client-error or server-error status is not success', () {
        // 0x0400 client-error-bad-request, 0x0500 server-error-internal-error.
        expect(isIppSuccess(ippStatusOf(_ippResponse(0x0400))), isFalse);
        expect(isIppSuccess(ippStatusOf(_ippResponse(0x0500))), isFalse);
      });

      test('a body that is not an IPP response at all is not success', () {
        expect(ippStatusOf(const <int>[0x01]), isNull);
        expect(isIppSuccess(ippStatusOf(const <int>[])), isFalse);
      });
    });
  });

  group('IppTicketTransport, against a real HTTPS printer', () {
    // As close to the TM-m30III as a build agent can get: a real TLS handshake
    // against a real self-signed certificate, a real POST, the real bytes read
    // back off the request.
    test(
        'POSTs the ticket to /ipp/print over TLS, accepting the self-signed '
        'certificate', () async {
      final _FakeIppPrinter printer = await _FakeIppPrinter.start();
      addTearDown(printer.close);

      final ticket = LateArrivalPrinter(
        host: InternetAddress.loopbackIPv4.address,
        port: printer.port,
        logo: defaultTicketLogo,
      );
      addTearDown(ticket.dispose);

      final LateArrivalRecord record = _record();
      ticket.printRecord(record);
      await ticket.settled;

      expect(ticket.status.value.state, LateArrivalPrintState.idle,
          reason: '${ticket.status.value.error}');
      expect(printer.path, '/ipp/print');
      expect(printer.method, 'POST');
      expect(printer.contentType, 'application/ipp');
      // The ESC/POS bytes are unchanged by the transport: the request body ends
      // with exactly the ticket the composer produced.
      final Uint8List ticketBytes =
          composeTicketForRecord(record, logo: defaultTicketLogo);
      expect(
        printer.body!.sublist(printer.body!.length - ticketBytes.length),
        ticketBytes,
      );
      // …and it arrived wrapped, not raw: the IPP header is in front of it.
      expect(printer.body!.sublist(0, 4), <int>[0x01, 0x01, 0x00, 0x02]);
    });

    test('an HTTP 200 with a refusing IPP status is a failure, not a print',
        () async {
      // The #424 regression in one line. This printer answers 200 to jobs it
      // then refuses, so treating the HTTP status as the answer would report a
      // ticket that never came out.
      final _FakeIppPrinter printer =
          await _FakeIppPrinter.start(ippStatus: 0x0400);
      addTearDown(printer.close);

      const IppTicketTransport transport = IppTicketTransport();
      await expectLater(
        transport.send(
          host: InternetAddress.loopbackIPv4.address,
          port: printer.port,
          bytes: const <int>[0x1B, 0x40],
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<IppPrintRefused>()
            .having((IppPrintRefused e) => e.status, 'status', 0x0400)),
      );
    });

    test('an HTTP error is a failure even when the body looks fine', () async {
      final _FakeIppPrinter printer =
          await _FakeIppPrinter.start(httpStatus: HttpStatus.upgradeRequired);
      addTearDown(printer.close);

      const IppTicketTransport transport = IppTicketTransport();
      await expectLater(
        transport.send(
          host: InternetAddress.loopbackIPv4.address,
          port: printer.port,
          bytes: const <int>[0x1B, 0x40],
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<IppPrintRefused>().having(
            (IppPrintRefused e) => e.httpStatus,
            'httpStatus',
            HttpStatus.upgradeRequired)),
      );
    });

    test('accepting that certificate does not leak to the rest of the app',
        () async {
      // The scoping half of #424: the printer's certificate is trusted for the
      // printer, not process-wide. A plain client — which is what every other
      // connection in the app uses — must still refuse the very same server.
      final _FakeIppPrinter printer = await _FakeIppPrinter.start();
      addTearDown(printer.close);

      const IppTicketTransport transport = IppTicketTransport();
      await transport.send(
        host: InternetAddress.loopbackIPv4.address,
        port: printer.port,
        bytes: const <int>[0x1B, 0x40],
        timeout: const Duration(seconds: 10),
      );

      final HttpClient plain = HttpClient();
      addTearDown(() => plain.close(force: true));
      await expectLater(
        plain
            .getUrl(Uri.https(
              '${InternetAddress.loopbackIPv4.address}:${printer.port}',
              '/ipp/print',
            ))
            .then((HttpClientRequest r) => r.close()),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('throws when nothing is listening, which is what the desk must see',
        () async {
      // Bind and immediately release a port, so the address is well-formed and
      // certainly closed.
      final ServerSocket probe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = probe.port;
      await probe.close();

      const IppTicketTransport transport = IppTicketTransport();
      await expectLater(
        transport.send(
          host: InternetAddress.loopbackIPv4.address,
          port: deadPort,
          bytes: const <int>[0x1B, 0x40],
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });
}

/// An eight-byte IPP response carrying [status].
Uint8List _ippResponse(int status) => Uint8List.fromList(<int>[
      0x01,
      0x01,
      (status >> 8) & 0xff,
      status & 0xff,
      0x00,
      0x00,
      0x00,
      0x01,
    ]);

/// A loopback HTTPS server holding a self-signed certificate, standing in for
/// the reception printer's IPP service (#424).
class _FakeIppPrinter {
  _FakeIppPrinter._(this._server, this._httpStatus, this._ippStatus) {
    unawaited(_serve());
  }

  static Future<_FakeIppPrinter> start({
    int httpStatus = HttpStatus.ok,
    int ippStatus = ippSuccessfulOk,
  }) async {
    final HttpServer server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      selfSignedPrinterContext(),
    );
    return _FakeIppPrinter._(server, httpStatus, ippStatus);
  }

  final HttpServer _server;
  final int _httpStatus;
  final int _ippStatus;

  String? method;
  String? path;
  String? contentType;
  Uint8List? body;

  int get port => _server.port;

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      final BytesBuilder buffer = BytesBuilder(copy: false);
      await for (final List<int> chunk in request) {
        buffer.add(chunk);
      }
      method = request.method;
      path = request.uri.path;
      contentType = request.headers.contentType?.mimeType;
      body = buffer.takeBytes();
      request.response
        ..statusCode = _httpStatus
        ..headers.contentType = ContentType('application', 'ipp')
        ..add(_ippResponse(_ippStatus));
      await request.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// A transport whose failure is decided per call, for the recovery test.
class _ConditionalTransport implements TicketTransport {
  _ConditionalTransport(this.shouldFail);

  final bool Function() shouldFail;

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    if (shouldFail()) throw const SocketException('connection refused');
  }
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
