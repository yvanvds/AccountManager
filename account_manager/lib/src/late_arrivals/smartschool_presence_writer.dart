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
  /// Writes the presence for the [part] half-day. Throws the library's own
  /// exception types.
  ///
  /// [onlyReplacing] is the library's own guard, passed straight through:
  /// `null` overwrites whatever the half-day holds; a set of status names
  /// refuses any other with a [ss.SmartschoolPresenceChangeRefusedError] and
  /// sends nothing.
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required ss.DayPart part,
    required bool withoutValidReason,
    required String motivation,
    Set<String>? onlyReplacing,
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
    required ss.DayPart part,
    required bool withoutValidReason,
    required String motivation,
    Set<String>? onlyReplacing,
  }) async {
    final ss.PresenceService service = await _service();
    await service.setLate(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      withoutValidReason: withoutValidReason,
      motivation: motivation,
      onlyReplacing: onlyReplacing,
    );
  }

  @override
  Future<void> signIn() async {
    // The whole session goes, not just the cookies: `PresenceService` caches
    // the module config and the code list, and both were read under the login
    // that has just been found wanting. Disposing the old client closes its
    // HTTP connections (0.3.x). The new one starts the library's own count of
    // failed logins (three in a row, then a cooldown, dartschool#32) from
    // zero, so it is the drain's capped re-authentication budget that bounds
    // the retries, not the library's.
    final ss.SmartschoolClient? previous = _client;
    _client = null;
    _presence = null;
    if (previous != null) {
      await previous.clearCookies();
      await previous.dispose();
    }
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
    required HalfDay part,
    required bool withoutValidReason,
    required String motivation,
    bool keepRecordedAbsence = false,
  }) async {
    try {
      await session.setLate(
        userId: userId,
        classGroupId: classGroupId,
        date: date,
        part: dayPartOf(part),
        withoutValidReason: withoutValidReason,
        motivation: motivation,
        onlyReplacing: keepRecordedAbsence ? requeuedWriteMayReplace : null,
      );
    } on Object catch (error) {
      throw classifyPresenceFailure(error);
    }
  }

  @override
  Future<void> reauthenticate() => session.signIn();
}

/// What the write of a registration the operator requeued may overwrite
/// (#460): a half-day that holds nothing, a presence, or a late arrival with or
/// without a valid reason.
///
/// A requeued write can come hours after the scan. Anything else the half-day
/// holds by then — an absence the secretariat recorded, a student sent home —
/// was put there by somebody since, and wiping it would be silent. The library
/// refuses it before sending anything, which the drain records as *mislukt*
/// with [describeRefusedChange]'s sentence, so the operator looks at it. A
/// "Te laat" entered by hand in the meantime *may* be replaced: the scan says
/// the same thing, with the exact arrival time in the motivation.
const Set<String> requeuedWriteMayReplace = <String>{
  ss.PresenceService.nothingRecorded,
  ss.PresenceService.presentCodeName,
  ss.PresenceService.lateCodeName,
  ss.PresenceService.lateWithoutReasonAliasName,
};

/// The operator's sentence for a write the library refused because the
/// half-day held a status it was not allowed to replace (#460).
///
/// Dutch rather than the library's own English, because this one is not a
/// fault to forward to whoever maintains the app: it is the desk's own guard
/// doing its job, and the operator is the one who has to act on it.
String describeRefusedChange(ss.SmartschoolPresenceChangeRefusedError error) {
  final String part = switch (error.part) {
    ss.DayPart.morning => 'voormiddag',
    ss.DayPart.afternoon => 'namiddag',
  };
  final String? heldStatus = error.heldStatus;
  final String held = heldStatus == null || heldStatus.isEmpty
      ? 'een andere registratie'
      : '"$heldStatus"';
  return 'In Smartschool staat voor de $part van ${error.date} al $held. Die '
      'is niet overschreven. Kijk na of deze leerling nog als te laat '
      'ingevoerd moet worden, en duid de registratie daarna aan als manueel '
      'ingevoerd.';
}

/// The library's name for a half-day (#428). Exhaustive, so a third value on
/// either side is a compile error here rather than a presence in the wrong
/// cell.
ss.DayPart dayPartOf(HalfDay part) => switch (part) {
      HalfDay.morning => ss.DayPart.morning,
      HalfDay.afternoon => ss.DayPart.afternoon,
    };

/// Turns a `flutter_smartschool` failure into the answer the drain acts on.
///
/// Three outcomes, and the drain does something different with each:
///
/// - [PresenceSessionExpired] — sign in again and retry, no strike against the
///   record. Every [ss.SmartschoolAuthenticationError], which includes the
///   typed [ss.SmartschoolSessionExpiredError] the Presence module raises when
///   Smartschool answers a request with its login chain (`yvanvds/dartschool#5`)
///   — and also what the library raises, *without* logging in, once three
///   logins in a row failed and its cooldown is running (`dartschool#32`). The
///   drain's own re-authentication cap bounds how often this path is walked,
///   and `LiveSmartschoolPresenceSession.signIn` replaces the client, which
///   starts the library's count afresh.
/// - [PresenceRejected] — terminal at once, keeping the server's own wording so
///   the operator can tell an access right from a class registration. Every
///   other [ss.SmartschoolPresenceError]: a save the module refused
///   (`errors[]`), and the typed preconditions it checks before sending
///   anything — a pupil the class no longer lists, a class the account may not
///   confirm for, an error page that is not the login chain. None of those is
///   fixed by signing in again.
/// - anything else, returned unchanged — transient, retried with backoff. The
///   [ss.SmartschoolConnectionError] is the one that matters here (#455):
///   Smartschool was never reached, so the session is not known to be bad and
///   a fresh login would only hit the same network. On 0.2.10 the library
///   wrapped it in an authentication error, and the drain spent its capped
///   re-authentications on an unplugged cable before it fell through to the
///   backoff it should have started with.
///
/// Until 0.3.0 the library reported an HTML answer in one sentence for two
/// causes ("the session may have expired, **or** the account lacks Presence
/// access") and this function read that sentence, choosing expiry as the safe
/// reading. The typed error (`dartschool#5`) made the message match go away:
/// the login chain is now a [ss.SmartschoolSessionExpiredError], and any other
/// HTML page stays a [ss.SmartschoolPresenceError] whose message names the HTTP
/// status instead.
Object classifyPresenceFailure(Object error) {
  if (error is PresenceSessionExpired || error is PresenceRejected) {
    return error;
  }
  if (error is ss.SmartschoolConnectionError) {
    // Not an authentication failure, by the library's own design: nothing was
    // sent, so there is nothing to sign in again for. Retry it.
    return error;
  }
  if (error is ss.SmartschoolAuthenticationError) {
    return PresenceSessionExpired(error.message);
  }
  if (error is ss.SmartschoolPresenceChangeRefusedError) {
    // The `onlyReplacing` guard a requeued write carries (#460): the half-day
    // holds something recorded since the scan. Terminal like any refusal, but
    // in the operator's words, because the operator is who acts on it.
    return PresenceRejected(describeRefusedChange(error));
  }
  if (error is ss.SmartschoolPresenceError) {
    // The server's `errors[]` when it rejected the save, the client-side
    // precondition message otherwise. Either way it is what the operator needs
    // to read, verbatim.
    return PresenceRejected(
      error.errors.isEmpty ? error.message : error.errors.join('; '),
    );
  }
  // A 502, a disposed client, anything the library did not name. Retry it.
  return error;
}
