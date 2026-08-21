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
  /// target and the applier ran straight away (#230), in the order they ran.
  ///
  /// Empty for every action that declares no `unlocks`, and for a dry run or a
  /// failed write (nothing was written, so nothing was unlocked). The caller
  /// reports these beside [result]: they are writes the operator's one click
  /// performed and must see.
  final List<ActionResult> followUps;

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
    this.passwordQueue,
    this.ourSchoolIds,
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

  /// The shared password-distribution queue (#105). When wired, every apply that
  /// **creates** an account drops the password it minted into this store, keyed
  /// by [core.PersonId], so one operator can generate while another prints and
  /// distributes. Azure-create and Smartschool-create for the same person merge
  /// onto a single [PasswordEntry] (both backends on one sheet, matching legacy
  /// `AccountPassword`). Left null when the caller does not centralize passwords
  /// (e.g. headless linking-only paths), in which case the minted password is
  /// still written to the target system but not queued.
  final PasswordQueueStore? passwordQueue;

  /// The WISA school ids the operator actually manages (from the persisted
  /// `AppSettings.wisaSchools` ownership flags, #178). Threaded into `link()` so
  /// a student present only in a non-managed sibling school is classified
  /// [core.WisaPresence.groupOnly] and kept out of the managed-school Actions
  /// view. Null falls back to the snapshot's `MarkAsOurs` flags (see `link()`).
  final Set<int>? ourSchoolIds;

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
        ourSchoolIds: ourSchoolIds,
      );

  /// Applies a [StudentAction] and refreshes the snapshot on a real write, then
  /// runs whatever that write unlocked on the same student (#230).
  Future<ApplyResult> applyStudent(
    StudentAction action, {
    ApplyOptions options = const ApplyOptions(),
  }) async {
    final result = await action.apply(connectors, options);
    final applied = await _refresh(
      result,
      removedSmartschoolUid: action.target.smartschool?.uid,
      removedAzureId: action.target.azure?.id,
    );
    return _chainStudentFollowUps(action, applied, options);
  }

  /// Runs the follow-up actions [action]'s write unlocked on the same student,
  /// against the **relinked** record (#230).
  ///
  /// Provisioning a new student is a two-link chain: `AddStudentToSmartschool`
  /// builds the account with the Azure UPN as its `mail`, so it cannot evaluate
  /// true until `AddStudentToAzure` has run. The dispatcher is a pure function
  /// of the current record and can only offer the first link, so one click used
  /// to create the Office 365 account and stop, leaving the Smartschool create
  /// to a second pass the operator had to notice and trigger.
  ///
  /// Each link is taken from the freshly recomputed [LinkedState]'s own
  /// dispatch — the same list the UI would show on the next render — so the
  /// follow-up is bound to the record the previous write produced, placement
  /// and all, and its own `evaluate()` has already agreed it applies. Never a
  /// projection: `createPrincipalName` resolves a UPN collision by suffixing,
  /// so the UPN that landed can differ from the projected one.
  ///
  /// The walk is bounded three ways, so no declaration can spin it: nothing is
  /// unlocked when nothing was written (a dry run or a failure returns no
  /// refreshed view), each action type runs at most once per chain, and a
  /// failed link stops it — the failure is reported and the next sync re-offers
  /// whatever is still missing.
  Future<ApplyResult> _chainStudentFollowUps(
    StudentAction action,
    ApplyResult applied,
    ApplyOptions options,
  ) async {
    var linked = applied.linked;
    if (linked == null || action.unlocks.isEmpty) return applied;

    final targetId = action.target.id;
    final ran = <Type>{action.runtimeType};
    final followUps = <ActionResult>[];
    var unlocks = action.unlocks;

    while (unlocks.isNotEmpty) {
      final next = _unlockedStudentAction(linked!, targetId, unlocks, ran);
      if (next == null) break;
      ran.add(next.runtimeType);
      final result = await next.apply(connectors, options);
      followUps.add(result);
      final refreshed = await _refresh(
        result,
        removedSmartschoolUid: next.target.smartschool?.uid,
        removedAzureId: next.target.azure?.id,
      );
      if (!refreshed.refreshed) break;
      linked = refreshed.linked;
      unlocks = next.unlocks;
    }

    if (followUps.isEmpty) return applied;
    return ApplyResult(applied.result, linked, followUps: followUps);
  }

  /// The first action [linked]'s dispatch raised for [targetId] whose type is
  /// named by [unlocks] and has not run yet this chain, or null when the write
  /// unlocked nothing after all.
  StudentAction? _unlockedStudentAction(
    LinkedState linked,
    core.LinkedAccountId targetId,
    Set<Type> unlocks,
    Set<Type> ran,
  ) {
    for (final candidate in linked.studentActions) {
      if (candidate.target.id == targetId &&
          unlocks.contains(candidate.runtimeType) &&
          !ran.contains(candidate.runtimeType)) {
        return candidate;
      }
    }
    return null;
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
