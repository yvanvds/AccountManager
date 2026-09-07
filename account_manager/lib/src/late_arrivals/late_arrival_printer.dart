/// Getting the late-arrival ticket out of the app and onto paper (#406).
///
/// The composition is pure and lives in `packages/late_arrivals/`; this is the
/// half that has to touch the world — one TCP connection to the printer's raw
/// port, and the status an operator reads when it does not answer.
///
/// **Raw ESC/POS over port 9100, deliberately not a Windows printer driver.**
/// A driver would mean an installed queue per reception desk, a spooler that
/// can be paused, and a "printer offline" dialog that steals focus from the
/// scanner. A socket has none of that: the app opens it, writes the bytes,
/// closes it, and is finished with the ticket. That is what lets printing be
/// fire-and-forget.
///
/// **The registration never depends on the ticket.** By the time anything here
/// runs, the record is already flushed to the journal (#402) and mirrored
/// (#403), and the drain to Smartschool (#404) reads the journal, not this. A
/// printer that is off, unplugged or on the wrong IP therefore costs a piece of
/// paper and nothing else — which is exactly why [printRecord] returns `void`
/// rather than a future anybody could be tempted to await.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:late_arrivals/late_arrivals.dart';

/// How long to wait for the printer to accept a connection before giving up.
///
/// Short on purpose. This is a device on the same LAN as the desk; if it has
/// not answered in five seconds it is not going to, and the operator is better
/// served by a visible failure than by a spinner. Nothing is blocked on it
/// either way — the queue below runs off the scan flow.
const Duration lateArrivalPrinterTimeout = Duration(seconds: 5);

/// Where a [LateArrivalPrinter] has got to, for the operator to read.
enum LateArrivalPrintState {
  /// No printer is configured on this machine, so nothing is printed. The
  /// honest state for an office laptop draining a queue (#403), and not an
  /// error — nagging every scan would train the operator to ignore the banner
  /// that matters.
  disabled,

  /// Configured, and everything asked for so far has gone out.
  idle,

  /// A ticket is on its way to the printer.
  printing,

  /// The last ticket did not reach the printer. The registration still stands.
  failed,
}

/// The printer's last known state and what to tell the operator about it.
@immutable
class LateArrivalPrintStatus {
  const LateArrivalPrintStatus(this.state, this.message, {this.error});

  final LateArrivalPrintState state;

  /// A complete Dutch sentence for the operator, or empty when there is
  /// nothing worth saying.
  final String message;

  /// What actually went wrong, for the log. Never shown raw.
  final Object? error;

  /// Whether this is the state that has to be put in front of the operator.
  bool get isFailure => state == LateArrivalPrintState.failed;

  @override
  bool operator ==(Object other) =>
      other is LateArrivalPrintStatus &&
      other.state == state &&
      other.message == message;

  @override
  int get hashCode => Object.hash(state, message);

  @override
  String toString() => 'LateArrivalPrintStatus(${state.name}, $message)';
}

/// Delivers a composed ticket to a printer. The seam a test binds so the
/// layout, the queueing and the error surface can all be driven without a
/// device on the network.
abstract interface class TicketTransport {
  /// Sends [bytes] to [host]:[port]. Completes when the bytes are on the wire;
  /// **throws** when they are not.
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  });
}

/// The production [TicketTransport]: one short-lived TCP connection per ticket.
///
/// A connection per ticket rather than a kept-open socket. A receipt printer at
/// a reception desk is idle for hours at a time, and a socket held across that
/// is a socket a switch, a sleep or a power cycle has silently dropped — the
/// failure would then land on the next student rather than on the ticket that
/// caused it. Connecting each time costs milliseconds and is honest about
/// whether the printer is there *now*.
class TcpTicketTransport implements TicketTransport {
  const TcpTicketTransport();

  @override
  Future<void> send({
    required String host,
    required int port,
    required List<int> bytes,
    required Duration timeout,
  }) async {
    final Socket socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.add(bytes);
      await socket.flush().timeout(timeout);
    } finally {
      // `destroy`, not `close`: closing waits for the *printer* to hang up, and
      // an ESC/POS printer has no reason to. The bytes are flushed by here.
      socket.destroy();
    }
  }
}

/// Prints late-arrival tickets on an ESC/POS printer over raw TCP (#406).
///
/// Fire-and-forget by construction: [printRecord] and [printTicket] return
/// `void`, hand the bytes to a queue and are done. The scanner is free for the
/// next student while the paper is still coming out, and a printer that never
/// answers stalls only the queue — which drops back to [LateArrivalPrintState.idle]
/// after its timeout — never the desk.
///
/// Tickets are serialised through one chain rather than fired in parallel, so
/// two students scanned in quick succession come out in the order they were
/// scanned. A test awaits [settled] to know the queue has drained.
class LateArrivalPrinter {
  LateArrivalPrinter({
    required String host,
    this.transport = const TcpTicketTransport(),
    this.logo,
    this.port = escPosRawPort,
    this.timeout = lateArrivalPrinterTimeout,
  }) : host = host.trim() {
    _status = ValueNotifier<LateArrivalPrintStatus>(
      isConfigured
          ? const LateArrivalPrintStatus(LateArrivalPrintState.idle, '')
          : const LateArrivalPrintStatus(
              LateArrivalPrintState.disabled,
              'Er is op deze computer geen ticketprinter ingesteld, dus er '
              'worden geen tickets afgedrukt. De registratie zelf gaat '
              'gewoon door.',
            ),
    );
  }

  /// The printer's host name or IP, as this machine has it configured. Empty
  /// means this machine does not print.
  final String host;

  /// Always 9100 in practice — it is what "raw" means — but injectable so a
  /// test can bind an ephemeral loopback port.
  final int port;

  final TicketTransport transport;

  /// The mark at the top of the ticket, or `null` for none. See
  /// [defaultTicketLogo].
  final TicketLogo? logo;

  final Duration timeout;

  late final ValueNotifier<LateArrivalPrintStatus> _status;

  /// One ticket at a time, in scan order.
  Future<void> _queue = Future<void>.value();

  bool _disposed = false;

  /// Whether this machine has a printer to print on.
  bool get isConfigured => host.isNotEmpty;

  /// What to show the operator. Listenable so the scan tab (#407) can put a
  /// failure on screen the moment it happens, without polling.
  ValueListenable<LateArrivalPrintStatus> get status => _status;

  /// Completes when everything queued so far has been sent or has failed.
  ///
  /// For tests and for a clean shutdown. Deliberately *not* what the scan flow
  /// waits on: the whole point of this class is that nothing waits on it.
  Future<void> get settled => _queue;

  /// Prints the ticket for a journalled registration (#402) — the entry point
  /// the scan tab (#407) calls, right after `journal.register` has returned.
  ///
  /// Returns immediately. The record's `scannedAt` is what reaches the paper,
  /// so a slow printer cannot put the wrong minute on a ticket.
  void printRecord(LateArrivalRecord record) => printTicket(
        displayName: record.displayName,
        className: record.className,
        scannedAt: record.scannedAt,
      );

  /// Prints one ticket. Returns immediately; see [printRecord].
  void printTicket({
    required String displayName,
    required String className,
    required DateTime scannedAt,
  }) {
    if (_disposed || !isConfigured) return;
    final Uint8List bytes;
    try {
      bytes = composeLateArrivalTicket(
        displayName: displayName,
        className: className,
        scannedAt: scannedAt,
        logo: logo,
      );
    } on Object catch (e) {
      // A logo that does not fit the paper, say. It is still not the student's
      // problem: report it and let the registration stand.
      _report(LateArrivalPrintStatus(
        LateArrivalPrintState.failed,
        'Het ticket kon niet worden opgemaakt. De registratie is bewaard en '
        'wordt naar Smartschool verstuurd.',
        error: e,
      ));
      return;
    }
    _enqueue(bytes);
  }

  /// Prints a sample ticket, so the operator can check the address they just
  /// typed without waiting for a student to be late.
  ///
  /// Same composition, same transport, same error surface — a test print that
  /// took a different path would prove nothing about the real one.
  void printTestTicket({DateTime? now}) => printTicket(
        displayName: 'Testticket',
        className: 'Balie',
        scannedAt: now ?? DateTime.now(),
      );

  void _enqueue(Uint8List bytes) {
    _report(const LateArrivalPrintStatus(LateArrivalPrintState.printing, ''));
    _queue = _queue.then((_) async {
      if (_disposed) return;
      try {
        await transport.send(
          host: host,
          port: port,
          bytes: bytes,
          timeout: timeout,
        );
        _report(const LateArrivalPrintStatus(LateArrivalPrintState.idle, ''));
      } on Object catch (e) {
        _report(LateArrivalPrintStatus(
          LateArrivalPrintState.failed,
          'De ticketprinter op $host:$port antwoordt niet, dus er is geen '
          'ticket afgedrukt. De registratie is bewaard en wordt naar '
          'Smartschool verstuurd.',
          error: e,
        ));
      }
    });
  }

  void _report(LateArrivalPrintStatus next) {
    if (_disposed) return;
    _status.value = next;
  }

  /// Stops reporting and lets the queue run out. Nothing is cancelled: a
  /// ticket already on the wire is a ticket the student is waiting for.
  void dispose() {
    _disposed = true;
    _status.dispose();
  }
}
