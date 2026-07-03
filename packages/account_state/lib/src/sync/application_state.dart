import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import 'system_state.dart';

/// Root of the orchestration layer's synced state.
///
/// Owns one [SystemState] per system and exposes a single [sync] entry point
/// keyed by [core.Origin], mirroring the legacy `App` singleton's `Wisa` /
/// `Smartschool` / `Azure` sub-states — but as an injectable, pure-Dart object
/// (no singleton, no disk, no WPF observers). The linker and action engine
/// read the three [SystemState.snapshot]s from here; derived state
/// (`LinkedSnapshot`, action lists) is recomputed, never stored on this class
/// (README "persist vs derive").
///
/// The connectors and their per-sync parameters live behind each
/// [SystemState]'s injected [Syncer], so this class stays connector-agnostic
/// and testable against fakes. Wire the Azure state with [azureSyncer] to get
/// the delta-from-day-one behaviour (PAIN-2).
class ApplicationState {
  ApplicationState({
    required this.wisa,
    required this.smartschool,
    required this.azure,
  });

  final SystemState<WisaSnapshot> wisa;
  final SystemState<SmartschoolSnapshot> smartschool;
  final SystemState<AzureSnapshot> azure;

  /// Runs one sync for [system] and returns the fresh snapshot. Replaces the
  /// stored snapshot and stamps `lastSync` only on success; a failure leaves
  /// the previous snapshot intact (domain-model §6.1).
  ///
  /// [system] must be a concrete system ([core.Origin.wisa],
  /// [core.Origin.smartschool], or [core.Origin.azure]); the [core.Origin.all]
  /// and [core.Origin.other] wildcards are not syncable and throw
  /// [ArgumentError].
  Future<core.Snapshot> sync(core.Origin system) {
    switch (system) {
      case core.Origin.wisa:
        return wisa.sync();
      case core.Origin.smartschool:
        return smartschool.sync();
      case core.Origin.azure:
        return azure.sync();
      case core.Origin.all:
      case core.Origin.other:
        throw ArgumentError.value(
          system,
          'system',
          'sync targets a concrete system (wisa/smartschool/azure)',
        );
    }
  }
}

/// Builds the [Syncer] for an [AzureConnector] with the PAIN-2 delta wiring:
/// the first sync (no previous snapshot) does the `$filter`-scoped bulk read
/// and primes a delta token; every later sync passes that token and the
/// previous user list to `/users/delta`, so the app never re-pulls the whole
/// tenant.
///
/// WISA and Smartschool have no equivalent helper: their syncers are the
/// one-liner `(_) => connector.sync(...)`, written at the wiring site because
/// their per-sync parameters (WISA schools/workdate, the import-rule sets) come
/// from live-config that a later slice folds in.
Syncer<AzureSnapshot> azureSyncer(AzureConnector connector) =>
    (previous) => connector.sync(
          deltaToken: previous?.deltaToken,
          previous: previous,
        );
