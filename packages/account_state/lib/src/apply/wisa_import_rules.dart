import 'package:wisa_api/wisa_api.dart';

/// A mutable, de-duplicating set of [WisaImportRule]s shared between the WISA
/// [Syncer] and the [StateApplier] — the rules **this session earned**.
///
/// WISA is read-only, so the `DontImportFromWisa` actions (student/staff
/// [DontImportUserFromWisa], group [DontImportClass]) cannot write anything;
/// instead they hand back a rule for the State layer to accumulate here and
/// re-sync WISA, which drops the ignored record from the next snapshot
/// (spec `docs/domain-model.md` §3.11; #72).
///
/// ## Wiring contract
///
/// This holder is the seam that lets [StateApplier] re-sync WISA with the
/// accumulated rules **without** re-wiring the [SystemState]. Build it once,
/// wire the WISA syncer to read the rules live, then hand the same instance to
/// the applier:
///
/// ```dart
/// final importRules = WisaImportRules();
/// final wisa = SystemState<WisaSnapshot>(
///   system: Origin.wisa,
///   syncer: (_) => connector.sync(
///     schools: schools,
///     workDate: workDate,
///     // read live, so a later add() — and a later save — takes effect
///     rules: importRules.unionWith(live.current.wisaRules),
///   ),
/// );
/// // ... build ApplicationState, then:
/// final applier = StateApplier(app: app, wisaRules: importRules, ...);
/// ```
///
/// Because the syncer composes the rules at call time, `applier` only has to
/// [add] the new rule and trigger `app.sync(Origin.wisa)`.
///
/// ## Why the persisted rules are *not* seeded in here (#263)
///
/// The obvious wiring — `WisaImportRules(initial: settings.wisaRules)` at
/// bootstrap — is what this holder used to get, and it froze the operator's
/// persisted rules for the life of the process: nothing ever published a saved
/// settings document back into the holder, so a rule the operator (or another
/// operator, through the shared document) added reached the pull only after a
/// relaunch, and a rule *removed* from the document could never be dropped at
/// all. So the two sources stay distinct — persisted rules on the settings
/// document, read live at pull time through [unionWith]; session-earned rules
/// here — and the pull unions them.
///
/// ## An earned rule is persisted too (#276)
///
/// This holder is no longer the *record* of a `DontImportFromWisa` apply, only
/// its immediate effect: it is what lets the applier re-sync WISA at once,
/// without waiting for a settings round-trip. The app layer writes the same rule
/// to the settings document (`mergeEarnedWisaRules`) when the apply pass ends,
/// because the exclusion is a standing decision — WISA keeps reporting a retired
/// staff member active indefinitely — and a rule that died with the process made
/// the app propose re-creating the very account it had just been told to stop
/// importing. The two copies collapse to one at the next pull, exactly as
/// [unionWith] collapses any other overlap.
class WisaImportRules {
  WisaImportRules({Iterable<WisaImportRule> initial = const []}) {
    for (final rule in initial) {
      add(rule);
    }
  }

  final List<WisaImportRule> _rules = [];
  final Set<String> _keys = {};

  /// The rules this session accumulated, in insertion order. A pull wants
  /// [unionWith] instead — this is only the session's own half.
  List<WisaImportRule> get rules => List.unmodifiable(_rules);

  /// The rules one WISA pull should apply: the operator's [persisted] rules —
  /// read from the live settings document at pull time — followed by the ones
  /// this session earned, de-duplicated exactly as [add] de-duplicates (#263).
  ///
  /// Persisted first because they are the operator's standing configuration;
  /// the session's own `DontImportFromWisa` rules are the increment on top. A
  /// rule present in both collapses to one, so re-applying a `DontImportClass`
  /// the document already carries changes nothing.
  List<WisaImportRule> unionWith(Iterable<WisaImportRule> persisted) {
    final keys = <String>{};
    final merged = <WisaImportRule>[];
    for (final rule in <WisaImportRule>[...persisted, ..._rules]) {
      if (keys.add(_keyOf(rule))) merged.add(rule);
    }
    return List.unmodifiable(merged);
  }

  /// Adds [rule] unless a structurally-equal rule is already present. Returns
  /// `true` if the set changed. De-duplication keeps a repeated
  /// `DontImportFromWisa` apply (or a rule already loaded from settings) from
  /// growing the set unbounded — applying the same rule twice is a no-op for
  /// the snapshot either way.
  bool add(WisaImportRule rule) {
    if (!_keys.add(_keyOf(rule))) return false;
    _rules.add(rule);
    return true;
  }

  static String _keyOf(WisaImportRule rule) => wisaRuleKey(rule);
}

/// The identity two WISA import rules are the *same rule* by: the fields that
/// decide what the rule matches, and nothing else.
///
/// [WisaImportRules] de-duplicates on this, and so does everything that has to
/// agree with it about what a duplicate is — the settings document's per-rule
/// provenance is keyed by it (#285), so metadata attaches to the decision rather
/// than to one particular object, and a rule the document already carries keeps
/// the provenance of whoever decided it first.
///
/// Derived from the identifying fields rather than the whole record on purpose:
/// that is what lets provenance ride along without changing what a duplicate is.
/// Note [ReplaceInstitute] keys on [ReplaceInstitute.original] alone — two rules
/// rewriting the same institute to different targets are one decision, correctly
/// stated once.
String wisaRuleKey(WisaImportRule rule) => switch (rule) {
      DontImportClass(:final className) => 'class:$className',
      DontImportUserFromWisa(:final userCode) => 'user:$userCode',
      ReplaceInstitute(:final original) => 'institute:$original',
      MarkAsVirtual(:final schoolCode) => 'virtual:$schoolCode',
    };
