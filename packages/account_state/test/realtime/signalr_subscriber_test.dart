import 'dart:async';
import 'dart:convert';

import 'package:account_core/account_core.dart';
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// One framed SignalR message (`json` + the `0x1e` record separator).
String _frame(Map<String, dynamic> message) =>
    jsonEncode(message) + signalRRecordSeparator;

String _signalFrame(ChangeSignal signal) => _frame({
      'type': signalRMessageTypeInvocation,
      'target': signalRTarget,
      'arguments': [signal.toJson()],
    });

/// A negotiate transport that hands back a scripted connection URL + token and
/// counts calls, so a reconnect (a second negotiate) is observable.
class _FakeNegotiateTransport implements SignalRTransport {
  int calls = 0;
  Object? failWith;

  @override
  Future<SignalRResponse> send(SignalRRequest request) async {
    calls++;
    final failure = failWith;
    if (failure != null) throw failure;
    return SignalRResponse(
      statusCode: 200,
      body: jsonEncode({
        'url': 'wss://demo.service.signalr.net/client?hub=reconcile',
        'accessToken': 'ct-$calls',
      }),
    );
  }
}

/// An in-memory [SignalRSocket]: the test pushes server frames in and drops the
/// connection, and asserts on what the subscriber sent.
class _FakeSocket implements SignalRSocket {
  final StreamController<String> _incoming = StreamController<String>();
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void serverSend(String frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
  }

  Future<void> serverDrop() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class _FakeConnector implements SignalRSocketConnector {
  final List<Uri> urls = <Uri>[];
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  Object? failNextWith;

  @override
  Future<SignalRSocket> connect(Uri url) async {
    urls.add(url);
    final failure = failNextWith;
    if (failure != null) {
      failNextWith = null;
      throw failure;
    }
    final socket = _FakeSocket();
    sockets.add(socket);
    return socket;
  }
}

/// A log sink recording only errors, for the reconnect-failure assertions.
class _RecordingLog implements ILog {
  final List<String> errors = <String>[];

  @override
  void addError(Origin origin, String message) => errors.add(message);

  @override
  void addMessage(Origin origin, String message) {}
}

void main() {
  group('SignalR hub protocol', () {
    test('the handshake request selects the JSON protocol, framed', () {
      expect(
        signalRHandshakeRequest,
        '{"protocol":"json","version":1}$signalRRecordSeparator',
      );
    });

    test('the parser splits batched frames and buffers a partial one', () {
      final parser = SignalRMessageParser();
      // Two whole frames plus the start of a third.
      final chunk = '${_frame({'type': 6})}${_frame({'type': 7})}'
          '{"type":1,"target":"signal"';
      expect(parser.add(chunk).toList(), [
        {'type': 6},
        {'type': 7},
      ]);
      // The remainder completes on the next chunk.
      expect(
        parser.add(',"arguments":[]}$signalRRecordSeparator').toList(),
        [
          {'type': 1, 'target': 'signal', 'arguments': <dynamic>[]},
        ],
      );
    });

    test('handshake ack vs. error are told apart', () {
      expect(isSignalRHandshakeSuccess(const {}), isTrue);
      expect(signalRHandshakeError(const {}), isNull);
      expect(isSignalRHandshakeSuccess(const {'error': 'nope'}), isFalse);
      expect(signalRHandshakeError(const {'error': 'nope'}), 'nope');
      // A ping is not a handshake message.
      expect(signalRHandshakeError(const {'type': 6}), isNull);
    });

    test('decodes a signal invocation into a ChangeSignal', () {
      const signal = ChangeSignal.viewChanged(generation: 9);
      final message = {
        'type': signalRMessageTypeInvocation,
        'target': signalRTarget,
        'arguments': [signal.toJson()],
      };
      expect(changeSignalFromMessage(message), signal);
    });

    test('non-signal messages decode to null', () {
      expect(changeSignalFromMessage(const {'type': 6}), isNull);
      expect(
        changeSignalFromMessage(
            const {'type': 1, 'target': 'other', 'arguments': <Object?>[]}),
        isNull,
      );
      expect(
        changeSignalFromMessage(
            const {'type': 1, 'target': 'signal', 'arguments': <Object?>[]}),
        isNull,
      );
    });
  });

  group('SignalRSubscriber', () {
    late _FakeNegotiateTransport transport;
    late _FakeConnector connector;

    const config = SignalRConfig(
        endpoint: 'https://demo.service.signalr.net', hub: 'reconcile');

    setUp(() {
      transport = _FakeNegotiateTransport();
      connector = _FakeConnector();
    });

    SignalRSubscriber build({
      Future<void> Function()? onReconnect,
      ILog? log,
    }) =>
        SignalRSubscriber(
          config: config,
          tokens: const StaticSignalRTokenProvider('tok'),
          transport: transport,
          connector: connector,
          onReconnect: onReconnect,
          reconnectDelay: Duration.zero,
          // Far in the future so the keep-alive never fires during a test.
          pingInterval: const Duration(hours: 1),
          log: log,
        );

    test('negotiates, opens the socket with the token, and handshakes',
        () async {
      final sub = build();
      addTearDown(sub.close);
      sub.signals.listen((_) {});
      await pumpEventQueue();

      expect(transport.calls, 1, reason: 'negotiated once');
      expect(connector.sockets, hasLength(1));
      // The connection token rode in as the access_token query parameter.
      expect(connector.urls.single.queryParameters['access_token'], 'ct-1');
      // The first thing sent is the JSON-protocol handshake.
      expect(connector.sockets.single.sent.first, signalRHandshakeRequest);
    });

    test('surfaces a pushed signal as a ChangeSignal after the handshake',
        () async {
      final sub = build();
      addTearDown(sub.close);
      final received = <ChangeSignal>[];
      sub.signals.listen(received.add);
      await pumpEventQueue();

      final socket = connector.sockets.single;
      socket.serverSend(_frame(const {})); // handshake ack
      socket.serverSend(
          _signalFrame(const ChangeSignal.viewChanged(generation: 4)));
      await pumpEventQueue();

      expect(received, [const ChangeSignal.viewChanged(generation: 4)]);
    });

    test('fires the catch-up hook on connect, before any signal', () async {
      var catchUps = 0;
      final sub = build(onReconnect: () async => catchUps++);
      addTearDown(sub.close);
      sub.signals.listen((_) {});
      await pumpEventQueue();

      // Not yet — the handshake has not been acknowledged.
      expect(catchUps, 0);
      connector.sockets.single.serverSend(_frame(const {}));
      await pumpEventQueue();
      expect(catchUps, 1,
          reason: 'catch-up fires once the handshake completes');
    });

    test('ignores pings and non-signal invocations', () async {
      final sub = build();
      addTearDown(sub.close);
      final received = <ChangeSignal>[];
      sub.signals.listen(received.add);
      await pumpEventQueue();

      final socket = connector.sockets.single;
      socket.serverSend(_frame(const {}));
      socket.serverSend(_frame(const {'type': signalRMessageTypePing}));
      socket.serverSend(_frame(
          const {'type': 1, 'target': 'other', 'arguments': <dynamic>[]}));
      await pumpEventQueue();

      expect(received, isEmpty);
    });

    test('reconnects after the socket drops and re-fires the catch-up',
        () async {
      var catchUps = 0;
      final sub = build(onReconnect: () async => catchUps++);
      addTearDown(sub.close);
      final received = <ChangeSignal>[];
      sub.signals.listen(received.add);
      await pumpEventQueue();

      // First connection: handshake, then the service recycles the socket.
      connector.sockets.single.serverSend(_frame(const {}));
      await pumpEventQueue();
      expect(catchUps, 1);
      await connector.sockets.single.serverDrop();
      await pumpEventQueue();

      // A fresh negotiate + socket came up on its own.
      expect(transport.calls, 2, reason: 're-negotiated on reconnect');
      expect(connector.sockets, hasLength(2));
      expect(connector.sockets.last.sent.first, signalRHandshakeRequest);

      // Catch-up runs again and signals flow over the new socket.
      connector.sockets.last.serverSend(_frame(const {}));
      connector.sockets.last.serverSend(
          _signalFrame(const ChangeSignal.viewChanged(generation: 7)));
      await pumpEventQueue();
      expect(catchUps, 2);
      expect(received, [const ChangeSignal.viewChanged(generation: 7)]);
    });

    test('a failed connect is logged and retried', () async {
      final log = _RecordingLog();
      connector.failNextWith = StateError('socket refused');
      final sub = build(log: log);
      addTearDown(sub.close);
      sub.signals.listen((_) {});
      await pumpEventQueue();

      // The first attempt failed and a second one succeeded.
      expect(log.errors, isNotEmpty);
      expect(log.errors.first, contains('SignalR connection lost'));
      expect(connector.sockets, hasLength(1), reason: 'the retry connected');
    });

    test('close stops the reconnect loop and closes the stream', () async {
      final sub = build();
      var done = false;
      sub.signals.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      final socket = connector.sockets.single;

      await sub.close();
      await pumpEventQueue();

      expect(socket.closed, isTrue, reason: 'the live socket was torn down');
      expect(done, isTrue, reason: 'the signals stream closed');

      // Dropping the (already closed) socket triggers no reconnect.
      final negotiatesBefore = transport.calls;
      await socket.serverDrop();
      await pumpEventQueue();
      expect(transport.calls, negotiatesBefore);
    });
  });
}
