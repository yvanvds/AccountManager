import 'materialized_state.dart';

/// The result of merging persisted operator [AccountDecision]s into a freshly
/// materialized set of accounts and groups.
class DecisionsMerge {
  const DecisionsMerge({
    required this.accounts,
    this.groups = const [],
    required this.surviving,
    required this.dropped,
  });

  /// The input accounts, each with its still-applicable decisions re-attached.
  final List<MaterializedAccount> accounts;

  /// The input groups, each with its still-applicable decisions re-attached
  /// (#119).
  final List<MaterializedGroup> groups;

  /// Every decision whose situation still exists (attached to an account or
  /// group).
  final List<AccountDecision> surviving;

  /// Every decision whose situation is gone — the target vanished or no longer
  /// carries the matching candidate/warning. These are deleted from the store.
  final List<AccountDecision> dropped;
}

/// Re-attaches persisted operator decisions to the freshly recomputed accounts
/// and groups, dropping only those whose situation no longer exists (#115, #119).
///
/// A sync rewrites the derived per-account and per-group docs wholesale, so
/// operator intent lives in separate [AccountDecision] documents. This merge is
/// what keeps a re-sync from clobbering in-progress work: a decision is kept
/// while its target (account **or** group) still carries the situation it
/// resolves —
///
/// - [DecisionKind.chosenAlternative] / [DecisionKind.appliedStatus]: the target
///   still has a candidate whose [CandidateAction.kind] matches the decision's
///   [AccountDecision.targetKind];
/// - [DecisionKind.acceptedDuplicate]: the target still carries a warning (the
///   collision is still present).
///
/// Accounts and groups share one decisions container, so both are considered in
/// a single pass — a group decision is never dropped merely because it does not
/// match an account. A decision whose target vanished, or whose situation is
/// resolved, is [DecisionsMerge.dropped].
DecisionsMerge mergeDecisions({
  required List<MaterializedAccount> accounts,
  List<MaterializedGroup> groups = const [],
  required List<AccountDecision> existing,
}) {
  final byTarget = <String, List<AccountDecision>>{};
  for (final d in existing) {
    (byTarget[d.accountId.value] ??= <AccountDecision>[]).add(d);
  }

  final surviving = <AccountDecision>[];

  final mergedAccounts = <MaterializedAccount>[];
  for (final account in accounts) {
    final decisions = byTarget[account.id.value] ?? const <AccountDecision>[];
    final kept = [
      for (final d in decisions)
        if (_situationExists(account.candidates, account.warnings, d)) d,
    ];
    surviving.addAll(kept);
    mergedAccounts.add(kept.isEmpty ? account : account.withDecisions(kept));
  }

  final mergedGroups = <MaterializedGroup>[];
  for (final group in groups) {
    final decisions = byTarget[group.id.value] ?? const <AccountDecision>[];
    final kept = [
      for (final d in decisions)
        if (_situationExists(group.candidates, const [], d)) d,
    ];
    surviving.addAll(kept);
    mergedGroups.add(kept.isEmpty ? group : group.withDecisions(kept));
  }

  // Anything not kept — including decisions whose target is gone entirely — is
  // dropped from the store.
  final survivingIds = surviving.toSet();
  final dropped = [
    for (final d in existing)
      if (!survivingIds.contains(d)) d,
  ];

  return DecisionsMerge(
    accounts: mergedAccounts,
    groups: mergedGroups,
    surviving: surviving,
    dropped: dropped,
  );
}

bool _situationExists(
  List<CandidateAction> candidates,
  List<String> warnings,
  AccountDecision d,
) {
  switch (d.kind) {
    case DecisionKind.acceptedDuplicate:
      return warnings.isNotEmpty;
    case DecisionKind.chosenAlternative:
    case DecisionKind.appliedStatus:
      return candidates.any((c) => c.kind == d.targetKind);
  }
}
