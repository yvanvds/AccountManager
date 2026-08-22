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
MergedWisaRules? mergeEarnedWisaRules({
  required AppSettings stored,
  required Iterable<WisaImportRule> earned,
}) {
  final merged = WisaImportRules(initial: stored.wisaRules);
  final added = <WisaImportRule>[
    for (final rule in earned)
      if (merged.add(rule)) rule,
  ];
  if (added.isEmpty) return null;
  return MergedWisaRules(
    settings: stored.copyWith(wisaRules: merged.rules),
    added: added,
  );
}
