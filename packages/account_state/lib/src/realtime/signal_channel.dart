import 'dart:async';

import 'change_signal.dart';

/// The **publish** side of the realtime seam (#116): a writer posts a
/// [ChangeSignal] so every connected operator is nudged.
///
/// Kept an interface — mirroring the other persistence seams in this package —
/// so the orchestration layer publishes through it without knowing whether the
/// signal goes to Azure SignalR (`SignalRPublisher`) or, in tests and headless
/// runs, into an [InMemorySignalHub]. Publishing is best-effort by contract: a
/// failed push must not fail the write that triggered it, because the stored
/// `generation` marker — not the signal — is the source of truth a client falls
/// back to.
abstract interface class SignalPublisher {
  /// Fans [signal] out to every connected client. May throw on a transport
  /// failure; callers treat a publish as best-effort and swallow that.
  Future<void> publish(ChangeSignal signal);
}

/// The **subscribe** side of the realtime seam (#116): a client holds an idle
/// connection and receives every [ChangeSignal] a writer publishes.
///
/// The production implementation is a persistent Azure SignalR WebSocket
/// connection (the negotiate → connect → reconnect loop is the follow-up to this
/// slice — see `signalr_negotiate.dart`); tests and headless runs use an
/// [InMemorySignalHub]. A client that missed a message while disconnected still
/// self-heals: on reconnect it compares its cached generation against the store.
abstract interface class SignalSubscriber {
  /// The stream of incoming signals. A broadcast stream, so more than one
  /// listener (e.g. the controller plus a diagnostic) can attach.
  Stream<ChangeSignal> get signals;

  /// Tears the subscription down (closes the underlying connection / stream).
  Future<void> close();
}

/// An in-memory [SignalPublisher] + [SignalSubscriber] fan-out for tests and
/// headless runs — the realtime counterpart of `InMemoryLinkedStore`.
///
/// Models Azure SignalR's broadcast: a signal published through [publisher]
/// reaches **every** subscriber [subscriber] handed out, including one owned by
/// the very session that published it (SignalR echoes to the sender too). That
/// self-echo is intentional in the fake — it lets a test assert the receiving
/// controller's guards ignore its own signals — and it mirrors production, where
/// a writer filters its own owner/generation out rather than relying on the
/// transport to exclude it.
class InMemorySignalHub {
  final List<ChangeSignal> _published = <ChangeSignal>[];
  final List<StreamController<ChangeSignal>> _subscribers =
      <StreamController<ChangeSignal>>[];

  /// Every signal published through this hub, in order — for test assertions.
  List<ChangeSignal> get published => List.unmodifiable(_published);

  /// A publisher bound to this hub. All publishers share the one fan-out.
  SignalPublisher publisher() => _HubPublisher(this);

  /// A fresh subscriber bound to this hub. Each gets its own broadcast stream;
  /// closing one leaves the others live.
  SignalSubscriber subscriber() {
    final controller = StreamController<ChangeSignal>.broadcast();
    _subscribers.add(controller);
    controller.onCancel = () => _subscribers.remove(controller);
    return _HubSubscriber(controller, () => _subscribers.remove(controller));
  }

  void _fanOut(ChangeSignal signal) {
    _published.add(signal);
    // Snapshot: a listener that closes on receipt must not mutate mid-iteration.
    for (final c in List.of(_subscribers)) {
      if (!c.isClosed) c.add(signal);
    }
  }
}

class _HubPublisher implements SignalPublisher {
  _HubPublisher(this._hub);

  final InMemorySignalHub _hub;

  @override
  Future<void> publish(ChangeSignal signal) async => _hub._fanOut(signal);
}

class _HubSubscriber implements SignalSubscriber {
  _HubSubscriber(this._controller, this._detach);

  final StreamController<ChangeSignal> _controller;
  final void Function() _detach;

  @override
  Stream<ChangeSignal> get signals => _controller.stream;

  @override
  Future<void> close() async {
    _detach();
    await _controller.close();
  }
}
