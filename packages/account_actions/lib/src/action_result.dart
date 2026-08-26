import 'package:account_core/account_core.dart';
import 'package:wisa_api/wisa_api.dart' show WisaImportRule;

import 'change_set.dart';

/// How an `apply()` call ended.
enum ActionOutcome {
  /// The write was performed successfully.
  applied,

  /// [ApplyOptions.dryRun] was set — no write was performed; the result
  /// carries the projected [ChangeSet] and record only (PAIN-3).
  dryRun,

  /// The write was attempted and failed; [ActionResult.error] holds the cause.
  /// Per INV-41 the target state is not left corrupted — the action can be
  /// retried.
  failed,
}

/// The outcome of applying an action.
///
/// Beyond success/failure and the [changes] that were made, this carries the
/// **mutated source record** ([smartschool] or [azure]) — the new or updated
/// connector record — so the State layer can patch its in-memory snapshot and
/// re-run `link()` without a network re-sync (the incremental-refresh
/// constraint from #40). A lifecycle delete sets [removed] instead of a record.
///
/// The record fields are typed against the `account_core` interfaces; the
/// concrete connector records ([smartschool_api] / [azure_api]) implement them.
///
/// A WISA-targeted action ([wisaRule], e.g. the staff `DontImportFromWisa`)
/// carries no connector record: WISA is read-only, so the action produces an
/// import rule for the State layer to add to its rule set and filter its
/// snapshot by, rather than writing anything itself.
class ActionResult {
  final ActionOutcome outcome;

  /// What was changed (or, on a dry run, what would be changed).
  final ChangeSet changes;

  /// The system the action wrote to.
  final Origin system;

  /// The created/updated Smartschool record, when [system] is Smartschool and
  /// the record still exists. Null for a delete or an Azure-targeted action.
  final SmartschoolAccount? smartschool;

  /// The created/updated Azure record, when [system] is Azure and the record
  /// still exists. Null for a delete or a Smartschool-targeted action.
  final AzureUser? azure;

  /// The created/updated Smartschool **group** record, when the action targets
  /// a class group (the [GroupAction] family) rather than an account. Carried
  /// separately from [smartschool] because a group is a [Group], not a
  /// [SmartschoolAccount]. Null for every account-targeted action and for a
  /// group delete (which sets [removed] instead).
  final Group? group;

  /// The created/updated Azure **group** record — the Office 365 class group a
  /// create or membership write produced (#228). Carried separately from
  /// [group] (a Smartschool [Group]) and from [azure] (a user) so the State
  /// layer knows which half of the Azure snapshot to patch. Null for every
  /// other action.
  final AzureGroup? azureGroup;

  /// The official Smartschool class an account-targeted action **seated the
  /// account in** (#341) — set by [MoveToSmartschoolClassGroup] on a real
  /// write, alongside the unchanged [smartschool] record, and by
  /// [AddStudentToSmartschool] when its best-effort placement step actually
  /// wrote the new account into its class (#342).
  ///
  /// A move writes a *membership*, not a field on the account, so the record
  /// the write returns is byte-for-byte the one it started from. Without this
  /// the State layer had nothing to patch the snapshot's membership list from,
  /// so the class the student sat in never changed there: the placement
  /// resolver kept reporting the old class and the move kept evaluating true
  /// after its own write had landed (and, since #338, the stamboeknummer write
  /// waiting behind it stayed deferred) until Smartschool was read again.
  ///
  /// A create has the same problem from the other side: the record it returns
  /// is the account it just built, which says nothing about the class the
  /// placement step then wrote it into, so a freshly provisioned student
  /// landed in the snapshot with no membership at all and was offered a move
  /// into the class they were already sitting in (#342).
  ///
  /// Null for every other action — and for a failed or dry-run move, or a
  /// create whose best-effort placement was skipped or refused: none of those
  /// changed a membership, and this field is spliced into the snapshot as
  /// fact, so only a write that demonstrably landed may name a class.
  final Group? movedToClass;

  /// The **non-official** Smartschool group an account-targeted action added the
  /// account to (#374) — today only the staff-group seat
  /// [AddStaffToSmartschool] performs after its create.
  ///
  /// The staff twin of [movedToClass], and separate from it because the two
  /// splice differently: Smartschool gives an account exactly one official
  /// class, so a class seat *replaces* whatever official row the account held,
  /// while a plain group membership is simply one more row beside the others.
  ///
  /// Null unless that one write demonstrably landed — a dry run, a refusal, a
  /// throw, and an unresolved target all name nothing. This field is spliced
  /// into the snapshot as fact, so silence is the only honest answer to a write
  /// that did not happen.
  final Group? joinedGroup;

  /// The **non-official** Smartschool group an account-targeted action removed
  /// the account from (#374) — today only the default-group
  /// ([smartschoolDefaultGroupName]) seat [AddStaffToSmartschool] undoes after
  /// its create, because `saveUser` puts every account it makes there.
  ///
  /// Null unless the removal both landed *and* named a group the snapshot in
  /// hand carries: the write is addressed by name, so it can succeed against a
  /// group our root-scoped pull never saw, and there is then no local row to
  /// drop.
  final Group? leftGroup;

  /// True when the record is **gone from the snapshot** for [system], so the
  /// State layer drops it rather than patching it.
  ///
  /// Usually that is because the action deleted it. Since #349 it can also mean
  /// the action put the record into a state the connector's own snapshot
  /// construction filters out — [DeactivateStaffInSmartschool] disables a
  /// Smartschool account, which still exists there but no longer reaches any
  /// pull of ours. Both are the same instruction to this layer, and stating it
  /// as "gone from the snapshot" is what keeps the local patch equal to what the
  /// next sync will produce.
  final bool removed;

  /// The WISA import rule the action produced, when [system] is
  /// [Origin.wisa]. WISA is read-only, so the action performs no write itself;
  /// the State layer adds this rule to its import-rule set and applies it to the
  /// snapshot in hand, which drops the ignored record there and then — the rule
  /// is a client-side filter, so no re-pull is involved (#345). Null for every
  /// non-WISA action.
  final WisaImportRule? wisaRule;

  /// The password minted for a **freshly created** account, so the State layer
  /// can drop it into the shared password-distribution queue (#105) instead of
  /// the account-creating action generating it and forgetting it.
  ///
  /// Set only by the account-creating actions on a real [ActionOutcome.applied]
  /// write — the value they passed to the connector. Null for every modify or
  /// delete action, and null on a dry run (no write, so no password is minted
  /// and nothing must leak into the queue).
  final String? generatedPassword;

  /// The failure cause; non-null only when [outcome] is [ActionOutcome.failed].
  final Object? error;

  /// Problems that happened **inside a successful apply** — operator-facing
  /// sentences, already worded, for the caller to log and show beside the
  /// verdict (#343).
  ///
  /// [error] answers "why did this action fail"; this answers "what went wrong
  /// even though it did not". They are mutually exclusive in practice: an
  /// action either finishes and may carry warnings, or fails and carries an
  /// error.
  ///
  /// Only an action with a genuinely **best-effort step** can produce one. Today
  /// that is [AddStudentToSmartschool], whose class placement (#55) may not fail
  /// the create around it (INV-41): before #343 a `moveUserToClass` that *threw*
  /// — a dropped connection, a gateway error, unreadable XML — was caught by the
  /// create's own `catch` and reported as a failed create, for an account that
  /// already existed. Swallowing it instead is what the contract asks for, but a
  /// swallowed exception on a path with no log sink is a silent one, so the
  /// swallowed cause travels here.
  ///
  /// Empty for every action and every outcome that has nothing to add — which
  /// is nearly all of them.
  final List<String> warnings;

  const ActionResult({
    required this.outcome,
    required this.changes,
    required this.system,
    this.smartschool,
    this.azure,
    this.group,
    this.azureGroup,
    this.movedToClass,
    this.joinedGroup,
    this.leftGroup,
    this.removed = false,
    this.wisaRule,
    this.generatedPassword,
    this.error,
    this.warnings = const <String>[],
  });

  /// Convenience: the write succeeded or was a dry run (i.e. not failed).
  bool get ok => outcome != ActionOutcome.failed;

  /// Convenience: a real write happened (not a dry run, not a failure).
  bool get wrote => outcome == ActionOutcome.applied;
}
