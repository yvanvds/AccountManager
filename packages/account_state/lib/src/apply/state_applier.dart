import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;

import '../link/linked_state.dart';
import '../link/placement.dart';
import '../passwords/password_entry.dart';
import '../passwords/password_queue_store.dart';
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
  const ApplyResult(this.result, this.linked, {this.followUps = const []});

  /// The action's own result — outcome, changes, mutated record.
  final ActionResult result;

  /// The linked view recomputed after the incremental refresh, or `null` when
  /// nothing was written (dry run / failure). When [followUps] ran, this is the
  /// view the **last** of them left behind.
  final LinkedState? linked;

  /// The results of the follow-up actions this write unlocked on the same
  /// target and the applier ran straight away (#230 for students, #245 for
  /// class groups, #240 for staff), in the order they ran.
  ///
  /// Empty for every action that declares no `unlocks`, and for a dry run or a
  /// failed write (nothing was written, so nothing was unlocked). The caller
  /// reports these beside [result]: they are writes the operator's one click
  /// performed and must see.
  final List<ActionResult> followUps;

  /// Whether the snapshot was patched and [linked] recomputed.
  bool get refreshed => linked != null;
}

/// Everything [StateApplier] derives from the operator's settings document,
/// gathered into one value it re-reads at every use (#246).
///
/// These four used to be `final` fields on the applier, captured when
/// `bootstrapReconcile` assembled the stack and never looked at again. That made
/// the school prefix, the Azure domain, the Smartschool class tree and the
/// managed-school set relaunch-only: an operator could flip a school's
/// **beheerd** mark in Instellingen, save, sync, and get the old scoping back
/// with nothing on screen to explain it. Bundling them means the applier takes
/// **one** supplier rather than four, and that a pass which samples them
/// ([StateApplier.link]) is guaranteed to see one consistent document.
class ApplierSettings {
  const ApplierSettings({
    required this.studentConfig,
    required this.staffConfig,
    this.classTree = const SmartschoolClassTree(),
    this.ourSchoolIds,
  });

  /// Student action config — the school prefix the linker scopes Azure by and
  /// the UPN domains new accounts are minted under.
  final StudentActionConfig studentConfig;

  /// Staff action config; carries the same prefix and base domain.
  final StaffActionConfig staffConfig;

  /// The Smartschool grade/year vocabulary and group root a freshly created
  /// class hangs under (`classTreeFrom(settings.smartschool)`).
  final SmartschoolClassTree classTree;

  /// The `ours`-flagged WISA school ids (#178), or null when no school is
  /// flagged — which, like an empty set, reads as "ownership unconfigured" and
  /// counts every school, never as "no school is ours".
  final Set<int>? ourSchoolIds;
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
///    / [ActionResult.group], or a removal) and re-runs `link()` — no re-sync.
///    A class move mutates no field of the account it moves, so it names the
///    class instead ([ActionResult.movedToClass]) and the patch reseats the
///    membership as well (#341);
/// 3. for a `DontImportFromWisa` action (which writes nothing and returns a
///    [ActionResult.wisaRule]), accumulates the rule in [wisaRules] and patches
///    the WISA snapshot with it locally, so the ignored record drops with no
///    network at all (#345 — the rule is a client-side filter, never a query
///    parameter). Making that rule permanent is the caller's job, not this
///    layer's: since #276 the reconcile controller writes it to the shared
///    settings document once the pass ends, where the store (and, for #285, the
///    operator's identity) lives.
///
/// No step here touches the network beyond the action's own write.
///
/// **Smartschool uid uniqueness (#72).** Because State holds the account set,
/// this applier wraps the injected [StudentActionConfig] / [StaffActionConfig]
/// with a `smartschoolUid` builder that disambiguates a freshly created login
/// against the uids already in the current Smartschool snapshot (`uid`, then
/// `uid1`, `uid2`, … — the legacy `AccountManager.CreateUID` counter). Read the
/// current derived view (and the actions to apply) via [link], so both linking
/// and applying use those uniqueness-aware configs.
///
/// **Settings are read live (#246).** Every settings-derived input arrives as
/// one [ApplierSettings] supplier that is called *per link and per apply*, never
/// captured in a field. Before #246 the four values were `final`, so an operator
/// who flipped a school's **beheerd** mark, changed the school prefix or edited
/// the Smartschool class tree kept getting the bootstrap-time answer until the
/// app was relaunched.
class StateApplier {
  StateApplier({
    required this.app,
    required this.connectors,
    required this.resolver,
    required this.wisaRules,
    required ApplierSettings Function() settings,
    this.passwordQueue,
  }) : _settings = settings;

  /// Convenience wiring for a stack whose settings genuinely cannot change
  /// while it lives — a headless linking pass, a fixture, a unit test. Supplies
  /// the same [ApplierSettings] on every read; production always uses the
  /// unnamed constructor with a supplier over the live document.
  StateApplier.fixed({
    required ApplicationState app,
    required Connectors connectors,
    required core.PersonIdResolver resolver,
    required WisaImportRules wisaRules,
    required StudentActionConfig studentConfig,
    required StaffActionConfig staffConfig,
    SmartschoolClassTree classTree = const SmartschoolClassTree(),
    Set<int>? ourSchoolIds,
    PasswordQueueStore? passwordQueue,
  }) : this(
          app: app,
          connectors: connectors,
          resolver: resolver,
          wisaRules: wisaRules,
          passwordQueue: passwordQueue,
          settings: () => ApplierSettings(
            studentConfig: studentConfig,
            staffConfig: staffConfig,
            classTree: classTree,
            ourSchoolIds: ourSchoolIds,
          ),
        );

  /// The snapshots this applier reads and patches.
  final ApplicationState app;

  /// The write-capable connectors the actions call.
  final Connectors connectors;

  /// The identity seam the linker mints/persists person ids through.
  final core.PersonIdResolver resolver;

  /// The shared WISA import-rule set the `DontImportFromWisa` path grows before
  /// patching the snapshot with the new rule. Must be the same instance the WISA
  /// [Syncer] reads (see [WisaImportRules]), so the *next* real pull filters by
  /// everything this pass earned.
  final WisaImportRules wisaRules;

  /// The shared password-distribution queue (#105). When wired, every apply that
  /// **creates** an account drops the password it minted into this store, keyed
  /// by [core.PersonId], so one operator can generate while another prints and
  /// distributes. Azure-create and Smartschool-create for the same person merge
  /// onto a single [PasswordEntry] (both backends on one sheet, matching legacy
  /// `AccountPassword`). Left null when the caller does not centralize passwords
  /// (e.g. headless linking-only paths), in which case the minted password is
  /// still written to the target system but not queued.
  final PasswordQueueStore? passwordQueue;

  /// The settings-derived inputs, read afresh on every use (#246).
  final ApplierSettings Function() _settings;

  /// The settings-derived inputs as they stand **right now**. Call this once
  /// per operation and use the result throughout it, so a save landing mid-pass
  /// cannot split one link across two documents.
  ApplierSettings get settings => _settings();

  /// The WISA school ids the operator actually manages (from the persisted
  /// `AppSettings.wisaSchools` ownership flags, #178). Threaded into `link()` so
  /// a student present only in a non-managed sibling school is classified
  /// [core.WisaPresence.groupOnly] and kept out of the managed-school Actions
  /// view. Null reads as unconfigured — every school counts (see `link()`).
  Set<int>? get ourSchoolIds => settings.ourSchoolIds;

  /// Smartschool class-tree live-config the placement resolver needs.
  SmartschoolClassTree get classTree => settings.classTree;

  /// The uid-uniqueness-aware student config used for both linking and applying.
  StudentActionConfig get studentConfig =>
      _uniqueStudentConfig(settings.studentConfig, _uidsFrom(app));

  /// The uid-uniqueness-aware staff config used for both linking and applying.
  StaffActionConfig get staffConfig =>
      _uniqueStaffConfig(settings.staffConfig, _uidsFrom(app));

  /// The current derived linked view over [app]'s snapshots, built with the
  /// uniqueness-aware configs. Rebuild the UI's action lists from this after
  /// every sync or apply. Throws [StateError] if a system has not synced yet
  /// (see [LinkedState.fromApplicationAsync]).
  ///
  /// Asynchronous because [resolver] may be a [PreparablePersonIdResolver] (the
  /// DB-backed identity map), which is primed before the pure `link()` runs; a
  /// file/in-memory resolver skips that step and this resolves immediately.
  ///
  /// The settings are sampled **once** here and threaded through the whole pass
  /// (#246): the school prefix the linker scopes by, the managed-school set and
  /// the class tree must all describe the same document, or `link()` would scope
  /// Azure by one prefix while `naturalKeysFor` primed the resolver with
  /// another.
  Future<LinkedState> link() {
    final now = settings;
    final uids = _uidsFrom(app);
    return LinkedState.fromApplicationAsync(
      app,
      resolver: resolver,
      studentConfig: _uniqueStudentConfig(now.studentConfig, uids),
      staffConfig: _uniqueStaffConfig(now.staffConfig, uids),
      classTree: now.classTree,
      ourSchoolIds: now.ourSchoolIds,
    );
  }

  /// Applies a [StudentAction] and refreshes the snapshot on a real write, then
  /// runs whatever that write unlocked on the same student (#230).
  Future<ApplyResult> applyStudent(
    StudentAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final applied = await _applyStudentOnce(action, options);
    final targetId = action.target.id;
    return _chainFollowUps<StudentAction>(
      action,
      applied,
      options,
      dispatch: (linked) => linked.studentActions,
      sameTarget: (candidate) => candidate.target.id == targetId,
      canApply: (candidate) => candidate.canApply,
      unlocksOf: (candidate) => candidate.unlocks,
      run: _applyStudentOnce,
    );
  }

  /// Applies a [StaffAction] and refreshes the snapshot on a real write, then
  /// runs whatever that write unlocked on the same staff member (#240).
  Future<ApplyResult> applyStaff(
    StaffAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final applied = await _applyStaffOnce(action, options);
    final targetId = action.target.id;
    return _chainFollowUps<StaffAction>(
      action,
      applied,
      options,
      dispatch: (linked) => linked.staffActions,
      // A staff member's [core.LinkedAccountId] comes from the resolver's
      // natural key (`wisaId`, else the staff `code`), and an Azure create
      // stamps that same `wisaId` as the account's `employeeId` — so the record
      // that raised the create is the same record after the relink.
      sameTarget: (candidate) => candidate.target.id == targetId,
      canApply: (candidate) => candidate.canApply,
      unlocksOf: (candidate) => candidate.unlocks,
      run: _applyStaffOnce,
    );
  }

  /// Applies a [GroupAction] and refreshes the snapshot on a real write, then
  /// runs whatever that write unlocked on the same class (#245).
  ///
  /// Stamps the pass with the werkdatum the WISA snapshot in hand was pulled as
  /// of (#339) unless the caller already named one. The State layer owns the
  /// snapshots, so it is the one layer that can answer "which school year is
  /// this class data from" — leaving it to each call site is how the class
  /// writes came to name no year at all. A caller that *does* set
  /// [ApplyOptions.workDate] is left alone: it knows something this does not.
  Future<ApplyResult> applyGroup(
    GroupAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final dated = _stamped(options);
    final applied = await _applyGroupOnce(action, dated);
    final targetKey = _groupKeyOf(action.target);
    return _chainFollowUps<GroupAction>(
      action,
      applied,
      dated,
      dispatch: (linked) => linked.groupActions,
      sameTarget: (candidate) => _groupKeyOf(candidate.target) == targetKey,
      canApply: (candidate) => candidate.canApply,
      unlocksOf: (candidate) => candidate.unlocks,
      run: _applyGroupOnce,
    );
  }

  /// [options] carrying the werkdatum of the WISA snapshot this applier holds,
  /// or unchanged when the caller named one or no snapshot has a stamp (a pull
  /// from before #247, or a harness that models no sync). See
  /// [ApplyOptions.workDate].
  ApplyOptions _stamped(ApplyOptions options) {
    if (options.workDate != null) return options;
    final stamp = app.wisa.snapshot?.workDate;
    return stamp == null ? options : options.asOf(stamp);
  }

  /// Runs one student action and refreshes the snapshot — the single link the
  /// chain repeats.
  Future<ApplyResult> _applyStudentOnce(
    StudentAction action,
    ApplyOptions options,
  ) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      removedSmartschoolUid: action.target.smartschool?.uid,
      removedAzureId: action.target.azure?.id,
    );
  }

  /// Runs one staff action and refreshes the snapshot.
  Future<ApplyResult> _applyStaffOnce(
    StaffAction action,
    ApplyOptions options,
  ) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      removedSmartschoolUid: action.target.smartschool?.uid,
      removedAzureId: action.target.azure?.id,
    );
  }

  /// Runs one group action and refreshes the snapshot.
  Future<ApplyResult> _applyGroupOnce(
    GroupAction action,
    ApplyOptions options,
  ) async {
    final result = await action.apply(connectors, options);
    return _refresh(
      result,
      // The Smartschool class `DeleteSmartschoolClass` removes (#313).
      removedGroupId: action.target.smartschool?.id,
      // The Office 365 group `DeleteAzureClassGroup` removes (#271). A delete
      // carries no record back, so the key comes off the bound target — and it
      // is a *group* id, which is why it travels separately from the
      // `removedAzureId` the account families pass (that one is a user).
      removedAzureGroupId: action.target.azure?.id,
    );
  }

  /// Runs the follow-up actions [action]'s write unlocked on the same target,
  /// against the **relinked** record — one walk, shared by all three families
  /// (students #230, class groups #245, staff #240) rather than a copy per
  /// family. Only the typed dispatch it reads and the target identity differ,
  /// so those arrive as parameters.
  ///
  /// Provisioning is a two-link chain in every family, and dispatch (§6.3) is a
  /// pure function of the record *as it stands*, so it can only ever offer the
  /// first link. `AddStudentToSmartschool` / [AddStaffToSmartschool] build their
  /// account with the Azure UPN as its `mail` and evaluate false until the
  /// Office 365 account exists; `CreateAzureClassGroup` leaves an empty group
  /// because Graph writes the roster separately. In each case one click used to
  /// perform the first write and stop, leaving the rest to a second pass the
  /// operator had to notice and trigger.
  ///
  /// Each link is taken from the freshly recomputed [LinkedState]'s own
  /// [dispatch] — the same list the UI would show on the next render — so the
  /// follow-up is bound to the record the previous write produced, placement and
  /// all, and its own `evaluate()` has already agreed it applies. Never a
  /// projection: `createPrincipalName` resolves a UPN collision by suffixing, so
  /// the UPN that landed can differ from the projected one, and a created
  /// group's id is not knowable before the write at all.
  ///
  /// The walk is bounded four ways, so no declaration can spin it: nothing is
  /// unlocked when nothing was written (a dry run or a failure returns no
  /// refreshed view), each action type runs at most once per chain, an
  /// informational action ([canApply] false) is never run, and a failed link
  /// stops it — the failure is reported and the next sync re-offers whatever is
  /// still missing.
  Future<ApplyResult> _chainFollowUps<A extends Object>(
    A action,
    ApplyResult applied,
    ApplyOptions options, {
    required List<A> Function(LinkedState linked) dispatch,
    required bool Function(A candidate) sameTarget,
    required bool Function(A candidate) canApply,
    required Set<Type> Function(A candidate) unlocksOf,
    required Future<ApplyResult> Function(A action, ApplyOptions options) run,
  }) async {
    var linked = applied.linked;
    var unlocks = unlocksOf(action);
    if (linked == null || unlocks.isEmpty) return applied;

    final ran = <Type>{action.runtimeType};
    final followUps = <ActionResult>[];

    while (unlocks.isNotEmpty) {
      final next = _firstUnlocked(
        dispatch(linked!),
        unlocks,
        ran,
        sameTarget,
        canApply,
      );
      if (next == null) break;
      ran.add(next.runtimeType);
      final refreshed = await run(next, options);
      followUps.add(refreshed.result);
      if (!refreshed.refreshed) break;
      linked = refreshed.linked;
      unlocks = unlocksOf(next);
    }

    if (followUps.isEmpty) return applied;
    return ApplyResult(applied.result, linked, followUps: followUps);
  }

  /// The first of [candidates] that targets the same record, is applyable, has a
  /// type named by [unlocks], and has not run yet this chain — or null when the
  /// write unlocked nothing after all.
  A? _firstUnlocked<A extends Object>(
    List<A> candidates,
    Set<Type> unlocks,
    Set<Type> ran,
    bool Function(A candidate) sameTarget,
    bool Function(A candidate) canApply,
  ) {
    for (final candidate in candidates) {
      if (sameTarget(candidate) &&
          canApply(candidate) &&
          unlocks.contains(candidate.runtimeType) &&
          !ran.contains(candidate.runtimeType)) {
        return candidate;
      }
    }
    return null;
  }

  /// The identity of a linked class record across a relink. A [core.LinkedGroup]
  /// carries no id of its own, so this uses the keys the linker builds it from,
  /// WISA first: the WISA `fullName` is what the linker keys records by (INV-20)
  /// and is untouched by any Azure or Smartschool write, so the record that
  /// raised the create is the same record after the relink.
  static String _groupKeyOf(core.LinkedGroup group) =>
      group.wisa?.id.value ??
      group.smartschool?.id.value ??
      group.azure?.id ??
      '';

  /// Patches the owning snapshot from [result] and re-links, unless nothing was
  /// written. The `removed*` keys identify the record to drop for a delete
  /// action — a delete's [ActionResult] carries no record, so the key comes
  /// from the action's bound target (read by the typed `apply*` entry points).
  Future<ApplyResult> _refresh(
    ActionResult result, {
    String? removedSmartschoolUid,
    String? removedAzureId,
    core.GroupId? removedGroupId,
    String? removedAzureGroupId,
  }) async {
    // Dry run or failure: the snapshot is untouched, so there is nothing to
    // re-link — the caller keeps its previous view.
    if (!result.wrote) return ApplyResult(result, null);

    switch (result.system) {
      case core.Origin.wisa:
        // WISA is read-only: the action produced an import rule instead of a
        // write. Accumulate it — the rule must still reach the *next* real pull
        // and, since #276, the shared settings document — and then patch the
        // snapshot locally, exactly like every other origin (#345).
        //
        // This used to re-sync WISA, and that re-pull bought nothing: an import
        // rule never reaches WISA. It is a client-side filter the connector
        // applies at snapshot *construction*, after all the I/O, and the row
        // queries carry no rule parameter — so `sync()` paid three SOAP round
        // trips per school (20s+ on a real scholengroep) only to rebuild the
        // snapshot already in hand minus one dropped row.
        final rule = result.wisaRule;
        if (rule != null) {
          wisaRules.add(rule);
          app.wisa.patch(_applyWisaRule(app.wisa.snapshot!, rule));
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
          // A class move (#341) returns the account unchanged and names the
          // class it now belongs to instead, so the membership travels with
          // the record splice — otherwise the relink below would still read
          // the old class off `current.memberships` and re-raise the very move
          // that just succeeded. A create that placed its new account names it
          // the same way (#342), for the same reason from the other side: the
          // record it returns says nothing about the class it was written
          // into, so without this the student arrives in the snapshot with no
          // membership and is offered the move they no longer need.
          app.smartschool.patch(
            _putAccount(
              current,
              result.smartschool!,
              movedTo: result.movedToClass,
            ),
          );
        }
      case core.Origin.azure:
        final current = app.azure.snapshot!;
        if (result.removed) {
          // Only the group family passes a group key (#271), so a student's or
          // staff member's Azure delete still drops a *user* exactly as before.
          app.azure.patch(
            removedAzureGroupId == null
                ? _dropAzureUser(current, removedAzureId)
                : _dropAzureGroup(current, removedAzureGroupId),
          );
        } else if (result.azureGroup != null) {
          // An Office 365 class group was created or had its membership
          // rewritten (#228) — patch the snapshot's group list so the relink
          // below sees the class as provisioned/in sync without a re-pull.
          app.azure.patch(_putAzureGroup(current, result.azureGroup!));
        } else if (result.azure != null) {
          app.azure.patch(_putAzureUser(current, result.azure!));
        }
      case core.Origin.all:
      case core.Origin.other:
        throw StateError(
          'an applied action targeted the non-writable ${result.system}',
        );
    }

    final linked = await link();
    // A create action carries the password it minted; drop it in the shared
    // queue keyed by person (#105), merging Azure- and Smartschool-create onto
    // one sheet. Every other action leaves [generatedPassword] null.
    if (result.generatedPassword != null) {
      await _enqueuePassword(linked, result);
    }
    return ApplyResult(result, linked);
  }

  /// Merges the freshly minted password from [result] into [passwordQueue],
  /// keyed by the created person's [core.PersonId] (the `id` the linker built
  /// from the resolver). A person's Azure and Smartschool creates land on **one**
  /// [PasswordEntry] — the second create fills the empty backend field on the
  /// entry the first create left — matching the legacy one-sheet-per-student
  /// `AccountPassword`. A no-op when no queue is wired or the created record
  /// cannot be matched in the fresh linked view.
  Future<void> _enqueuePassword(LinkedState linked, ActionResult result) async {
    final store = passwordQueue;
    final password = result.generatedPassword;
    if (store == null || password == null) return;

    final target = _passwordTargetFor(linked, result);
    if (target == null) return;

    final toAzure = result.system == core.Origin.azure;
    final queue = await store.load();
    final index = queue.indexWhere(
      (e) =>
          e.personId.value == target.personId.value &&
          e.kind == PasswordAccountKind.account,
    );
    final existing = index >= 0 ? queue[index] : null;

    final merged = PasswordEntry(
      personId: target.personId,
      kind: PasswordAccountKind.account,
      accountName: target.accountName,
      displayName: target.displayName,
      // Prefer the freshly linked view's fields (the second create sees a more
      // complete record), falling back to whatever the first create recorded.
      mail: target.mail ?? existing?.mail,
      classGroup: target.classGroup ?? existing?.classGroup,
      smartschoolPassword: toAzure ? existing?.smartschoolPassword : password,
      azurePassword: toAzure ? password : existing?.azurePassword,
    );

    final updated = [...queue];
    if (index >= 0) {
      updated[index] = merged;
    } else {
      updated.add(merged);
    }
    await store.save(updated);
  }

  /// Locates the created record in the fresh linked view and reads the fields a
  /// [PasswordEntry] prints, or null when it cannot be matched (which should not
  /// happen right after a successful create). Matches on the connector identity
  /// the write returned — Smartschool `uid` or Azure `id` — because the
  /// [core.PersonId] is only known through the linked record.
  _PasswordTarget? _passwordTargetFor(LinkedState linked, ActionResult result) {
    final snapshot = linked.snapshot;
    switch (result.system) {
      case core.Origin.smartschool:
        final uid = result.smartschool?.uid;
        if (uid == null) return null;
        for (final a in snapshot.accounts) {
          if (a.smartschool?.uid == uid) return _targetFromAccount(a);
        }
        for (final s in snapshot.staff) {
          if (s.smartschool?.uid == uid) return _targetFromStaff(s);
        }
        return null;
      case core.Origin.azure:
        final id = result.azure?.id;
        if (id == null) return null;
        for (final a in snapshot.accounts) {
          if (a.azure?.id == id) return _targetFromAccount(a);
        }
        for (final s in snapshot.staff) {
          if (s.azure?.id == id) return _targetFromStaff(s);
        }
        return null;
      case core.Origin.wisa:
      case core.Origin.all:
      case core.Origin.other:
        return null;
    }
  }

  // The rich name/class/mail fields live on the concrete connector records, not
  // the minimal `account_core` interfaces `LinkedAccount` exposes. The applier
  // already downcasts these snapshot records elsewhere (see `_putAccount`), so
  // the same casts are safe here.

  _PasswordTarget _targetFromAccount(core.LinkedAccount a) {
    final wisa = a.wisa as wapi.WisaStudent?;
    final ssAccount = a.smartschool as ss.SmartschoolAccount?;
    final azUser = a.azure as az.AzureUser?;
    return _PasswordTarget(
      personId: core.PersonId(a.id.value),
      accountName: ssAccount?.uid ?? _localPart(azUser?.upn),
      displayName:
          wisa?.fullName ?? azUser?.displayName ?? _nameOf(ssAccount) ?? '',
      mail: azUser?.upn ?? ssAccount?.mail,
      classGroup: wisa?.classGroup ?? azUser?.department,
    );
  }

  _PasswordTarget _targetFromStaff(core.LinkedStaff s) {
    final wisa = s.wisa as wapi.WisaStaff?;
    final ssAccount = s.smartschool as ss.SmartschoolAccount?;
    final azUser = s.azure as az.AzureUser?;
    return _PasswordTarget(
      personId: core.PersonId(s.id.value),
      accountName: ssAccount?.uid ?? _localPart(azUser?.upn),
      displayName: azUser?.displayName ??
          _nameOf(ssAccount) ??
          [wisa?.firstName, wisa?.lastName]
              .whereType<String>()
              .join(' ')
              .trim(),
      mail: azUser?.upn ?? ssAccount?.mail,
      classGroup: azUser?.department,
    );
  }
}

/// The fields a [PasswordEntry] needs, read from the freshly linked record the
/// created account now belongs to.
class _PasswordTarget {
  const _PasswordTarget({
    required this.personId,
    required this.accountName,
    required this.displayName,
    this.mail,
    this.classGroup,
  });

  final core.PersonId personId;
  final String accountName;
  final String displayName;
  final String? mail;
  final String? classGroup;
}

/// The local part of an email/UPN (`jane.doe` from `jane.doe@x.be`); '' when
/// [mail] is null so the entry always has a non-null account name.
String _localPart(String? mail) {
  if (mail == null) return '';
  return mail.contains('@') ? mail.split('@').first : mail;
}

/// A display name assembled from a Smartschool record's given + surname, or null
/// when no record is present.
String? _nameOf(ss.SmartschoolAccount? account) {
  if (account == null) return null;
  return '${account.givenName} ${account.surname}'.trim();
}

// ---------------------------------------------------------------------------
// Snapshot splicing. Each helper rebuilds an immutable snapshot with a single
// record replaced/removed, reusing the current snapshot's `fetchedAt` so the
// patch reads as the same fetch (a local edit, not a fresh network read).
// ---------------------------------------------------------------------------

/// [current] with [rule] applied to it exactly as [wapi.WisaConnector.sync]
/// applies its rule set at snapshot construction (#345) — the staff filter and
/// the class-group filter, in that one order, over the snapshot in hand.
///
/// This is what makes the local patch honest rather than merely fast: the two
/// filters here are the *same* functions the next real pull runs, so a
/// `DontImportUserFromWisa` drops the same staff row and a `DontImportClass`
/// the same class group the pull would have dropped, and the in-memory view
/// cannot drift from the snapshot that pull will produce. Both rule kinds go
/// through both filters because a rule the other filter does not recognise is a
/// no-op there, which is also how the connector composes them.
///
/// Students are untouched: no import rule drops a student. A `DontImportClass`
/// removes the *class group*, and the students who were in it keep their
/// (now classless) rows — precisely what the connector leaves behind, since it
/// filters `classGroups` and hands `students` through unfiltered.
///
/// `fetchedAt` and `workDate` are carried over: a local filter is not a fresh
/// fetch, so the roster still dates from the pull it came out of (and
/// [SystemState.patch] leaves `lastSync` alone for the same reason).
wapi.WisaSnapshot _applyWisaRule(
  wapi.WisaSnapshot current,
  wapi.WisaImportRule rule,
) {
  final rules = [rule];
  return wapi.WisaSnapshot(
    fetchedAt: current.fetchedAt,
    workDate: current.workDate,
    students: current.students,
    staff: wapi.applyRulesToStaff(current.staff, rules),
    classGroups: wapi.applyRulesToClassGroups(current.classGroups, rules),
    schools: current.schools,
  );
}

ss.SmartschoolSnapshot _putAccount(
  ss.SmartschoolSnapshot current,
  core.SmartschoolAccount account, {
  core.Group? movedTo,
}) {
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
    memberships: movedTo == null
        ? current.memberships
        : _reseat(current, uid: record.uid, target: movedTo),
  );
}

/// [current]'s memberships with [uid]'s **official class** row replaced by one
/// in [target] — the membership half of a successful class move (#341), and of
/// a create that placed its new account (#342, where there is no row to
/// replace and the target is simply the account's first seat).
///
/// Smartschool gives an account exactly one official class (`saveUserToClass`
/// re-seats rather than adds), so every official-class row this uid holds goes
/// and the target's takes their place. Everything else the account belongs to —
/// subject groups, the `Leerlingen` root, another school's node — is untouched:
/// the move said nothing about those, and dropping them would make the snapshot
/// lie in the other direction.
///
/// The uid is matched the way [PlacementResolver] keys its own membership index
/// (trimmed, case-insensitive), so a row that index would have found is a row
/// this replaces. The target is appended last, like every other splice here;
/// it is the only official-class row left for the uid, so the resolver's
/// first-wins walk finds it regardless of position.
List<ss.SmartschoolMembership> _reseat(
  ss.SmartschoolSnapshot current, {
  required String uid,
  required core.Group target,
}) {
  final officialClasses = <String>{
    for (final g in current.groups)
      if (g.official && g.type == core.GroupType.classGroup) g.id.value,
  };
  final key = uid.trim().toLowerCase();
  bool isMovedFrom(ss.SmartschoolMembership m) =>
      m.uid.trim().toLowerCase() == key &&
      officialClasses.contains(m.groupId.value);

  return [
    for (final m in current.memberships)
      if (!isMovedFrom(m)) m,
    ss.SmartschoolMembership(uid: uid, groupId: target.id),
  ];
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
    // Drop the group by id — the class `DeleteSmartschoolClass` removes
    // (#313), so the relink sees the leftover gone instead of re-raising the
    // very pair the operator just resolved — else drop the account and its
    // now-dangling memberships by uid. A deleted class's memberships are left
    // where they are: `PlacementResolver` resolves each one through the group
    // list and skips the ones that no longer land anywhere.
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

az.AzureSnapshot _putAzureGroup(
  az.AzureSnapshot current,
  core.AzureGroup group,
) {
  final record = group as az.AzureGroup;
  // Keyed by Azure object id, like the user splice. Only a real write reaches
  // here (a dry run never refreshes), so a created group already carries the id
  // Graph minted and a membership rewrite carries the group's own.
  final groups = [
    for (final g in current.groups)
      if (g.id != record.id) g,
    record,
  ];
  return az.AzureSnapshot(
    fetchedAt: current.fetchedAt,
    deltaToken: current.deltaToken,
    users: current.users,
    groups: groups,
  );
}

/// Drops a deleted Office 365 group from the snapshot (#271), so the relink
/// below sees the stale class gone instead of re-raising the very pair the
/// operator just resolved. The users are untouched: deleting a group removes
/// nobody's account.
az.AzureSnapshot _dropAzureGroup(az.AzureSnapshot current, String? id) {
  return az.AzureSnapshot(
    fetchedAt: current.fetchedAt,
    deltaToken: current.deltaToken,
    users: current.users,
    groups: id == null
        ? current.groups
        : [
            for (final g in current.groups)
              if (g.id != id) g,
          ],
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
