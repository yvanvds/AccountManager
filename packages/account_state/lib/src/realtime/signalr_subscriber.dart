import 'dart:async';

import 'package:account_core/account_core.dart' as core;

import 'change_signal.dart';
import 'signal_channel.dart';
import 'signalr_config.dart';
import 'signalr_hub_protocol.dart';
import 'signalr_negotiate.dart';
import 'signalr_socket.dart';
import 'signalr_token_provider.dart';
import 'signalr_transport.dart';

/// The production [SignalSubscriber] (#124): a persistent Azure SignalR client
/// that turns pushed `signal` hub messages into [ChangeSignal]s on
/// [signals], with an auto-reconnect loop — the receive half of the realtime
/// seam whose publish half shipped in #116.
///
/// Each connection attempt: call the client negotiate endpoint
/// ([signalRNegotiateRequest] over the injected [SignalRTransport]) to obtain
/// the WebSocket URL + connection token, open the socket (via the injected
/// [SignalRSocketConnector]), send the JSON-protocol handshake, then surface
/// every `signal` invocation as a [ChangeSignal]. When the socket drops, it
/// waits [reconnectDelay] and negotiates afresh — a token expiry or a service
/// recycle self-heals.
///
/// **Catch-up on (re)connect.** A client that was disconnected while a writer
/// broadcast has no signal to replay, so on *every* successful connect it fires
/// [onReconnect]. Bootstrap wires that to re-read the shared store: the signal
/// is only the nudge, the store's `generation` marker is the source of truth,
/// and the controller's `onStoreChanged` refetches only when it actually
/// advanced — so a caught-up client does no redundant work and a client that
/// missed a message still converges.
///
/// The connect/handshake/reconnect *logic* is fully exercised against a fake
/// socket in CI; only the live Azure WebSocket is manual (`/live-tests
/// signalr`), like the other `Http*` transports.
class SignalRSubscriber implements SignalSubscriber {
  SignalRSubscriber({
    required SignalRConfig config,
    required SignalRTokenProvider tokens,
    required SignalRTransport transport,
    required SignalRSocketConnector connector,
    Future<void> Function()? onReconnect,
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration pingInterval = const Duration(seconds: 15),
    core.ILog? log,
  })  : _config = config,
        _tokens = tokens,
        _transport = transport,
        _connector = connector,
        _onReconnect = onReconnect,
        _reconnectDelay = reconnectDelay,
        _pingInterval = pingInterval,
        _log = log;

  final SignalRConfig _config;
  final SignalRTokenProvider _tokens;
  final SignalRTransport _transport;
  final SignalRSocketConnector _connector;
  final Future<void> Function()? _onReconnect;
  final Duration _reconnectDelay;
  final Duration _pingInterval;
  final core.ILog? _log;

  final StreamController<ChangeSignal> _out =
      StreamController<ChangeSignal>.broadcast();

  bool _closed = false;
  bool _running = false;
  SignalRSocket? _socket;
  StreamSubscription<String>? _socketSub;
  Timer? _pingTimer;
  Completer<void>? _connectionClosed;

  /// The incoming signals. A broadcast stream; the connection is opened lazily
  /// on the first listen and kept up (reconnecting) until [close].
  @override
  Stream<ChangeSignal> get signals {
    _ensureRunning();
    return _out.stream;
  }

  void _ensureRunning() {
    if (_running || _closed) return;
    _running = true;
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    while (!_closed) {
      try {
        await _connectOnce();
      } on Object catch (e) {
        // Kept as an error, and therefore Dutch (#266): the operator can do
        // nothing about the transport itself, but losing the live channel is
        // why another operator's sync stops showing up here — so the panel has
        // to say it in the language the rest of the pass speaks.
        _log?.addError(core.Origin.all, 'SignalR-verbinding verbroken: $e');
      }
      if (_closed) break;
      await Future<void>.delayed(_reconnectDelay);
    }
  }

  Future<void> _connectOnce() async {
    final request =
        await signalRNegotiateRequest(config: _config, tokens: _tokens);
    final info = SignalRConnectionInfo.fromResponse(
      await _transport.send(request),
    );
    final socket = await _connector.connect(_socketUrl(info));
    _socket = socket;

    final parser = SignalRMessageParser();
    final closed = Completer<void>();
    _connectionClosed = closed;
    var handshaken = false;

    void complete([Object? error]) {
      if (closed.isCompleted) return;
      error == null ? closed.complete() : closed.completeError(error);
    }

    _socketSub = socket.messages.listen(
      (data) {
        try {
          for (final message in parser.add(data)) {
            if (!handshaken) {
              final error = signalRHandshakeError(message);
              if (error != null) {
                complete(SignalRException(0, 'handshake rejected: $error'));
                return;
              }
              if (isSignalRHandshakeSuccess(message)) {
                handshaken = true;
                _fireCatchUp();
              }
              continue;
            }
            if (message['type'] == signalRMessageTypeClose) {
              complete();
              return;
            }
            final signal = changeSignalFromMessage(message);
            if (signal != null && !_out.isClosed) _out.add(signal);
          }
        } on Object catch (e) {
          complete(e);
        }
      },
      onError: complete,
      onDone: complete,
      cancelOnError: true,
    );

    socket.send(signalRHandshakeRequest);
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      try {
        socket.send(signalRPingFrame);
      } on Object {
        // A failed ping just means the socket is going; the stream's onDone
        // drives the reconnect.
      }
    });

    try {
      await closed.future;
    } finally {
      _pingTimer?.cancel();
      _pingTimer = null;
      await _socketSub?.cancel();
      _socketSub = null;
      _connectionClosed = null;
      await socket.close();
      if (identical(_socket, socket)) _socket = null;
    }
  }

  /// Fires the reconnect catch-up hook without blocking message delivery; a
  /// failure is logged, never thrown into the socket loop.
  void _fireCatchUp() {
    final onReconnect = _onReconnect;
    if (onReconnect == null) return;
    unawaited(() async {
      try {
        await onReconnect();
      } on Object catch (e) {
        // The wording `ReconcileController` already uses for exactly this
        // failure ("Kon niet bijwerken na het herverbinden: …", #258).
        _log?.addError(
          core.Origin.all,
          'SignalR: kon niet bijwerken na het herverbinden: $e',
        );
      }
    }());
  }

  /// The negotiate reply's URL with the connection token appended as the
  /// `access_token` query parameter — how a browser-style SignalR client
  /// presents its token over a WebSocket (no Authorization header).
  Uri _socketUrl(SignalRConnectionInfo info) {
    final base = Uri.parse(info.url);
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'access_token': info.accessToken,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    // Unblock any in-flight connect so the loop sees _closed and stops.
    final connection = _connectionClosed;
    if (connection != null && !connection.isCompleted) connection.complete();
    await _socketSub?.cancel();
    _socketSub = null;
    await _socket?.close();
    _socket = null;
    if (!_out.isClosed) await _out.close();
  }
}
