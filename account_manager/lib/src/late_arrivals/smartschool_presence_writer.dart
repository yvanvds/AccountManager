/// The half of the late-arrival drain (#404) that touches Smartschool.
///
/// The worker itself — ordering, retry, give-up, the status the scan tab reads
/// — is pure Dart in `packages/late_arrivals/`. This is the adapter that turns
/// its [LatePresenceWriter] seam into a real `Presence/Class/savePupilsPresences`
/// call through `flutter_smartschool`.
///
/// **Why that library and not `smartschool_api`.** The public Smartschool API
/// this repo's own connector speaks cannot write a presence at all. Only the
/// internal Presence module can, and `flutter_smartschool` (repo
/// `yvanvds/dartschool`) already implements it, including the session and
/// cookie handling its login flow needs.
///
/// **Whose account signs in.** The operator's own. A presence is attributed to
/// whoever wrote it, and a morning of registrations filed under a shared
/// "onthaal" login tells a form teacher nothing about who to ask. It also means
/// the presence rights the module checks (`userCanRecord` for the class) are
/// the rights the person at the desk actually has, rather than a superset baked
/// into a shared account.
///
/// **Classification is the interesting part.** Which failures are worth
/// retrying, which mean "sign in again", and which are the server saying no and
/// meaning it — see [SmartschoolPresenceWriter.setLate]. Everything below the
/// seam is one call; everything above it depends on getting that answer right,
/// which is why [SmartschoolPresenceSession] exists and is faked in the tests.
library;

import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;
import 'package:late_arrivals/late_arrivals.dart';

/// The two things the drain needs from a signed-in Smartschool session.
///
/// A seam over `PresenceService` so the failure classification below can be
/// exercised without a Smartschool on the network — which the repo's
/// live-testing policy requires, since `setLate` is a *write* against a live
/// school tenant and write-capable verification never runs in CI.
abstract interface class SmartschoolPresenceSession {
  /// Writes the morning presence. Throws the library's own exception types.
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  });

  /// Drops the current session and signs in again.
  Future<void> signIn();
}

/// The real session: one lazily-created [ss.SmartschoolClient] and the
/// [ss.PresenceService] on top of it.
///
/// Lazy on purpose. The drain is constructed at app start, long before anybody
/// is late, and a login at launch would be a network round trip on the critical
/// path of a desk that may not register a single student that day.
class LiveSmartschoolPresenceSession implements SmartschoolPresenceSession {
  LiveSmartschoolPresenceSession({
    required this.credentials,
    this.cacheDir,
  });

  /// The operator's own Smartschool login — see the library note above.
  final ss.Credentials credentials;

  /// Where the session's cookie jar lives. `null` uses the library's default
  /// (a per-username directory under the user's cache).
  final String? cacheDir;

  ss.SmartschoolClient? _client;
  ss.PresenceService? _presence;

  Future<ss.PresenceService> _service() async {
    final ss.PresenceService? held = _presence;
    if (held != null) return held;
    final ss.SmartschoolClient client =
        await ss.SmartschoolClient.create(credentials, cacheDir: cacheDir);
    _client = client;
    return _presence = ss.PresenceService(client);
  }

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  }) async {
    final ss.PresenceService service = await _service();
    await service.setLate(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      // Always the morning. A student who turns up at 12:15 is not late, they
      // were absent for the morning, and they are not scanned at all (#399).
      part: ss.DayPart.morning,
      withoutValidReason: withoutValidReason,
      motivation: motivation,
    );
  }

  @override
  Future<void> signIn() async {
    // The whole session goes, not just the cookies: `PresenceService` caches
    // the module config and the code list, and both were read under the login
    // that has just been found wanting.
    await _client?.clearCookies();
    _client = null;
    _presence = null;
    final ss.SmartschoolClient client =
        await ss.SmartschoolClient.create(credentials, cacheDir: cacheDir);
    await client.ensureAuthenticated();
    _client = client;
    _presence = ss.PresenceService(client);
  }
}

/// Writes journalled late arrivals to Smartschool for the drain (#404).
///
/// Everything it does is translate: one presence call down, and one of three
/// answers back up. The drain's whole retry policy hangs off which answer it
/// gets, so the mapping is the contract.
class SmartschoolPresenceWriter implements LatePresenceWriter {
  const SmartschoolPresenceWriter(this.session);

  /// Builds a writer that signs in as [username] on [mainUrl].
  ///
  /// [mfa] is the TOTP secret or the birthday string when the account has
  /// two-factor or account verification turned on; `null` otherwise.
  factory SmartschoolPresenceWriter.forOperator({
    required String username,
    required String password,
    required String mainUrl,
    String? mfa,
    String? cacheDir,
  }) =>
      SmartschoolPresenceWriter(
        LiveSmartschoolPresenceSession(
          credentials: ss.AppCredentials(
            username: username,
            password: password,
            mainUrl: mainUrl,
            mfa: mfa,
          ),
          cacheDir: cacheDir,
        ),
      );

  final SmartschoolPresenceSession session;

  @override
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required bool withoutValidReason,
    required String motivation,
  }) async {
    try {
      await session.setLate(
        userId: userId,
        classGroupId: classGroupId,
        date: date,
        withoutValidReason: withoutValidReason,
        motivation: motivation,
      );
    } on Object catch (error) {
      throw classifyPresenceFailure(error);
    }
  }

  @override
  Future<void> reauthenticate() => session.signIn();
}

/// Turns a `flutter_smartschool` failure into the answer the drain acts on.
///
/// Three outcomes, and the drain does something different with each:
///
/// - [PresenceSessionExpired] — sign in again and retry, no strike against the
///   record.
/// - [PresenceRejected] — terminal at once, keeping the server's own wording so
///   the operator can tell an access right from a class registration.
/// - anything else, returned unchanged — transient, retried with backoff.
///
/// The library conflates two causes in one message for an HTML response ("the
/// session may have expired, **or** the account lacks Presence access"), and
/// this reads that as expiry. That is the safe reading rather than the likely
/// one: the drain caps re-authentication, so a genuine rights problem burns two
/// sign-ins, then falls through the ordinary transient path and lands on the
/// record as a visible failure carrying that exact sentence. Reading it the
/// other way round would terminally fail a queue that a fresh login would have
/// drained.
///
/// Matching on the message is fragile and known to be: `yvanvds/dartschool#5`
/// asks for a type or a flag to tell the two causes apart. When that lands,
/// [_readsAsExpiredSession] goes away.
Object classifyPresenceFailure(Object error) {
  if (error is PresenceSessionExpired || error is PresenceRejected) {
    return error;
  }
  if (error is ss.SmartschoolAuthenticationError) {
    return PresenceSessionExpired(error.message);
  }
  if (error is ss.SmartschoolPresenceError) {
    if (_readsAsExpiredSession(error.message)) {
      return PresenceSessionExpired(error.message);
    }
    // The server's `errors[]` when it rejected the save, the client-side
    // precondition message otherwise. Either way it is what the operator needs
    // to read, verbatim.
    return PresenceRejected(
      error.errors.isEmpty ? error.message : error.errors.join('; '),
    );
  }
  // A dropped connection, a timeout, a 502. Retry it.
  return error;
}

/// Whether a presence error is the library's "got HTML back" message, which is
/// what an expired session looks like from inside the Presence module.
bool _readsAsExpiredSession(String message) {
  final String lower = message.toLowerCase();
  return lower.contains('session may have expired') ||
      lower.contains('html instead of json');
}
