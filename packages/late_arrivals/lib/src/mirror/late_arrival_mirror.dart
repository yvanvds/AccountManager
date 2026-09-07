import 'dart:async';

import 'package:account_core/account_core.dart' as core;

import '../journal/late_arrival_record.dart';
import '../journal/record_sink.dart';
import '../journal/school_day.dart';
import '../retry/backoff.dart';
import 'late_arrival_mirror_store.dart';
import 'mirrored_registration.dart';

/// How the mirror backs off between failed attempts.
///
/// The same curve the Smartschool drain (#404) uses; see [RetryBackoff]. Kept
/// under its original name so #403's callers read unchanged.
typedef MirrorBackoff = RetryBackoff;

/// What the mirror is currently managing to do (#403).
///
/// Published rather than logged-and-forgotten: a mirror that has silently
/// stopped working is a mirror that is not there when the laptop dies, which is
/// the one moment anybody finds out. [degraded] is what a screen shows.
final class LateArrivalMirrorStatus {
  const LateArrivalMirrorStatus({
    required this.pending,
    required this.consecutiveFailures,
    required this.degraded,
    this.lastError,
    this.lastSuccessAt,
  });

  /// Registrations written locally whose mirrored document is not up to date.
  final int pending;

  /// Failed attempts since the last success.
  final int consecutiveFailures;

  /// Whether the worker has given up for now — it exhausted its attempts and is
  /// waiting for a fresh registration or an explicit [LateArrivalMirror.retryNow].
  /// Nothing was lost: every pending record is still queued and still on disk.
  final bool degraded;

  /// The last failure, as text an operator can be shown. `null` once a write
  /// succeeds.
  final String? lastError;

  /// When the store last accepted a write.
  final DateTime? lastSuccessAt;

  /// Whether the mirror is keeping up.
  bool get isHealthy => !degraded && consecutiveFailures == 0;

  @override
  String toString() => 'LateArrivalMirrorStatus($pending te spiegelen, '
      '$consecutiveFailures mislukt${degraded ? ', opgegeven' : ''})';
}

/// What a startup reconciliation against the shared store found (#403).
final class LateArrivalReconciliation {
  const LateArrivalReconciliation({
    required this.day,
    required this.missingLocally,
    required this.requeued,
    this.error,
  });

  /// The day that was reconciled.
  final SchoolDay day;

  /// Registrations the shared store holds that this machine's journal does not
  /// — another desk's work, or this desk's own after the journal was lost.
  ///
  /// **The entire reason this feature exists.** The local journal already covers
  /// an app crash; this covers a dead laptop, and it only covers it if the
  /// stand-in operator is actually shown what is outstanding.
  final List<MirroredRegistration> missingLocally;

  /// How many local records were queued for a re-mirror because the store had
  /// no copy, or a copy in an older status — a machine that crashed between the
  /// disk write and the mirror write catches up here.
  final int requeued;

  /// Why the store could not be read, when it could not be. A mirror that is
  /// unreachable at startup must not take the launch down: the desk works off
  /// its own journal, exactly as it did before this existed.
  final String? error;

  /// Whether the shared store answered at all.
  bool get available => error == null;

  /// The subset of [missingLocally] that still needs draining — the queue a
  /// stand-in operator has to pick up. A confirmed registration is somebody
  /// else's finished work and needs nothing.
  List<MirroredRegistration> get outstanding => <MirroredRegistration>[
        for (final MirroredRegistration e in missingLocally)
          if (e.record.status.needsDraining) e,
      ];

  @override
  String toString() => 'LateArrivalReconciliation($day, '
      '${missingLocally.length} elders, $requeued opnieuw, '
      '${error ?? 'ok'})';
}

/// Mirrors the late-arrival journal to the shared store, asynchronously (#403).
///
/// **Why it exists.** The journal (#402) makes a registration survive the app
/// dying. It does nothing at all for the laptop dying, and the agreed fallback
/// for that case is that a colleague picks the work up on her own machine. She
/// can only do that if the day's registrations are somewhere both machines can
/// see, which is the Cosmos account epic #112 already keeps the shared operator
/// state in.
///
/// **It sits behind the journal, never in front of it.** [onRecord] is `void`
/// and returns immediately: the record is already flushed to disk by the time
/// it is called, the ticket prints off the journal's future and not this one,
/// and a slow or dead Cosmos changes the desk's timing by nothing. Everything
/// here is best-effort *on top of* a guarantee that has already been kept.
///
/// **Nothing is ever lost to a failure.** A failed write leaves the record
/// queued and retries it with [MirrorBackoff]; after [maxAttempts] consecutive
/// failures the worker stops burning the network and marks itself
/// [LateArrivalMirrorStatus.degraded], which is what puts a persistent outage in
/// front of the operator instead of in a log file. The queue survives that: the
/// next registration, an explicit [retryNow], or the next [reconcile] picks it
/// straight back up, and the local journal was never touched either way.
///
/// ```dart
/// final mirror = LateArrivalMirror(store: cosmosMirror, deskId: hostName);
/// final journal = await LateArrivalJournal.open(store, sink: mirror);
/// final recovery = await mirror.reconcile(
///   day: SchoolDay.of(DateTime.now()),
///   local: journal.records,
/// );
/// // recovery.outstanding is what the other laptop did not get to.
/// ```
class LateArrivalMirror implements LateArrivalRecordSink {
  LateArrivalMirror({
    required LateArrivalMirrorStore store,
    required String deskId,
    core.ILog? log,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.backoff = const MirrorBackoff(),
    this.maxAttempts = 4,
  })  : _store = store,
        _deskId = deskId,
        _log = log,
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? _wallClockSleep;

  final LateArrivalMirrorStore _store;
  final String _deskId;
  final core.ILog? _log;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  /// How long the worker waits between failed attempts.
  final MirrorBackoff backoff;

  /// How many consecutive failures the worker takes before standing down and
  /// reporting itself degraded. It never stands down *quietly* and it never
  /// drops what it was carrying.
  final int maxAttempts;

  /// Records whose mirrored document is not up to date, keyed by the journal's
  /// local record id — so a registration and its later status changes coalesce
  /// into the one document write that would have been the final state anyway.
  final Map<String, LateArrivalRecord> _queue = <String, LateArrivalRecord>{};

  final StreamController<LateArrivalMirrorStatus> _statuses =
      StreamController<LateArrivalMirrorStatus>.broadcast();
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];

  bool _pumping = false;
  bool _closed = false;
  bool _degraded = false;
  int _consecutiveFailures = 0;
  String? _lastError;
  DateTime? _lastSuccessAt;

  static Future<void> _wallClockSleep(Duration d) => Future<void>.delayed(d);

  /// The mirror's health, published on every change.
  Stream<LateArrivalMirrorStatus> get statuses => _statuses.stream;

  /// The mirror's health right now.
  LateArrivalMirrorStatus get status => LateArrivalMirrorStatus(
        pending: _queue.length,
        consecutiveFailures: _consecutiveFailures,
        degraded: _degraded,
        lastError: _lastError,
        lastSuccessAt: _lastSuccessAt,
      );

  /// Queues [record] for mirroring and returns immediately.
  ///
  /// Called by the journal *after* the line is flushed, so this can never delay
  /// a ticket. It must not throw, and it does not: a store that is down is the
  /// pump's problem, not the desk's.
  @override
  void onRecord(LateArrivalRecord record) {
    if (_closed) return;
    _queue[record.id] = record;
    // A fresh registration is also the signal to try again after a stand-down:
    // the network that was down a minute ago may well be back.
    _degraded = false;
    _emit();
    unawaited(_pump());
  }

  /// Picks the queue back up after the worker stood down. Safe to call at any
  /// time; a no-op when there is nothing queued.
  void retryNow() {
    if (_closed || _queue.isEmpty) return;
    _degraded = false;
    _consecutiveFailures = 0;
    _emit();
    unawaited(_pump());
  }

  /// Reconciles the local journal against the shared store for [day].
  ///
  /// Two directions, and both matter:
  ///
  /// - **inwards** — registrations the store holds that [local] does not are
  ///   returned in [LateArrivalReconciliation.missingLocally]. That is the
  ///   stand-in operator's queue: her laptop has never seen the dead one's
  ///   morning, and this is the only place it can come from.
  /// - **outwards** — local records the store has no copy of, or holds in an
  ///   earlier status, are queued for a re-mirror. A machine that died between
  ///   the disk write and the mirror write heals itself here.
  ///
  /// Never throws: an unreachable store comes back as
  /// [LateArrivalReconciliation.error] with an empty result, and the desk
  /// carries on off its own journal.
  Future<LateArrivalReconciliation> reconcile({
    required SchoolDay day,
    required Iterable<LateArrivalRecord> local,
  }) async {
    final List<MirroredRegistration> remote;
    try {
      remote = await _store.readDay(day);
    } on Object catch (error) {
      _lastError = '$error';
      _emit();
      _log?.addError(
        core.Origin.all,
        'Te-laatregistraties van $day konden niet uit de gedeelde opslag '
        'gelezen worden: $error',
      );
      return LateArrivalReconciliation(
        day: day,
        missingLocally: const <MirroredRegistration>[],
        requeued: 0,
        error: '$error',
      );
    }

    final String desk = normalizeDeskId(_deskId);
    final Map<String, LateArrivalRecord> mine = <String, LateArrivalRecord>{
      for (final LateArrivalRecord r in local)
        if (r.day == day) r.id: r,
    };
    final Map<String, MirroredRegistration> stored =
        <String, MirroredRegistration>{
      for (final MirroredRegistration e in remote)
        if (e.deskId == desk) e.record.id: e,
    };

    final List<MirroredRegistration> missing = <MirroredRegistration>[
      for (final MirroredRegistration e in remote)
        // Another desk's work is by definition not in this journal; this desk's
        // own is missing only when the journal itself was lost.
        if (e.deskId != desk || !mine.containsKey(e.record.id)) e,
    ];

    int requeued = 0;
    for (final MapEntry<String, LateArrivalRecord> entry in mine.entries) {
      final MirroredRegistration? held = stored[entry.key];
      if (held != null && held.record.status == entry.value.status) continue;
      _queue[entry.key] = entry.value;
      requeued++;
    }
    if (requeued > 0) {
      _degraded = false;
      _consecutiveFailures = 0;
      unawaited(_pump());
    }
    _emit();

    return LateArrivalReconciliation(
      day: day,
      missingLocally: List<MirroredRegistration>.unmodifiable(missing),
      requeued: requeued,
    );
  }

  /// Completes once the queue is empty, or once the worker has stood down after
  /// [maxAttempts] failures. A shutdown hook, and what a test waits on instead
  /// of guessing at timings.
  Future<void> drain() {
    if (_queue.isEmpty && !_pumping) return Future<void>.value();
    unawaited(_pump());
    if (!_pumping) return Future<void>.value();
    final Completer<void> waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// Stops the worker and releases the status stream. Anything still queued
  /// stays in the journal on disk, which is where it was always the record of
  /// record.
  Future<void> close() async {
    _closed = true;
    await drain();
    _releaseWaiters();
    await _statuses.close();
  }

  /// Writes the queue out, one document at a time, retrying a failure in place.
  ///
  /// Only ever one pump runs: it is re-entered by every [onRecord], and the
  /// guard is what keeps a busy desk from opening a connection per scan.
  Future<void> _pump() async {
    if (_pumping || _closed) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_closed && !_degraded) {
        final LateArrivalRecord record = _queue.values.first;
        try {
          await _store.put(
            MirroredRegistration(
              deskId: _deskId,
              record: record,
              mirroredAt: _clock(),
            ),
          );
        } on Object catch (error) {
          _consecutiveFailures++;
          _lastError = '$error';
          if (_consecutiveFailures >= maxAttempts) {
            // Stand down — but loudly, and without dropping anything. The
            // record stays queued and stays on disk; what changes is that the
            // operator is told the shared copy is not being kept up.
            _degraded = true;
            _emit();
            _log?.addError(
              core.Origin.all,
              'Te-laatregistraties worden niet meer gespiegeld naar de '
              'gedeelde opslag (${_queue.length} in wachtrij): $error',
            );
            break;
          }
          _emit();
          await _sleep(backoff.delayFor(_consecutiveFailures));
          continue;
        }

        // Only drop what was actually written: a status change that landed
        // while the write was in flight replaced the queued value and still
        // owes the store a document.
        if (identical(_queue[record.id], record)) _queue.remove(record.id);
        _consecutiveFailures = 0;
        _lastError = null;
        _lastSuccessAt = _clock();
        _emit();
      }
    } finally {
      _pumping = false;
      _releaseWaiters();
    }
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
