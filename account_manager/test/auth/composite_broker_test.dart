import 'package:account_manager/src/auth/auth.dart';
import 'package:azure_api/azure_api.dart' show AzureCredentials;
import 'package:flutter_test/flutter_test.dart';

import 'fake_broker.dart';

/// A broker that always reports itself unavailable — the native WAM stub on a
/// machine without the MSAL Runtime.
class _UnavailableBroker implements AadBroker {
  int silentCalls = 0;
  int interactiveCalls = 0;

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async {
    silentCalls++;
    throw const AadBrokerException('not built', code: 'broker_unavailable');
  }

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    interactiveCalls++;
    throw const AadBrokerException('not built', code: 'broker_unavailable');
  }
}

void main() {
  final graph = AadResource.graph(AzureCredentials(
    clientId: 'c',
    tenantId: 't',
    azureDomain: 'd',
    schoolPrefix: 'p',
  ));

  test('silent uses the first broker that returns a token', () async {
    final primary = FakeBroker(silent: (_) => fakeToken('WAM-AT'));
    final secondary = FakeBroker(silent: (_) => fakeToken('OAUTH-AT'));
    final composite = CompositeBroker([primary, secondary]);

    expect((await composite.acquireSilent(graph))?.accessToken, 'WAM-AT');
    expect(secondary.silentCalls, isEmpty); // never consulted
  });

  test('silent skips an unavailable broker and is best-effort', () async {
    final unavailable = _UnavailableBroker();
    // Second broker has no silent token → null. Composite must still return
    // null (not throw) so the session falls back to interactive.
    final composite = CompositeBroker([unavailable, FakeBroker()]);

    expect(await composite.acquireSilent(graph), isNull);
    expect(unavailable.silentCalls, 1);
  });

  test('interactive falls through an unavailable broker to the next', () async {
    final unavailable = _UnavailableBroker();
    final loopback = FakeBroker(interactive: (_) => fakeToken('OAUTH-AT'));
    final composite = CompositeBroker([unavailable, loopback]);

    final token = await composite.acquireInteractive(graph);
    expect(token.accessToken, 'OAUTH-AT');
    expect(unavailable.interactiveCalls, 1);
    expect(loopback.interactiveCalls, ['graph']);
  });

  test('interactive stops the chain on a non-unavailable error (e.g. cancel)',
      () async {
    final cancelling = FakeBroker(
      interactive: (_) => throw const AadBrokerException(
        'cancelled',
        code: 'user_cancelled',
      ),
    );
    final loopback = FakeBroker(interactive: (_) => fakeToken('OAUTH-AT'));
    final composite = CompositeBroker([cancelling, loopback]);

    await expectLater(
      composite.acquireInteractive(graph),
      throwsA(isA<AadBrokerException>()
          .having((e) => e.isUserCancelled, 'isUserCancelled', isTrue)),
    );
    // The second broker was never prompted after the cancel.
    expect(loopback.interactiveCalls, isEmpty);
  });
}
