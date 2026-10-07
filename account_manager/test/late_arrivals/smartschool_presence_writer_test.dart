/// The adapter between the pure drain (#404) and `flutter_smartschool`.
///
/// The drain's whole retry policy is decided by *which* exception comes back
/// out of a failed presence write, so the mapping from the library's exception
/// types to the seam's three answers is the thing worth testing. Everything
/// here runs against a fake session, or the live one over a fake client
/// (#469): `setLate` is a write against a live school tenant, and the repo's
/// live-testing policy keeps write-capable verification out of CI and in the
/// operator's hands.
library;

import 'dart:io' show Directory, FileSystemException;

import 'package:account_manager/src/late_arrivals/operator_credentials.dart'
    show describeRefusedSmartschoolSignIn;
import 'package:account_manager/src/late_arrivals/smartschool_presence_writer.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;
import 'package:flutter_test/flutter_test.dart';
import 'package:late_arrivals/late_arrivals.dart';

import 'fake_presence_module.dart';
import 'fake_smartschool_client.dart';

class FakeSession implements SmartschoolPresenceSession {
  FakeSession({
    this.failure,
    Iterable<Object> failures = const <Object>[],
    this.signInFailure,
  }) : failures = List<Object>.of(failures);

  /// Thrown by every call, after [failures] ran out.
  final Object? failure;

  /// Thrown one per call, in order, before [failure] applies — a Smartschool
  /// that answers the next calls badly and then recovers (#461).
  final List<Object> failures;

  /// Thrown by every [signIn] — a login Smartschool refuses (#464). `null`
  /// signs in.
  final Object? signInFailure;

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
  Future<void> signIn() async {
    signIns++;
    final Object? error = signInFailure;
    if (error != null) throw error;
  }
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

/// The sentence the desk shows, and the text kept behind it — the split
/// `DeskWarning.fromText` makes (#463).
(String, String) linesOf(String text) {
  final int newline = text.indexOf('\n');
  return newline < 0
      ? (text, '')
      : (text.substring(0, newline), text.substring(newline + 1));
}

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
      // may or may not have landed and is safe to send again. Every kind, so
      // also the JSON with an error status of dartschool#143 (#468).
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
      const PresenceCredentialsRefused refused =
          PresenceCredentialsRefused('Het wachtwoord klopt niet.');
      expect(classifyPresenceFailure(refused), same(refused));
    });
  });

  group('the library\'s own reading of an answer, over a real client (#468)',
      () {
    // The tests above hand the writer the library's errors, built by hand.
    // These let the library build them: a real `SmartschoolClient` and the
    // real `PresenceService` read what the fake module answers, so a bump of
    // `flutter_smartschool` that changes which error an answer becomes shows
    // up here. dartschool#143 did: until 0.3.7 a JSON body with an error status
    // was read as the module's answer.

    /// The writer the desk builds for an operator, over a real client whose
    /// requests go to [module].
    SmartschoolPresenceWriter writerOver(FakePresenceModule module) {
      final Directory cache =
          Directory.systemTemp.createTempSync('am-presence-468-');
      addTearDown(() async {
        for (final ss.SmartschoolClient client in module.clients) {
          await client.dispose();
        }
        try {
          cache.deleteSync(recursive: true);
        } on FileSystemException {
          // A temp directory left behind is not worth failing a test over.
        }
      });
      return SmartschoolPresenceWriter(
        LiveSmartschoolPresenceSession(
          credentials: ss.AppCredentials(
            username: 'ann.peeters',
            password: 'zeergeheim',
            mainUrl: 'arcadia.smartschool.be',
          ),
          cacheDir: cache.path,
          createClient: module.createClient,
        ),
      );
    }

    /// The module of [write]'s class, with [write]'s pupil in it.
    FakePresenceModule moduleOfWrite() =>
        FakePresenceModule(classGroupId: 298, pupils: <int>[11110]);

    /// Writes once through [writer] and returns what it threw.
    Future<Object> failureOf(SmartschoolPresenceWriter writer) async {
      try {
        await write(writer);
      } on Object catch (error) {
        return error;
      }
      fail('the write went through');
    }

    test('the module\'s answers make a write go through', () async {
      // The fake itself: without this, the failures below could be the fake's.
      final FakePresenceModule module = moduleOfWrite();
      await write(writerOver(module));
      expect(module.saved, <int>[11110]);
      expect(module.requests, <String>[
        'POST ${FakePresenceModule.getConfigPath}',
        'POST ${FakePresenceModule.getAllCodesPath}',
        'POST ${FakePresenceModule.getClassPath}',
        'POST ${FakePresenceModule.savePath}',
      ]);
    });

    test(
        'a read answered with an error status and a JSON body is transient: '
        'the library\'s error comes back unchanged, and the next try reads '
        'the module afresh', () async {
      // The answer of the issue. Until dartschool#143, a `getConfig` answered
      // `500` with `{"message": ...}` gave a config without classes, which the
      // library cached; the save then failed as a class "not among the
      // classes this account may record presences for", a plain
      // `SmartschoolPresenceError`, and the drain gave the registration up at
      // once. `getAllCodes` and `getClass` are read the same way.
      for (final String path in <String>[
        FakePresenceModule.getConfigPath,
        FakePresenceModule.getAllCodesPath,
        FakePresenceModule.getClassPath,
      ]) {
        final FakePresenceModule module = moduleOfWrite()
          ..answerNext(path, FakePresenceModule.internalServerError);
        final SmartschoolPresenceWriter writer = writerOver(module);

        final Object error = await failureOf(writer);
        expect(
          error,
          isA<ss.SmartschoolPresenceUnreadableAnswerError>()
              .having((ss.SmartschoolPresenceUnreadableAnswerError e) => e.kind,
                  'kind', ss.PresenceUnreadableAnswerKind.errorStatus)
              .having(
                  (ss.SmartschoolPresenceUnreadableAnswerError e) =>
                      e.statusCode,
                  'statusCode',
                  500)
              .having((ss.SmartschoolPresenceUnreadableAnswerError e) => e.path,
                  'path', path),
          reason: path,
        );
        expect(classifyPresenceFailure(error), same(error), reason: path);
        expect(module.saved, isEmpty, reason: path);

        // The drain's next attempt: nothing of the error answer was kept.
        await write(writer);
        expect(module.saved, <int>[11110], reason: path);
        // Never signed in again: every request went to the Presence module.
        expect(module.requests, everyElement(startsWith('POST /Presence/')),
            reason: path);
      }
    });

    test(
        'a save answered with an error status and no errors of the module\'s '
        'is transient, not a confirmed save', () async {
      // Until dartschool#143 the library found no `errors[]` in such an
      // answer and returned as from a save that went through: the drain marked
      // the registration confirmed, and nobody knew whether it had landed.
      final FakePresenceModule module = moduleOfWrite()
        ..answerNext(
          FakePresenceModule.savePath,
          FakePresenceModule.internalServerError,
        );
      final SmartschoolPresenceWriter writer = writerOver(module);

      final Object error = await failureOf(writer);
      expect(
        error,
        isA<ss.SmartschoolPresenceUnreadableAnswerError>()
            .having((ss.SmartschoolPresenceUnreadableAnswerError e) => e.kind,
                'kind', ss.PresenceUnreadableAnswerKind.errorStatus)
            .having((ss.SmartschoolPresenceUnreadableAnswerError e) => e.path,
                'path', FakePresenceModule.savePath),
      );
      expect(classifyPresenceFailure(error), same(error));

      // Sent again, it goes through.
      await write(writer);
      expect(module.saved, <int>[11110]);
    });

    test(
        'a save the module refuses with its own errors under an error status '
        'is still a rejection, in the module\'s words', () async {
      // The one non-2xx JSON answer that stays a refusal after dartschool#143:
      // asking again gets the same `errors[]`, so the drain gives it up.
      final FakePresenceModule module = moduleOfWrite()
        ..answerNext(
          FakePresenceModule.savePath,
          FakePresenceModule.refusedSave('Geen schrijfrechten voor deze klas.'),
        );

      final Object error = await failureOf(writerOver(module));
      expect(
        error,
        isA<PresenceRejected>().having((PresenceRejected e) => e.message,
            'message', 'Geen schrijfrechten voor deze klas.'),
      );
      expect(module.saved, isEmpty);
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

  group('a retried failure in the operator\'s words (#463)', () {
    test(
        'an answer that could not be read is a Dutch sentence with its HTTP '
        'status, and the library\'s text on the line below', () {
      final (String sentence, String detail) =
          linesOf(describePresenceFailure(emptyGatewayAnswer));
      expect(
        sentence,
        'Smartschool gaf een antwoord dat niet gelezen kon worden (HTTP 502). '
        'Meestal is Smartschool dan even niet bereikbaar; probeer opnieuw '
        'zodra het weer werkt.',
      );
      // Kept, whole, for whoever has to diagnose it.
      expect(detail, '$emptyGatewayAnswer');
      expect(detail, contains('SmartschoolPresenceUnreadableAnswerError'));
    });

    test(
        'an HTML page and broken JSON get the same sentence, with or without a '
        'status', () {
      final ss.SmartschoolPresenceUnreadableAnswerError page =
          smartschoolErrorPage(path: '/Presence/Class/savePupilsPresences');
      final (String pageSentence, String pageDetail) =
          linesOf(describePresenceFailure(page));
      expect(
          pageSentence,
          startsWith('Smartschool gaf een antwoord dat niet '
              'gelezen kon worden (HTTP 500).'));
      expect(pageDetail, contains('Oeps, er ging iets mis'));
      expect(pageDetail, contains('/Presence/Class/savePupilsPresences'));

      const ss.SmartschoolPresenceUnreadableAnswerError unknown =
          ss.SmartschoolPresenceUnreadableAnswerError(
        'Broken JSON from /Presence/Class/getClass (status unknown).',
        path: '/Presence/Class/getClass',
        kind: ss.PresenceUnreadableAnswerKind.malformedJson,
      );
      final (String unknownSentence, _) =
          linesOf(describePresenceFailure(unknown));
      expect(
        unknownSentence,
        startsWith(
          'Smartschool gaf een antwoord dat niet gelezen kon worden. Meestal',
        ),
      );
    });

    test(
        'a JSON answer with an error status is a Dutch sentence of its own, '
        'with its HTTP status, and the library\'s text on the line below '
        '(#468)', () {
      // dartschool#143's kind. Smartschool did answer, readably; it answered
      // with an error, so the sentence says that rather than "niet gelezen".
      const ss.SmartschoolPresenceUnreadableAnswerError errorAnswer =
          ss.SmartschoolPresenceUnreadableAnswerError(
        'Error status from /Presence/Main/getConfig (HTTP 500): its JSON body '
        'is not read as an answer of the Presence module.',
        path: '/Presence/Main/getConfig',
        kind: ss.PresenceUnreadableAnswerKind.errorStatus,
        statusCode: 500,
      );
      final (String sentence, String detail) =
          linesOf(describePresenceFailure(errorAnswer));
      expect(
        sentence,
        'Smartschool antwoordde met een foutmelding (HTTP 500). Meestal is '
        'Smartschool dan even niet bereikbaar; probeer opnieuw zodra het weer '
        'werkt.',
      );
      expect(detail, '$errorAnswer');
      expect(
        describeUnreadablePresenceAnswer(
          ss.PresenceUnreadableAnswerKind.errorStatus,
          null,
        ),
        startsWith('Smartschool antwoordde met een foutmelding. Meestal'),
      );
    });

    test(
        'every kind the library has is worded in Dutch, with the same advice, '
        'and keeps the library\'s text below it', () {
      // A kind a later `flutter_smartschool` adds fails to compile in the
      // describer; this keeps each one's line free of the library's English.
      for (final ss.PresenceUnreadableAnswerKind kind
          in ss.PresenceUnreadableAnswerKind.values) {
        final ss.SmartschoolPresenceUnreadableAnswerError answer =
            ss.SmartschoolPresenceUnreadableAnswerError(
          'Unreadable answer from /Presence/Class/getClass (HTTP 503).',
          path: '/Presence/Class/getClass',
          kind: kind,
          statusCode: 503,
        );
        final (String sentence, String detail) =
            linesOf(describePresenceFailure(answer));
        expect(sentence, startsWith('Smartschool '), reason: '$kind');
        expect(sentence, contains('(HTTP 503).'), reason: '$kind');
        expect(
          sentence,
          endsWith('Meestal is Smartschool dan even niet bereikbaar; probeer '
              'opnieuw zodra het weer werkt.'),
          reason: '$kind',
        );
        expect(sentence, isNot(contains('Unreadable')), reason: '$kind');
        expect(sentence, isNot(contains('Error')), reason: '$kind');
        expect(detail, '$answer', reason: '$kind');
      }
    });

    test(
        'a Smartschool that could not be reached is a Dutch sentence, and the '
        'library\'s text on the line below', () {
      const ss.SmartschoolConnectionError unreachable =
          ss.SmartschoolConnectionError(
        'Unable to reach Smartschool at https://arcadia.smartschool.be: the '
        'connection failed (SocketException: Connection refused)',
      );
      final (String sentence, String detail) =
          linesOf(describePresenceFailure(unreachable));
      expect(
        sentence,
        'Smartschool was niet bereikbaar vanaf deze computer. Probeer opnieuw '
        'zodra de netwerkverbinding in orde is; lukt het dan nog niet, test de '
        'aanmelding bij Instellingen → Te laat.',
      );
      expect(detail, '$unreachable');
    });

    test('anything else keeps its own text, as before', () {
      for (final Object error in <Object>[
        const SocketException('Connection reset by peer'),
        StateError('SmartschoolClient was disposed'),
        const ss.SmartschoolAuthenticationError('Login expired'),
      ]) {
        expect(describePresenceFailure(error), '$error');
      }
    });

    test(
        'through the real drain over the real writer, the registration given '
        'up on carries the sentence after the same attempts', () async {
      final DateTime monday = DateTime(2026, 9, 7, 8, 14);
      final LateArrivalJournal journal =
          await LateArrivalJournal.open(InMemoryJournalStore(), now: monday);
      final LateArrivalRecord record = await journal.register(
        scan: const ScanRegisterable(jonas),
        scannedAt: monday,
        reasonLabel: 'Bus te laat',
        reasonIsValid: true,
      );
      final FakeSession session = FakeSession(failure: emptyGatewayAnswer);
      final List<Duration> waits = <Duration>[];
      final LateArrivalDrain drain = LateArrivalDrain(
        journal: journal,
        writer: SmartschoolPresenceWriter(session),
        maxAttempts: 3,
        clock: () => monday,
        sleep: (Duration d) async => waits.add(d),
        describeFailure: describePresenceFailure,
      );

      drain.start();
      await drain.settle();

      // Still retried with backoff, never signed in again: only the words
      // changed.
      expect(session.calls, 3);
      expect(
          waits, const <Duration>[Duration(seconds: 2), Duration(seconds: 4)]);
      expect(session.signIns, 0);
      final LateArrivalRecord failed = journal.byId(record.id)!;
      expect(failed.status, LateArrivalStatus.failed);
      final (String sentence, String detail) = linesOf(failed.error!);
      expect(sentence, startsWith('Smartschool gaf een antwoord'));
      expect(sentence,
          isNot(contains('SmartschoolPresenceUnreadableAnswerError')));
      expect(detail, '$emptyGatewayAnswer');
      await drain.close();
    });
  });

  group('a refused login in the operator\'s words (#464)', () {
    const String fixIt = 'Pas de aanmelding aan bij Instellingen → Te laat, '
        'test ze met Aanmelding testen en probeer daarna opnieuw.';

    /// Every login refusal the library types, and the cause the operator's
    /// sentence has to name.
    const List<(ss.SmartschoolAuthenticationError, String)> refusals =
        <(ss.SmartschoolAuthenticationError, String)>[
      (
        ss.SmartschoolInvalidCredentialsError(),
        'Smartschool aanvaardde de gebruikersnaam of het wachtwoord niet.',
      ),
      (
        ss.SmartschoolTwoFactorRequiredError(),
        'Smartschool vraagt voor dit account een tweestapsverificatie, maar '
            'bij de aanmelding staat geen geheime sleutel van de '
            'authenticator (MFA).',
      ),
      (
        ss.SmartschoolTwoFactorRejectedError(),
        'Smartschool aanvaardde de code van de tweestapsverificatie niet. '
            'Kijk de geheime sleutel van de authenticator (MFA) na, en of de '
            'klok van deze computer juist staat.',
      ),
      (
        ss.SmartschoolInvalidTotpSecretError(),
        'De geheime sleutel van de authenticator (MFA) is geen geldige '
            'sleutel: vul de tekenreeks in die Smartschool toont bij het '
            'instellen van de authenticator, niet de code van zes cijfers uit '
            'de app.',
      ),
      (
        ss.SmartschoolUnsupportedTwoFactorMethodError(<String>['sms']),
        'Dit account gebruikt een tweestapsverificatie die het programma niet '
            'kan invullen: alleen een authenticator-app (zoals Google '
            'Authenticator) wordt ondersteund.',
      ),
      (
        ss.SmartschoolAccountVerificationRequiredError(),
        'Smartschool vraagt voor dit account een accountverificatie met de '
            'geboortedatum, maar in het MFA-veld van de aanmelding staat geen '
            'datum (jjjj-mm-dd).',
      ),
      (
        ss.SmartschoolAccountVerificationRejectedError(),
        'Smartschool aanvaardde de geboortedatum van de accountverificatie '
            'niet. Kijk de datum in het MFA-veld na (jjjj-mm-dd).',
      ),
    ];

    test(
        'each refusal names its cause in Dutch and where to fix it, with the '
        'library\'s text on the line below', () {
      for (final (ss.SmartschoolAuthenticationError error, String cause)
          in refusals) {
        final String type = '${error.runtimeType}';
        expect(describeRefusedSmartschoolSignIn(error), cause, reason: type);
        final (String sentence, String detail) =
            linesOf(describePresenceFailure(error));
        expect(sentence, '$cause $fixIt', reason: type);
        // No Dart type name and none of the library's English on the line
        // the operator reads — all of it on the line below.
        expect(sentence, isNot(contains(type)));
        expect(sentence, isNot(contains(error.message)));
        expect(detail, '$error', reason: type);
        expect(detail, startsWith('$type: '));
      }
    });

    test(
        'a session Smartschool no longer accepts is not a refused login, nor '
        'is anything else: those keep their own text', () {
      for (final Object error in <Object>[
        const ss.SmartschoolSessionExpiredError(),
        const ss.SmartschoolAuthenticationError('Login expired'),
        const ss.SmartschoolConnectionError('Unable to reach Smartschool'),
        StateError('SmartschoolClient was disposed'),
      ]) {
        expect(describeRefusedSmartschoolSignIn(error), isNull,
            reason: '$error');
      }
      expect(
        describePresenceFailure(const ss.SmartschoolSessionExpiredError()),
        '${const ss.SmartschoolSessionExpiredError()}',
      );
    });

    test(
        'a refused login on a write tells the drain to stand down, not to sign '
        'in again, and it carries the operator\'s words (#466)', () async {
      for (final (ss.SmartschoolAuthenticationError error, _) in refusals) {
        final FakeSession session = FakeSession(failure: error);
        await expectLater(
          write(SmartschoolPresenceWriter(session)),
          throwsA(
            isA<PresenceCredentialsRefused>().having(
              (PresenceCredentialsRefused e) => e.message,
              'message',
              describePresenceFailure(error),
            ),
          ),
          reason: '${error.runtimeType}',
        );
        expect(session.signIns, 0, reason: '${error.runtimeType}');
      }
    });

    test(
        'a refused fresh sign-in tells the drain the same, in the same words '
        '(#466)', () async {
      for (final (ss.SmartschoolAuthenticationError error, _) in refusals) {
        final FakeSession session = FakeSession(signInFailure: error);
        await expectLater(
          SmartschoolPresenceWriter(session).reauthenticate(),
          throwsA(
            isA<PresenceCredentialsRefused>().having(
              (PresenceCredentialsRefused e) => e.message,
              'message',
              describePresenceFailure(error),
            ),
          ),
          reason: '${error.runtimeType}',
        );
        expect(session.signIns, 1, reason: '${error.runtimeType}');
      }
    });

    test(
        'any other sign-in failure is passed on as the library threw it, for '
        'the drain to retry', () async {
      for (final Object error in <Object>[
        const ss.SmartschoolConnectionError('Unable to reach Smartschool'),
        const ss.SmartschoolSessionExpiredError(),
        const ss.SmartschoolAuthenticationError('Unable to validate session'),
        StateError('SmartschoolClient was disposed'),
      ]) {
        await expectLater(
          SmartschoolPresenceWriter(FakeSession(signInFailure: error))
              .reauthenticate(),
          throwsA(same(error)),
          reason: '$error',
        );
      }
    });

    test('a session Smartschool no longer accepts keeps the library\'s message',
        () async {
      await expectLater(
        write(
          SmartschoolPresenceWriter(
            FakeSession(failure: const ss.SmartschoolSessionExpiredError()),
          ),
        ),
        throwsA(
          isA<PresenceSessionExpired>().having(
            (PresenceSessionExpired e) => e.message,
            'message',
            'Smartschool did not accept the session.',
          ),
        ),
      );
    });

    group('through the real drain over the real writer (#466)', () {
      final DateTime monday = DateTime(2026, 9, 7, 8, 14);

      /// A journal with the real drain behind its sink, over the real writer
      /// on [session] — the way the desk wires it, so a new scan wakes the
      /// drain exactly as it does in the app. The drain's own defaults: five
      /// attempts, two fresh sign-ins.
      Future<(LateArrivalJournal, LateArrivalDrain)> wired(
        FakeSession session, {
        required List<Duration> waits,
      }) async {
        final _DrainSink sink = _DrainSink();
        final LateArrivalJournal journal = await LateArrivalJournal.open(
          InMemoryJournalStore(),
          now: monday,
          sink: sink,
        );
        final LateArrivalDrain drain = LateArrivalDrain(
          journal: journal,
          writer: SmartschoolPresenceWriter(session),
          clock: () => monday,
          sleep: (Duration d) async => waits.add(d),
          describeFailure: describePresenceFailure,
        );
        sink.drain = drain;
        return (journal, drain);
      }

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

      test(
          'a changed password: one login, then the drain stands down with the '
          'registration still queued, and the next scan does not log in again',
          () async {
        // What the live session does once the password changed: every write
        // makes the client log in, and Smartschool refuses it; so would every
        // fresh sign-in. Until #466 that was five writes and two fresh
        // sign-ins — seven refused logins — and the registration given up on.
        const ss.SmartschoolInvalidCredentialsError refused =
            ss.SmartschoolInvalidCredentialsError();
        final FakeSession session =
            FakeSession(failure: refused, signInFailure: refused);
        final List<Duration> waits = <Duration>[];
        final (LateArrivalJournal journal, LateArrivalDrain drain) =
            await wired(session, waits: waits);
        drain.start();

        final LateArrivalRecord jonasRecord = await register(journal, jonas);
        await drain.settle();

        expect(session.calls, 1);
        expect(session.signIns, 0);
        expect(waits, isEmpty);
        expect(journal.byId(jonasRecord.id)!.status, LateArrivalStatus.pending);
        expect(journal.failures, isEmpty);
        expect(drain.status.degraded, isTrue);
        expect(drain.status.credentialsRefused, isTrue);

        // What the desk shows while it waits: the cause, where to fix it, and
        // the library's own text on the line below.
        final (String sentence, String detail) =
            linesOf(drain.status.lastError!);
        expect(
          sentence,
          'Smartschool aanvaardde de gebruikersnaam of het wachtwoord niet. '
          '$fixIt',
        );
        expect(detail, '$refused');

        // Lea is late too. Her registration waits with Jonas's; nobody logs
        // in with the refused password for her.
        final LateArrivalRecord leaRecord = await register(journal, lea);
        await drain.settle();
        expect(session.calls, 1);
        expect(session.signIns, 0);
        expect(journal.byId(leaRecord.id)!.status, LateArrivalStatus.pending);
        expect(drain.status.outstanding, 2);
        await drain.close();
      });

      test(
          'a fresh sign-in refused on the second factor: one sign-in, then the '
          'drain stands down, naming the second factor', () async {
        // A session Smartschool stopped accepting, and a login whose second
        // factor it then rejects. A second fresh sign-in would send the same
        // secret.
        const ss.SmartschoolTwoFactorRejectedError rejected =
            ss.SmartschoolTwoFactorRejectedError();
        final FakeSession session = FakeSession(
          failure: const ss.SmartschoolSessionExpiredError(),
          signInFailure: rejected,
        );
        final List<Duration> waits = <Duration>[];
        final (LateArrivalJournal journal, LateArrivalDrain drain) =
            await wired(session, waits: waits);
        drain.start();

        final LateArrivalRecord record = await register(journal, jonas);
        await drain.settle();

        expect(session.calls, 1);
        expect(session.signIns, 1);
        expect(waits, isEmpty);
        expect(journal.byId(record.id)!.status, LateArrivalStatus.pending);
        expect(journal.failures, isEmpty);
        expect(drain.status.credentialsRefused, isTrue);
        final (String sentence, String detail) =
            linesOf(drain.status.lastError!);
        expect(
          sentence,
          'Smartschool aanvaardde de code van de tweestapsverificatie niet. '
          'Kijk de geheime sleutel van de authenticator (MFA) na, en of de '
          'klok van deze computer juist staat. $fixIt',
        );
        expect(detail, '$rejected');
        await drain.close();
      });

      test(
          'a session Smartschool no longer accepts is still signed in again, '
          'and the write goes through', () async {
        // The other authentication error: the remedy is a fresh sign-in, and
        // nothing about #466 changes that.
        final FakeSession session = FakeSession(
          failures: <Object>[const ss.SmartschoolSessionExpiredError()],
        );
        final (LateArrivalJournal journal, LateArrivalDrain drain) =
            await wired(session, waits: <Duration>[]);
        drain.start();

        final LateArrivalRecord record = await register(journal, jonas);
        await drain.settle();

        expect(session.calls, 2);
        expect(session.signIns, 1);
        expect(
          journal.byId(record.id)!.status,
          LateArrivalStatus.confirmed,
        );
        expect(drain.status.credentialsRefused, isFalse);
        await drain.close();
      });
    });
  });

  group('re-authentication', () {
    test('is delegated to the session', () async {
      final FakeSession session = FakeSession();
      await SmartschoolPresenceWriter(session).reauthenticate();
      expect(session.signIns, 1);
    });

    /// The live session itself, over clients a test makes (#469): a fresh
    /// sign-in that fails must close the client it made for it, and pass the
    /// error on as the library threw it.
    group('on the live session', () {
      /// A session whose clients come from [clients], in order, and the list
      /// of the ones it has asked for so far.
      (LiveSmartschoolPresenceSession, List<FakeClient>) liveSession(
        List<FakeClient> clients,
      ) {
        final List<FakeClient> made = <FakeClient>[];
        final LiveSmartschoolPresenceSession session =
            LiveSmartschoolPresenceSession(
          credentials: ss.AppCredentials(
            username: 'onthaal',
            password: 'geheim',
            mainUrl: 'school.smartschool.be',
          ),
          createClient: (ss.Credentials credentials, {String? cacheDir}) async {
            final FakeClient client = clients.removeAt(0);
            made.add(client);
            return client;
          },
        );
        return (session, made);
      }

      test(
          'a sign-in Smartschool cannot be reached for closes the client it '
          'made, and passes the error on unchanged', () async {
        const ss.SmartschoolConnectionError unreachable =
            ss.SmartschoolConnectionError('Unable to reach Smartschool');
        final (LiveSmartschoolPresenceSession session, List<FakeClient> made) =
            liveSession(<FakeClient>[FakeClient(signInFailure: unreachable)]);

        await expectLater(session.signIn(), throwsA(same(unreachable)));

        expect(made, hasLength(1));
        expect(made.single.signIns, 1);
        expect(made.single.disposals, 1);
      });

      test(
          'a sign-in Smartschool refuses closes the client it made, and the '
          'writer still stands the drain down over it', () async {
        final (LiveSmartschoolPresenceSession session, List<FakeClient> made) =
            liveSession(<FakeClient>[
          FakeClient(
            signInFailure: const ss.SmartschoolInvalidCredentialsError(),
          ),
        ]);

        await expectLater(
          SmartschoolPresenceWriter(session).reauthenticate(),
          throwsA(isA<PresenceCredentialsRefused>()),
        );

        expect(made.single.disposals, 1);
      });

      test(
          'the next write after a failed sign-in makes a client of its own '
          'instead of using the closed one', () async {
        final (LiveSmartschoolPresenceSession session, List<FakeClient> made) =
            liveSession(<FakeClient>[
          FakeClient(
            signInFailure: const ss.SmartschoolConnectionError('offline'),
          ),
          FakeClient(),
        ]);
        await expectLater(
          session.signIn(),
          throwsA(isA<ss.SmartschoolConnectionError>()),
        );

        // The fake answers no request, so the write fails on its first one;
        // what matters is which client it went to.
        await expectLater(
          session.setLate(
            userId: 11110,
            classGroupId: 298,
            date: DateTime(2026, 9, 7),
            part: ss.DayPart.morning,
            withoutValidReason: false,
            motivation: '08:14 – Bus te laat',
          ),
          throwsA(isA<UnimplementedError>()),
        );

        expect(made, hasLength(2));
        expect(made.last.requests, 1);
        expect(made.last.disposals, 0);
        expect(made.first.requests, 0);
      });

      test(
          'a sign-in that succeeds keeps its client open until the next '
          'sign-in replaces it', () async {
        final (LiveSmartschoolPresenceSession session, List<FakeClient> made) =
            liveSession(<FakeClient>[FakeClient(), FakeClient()]);

        await session.signIn();
        expect(made.single.disposals, 0);

        await session.signIn();
        expect(made, hasLength(2));
        expect(made.first.cookieClears, 1);
        expect(made.first.disposals, 1);
        expect(made.last.disposals, 0);
      });
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

/// The journal's sink, pointed at the drain once it exists: the drain needs
/// the journal, and the journal wants the drain.
class _DrainSink implements LateArrivalRecordSink {
  LateArrivalDrain? drain;

  @override
  void onRecord(LateArrivalRecord record) => drain?.onRecord(record);
}
