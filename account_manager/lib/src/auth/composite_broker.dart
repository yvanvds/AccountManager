import 'aad_broker.dart';
import 'aad_resource.dart';

/// Chains several [AadBroker]s, trying them in order.
///
/// This is how the app runs "silent WAM broker, then interactive fallback" as a
/// single broker the [SignInSession] doesn't have to know about (#98). On a
/// school-account machine the native WAM broker satisfies the silent leg; on
/// the dev laptop it reports `broker_unavailable` and the chain moves on to the
/// loopback OAuth broker for interactive sign-in.
///
/// - [acquireSilent] is best-effort: it returns the first non-null token and
///   never fails the chain — a broker that errors (unavailable, transient) is
///   just skipped, since a failed silent acquisition simply means "fall back to
///   interactive".
/// - [acquireInteractive] returns the first success. A `broker_unavailable`
///   error moves to the next broker; any other error (e.g. the user cancelled)
///   stops the chain, so a cancel isn't papered over by another prompt.
class CompositeBroker implements AadBroker {
  CompositeBroker(this._brokers)
      : assert(_brokers.isNotEmpty, 'need at least one broker');

  final List<AadBroker> _brokers;

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async {
    for (final broker in _brokers) {
      try {
        final token = await broker.acquireSilent(resource);
        if (token != null) return token;
      } catch (_) {
        // Silent is an optimization; on any failure try the next broker.
      }
    }
    return null;
  }

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    AadBrokerException? last;
    for (final broker in _brokers) {
      try {
        return await broker.acquireInteractive(resource);
      } on AadBrokerException catch (e) {
        last = e;
        if (e.isBrokerUnavailable) continue; // this broker can't; try the next
        rethrow; // a real failure (cancel, denied) stops the chain
      }
    }
    throw last ??
        const AadBrokerException(
            'no broker could complete interactive sign-in');
  }
}
