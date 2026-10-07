/// The durability contract of the late-arrival journal (#402).
///
/// Four properties carry the feature, and every one of them is a thing that
/// only shows up when something has gone wrong: a record that produced a ticket
/// is on disk *before* the ticket prints; a restart finds everything that was
/// not drained; a crash mid-write costs the torn line and nothing else; and a
/// student scanned twice drains in the order they were scanned, because the
/// second scan is the real one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  /// 07 Sep 2026, 08:14 local — a plausible moment to be late.
  final DateTime monday = DateTime(2026, 9, 7, 8, 14, 33);
  final SchoolDay mondayDay = SchoolDay.of(monday);

  ScanRegisterable scanOf(
    String uid, {
    String accountId = '123456',
    String name = 'Jane',
    String surname = 'Doe',
    String classCode = 'SSM1A',
    String className = '1A',
    int sourceId = 298,
    String referenceIdentifier = '4069_12016_0',
    core.PersonId? personId,
  }) {
    final ScanResolver resolver = ScanResolver.fromSmartschool(
      snapshot(
        accounts: [
          account(
            uid,
            accountId: accountId,
            givenName: name,
            surname: surname,
            referenceIdentifier: referenceIdentifier,
          ),
        ],
        groups: [ssGroup(classCode, name: className, sourceId: sourceId)],
        memberships: [membership(uid, classCode)],
      ),
      personIdsByUid: personId == null
          ? const <String, core.PersonId>{}
          : <String, core.PersonId>{uid: personId},
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

  group('append and read back', () {
    test('a registration survives a restart, whole', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);

      final LateArrivalRecord written = await register(
        first,
        scanOf('jane.doe', personId: const core.PersonId('p-1')),
      );

      // A whole new process's worth of state, over the same files.
      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);

      expect(second.records, hasLength(1));
      final LateArrivalRecord read = second.records.single;
      expect(read.id, written.id);
      expect(read.id, '2026-09-07-0001');
      expect(read.day, mondayDay);
      expect(read.sequence, 1);
      expect(read.scannedAt, monday);
      expect(read.smartschoolUid, 'jane.doe');
      expect(read.wisaId, '123456');
      expect(read.personId, 'p-1');
      expect(read.displayName, 'Jane Doe');
      expect(read.className, '1A');
      expect(read.internalUserId, 12016);
      expect(read.classGroupId, 298);
      expect(read.reasonLabel, 'Bus te laat');
      expect(read.reasonIsValid, isTrue);
      expect(read.motivation, '08:14 – Bus te laat');
      expect(read.status, LateArrivalStatus.pending);
      expect(second.recovery.isClean, isTrue);
    });

    test('the motivation keeps the fixed format for an invalid reason',
        () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);

      final LateArrivalRecord record = await register(
        journal,
        scanOf('jane.doe'),
        at: DateTime(2026, 9, 7, 9, 5),
        reason: 'zonder geldige reden',
        valid: false,
      );

      expect(record.motivation, '09:05 – zonder geldige reden');
      expect(record.reasonIsValid, isFalse);
    });

    test('each registration is one self-contained line', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);
      await register(journal, scanOf('jane.doe'));

      final List<String> lines = (await store.read(mondayDay))
          .split('\n')
          .where((String l) => l.isNotEmpty)
          .toList();

      expect(lines, hasLength(1));
      final Map<String, Object?> decoded =
          jsonDecode(lines.single) as Map<String, Object?>;
      expect(decoded['kind'], 'registration');
      expect(decoded['uid'], 'jane.doe');
      expect(decoded['status'], 'pending');
    });
  });

  group('durability ordering', () {
    test('register does not complete until the line is durable', () async {
      final _GatedJournalStore store = _GatedJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);

      store.gate = Completer<void>();
      bool printed = false;
      final Future<void> registration =
          register(journal, scanOf('jane.doe')).then((_) => printed = true);

      await _settle();
      expect(
        printed,
        isFalse,
        reason: 'the ticket must not print while the write is in flight',
      );
      expect(
        journal.pending,
        isEmpty,
        reason: 'the journal must not claim a record the disk has not got',
      );

      store.gate!.complete();
      await registration;

      expect(printed, isTrue);
      expect(journal.pending, hasLength(1));
    });

    test('a status change is durable before it is visible', () async {
      final _GatedJournalStore store = _GatedJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord record = await register(journal, scanOf('jd'));

      store.gate = Completer<void>();
      final Future<LateArrivalRecord> sending = journal.markSent(record.id);
      await _settle();

      expect(journal.byId(record.id)!.status, LateArrivalStatus.pending);
      store.gate!.complete();
      await sending;
      expect(journal.byId(record.id)!.status, LateArrivalStatus.sent);
    });
  });

  group('status transitions', () {
    test('pending → sent → confirmed is replayed after a restart', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord record =
          await register(first, scanOf('jane.doe'));
      await first.markSent(record.id);
      await first.markConfirmed(record.id);

      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);

      expect(second.records.single.status, LateArrivalStatus.confirmed);
      expect(second.pending, isEmpty);
    });

    test('a failure is terminal and keeps its reason across a restart',
        () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord record =
          await register(first, scanOf('jane.doe'));
      await first.markSent(record.id);
      await first.markFailed(record.id, 'sessie verlopen');

      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord read = second.records.single;

      expect(read.status, LateArrivalStatus.failed);
      expect(read.error, 'sessie verlopen');
      expect(second.pending, isEmpty);
      expect(
        () => second.markSent(read.id),
        throwsA(isA<StateError>()),
        reason: 'nothing walks back out of a terminal state',
      );
    });

    test('a transient failure requeues rather than ending the record',
        () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord record =
          await register(journal, scanOf('jane.doe'));

      await journal.markSent(record.id);
      await journal.markPending(record.id);

      expect(journal.pending.single.status, LateArrivalStatus.pending);
    });

    test('a status change for an unknown id is a programming error', () {
      expect(
        () async => (await LateArrivalJournal.open(
          InMemoryJournalStore(),
          now: monday,
        ))
            .markSent('2026-09-07-0009'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the operator\'s way out of a failure (#460)', () {
    /// One registration of [uid], given up on with [error] — what the drain
    /// leaves behind after a refusal.
    Future<LateArrivalRecord> failedOne(
      LateArrivalJournal journal,
      String uid, {
      DateTime? at,
      String error = 'Empty response from /Presence/Main/getConfig.',
    }) async {
      final LateArrivalRecord record =
          await register(journal, scanOf(uid), at: at);
      await journal.markSent(record.id);
      return journal.markFailed(record.id, error);
    }

    test(
        'a requeued failure is queued again — and still is after a reload, '
        'where the older failed line does not win', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord failed = await failedOne(first, 'jane.doe');
      expect(first.failures.map((LateArrivalRecord r) => r.id), [failed.id]);

      final LateArrivalRecord requeued = await first.requeueFailed(failed.id);

      expect(requeued.status, LateArrivalStatus.pending);
      expect(requeued.error, isNull);
      expect(requeued.requeuedByOperator, isTrue);
      expect(first.pending.map((LateArrivalRecord r) => r.id), [failed.id]);
      expect(first.failures, isEmpty);

      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord read = second.byId(failed.id)!;
      expect(read.status, LateArrivalStatus.pending);
      expect(read.requeuedByOperator, isTrue);
      expect(second.pending.map((LateArrivalRecord r) => r.id), [failed.id]);
      expect(second.failures, isEmpty);
      expect(second.recovery.pendingCount, 1);
    });

    test('the requeue mark outlives the drain\'s later lines', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord failed = await failedOne(first, 'jane.doe');
      await first.requeueFailed(failed.id);
      await first.markSent(failed.id);
      await first.markPending(failed.id);
      await first.markSent(failed.id);
      await first.markConfirmed(failed.id);

      expect(first.byId(failed.id)!.requeuedByOperator, isTrue);
      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);
      expect(second.byId(failed.id)!.status, LateArrivalStatus.confirmed);
      expect(second.byId(failed.id)!.requeuedByOperator, isTrue);
    });

    test('the drain itself still cannot walk out of failed', () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord failed = await failedOne(journal, 'jane.doe');

      for (final Future<LateArrivalRecord> Function() drainWrite
          in <Future<LateArrivalRecord> Function()>[
        () => journal.markPending(failed.id),
        () => journal.markSent(failed.id),
        () => journal.markConfirmed(failed.id),
      ]) {
        await expectLater(drainWrite(), throwsA(isA<StateError>()));
      }
      expect(
          LateArrivalStatus.failed.canTransitionTo(LateArrivalStatus.pending),
          isFalse);
      expect(journal.byId(failed.id)!.status, LateArrivalStatus.failed);
    });

    test('only a failed registration can be requeued', () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord queued =
          await register(journal, scanOf('a.one', accountId: '111111'));
      final LateArrivalRecord sent =
          await register(journal, scanOf('b.two', accountId: '222222'));
      await journal.markSent(sent.id);
      final LateArrivalRecord confirmed =
          await register(journal, scanOf('c.three', accountId: '333333'));
      await journal.markConfirmed(confirmed.id);
      final LateArrivalRecord handled = await failedOne(journal, 'd.four');
      await journal.markHandledManually(handled.id);

      for (final String id in <String>[
        queued.id,
        sent.id,
        confirmed.id,
        handled.id,
      ]) {
        await expectLater(
          journal.requeueFailed(id),
          throwsA(isA<StateError>()),
          reason: '${journal.byId(id)!.status.wireName} is not failed',
        );
      }
      await expectLater(
        journal.requeueFailed('2026-09-07-0099'),
        throwsA(isA<StateError>()),
      );
    });

    test(
        'a later scan of the same student and half-day supersedes a failure; '
        'one of the other half-day does not', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord morning = await failedOne(
        journal,
        'jane.doe',
        at: DateTime(2026, 9, 7, 8, 10),
      );
      final LateArrivalRecord afternoon = await register(
        journal,
        scanOf('jane.doe'),
        at: DateTime(2026, 9, 7, 13, 5),
      );
      expect(journal.supersededBy(morning), isNull);
      expect(journal.failures.map((LateArrivalRecord r) => r.id), [morning.id]);

      final LateArrivalRecord correction = await register(
        journal,
        scanOf('jane.doe'),
        at: DateTime(2026, 9, 7, 8, 40),
      );

      expect(journal.supersededBy(morning)?.id, correction.id);
      expect(journal.supersededBy(correction), isNull);
      expect(journal.supersededBy(afternoon), isNull);
      expect(journal.failures, isEmpty);
      expect(await journal.requeueFailures(), isEmpty);
      await expectLater(
        journal.requeueFailed(morning.id),
        throwsA(isA<StateError>()),
      );
      // Still in the journal, still failed — it simply no longer matters.
      expect(journal.byId(morning.id)!.status, LateArrivalStatus.failed);

      final LateArrivalJournal reloaded =
          await LateArrivalJournal.open(store, now: monday);
      expect(reloaded.failures, isEmpty);
    });

    test('requeueFailures requeues every failure on the list, in drain order',
        () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord a = await failedOne(
        journal,
        'a.one',
        at: DateTime(2026, 9, 7, 8, 10),
      );
      await register(
        journal,
        scanOf('b.two', accountId: '222222'),
        at: DateTime(2026, 9, 7, 8, 11),
      );
      final LateArrivalRecord c = await failedOne(
        journal,
        'c.three',
        at: DateTime(2026, 9, 7, 8, 12),
      );

      final List<LateArrivalRecord> requeued = await journal.requeueFailures();

      expect(requeued.map((LateArrivalRecord r) => r.id), [a.id, c.id]);
      expect(journal.failures, isEmpty);
      expect(
        journal.pending.map((LateArrivalRecord r) => r.id).toList(),
        hasLength(3),
      );
      expect(journal.pending.first.id, a.id);
    });

    test(
        'handled by hand: off the failure list for good, still in the '
        'journal, and so after a reload', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord failed =
          await failedOne(first, 'jane.doe', error: 'geen rechten');

      final LateArrivalRecord handled =
          await first.markHandledManually(failed.id);

      for (final LateArrivalJournal journal in <LateArrivalJournal>[
        first,
        await LateArrivalJournal.open(store, now: monday),
      ]) {
        final LateArrivalRecord read = journal.byId(failed.id)!;
        expect(read.status, LateArrivalStatus.handledManually);
        expect(read.status.isTerminal, isTrue);
        // Why it had to be entered by hand stays part of its story.
        expect(read.error, 'geen rechten');
        expect(journal.failures, isEmpty);
        expect(journal.pending, isEmpty);
        expect(await journal.requeueFailures(), isEmpty);
        // Never deleted: append-only, and still answerable per student.
        expect(journal.records.map((LateArrivalRecord r) => r.id), [failed.id]);
        expect(journal.recordsOf('jane.doe').single.status,
            LateArrivalStatus.handledManually);
      }
      expect(handled.status, LateArrivalStatus.handledManually);
      expect(await store.read(mondayDay), contains('"handled-manually"'));
    });

    test(
        'handled by hand is refused from pending, sent and confirmed, and the '
        'drain can never write it', () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord queued =
          await register(journal, scanOf('a.one', accountId: '111111'));
      final LateArrivalRecord sent =
          await register(journal, scanOf('b.two', accountId: '222222'));
      await journal.markSent(sent.id);
      final LateArrivalRecord confirmed =
          await register(journal, scanOf('c.three', accountId: '333333'));
      await journal.markConfirmed(confirmed.id);

      for (final LateArrivalRecord record in <LateArrivalRecord>[
        queued,
        sent,
        confirmed,
      ]) {
        final LateArrivalStatus before = journal.byId(record.id)!.status;
        await expectLater(
          journal.markHandledManually(record.id),
          throwsA(isA<StateError>()),
          reason: '${before.wireName} is not the operator\'s to settle',
        );
        expect(journal.byId(record.id)!.status, before);
      }
      // The drain's rule: no state at all may walk into it.
      for (final LateArrivalStatus from in LateArrivalStatus.values) {
        expect(
          from.canTransitionTo(LateArrivalStatus.handledManually),
          isFalse,
          reason: 'the drain may not record handled-manually from '
              '${from.wireName}',
        );
      }
      // …and nothing walks back out of it either.
      final LateArrivalRecord failed = await failedOne(journal, 'd.four');
      await journal.markHandledManually(failed.id);
      await expectLater(
        journal.markHandledManually(failed.id),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        journal.markPending(failed.id),
        throwsA(isA<StateError>()),
      );
    });

    test('a day settled by hand rolls off after retention like any drained one',
        () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal back = await LateArrivalJournal.open(
        store,
        now: DateTime(2026, 6, 1, 8, 30),
      );
      final LateArrivalRecord failed = await failedOne(
        back,
        'a.one',
        at: DateTime(2026, 6, 1, 8, 30),
      );
      final LateArrivalJournal stillFailed =
          await LateArrivalJournal.open(store, now: DateTime(2026, 6, 1, 9));
      expect(stillFailed.failures, hasLength(1));
      await stillFailed.markHandledManually(failed.id);

      final LateArrivalJournal now =
          await LateArrivalJournal.open(store, now: monday);

      expect(now.recovery.rolledOff, <SchoolDay>[const SchoolDay(2026, 6, 1)]);
      expect(now.records, isEmpty);
    });

    test('the operator\'s lines round-trip through the record\'s JSON', () {
      final LateArrivalRecord? back = LateArrivalRecord.tryFromJson(
        <String, Object?>{
          'id': '2026-09-07-0001',
          'day': '2026-09-07',
          'seq': 1,
          'scannedAt': '2026-09-07T08:10:00.000',
          'uid': 'a.one',
          'userId': 12016,
          'groupId': 298,
          'status': 'handled-manually',
          'error': 'geen rechten',
          'requeuedByOperator': true,
        },
      );
      expect(back?.status, LateArrivalStatus.handledManually);
      expect(back?.error, 'geen rechten');
      expect(back?.requeuedByOperator, isTrue);
      expect(back!.toJson()['status'], 'handled-manually');
      expect(back.toJson()['requeuedByOperator'], isTrue);
      expect(
        LateArrivalStatus.tryParse('handled-manually'),
        LateArrivalStatus.handledManually,
      );
    });
  });

  group('recovery', () {
    test('surfaces every non-terminal record for draining, in order', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);

      final LateArrivalRecord a = await register(first, scanOf('a.one'),
          at: DateTime(2026, 9, 7, 8, 10));
      final LateArrivalRecord b = await register(first, scanOf('b.two'),
          at: DateTime(2026, 9, 7, 8, 11));
      final LateArrivalRecord c = await register(first, scanOf('c.three'),
          at: DateTime(2026, 9, 7, 8, 12));
      await first.markConfirmed(b.id); // b is done; a and c are not.
      await first.markSent(c.id);

      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);

      expect(
        second.pending.map((LateArrivalRecord r) => r.id),
        <String>[a.id, c.id],
      );
      expect(second.recovery.recordCount, 3);
      expect(second.recovery.pendingCount, 2);
      expect(second.recovery.days, <SchoolDay>[mondayDay]);
    });

    test('yesterday\'s undrained records come back too, before today\'s',
        () async {
      const SchoolDay friday = SchoolDay(2026, 9, 4);
      final InMemoryJournalStore store = InMemoryJournalStore();

      final LateArrivalJournal onFriday = await LateArrivalJournal.open(
        store,
        now: DateTime(2026, 9, 4, 8, 20),
      );
      final LateArrivalRecord stranded = await register(
        onFriday,
        scanOf('a.one'),
        at: DateTime(2026, 9, 4, 8, 20),
      );

      final LateArrivalJournal onMonday =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord fresh =
          await register(onMonday, scanOf('b.two'), at: monday);

      expect(
        onMonday.pending.map((LateArrivalRecord r) => r.id),
        <String>[stranded.id, fresh.id],
      );
      expect(stranded.day, friday);
      expect(onMonday.recovery.days, <SchoolDay>[friday]);
    });
  });

  group('a crash mid-write', () {
    test('costs the torn trailing line and nothing else', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord kept = await register(first, scanOf('a.one'),
          at: DateTime(2026, 9, 7, 8, 10));
      await register(first, scanOf('b.two'), at: DateTime(2026, 9, 7, 8, 11));

      // Cut the file in the middle of the second registration's line, exactly
      // as a power loss during the write would.
      final String whole = await store.read(mondayDay);
      final int lastLineStart = whole.lastIndexOf('\n', whole.length - 2) + 1;
      final String torn = whole.substring(0, lastLineStart + 20);
      final InMemoryJournalStore crashed =
          InMemoryJournalStore(<SchoolDay, String>{mondayDay: torn});

      final LateArrivalJournal after =
          await LateArrivalJournal.open(crashed, now: monday);

      expect(
          after.records.map((LateArrivalRecord r) => r.id), <String>[kept.id]);
      expect(after.recovery.truncatedTails, 1);
      expect(after.recovery.damagedLines, 0);
      expect(after.recovery.isClean, isFalse);
    });

    test('the next registration keeps appending to the repaired day', () async {
      final InMemoryJournalStore store = InMemoryJournalStore(
        <SchoolDay, String>{
          mondayDay: '${jsonEncode(<String, Object?>{
                'kind': 'registration',
                'id': '2026-09-07-0001',
                'day': '2026-09-07',
                'seq': 1,
                'scannedAt': '2026-09-07T08:10:00.000',
                'uid': 'a.one',
                'wisaId': '111111',
                'name': 'A One',
                'className': '1A',
                'userId': 12016,
                'groupId': 298,
                'reason': 'Bus te laat',
                'reasonValid': true,
                'motivation': '08:10 – Bus te laat',
                'status': 'pending',
              })}\n{"kind":"registrati',
        },
      );

      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);
      final LateArrivalRecord next = await register(journal, scanOf('b.two'));

      expect(next.id, '2026-09-07-0002');
      expect(journal.pending, hasLength(2));
    });

    test('a complete but unreadable line is counted, not fatal', () async {
      final InMemoryJournalStore store = InMemoryJournalStore(
        <SchoolDay, String>{mondayDay: '{not json at all}\n{"kind":"weird"}\n'},
      );

      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);

      expect(journal.records, isEmpty);
      expect(journal.recovery.damagedLines, 2);
      expect(journal.recovery.truncatedTails, 0);
    });

    test('a status line naming nothing is counted as an orphan', () async {
      final InMemoryJournalStore store = InMemoryJournalStore(
        <SchoolDay, String>{
          mondayDay:
              '{"kind":"status","id":"2026-09-07-0007","status":"sent"}\n',
        },
      );

      final LateArrivalJournal journal =
          await LateArrivalJournal.open(store, now: monday);

      expect(journal.records, isEmpty);
      expect(journal.recovery.orphanStatusLines, 1);
      expect(journal.recovery.damagedLines, 0);
    });
  });

  group('ordering per student', () {
    test('a second scan of the same student drains after the first', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal first =
          await LateArrivalJournal.open(store, now: monday);

      final LateArrivalRecord early = await register(
        first,
        scanOf('jane.doe'),
        at: DateTime(2026, 9, 7, 8, 10),
        reason: 'Bus te laat',
      );
      await register(first, scanOf('other.one', accountId: '222222'),
          at: DateTime(2026, 9, 7, 8, 11));
      final LateArrivalRecord late = await register(
        first,
        scanOf('jane.doe'),
        at: DateTime(2026, 9, 7, 8, 40),
        reason: 'zonder geldige reden',
        valid: false,
      );

      // The correction must be the last thing Smartschool sees, in this session
      // and after a reload — a presence save overwrites the half-day cell.
      final LateArrivalJournal second =
          await LateArrivalJournal.open(store, now: monday);
      for (final LateArrivalJournal journal in <LateArrivalJournal>[
        first,
        second,
      ]) {
        expect(
          journal.recordsOf('jane.doe').map((LateArrivalRecord r) => r.id),
          <String>[early.id, late.id],
        );
        expect(
          journal.recordsOf('jane.doe').last.reasonLabel,
          'zonder geldige reden',
        );
        final List<String> drainOrder =
            journal.pending.map((LateArrivalRecord r) => r.id).toList();
        expect(
          drainOrder.indexOf(early.id),
          lessThan(drainOrder.indexOf(late.id)),
        );
      }
    });

    test('a backdated scan still sorts into its place', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal journal = await LateArrivalJournal.open(
        store,
        now: monday,
      );

      final LateArrivalRecord today =
          await register(journal, scanOf('a.one'), at: monday);
      final LateArrivalRecord backdated = await register(
        journal,
        scanOf('b.two'),
        at: DateTime(2026, 9, 4, 8, 20),
      );

      expect(
        journal.records.map((LateArrivalRecord r) => r.id),
        <String>[backdated.id, today.id],
      );
    });
  });

  group('roll-off', () {
    test('a fully drained day past retention is deleted', () async {
      const SchoolDay old = SchoolDay(2026, 6, 1);
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal back = await LateArrivalJournal.open(
        store,
        now: DateTime(2026, 6, 1, 8, 30),
      );
      final LateArrivalRecord record = await register(
        back,
        scanOf('a.one'),
        at: DateTime(2026, 6, 1, 8, 30),
      );
      await back.markSent(record.id);
      await back.markConfirmed(record.id);

      final LateArrivalJournal now =
          await LateArrivalJournal.open(store, now: monday);

      expect(now.recovery.rolledOff, <SchoolDay>[old]);
      expect(now.records, isEmpty);
      expect(await store.days(), isEmpty);
    });

    test('an old day that still owes Smartschool a write is never rolled off',
        () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal back = await LateArrivalJournal.open(
        store,
        now: DateTime(2026, 6, 1, 8, 30),
      );
      await register(back, scanOf('a.one'), at: DateTime(2026, 6, 1, 8, 30));

      final LateArrivalJournal now =
          await LateArrivalJournal.open(store, now: monday);

      expect(now.recovery.rolledOff, isEmpty);
      expect(now.pending, hasLength(1));
    });

    test('a drained day inside the window is kept', () async {
      final InMemoryJournalStore store = InMemoryJournalStore();
      final LateArrivalJournal back = await LateArrivalJournal.open(
        store,
        now: DateTime(2026, 9, 4, 8, 30),
      );
      final LateArrivalRecord record = await register(
        back,
        scanOf('a.one'),
        at: DateTime(2026, 9, 4, 8, 30),
      );
      await back.markSent(record.id);
      await back.markConfirmed(record.id);

      final LateArrivalJournal now =
          await LateArrivalJournal.open(store, now: monday);

      expect(now.recovery.rolledOff, isEmpty);
      expect(now.records, hasLength(1));
    });
  });
}

/// Lets the microtask and event queues drain, so "has this future completed
/// yet?" is a fair question.
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// An [InMemoryJournalStore] whose [append] can be held open, so a test can look
/// at the world *while* a write is in flight — which is the only way to prove
/// the journal does not announce a record before the disk has it.
class _GatedJournalStore implements JournalStore {
  final InMemoryJournalStore _inner = InMemoryJournalStore();

  /// When set, [append] waits on it before doing anything.
  Completer<void>? gate;

  @override
  Future<void> append(SchoolDay day, String line) async {
    final Completer<void>? held = gate;
    if (held != null) await held.future;
    await _inner.append(day, line);
  }

  @override
  Future<List<SchoolDay>> days() => _inner.days();

  @override
  Future<void> delete(SchoolDay day) => _inner.delete(day);

  @override
  Future<String> read(SchoolDay day) => _inner.read(day);

  @override
  String locationOf(SchoolDay day) => _inner.locationOf(day);
}
