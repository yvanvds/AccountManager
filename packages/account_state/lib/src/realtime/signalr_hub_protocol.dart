import 'dart:convert';

import 'change_signal.dart';
import 'signalr_config.dart';

/// The pure SignalR **JSON hub protocol** helpers the live subscriber (#124)
/// speaks over its WebSocket — the negotiate builders' sibling in
/// `signalr_negotiate.dart`, split out so the framing and message decoding are
/// unit-testable with no socket, no service.
///
/// SignalR frames each message as JSON terminated by the ASCII **record
/// separator** `0x1e`; a single WebSocket frame may carry several messages, or
/// split one across frames, so decoding needs the small buffering
/// [SignalRMessageParser] rather than a bare `jsonDecode`. Only the two message
/// shapes this receive-only client cares about are interpreted: the handshake
/// ack and a `signal` invocation; everything else (pings, completions) is
/// recognised and ignored by the subscriber.

/// The ASCII record separator (`0x1e`) SignalR terminates every framed message
/// with.
const String signalRRecordSeparator = '';

/// SignalR hub-protocol message type for an Invocation — a server calling a
/// client method (`target` + `arguments`). The only type carrying a signal.
const int signalRMessageTypeInvocation = 1;

/// SignalR hub-protocol message type for a keep-alive Ping.
const int signalRMessageTypePing = 6;

/// SignalR hub-protocol message type for a Close frame (the server is dropping
/// the connection, optionally with an `error`).
const int signalRMessageTypeClose = 7;

/// The framed handshake request a client sends immediately after the WebSocket
/// opens: it selects the JSON protocol, version 1. The service replies with a
/// framed `{}` on success or `{"error": "..."}` on rejection.
final String signalRHandshakeRequest =
    '${jsonEncode({'protocol': 'json', 'version': 1})}$signalRRecordSeparator';

/// A framed keep-alive ping (`{"type":6}`) the client sends periodically so the
/// service does not drop an otherwise-idle receive-only connection.
final String signalRPingFrame =
    '${jsonEncode({'type': signalRMessageTypePing})}$signalRRecordSeparator';

/// Splits the record-separator-framed SignalR stream into whole JSON messages,
/// buffering any trailing partial frame until the rest arrives.
///
/// A WebSocket text event can batch several framed messages or cut one
/// mid-frame, so [add] appends the chunk to the internal buffer, yields every
/// complete message decoded from JSON, and keeps the remainder for next time.
class SignalRMessageParser {
  final StringBuffer _buffer = StringBuffer();

  /// Feeds one WebSocket text [chunk] in and returns every complete message it
  /// completes, in order. Malformed JSON in a completed frame throws
  /// [FormatException] (a real protocol violation, surfaced not swallowed).
  Iterable<Map<String, dynamic>> add(String chunk) sync* {
    _buffer.write(chunk);
    final combined = _buffer.toString();
    final parts = combined.split(signalRRecordSeparator);
    // The last element is the (possibly empty) unterminated remainder.
    _buffer.clear();
    _buffer.write(parts.removeLast());
    for (final part in parts) {
      if (part.isEmpty) continue;
      final decoded = jsonDecode(part);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('SignalR message was not a JSON object');
      }
      yield decoded;
    }
  }
}

/// Whether [message] is the successful handshake acknowledgement — the first
/// framed reply, an empty object with no `type` and no `error`.
bool isSignalRHandshakeSuccess(Map<String, dynamic> message) =>
    !message.containsKey('type') && message['error'] == null;

/// The rejection reason when [message] is a failed handshake reply
/// (`{"error": "..."}`), or `null` when it is not a handshake error.
String? signalRHandshakeError(Map<String, dynamic> message) {
  if (message.containsKey('type')) return null;
  final error = message['error'];
  return error is String ? error : null;
}

/// Decodes a `signal` invocation [message] into its [ChangeSignal], or returns
/// `null` when the message is not a `signal` invocation (a ping, a completion,
/// or an invocation of some other target this client ignores).
ChangeSignal? changeSignalFromMessage(Map<String, dynamic> message) {
  if (message['type'] != signalRMessageTypeInvocation) return null;
  if (message['target'] != signalRTarget) return null;
  final args = message['arguments'];
  if (args is! List || args.isEmpty) return null;
  final first = args.first;
  if (first is! Map<String, dynamic>) return null;
  return ChangeSignal.fromJson(first);
}
