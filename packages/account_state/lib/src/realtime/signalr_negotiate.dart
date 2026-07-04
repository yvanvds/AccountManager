import 'signalr_config.dart';
import 'signalr_token_provider.dart';
import 'signalr_transport.dart';

/// The client-side negotiate request + response, the forward-compatible hook for
/// the persistent WebSocket connection this slice deliberately defers (#116).
///
/// This slice ships the *publish* side (a writer broadcasts) plus the transport
/// seam; the *subscribe* side's live implementation — the negotiate → WebSocket
/// → auto-reconnect loop — is a follow-up. That client first calls SignalR's
/// negotiate endpoint to obtain the actual connection URL and a connection
/// token; [signalRNegotiateRequest] builds that call and
/// [SignalRConnectionInfo] parses its reply. Both are pure so they can be
/// unit-tested now (against a fake [SignalRTransport]) and reused unchanged when
/// the WebSocket loop lands.

/// Builds the SignalR client negotiate request for [config], authenticated with
/// a freshly minted AAD [tokens] bearer token.
///
/// `POST {endpoint}/client/?hub={hub}&negotiateVersion=1` — the endpoint's
/// trailing slash is tolerated.
Future<SignalRRequest> signalRNegotiateRequest({
  required SignalRConfig config,
  required SignalRTokenProvider tokens,
}) async {
  final token = await tokens.signalRAccessToken();
  final base = config.endpoint.endsWith('/')
      ? config.endpoint.substring(0, config.endpoint.length - 1)
      : config.endpoint;
  return SignalRRequest(
    method: 'POST',
    url: Uri.parse(
      '$base/client/'
      '?hub=${Uri.encodeQueryComponent(config.hub)}&negotiateVersion=1',
    ),
    headers: {
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
    },
    body: '',
  );
}

/// The connection info a SignalR negotiate reply carries: the [url] the
/// WebSocket connects to and the [accessToken] it presents.
class SignalRConnectionInfo {
  const SignalRConnectionInfo({required this.url, required this.accessToken});

  final String url;
  final String accessToken;

  /// Parses a negotiate [response]. Throws [SignalRException] on a non-2xx and
  /// [FormatException] when the expected fields are absent.
  factory SignalRConnectionInfo.fromResponse(SignalRResponse response) {
    if (!response.isSuccess) {
      throw SignalRException(response.statusCode, response.body);
    }
    final json = response.json;
    final url = json['url'];
    final accessToken = json['accessToken'];
    if (url is! String || accessToken is! String) {
      throw const FormatException(
        'SignalR negotiate reply missing url/accessToken',
      );
    }
    return SignalRConnectionInfo(url: url, accessToken: accessToken);
  }
}
