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
/// On top of whatever the caller names, this syncer **always** adds
/// [retainedStaffEmployeeIds] over the snapshot it was handed (#269). Those ids
/// are not the caller's to supply: they come from Azure, not WISA, and the whole
/// point is that they outlive WISA. Without them a staff member's account leaves
/// the app's view on the same pass WISA stops listing them, and the deletion
/// they need is never proposed.
///
/// WISA and Smartschool have no equivalent helper: their syncers are the
/// one-liner `(_) => connector.sync(...)`, written at the wiring site because
/// their per-sync parameters (WISA schools/workdate, the import-rule sets) come
/// from live-config that a later slice folds in.
///
/// [schoolPrefix] is likewise read **at sync time** (#246): the prefix scopes
/// both the bulk `$filter` and the group listing, and the operator can change it
/// in Instellingen while the app runs, so the connector's own
/// `AzureCredentials.schoolPrefix` — frozen when bootstrap built it — must not
/// be the last word. Omit it and the pull is exactly as it shipped before #246.
///
/// **Changing the prefix forces a full read.** `/users/delta` returns the
/// tenant's changes and the walk filters them client-side by prefix, so an
/// incremental pass layers the new prefix's *changes* on top of the previous
/// pass's *old-prefix* user list. The snapshot would then be a mix of two
/// schools that no relink could untangle, and it would persist to the cold store
/// and materialize for everyone. So when the prefix has moved since the last
/// pull this syncer performed, the stored token and previous list are dropped
/// and the pass re-reads in full — the same recovery #213 already makes when
/// Graph refuses a token.
/// [expectedGroupMailNicknames] is the group half of the same idea (#280), and
/// is read at sync time **with the prefix this pass resolved**: the addresses
/// are `<PREFIX>-<KLAS>`, so the callback cannot be handed a frozen prefix any
/// more than the pull itself can. Supply
/// [managedClassGroupMailNicknames] over `app.wisa.snapshot` for the production
/// behaviour. Omit it and the group pull is exactly as it shipped before #280.
Syncer<AzureSnapshot> azureSyncer(
  AzureConnector connector, {
  Iterable<String> Function()? expectedEmployeeIds,
  Iterable<String> Function(String schoolPrefix)? expectedGroupMailNicknames,
  String Function()? schoolPrefix,
}) {
  // The prefix the snapshot in hand was read with. Seeded from the wiring-time
  // value, which is the one the cold seed (if any) was pulled with: bootstrap
  // wires this from the very document it just loaded.
  var pulledWith = schoolPrefix?.call() ?? connector.credentials.schoolPrefix;
  return (previous) {
    final prefix = schoolPrefix?.call() ?? connector.credentials.schoolPrefix;
    final moved = prefix != pulledWith;
    pulledWith = prefix;
    // The snapshot this pass may build on. A moved prefix invalidates all of
    // it — token, users, and the ids remembered from them all describe the
    // *previous* school — so it is dropped whole rather than in pieces.
    final carried = moved ? null : previous;
    return connector.sync(
      deltaToken: carried?.deltaToken,
      previous: carried,
      expectedEmployeeIds: <String>{
        ...?expectedEmployeeIds?.call(),
        ...retainedStaffEmployeeIds(carried, schoolPrefix: prefix),
      },
      expectedGroupMailNicknames:
          expectedGroupMailNicknames?.call(prefix) ?? const <String>[],
      schoolPrefix: prefix,
    );
  };
}

/// The WISA ids of the students in [snapshot] that belong to a school we
/// manage — the ids [azureSyncer] hands the connector as the accounts this pass
/// expects to find in Azure (#224).
///
/// [ourSchoolIds] is the operator's managed-school set from Settings, exactly as
/// handed to `link()`. `null` — like an empty set — means ownership is
/// unconfigured, in which case every WISA student counts, mirroring the
/// linker's own `_isOurWisaSchool` fallback. Scoping matters: a sibling school's
/// student is none of our business, and looking their account up would grow the
/// bounded pull for nothing.
Set<String> managedStudentEmployeeIds(
  WisaSnapshot? snapshot, {
  Set<int>? ourSchoolIds,
}) {
  if (snapshot == null) return const <String>{};
  final effective = ourSchoolIds ?? const <int>{};
  return <String>{
    for (final student in snapshot.students)
      if (effective.isEmpty || effective.contains(student.schoolId))
        if (student.wisaId.value.trim().isNotEmpty) student.wisaId.value.trim(),
  };
}

/// The `<PREFIX>-<KLAS>` addresses this pass expects Office 365 class groups on
/// — the group counterpart of [managedStudentEmployeeIds], and what
/// [azureSyncer] hands the connector so a group Graph already holds under one of
/// them is adopted rather than endlessly proposed for a create (#280).
///
/// Derived from the **students**, not from the class list, and deliberately so:
/// a class with no students of ours gets no Office 365 group proposed
/// (`AzureClassGroupPlan.containsStudents`), so asking Graph about its address
/// would grow a bounded pull for a group nothing would ever create. The bare
/// class name is `WisaStudent.classGroup` — `2F`, never the sub-grouped
/// `2F ECO`, since sub-groups share the parent class's one group.
///
/// [ourSchoolIds] scopes the students exactly as [managedStudentEmployeeIds]
/// does, with the same `null`-means-unconfigured reading. A name that would not
/// survive as a Graph `mailNickname`
/// is dropped, mirroring the plan that would refuse to propose it.
///
/// Names collapse case-insensitively (INV-12) but are asked about as WISA writes
/// them, so the filter Graph receives is the address the app would create.
Set<String> managedClassGroupMailNicknames(
  WisaSnapshot? snapshot, {
  required String schoolPrefix,
  Set<int>? ourSchoolIds,
}) {
  if (snapshot == null || schoolPrefix.trim().isEmpty) return const <String>{};
  final effective = ourSchoolIds ?? const <int>{};
  final byKey = <String, String>{};
  for (final student in snapshot.students) {
    if (effective.isNotEmpty && !effective.contains(student.schoolId)) continue;
    final nickname = core.azureClassGroupName(schoolPrefix, student.classGroup);
    if (nickname == null || !core.isValidMailNickname(nickname)) continue;
    byKey.putIfAbsent(nickname.toLowerCase(), () => nickname);
  }
  return byKey.values.toSet();
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

/// The `employeeId`s of the staff accounts the Azure snapshot **already in
/// hand** holds for our school — the ids [azureSyncer] keeps feeding the
/// back-fill so a staff member who leaves WISA does not take their Office 365
/// account out of the app's view with them (#269).
///
/// [managedStaffEmployeeIds] is derived from the *current* WISA snapshot, so the
/// moment WISA stops listing someone their id leaves that set and the back-fill
/// stops asking about them. For a staff member whose `department` lists our
/// school second in the comma-separated list other software maintains
/// (`SSM,GBS`, #237) that is fatal: the bulk read's server-side
/// `startswith(department, …)` cannot see them either, and #268 ruled that leg
/// cannot be widened — Graph has no `contains`. So the pass that drops them from
/// WISA is the pass their account drops out of the snapshot. No `LinkedStaff`
/// record is built for them, `RemoveStaffFromAzure` (which needs `azure != null`)
/// is never evaluated, and the Office 365 account lives on unmanaged. The failure
/// is not a to-do left visibly undone — the person vanishes from the app.
///
/// The snapshot in hand *is* the memory that closes this, and it costs no new
/// storage: it is persisted after every pull and re-seeded at launch, so the
/// account it already carries names the id to keep asking about. The retention
/// rule is the account itself — an id is remembered while the Azure row still
/// names our school in `department` (INV-22's staff signal, the very rule by
/// which the linker keeps an Azure-only staff record). Once the account is
/// deleted, or another school's software drops our prefix from the list, there is
/// nothing left to remember and the id falls out on its own. No "former staff"
/// state is invented, and nothing is ever remembered forever.
///
/// Only the `department` (staff) signal is read here. A departed *student* is
/// unaffected: the bulk read's `companyName eq '<prefix>'` leg is an equality,
/// not a prefix match, so it keeps returning their account with no help. The
/// group-wide student question is #113.
///
/// Costs nothing on an incremental pass: the accounts are already in the user
/// list the delta builds on, so the connector's back-fill finds them accounted
/// for and issues no lookup. What this is for is the **full read**, which drops
/// that list — a delta token Graph refused (#213), or a walk that left no
/// deltaLink behind. Neither is avoidable: a token expires after 30 days, so any
/// long enough gap between passes forces one, and from then on the account was
/// gone for good. (A first sync has no snapshot to remember from, and a *changed*
/// prefix deliberately drops the memory with everything else — those users belong
/// to the previous school.)
Set<String> retainedStaffEmployeeIds(
  AzureSnapshot? snapshot, {
  required String schoolPrefix,
}) {
  if (snapshot == null) return const <String>{};
  return <String>{
    for (final user in snapshot.users)
      // INV-22's staff signal, from the one definition in `account_core` (#279)
      // — the very rule by which the linker keeps an Azure-only staff record,
      // and by which the connector's client-side reads keep the row at all. A
      // blank prefix matches nobody there, so an unconfigured school remembers
      // nobody rather than the whole snapshot.
      if (core.staffBelongsToSchool(user.department, schoolPrefix))
        if ((user.employeeId ?? '').trim().isNotEmpty) user.employeeId!.trim(),
  };
}
