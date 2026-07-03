import 'package:account_manager/src/auth/auth.dart';

/// A scriptable [AadBroker] for tests.
///
/// Each leg is driven by a callback so a test can decide, per resource, what
/// silent/interactive acquisition returns (or throws), and can assert exactly
/// how many times and in which order each leg ran. With no callbacks, silent
/// yields `null` and interactive throws — the "no broker configured" default
/// used by boot-path widget tests that never sign in.
class FakeBroker implements AadBroker {
  FakeBroker({this.silent, this.interactive});

  /// Returns the silent token for a resource, or `null` to model "silent not
  /// possible". Throwing simulates a broker error.
  BrokerToken? Function(AadResource resource)? silent;
  BrokerToken Function(AadResource resource)? interactive;

  final List<String> silentCalls = <String>[];
  final List<String> interactiveCalls = <String>[];

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async {
    silentCalls.add(resource.id);
    return silent?.call(resource);
  }

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    interactiveCalls.add(resource.id);
    final result = interactive?.call(resource);
    if (result == null) {
      throw const AadBrokerException('no interactive token scripted');
    }
    return result;
  }
}

/// Builds a [BrokerToken] valid for [validFor] from [now] (default: now).
BrokerToken fakeToken(
  String value, {
  Duration validFor = const Duration(hours: 1),
  String account = 'operator@school.example',
  DateTime? now,
}) =>
    BrokerToken(
      accessToken: value,
      expiresOn: (now ?? DateTime.now().toUtc()).add(validFor),
      account: account,
    );
