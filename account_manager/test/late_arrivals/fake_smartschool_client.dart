/// A `SmartschoolClient` that never reaches a Smartschool, for the two places
/// that sign the operator in with a client of their own: the drain's fresh
/// sign-in (`LiveSmartschoolPresenceSession.signIn`, #469) and
/// **Aanmelding testen** (`probeSmartschoolOperatorSignInLive`, #470).
///
/// Shared so the two cannot drift apart: both are checked for the same thing,
/// a client closed on every path that leaves it unheld.
library;

import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;

/// A `SmartschoolClient` that signs in, or fails to, the way it is told, and
/// counts what was done to it (#469). It answers no request: every other
/// member throws an [UnimplementedError], counted in [requests].
///
/// Like the library's own, a disposed one refuses to sign in with a
/// [ss.SmartschoolClientDisposedError] (#470), so a client closed too early is
/// caught rather than counted as a login.
class FakeClient implements ss.SmartschoolClient {
  FakeClient({this.signInFailure});

  /// Thrown by [ensureAuthenticated]; `null` signs in.
  final Object? signInFailure;

  int signIns = 0;
  int cookieClears = 0;
  int disposals = 0;
  int requests = 0;

  @override
  bool get isDisposed => disposals > 0;

  @override
  Future<void> ensureAuthenticated() async {
    if (isDisposed) {
      throw ss.SmartschoolClientDisposedError(
        'SmartschoolClient was disposed: it sends no more requests',
      );
    }
    signIns++;
    final Object? error = signInFailure;
    if (error != null) throw error;
  }

  @override
  Future<void> clearCookies() async {
    cookieClears++;
  }

  @override
  Future<void> dispose({bool force = true}) async {
    disposals++;
  }

  @override
  Never noSuchMethod(Invocation invocation) {
    requests++;
    throw UnimplementedError(
      'FakeClient does not answer ${invocation.memberName}',
    );
  }
}
