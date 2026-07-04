import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A [SignalRTransport] fake that records the one request it is sent and replays
/// a scripted response — the SignalR counterpart of the cosmos transport fakes.
class _FakeSignalRTransport implements SignalRTransport {
  _FakeSignalRTransport(this._response);

  final SignalRResponse _response;
  final List<SignalRRequest> requests = <SignalRRequest>[];

  @override
  Future<SignalRResponse> send(SignalRRequest request) async {
    requests.add(request);
    return _response;
  }
}

void main() {
  group('ChangeSignal', () {
    test('viewChanged round-trips through JSON with a named shard', () {
      const signal = ChangeSignal.viewChanged(
        generation: 7,
        shard: ShardRef(school: 'GBS', classroom: '3C'),
      );

      final restored = ChangeSignal.fromJson(
        jsonDecode(jsonEncode(signal.toJson())) as Map<String, dynamic>,
      );

      expect(restored, signal);
      expect(restored.kind, ChangeSignalKind.viewChanged);
      expect(restored.generation, 7);
      expect(restored.shard, const ShardRef(school: 'GBS', classroom: '3C'));
      expect(restored.owner, isNull);
    });

    test('a whole-view change carries no shard', () {
      const signal = ChangeSignal.viewChanged(generation: 2);
      expect(signal.shard, isNull);
      expect(signal.toJson().containsKey('shard'), isFalse);
      expect(ChangeSignal.fromJson(signal.toJson()), signal);
    });

    test('syncStarted / syncEnded round-trip with the owner only', () {
      const started = ChangeSignal.syncStarted(owner: 'jan@school');
      const ended = ChangeSignal.syncEnded(owner: 'jan@school');

      expect(ChangeSignal.fromJson(started.toJson()), started);
      expect(ChangeSignal.fromJson(ended.toJson()), ended);
      expect(started.owner, 'jan@school');
      expect(started.generation, isNull);
      expect(started, isNot(ended));
    });

    test('the payload carries identifiers only — no account data', () {
      const signal = ChangeSignal.viewChanged(
        generation: 1,
        shard: ShardRef(accountId: 'p42'),
      );
      // Just kind + generation + the shard identifier; nothing else leaks.
      expect(signal.toJson(), {
        'kind': 'viewChanged',
        'generation': 1,
        'shard': {'accountId': 'p42'},
      });
    });

    test('ShardRef.isWholeView is true only when it names nothing', () {
      expect(const ShardRef().isWholeView, isTrue);
      expect(const ShardRef(school: 'GBS').isWholeView, isFalse);
      expect(const ShardRef(accountId: 'p1').isWholeView, isFalse);
    });
  });

  group('InMemorySignalHub', () {
    test('fans a published signal out to every subscriber', () async {
      final hub = InMemorySignalHub();
      final a = hub.subscriber();
      final b = hub.subscriber();
      final seenA = <ChangeSignal>[];
      final seenB = <ChangeSignal>[];
      a.signals.listen(seenA.add);
      b.signals.listen(seenB.add);

      const signal = ChangeSignal.viewChanged(generation: 3);
      await hub.publisher().publish(signal);
      // Let the broadcast microtasks drain.
      await Future<void>.delayed(Duration.zero);

      expect(seenA, [signal]);
      expect(seenB, [signal]);
      expect(hub.published, [signal]);
    });

    test('a closed subscriber stops receiving and detaches', () async {
      final hub = InMemorySignalHub();
      final a = hub.subscriber();
      final b = hub.subscriber();
      final seenA = <ChangeSignal>[];
      final seenB = <ChangeSignal>[];
      a.signals.listen(seenA.add);
      b.signals.listen(seenB.add);

      await a.close();
      await hub.publisher().publish(const ChangeSignal.syncEnded(owner: 'x'));
      await Future<void>.delayed(Duration.zero);

      expect(seenA, isEmpty, reason: 'a closed subscriber gets nothing');
      expect(seenB, hasLength(1));
    });
  });

  group('SignalRPublisher', () {
    test('posts a :send broadcast with the pinned api-version and bearer token',
        () async {
      final transport =
          _FakeSignalRTransport(const SignalRResponse(statusCode: 202));
      final publisher = SignalRPublisher(
        config: const SignalRConfig(
          // Trailing slash must be tolerated.
          endpoint: 'https://demo.service.signalr.net/',
          hub: 'reconcile',
        ),
        tokens: const StaticSignalRTokenProvider('tok-123'),
        transport: transport,
      );

      const signal = ChangeSignal.viewChanged(generation: 5);
      await publisher.publish(signal);

      expect(transport.requests, hasLength(1));
      final req = transport.requests.single;
      expect(req.method, 'POST');
      expect(
        req.url.toString(),
        'https://demo.service.signalr.net/api/hubs/reconcile/:send'
        '?api-version=$signalRApiVersion',
      );
      expect(req.headers['authorization'], 'Bearer tok-123');
      expect(req.headers['content-type'], 'application/json');
      expect(jsonDecode(req.body!), {
        'target': signalRTarget,
        'arguments': [signal.toJson()],
      });
    });

    test('throws SignalRException on a non-2xx response', () async {
      final transport = _FakeSignalRTransport(
        const SignalRResponse(statusCode: 401, body: 'nope'),
      );
      final publisher = SignalRPublisher(
        config: const SignalRConfig(
          endpoint: 'https://demo.service.signalr.net',
          hub: 'reconcile',
        ),
        tokens: const StaticSignalRTokenProvider('tok'),
        transport: transport,
      );

      expect(
        () => publisher.publish(const ChangeSignal.syncEnded(owner: 'x')),
        throwsA(isA<SignalRException>()),
      );
    });
  });

  group('SignalR negotiate (forward hook)', () {
    test('builds the client negotiate request with the bearer token', () async {
      final req = await signalRNegotiateRequest(
        config: const SignalRConfig(
          endpoint: 'https://demo.service.signalr.net/',
          hub: 'reconcile',
        ),
        tokens: const StaticSignalRTokenProvider('tok'),
      );

      expect(req.method, 'POST');
      expect(
        req.url.toString(),
        'https://demo.service.signalr.net/client/'
        '?hub=reconcile&negotiateVersion=1',
      );
      expect(req.headers['authorization'], 'Bearer tok');
    });

    test('parses a negotiate reply into connection info', () {
      final info = SignalRConnectionInfo.fromResponse(
        SignalRResponse(
          statusCode: 200,
          body: jsonEncode({'url': 'wss://demo/client', 'accessToken': 'ct'}),
        ),
      );
      expect(info.url, 'wss://demo/client');
      expect(info.accessToken, 'ct');
    });

    test('rejects a non-2xx negotiate reply', () {
      expect(
        () => SignalRConnectionInfo.fromResponse(
          const SignalRResponse(statusCode: 403, body: 'denied'),
        ),
        throwsA(isA<SignalRException>()),
      );
    });
  });
}
