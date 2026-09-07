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
/// The parameters mirror `PresenceService.setLate` one-for-one, minus `part` —
/// which is always the morning half-day. A student who turns up at 12:15 is not
/// late, they were absent for the morning, and they are not scanned at all
/// (#399), so there is deliberately no afternoon path and no noon cutoff.
library;

/// Writes one late-arrival registration to Smartschool.
abstract interface class LatePresenceWriter {
  /// Marks [userId] late for the morning of [date] in class [classGroupId].
  ///
  /// Completes when the server accepted the write. Throws otherwise, and *how*
  /// it throws is the whole contract:
  ///
  /// - [PresenceSessionExpired] — the login is no longer good. The drain calls
  ///   [reauthenticate] and tries again; it is never a reason to give up on a
  ///   registration.
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
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  });

  /// Signs in again after a [PresenceSessionExpired].
  ///
  /// Throws when the credentials themselves are the problem — which the drain
  /// then handles as an ordinary transient failure, so a wrong password ends up
  /// visible on the record instead of spinning forever.
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
