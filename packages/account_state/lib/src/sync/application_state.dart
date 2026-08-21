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
/// [expectedEmployeeIds] is read **at sync time** (hence a callback, not a
/// value): it names the WISA ids this pass expects Azure accounts for, so the
/// connector can look up by `employeeId` the ones the prefix-scoped read did not
/// turn up (#224). Reading it lazily is what lets the wiring site point it at
/// the WISA snapshot the same [ApplicationState] pulled moments earlier — WISA
/// always syncs before Azure in a pass. Supply the union of
/// [managedStudentEmployeeIds] and [managedStaffEmployeeIds] over
/// `app.wisa.snapshot` for the production behaviour — both populations transfer
/// between the group's schools, and both are invisible to the prefix-scoped
/// read afterwards (#224 students, #231 staff). Omit it and the pull is exactly
/// as it shipped before #224.
///
/// WISA and Smartschool have no equivalent helper: their syncers are the
/// one-liner `(_) => connector.sync(...)`, written at the wiring site because
/// their per-sync parameters (WISA schools/workdate, the import-rule sets) come
/// from live-config that a later slice folds in.
Syncer<AzureSnapshot> azureSyncer(
  AzureConnector connector, {
  Iterable<String> Function()? expectedEmployeeIds,
}) =>
    (previous) => connector.sync(
          deltaToken: previous?.deltaToken,
          previous: previous,
          expectedEmployeeIds: expectedEmployeeIds?.call() ?? const <String>[],
        );

/// The WISA ids of the students in [snapshot] that belong to a school we
/// manage — the ids [azureSyncer] hands the connector as the accounts this pass
/// expects to find in Azure (#224).
///
/// [ourSchoolIds] is the operator's managed-school set from Settings, exactly as
/// handed to `link()`. `null` falls back to the snapshot's own
/// `WisaSchool.isOurs` flags, and an empty effective set means ownership is
/// unconfigured — in which case every WISA student counts, mirroring the
/// linker's own `_isOurWisaSchool` fallback. Scoping matters: a sibling school's
/// student is none of our business, and looking their account up would grow the
/// bounded pull for nothing.
Set<String> managedStudentEmployeeIds(
  WisaSnapshot? snapshot, {
  Set<int>? ourSchoolIds,
}) {
  if (snapshot == null) return const <String>{};
  final effective = ourSchoolIds ??
      <int>{
        for (final school in snapshot.schools)
          if (school.isOurs) school.id,
      };
  return <String>{
    for (final student in snapshot.students)
      if (effective.isEmpty || effective.contains(student.schoolId))
        if (student.wisaId.value.trim().isNotEmpty) student.wisaId.value.trim(),
  };
}

/// The WISA ids of the staff in [snapshot] — the personeel half of the ids
/// [azureSyncer] hands the connector, and the staff counterpart of
/// [managedStudentEmployeeIds] (#231).
///
/// A staff member who moves in from a sibling group school leaves the same
/// wreckage a transferred student does: the Office 365 account already exists
/// and carries their WISA id as `employeeId`, but its `department` still names
/// the school they came from, so neither leg of the connector's `$filter`
/// matches it and the app proposed creating a second one.
///
/// Unlike [managedStudentEmployeeIds] there is nothing to scope by: the
/// `SmaSyncPer` pull carries no school id per staff row, so every staff member
/// it returned is one this pass expects an account for. `wisaId` is **nullable**
/// on a staff row (`code` is the staff primary key, spec §3.4 / OQ-1); a member
/// without one is dropped, since `wisaId ≡ employeeId` is the only Azure bridge
/// the linker has for staff and there is nothing to look up.
Set<String> managedStaffEmployeeIds(WisaSnapshot? snapshot) {
  if (snapshot == null) return const <String>{};
  return <String>{
    for (final member in snapshot.staff)
      if ((member.wisaId?.value.trim() ?? '').isNotEmpty)
        member.wisaId!.value.trim(),
  };
}
