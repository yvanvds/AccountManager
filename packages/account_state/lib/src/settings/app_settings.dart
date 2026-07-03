import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import 'import_rule_codec.dart';

/// The persisted configuration model for the Arcadia Account Manager.
///
/// This is the Dart counterpart of the legacy `config.json` (PROJECT_OVERVIEW
/// §7): the operator-tunable settings that survive across runs. This scaffold
/// slice models the two pieces the State layer needs first — the global flags
/// ([schoolPrefix], [debugMode], mirroring the legacy `SettingsState`) and the
/// per-connector **import-rule sets** applied at snapshot construction (spec
/// §3.11). Connection credentials and the WISA workdate pair are deliberately
/// out of scope here; they are the connectors' own live-config concern and
/// will be folded in by a later slice.
///
/// The model is immutable — mutate by [copyWith] and hand the result to a
/// [SettingsStore]. It carries its own `toJson`/`fromJson` so the file-backed
/// store never has to know the field layout.
class AppSettings {
  const AppSettings({
    this.schoolPrefix = '',
    this.debugMode = false,
    this.wisaRules = const [],
    this.smartschoolRules = const [],
  });

  /// The school prefix used by the linker to scope Azure users to this school
  /// (INV-22). Legacy `SettingsState.SchoolPrefix`.
  final String schoolPrefix;

  /// Whether verbose diagnostics are enabled. Legacy `SettingsState.DebugMode`.
  final bool debugMode;

  /// WISA import rules applied at snapshot construction (spec §3.11).
  final List<WisaImportRule> wisaRules;

  /// Smartschool import rules applied at snapshot construction (spec §3.11).
  final List<SmartschoolImportRule> smartschoolRules;

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    String? schoolPrefix,
    bool? debugMode,
    List<WisaImportRule>? wisaRules,
    List<SmartschoolImportRule>? smartschoolRules,
  }) {
    return AppSettings(
      schoolPrefix: schoolPrefix ?? this.schoolPrefix,
      debugMode: debugMode ?? this.debugMode,
      wisaRules: wisaRules ?? this.wisaRules,
      smartschoolRules: smartschoolRules ?? this.smartschoolRules,
    );
  }

  /// Serializes to a JSON-encodable map.
  Map<String, dynamic> toJson() {
    return {
      'schoolPrefix': schoolPrefix,
      'debugMode': debugMode,
      'wisaRules': wisaRules.map(encodeWisaRule).toList(),
      'smartschoolRules': smartschoolRules.map(encodeSmartschoolRule).toList(),
    };
  }

  /// Reconstructs an [AppSettings] from a map produced by [toJson].
  ///
  /// Missing keys fall back to the constructor defaults so an older or
  /// partial config still loads. Throws [FormatException] (via the rule
  /// codecs) if a rule carries an unknown `type` tag.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final wisa = (json['wisaRules'] as List<dynamic>?) ?? const [];
    final smartschool =
        (json['smartschoolRules'] as List<dynamic>?) ?? const [];
    return AppSettings(
      schoolPrefix: (json['schoolPrefix'] as String?) ?? '',
      debugMode: (json['debugMode'] as bool?) ?? false,
      wisaRules: [
        for (final r in wisa) decodeWisaRule(r as Map<String, dynamic>),
      ],
      smartschoolRules: [
        for (final r in smartschool)
          decodeSmartschoolRule(r as Map<String, dynamic>),
      ],
    );
  }
}
