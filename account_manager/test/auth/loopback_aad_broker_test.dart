import 'package:account_manager/src/auth/auth.dart';
import 'package:azure_api/azure_api.dart'
    show AzureAuthException, AzureAuthProvider, AzureCredentials;
import 'package:flutter_test/flutter_test.dart';

/// A per-resource auth provider stand-in for [OAuthAuthProvider].
class _FakeProvider implements AzureAuthProvider {
  _FakeProvider(this._result);
  final Object _result; // a String token, or an Exception to throw.
  int calls = 0;

  @override
  Future<String> getAccessToken() async {
    calls++;
    final r = _result;
    if (r is String) return r;
    throw r;
  }
}

void main() {
  final graph = AadResource.graph(AzureCredentials(
    clientId: 'c',
    tenantId: 't',
    azureDomain: 'd',
    schoolPrefix: 'p',
  ));

  test('acquireSilent never prompts — it always returns null', () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) => _FakeProvider('SHOULD-NOT-BE-USED'),
    );
    expect(await broker.acquireSilent(graph), isNull);
  });

  test('acquireInteractive returns the provider token with a future expiry',
      () async {
    final now = DateTime.utc(2026, 1, 1, 12);
    final broker = LoopbackAadBroker(
      providerFactory: (_) => _FakeProvider('AT'),
      assumedLifetime: const Duration(minutes: 50),
      clock: () => now,
    );

    final token = await broker.acquireInteractive(graph);
    expect(token.accessToken, 'AT');
    expect(token.expiresOn, now.add(const Duration(minutes: 50)));
  });

  test('reuses one provider per resource so its cache survives calls',
      () async {
    final providers = <String, _FakeProvider>{};
    final broker = LoopbackAadBroker(
      providerFactory: (r) =>
          providers.putIfAbsent(r.id, () => _FakeProvider('AT')),
    );

    await broker.acquireInteractive(graph);
    await broker.acquireInteractive(graph);
    // Same provider instance both times (built once, then reused).
    expect(providers.length, 1);
    expect(providers['graph']!.calls, 2);
  });

  test('wraps an AzureAuthException as an AadBrokerException', () async {
    final broker = LoopbackAadBroker(
      providerFactory: (_) =>
          _FakeProvider(const AzureAuthException('sign-in was denied')),
    );

    await expectLater(
      broker.acquireInteractive(graph),
      throwsA(isA<AadBrokerException>()
          .having((e) => e.message, 'message', 'sign-in was denied')),
    );
  });
}
