import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart';
import 'package:account_linker/account_linker.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../sync/application_state.dart';
import 'azure_class_groups.dart';
import 'placement.dart';

/// The State layer's **derived** view of one link+dispatch pass: the pure
/// [LinkedSnapshot] plus the per-family action lists the UI renders.
///
/// Ties the three layers together (spec `docs/domain-model.md` §6.2–§6.4):
/// the pure `link()` reconciles the current connector snapshots, then the
/// action dispatchers derive the applicable actions — with the membership- and
/// tree-dependent ones wired through a [PlacementResolver] so
/// `MoveToSmartschoolClassGroup`, the placement step in `AddStudentToSmartschool`,
/// and the group `AddToSmartschool` / `CreateInSmartschool` actions are
/// considered (#55 / #65).
///
/// **Transient in-RAM view.** This is recomputed from the snapshots on demand
/// by the session that runs a sync; rebuild it with [LinkedState.fromApplication]
/// (or [LinkedState.recompute]) whenever a sync replaces a snapshot. Its
/// *materialized* form — the shared, versioned per-account documents + rollups a
/// passive session reads without pulling or re-linking — is produced by
/// `materialize()` and written through the `LinkedStore` (#115, keystone of
/// #112). This corrects the earlier "the linked view is never persisted" stance
/// (legacy `LinkedState.SaveContent` deliberately threw): the *derived* view is
/// now shared state, even though this transient object still carries the live
/// action objects the apply pass drives.
class LinkedState {
  const LinkedState({
    required this.snapshot,
    required this.studentActions,
    required this.staffActions,
    required this.groupActions,
  });

  /// The reconciled output of `link()` over the three current snapshots.
  final LinkedSnapshot snapshot;

  /// Applicable student actions, in snapshot order, with class placement wired.
  final List<actions.StudentAction> studentActions;

  /// Applicable staff actions, in snapshot order. Staff carry no placement
  /// (their Office 365 group actions are out of the port's scope), so this is a
  /// plain dispatch — included here so [LinkedState] is the one derived view of
  /// every family, not just the placement-bearing two.
  final List<actions.StaffAction> staffActions;

  /// Applicable group actions, in snapshot order, with group placement wired.
  final List<actions.GroupAction> groupActions;

  /// Recomputes the linked view from three concrete snapshots.
  ///
  /// Runs the pure `link()` (scoped by the shared `schoolPrefix` the
  /// [studentConfig] / [staffConfig] carry) and then the three dispatchers,
  /// binding a [PlacementResolver] built from the WISA + Smartschool snapshots
  /// and the injected [classTree] to the student and group `placementFor`
  /// callbacks.
  ///
  /// [ourSchoolIds] is the set of WISA school ids the operator actually manages
  /// (from the persisted `AppSettings.wisaSchools` ownership flags, #178). It is
  /// threaded into `link()` so `wisaPresence` is authoritative from Settings
  /// rather than only the snapshot's `MarkAsOurs` flags, **and** into the
  /// [PlacementResolver] so "does this class hold students?" counts only the
  /// students of a school we manage (#222) — the two must agree, since the
  /// linker seeds a class group only for a managed school (#205). When null,
  /// both fall back to those snapshot flags (see their doc-comments).
  factory LinkedState.recompute({
    required wapi.WisaSnapshot wisa,
    required ss.SmartschoolSnapshot smartschool,
    required az.AzureSnapshot azure,
    required PersonIdResolver resolver,
    required actions.StudentActionConfig studentConfig,
    required actions.StaffActionConfig staffConfig,
    SmartschoolClassTree classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
  }) {
    assert(
      studentConfig.schoolPrefix == staffConfig.schoolPrefix,
      'student/staff configs must share the school prefix the linker scopes by',
    );

    final snapshot = link(
      wisa,
      smartschool,
      azure,
      resolver,
      schoolPrefix: studentConfig.schoolPrefix,
      ourSchoolIds: ourSchoolIds,
    );

    final placements = PlacementResolver(
      wisa: wisa,
      smartschool: smartschool,
      classTree: classTree,
      ourSchoolIds: ourSchoolIds,
    );

    // The Office 365 class-group plans are derived from the *linked* view, not
    // the raw snapshots (#228): the roster is expressed as Azure object ids, and
    // the `wisaId ≡ employeeId` bridge that produces them is the linker's. The
    // same resolver feeds the per-student view of that membership (#245), so
    // the class row and the account row read one set of facts.
    final azureClassGroups = AzureClassGroupResolver(
      linked: snapshot,
      schoolPrefix: studentConfig.schoolPrefix,
      studentDomain: studentConfig.studentDomain,
    );

    return LinkedState(
      snapshot: snapshot,
      studentActions: actions.studentActions(
        snapshot,
        studentConfig,
        placementFor: placements.classPlacementFor,
        azurePlacementFor: azureClassGroups.placementFor,
      ),
      staffActions: actions.staffActions(snapshot, staffConfig),
      groupActions: actions.groupActions(
        snapshot,
        placementFor: placements.groupPlacementFor,
        azurePlanFor: azureClassGroups.planFor,
      ),
    );
  }

  /// The async counterpart of [LinkedState.recompute] for a
  /// [PreparablePersonIdResolver] (the DB-backed [CosmosPersonIdResolver]).
  ///
  /// A network-backed resolver cannot mint inside the synchronous pure `link()`,
  /// so its id map is populated up front: this computes the exact key set with
  /// `naturalKeysFor` (over the same snapshots and `schoolPrefix` the linker
  /// uses) and awaits `resolver.prepare(keys)` before delegating to the
  /// synchronous [recompute]. A plain [PersonIdResolver] (file/in-memory) is not
  /// preparable and mints lazily, so it skips the prepare step and this behaves
  /// exactly like [recompute].
  static Future<LinkedState> recomputeAsync({
    required wapi.WisaSnapshot wisa,
    required ss.SmartschoolSnapshot smartschool,
    required az.AzureSnapshot azure,
    required PersonIdResolver resolver,
    required actions.StudentActionConfig studentConfig,
    required actions.StaffActionConfig staffConfig,
    SmartschoolClassTree classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
  }) async {
    if (resolver is PreparablePersonIdResolver) {
      final keys = naturalKeysFor(
        wisa,
        smartschool,
        azure,
        schoolPrefix: studentConfig.schoolPrefix,
      );
      await resolver.prepare(keys);
    }
    return LinkedState.recompute(
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      resolver: resolver,
      studentConfig: studentConfig,
      staffConfig: staffConfig,
      classTree: classTree,
      ourSchoolIds: ourSchoolIds,
    );
  }

  /// Recomputes the linked view from an [ApplicationState]'s current snapshots.
  ///
  /// Throws a [StateError] when any system has not synced yet (its snapshot is
  /// still `null`): linking needs all three views, mirroring how the legacy
  /// dashboard only re-linked after the syncs had run.
  factory LinkedState.fromApplication(
    ApplicationState app, {
    required PersonIdResolver resolver,
    required actions.StudentActionConfig studentConfig,
    required actions.StaffActionConfig staffConfig,
    SmartschoolClassTree classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
  }) {
    final (wisa, smartschool, azure) = _syncedSnapshots(app);
    return LinkedState.recompute(
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      resolver: resolver,
      studentConfig: studentConfig,
      staffConfig: staffConfig,
      classTree: classTree,
      ourSchoolIds: ourSchoolIds,
    );
  }

  /// The async counterpart of [LinkedState.fromApplication] for a
  /// [PreparablePersonIdResolver]: same "every system must have synced" guard,
  /// then delegates to [recomputeAsync] so a DB-backed resolver is prepared
  /// before linking. Use this (not [fromApplication]) whenever the resolver may
  /// be network-backed.
  static Future<LinkedState> fromApplicationAsync(
    ApplicationState app, {
    required PersonIdResolver resolver,
    required actions.StudentActionConfig studentConfig,
    required actions.StaffActionConfig staffConfig,
    SmartschoolClassTree classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
  }) async {
    final (wisa, smartschool, azure) = _syncedSnapshots(app);
    return recomputeAsync(
      wisa: wisa,
      smartschool: smartschool,
      azure: azure,
      resolver: resolver,
      studentConfig: studentConfig,
      staffConfig: staffConfig,
      classTree: classTree,
      ourSchoolIds: ourSchoolIds,
    );
  }

  /// Returns [app]'s three current snapshots, or throws a [StateError] when any
  /// system has not synced yet — linking needs all three views, mirroring how
  /// the legacy dashboard only re-linked after the syncs had run.
  static (wapi.WisaSnapshot, ss.SmartschoolSnapshot, az.AzureSnapshot)
      _syncedSnapshots(ApplicationState app) {
    final wisa = app.wisa.snapshot;
    final smartschool = app.smartschool.snapshot;
    final azure = app.azure.snapshot;
    if (wisa == null || smartschool == null || azure == null) {
      throw StateError(
        'Cannot link before every system has synced at least once '
        '(wisa: ${wisa != null}, smartschool: ${smartschool != null}, '
        'azure: ${azure != null}).',
      );
    }
    return (wisa, smartschool, azure);
  }
}
