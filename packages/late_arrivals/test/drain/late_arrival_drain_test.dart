/// The background drain from the journal to Smartschool presences (#404).
///
/// Everything here runs against a **fake** presence service, and that is a
/// policy decision rather than a convenience: `setLate` is a write against a
/// live school tenant, and the repo's live-testing rule keeps write-capable
/// verification out of CI and in the operator's hands. So the fake is where the
/// four properties that carry the feature get proved:
///
/// - a student's registrations reach Smartschool in **scan order**, because a
///   presence save updates the half-day cell rather than appending to it and the
///   second scan is the one that must stand;
/// - a **transient** failure is retried and the registration still lands;
/// - a record that keeps failing reaches a **terminal** `failed` with the
///   server's own words on it, and stays visible;
/// - an **expired session** is signed in again rather than being given up on.
library;

import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// One call to [LatePresenceWriter.setLate], as it went out.
class SentPresence {
  SentPresence({
    required this.userId,
    required this.classGroupId,
    required this.date,
    required this.withoutValidReason,
    required this.motivation,
  });

  final int userId;
  final int classGroupId;
  final DateTime date;
  final bool withoutValidReason;
  final String motivation;

  @override
  String toString() => 'SentPresence($userId, $classGroupId, $motivation)';
}

/// A stand-in for `PresenceService`, scripted per attempt.
///
/// [failures] is consumed one entry per call: a non-null entry is thrown, a
/// null entry lets the write through. Anything past the end of the script
/// succeeds.
class FakePresenceWriter implements LatePresenceWriter {
  FakePresenceWriter({List<Object?> failures = const <Object?>[]})
      : _script = List<Object?>.of(failures);

  final List<Object?> _script;
  final List<SentPresence> sent = <SentPresence>[];
  final List<SentPresence> accepted = <SentPresence>[];
  int signIns = 0;
  Object? signInError;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  }) async {
    final SentPresence attempt = SentPresence(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      withoutValidReason: withoutValidReason,
      motivation: motivation,
    );
    sent.add(attempt);
    if (_script.isNotEmpty) {
      final Object? failure = _script.removeAt(0);
      if (failure != null) throw failure;
    }
    accepted.add(attempt);
  }

  @override
  Future<void> reauthenticate() async {
    signIns++;
    final Object? error = signInError;
    if (error != null) throw error;
  }
}

class RecordingLog implements core.ILog {
  final List<String> errors = <String>[];

  @override
  void addMessage(core.Origin origin, String message) {}

  @override
  void addError(core.Origin origin, String message) => errors.add(message);
}

void main() {
  final DateTime monday = DateTime(2026, 9, 7, 8, 14, 33);

  ScanRegisterable scanOf(
    String uid, {
    String accountId = '123456',
    String name = 'Jane',
    String surname = 'Doe',
    int sourceId = 298,
  }) {
    final ScanResolver resolver = ScanResolver.fromSmartschool(
      snapshot(
        accounts: [
          account(
            uid,
            accountId: accountId,
            givenName: name,
            surname: surname,
            // A distinct internal user id per student, so an assertion about
            // whose presence was written cannot pass by coincidence.
            referenceIdentifier: '4069_${int.parse(accountId)}_0',
          ),
        ],
        groups: [ssGroup('SSM1A', name: '1A', sourceId: sourceId)],
        memberships: [membership(uid, 'SSM1A')],
      ),
    );
    return resolver.resolve(accountId) as ScanRegisterable;
  }

  Future<LateArrivalRecord> register(
    LateArrivalJournal journal,
    ScanRegisterable scan, {
    DateTime? at,
    String reason = 'Bus te laat',
    bool valid = true,
  }) =>
      journal.register(
        scan: scan,
        scannedAt: at ?? monday,
        reasonLabel: reason,
        reasonIsValid: valid,
      );

  /// A drain with no wall-clock waits, so the backoff path runs at test speed.
  LateArrivalDrain drainOn(
    LateArrivalJournal journal,
    LatePresenceWriter writer, {
    core.ILog? log,
    int maxAttempts = 3,
    int maxSessionRenewals = 2,
    List<Duration>? waits,
  }) =>
      LateArrivalDrain(
        journal: journal,
        writer: writer,
        log: log,
        maxAttempts: maxAttempts,
        maxSessionRenewals: maxSessionRenewals,
        clock: () => monday,
        sleep: (Duration d) async => waits?.add(d),
      );

  Future<LateArrivalJournal> openJournal({LateArrivalRecordSink? sink}) =>
      LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: sink,
      );

  group('draining to Smartschool', () {
    test('sends the pending journal as morning presences', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter();
      final LateArrivalDrain drain = drainOn(journal, writer);

      drain.start();
      await drain.settle();

      expect(writer.accepted, hasLength(1));
      final SentPresence call = writer.accepted.single;
      expect(call.userId, 123456);
      expect(call.classGroupId, 298);
      // The day, at midnight — never the moment of the write.
      expect(call.date, DateTime(2026, 9, 7));
      expect(call.motivation, '08:14 – Bus te laat');
      expect(call.withoutValidReason, isFalse);
      expect(journal.pending, isEmpty);
      expect(journal.records.single.status, LateArrivalStatus.confirmed);
      await drain.close();
    });

    test('withoutValidReason follows the flag on the chosen reason', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(
        journal,
        scanOf('jane.doe'),
        reason: 'Uitgeslapen',
        valid: false,
      );
      final FakePresenceWriter writer = FakePresenceWriter();
      final LateArrivalDrain drain = drainOn(journal, writer);

      drain.start();
      await drain.settle();

      expect(writer.accepted.single.withoutValidReason, isTrue);
      expect(writer.accepted.single.motivation, '08:14 – Uitgeslapen');
      await drain.close();
    });

    test('a newly journalled registration wakes the drain', () async {
      final FakePresenceWriter writer = FakePresenceWriter();
      late final LateArrivalDrain drain;
      final LateArrivalJournal journal = await openJournal(
        sink: _LazySink(() => drain),
      );
      drain = drainOn(journal, writer);
      drain.start();
      await drain.settle();
      expect(writer.accepted, isEmpty);

      await register(journal, scanOf('jane.doe'));
      await drain.settle();

      expect(writer.accepted, hasLength(1));
      expect(journal.pending, isEmpty);
      await drain.close();
    });

    test('resumes the recovered journal after a restart', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first = await LateArrivalJournal.open(
        store,
        now: monday,
      );
      await register(first, scanOf('jane.doe'));
      // Crash: the record is on disk, nothing drained it.

      final LateArrivalJournal reopened = await LateArrivalJournal.open(
        store,
        now: monday,
      );
      expect(reopened.recovery.pendingCount, 1);

      final FakePresenceWriter writer = FakePresenceWriter();
      final LateArrivalDrain drain = drainOn(reopened, writer);
      drain.start();
      await drain.settle();

      expect(writer.accepted, hasLength(1));
      expect(reopened.pending, isEmpty);
      await drain.close();
    });
  });

  group('ordering per student', () {
    test('two scans of one student are written in scan order', () async {
      final LateArrivalJournal journal = await openJournal();
      final ScanRegisterable jane = scanOf('jane.doe');
      await register(
        journal,
        jane,
        at: monday,
        reason: 'Bus te laat',
      );
      await register(
        journal,
        jane,
        at: DateTime(2026, 9, 7, 8, 41),
        reason: 'Doktersbriefje',
      );

      final FakePresenceWriter writer = FakePresenceWriter();
      final LateArrivalDrain drain = drainOn(journal, writer);
      drain.start();
      await drain.settle();

      // The second scan is the correction, and a presence save overwrites the
      // half-day cell — so it has to be the last one on the wire.
      expect(
        writer.accepted.map((SentPresence p) => p.motivation).toList(),
        <String>['08:14 – Bus te laat', '08:41 – Doktersbriefje'],
      );
      await drain.close();
    });

    test('order per student survives a retry of the first scan', () async {
      final LateArrivalJournal journal = await openJournal();
      final ScanRegisterable jane = scanOf('jane.doe');
      await register(journal, jane, reason: 'Bus te laat');
      await register(
        journal,
        jane,
        at: DateTime(2026, 9, 7, 8, 41),
        reason: 'Doktersbriefje',
      );

      // The first scan fails twice before landing. A worker that gave up on
      // ordering under retry would let the second scan overtake it, and the
      // desk's correction would be silently undone.
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const SocketFailure('verbinding verbroken'),
          const SocketFailure('verbinding verbroken'),
        ],
      );
      final LateArrivalDrain drain = drainOn(journal, writer);
      drain.start();
      await drain.settle();

      expect(
        writer.accepted.map((SentPresence p) => p.motivation).toList(),
        <String>['08:14 – Bus te laat', '08:41 – Doktersbriefje'],
      );
      await drain.close();
    });
  });

  group('retrying a transient failure', () {
    test('a dropped connection is retried and the record still lands',
        () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[const SocketFailure('502 Bad Gateway')],
      );
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain = drainOn(journal, writer, waits: waits);

      drain.start();
      await drain.settle();

      expect(writer.sent, hasLength(2));
      expect(writer.accepted, hasLength(1));
      expect(journal.records.single.status, LateArrivalStatus.confirmed);
      expect(journal.records.single.error, isNull);
      // Backed off before going round again, rather than hammering.
      expect(waits, <Duration>[const Duration(seconds: 2)]);
      expect(drain.status.isHealthy, isTrue);
      await drain.close();
    });

    test('the backoff grows between attempts', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const SocketFailure('x'),
          const SocketFailure('x'),
        ],
      );
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain = drainOn(
        journal,
        writer,
        maxAttempts: 4,
        waits: waits,
      );

      drain.start();
      await drain.settle();

      expect(waits, <Duration>[
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      await drain.close();
    });
  });

  group('an expired session', () {
    test('signs in again and retries without spending an attempt', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const PresenceSessionExpired('De sessie is verlopen.'),
        ],
      );
      final List<Duration> waits = <Duration>[];
      // One attempt only: if the expiry had counted as a strike, the record
      // would be terminally failed instead of confirmed.
      final LateArrivalDrain drain = drainOn(
        journal,
        writer,
        maxAttempts: 1,
        waits: waits,
      );

      drain.start();
      await drain.settle();

      expect(writer.signIns, 1);
      expect(writer.accepted, hasLength(1));
      expect(journal.records.single.status, LateArrivalStatus.confirmed);
      // No backoff either — a fresh session is a new situation, not a wait.
      expect(waits, isEmpty);
      await drain.close();
    });

    test('a sign-in that keeps failing ends as a visible failure', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const PresenceSessionExpired('verlopen'),
          const PresenceSessionExpired('verlopen'),
          const PresenceSessionExpired('verlopen'),
          const PresenceSessionExpired('verlopen'),
        ],
      );
      writer.signInError = const SocketFailure('wachtwoord geweigerd');
      final LateArrivalDrain drain = drainOn(journal, writer, maxAttempts: 2);

      drain.start();
      await drain.settle();

      expect(journal.records.single.status, LateArrivalStatus.failed);
      expect(
        journal.records.single.error,
        contains('wachtwoord geweigerd'),
      );
      await drain.close();
    });

    test('re-authentication is capped so it cannot loop forever', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          for (int i = 0; i < 20; i++) const PresenceSessionExpired('verlopen'),
        ],
      );
      final LateArrivalDrain drain = drainOn(
        journal,
        writer,
        maxAttempts: 2,
        maxSessionRenewals: 2,
      );

      drain.start();
      await drain.settle();

      expect(writer.signIns, 2);
      expect(journal.records.single.status, LateArrivalStatus.failed);
      await drain.close();
    });
  });

  group('giving up', () {
    test('a rejected write fails at once, keeping the server text', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const PresenceRejected(
            'Klas 298 hoort niet bij dit account.',
          ),
        ],
      );
      final RecordingLog log = RecordingLog();
      final LateArrivalDrain drain = drainOn(journal, writer, log: log);

      drain.start();
      await drain.settle();

      // Once — retrying a refusal only buries the explanation.
      expect(writer.sent, hasLength(1));
      final LateArrivalRecord failed = journal.records.single;
      expect(failed.status, LateArrivalStatus.failed);
      expect(failed.error, 'Klas 298 hoort niet bij dit account.');
      expect(drain.failures.single.id, failed.id);
      expect(drain.status.failed, 1);
      expect(drain.status.needsAttention, isTrue);
      expect(log.errors.single, contains('Jane Doe'));
      await drain.close();
    });

    test('a rejection does not hold up the rest of the queue', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      await register(
        journal,
        scanOf('john.roe', accountId: '654321', name: 'John', surname: 'Roe'),
      );
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[const PresenceRejected('geen rechten')],
      );
      final LateArrivalDrain drain = drainOn(journal, writer);

      drain.start();
      await drain.settle();

      expect(writer.accepted, hasLength(1));
      expect(journal.records.first.status, LateArrivalStatus.failed);
      expect(journal.records.last.status, LateArrivalStatus.confirmed);
      await drain.close();
    });

    test('a record that exhausts its attempts fails with the last error',
        () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          const SocketFailure('eerste'),
          const SocketFailure('tweede'),
          const SocketFailure('derde — de laatste'),
        ],
      );
      final RecordingLog log = RecordingLog();
      final LateArrivalDrain drain = drainOn(
        journal,
        writer,
        maxAttempts: 3,
        log: log,
      );

      drain.start();
      await drain.settle();

      expect(writer.sent, hasLength(3));
      final LateArrivalRecord failed = journal.records.single;
      expect(failed.status, LateArrivalStatus.failed);
      expect(failed.error, contains('derde — de laatste'));
      // Terminal means terminal: the operator can still see it.
      expect(journal.pending, isEmpty);
      expect(drain.failures, hasLength(1));
      await drain.close();
    });

    test('an outage stands the worker down instead of failing the queue',
        () async {
      final LateArrivalJournal journal = await openJournal();
      for (int i = 0; i < 4; i++) {
        await register(
          journal,
          scanOf('pupil$i', accountId: '10000$i'),
          at: DateTime(2026, 9, 7, 8, 10 + i),
        );
      }
      // Smartschool is simply down: everything thrown at it fails.
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[
          for (int i = 0; i < 50; i++) const SocketFailure('geen verbinding'),
        ],
      );
      final RecordingLog log = RecordingLog();
      final LateArrivalDrain drain = drainOn(
        journal,
        writer,
        maxAttempts: 2,
        log: log,
      );

      drain.start();
      await drain.settle();

      // Exactly one record spent its budget; the other three are untouched and
      // still on disk, which is what a ten-minute outage must cost.
      expect(
        journal.records.where(
          (LateArrivalRecord r) => r.status == LateArrivalStatus.failed,
        ),
        hasLength(1),
      );
      expect(journal.pending, hasLength(3));
      expect(drain.status.degraded, isTrue);
      expect(drain.status.outstanding, 3);
      expect(log.errors.any((String e) => e.contains('wachtrij')), isTrue);

      // And the queue picks straight back up once Smartschool answers again.
      final FakePresenceWriter recovered = FakePresenceWriter();
      final LateArrivalDrain second = drainOn(journal, recovered);
      second.retryNow();
      await second.settle();
      expect(recovered.accepted, hasLength(3));
      expect(journal.pending, isEmpty);
      await drain.close();
      await second.close();
    });
  });

  group('the status the scan tab reads', () {
    test('counts what is outstanding and what is stuck', () async {
      final LateArrivalJournal journal = await openJournal();
      await register(journal, scanOf('jane.doe'));
      await register(
        journal,
        scanOf('john.roe', accountId: '654321', name: 'John', surname: 'Roe'),
      );
      final FakePresenceWriter writer = FakePresenceWriter(
        failures: <Object?>[const PresenceRejected('geen rechten')],
      );
      final LateArrivalDrain drain = drainOn(journal, writer);

      expect(drain.status.outstanding, 2);
      expect(drain.status.isHealthy, isFalse);

      final List<LateArrivalDrainStatus> seen = <LateArrivalDrainStatus>[];
      final StreamSubscription<LateArrivalDrainStatus> sub =
          drain.statuses.listen(seen.add);

      drain.start();
      await drain.settle();
      await Future<void>.delayed(Duration.zero);

      expect(drain.status.outstanding, 0);
      expect(drain.status.failed, 1);
      expect(drain.status.needsAttention, isTrue);
      expect(seen, isNotEmpty);
      expect(seen.any((LateArrivalDrainStatus s) => s.draining), isTrue);
      await sub.cancel();
      await drain.close();
    });
  });

  group('fanning the journal out', () {
    test('every sink hears about a record, even when one throws', () async {
      final _CountingSink good = _CountingSink();
      final LateArrivalJournal journal = await openJournal(
        sink: FanOutRecordSink(<LateArrivalRecordSink>[
          _ThrowingSink(),
          good,
        ]),
      );

      await register(journal, scanOf('jane.doe'));

      expect(good.seen, 1);
    });
  });
}

/// A transport-level fault: what a dropped connection or a 502 looks like to
/// the drain. Anything that is neither a rejection nor an expiry is transient.
class SocketFailure implements Exception {
  const SocketFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lets the journal be opened with a sink that is constructed afterwards — the
/// drain needs the journal, and the journal wants the drain.
class _LazySink implements LateArrivalRecordSink {
  _LazySink(this._target);

  final LateArrivalRecordSink Function() _target;

  @override
  void onRecord(LateArrivalRecord record) => _target().onRecord(record);
}

class _CountingSink implements LateArrivalRecordSink {
  int seen = 0;

  @override
  void onRecord(LateArrivalRecord record) => seen++;
}

class _ThrowingSink implements LateArrivalRecordSink {
  @override
  void onRecord(LateArrivalRecord record) =>
      throw StateError('deze sink is stuk');
}
