import 'package:account_manager/src/auth/auth.dart';
import 'package:azure_api/azure_api.dart'
    show AzureAuthException, AzureCredentials;
import 'package:flutter_test/flutter_test.dart';

import 'fake_broker.dart';

void main() {
  final credentials = AzureCredentials(
    clientId: 'client-123',
    tenantId: 'tenant-abc',
    azureDomain: 'school.example',
    schoolPrefix: 'GBS',
  );
  final graph = AadResource.graph(credentials);

  group('acquisition order', () {
    test('returns a silent token without ever prompting', () async {
      final broker = FakeBroker(silent: (_) => fakeToken('SILENT-AT'));
      final session = SignInSession(broker);

      expect(await session.tokenFor(graph), 'SILENT-AT');
      expect(broker.silentCalls, ['graph']);
      expect(broker.interactiveCalls, isEmpty);
      expect(session.account, 'operator@school.example');
      expect(session.isSignedIn, isTrue);
    });

    test('falls back to interactive when silent yields no account', () async {
      final broker = FakeBroker(
        silent: (_) => null,
        interactive: (_) => fakeToken('INTERACTIVE-AT'),
      );
      final session = SignInSession(broker);

      expect(await session.tokenFor(graph), 'INTERACTIVE-AT');
      expect(broker.silentCalls, ['graph']);
      expect(broker.interactiveCalls, ['graph']);
    });
  });

  group('caching', () {
    test('reuses a still-valid token without calling the broker again',
        () async {
      var silentCount = 0;
      final broker = FakeBroker(silent: (_) {
        silentCount++;
        return fakeToken('AT-$silentCount');
      });
      final session = SignInSession(broker);

      expect(await session.tokenFor(graph), 'AT-1');
      expect(await session.tokenFor(graph), 'AT-1');
      expect(silentCount, 1);
    });

    test('re-acquires once the cached token enters the refresh leeway',
        () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final broker = FakeBroker(
        silent: (_) =>
            fakeToken('FRESH', validFor: const Duration(minutes: 3), now: now),
      );
      final session = SignInSession(
        broker,
        refreshLeeway: const Duration(minutes: 5),
        clock: () => now,
      );

      // Token valid for 3 min but leeway is 5 min → treated as expiring, so a
      // second read re-acquires.
      expect(await session.tokenFor(graph), 'FRESH');
      expect(await session.tokenFor(graph), 'FRESH');
      expect(broker.silentCalls.length, 2);

      // Advance past real expiry: still re-acquires.
      now = now.add(const Duration(minutes: 10));
      await session.tokenFor(graph);
      expect(broker.silentCalls.length, 3);
    });

    test('signOut drops the cache so the next read acquires again', () async {
      var count = 0;
      final broker = FakeBroker(silent: (_) => fakeToken('AT-${++count}'));
      final session = SignInSession(broker);

      expect(await session.tokenFor(graph), 'AT-1');
      session.signOut();
      expect(session.isSignedIn, isFalse);
      expect(await session.tokenFor(graph), 'AT-2');
    });
  });

  group('sign in once, then silent for the second resource', () {
    test('interactive is paid at most once across resources', () async {
      // Graph needs interactive (dev laptop); once signed in, Cosmos is silent.
      var signedIn = false;
      final broker = FakeBroker(
        silent: (_) => signedIn ? fakeToken('COSMOS-AT') : null,
        interactive: (_) {
          signedIn = true;
          return fakeToken('GRAPH-AT');
        },
      );
      final session = SignInSession(broker);

      expect(await session.tokenFor(graph), 'GRAPH-AT');
      expect(await session.tokenFor(AadResource.cosmos), 'COSMOS-AT');
      expect(broker.interactiveCalls, ['graph']); // never for cosmos
      expect(broker.silentCalls, ['graph', 'cosmos']);
    });
  });

  group('concurrency', () {
    test('concurrent reads for one resource share a single acquisition',
        () async {
      var silentCount = 0;
      final broker = FakeBroker(silent: (_) {
        silentCount++;
        return fakeToken('AT');
      });
      final session = SignInSession(broker);

      final results =
          await Future.wait([session.tokenFor(graph), session.tokenFor(graph)]);
      expect(results, ['AT', 'AT']);
      expect(silentCount, 1);
    });
  });

  group('seam adapters', () {
    test('GraphSessionAuthProvider returns the Graph token', () async {
      final broker = FakeBroker(silent: (_) => fakeToken('GRAPH-AT'));
      final session = SignInSession(broker);
      final provider = GraphSessionAuthProvider(session, graph);

      expect(await provider.getAccessToken(), 'GRAPH-AT');
      expect(broker.silentCalls, ['graph']);
    });

    test(
        'GraphSessionAuthProvider translates broker failure to '
        'AzureAuthException', () async {
      final broker = FakeBroker(
        silent: (_) => null,
        interactive: (_) => throw const AadBrokerException(
          'cancelled',
          code: 'user_cancelled',
        ),
      );
      final provider = GraphSessionAuthProvider(SignInSession(broker), graph);

      expect(
        () => provider.getAccessToken(),
        throwsA(isA<AzureAuthException>()),
      );
    });

    test('CosmosSessionTokenProvider mints a token for the Cosmos resource',
        () async {
      final broker = FakeBroker(silent: (r) => fakeToken('COSMOS-${r.id}'));
      final session = SignInSession(broker);
      final provider = CosmosSessionTokenProvider(session);

      expect(await provider.cosmosAccessToken(), 'COSMOS-cosmos');
      expect(broker.silentCalls, ['cosmos']);
    });
  });

  group('AadResource', () {
    test('graph keeps only Graph scopes, dropping offline_access/OIDC', () {
      expect(
        graph.scopes,
        containsAll(<String>[
          'https://graph.microsoft.com/User.ReadWrite.All',
          'https://graph.microsoft.com/Group.ReadWrite.All',
        ]),
      );
      expect(graph.scopes, isNot(contains('offline_access')));
    });

    test('graph carries the passwordProfile write permission (#216)', () {
      // The broker asks for exactly these scopes, so the permission that
      // authorises an Office 365 password reset has to travel with them —
      // `User.ReadWrite.All` alone gets a 403 on the passwordProfile write.
      expect(
        graph.scopes,
        contains(
            'https://graph.microsoft.com/User-PasswordProfile.ReadWrite.All'),
      );
    });

    test('cosmos requests the cosmos.azure.com default scope', () {
      expect(AadResource.cosmos.scopes, ['https://cosmos.azure.com/.default']);
    });
  });
}
