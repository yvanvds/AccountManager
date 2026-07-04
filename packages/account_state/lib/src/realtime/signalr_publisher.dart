import 'dart:convert';

import 'change_signal.dart';
import 'signal_channel.dart';
import 'signalr_config.dart';
import 'signalr_token_provider.dart';
import 'signalr_transport.dart';

/// The production [SignalPublisher]: posts a [ChangeSignal] to Azure SignalR's
/// REST/management endpoint so every connected operator is nudged (#116).
///
/// This is the *fat-client* publisher the issue settles on — the session that
/// performed the write broadcasts, fitting the current model where every desktop
/// runs the connectors and can sync. It builds the `:send` broadcast request
/// (URL + pinned api-version + `{target, arguments}` payload) and authenticates
/// with the operator's own AAD identity via [SignalRTokenProvider] — no stored
/// access key. Only the request/payload building is exercised in CI (against a
/// fake [SignalRTransport]); the live HTTPS send is the thin part, like the
/// other `Http*Transport` wrappers.
///
/// A failed broadcast throws [SignalRException]; the orchestration layer treats
/// every publish as best-effort and swallows it, because the stored `generation`
/// marker — not the signal — is what a client falls back to.
class SignalRPublisher implements SignalPublisher {
  SignalRPublisher({
    required SignalRConfig config,
    required SignalRTokenProvider tokens,
    required SignalRTransport transport,
  })  : _config = config,
        _tokens = tokens,
        _transport = transport;

  final SignalRConfig _config;
  final SignalRTokenProvider _tokens;
  final SignalRTransport _transport;

  @override
  Future<void> publish(ChangeSignal signal) async {
    final token = await _tokens.signalRAccessToken();
    final response = await _transport.send(
      SignalRRequest(
        method: 'POST',
        url: _broadcastUrl(),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'target': signalRTarget,
          'arguments': [signal.toJson()],
        }),
      ),
    );
    if (!response.isSuccess) {
      throw SignalRException(response.statusCode, response.body);
    }
  }

  /// `{endpoint}/api/hubs/{hub}/:send?api-version=…` — the broadcast-to-all
  /// route, with the trailing slash on the endpoint tolerated.
  Uri _broadcastUrl() {
    final base = _config.endpoint.endsWith('/')
        ? _config.endpoint.substring(0, _config.endpoint.length - 1)
        : _config.endpoint;
    return Uri.parse(
      '$base/api/hubs/${Uri.encodeComponent(_config.hub)}/:send'
      '?api-version=$signalRApiVersion',
    );
  }
}
