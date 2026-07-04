import 'materialized_state.dart';

/// The result of merging persisted operator [AccountDecision]s into a freshly
/// materialized set of accounts.
class DecisionsMerge {
  const DecisionsMerge({
    required this.accounts,
    required this.surviving,
    required this.dropped,
  });

  /// The input accounts, each with its still-applicable decisions re-attached.
  final List<MaterializedAccount> accounts;

  /// Every decision whose situation still exists (attached to [accounts]).
  final List<AccountDecision> surviving;

  /// Every decision whose situation is gone — the account vanished or no longer
  /// carries the matching candidate/warning. These are deleted from the store.
  final List<AccountDecision> dropped;
}

/// Re-attaches persisted operator decisions to the freshly recomputed accounts,
/// dropping only those whose situation no longer exists (#115).
///
/// A sync rewrites the derived per-account docs wholesale, so operator intent
/// lives in separate [AccountDecision] documents. This merge is what keeps a
/// re-sync from clobbering in-progress work: a decision is kept while its
/// account still carries the situation it resolves —
///
/// - [DecisionKind.chosenAlternative] / [DecisionKind.appliedStatus]: the
///   account still has a candidate whose [CandidateAction.kind] matches the
///   decision's [AccountDecision.targetKind];
/// - [DecisionKind.acceptedDuplicate]: the account still carries a warning (the
///   collision is still present).
///
/// A decision for an account that vanished, or whose situation is resolved, is
/// [DecisionsMerge.dropped].
DecisionsMerge mergeDecisions({
  required List<MaterializedAccount> accounts,
  required List<AccountDecision> existing,
}) {
  final byAccount = <String, List<AccountDecision>>{};
  for (final d in existing) {
    (byAccount[d.accountId.value] ??= <AccountDecision>[]).add(d);
  }

  final merged = <MaterializedAccount>[];
  final surviving = <AccountDecision>[];
  final matchedAccountKeys = <String>{};

  for (final account in accounts) {
    final candidates = byAccount[account.id.value] ?? const <AccountDecision>[];
    if (candidates.isEmpty) {
      merged.add(account);
      continue;
    }
    matchedAccountKeys.add(account.id.value);
    final kept = [
      for (final d in candidates)
        if (_situationExists(account, d)) d,
    ];
    surviving.addAll(kept);
    merged.add(kept.isEmpty ? account : account.withDecisions(kept));
  }

  // Anything not kept — including decisions whose account is gone entirely — is
  // dropped from the store.
  final survivingIds = surviving.toSet();
  final dropped = [
    for (final d in existing)
      if (!survivingIds.contains(d)) d,
  ];

  return DecisionsMerge(
    accounts: merged,
    surviving: surviving,
    dropped: dropped,
  );
}

bool _situationExists(MaterializedAccount account, AccountDecision d) {
  switch (d.kind) {
    case DecisionKind.acceptedDuplicate:
      return account.warnings.isNotEmpty;
    case DecisionKind.chosenAlternative:
    case DecisionKind.appliedStatus:
      return account.candidates.any((c) => c.kind == d.targetKind);
  }
}
