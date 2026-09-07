import 'dart:async';

import 'package:account_core/account_core.dart' as core;

import '../journal/late_arrival_journal.dart';
import '../journal/late_arrival_record.dart';
import '../journal/record_sink.dart';
import '../retry/backoff.dart';
import 'presence_writer.dart';

/// What the drain is currently managing to do (#404).
///
/// Published rather than logged, because a queue that has quietly stopped
/// moving is indistinguishable from an empty one until somebody's absence
/// turns up in a report weeks later. [outstanding] and [failed] are what the
/// scan tab (#407) puts on screen; the rest is what it says when the operator
/// asks why.
final class LateArrivalDrainStatus {
  const LateArrivalDrainStatus({
    required this.outstanding,
    required this.failed,
    required this.consecutiveFailures,
    required this.draining,
    required this.degraded,
    this.lastError,
    this.lastSuccessAt,
  });

  /// Registrations that still owe Smartschool a write — everything not yet
  /// confirmed and not yet given up on. The number the desk reads as "nog te
  /// versturen".
  final int outstanding;

  /// Registrations that were given up on and are still on the day's journal.
  /// Non-zero is always worth showing: nothing will retry these on its own.
  final int failed;

  /// Failed attempts since the last accepted write, across records.
  final int consecutiveFailures;

  /// Whether a write is in flight right now.
  final bool draining;

  /// Whether the worker has stood down after a run of failures and is waiting
  /// for a fresh registration, a [LateArrivalDrain.retryNow], or a restart.
  ///
  /// **Nothing is lost while this is true.** Every record it stood down over is
  /// still `pending` in the journal on disk; standing down is what stops a
  /// Smartschool outage from burning the whole morning's retry budget and
  /// terminal-failing a queue that would have gone through fine ten minutes
  /// later.
  final bool degraded;

  /// The last failure, in words an operator can be shown. `null` after a
  /// success.
  final String? lastError;

  /// When Smartschool last accepted a write.
  final DateTime? lastSuccessAt;

  /// Whether the queue is empty and nothing needs the operator's attention.
  bool get isHealthy => outstanding == 0 && failed == 0 && !degraded;

  /// Whether something is stuck and the operator has to be told.
  bool get needsAttention => degraded || failed > 0;

  @override
  String toString() => 'LateArrivalDrainStatus($outstanding te versturen, '
      '$failed mislukt${degraded ? ', opgegeven' : ''})';
}

/// Drains journalled late arrivals to Smartschool presences (#404).
///
/// **Why it is a background worker and not a call in the scan flow.** The desk
/// has a queue of students in front of it. A presence write is three round
/// trips to Smartschool (config, codes, class), any of which can hang on a bad
/// morning, and none of which the student standing there should wait for. So
/// the scan journals (#402), prints (#406) and frees the input; this reads the
/// journal afterwards and makes the registration real. A slow or broken
/// Smartschool delays writes. It never stalls the desk, and it never loses one.
///
/// **Order is the contract, not a nicety.** `savePupilsPresences` *updates* the
/// half-day cell rather than appending to it, so of two scans of the same
/// student the last one written is the one that stands. The operator's second
/// scan is the correction, so it has to be written second. The journal hands
/// records over in scan order and this worker sends them one at a time, in that
/// order — which is the cheapest way to get the per-student guarantee, since a
/// globally ordered queue is per-student ordered by construction.
///
/// **A failure is retried, then kept.** A transient failure (a dropped
/// connection, a 502) waits out [backoff] and goes round again, up to
/// [maxAttempts]. An expired session is not a failure at all: the worker signs
/// in again and retries without spending an attempt. A [PresenceRejected] — no
/// presence rights for the class, pupil not in it — is terminal at once,
/// because retrying only buries the server's explanation. Whatever the route,
/// a record that ends up given up on lands in [LateArrivalStatus.failed] with
/// the error text on it and stays in the journal, visible, rather than
/// vanishing.
///
/// **It stands down rather than draining into failures.** When a record
/// exhausts its budget against a transient fault the worker stops, marks itself
/// [LateArrivalDrainStatus.degraded], and leaves everything behind that record
/// `pending`. That is what keeps a ten-minute Smartschool outage from turning
/// forty registrations into forty permanent failures. The next scan, an
/// explicit [retryNow] or the next app start picks the queue straight back up.
///
/// ```dart
/// final drain = LateArrivalDrain(journal: journal, writer: writer, log: log);
/// final journal = await LateArrivalJournal.open(
///   store,
///   sink: FanOutRecordSink(<LateArrivalRecordSink>[mirror, drain]),
/// );
/// drain.start(); // resumes whatever the recovered journal still owes
/// ```
class LateArrivalDrain implements LateArrivalRecordSink {
  LateArrivalDrain({
    required LateArrivalJournal journal,
    required LatePresenceWriter writer,
    core.ILog? log,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.backoff = const RetryBackoff(
      base: Duration(seconds: 2),
      max: Duration(seconds: 60),
    ),
    this.maxAttempts = 5,
    this.maxSessionRenewals = 2,
  })  : _journal = journal,
        _writer = writer,
        _log = log,
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? _wallClockSleep;

  final LateArrivalJournal _journal;
  final LatePresenceWriter _writer;
  final core.ILog? _log;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  /// How long the worker waits between attempts at the same record.
  final RetryBackoff backoff;

  /// How many transient failures one record takes before it is given up on.
  final int maxAttempts;

  /// How many times a single record may trigger a fresh sign-in before the
  /// expiry is treated as an ordinary failure.
  ///
  /// A cap rather than a free-for-all: a login that succeeds and is instantly
  /// invalid again is a loop, and a loop that never reaches the operator is the
  /// worst of the failure modes on offer.
  final int maxSessionRenewals;

  final StreamController<LateArrivalDrainStatus> _statuses =
      StreamController<LateArrivalDrainStatus>.broadcast();
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];

  bool _pumping = false;
  bool _closed = false;
  bool _degraded = false;
  bool _inFlight = false;
  int _consecutiveFailures = 0;
  String? _lastError;
  DateTime? _lastSuccessAt;

  static Future<void> _wallClockSleep(Duration d) => Future<void>.delayed(d);

  /// The worker's state, published on every change.
  Stream<LateArrivalDrainStatus> get statuses => _statuses.stream;

  /// The worker's state right now.
  LateArrivalDrainStatus get status => LateArrivalDrainStatus(
        outstanding: _journal.pending.length,
        failed: failures.length,
        consecutiveFailures: _consecutiveFailures,
        draining: _inFlight,
        degraded: _degraded,
        lastError: _lastError,
        lastSuccessAt: _lastSuccessAt,
      );

  /// The registrations that were given up on, in scan order.
  ///
  /// Kept addressable rather than merely counted: "twee mislukt" is not
  /// actionable, "Jonas Peeters, 3MTa — deze klas hoort niet bij dit account"
  /// is (#407).
  List<LateArrivalRecord> get failures => <LateArrivalRecord>[
        for (final LateArrivalRecord r in _journal.records)
          if (r.status == LateArrivalStatus.failed) r,
      ];

  /// Starts draining whatever the journal already holds.
  ///
  /// This is the whole of "draining resumes after a restart": the journal has
  /// already replayed the day's file by the time this is called, so its pending
  /// list *is* the queue the previous run did not finish — including anything
  /// left in [LateArrivalStatus.sent], which is re-sent because a presence save
  /// updates the same cell and re-sending it is therefore harmless.
  void start() {
    if (_closed) return;
    _emit();
    unawaited(_pump());
  }

  /// Wakes the worker for a newly journalled registration.
  ///
  /// Called by the journal after the line is flushed to disk, so this cannot
  /// delay a ticket, and it must not throw — it does not: a Smartschool that is
  /// down is the pump's problem, never the desk's.
  @override
  void onRecord(LateArrivalRecord record) {
    if (_closed) return;
    // Status lines the pump itself writes come back through here; the pump
    // re-reads the journal each turn, so there is nothing to do but let it.
    if (_pumping) return;
    if (!record.status.needsDraining) {
      _emit();
      return;
    }
    // A fresh registration is also the signal to try again after a stand-down:
    // Smartschool may well be back.
    _degraded = false;
    _consecutiveFailures = 0;
    _emit();
    unawaited(_pump());
  }

  /// Picks the queue back up after the worker stood down — the operator's
  /// "opnieuw proberen". A no-op when there is nothing left to send.
  void retryNow() {
    if (_closed) return;
    _degraded = false;
    _consecutiveFailures = 0;
    _lastError = null;
    _emit();
    unawaited(_pump());
  }

  /// Completes once the queue is empty or the worker has stood down.
  ///
  /// A shutdown hook, and what a test waits on instead of guessing at timings.
  Future<void> settle() {
    if (!_pumping) return Future<void>.value();
    final Completer<void> waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// Stops the worker and releases the status stream. Anything still queued
  /// stays `pending` in the journal, which is where it was the record of record
  /// all along.
  Future<void> close() async {
    _closed = true;
    await settle();
    _releaseWaiters();
    await _statuses.close();
  }

  /// Sends the queue, one record at a time, in journal order.
  ///
  /// Only ever one pump runs. Re-entered by every [onRecord] and every
  /// [retryNow], the guard is what keeps a busy desk from opening a Smartschool
  /// session per scan — and, more importantly, what keeps two writes for the
  /// same student from racing into the same half-day cell.
  Future<void> _pump() async {
    if (_pumping || _closed) return;
    _pumping = true;
    try {
      while (!_closed && !_degraded) {
        final List<LateArrivalRecord> queue = _journal.pending;
        if (queue.isEmpty) break;
        await _send(queue.first);
      }
    } finally {
      _pumping = false;
      _inFlight = false;
      _emit();
      _releaseWaiters();
    }
  }

  /// Sends one record, retrying it in place until it is confirmed or given up
  /// on. Returns only once the record has left [LateArrivalJournal.pending], so
  /// the pump can never spin on it.
  Future<void> _send(LateArrivalRecord record) async {
    final String id = record.id;
    int attempt = 0;
    int renewals = 0;
    String lastError = 'Onbekende fout.';

    while (!_closed) {
      if (_journal.byId(id)?.status != LateArrivalStatus.sent) {
        await _journal.markSent(id);
      }
      _inFlight = true;
      _emit();

      try {
        await _writer.setLate(
          userId: record.internalUserId,
          classGroupId: record.classGroupId,
          date: DateTime(record.day.year, record.day.month, record.day.day),
          withoutValidReason: !record.reasonIsValid,
          motivation: record.motivation,
        );
      } on PresenceRejected catch (error) {
        // The server's answer will not change; keep its wording and move on.
        await _giveUp(id, record, error.message);
        return;
      } on Object catch (error) {
        _inFlight = false;
        final bool expired = error is PresenceSessionExpired;
        lastError = expired ? error.message : '$error';
        _consecutiveFailures++;
        _lastError = lastError;
        await _journal.markPending(id);
        _emit();

        if (expired && renewals < maxSessionRenewals) {
          renewals++;
          try {
            await _writer.reauthenticate();
            // A fresh session is a new situation, not another strike: retry
            // straight away and leave the record's budget untouched.
            continue;
          } on Object catch (signInError) {
            lastError = 'Aanmelden bij Smartschool lukte niet: $signInError';
            _lastError = lastError;
            _emit();
          }
        }

        attempt++;
        if (attempt >= maxAttempts) {
          await _giveUp(id, record, lastError);
          // Stand down rather than spending the next record's budget on the
          // same outage. Everything behind this one stays pending on disk.
          _degraded = true;
          _emit();
          _log?.addError(
            core.Origin.smartschool,
            'Te-laatregistraties worden niet meer naar Smartschool verstuurd '
            '(${_journal.pending.length} in wachtrij): $lastError',
          );
          return;
        }
        await _sleep(backoff.delayFor(attempt));
        continue;
      }

      await _journal.markConfirmed(id);
      _inFlight = false;
      _consecutiveFailures = 0;
      _lastError = null;
      _lastSuccessAt = _clock();
      _emit();
      return;
    }
  }

  Future<void> _giveUp(
    String id,
    LateArrivalRecord record,
    String error,
  ) async {
    await _journal.markFailed(id, error);
    _inFlight = false;
    _lastError = error;
    _emit();
    _log?.addError(
      core.Origin.smartschool,
      'De te-laatregistratie van ${record.displayName} (${record.className}) '
      'kon niet naar Smartschool geschreven worden: $error',
    );
  }

  void _releaseWaiters() {
    if (_idleWaiters.isEmpty) return;
    final List<Completer<void>> waiting =
        List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final Completer<void> waiter in waiting) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _emit() {
    if (_statuses.isClosed) return;
    _statuses.add(status);
  }
}
