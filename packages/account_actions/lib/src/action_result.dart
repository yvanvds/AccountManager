import 'package:account_core/account_core.dart';

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

  /// True when the action deleted the record from [system] (so the State layer
  /// should drop it from the snapshot rather than patch it).
  final bool removed;

  /// The failure cause; non-null only when [outcome] is [ActionOutcome.failed].
  final Object? error;

  const ActionResult({
    required this.outcome,
    required this.changes,
    required this.system,
    this.smartschool,
    this.azure,
    this.removed = false,
    this.error,
  });

  /// Convenience: the write succeeded or was a dry run (i.e. not failed).
  bool get ok => outcome != ActionOutcome.failed;

  /// Convenience: a real write happened (not a dry run, not a failure).
  bool get wrote => outcome == ActionOutcome.applied;
}
