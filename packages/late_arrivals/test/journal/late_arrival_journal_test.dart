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
