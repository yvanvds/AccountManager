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
/// import rule for the State layer to add to its rule set and re-sync, rather
/// than writing anything itself.
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

  /// True when the action deleted the record from [system] (so the State layer
  /// should drop it from the snapshot rather than patch it).
  final bool removed;

  /// The WISA import rule the action produced, when [system] is
  /// [Origin.wisa]. WISA is read-only, so the action performs no write itself;
  /// the State layer adds this rule to its import-rule set and re-syncs (which
  /// drops the ignored staff record from the next snapshot). Null for every
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

  const ActionResult({
    required this.outcome,
    required this.changes,
    required this.system,
    this.smartschool,
    this.azure,
    this.group,
    this.removed = false,
    this.wisaRule,
    this.generatedPassword,
    this.error,
  });

  /// Convenience: the write succeeded or was a dry run (i.e. not failed).
  bool get ok => outcome != ActionOutcome.failed;

  /// Convenience: a real write happened (not a dry run, not a failure).
  bool get wrote => outcome == ActionOutcome.applied;
}
