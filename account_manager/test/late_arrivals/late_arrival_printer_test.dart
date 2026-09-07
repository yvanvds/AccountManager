/// The transport half of the late-arrival ticket (#406).
///
/// The pure package proves what the ticket *says*; this proves the two things
/// it cannot: that the bytes reach a socket on port 9100, and that a printer
/// which is not there costs a piece of paper rather than a registration.
///
/// No hardware anywhere. The TCP tests bind an ephemeral loopback listener and
/// read the stream back, which exercises the real [TcpTicketTransport] end to
/// end; the behavioural tests bind a fake so a failure can be summoned on
/// demand.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:account_manager/src/late_arrivals/late_arrival_printer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

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

  group('what goes down the socket', () {
    test('is the ticket for that record, at port 9100', () async {
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
      expect(transport.ports, <int>[escPosRawPort]);
      expect(escPosRawPort, 9100);
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
      expect(status.message, contains('10.0.0.31:9100'));
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

      expect(transport.ports, <int>[escPosRawPort]);
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

  group('TcpTicketTransport, against a real socket', () {
    test('delivers the whole byte stream to a listener on the given port',
        () async {
      // As close to the TM-m30III as a build agent can get: a real TCP
      // connection, the real bytes, read back off the wire.
      final ServerSocket server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final Completer<List<int>> received = Completer<List<int>>();
      final StreamSubscription<Socket> accepting = server.listen(
        (Socket socket) {
          final BytesBuilder buffer = BytesBuilder(copy: false);
          socket.listen(
            buffer.add,
            onDone: () {
              if (!received.isCompleted) received.complete(buffer.takeBytes());
              socket.destroy();
            },
          );
        },
      );
      addTearDown(accepting.cancel);

      final printer = LateArrivalPrinter(
        host: server.address.address,
        port: server.port,
        logo: defaultTicketLogo,
      );
      addTearDown(printer.dispose);

      final LateArrivalRecord record = _record();
      printer.printRecord(record);
      await printer.settled;

      expect(printer.status.value.state, LateArrivalPrintState.idle);
      expect(
        await received.future.timeout(const Duration(seconds: 10)),
        composeTicketForRecord(record, logo: defaultTicketLogo),
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

      const TcpTicketTransport transport = TcpTicketTransport();
      await expectLater(
        transport.send(
          host: InternetAddress.loopbackIPv4.address,
          port: deadPort,
          bytes: const <int>[0x1B, 0x40],
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });
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
