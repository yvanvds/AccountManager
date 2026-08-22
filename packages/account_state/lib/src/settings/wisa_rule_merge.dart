/// Folding session-earned WISA import rules into the settings document (#276).
///
/// A `DontImportFromWisa` apply produces a [WisaImportRule] rather than a write
/// — WISA is read-only — and the State layer accumulates it in the session's
/// [WisaImportRules] holder. That holder is rebuilt empty on every launch, so
/// on its own the exclusion is a one-run decision. It is not: the rules exist
/// for staff who retired or left while WISA still reports an *actief
/// dienstverband*, which it will keep doing indefinitely. Persisting the rule is
/// what makes the exclusion the standing decision it is meant to be, and what
/// keeps the app from proposing to re-create an account it was just told to
/// delete.
///
/// The merge lives here — beside the document it writes — rather than in the
/// applier, because the store and the operator identity are an app-layer
/// concern; the applier only earns the rule.
library;

import 'package:wisa_api/wisa_api.dart';

import '../apply/wisa_import_rules.dart';
import 'app_settings.dart';
import 'rule_provenance.dart';

/// One rule an apply pass earned, with the name of whoever (or whatever) it was
/// earned *about* (#285).
///
/// The subject travels per rule while the operator and the timestamp are
/// arguments to the whole merge, because that is how a pass actually works: one
/// operator, one instant, thirty departed teachers. The name is the label the
/// apply already had in hand for the record it acted on — captured here, at the
/// moment of the decision, and never refreshed afterwards. That is the point:
/// the staff a `DontImportFromWisa` is about are exactly the ones who later
/// vanish from WISA, so a name resolved lazily at render time would be blank
/// precisely when it is needed.
class EarnedWisaRule {
  const EarnedWisaRule(this.rule, {this.subject = ''});

  /// The rule the apply produced.
  final WisaImportRule rule;

  /// The subject's name as it read at the time — empty when the caller knows
  /// none, which records honestly as "onbekend" rather than as a blank.
  final String subject;
}

/// What [mergeEarnedWisaRules] produced: the document to save, and the rules
/// that were genuinely new to it.
///
/// [added] is what the caller reports to the operator — a permanent, shared
/// change owes them a line naming it — and is never empty (a merge that adds
/// nothing returns `null` instead of an empty result).
class MergedWisaRules {
  const MergedWisaRules({required this.settings, required this.added});

  /// [AppSettings] with [added] appended to its persisted WISA import rules.
  final AppSettings settings;

  /// The rules this merge appended, in the order they were earned.
  final List<WisaImportRule> added;
}

/// Appends the session-[earned] WISA import rules to [stored]'s persisted rule
/// list, or returns `null` when the document already carries every one of them
/// and there is nothing to write.
///
/// De-duplication is [WisaImportRules]' own: the merge runs the persisted rules
/// and the earned ones through a single holder, so "already persisted" means
/// exactly what "already earned this session" means — same key per rule kind,
/// same collapse. Applying the same `DontImportFromWisa` twice therefore cannot
/// grow the document, whether the first apply happened in this session or in
/// another operator's.
///
/// Nothing else on the document is touched, and the existing rules keep their
/// order: the operator's standing configuration is theirs, and an apply only
/// adds to it.
///
/// ## Provenance (#285)
///
/// Every rule this merge genuinely appends is stamped with [addedBy], [addedAt]
/// and its own [EarnedWisaRule.subject], so a colleague opening Instellingen
/// next month reads who decided it, when, and about whom instead of a bare WISA
/// code. A rule the document **already** carries is not re-stamped: it collapses
/// into the standing decision, which keeps the provenance of whoever made it
/// first. That is the desired outcome of the collapse rather than an incidental
/// one — the earlier decision is the one the document has been standing on.
MergedWisaRules? mergeEarnedWisaRules({
  required AppSettings stored,
  required Iterable<EarnedWisaRule> earned,
  String addedBy = '',
  DateTime? addedAt,
}) {
  final merged = WisaImportRules(initial: stored.wisaRules);
  final added = <WisaImportRule>[];
  final provenance = Map<String, RuleProvenance>.of(stored.wisaRuleProvenance);
  for (final entry in earned) {
    if (!merged.add(entry.rule)) continue;
    added.add(entry.rule);
    final record = RuleProvenance(
      subject: entry.subject,
      addedBy: addedBy,
      addedAt: addedAt,
    );
    if (record.isNotEmpty) provenance[wisaRuleKey(entry.rule)] = record;
  }
  if (added.isEmpty) return null;
  return MergedWisaRules(
    settings: stored.copyWith(
      wisaRules: merged.rules,
      wisaRuleProvenance: provenance,
    ),
    added: added,
  );
}
