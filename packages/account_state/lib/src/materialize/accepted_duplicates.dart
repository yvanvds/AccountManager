/// Pure helpers for the **accepted duplicate-mail** decisions (#109).
///
/// The linker raises a [core.ResolveDuplicateMail] warning whenever two or more
/// Smartschool accounts share a `mail` (INV-23). In practice every current
/// collision is deliberate — a person who needs both an admin and a normal user
/// account — so the operator can mark a collision **accepted**, after which it
/// stops warning. That acceptance is persisted as an [AccountDecision] of kind
/// [DecisionKind.acceptedDuplicate] in the shared `decisions` container, so it
/// survives a re-sync (re-attached by [mergeDecisions]) exactly like the
/// chosen-alternative / applied-status intent from #110.
///
/// The acceptance is scoped to the *exact* colliding set: the payload records
/// the shared [mail] and the sorted set of colliding Smartschool [uids]. When
/// the set changes — a third account appears on the same mail — the stored set
/// no longer matches and the warning re-surfaces, so a new, unreviewed collision
/// is never silently suppressed.
///
/// Pure data — no I/O, no Flutter. The store seam persists the decisions; this
/// module only builds and matches them.
library;

import 'package:account_core/account_core.dart' as core;

import 'materialized_state.dart';

/// The JSON payload key holding the shared, normalized mail of an accepted
/// duplicate.
const String acceptedDuplicateMailKey = 'mail';

/// The JSON payload key holding the sorted colliding Smartschool uids an
/// acceptance covers.
const String acceptedDuplicateUidsKey = 'uids';

/// Normalizes a mail for comparison and keying: trimmed and lower-cased, exactly
/// as the linker compares mails (INV-12).
String normalizeDuplicateMail(String mail) => mail.trim().toLowerCase();

/// The sorted, de-duplicated colliding uids — the stable set an acceptance
/// covers, so two acceptances of the same collision key and compare identically
/// regardless of the order the linker listed the accounts.
List<String> sortedDuplicateUids(Iterable<String> uids) =>
    (uids.toSet().toList())..sort();

/// Builds the [AccountDecision] that records [decidedBy] accepting the
/// duplicate-mail collision on [mail] shared by [uids], keyed to [accountId]
/// (one of the colliding accounts, so the merge keeps it while that account
/// still carries a warning).
///
/// [targetKind] is the normalized mail — a stable situation id the re-attach
/// merge matches by presence of any warning on the target ([mergeDecisions]).
AccountDecision acceptedDuplicateDecision({
  required core.LinkedAccountId accountId,
  required String mail,
  required Iterable<String> uids,
  required String decidedBy,
  required DateTime decidedAt,
}) {
  final normalized = normalizeDuplicateMail(mail);
  return AccountDecision(
    accountId: accountId,
    kind: DecisionKind.acceptedDuplicate,
    targetKind: normalized,
    payload: {
      acceptedDuplicateMailKey: normalized,
      acceptedDuplicateUidsKey: sortedDuplicateUids(uids),
    },
    decidedBy: decidedBy,
    decidedAt: decidedAt,
  );
}

/// Reads the colliding uids an [acceptedDuplicate] decision covers, sorted.
/// Empty for a decision of any other kind or a malformed payload.
List<String> acceptedUidsOf(AccountDecision decision) {
  if (decision.kind != DecisionKind.acceptedDuplicate) return const [];
  final raw = decision.payload[acceptedDuplicateUidsKey];
  if (raw is! List) return const [];
  return sortedDuplicateUids([for (final u in raw) u as String]);
}

/// The persisted acceptance covering the collision on [mail] over exactly
/// [uids], or `null` when none matches.
///
/// A match requires both the normalized mail **and** the exact colliding set to
/// agree: a changed set (a new colliding account) yields no match, so the
/// warning re-surfaces (#109).
AccountDecision? findAcceptedDuplicate(
  Iterable<AccountDecision> decisions, {
  required String mail,
  required Iterable<String> uids,
}) {
  final wantMail = normalizeDuplicateMail(mail);
  final wantUids = sortedDuplicateUids(uids);
  for (final d in decisions) {
    if (d.kind != DecisionKind.acceptedDuplicate) continue;
    if ((d.payload[acceptedDuplicateMailKey] as String?) != wantMail) continue;
    final have = acceptedUidsOf(d);
    if (have.length == wantUids.length &&
        List.generate(have.length, (i) => have[i] == wantUids[i])
            .every((e) => e)) {
      return d;
    }
  }
  return null;
}

/// Whether the collision on [mail] over exactly [uids] has been accepted.
bool duplicateAccepted(
  Iterable<AccountDecision> decisions, {
  required String mail,
  required Iterable<String> uids,
}) =>
    findAcceptedDuplicate(decisions, mail: mail, uids: uids) != null;
