import 'dart:io';

/// Configuration for the opt-in Azure SignalR live check
/// (`test/integration/signalr_live_test.dart`, issue #124).
///
/// The check exercises the real realtime seam end to end against the
/// provisioned service: mint a bearer token for `https://signalr.azure.com`,
/// open a live [SignalRSubscriber] WebSocket (negotiate → handshake →
/// auto-reconnect), then broadcast a probe [ChangeSignal] through a
/// [SignalRPublisher] and assert it comes back over the socket — the one path a
/// fake transport cannot prove.
///
/// It broadcasts to *every* connected operator, so per the repo live-testing
/// policy it is **write-capable**, manual/opt-in only (never CI): the probe
/// signal carries a sentinel generation and no data, and it changes nothing in
/// any store.
///
/// Offline unit tests never read this. See `.signalr.env.example` at the
/// repository root for the variable names.
class SignalRLiveConfig {
  const SignalRLiveConfig({
    required this.endpoint,
    required this.hub,
    required this.accessToken,
  });

  /// The service data-plane endpoint under test, e.g.
  /// `https://accountmanager-signalr.service.signalr.net`.
  final String endpoint;

  /// The hub operators connect to and writers broadcast on, e.g. `reconcile`.
  final String hub;

  /// A pre-acquired bearer token for `https://signalr.azure.com`. Expires in
  /// ~1 hour, so it is minted fresh per run rather than stored (e.g.
  /// `az account get-access-token --resource https://signalr.azure.com`).
  final String accessToken;

  /// Names of the environment variables, in canonical order.
  static const List<String> envVarNames = [
    'SIGNALR_ENDPOINT',
    'SIGNALR_HUB',
    'SIGNALR_ACCESS_TOKEN',
  ];

  /// Reads config from environment variables (defaulting to
  /// `Platform.environment`). Returns `null` when `SIGNALR_ACCESS_TOKEN` is
  /// empty or missing — the integration test uses this as its skip signal, so
  /// `dart test` stays offline by default. `SIGNALR_HUB` defaults to
  /// `reconcile` when unset.
  ///
  /// Throws [ArgumentError] when `SIGNALR_ACCESS_TOKEN` is set but
  /// `SIGNALR_ENDPOINT` is missing.
  static SignalRLiveConfig? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final accessToken = (source['SIGNALR_ACCESS_TOKEN'] ?? '').trim();
    if (accessToken.isEmpty) return null;

    final endpoint = (source['SIGNALR_ENDPOINT'] ?? '').trim();
    if (endpoint.isEmpty) {
      throw ArgumentError(
        'SIGNALR_ACCESS_TOKEN is set but SIGNALR_ENDPOINT is missing or empty.',
      );
    }
    final hub = (source['SIGNALR_HUB'] ?? '').trim();

    return SignalRLiveConfig(
      endpoint: endpoint,
      hub: hub.isEmpty ? 'reconcile' : hub,
      accessToken: accessToken,
    );
  }
}
