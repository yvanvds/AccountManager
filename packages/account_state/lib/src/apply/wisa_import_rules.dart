import 'package:wisa_api/wisa_api.dart';

/// A mutable, de-duplicating set of [WisaImportRule]s shared between the WISA
/// [Syncer] and the [StateApplier].
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
/// wire the WISA syncer to read [rules] live, then hand the same instance to
/// the applier:
///
/// ```dart
/// final importRules = WisaImportRules(initial: settings.wisaRules);
/// final wisa = SystemState<WisaSnapshot>(
///   system: Origin.wisa,
///   syncer: (_) => connector.sync(
///     schools: schools,
///     workDate: workDate,
///     rules: importRules.rules, // read live, so a later add() takes effect
///   ),
/// );
/// // ... build ApplicationState, then:
/// final applier = StateApplier(app: app, wisaRules: importRules, ...);
/// ```
///
/// Because the syncer reads [rules] at call time, `applier` only has to
/// [add] the new rule and trigger `app.sync(Origin.wisa)`.
class WisaImportRules {
  WisaImportRules({Iterable<WisaImportRule> initial = const []}) {
    for (final rule in initial) {
      add(rule);
    }
  }

  final List<WisaImportRule> _rules = [];
  final Set<String> _keys = {};

  /// The accumulated rules, in insertion order. Pass this to the WISA
  /// connector's `sync(rules: ...)` — read live so an [add] between syncs is
  /// picked up by the next re-sync.
  List<WisaImportRule> get rules => List.unmodifiable(_rules);

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

  static String _keyOf(WisaImportRule rule) => switch (rule) {
        DontImportClass(:final className) => 'class:$className',
        DontImportUserFromWisa(:final userCode) => 'user:$userCode',
        ReplaceInstitute(:final original) => 'institute:$original',
        MarkAsVirtual(:final schoolCode) => 'virtual:$schoolCode',
        MarkAsOurs(:final schoolCode) => 'ours:$schoolCode',
      };
}
