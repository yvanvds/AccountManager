/// The reception operator's own Smartschool login on this machine (#409).
///
/// **Why this exists at all.** The drain (#404) writes a presence through
/// `flutter_smartschool`'s internal Presence module, which needs a real user
/// login. The credential `smartschool_api` already stores is the *public* API
/// access code, and that cannot write a presence at any privilege level — so
/// there was nowhere in the app holding a login the drain could use, and
/// nothing constructed the drain.
///
/// **Whose login.** The operator's own, not a shared "onthaal" account. A
/// presence is attributed to whoever wrote it, so a shared login tells a form
/// teacher nothing about who to ask, and the module's `userCanRecord` check
/// would be against a superset of rights the person at the desk does not have.
/// That decision was settled in #404 and this is where it lands: a login that is
/// per-*operator* is by construction per-*machine*, because two operators do not
/// share a Windows session at a reception desk.
///
/// **Where it is kept, and why not with the others.** Three candidate homes were
/// already in the repo and none of them fits:
///
/// - `AppSettings` in Cosmos is the *shared* document. Every operator reads it,
///   which is exactly what a password must not be.
/// - Key Vault holds the two shared connector credentials (the WISA password,
///   the Smartschool passphrase). Those are the school's; this one is a person's,
///   and putting it there would let any operator's app read a colleague's
///   password.
/// - `preferences.json` is per-machine and is where this desk's own working
///   answers live — but it is deliberately plain JSON, and its own doc says no
///   secret goes in it.
///
/// So: a file of its own, next to `connection.json` and `preferences.json` under
/// `%APPDATA%\AccountManager\`, holding **only ciphertext** — the same
/// user-scoped DPAPI cipher the OAuth token cache uses (#103), so the bytes can
/// only be read back by the Windows account that wrote them, on this machine.
///
/// Not under `auth\` with the token cache, deliberately: a tenant change in
/// Instellingen → Verbinding deletes that whole directory (`_forgetCachedTokens`
/// in `main.dart`), and a Smartschool login has nothing to do with which Azure AD
/// tenant the app signs in to. Keeping it out of the blast radius is the whole
/// reason for the separate path.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;

/// The file this machine's Smartschool login lives in, beside `connection.json`
/// and `preferences.json` under the same `%APPDATA%\AccountManager\` root.
///
/// The extension says what is inside: not JSON, ciphertext.
const String smartschoolOperatorCredentialFileName =
    'smartschool-operator.cred';

/// The operator's Smartschool login, as the Presence module needs it.
///
/// [mfa] is optional and is whichever second factor the account has turned on —
/// a Base32 TOTP secret for two-factor, or a `yyyy-MM-dd` birthday for
/// account-verification. `flutter_smartschool` takes both in the one field and
/// works out which it is, so this does not try to be cleverer than the library.
class SmartschoolOperatorLogin {
  const SmartschoolOperatorLogin({
    required this.username,
    required this.password,
    this.mfa = '',
  });

  /// Reads a login back out of its decrypted JSON, tolerating anything —
  /// a wrong shape reads as "nothing stored", never as a launch failure.
  static SmartschoolOperatorLogin? tryFromJson(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final Object? username = decoded['username'];
    final Object? password = decoded['password'];
    if (username is! String || password is! String) return null;
    final Object? mfa = decoded['mfa'];
    final SmartschoolOperatorLogin login = SmartschoolOperatorLogin(
      username: username,
      password: password,
      mfa: mfa is String ? mfa : '',
    );
    return login.isEmpty ? null : login;
  }

  final String username;
  final String password;
  final String mfa;

  /// Whether this login can actually be signed in with. A half-typed one (a
  /// username and no password) is *not* usable, and the desk treats it exactly
  /// as it treats none at all — journalling and printing, not draining.
  bool get isComplete =>
      username.trim().isNotEmpty && password.trim().isNotEmpty;

  /// Whether nothing was entered at all.
  bool get isEmpty =>
      username.trim().isEmpty && password.trim().isEmpty && mfa.trim().isEmpty;

  /// The login with [password] and/or [mfa] replaced only where the operator
  /// typed something.
  ///
  /// This is what makes the password field write-only in Instellingen the same
  /// way the WISA password and Smartschool passphrase already are: a blank field
  /// keeps what is stored rather than erasing it, so an operator correcting a
  /// typo in their username does not have to retype their password to do it.
  SmartschoolOperatorLogin merged({
    required String username,
    required String password,
    required String mfa,
  }) =>
      SmartschoolOperatorLogin(
        username: username.trim(),
        password: password.isEmpty ? this.password : password,
        mfa: mfa.isEmpty ? this.mfa : mfa.trim(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'username': username,
        'password': password,
        if (mfa.isNotEmpty) 'mfa': mfa,
      };

  /// Never the password. This type ends up in error text and log lines, and a
  /// credential that prints itself is a credential that leaks.
  @override
  String toString() => 'SmartschoolOperatorLogin($username, '
      '${password.isEmpty ? 'geen wachtwoord' : 'wachtwoord ingesteld'}'
      '${mfa.isEmpty ? '' : ', mfa'})';
}

/// Where the operator's login is read and written.
///
/// A seam rather than a bare file for the reason every other store in this
/// folder is one: a headless run must be able to prove the whole round trip
/// without writing to the operator's real `%APPDATA%` — and, here, without
/// calling DPAPI, which does not exist on the Linux runner the unit suite runs
/// on.
abstract interface class OperatorCredentialStore {
  /// The stored login, or `null` when there is none.
  ///
  /// **Never throws.** A missing file, an unreadable one, one written by another
  /// Windows user (DPAPI refuses it) or one that predates a format change all
  /// read as "no login configured", which is a state the desk already handles:
  /// it keeps journalling and printing and says the drain is not running.
  Future<SmartschoolOperatorLogin?> read();

  /// Replaces the stored login. Throws when it cannot be persisted — unlike a
  /// read, a *save* that silently did nothing would leave the operator believing
  /// the desk is configured when it is not.
  Future<void> write(SmartschoolOperatorLogin login);

  /// Removes the stored login entirely — the "wissen" affordance, and the only
  /// way to get back to an unconfigured desk. Best effort.
  Future<void> clear();

  /// Where a [write] puts the value, as the operator should read it.
  String get location;
}

/// The production [OperatorCredentialStore]: one file holding one ciphertext.
///
/// The cipher is injected rather than reached for, so the unit suite can prove
/// the round trip, the merge rules and the never-in-the-clear guarantee on a
/// machine that has no `crypt32.dll`. `main()` passes `Dpapi.protect` /
/// `Dpapi.unprotect`; the full-app integration run on Windows drives those same
/// two, so the real cipher is exercised end to end where it exists.
class EncryptedFileCredentialStore implements OperatorCredentialStore {
  EncryptedFileCredentialStore(
    this.file, {
    required this.encrypt,
    required this.decrypt,
  });

  /// The credential file, which need not exist — an install nobody has
  /// configured has none, which is a supported state and not an error.
  final File file;

  /// Plaintext in, ciphertext out. Whatever it returns is what lands on disk,
  /// so a cipher that does nothing would break the one promise this class makes.
  final String Function(String plaintext) encrypt;

  /// The inverse. Expected to throw when the payload cannot be decrypted —
  /// tampered with, another user's, another machine's — which [read] reports as
  /// "no login configured".
  final String Function(String ciphertext) decrypt;

  @override
  String get location => file.path;

  @override
  Future<SmartschoolOperatorLogin?> read() async {
    try {
      if (!file.existsSync()) return null;
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return SmartschoolOperatorLogin.tryFromJson(jsonDecode(decrypt(raw)));
    } on Object {
      // See the interface doc: a credential that cannot be read is a desk with
      // no login, never a failed launch.
      return null;
    }
  }

  @override
  Future<void> write(SmartschoolOperatorLogin login) async {
    file.parent.createSync(recursive: true);
    // Encrypt first, and only then touch the file. A cipher that throws must
    // leave the previous credential intact rather than truncating it to
    // nothing — and it must never be possible for the plaintext to reach the
    // filesystem on the way.
    final String ciphertext = encrypt(jsonEncode(login.toJson()));
    await file.writeAsString(ciphertext, flush: true);
  }

  @override
  Future<void> clear() async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best effort: a locked file means the stale ciphertext lingers, and the
      // desk has already dropped the login it was holding in memory.
    }
  }
}

/// An [OperatorCredentialStore] that keeps the login in memory.
///
/// Two uses, and both matter: it is what tests bind so a headless run cannot
/// write to the operator's real `%APPDATA%`, and it is what a non-Windows (or
/// APPDATA-less) run falls back to — where there is no DPAPI to encrypt with,
/// so a per-session login is the only honest offer.
class InMemoryOperatorCredentialStore implements OperatorCredentialStore {
  InMemoryOperatorCredentialStore([this._stored]);

  SmartschoolOperatorLogin? _stored;

  @override
  String get location =>
      '$smartschoolOperatorCredentialFileName (niet bewaard op deze machine)';

  @override
  Future<SmartschoolOperatorLogin?> read() async => _stored;

  @override
  Future<void> write(SmartschoolOperatorLogin login) async => _stored = login;

  @override
  Future<void> clear() async => _stored = null;
}

/// The credential store for the machine this process is running on:
/// `%APPDATA%\AccountManager\smartschool-operator.cred` on Windows, an in-memory
/// one anywhere APPDATA is absent — the same rule the token cache,
/// `connection.json` and `preferences.json` follow.
///
/// The DPAPI branch is Windows-only for a stronger reason than the others: there
/// is no cipher off Windows, and writing a password to disk in the clear because
/// the platform has no keystore would be worse than not remembering it.
OperatorCredentialStore smartschoolOperatorCredentialStoreForThisMachine({
  required String Function(String) encrypt,
  required String Function(String) decrypt,
}) {
  final String? appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryOperatorCredentialStore();
  }
  return EncryptedFileCredentialStore(
    File('$appData\\AccountManager\\$smartschoolOperatorCredentialFileName'),
    encrypt: encrypt,
    decrypt: decrypt,
  );
}

/// The Smartschool host `flutter_smartschool` signs in against, from the site
/// URI in the shared settings document.
///
/// `Credentials.mainUrl` wants a bare hostname (`arcadia.smartschool.be`), and
/// the document holds whatever the operator typed — with or without a scheme,
/// with or without a trailing path. This is deliberately *not*
/// `smartschoolSiteFrom` (`reconcile_bootstrap.dart`): that one strips the
/// `.smartschool.be` suffix because the SOAP connector wants the school's short
/// name, and handing that to the Presence login would sign in against a host
/// that does not exist.
///
/// **And in practice the document holds exactly that short name** (#412): the
/// Smartschool settings tab asks for the school's subdomain because that is what
/// the SOAP connector needs, so what is stored is `arcadia`, not
/// `arcadia.smartschool.be`. A dot-less label is therefore completed here rather
/// than handed to the Presence login as-is — signing in against `arcadia` dies
/// with `Failed host lookup`. A value that already carries a dot is left alone,
/// so a configuration that spells the address out in full keeps working.
///
/// Returns `''` for an unconfigured document, which the desk reports as a
/// missing site rather than trying to sign in against nothing.
String smartschoolHostFrom(String uri) {
  final String trimmed = uri.trim();
  if (trimmed.isEmpty) return '';
  final Uri? parsed =
      Uri.tryParse(trimmed.contains('://') ? trimmed : 'https://$trimmed');
  final String host = parsed?.host ?? '';
  final String label = host.isNotEmpty ? host : trimmed;
  return label.contains('.') ? label : '$label$smartschoolHostSuffix';
}

/// The domain every Belgian Smartschool platform lives under, and the suffix
/// [smartschoolHostFrom] completes a bare school subdomain with — the same
/// suffix `smartschoolSiteFrom` (`reconcile_bootstrap.dart`) strips back off for
/// the SOAP connector.
const String smartschoolHostSuffix = '.smartschool.be';

/// Signs in with [login] against [host] and returns once the session stands.
///
/// The seam behind **Aanmelding testen**. It exists as a seam because a real
/// Smartschool login is a live interaction with the school's tenant, and the
/// repo's live-testing policy keeps those out of CI entirely: every test binds a
/// fake, and only the operator pressing the button drives
/// [probeSmartschoolOperatorSignInLive].
///
/// Throws on failure, carrying the library's own message — a wrong password and
/// a missing second factor say different things, and the operator standing at
/// the desk needs to be told which. A Smartschool that could not be reached at
/// all is a [ss.SmartschoolConnectionError], which is not a login failure and
/// is worded as such by [describeSmartschoolSignInFailure] (#455).
typedef SmartschoolSignInProbe = Future<void> Function(
  SmartschoolOperatorLogin login,
  String host,
);

/// The real **Aanmelding testen**: one full login, then nothing.
///
/// Deliberately the same call the drain's own re-authentication makes
/// (`LiveSmartschoolPresenceSession.signIn`), and deliberately *only* that: it
/// reads no presence, writes no presence and touches no student. A typo in a
/// password should be caught here, minutes before the first student is late,
/// rather than discovered as a queue that will not drain.
Future<void> probeSmartschoolOperatorSignInLive(
  SmartschoolOperatorLogin login,
  String host, {
  String? cacheDir,
}) async {
  final ss.SmartschoolClient client = await ss.SmartschoolClient.create(
    ss.AppCredentials(
      username: login.username.trim(),
      password: login.password,
      mainUrl: host,
      mfa: login.mfa.trim().isEmpty ? null : login.mfa.trim(),
    ),
    cacheDir: cacheDir,
  );
  await client.ensureAuthenticated();
}

/// What is wrong with a login Smartschool refused, in the operator's words —
/// or `null` when [error] is not such a refusal (#464).
///
/// A refusal is one of the library's authentication errors that it counts as
/// rejected credentials itself (the list behind
/// `SmartschoolClient.resetLoginAttempts`): the password, the second factor or
/// the account verification did not get past the login. Each one names its
/// cause, because each has a different fix in the same three fields of
/// **Instellingen → Te laat** — the password, or the MFA field, which holds the
/// authenticator's secret key or, for an account verification, a date of
/// birth. They are told apart by type, never by the library's message.
///
/// One sentence about the login and nothing else: no Dart type name, none of
/// the library's English, and no advice on where to go, which depends on where
/// it is shown. A session Smartschool no longer accepts
/// ([ss.SmartschoolSessionExpiredError]) is not a refused login, and neither is
/// anything else; those return `null`.
///
/// It is also the test for "Smartschool refused the login" itself: a non-null
/// answer is what makes the presence writer stand the drain down instead of
/// signing in with the same credentials again (#466). Its seven types are the
/// library's own `_rejectsCredentials`.
///
/// `describePresenceFailure` puts this on the desk's queue panel while the
/// drain is stood down over a refused login. **Aanmelding testen** does not
/// use it yet: a refusal there still comes back in the library's own words
/// (see [describeSmartschoolSignInFailure], #467).
String? describeRefusedSmartschoolSignIn(Object error) => switch (error) {
      ss.SmartschoolInvalidCredentialsError() =>
        'Smartschool aanvaardde de gebruikersnaam of het wachtwoord niet.',
      ss.SmartschoolTwoFactorRequiredError() =>
        'Smartschool vraagt voor dit account een tweestapsverificatie, maar '
            'bij de aanmelding staat geen geheime sleutel van de '
            'authenticator (MFA).',
      ss.SmartschoolTwoFactorRejectedError() =>
        'Smartschool aanvaardde de code van de tweestapsverificatie niet. '
            'Kijk de geheime sleutel van de authenticator (MFA) na, en of de '
            'klok van deze computer juist staat.',
      ss.SmartschoolInvalidTotpSecretError() =>
        'De geheime sleutel van de authenticator (MFA) is geen geldige '
            'sleutel: vul de tekenreeks in die Smartschool toont bij het '
            'instellen van de authenticator, niet de code van zes cijfers uit '
            'de app.',
      ss.SmartschoolUnsupportedTwoFactorMethodError() =>
        'Dit account gebruikt een tweestapsverificatie die het programma niet '
            'kan invullen: alleen een authenticator-app (zoals Google '
            'Authenticator) wordt ondersteund.',
      ss.SmartschoolAccountVerificationRequiredError() =>
        'Smartschool vraagt voor dit account een accountverificatie met de '
            'geboortedatum, maar in het MFA-veld van de aanmelding staat geen '
            'datum (jjjj-mm-dd).',
      ss.SmartschoolAccountVerificationRejectedError() =>
        'Smartschool aanvaardde de geboortedatum van de accountverificatie '
            'niet. Kijk de datum in het MFA-veld na (jjjj-mm-dd).',
      _ => null,
    };

/// What a failed **Aanmelding testen** tells the person at the desk (#455).
///
/// Two kinds of failure come out of the probe, and they call for different
/// hands. A login Smartschool *refused* — a wrong password, a missing second
/// factor, a code it did not accept — comes back in the library's own words,
/// unchanged: those messages already tell the three apart, and the operator is
/// the one to fix them. (The drain, which stands down over the same refusal,
/// says it in Dutch, [describeRefusedSmartschoolSignIn], #464, #466.) A
/// [ss.SmartschoolConnectionError] is the other kind:
/// Smartschool was never reached, so nothing was sent — not the username, not
/// the password, not the MFA — and no amount of retyping them helps. Until the
/// library told the two apart (`yvanvds/dartschool#21`) a certificate the PC
/// did not trust (#454) arrived here as an *authentication* error, raw
/// `toString()` and BoringSSL source path included, and sent the technician
/// looking at the MFA secret.
///
/// The certificate case is singled out because its fix is on this computer,
/// not on the network. Since #454 the app trusts the GlobalSign roots itself,
/// so what is left when the handshake still fails is something on the network
/// re-signing TLS (a firewall, a proxy, an antivirus) or a root missing from
/// the Windows store; the open-it-once-in-Edge workaround is offered last, as
/// the fallback it is.
///
/// The library's own sentence stays reachable on a second line — whoever is
/// asked to fix it still needs to see what Dio said — but it is never the
/// operator's first line.
String describeSmartschoolSignInFailure(Object error, String host) {
  if (error is! ss.SmartschoolConnectionError) return '$error';
  final String operatorLine = _isCertificateFailure(error)
      ? 'De beveiligde verbinding met $host wordt op deze computer niet '
          'vertrouwd: de aanmeldpagina werd nooit bereikt, dus gebruikersnaam, '
          'wachtwoord en MFA zijn niet verstuurd. Meestal onderschept iets op '
          'het netwerk (een firewall, proxy of antivirus) de TLS-verbinding, '
          'of ontbreekt een basiscertificaat in het Windows-certificaatarchief. '
          'Helpt dat niet, open dan https://$host één keer in Edge en herstart '
          'de app.'
      : 'Smartschool op $host is niet bereikbaar: de aanmeldpagina werd nooit '
          'bereikt, dus gebruikersnaam, wachtwoord en MFA zijn niet verstuurd. '
          'Controleer de netwerkverbinding en het Smartschool-adres.';
  return '$operatorLine\n$error';
}

/// Whether a connection failure is the TLS handshake being refused — a
/// certificate this computer does not trust — rather than a host that does not
/// answer.
///
/// The library's `cause` is the `DioException`, whose own `error` is the
/// `HandshakeException`; this app does not depend on `dio` and has no business
/// starting to for one field, so the chain is read as text. Dio prints its
/// inner error (`Error: HandshakeException: …`), and the library's message
/// already carries it too (`the connection failed (HandshakeException: …)`),
/// so either is enough. A direct [TlsException] cause — which is what a test
/// hands in — is matched by type.
bool _isCertificateFailure(ss.SmartschoolConnectionError error) {
  final Object? cause = error.cause;
  if (cause is TlsException) return true;
  final String text = '${error.message}\n$cause'.toLowerCase();
  return text.contains('handshakeexception') ||
      text.contains('certificate_verify_failed') ||
      // `DioExceptionType.badCertificate`, as the library words it.
      text.contains('certificate was rejected');
}
