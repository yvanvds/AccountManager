import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;

import '../link/linked_state.dart';
import '../link/placement.dart';
import '../sync/application_state.dart';
import 'wisa_import_rules.dart';

/// The outcome of driving one action's `apply()` through the State layer.
///
/// Carries the action's own [ActionResult] plus, **only when a real write
/// happened**, the recomputed [linked] view — the State layer patched the
/// in-memory snapshot from the mutated record and re-ran the pure `link()`, so
/// [linked] already reflects the change with no network re-sync (#72). On a
/// dry run or a failed apply the snapshot is untouched, so [linked] is `null`
/// and the caller keeps its previous [LinkedState].
class ApplyResult {
  const ApplyResult(this.result, this.linked);

  /// The action's own result — outcome, changes, mutated record.
  final ActionResult result;

  /// The linked view recomputed after the incremental refresh, or `null` when
  /// nothing was written (dry run / failure).
  final LinkedState? linked;

  /// Whether the snapshot was patched and [linked] recomputed.
  bool get refreshed => linked != null;
}

/// Drives the action engine from the State layer and keeps the in-memory
/// snapshots consistent afterwards (spec `docs/domain-model.md` §6.4; #72).
///
/// Sits on top of [ApplicationState] (which owns the three connector snapshots)
/// and the pure `link()`. For each apply it:
///
/// 1. runs the action's `apply(connectors, options)` — a dry run performs no
///    writes and just returns the projected [ActionResult] (PAIN-3);
/// 2. on a successful real write, **patches the owning snapshot** from the
///    result's mutated record ([ActionResult.smartschool] / [ActionResult.azure]
///    / [ActionResult.group], or a removal) and re-runs `link()` — no re-sync;
/// 3. for a `DontImportFromWisa` action (which writes nothing and returns a
///    [ActionResult.wisaRule]), accumulates the rule in [wisaRules] and
///    **re-syncs WISA** so the ignored record drops from the next snapshot —
///    the one path that does hit the network again.
///
/// **Smartschool uid uniqueness (#72).** Because State holds the account set,
/// this applier wraps the injected [StudentActionConfig] / [StaffActionConfig]
/// with a `smartschoolUid` builder that disambiguates a freshly created login
/// against the uids already in the current Smartschool snapshot (`uid`, then
/// `uid1`, `uid2`, … — the legacy `AccountManager.CreateUID` counter). Read the
/// current derived view (and the actions to apply) via [link], so both linking
/// and applying use those uniqueness-aware configs.
class StateApplier {
  StateApplier({
    required this.app,
    required this.connectors,
    required this.resolver,
    required this.wisaRules,
    required StudentActionConfig studentConfig,
    required StaffActionConfig staffConfig,
    this.classTree = const SmartschoolClassTree(),
  })  : _studentConfig = _uniqueStudentConfig(studentConfig, _uidsFrom(app)),
        _staffConfig = _uniqueStaffConfig(staffConfig, _uidsFrom(app));

  /// The snapshots this applier reads and patches.
  final ApplicationState app;

  /// The write-capable connectors the actions call.
  final Connectors connectors;

  /// The identity seam the linker mints/persists person ids through.
  final core.PersonIdResolver resolver;

  /// The shared WISA import-rule set the `DontImportFromWisa` path grows before
  /// re-syncing WISA. Must be the same instance the WISA [Syncer] reads (see
  /// [WisaImportRules]).
  final WisaImportRules wisaRules;

  /// Smartschool class-tree live-config the placement resolver needs.
  final SmartschoolClassTree classTree;

  final StudentActionConfig _studentConfig;
  final StaffActionConfig _staffConfig;

  /// The uid-uniqueness-aware student config used for both linking and applying.
  StudentActionConfig get studentConfig => _studentConfig;

  /// The uid-uniqueness-aware staff config used for both linking and applying.
  StaffActionConfig get staffConfig => _staffConfig;

  /// The current derived linked view over [app]'s snapshots, built with the
  /// uniqueness-aware configs. Rebuild the UI's action lists from this after
  /// every sync or apply. Throws [StateError] if a system has not synced yet
  /// (see [LinkedState.fromApplicationAsync]).
  ///
  /// Asynchronous because [resolver] may be a [PreparablePersonIdResolver] (the
  /// DB-backed identity map), which is primed before the pure `link()` runs; a
  /// file/in-memory resolver skips that step and this resolves immediately.
  Future<LinkedState> link() => LinkedState.fromApplicationAsync(
        app,
        resolver: resolver,
        studentConfig: _studentConfig,
        staffConfig: _staffConfig,
        classTree: classTree,
      );

  /// Applies a [StudentAction] and refreshes the snapshot on a real write.
  Future<ApplyResult> applyStudent(
    StudentAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      removedSmartschoolUid: action.target.smartschool?.uid,
      removedAzureId: action.target.azure?.id,
    );
  }

  /// Applies a [StaffAction] and refreshes the snapshot on a real write.
  Future<ApplyResult> applyStaff(
    StaffAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      removedSmartschoolUid: action.target.smartschool?.uid,
      removedAzureId: action.target.azure?.id,
    );
  }

  /// Applies a [GroupAction] and refreshes the snapshot on a real write.
  Future<ApplyResult> applyGroup(
    GroupAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      removedGroupId: action.target.smartschool?.id,
    );
  }

  /// Patches the owning snapshot from [result] and re-links, unless nothing was
  /// written. The `removed*` keys identify the record to drop for a delete
  /// action — a delete's [ActionResult] carries no record, so the key comes
  /// from the action's bound target (read by the typed `apply*` entry points).
  Future<ApplyResult> _refresh(
    ActionResult result, {
    String? removedSmartschoolUid,
    String? removedAzureId,
    core.GroupId? removedGroupId,
  }) async {
    // Dry run or failure: the snapshot is untouched, so there is nothing to
    // re-link — the caller keeps its previous view.
    if (!result.wrote) return ApplyResult(result, null);

    switch (result.system) {
      case core.Origin.wisa:
        // WISA is read-only: the action produced an import rule instead of a
        // write. Accumulate it and re-sync WISA so the ignored record drops
        // from the next snapshot. This is the only path that hits the network.
        final rule = result.wisaRule;
        if (rule != null) {
          wisaRules.add(rule);
          await app.sync(core.Origin.wisa);
        }
      case core.Origin.smartschool:
        final current = app.smartschool.snapshot!;
        if (result.removed) {
          app.smartschool.patch(
            _dropFromSmartschool(
              current,
              uid: removedSmartschoolUid,
              groupId: removedGroupId,
            ),
          );
        } else if (result.group != null) {
          app.smartschool.patch(_putGroup(current, result.group!));
        } else if (result.smartschool != null) {
          app.smartschool.patch(_putAccount(current, result.smartschool!));
        }
      case core.Origin.azure:
        final current = app.azure.snapshot!;
        if (result.removed) {
          app.azure.patch(_dropAzureUser(current, removedAzureId));
        } else if (result.azure != null) {
          app.azure.patch(_putAzureUser(current, result.azure!));
        }
      case core.Origin.all:
      case core.Origin.other:
        throw StateError(
          'an applied action targeted the non-writable ${result.system}',
        );
    }

    return ApplyResult(result, await link());
  }
}

// ---------------------------------------------------------------------------
// Snapshot splicing. Each helper rebuilds an immutable snapshot with a single
// record replaced/removed, reusing the current snapshot's `fetchedAt` so the
// patch reads as the same fetch (a local edit, not a fresh network read).
// ---------------------------------------------------------------------------

ss.SmartschoolSnapshot _putAccount(
  ss.SmartschoolSnapshot current,
  core.SmartschoolAccount account,
) {
  final record = account as ss.SmartschoolAccount;
  final accounts = [
    for (final a in current.accounts)
      if (a.uid != record.uid) a,
    record,
  ];
  return ss.SmartschoolSnapshot(
    fetchedAt: current.fetchedAt,
    groups: current.groups,
    accounts: accounts,
    memberships: current.memberships,
  );
}

ss.SmartschoolSnapshot _putGroup(
  ss.SmartschoolSnapshot current,
  core.Group group,
) {
  final groups = [
    for (final g in current.groups)
      if (g.id != group.id) g,
    group,
  ];
  return ss.SmartschoolSnapshot(
    fetchedAt: current.fetchedAt,
    groups: groups,
    accounts: current.accounts,
    memberships: current.memberships,
  );
}

ss.SmartschoolSnapshot _dropFromSmartschool(
  ss.SmartschoolSnapshot current, {
  String? uid,
  core.GroupId? groupId,
}) {
  return ss.SmartschoolSnapshot(
    fetchedAt: current.fetchedAt,
    // Drop the group by id (no group-delete action ships yet, so this is a
    // defensive branch), else drop the account and its now-dangling
    // memberships by uid.
    groups: groupId == null
        ? current.groups
        : [
            for (final g in current.groups)
              if (g.id != groupId) g,
          ],
    accounts: uid == null
        ? current.accounts
        : [
            for (final a in current.accounts)
              if (a.uid != uid) a,
          ],
    memberships: uid == null
        ? current.memberships
        : [
            for (final m in current.memberships)
              if (m.uid != uid) m,
          ],
  );
}

az.AzureSnapshot _putAzureUser(az.AzureSnapshot current, core.AzureUser user) {
  final record = user as az.AzureUser;
  final users = [
    for (final u in current.users)
      if (u.id != record.id) u,
    record,
  ];
  return az.AzureSnapshot(
    fetchedAt: current.fetchedAt,
    deltaToken: current.deltaToken,
    users: users,
    groups: current.groups,
  );
}

az.AzureSnapshot _dropAzureUser(az.AzureSnapshot current, String? id) {
  return az.AzureSnapshot(
    fetchedAt: current.fetchedAt,
    deltaToken: current.deltaToken,
    users: id == null
        ? current.users
        : [
            for (final u in current.users)
              if (u.id != id) u,
          ],
    groups: current.groups,
  );
}

// ---------------------------------------------------------------------------
// Uid-uniqueness-aware config wrapping (#72). State holds the account set, so
// it disambiguates a created login against the current Smartschool uids.
// ---------------------------------------------------------------------------

/// A live view of the uids currently taken in [app]'s Smartschool snapshot,
/// lower-cased. Read at uid-generation time so each apply sees the accounts the
/// previous applies spliced in.
Set<String> Function() _uidsFrom(ApplicationState app) => () => {
      for (final a in app.smartschool.snapshot?.accounts ??
          const <ss.SmartschoolAccount>[])
        a.uid.toLowerCase(),
    };

StudentActionConfig _uniqueStudentConfig(
  StudentActionConfig base,
  Set<String> Function() taken,
) =>
    StudentActionConfig(
      schoolPrefix: base.schoolPrefix,
      azureDomain: base.azureDomain,
      studentDomain: base.studentDomain,
      newAccountPassword: base.newAccountPassword,
      smartschoolUid: _uniqueUid(base.smartschoolUid, taken),
    );

StaffActionConfig _uniqueStaffConfig(
  StaffActionConfig base,
  Set<String> Function() taken,
) =>
    StaffActionConfig(
      schoolPrefix: base.schoolPrefix,
      azureDomain: base.azureDomain,
      newAccountPassword: base.newAccountPassword,
      smartschoolUid: _uniqueUid(base.smartschoolUid, taken),
    );

/// Wraps [base] so a generated uid that collides with a currently-taken one is
/// suffixed with the lowest free counter — `uid`, then `uid1`, `uid2`, …,
/// matching legacy `AccountManager.CreateUID`.
String Function(String, String) _uniqueUid(
  String Function(String, String) base,
  Set<String> Function() taken,
) {
  return (givenName, surname) {
    final baseUid = base(givenName, surname);
    final takenLower = taken();
    if (!takenLower.contains(baseUid.toLowerCase())) return baseUid;
    var counter = 1;
    while (takenLower.contains('$baseUid$counter'.toLowerCase())) {
      counter++;
    }
    return '$baseUid$counter';
  };
}
