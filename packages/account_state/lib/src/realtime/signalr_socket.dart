import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// The duplex-WebSocket seam the live [SignalRSubscriber] talks through (#124),
/// abstracted exactly the way [SignalRTransport] abstracts the REST calls: the
/// subscriber's negotiate → handshake → parse → auto-reconnect orchestration is
/// unit-testable against an in-memory fake socket, while the one thin adapter
/// that actually opens an Azure SignalR WebSocket ([WebSocketSignalRSocket]) is
/// the only part that needs the live service.
///
/// Text-only: SignalR's JSON hub protocol frames are UTF-8 text, so [messages]
/// surfaces decoded strings and [send] takes a string.
abstract interface class SignalRSocket {
  /// Incoming text frames. Completes (via `onDone`) or errors when the
  /// connection closes — which is the subscriber's cue to reconnect.
  Stream<String> get messages;

  /// Sends one text frame (a framed SignalR message).
  void send(String data);

  /// Closes the connection. Idempotent — safe to call more than once.
  Future<void> close();
}

/// Opens a [SignalRSocket] to the negotiated client URL.
///
/// Production wires [WebSocketSignalRConnector]; tests inject a fake that hands
/// back a scripted in-memory socket, so the whole subscriber loop runs with no
/// network.
abstract interface class SignalRSocketConnector {
  /// Connects to [url] (the negotiate reply's URL, with the connection access
  /// token already appended as the `access_token` query parameter).
  Future<SignalRSocket> connect(Uri url);
}

/// The default [SignalRSocketConnector], backed by `package:web_socket_channel`.
/// The only class in the realtime layer that touches a live WebSocket.
class WebSocketSignalRConnector implements SignalRSocketConnector {
  const WebSocketSignalRConnector();

  @override
  Future<SignalRSocket> connect(Uri url) async {
    final channel = WebSocketChannel.connect(url);
    // Surface a failed opening handshake here rather than as a late stream
    // error, so the subscriber's connect attempt fails cleanly and retries.
    await channel.ready;
    return WebSocketSignalRSocket(channel);
  }
}

/// A [SignalRSocket] wrapping a live [WebSocketChannel]. Binary frames (which
/// the JSON protocol never uses, but a server could send) are UTF-8 decoded so
/// [messages] is uniformly text.
class WebSocketSignalRSocket implements SignalRSocket {
  WebSocketSignalRSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.map(
        (event) => event is String
            ? event
            : utf8.decode((event as List<int>).cast<int>()),
      );

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}
