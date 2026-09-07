/// The Cosmos mirror of the late-arrival journal (#403).
///
/// Five properties carry the feature, and every one of them is about a machine
/// that is no longer there:
///
/// - the mirror is strictly **behind** the journal — a store that never answers
///   does not delay the ticket by a millisecond;
/// - a status change reaches the mirrored document, so what a colleague sees is
///   the current state and not the morning's first guess;
/// - a failure is **retried** and never costs the local record;
/// - a *persistent* failure is put in front of the operator instead of going
///   quiet;
/// - and at startup, what the shared store holds and this journal does not is
///   surfaced — which is the entire reason the feature exists.
library;

import 'dart:async';

import 'package:account_core/account_core.dart' as core;
import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// A store whose every [put] parks until the test releases it — the "Cosmos is
/// slow" fake the hot-path ordering is proved against.
class BlockingMirrorStore implements LateArrivalMirrorStore {
  final List<Completer<void>> parked = <Completer<void>>[];
  final List<MirroredRegistration> written = <MirroredRegistration>[];
  bool _released = false;

  /// Lets everything through, now and from here on.
  void releaseAll() {
    _released = true;
    for (final Completer<void> c in parked) {
      if (!c.isCompleted) c.complete();
    }
    parked.clear();
  }

  @override
  Future<void> put(MirroredRegistration entry) async {
    if (!_released) {
      final Completer<void> gate = Completer<void>();
      parked.add(gate);
      await gate.future;
    }
    written.add(entry);
  }

  @override
  Future<List<MirroredRegistration>> readDay(SchoolDay day) async =>
      <MirroredRegistration>[
        for (final MirroredRegistration e in written)
          if (e.day == day) e,
      ];
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
  final SchoolDay mondayDay = SchoolDay.of(monday);

  ScanRegisterable scanOf(
    String uid, {
    String accountId = '123456',
    String name = 'Jane',
    String surname = 'Doe',
  }) {
    final ScanResolver resolver = ScanResolver.fromSmartschool(
      snapshot(
        accounts: [
          account(uid, accountId: accountId, givenName: name, surname: surname),
        ],
        groups: [ssGroup('SSM1A', name: '1A', sourceId: 298)],
        memberships: [membership(uid, 'SSM1A')],
      ),
    );
    return resolver.resolve(accountId) as ScanRegisterable;
  }

  Future<LateArrivalRecord> register(
    LateArrivalJournal journal,
    ScanRegisterable scan, {
    DateTime? at,
  }) =>
      journal.register(
        scan: scan,
        scannedAt: at ?? monday,
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );

  /// A mirror with no wall-clock waits, so the retry path runs at test speed.
  LateArrivalMirror mirrorOn(
    LateArrivalMirrorStore store, {
    String desk = 'onthaal-1',
    core.ILog? log,
    int maxAttempts = 4,
  }) =>
      LateArrivalMirror(
        store: store,
        deskId: desk,
        log: log,
        maxAttempts: maxAttempts,
        clock: () => monday,
        sleep: (Duration _) async {},
      );

  group('mirroring a registration', () {
    test('every journalled record reaches the shared store', () async {
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore();
      final LateArrivalMirror mirror = mirrorOn(store);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      await register(journal, scanOf('jane.doe'));
      await register(journal, scanOf('john.roe', accountId: '654321'));
      await mirror.drain();

      expect(store.entries.map((MirroredRegistration e) => e.documentId), [
        '2026-09-07|onthaal-1|0001',
        '2026-09-07|onthaal-1|0002',
      ]);
      expect(
        store.entries.first.record.status,
        LateArrivalStatus.pending,
      );
    });

    test('a status change propagates to the mirrored document', () async {
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore();
      final LateArrivalMirror mirror = mirrorOn(store);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
      );
      await mirror.drain();
      await journal.markSent(record.id);
      await mirror.drain();
      await journal.markConfirmed(record.id);
      await mirror.drain();

      // One document, walked forward — not three rows to reconcile later.
      expect(store.entries, hasLength(1));
      expect(store.entries.single.record.status, LateArrivalStatus.confirmed);
    });

    test('changes made while a write is in flight coalesce', () async {
      final BlockingMirrorStore store = BlockingMirrorStore();
      final LateArrivalMirror mirror = mirrorOn(store);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
      );
      // Both status lines are journalled while the first mirror write is still
      // parked — a slow store must not turn into a write per status line.
      await journal.markSent(record.id);
      await journal.markConfirmed(record.id);

      store.releaseAll();
      await mirror.drain();

      expect(store.written, hasLength(2));
      expect(store.written.last.record.status, LateArrivalStatus.confirmed);
      expect(mirror.status.pending, 0);
    });
  });

  group('the mirror sits behind the journal', () {
    test('a store that never answers does not delay the ticket', () async {
      final BlockingMirrorStore store = BlockingMirrorStore();
      final LateArrivalMirror mirror = mirrorOn(store);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      // The ticket prints off *this* future. It resolves with the mirror write
      // still parked mid-flight — which is the whole design constraint.
      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
      );

      expect(record.status, LateArrivalStatus.pending);
      expect(journal.pending, hasLength(1));
      expect(store.written, isEmpty, reason: 'still in flight');
      expect(store.parked, isNotEmpty);

      store.releaseAll();
      await mirror.drain();
      expect(store.written, hasLength(1));
    });

    test('a store that throws never reaches the desk', () async {
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore()..failure = StateError('Cosmos down');
      final LateArrivalMirror mirror = mirrorOn(store, maxAttempts: 2);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
      );
      await mirror.drain();

      // The registration is exactly as durable as it was before the mirror
      // existed, and the drain worker still owes it an attempt.
      expect(record.id, '2026-09-07-0001');
      expect(journal.pending.single.id, record.id);
    });
  });

  group('failures are retried and never lose the record', () {
    test('a transient failure is retried until it lands', () async {
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore()..failure = StateError('429');
      final LateArrivalMirror mirror = mirrorOn(store, maxAttempts: 6);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      // Bring the store back after the first attempt has already failed.
      final StreamSubscription<LateArrivalMirrorStatus> sub =
          mirror.statuses.listen((LateArrivalMirrorStatus s) {
        if (s.consecutiveFailures == 2) store.failure = null;
      });
      addTearDown(sub.cancel);

      await register(journal, scanOf('jane.doe'));
      await mirror.drain();

      expect(store.entries, hasLength(1));
      expect(mirror.status.pending, 0);
      expect(mirror.status.isHealthy, isTrue);
      expect(store.putAttempts, greaterThan(1));
    });

    test('a persistent failure stands down loudly, holding the queue',
        () async {
      final RecordingLog log = RecordingLog();
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore()
            ..failure = StateError('geen netwerk');
      final LateArrivalMirror mirror =
          mirrorOn(store, log: log, maxAttempts: 3);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      await register(journal, scanOf('jane.doe'));
      await mirror.drain();

      expect(store.putAttempts, 3);
      expect(mirror.status.degraded, isTrue);
      expect(mirror.status.isHealthy, isFalse);
      expect(mirror.status.pending, 1, reason: 'nothing was dropped');
      expect(mirror.status.lastError, contains('geen netwerk'));
      // Visible to the operator, not buried: the failure is reported once, when
      // the worker stops trying.
      expect(log.errors.single, contains('gespiegeld'));
      // And the local record is untouched.
      expect(journal.pending, hasLength(1));

      // When the network comes back, the held record still goes out.
      store.failure = null;
      mirror.retryNow();
      await mirror.drain();

      expect(store.entries, hasLength(1));
      expect(mirror.status.pending, 0);
      expect(mirror.status.degraded, isFalse);
    });

    test('a fresh registration picks the stood-down queue back up', () async {
      final InMemoryLateArrivalMirrorStore store =
          InMemoryLateArrivalMirrorStore()
            ..failure = StateError('geen netwerk');
      final LateArrivalMirror mirror = mirrorOn(store, maxAttempts: 2);
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        InMemoryJournalStore(),
        now: monday,
        sink: mirror,
      );

      await register(journal, scanOf('jane.doe'));
      await mirror.drain();
      expect(mirror.status.degraded, isTrue);

      store.failure = null;
      await register(journal, scanOf('john.roe', accountId: '654321'));
      await mirror.drain();

      expect(
        store.entries.map((MirroredRegistration e) => e.record.smartschoolUid),
        <String>['jane.doe', 'john.roe'],
        reason: 'the record held through the outage goes out too',
      );
    });
  });

  group('startup reconciliation', () {
    /// The colleague's laptop: a journal that has never seen this morning.
    Future<LateArrivalJournal> emptyJournal(LateArrivalMirror mirror) =>
        LateArrivalJournal.open(
          InMemoryJournalStore(),
          now: monday,
          sink: mirror,
        );

    test('surfaces the dead laptop\'s outstanding queue', () async {
      final InMemoryLateArrivalMirrorStore shared =
          InMemoryLateArrivalMirrorStore();

      // Desk 1 registers three students and then its laptop dies.
      final LateArrivalMirror deskOne = mirrorOn(shared, desk: 'onthaal-1');
      final LateArrivalJournal one = await emptyJournal(deskOne);
      final LateArrivalRecord first = await register(one, scanOf('jane.doe'));
      await register(one, scanOf('john.roe', accountId: '654321'));
      await register(one, scanOf('kim.poe', accountId: '222222'));
      await one.markSent(first.id);
      await one.markConfirmed(first.id);
      await deskOne.drain();

      // Desk 2 starts up on another machine with nothing of its own.
      final LateArrivalMirror deskTwo = mirrorOn(shared, desk: 'onthaal-2');
      final LateArrivalJournal two = await emptyJournal(deskTwo);
      final LateArrivalReconciliation found = await deskTwo.reconcile(
        day: mondayDay,
        local: two.records,
      );

      expect(found.available, isTrue);
      expect(found.missingLocally, hasLength(3));
      // Only the two that never reached Smartschool are work to pick up; the
      // confirmed one is somebody else's finished business.
      expect(
        found.outstanding
            .map((MirroredRegistration e) => e.record.smartschoolUid),
        <String>['john.roe', 'kim.poe'],
      );
      expect(found.requeued, 0);
    });

    test('a machine that owns the records surfaces none of them', () async {
      final InMemoryLateArrivalMirrorStore shared =
          InMemoryLateArrivalMirrorStore();
      final LateArrivalMirror mirror = mirrorOn(shared, desk: 'onthaal-1');
      final LateArrivalJournal journal = await emptyJournal(mirror);
      await register(journal, scanOf('jane.doe'));
      await mirror.drain();

      final LateArrivalReconciliation found = await mirror.reconcile(
        day: mondayDay,
        local: journal.records,
      );

      expect(found.missingLocally, isEmpty);
      expect(found.requeued, 0);
    });

    test('re-mirrors what this machine wrote but never managed to send',
        () async {
      final InMemoryLateArrivalMirrorStore shared =
          InMemoryLateArrivalMirrorStore()
            ..failure = StateError('geen netwerk');
      final LateArrivalMirror mirror =
          mirrorOn(shared, desk: 'onthaal-1', maxAttempts: 1);
      final LateArrivalJournal journal = await emptyJournal(mirror);
      await register(journal, scanOf('jane.doe'));
      await mirror.drain();
      expect(shared.entries, isEmpty);

      // Next launch: the network is back and the journal still holds the record.
      shared.failure = null;
      final LateArrivalMirror relaunched =
          mirrorOn(shared, desk: 'onthaal-1', maxAttempts: 1);
      final LateArrivalReconciliation found = await relaunched.reconcile(
        day: mondayDay,
        local: journal.records,
      );
      await relaunched.drain();

      expect(found.requeued, 1);
      expect(shared.entries, hasLength(1));
      expect(shared.entries.single.record.smartschoolUid, 'jane.doe');
    });

    test('re-mirrors a status the shared copy is behind on', () async {
      final InMemoryLateArrivalMirrorStore shared =
          InMemoryLateArrivalMirrorStore();
      final LateArrivalMirror mirror =
          mirrorOn(shared, desk: 'onthaal-1', maxAttempts: 1);
      final LateArrivalJournal journal = await emptyJournal(mirror);
      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
      );
      await mirror.drain();
      expect(shared.entries.single.record.status, LateArrivalStatus.pending);

      // The status line reached disk; the mirror write for it did not.
      shared.failure = StateError('geen netwerk');
      await journal.markSent(record.id);
      await mirror.drain();
      expect(shared.entries.single.record.status, LateArrivalStatus.pending);

      // Next launch, with the network back.
      shared.failure = null;
      final LateArrivalMirror relaunched =
          mirrorOn(shared, desk: 'onthaal-1', maxAttempts: 1);
      final LateArrivalReconciliation found = await relaunched.reconcile(
        day: mondayDay,
        local: journal.records,
      );
      await relaunched.drain();

      expect(found.requeued, 1);
      expect(shared.entries.single.record.status, LateArrivalStatus.sent);
    });

    test('an unreachable store does not take the launch down', () async {
      final InMemoryLateArrivalMirrorStore shared =
          InMemoryLateArrivalMirrorStore()
            ..failure = StateError('geen netwerk');
      final RecordingLog log = RecordingLog();
      final LateArrivalMirror mirror = mirrorOn(shared, log: log);
      final LateArrivalJournal journal = await emptyJournal(mirror);

      final LateArrivalReconciliation found = await mirror.reconcile(
        day: mondayDay,
        local: journal.records,
      );

      expect(found.available, isFalse);
      expect(found.error, contains('geen netwerk'));
      expect(found.missingLocally, isEmpty);
      expect(log.errors.single, contains('gedeelde opslag'));
    });
  });

  group('MirrorBackoff', () {
    test('doubles from the base and stops at the cap', () {
      const MirrorBackoff backoff = MirrorBackoff(
        base: Duration(seconds: 1),
        max: Duration(seconds: 8),
      );

      expect(backoff.delayFor(1), const Duration(seconds: 1));
      expect(backoff.delayFor(2), const Duration(seconds: 2));
      expect(backoff.delayFor(4), const Duration(seconds: 8));
      expect(backoff.delayFor(40), const Duration(seconds: 8));
    });
  });
}
