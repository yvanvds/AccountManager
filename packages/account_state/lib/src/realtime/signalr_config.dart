/// The connection target for the centralized Azure SignalR service (#116).
///
/// Epic #112 pushes change notification over **Azure SignalR (serverless
/// tier)**: an idle WebSocket per operator, nudged by a small per-shard signal a
/// writer posts to the REST/management endpoint. This value type names *where*
/// that service lives — its data-plane endpoint and the hub — and nothing more.
/// Like [CosmosConfig] it carries no credential: authentication is a separate
/// seam (`SignalRTokenProvider`), keeping the AAD-only / no-stored-secret
/// discipline, so the target can round-trip through settings or a log line
/// without leaking anything.
///
/// The concrete endpoint/hub for this deployment are recorded in
/// `docs/port-plan.md`, not hard-coded here, so the library stays independent of
/// any one environment.
class SignalRConfig {
  const SignalRConfig({required this.endpoint, required this.hub});

  /// The service's data-plane endpoint, e.g.
  /// `https://accountmanager-signalr.service.signalr.net`. A trailing slash is
  /// tolerated — the request builders normalize it.
  final String endpoint;

  /// The hub name the operators connect to and the writer broadcasts on, e.g.
  /// `reconcile`.
  final String hub;

  Map<String, dynamic> toJson() => {'endpoint': endpoint, 'hub': hub};

  factory SignalRConfig.fromJson(Map<String, dynamic> json) => SignalRConfig(
        endpoint: json['endpoint'] as String,
        hub: json['hub'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is SignalRConfig && other.endpoint == endpoint && other.hub == hub;

  @override
  int get hashCode => Object.hash(endpoint, hub);

  @override
  String toString() => 'SignalRConfig($endpoint#$hub)';
}

/// The Azure SignalR REST API version the request builders target. Pinned so a
/// service-side default change cannot silently alter the wire contract.
const String signalRApiVersion = '2022-11-01';

/// The single hub method every client listens on and the writer broadcasts to.
///
/// One method carries every [ChangeSignal] kind (the client switches on
/// `kind`), rather than a method per kind — fewer moving parts on the wire and
/// the payload already self-describes.
const String signalRTarget = 'signal';
