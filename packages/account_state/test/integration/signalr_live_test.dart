@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// Opt-in live round-trip of the realtime seam against the real Azure SignalR
/// service (issue #124).
///
/// Exercises the production [SignalRSubscriber] end to end — negotiate
/// ([HttpSignalRTransport]) → live WebSocket ([WebSocketSignalRConnector]) →
/// JSON handshake → message framing — by broadcasting a probe [ChangeSignal]
/// through a [SignalRPublisher] and asserting it arrives back over the socket.
/// None of that is provable with a fake transport, which is why it is a live
/// check; the connect/handshake/reconnect *logic* is unit-tested offline.
///
/// It broadcasts to **every** connected operator, so per the repo live-testing
/// policy it is manual/opt-in only (not CI). The probe carries a sentinel
/// generation and no data, and writes nothing to any store. Run it via
/// `/live-tests signalr` (see `.signalr.env.example`), which mints a fresh
/// token for `https://signalr.azure.com`.
///
/// Offline by default: with no `SIGNALR_ACCESS_TOKEN` the config is null and the
/// group is skipped, so `dart test` stays hermetic.
void main() {
  final config = SignalRLiveConfig.fromEnvironment();

  group(
    'Azure SignalR realtime round-trip',
    () {
      test('a broadcast signal arrives over the live subscriber socket',
          () async {
        final signalConfig =
            SignalRConfig(endpoint: config!.endpoint, hub: config.hub);
        final tokens = StaticSignalRTokenProvider(config.accessToken);
        final transport = HttpSignalRTransport();

        // Fires once the WebSocket handshake completes — our cue that the
        // subscriber is connected and will receive a subsequent broadcast.
        final connected = Completer<void>();
        final subscriber = SignalRSubscriber(
          config: signalConfig,
          tokens: tokens,
          transport: transport,
          connector: const WebSocketSignalRConnector(),
          onReconnect: () async {
            if (!connected.isCompleted) connected.complete();
          },
        );

        final received = <ChangeSignal>[];
        final sub = subscriber.signals.listen(received.add);
        try {
          await connected.future.timeout(const Duration(seconds: 30));

          // A sentinel generation so a concurrent real sync's signal is not
          // mistaken for the probe.
          const probe = ChangeSignal.viewChanged(generation: 999999999);
          final publisher = SignalRPublisher(
            config: signalConfig,
            tokens: tokens,
            transport: transport,
          );
          await publisher.publish(probe);

          // Poll briefly for the echo (SignalR delivery is near-instant).
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (
              !received.contains(probe) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(received, contains(probe),
              reason: 'the broadcast came back over the live socket');
        } finally {
          await sub.cancel();
          await subscriber.close();
          transport.close();
        }
      });
    },
    skip: config == null
        ? 'Set SIGNALR_ACCESS_TOKEN (+ SIGNALR_ENDPOINT) to run the live '
            'SignalR round-trip; see .signalr.env.example.'
        : false,
  );
}
