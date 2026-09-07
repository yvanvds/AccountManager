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
  bool? lastWithoutValidReason;
  String? lastMotivation;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  }) async {
    calls++;
    lastDate = date;
    lastWithoutValidReason = withoutValidReason;
    lastMotivation = motivation;
    final Object? error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> signIn() async => signIns++;
}

Future<void> write(SmartschoolPresenceWriter writer) => writer.setLate(
      userId: 11110,
      classGroupId: 298,
      date: DateTime(2026, 9, 7),
      withoutValidReason: false,
      motivation: '08:14 – Bus te laat',
    );

void main() {
  group('a successful write', () {
    test('passes the drain\'s arguments straight through', () async {
      final FakeSession session = FakeSession();
      await write(SmartschoolPresenceWriter(session));

      expect(session.calls, 1);
      expect(session.lastDate, DateTime(2026, 9, 7));
      expect(session.lastWithoutValidReason, isFalse);
      expect(session.lastMotivation, '08:14 – Bus te laat');
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

    test('an HTML response reads as an expired session', () async {
      // Exactly what `PresenceService._decode` raises when Smartschool serves
      // the login page instead of JSON.
      final FakeSession session = FakeSession(
        failure: const ss.SmartschoolPresenceError(
          'Received HTML instead of JSON from /Presence/Main/getConfig. The '
          'session may have expired, or the account lacks Presence access.',
        ),
      );
      await expectLater(
        write(SmartschoolPresenceWriter(session)),
        throwsA(isA<PresenceSessionExpired>()),
      );
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
