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
  FakeSession({this.failure});

  final Object? failure;
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
        'an HTML page that is not the login chain is a rejection, not an '
        'expiry', () async {
      // The other half of dartschool#5: Smartschool's generic error page on a
      // request the module could not handle, with the session accepted. The
      // message no longer suggests expiry, and signing in again would not help.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceError(
          'The Presence module answered /Presence/Main/getConfig with an HTML '
          'page (HTTP 500) instead of JSON: it could not handle the request '
          '(the request is invalid, or the account may lack Presence access).',
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(
          isA<PresenceRejected>().having(
            (PresenceRejected e) => e.message,
            'message',
            contains('HTTP 500'),
          ),
        ),
      );
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
