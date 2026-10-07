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
/// retrying, which mean "sign in again", which mean "stop signing in, the
/// login itself was refused", and which are the server saying no and meaning
/// it — see [classifyPresenceFailure]. Everything below the seam is one call;
/// everything above it depends on getting that answer right, which is why
/// [SmartschoolPresenceSession] exists and is faked in the tests.
library;

import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;
import 'package:late_arrivals/late_arrivals.dart';

import 'operator_credentials.dart' show describeRefusedSmartschoolSignIn;

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

/// How [LiveSmartschoolPresenceSession] makes a client: the shape of
/// `SmartschoolClient.create`, less the options it leaves at their defaults.
typedef SmartschoolClientFactory = Future<ss.SmartschoolClient> Function(
  ss.Credentials credentials, {
  String? cacheDir,
});

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
    this.createClient = ss.SmartschoolClient.create,
  });

  /// The operator's own Smartschool login — see the library note above.
  final ss.Credentials credentials;

  /// Where the session's cookie jar lives. `null` uses the library's default
  /// (a per-username directory under the user's cache).
  final String? cacheDir;

  /// Makes each client the session works with: the library's own
  /// `SmartschoolClient.create`, unless a test hands in one that returns a
  /// client it can watch being disposed, without a Smartschool on the network
  /// (#469).
  final SmartschoolClientFactory createClient;

  ss.SmartschoolClient? _client;
  ss.PresenceService? _presence;

  Future<ss.PresenceService> _service() async {
    final ss.PresenceService? held = _presence;
    if (held != null) return held;
    final ss.SmartschoolClient client =
        await createClient(credentials, cacheDir: cacheDir);
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
    // the retries, not the library's. That count also stops a client from
    // logging in again after Smartschool refused its credentials, and a new
    // client would not know; so a refused login must never lead here. It
    // does not: the writer answers it with a `PresenceCredentialsRefused`,
    // and the drain stands down instead of asking for a fresh sign-in (#466).
    final ss.SmartschoolClient? previous = _client;
    _client = null;
    _presence = null;
    if (previous != null) {
      await previous.clearCookies();
      await previous.dispose();
    }
    final ss.SmartschoolClient client =
        await createClient(credentials, cacheDir: cacheDir);
    try {
      await client.ensureAuthenticated();
    } on Object {
      // Nothing holds this client once the error leaves here: `_client` stays
      // null, and the next write makes a client of its own. Until #469 its
      // HTTP connections stayed open until they timed out — one client per
      // failed sign-in, so up to two per registration while Smartschool
      // cannot be reached, and one per stand-down over a refused login.
      // Closing it does not touch the error the drain acts on: it is passed
      // on as the library threw it.
      await client.dispose();
      rethrow;
    }
    _client = client;
    _presence = ss.PresenceService(client);
  }
}

/// Writes journalled late arrivals to Smartschool for the drain (#404).
///
/// Everything it does is translate: one presence call down, and one of four
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

  /// Signs in again, through [session].
  ///
  /// A login Smartschool refused — the password, the second factor, the
  /// account verification — comes back as a [PresenceCredentialsRefused] in
  /// [describePresenceFailure]'s words, the answer [classifyPresenceFailure]
  /// gives the same refusal on a write, so the drain stands down instead of
  /// signing in with them again (#466). Anything else is passed on as the
  /// library threw it, for the drain to retry.
  @override
  Future<void> reauthenticate() async {
    try {
      await session.signIn();
    } on Object catch (error) {
      if (describeRefusedSmartschoolSignIn(error) == null) rethrow;
      throw PresenceCredentialsRefused(describePresenceFailure(error));
    }
  }
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

/// The operator's words for a failure the drain retries — and, once its
/// attempts are spent, the text the registration is given up with (#463).
///
/// The drain's `describeFailure`. Without it the drain stores the error's
/// `toString()`, and for the library's own types that is a Dart type name and
/// an English sentence about JSON on the desk's *mislukt* line. The operator
/// reading that line has one decision to make — **Opnieuw proberen** or
/// **Manueel ingevoerd** — and needs to be told the one thing these failures
/// share: Smartschool was not there for a while, so trying again later is the
/// answer. Two of the library's types reach the desk that way, both returned
/// unchanged by [classifyPresenceFailure] so that the drain retries them:
///
/// - a [ss.SmartschoolPresenceUnreadableAnswerError] (#461) — an empty answer,
///   an HTML page or broken JSON, such as a proxy's 502;
/// - a [ss.SmartschoolConnectionError] (#455) — Smartschool was never reached.
///   The sentence points at **Aanmelding testen** for when trying again does
///   not help: that test tells an unplugged network from a certificate this
///   computer does not trust (`describeSmartschoolSignInFailure`), and the
///   desk's line has no room to.
///
/// Neither sentence says whether the registration reached Smartschool. For a
/// read nothing was written, but an unreadable answer to the save, or a
/// connection that dropped during it, leaves that unknown. It does not matter
/// for the choice: sending it again is safe either way (see
/// [classifyPresenceFailure]).
///
/// A login Smartschool refused is the third failure the desk words (#464): a
/// wrong or changed password, a second factor it did not get or did not
/// accept, an account verification. The drain does not retry these and does
/// not give a registration up over them (#466): [classifyPresenceFailure] and
/// [SmartschoolPresenceWriter.reauthenticate] put these words in the
/// [PresenceCredentialsRefused] the drain stands down with, and the desk's
/// queue panel shows them for as long as it stays down. Trying again does not
/// help here — only the operator can, by fixing the login — so the sentence
/// names the cause ([describeRefusedSmartschoolSignIn]) and says where to fix
/// and test it.
///
/// The library's own text follows on the next line, the shape
/// `describeSmartschoolSignInFailure` gives a failed **Aanmelding testen**: the
/// desk shows the first line and folds the rest away behind **Details**
/// (`DeskWarning.fromText`), and the log and the journal keep both, for
/// whoever has to diagnose it. Anything else comes back as its own text, as
/// before.
String describePresenceFailure(Object error) {
  final String? refusedLogin = describeRefusedSmartschoolSignIn(error);
  final String? sentence = refusedLogin != null
      ? '$refusedLogin Pas de aanmelding aan bij Instellingen → Te laat, test '
          'ze met Aanmelding testen en probeer daarna opnieuw.'
      : switch (error) {
          ss.SmartschoolPresenceUnreadableAnswerError(:final int? statusCode) =>
            'Smartschool gaf een antwoord dat niet gelezen kon worden'
                '${statusCode == null ? '' : ' (HTTP $statusCode)'}. Meestal '
                'is Smartschool dan even niet bereikbaar; probeer opnieuw '
                'zodra het weer werkt.',
          ss.SmartschoolConnectionError() =>
            'Smartschool was niet bereikbaar vanaf deze computer. Probeer '
                'opnieuw zodra de netwerkverbinding in orde is; lukt het dan '
                'nog niet, test de aanmelding bij Instellingen → Te laat.',
          _ => null,
        };
  return sentence == null ? '$error' : '$sentence\n$error';
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
/// Four outcomes, and the drain does something different with each:
///
/// - [PresenceCredentialsRefused] — stand down at once, without signing in
///   again, without spending an attempt and without giving the registration
///   up (#466). A login Smartschool refused: the authentication errors the
///   library itself counts as rejected credentials and stops logging in after
///   until `SmartschoolClient.resetLoginAttempts` (its `_rejectsCredentials`,
///   dartschool#32) — the password, the second factor, the account
///   verification, as [describeRefusedSmartschoolSignIn] names them. Signing
///   in again would send the same credentials, and every refused login brings
///   the operator's account closer to being locked. It carries
///   [describePresenceFailure]'s Dutch (#464), with the library's text on the
///   line below.
/// - [PresenceSessionExpired] — sign in again and retry, no strike against the
///   record. Every other [ss.SmartschoolAuthenticationError], which includes
///   the typed [ss.SmartschoolSessionExpiredError] the Presence module raises
///   when Smartschool answers a request with its login chain
///   (`yvanvds/dartschool#5`) — and also what the library raises, *without*
///   logging in, once three logins in a row failed and its cooldown is running
///   (`dartschool#32`). The drain's own re-authentication cap bounds how often
///   this path is walked, and `LiveSmartschoolPresenceSession.signIn` replaces
///   the client, which starts the library's count afresh. It carries the
///   library's message.
/// - [PresenceRejected] — terminal at once, keeping the server's own wording so
///   the operator can tell an access right from a class registration. Every
///   other [ss.SmartschoolPresenceError]: a save the module refused
///   (`errors[]`), and the typed preconditions it checks before sending
///   anything — a pupil the class no longer lists, a class the account may not
///   confirm for, a half-day a requeued write may not overwrite. None of those
///   is fixed by signing in again, nor by asking again.
/// - anything else, returned unchanged — transient, retried with backoff. Two
///   of the library's own types matter here. A [ss.SmartschoolConnectionError]
///   (#455): Smartschool was never reached, so the session is not known to be
///   bad and a fresh login would only hit the same network. On 0.2.10 the
///   library wrapped it in an authentication error, and the drain spent its
///   capped re-authentications on an unplugged cable before it fell through to
///   the backoff it should have started with. And a
///   [ss.SmartschoolPresenceUnreadableAnswerError] (#461): an answer that was
///   empty, an HTML page or broken JSON, such as a proxy's 502. It is a
///   [ss.SmartschoolPresenceError] too, but not a refusal; see the reasoning
///   at its branch below.
///
/// Until 0.3.0 the library reported an HTML answer in one sentence for two
/// causes ("the session may have expired, **or** the account lacks Presence
/// access") and this function read that sentence, choosing expiry as the safe
/// reading. The typed error (`dartschool#5`) made the message match go away:
/// the login chain is now a [ss.SmartschoolSessionExpiredError]. Any other
/// answer it cannot read has had a type of its own since dartschool#137, so
/// this function still never reads a message.
Object classifyPresenceFailure(Object error) {
  if (error is PresenceSessionExpired ||
      error is PresenceRejected ||
      error is PresenceCredentialsRefused) {
    return error;
  }
  if (error is ss.SmartschoolConnectionError) {
    // Not an authentication failure, by the library's own design: nothing was
    // sent, so there is nothing to sign in again for. Retry it.
    return error;
  }
  if (error is ss.SmartschoolAuthenticationError) {
    if (describeRefusedSmartschoolSignIn(error) != null) {
      // A login Smartschool refused. Until #466 this was an expiry like any
      // other, and the drain spent two fresh sign-ins and five writes on it —
      // seven refused logins per registration, and as many again on the next
      // scan. Now the drain stands down on the first, in the operator's words
      // (#464), with the library's ("Login failed. Check username/password
      // …") on the line below.
      return PresenceCredentialsRefused(describePresenceFailure(error));
    }
    // A session Smartschool no longer accepts, or anything else here: signing
    // in again is the remedy, in the library's own words.
    return PresenceSessionExpired(error.message);
  }
  if (error is ss.SmartschoolPresenceUnreadableAnswerError) {
    // An answer the library could not read: empty, an HTML page where JSON
    // belongs, or JSON that breaks off (dartschool#137). Not the module saying
    // no — its refusals come as JSON (`errors[]`) or as the typed checks below
    // — but whatever stood between the desk and the module: a proxy's 502, a
    // 503 during maintenance, an answer cut off. Retry it (#461).
    //
    // Every kind and every status, the `200` and `500` HTML pages included.
    // Smartschool's generic error page is also how the module answers a
    // request it cannot handle, which a retry gets again. Retrying is still
    // the right call, for two reasons. Such an answer is about the endpoint,
    // the account or the proxy, never about this one pupil, so the next
    // registration would get it too. As a rejection, the drain gives the
    // record up and moves on to the next one, so the whole queue fails
    // record by record: what a desk saw live on 2026-10-07, when v1.4.0 read
    // an empty answer as one. As a transient failure, the drain's
    // `maxAttempts` bounds it: one record ends *mislukt* with this error, in
    // [describePresenceFailure]'s words (#463), the drain stands down as
    // `degraded`, and everything behind it stays queued on disk until
    // Smartschool answers again. A real refusal costs only the backoff.
    //
    // Retrying the save itself (`/Presence/Class/savePupilsPresences`) is
    // safe, even though nobody knows whether it landed. The next call reads
    // the class first and updates the half-day's record, never adds a second
    // one (#399). A requeued write's `onlyReplacing` allows the "Te laat" that
    // the first save may have stored ([requeuedWriteMayReplace]).
    return error;
  }
  if (error is ss.SmartschoolPresenceChangeRefusedError) {
    // The `onlyReplacing` guard a requeued write carries (#460): the half-day
    // holds something recorded since the scan. Terminal like any refusal, but
    // in the operator's words, because the operator is who acts on it.
    return PresenceRejected(describeRefusedChange(error));
  }
  if (error is ss.SmartschoolPresenceError) {
    // The server's `errors[]` when it rejected the save, the client-side
    // precondition message otherwise: a class, code or pupil it could not
    // resolve, or a class the account may not confirm for. Either way it is
    // what the operator needs to read, verbatim.
    return PresenceRejected(
      error.errors.isEmpty ? error.message : error.errors.join('; '),
    );
  }
  // Anything the library did not name: a disposed client, a `DioException` it
  // passed on as is, an I/O error. Nothing in it says the registration is
  // wrong, so retry it. (A gateway's 502 does not land here: the library takes
  // every HTTP status as an answer, so its error page is the unreadable
  // answer above.)
  return error;
}
