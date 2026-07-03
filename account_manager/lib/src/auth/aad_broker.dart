import 'aad_resource.dart';

/// A bearer token returned by the native broker for one [AadResource].
class BrokerToken {
  const BrokerToken({
    required this.accessToken,
    required this.expiresOn,
    this.account,
  });

  /// The bearer token to place in the `Authorization` header / SQL connection.
  final String accessToken;

  /// Absolute UTC expiry. The session refreshes shortly *before* this.
  final DateTime expiresOn;

  /// The home account id / UPN the token was minted for, when the broker
  /// reports it. Lets the session show "signed in as …" and target silent
  /// re-acquisition at the same account.
  final String? account;
}

/// The seam between the app and a platform token broker.
///
/// On Windows this is backed by the WAM broker (MSAL Runtime) over a
/// `MethodChannel`; tests inject a fake. Acquisition is split into the two
/// legs the legacy MSAL flow had (`AcquireTokenSilent` → `AcquireTokenInteractive`,
/// `Connector.cs`), and [SignInSession] owns the ordering between them.
abstract interface class AadBroker {
  /// Silent (no-prompt) acquisition. On a machine already signed in to Windows
  /// with the school AAD account this returns a token with no UI. Returns
  /// `null` when no cached account can satisfy the request silently (e.g. the
  /// dev laptop, or consent is required) — the signal to fall back to
  /// [acquireInteractive]. Throws [AadBrokerException] only on a genuine broker
  /// failure, not on "silent isn't possible".
  Future<BrokerToken?> acquireSilent(AadResource resource);

  /// Interactive acquisition: shows the WAM account picker / sign-in UI (or a
  /// web login on a non-joined machine) and returns the minted token. Throws
  /// [AadBrokerException] when the user cancels or sign-in fails.
  Future<BrokerToken> acquireInteractive(AadResource resource);
}

/// Thrown when the native broker cannot produce a token (user cancelled, the
/// broker is unavailable, or an underlying MSAL error).
class AadBrokerException implements Exception {
  const AadBrokerException(this.message, {this.code, this.cause});

  final String message;

  /// A stable error code from the native side (e.g. `broker_unavailable`,
  /// `user_cancelled`, `no_account`), when known.
  final String? code;

  final Object? cause;

  /// The broker (MSAL Runtime) is not present on this machine — the native
  /// plugin was built without it, or the runtime is not installed.
  bool get isBrokerUnavailable => code == 'broker_unavailable';

  /// The user dismissed the interactive prompt.
  bool get isUserCancelled => code == 'user_cancelled';

  @override
  String toString() => 'AadBrokerException(${code ?? 'error'}): $message'
      '${cause != null ? ' ($cause)' : ''}';
}
