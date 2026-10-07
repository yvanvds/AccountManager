/// The adapter between the pure drain (#404) and `flutter_smartschool`.
///
/// The drain's whole retry policy is decided by *which* exception comes back
/// out of a failed presence write, so the mapping from the library's exception
/// types to the seam's three answers is the thing worth testing. Everything
/// here runs against a fake session: `setLate` is a write against a live school
/// tenant, and the repo's live-testing policy keeps write-capable verification
/// out of CI and in the operator's hands.
library;

import 'package:account_manager/src/late_arrivals/smartschool_presence_writer.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

class FakeSession implements SmartschoolPresenceSession {
  FakeSession({this.failure, Iterable<Object> failures = const <Object>[]})
      : failures = List<Object>.of(failures);

  /// Thrown by every call, after [failures] ran out.
  final Object? failure;

  /// Thrown one per call, in order, before [failure] applies — a Smartschool
  /// that answers the next calls badly and then recovers (#461).
  final List<Object> failures;

  int calls = 0;
  int signIns = 0;
  DateTime? lastDate;
  ss.DayPart? lastPart;
  bool? lastWithoutValidReason;
  String? lastMotivation;
  Set<String>? lastOnlyReplacing;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required ss.DayPart part,
    required bool withoutValidReason,
    required String motivation,
    Set<String>? onlyReplacing,
  }) async {
    calls++;
    lastDate = date;
    lastPart = part;
    lastWithoutValidReason = withoutValidReason;
    lastMotivation = motivation;
    lastOnlyReplacing = onlyReplacing;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    final Object? error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> signIn() async => signIns++;
}

Future<void> write(
  SmartschoolPresenceWriter writer, {
  HalfDay part = HalfDay.morning,
  bool keepRecordedAbsence = false,
}) =>
    writer.setLate(
      userId: 11110,
      classGroupId: 298,
      date: DateTime(2026, 9, 7),
      part: part,
      withoutValidReason: false,
      motivation: '08:14 – Bus te laat',
      keepRecordedAbsence: keepRecordedAbsence,
    );

/// Two students of one class, as the scan resolver hands them to the journal.
const ScannedStudent jonas = ScannedStudent(
  scanCode: '123456',
  wisaId: '123456',
  smartschoolUid: 'jonas.peeters',
  displayName: 'Jonas Peeters',
  className: '3MTa',
  internalUserId: 4242,
  classGroupId: 77,
);
const ScannedStudent lea = ScannedStudent(
  scanCode: '223344',
  wisaId: '223344',
  smartschoolUid: 'lea.janssens',
  displayName: 'Lea Janssens',
  className: '3MTa',
  internalUserId: 4243,
  classGroupId: 77,
);

/// What `PresenceService` throws since dartschool#137 when a proxy answers the
/// first read of a write with an empty `502`.
const ss.SmartschoolPresenceUnreadableAnswerError emptyGatewayAnswer =
    ss.SmartschoolPresenceUnreadableAnswerError(
  'Empty response from /Presence/Main/getConfig (HTTP 502).',
  path: '/Presence/Main/getConfig',
  kind: ss.PresenceUnreadableAnswerKind.empty,
  statusCode: 502,
);

/// Smartschool's generic error page where JSON belongs, read the way the
/// library reads it (dartschool#137).
ss.SmartschoolPresenceUnreadableAnswerError smartschoolErrorPage({
  String path = '/Presence/Main/getConfig',
  int statusCode = 500,
}) =>
    ss.SmartschoolPresenceUnreadableAnswerError.fromPage(
      '<!DOCTYPE html><html><head><title>Smartschool</title></head>'
      '<body><h1>Oeps, er ging iets mis</h1></body></html>',
      path: path,
      statusCode: statusCode,
    );

void main() {
  group('a successful write', () {
    test('passes the drain\'s arguments straight through', () async {
      final FakeSession session = FakeSession();
      await write(SmartschoolPresenceWriter(session));

      expect(session.calls, 1);
      expect(session.lastDate, DateTime(2026, 9, 7));
      expect(session.lastPart, ss.DayPart.morning);
      expect(session.lastWithoutValidReason, isFalse);
      expect(session.lastMotivation, '08:14 – Bus te laat');
    });

    test('an afternoon scan is written to the afternoon cell (#428)', () async {
      final FakeSession session = FakeSession();
      await write(SmartschoolPresenceWriter(session), part: HalfDay.afternoon);
      expect(session.lastPart, ss.DayPart.afternoon);
    });

    test(
        'a first send overwrites whatever the half-day holds, as it always did',
        () async {
      final FakeSession session = FakeSession();
      await write(SmartschoolPresenceWriter(session));
      expect(session.lastOnlyReplacing, isNull);
    });

    test(
        'a requeued send may only replace nothing, a presence or a late '
        'arrival (#460)', () async {
      // Opnieuw proberen can come hours after the scan; an absence the
      // secretariat recorded since must not be wiped by it.
      final FakeSession session = FakeSession();
      await write(SmartschoolPresenceWriter(session),
          keepRecordedAbsence: true);
      expect(session.lastOnlyReplacing, <String>{
        ss.PresenceService.nothingRecorded,
        ss.PresenceService.presentCodeName,
        ss.PresenceService.lateCodeName,
        ss.PresenceService.lateWithoutReasonAliasName,
      });
    });

    test('maps every half-day onto the library\'s own value', () {
      expect(dayPartOf(HalfDay.morning), ss.DayPart.morning);
      expect(dayPartOf(HalfDay.afternoon), ss.DayPart.afternoon);
      // The wire tokens Smartschool actually reads.
      expect(dayPartOf(HalfDay.morning).wire, 'am');
      expect(dayPartOf(HalfDay.afternoon).wire, 'pm');
    });
  });

  group('classifying a failure', () {
    test('an authentication error means sign in again, not give up', () async {
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolAuthenticationError('Login expired'),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(isA<PresenceSessionExpired>()),
      );
    });

    test(
        'a session Smartschool no longer accepts reads as an expired session '
        '(dartschool#5)', () async {
      // What the Presence module raises since 0.3.0 when a request is answered
      // by the login chain — typed, where 0.2.10 had one HTML sentence for two
      // causes that this adapter had to read.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolSessionExpiredError(),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(isA<PresenceSessionExpired>()),
      );
    });

    test(
        'an HTML page that is not the login chain is neither an expiry nor a '
        'rejection: it is retried (#461)', () async {
      // The other half of dartschool#5: Smartschool's generic error page, with
      // the session accepted, so signing in again would not help. Until #461
      // this was a rejection, and a desk gave every registration of a
      // Smartschool hiccup up at once. It is an answer that could not be read
      // (dartschool#137), and the drain's attempts bound how often it is
      // asked again.
      final ss.SmartschoolPresenceUnreadableAnswerError page =
          smartschoolErrorPage();
      expect(page.kind, ss.PresenceUnreadableAnswerKind.html);
      expect(page.heading, 'Oeps, er ging iets mis');

      final FakeSession session = FakeSession(failure: page);
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          allOf(
            same(page),
            isNot(isA<PresenceRejected>()),
            isNot(isA<PresenceSessionExpired>()),
          ),
        ),
      );
      expect(session.signIns, 0);
    });

    test(
        'an empty answer from a gateway is transient: returned unchanged, no '
        're-authentication spent on it (#461)', () async {
      // The answer of the issue: a proxy in front of Smartschool says 502 and
      // nothing else. The session is fine; the module never saw the request.
      final FakeSession session = FakeSession(failure: emptyGatewayAnswer);
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          allOf(
            same(emptyGatewayAnswer),
            isNot(isA<PresenceRejected>()),
            isNot(isA<PresenceSessionExpired>()),
          ),
        ),
      );
      expect(session.signIns, 0);
    });

    test(
        'every unreadable answer is transient, whatever its kind, status or '
        'endpoint — the save included (#461)', () {
      // Classified on the type alone, never on the message or the status: a
      // `200` HTML page as much as a `504`, and an answer to the save, which
      // may or may not have landed and is safe to send again.
      const List<String> paths = <String>[
        '/Presence/Main/getConfig',
        '/Presence/Code/getAllCodes',
        '/Presence/Class/getClass',
        '/Presence/Class/savePupilsPresences',
      ];
      for (final String path in paths) {
        for (final int status in <int>[200, 408, 429, 500, 502, 503, 504]) {
          for (final ss.PresenceUnreadableAnswerKind kind
              in ss.PresenceUnreadableAnswerKind.values) {
            final ss.SmartschoolPresenceUnreadableAnswerError answer =
                ss.SmartschoolPresenceUnreadableAnswerError(
              'Unreadable answer from $path (HTTP $status).',
              path: path,
              kind: kind,
              statusCode: status,
            );
            expect(
              classifyPresenceFailure(answer),
              same(answer),
              reason: '$kind, HTTP $status, $path',
            );
          }
        }
      }
      // A status that is not known, too.
      const ss.SmartschoolPresenceUnreadableAnswerError unknown =
          ss.SmartschoolPresenceUnreadableAnswerError(
        'Empty response from /Presence/Class/getClass (status unknown).',
        path: '/Presence/Class/getClass',
        kind: ss.PresenceUnreadableAnswerKind.empty,
      );
      expect(classifyPresenceFailure(unknown), same(unknown));
    });

    test(
        'a Smartschool that cannot be reached is transient: returned unchanged, '
        'no re-authentication spent on it (#455)', () async {
      // What `ensureAuthenticated()` and every service call throw since
      // dartschool#21 for a host that does not resolve, a dropped connection or
      // a failed TLS handshake. On 0.2.10 this arrived as an authentication
      // error and the drain burned its capped sign-ins on a network problem.
      const ss.SmartschoolConnectionError unreachable =
          ss.SmartschoolConnectionError(
        'Unable to reach Smartschool at arcadia.smartschool.be: the connection '
        'failed (HandshakeException: Handshake error in client (OS Error: '
        'CERTIFICATE_VERIFY_FAILED: unable to get local issuer '
        'certificate(handshake.cc:393)))',
      );
      expect(classifyPresenceFailure(unreachable), same(unreachable));

      final FakeSession session = FakeSession(failure: unreachable);
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          allOf(
            same(unreachable),
            isNot(isA<PresenceSessionExpired>()),
            isNot(isA<PresenceRejected>()),
          ),
        ),
      );
      expect(session.signIns, 0);
    });

    test('the typed preconditions the module checks are rejections too',
        () async {
      // 0.3.x subtypes of `SmartschoolPresenceError`, raised before anything
      // is sent; a fresh login changes nothing about them.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresencePupilNotFoundError(
          'Pupil userID 11110 was not found in class groupID 298 on 2026-09-07.',
          userId: 11110,
          classGroupId: 298,
          date: '2026-09-07',
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            contains('was not found in class groupID 298'),
          ),
        ),
      );
    });

    test(
        'a class the account may not confirm for is a rejection, not an '
        'unreadable answer (#461)', () async {
      // A typed precondition: the module's config said no before anything was
      // sent. Asking again gets the same answer, so it stays terminal, unlike
      // the unreadable answers next to it.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceNoConfirmRightError(
          'The account may not confirm the half-days of class 3MTa '
          '(groupID 298): nothing was sent.',
          userId: 11110,
          classGroupId: 298,
          date: '2026-09-07',
          part: ss.DayPart.morning,
          classRef: ss.PresenceClassRef(
            groupId: 298,
            name: '3MTa',
            userCanRecord: true,
          ),
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            contains('may not confirm'),
          ),
        ),
      );
      expect(session.signIns, 0);
    });

    test(
        'a requeued write the half-day refuses is terminal, in the operator\'s '
        'own words (#460)', () async {
      // What the library throws when the guard a requeued write carries finds
      // an absence recorded since the scan. Nothing was sent; the operator has
      // to look at it, so the line says what is there and what to do.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceChangeRefusedError(
          'The morning of 2026-09-07 of pupil userID 11110 in class groupID '
          '298 holds "Ziek", which onlyReplacing does not allow: nothing was '
          'sent.',
          userId: 11110,
          part: ss.DayPart.morning,
          date: '2026-09-07',
          heldStatus: 'Ziek',
          onlyReplacing: requeuedWriteMayReplace,
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session), keepRecordedAbsence: true),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            allOf(
              contains('voormiddag van 2026-09-07'),
              contains('"Ziek"'),
              contains('niet overschreven'),
              contains('manueel ingevoerd'),
              isNot(contains('onlyReplacing')),
            ),
          ),
        ),
      );
      expect(session.signIns, 0);
    });

    test('a rejected save is terminal and keeps the server\'s words', () async {
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceError(
          'Saving the presence for userID 11110 failed.',
          errors: <String>['Geen schrijfrechten voor deze klas.'],
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            'Geen schrijfrechten voor deze klas.',
          ),
        ),
      );
    });

    test('a precondition failure is terminal with its own message', () async {
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceError(
          'Pupil userID 11110 was not found in class groupID 298 on 2026-09-07.',
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            contains('was not found in class groupID 298'),
          ),
        ),
      );
    });

    test('a transport failure stays transient so the drain retries it',
        () async {
      final FakeSession session = FakeSession(
        failure: const SocketException('Connection reset by peer'),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          allOf(
            isA<SocketException>(),
            isNot(isA<PresenceRejected>()),
            isNot(isA<PresenceSessionExpired>()),
          ),
        ),
      );
    });

    test('a non-200 download error stays transient', () {
      expect(
        classifyPresenceFailure(
          ss.SmartschoolDownloadError('Bad gateway', 502),
        ),
        isA<ss.SmartschoolDownloadError>(),
      );
    });

    test('an already-classified failure is passed through unchanged', () {
      const PresenceRejected rejected = PresenceRejected('nee');
      expect(classifyPresenceFailure(rejected), same(rejected));
    });
  });

  group('an unreadable answer, through the drain (#461)', () {
    // The real drain over the real writer, with only the session faked: the
    // classification above is a contract with the drain, and this is the
    // drain keeping its half of it.
    final DateTime monday = DateTime(2026, 9, 7, 8, 14);

    Future<LateArrivalRecord> register(
      LateArrivalJournal journal,
      ScannedStudent student,
    ) =>
        journal.register(
          scan: ScanRegisterable(student),
          scannedAt: monday,
          reasonLabel: 'Bus te laat',
          reasonIsValid: true,
        );

    LateArrivalDrain drainOver(
      LateArrivalJournal journal,
      FakeSession session, {
      required List<Duration> waits,
      int maxAttempts = 5,
    }) =>
        LateArrivalDrain(
          journal: journal,
          writer: SmartschoolPresenceWriter(session),
          maxAttempts: maxAttempts,
          clock: () => monday,
          sleep: (Duration d) async => waits.add(d),
        );

    test('is retried after a backoff, and the registration is confirmed',
        () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord record = await register(journal, jonas);
      // A gateway that answers nothing, then Smartschool's error page, then a
      // Smartschool that is back.
      final FakeSession session = FakeSession(
        failures: <Object>[emptyGatewayAnswer, smartschoolErrorPage()],
      );
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain = drainOver(journal, session, waits: waits);

      drain.start();
      await drain.settle();

      expect(session.calls, 3);
      expect(journal.byId(record.id)!.status, LateArrivalStatus.confirmed);
      expect(journal.byId(record.id)!.error, isNull);
      // Backed off, as for a dropped connection; never signed in again.
      expect(waits, <Duration>[
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(session.signIns, 0);
      expect(drain.status.isHealthy, isTrue);
      await drain.close();
    });

    test(
        'that keeps coming back stands the drain down after its attempts, and '
        'keeps the rest of the queue on disk', () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord first = await register(journal, jonas);
      final LateArrivalRecord second = await register(journal, lea);
      final FakeSession session = FakeSession(failure: emptyGatewayAnswer);
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain =
          drainOver(journal, session, waits: waits, maxAttempts: 3);

      drain.start();
      await drain.settle();

      // The first record spent its attempts and is mislukt, with the answer
      // that could not be read on it; Lea's was never sent.
      expect(session.calls, 3);
      expect(journal.byId(first.id)!.status, LateArrivalStatus.failed);
      expect(
        journal.byId(first.id)!.error,
        allOf(contains('/Presence/Main/getConfig'), contains('HTTP 502')),
      );
      expect(journal.byId(second.id)!.status, LateArrivalStatus.pending);
      expect(drain.status.degraded, isTrue);
      expect(drain.status.outstanding, 1);
      expect(session.signIns, 0);
      await drain.close();
    });

    test(
        'next to it, a save the module refused is still given up at once, and '
        'the queue goes on', () async {
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord first = await register(journal, jonas);
      final LateArrivalRecord second = await register(journal, lea);
      final FakeSession session = FakeSession(
        failures: <Object>[
          const ss.SmartschoolPresenceError(
            'Saving the presence for userID 4242 failed.',
            errors: <String>['Geen schrijfrechten voor deze klas.'],
          ),
        ],
      );
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain = drainOver(journal, session, waits: waits);

      drain.start();
      await drain.settle();

      expect(session.calls, 2);
      expect(journal.byId(first.id)!.status, LateArrivalStatus.failed);
      expect(
          journal.byId(first.id)!.error, 'Geen schrijfrechten voor deze klas.');
      expect(journal.byId(second.id)!.status, LateArrivalStatus.confirmed);
      expect(waits, isEmpty);
      expect(drain.status.degraded, isFalse);
      await drain.close();
    });
  });

  group('re-authentication', () {
    test('is delegated to the session', () async {
      final FakeSession session = FakeSession();
      await SmartschoolPresenceWriter(session).reauthenticate();
      expect(session.signIns, 1);
    });
  });
}

/// A stand-in for `dart:io`'s, so the test does not need the real socket layer
/// to describe a dropped connection.
class SocketException implements Exception {
  const SocketException(this.message);

  final String message;

  @override
  String toString() => 'SocketException: $message';
}
