/// The one thing the drain (#404) does to the outside world: write a
/// Smartschool presence.
///
/// A seam rather than a direct call into `flutter_smartschool` for two reasons.
/// The obvious one is that `packages/late_arrivals/` is pure Dart with no
/// network of its own, exactly like the journal's `JournalStore` and the
/// mirror's store. The load-bearing one is that the write is a *write*, against
/// a live school tenant: the repo's live-testing policy forbids exercising it
/// from CI, so the ordering, retry and give-up behaviour can only ever be
/// proven against a fake. That is only possible if the real client sits behind
/// an interface.
///
/// The parameters mirror `PresenceService.setLate` one-for-one. [HalfDay] is
/// this package's own name for the library's `DayPart`, so the seam stays free
/// of `flutter_smartschool` types; the adapter maps it.
library;

import '../journal/half_day.dart';

/// Writes one late-arrival registration to Smartschool.
abstract interface class LatePresenceWriter {
  /// Marks [userId] late for the [part] half-day of [date] in class
  /// [classGroupId].
  ///
  /// Completes when the server accepted the write. Throws otherwise, and *how*
  /// it throws is the whole contract:
  ///
  /// - [PresenceSessionExpired] — the login is no longer good. The drain calls
  ///   [reauthenticate] and tries again; it is never a reason to give up on a
  ///   registration.
  /// - [PresenceCredentialsRefused] — Smartschool refused the login itself:
  ///   the password, the second factor, the account verification (#466). The
  ///   drain stands down at once and does not sign in again with the same
  ///   credentials; nothing about the registration is wrong, so it stays
  ///   queued.
  /// - [PresenceRejected] — the server (or the client-side precondition check)
  ///   said no, and saying it again will not change the answer: the account has
  ///   no presence rights for the class, the pupil is not in it, the code does
  ///   not exist. Terminal immediately, with the server's own words kept.
  /// - anything else — treated as transient and retried with backoff. A dropped
  ///   connection, a 502, a timeout.
  ///
  /// Repeat calls for the same student and half-day **update** the existing
  /// cell rather than appending to it, which is why the drain is careful to
  /// send a student's registrations in scan order.
  ///
  /// [keepRecordedAbsence] guards that overwrite (#460). When `true`, the
  /// write may only replace a half-day that holds nothing, a presence or a
  /// late arrival; one that holds anything else — an absence the secretariat
  /// recorded since — is left alone, nothing is written, and the call throws
  /// [PresenceRejected] naming what the half-day holds. The drain sets it for
  /// a record the operator requeued, whose write can come hours after the
  /// scan. A first send leaves it `false` and overwrites, as it always did.
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required HalfDay part,
    required bool withoutValidReason,
    required String motivation,
    bool keepRecordedAbsence = false,
  });

  /// Signs in again after a [PresenceSessionExpired].
  ///
  /// Throws [PresenceCredentialsRefused] when Smartschool refused the login
  /// itself, and the drain stands down exactly as it does when [setLate]
  /// throws one (#466). Anything else it throws — a Smartschool that could not
  /// be reached — the drain handles as an ordinary transient failure, so it
  /// ends up visible on the record instead of spinning forever.
  Future<void> reauthenticate();
}

/// The signed-in Smartschool session is gone or was never established.
///
/// Distinct from every other failure because it has a *remedy*: sign in again.
/// Nothing about the registration is wrong, so it must not count as a strike
/// against the record's retry budget.
final class PresenceSessionExpired implements Exception {
  const PresenceSessionExpired(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Smartschool refused the login itself: the password, the second factor or
/// the account verification did not get past it (#466).
///
/// Distinct from [PresenceSessionExpired] because its remedy is not the
/// drain's to apply. Signing in again would send the same credentials, which
/// Smartschool refuses again, and every refused login brings the operator's
/// own account closer to being locked. So the drain does not sign in again,
/// and it does not count this against the record either: nothing about the
/// registration is wrong. It stands down at once, leaves the record and
/// everything behind it `pending` on disk, and waits for the operator — a
/// changed login, for which the desk builds a new drain, or **Opnieuw
/// proberen**. A new scan does not wake it.
///
/// [message] is what the operator is shown, as it stands: the writer words
/// it, because only the writer knows which library sits behind it and what
/// that library's refusals mean.
final class PresenceCredentialsRefused implements Exception {
  const PresenceCredentialsRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Smartschool refused this particular write, and will refuse it again.
///
/// [message] is carried through to the journal verbatim: the operator needs the
/// server's own wording ("deze klas hoort niet bij dit account") to know whether
/// to chase an access right or a class registration. Retrying it would only bury
/// that answer under a backoff.
final class PresenceRejected implements Exception {
  const PresenceRejected(this.message);

  final String message;

  @override
  String toString() => message;
}
