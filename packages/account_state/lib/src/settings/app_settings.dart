import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import '../apply/wisa_import_rules.dart';
import 'connection.dart';
import 'import_rule_codec.dart';
import 'rule_provenance.dart';
import 'wifi_network.dart';
import 'wisa_school_profile.dart';

/// The Smartschool group roots a pull is scoped to when the operator has
/// configured none — the two populations this app manages, spelled the way
/// this school's tree spells them (#351).
///
/// A default rather than a hardcoding: the tree is tenant-specific, so the
/// names are editable in Instellingen, and an install whose roots are named
/// otherwise says so there. Adopted by an older settings document too — one
/// written before #351 carries no roots at all, and scoping the pull is what
/// that document *means* now.
const List<String> defaultSmartschoolRoots = <String>[
  'Leerlingen',
  'Personeel',
];

/// The persisted configuration model for the Arcadia Account Manager.
///
/// This is the Dart counterpart of the legacy `config.json` (PROJECT_OVERVIEW
/// §6.2): the operator-tunable settings that survive across runs. It gathers
/// what the legacy per-system `*State` classes each persisted into one
/// immutable value:
///
/// - the global flags ([schoolPrefix], [debugMode]) — legacy `SettingsState`;
/// - the three **connection profiles** ([wisa], [smartschool], [azure]),
///   including the WISA work-date pair and the Smartschool grade/year
///   vocabulary — the config half of the legacy `WisaState`/`SmartschoolState`/
///   `AzureState`;
/// - the per-connector **import-rule sets** applied at snapshot construction
///   (spec §3.11).
///
/// Secrets are **not** here. The WISA password and Smartschool passphrase are
/// modeled as a [SecretRef] on their profile and resolved through a
/// [SecretProvider], so no credential is ever written to the settings blob.
///
/// The model is immutable — mutate by [copyWith] and hand the result to a
/// [SettingsStore]. It carries its own `toJson`/`fromJson` so the file-backed
/// store never has to know the field layout.
class AppSettings {
  const AppSettings({
    this.schoolPrefix = '',
    this.debugMode = false,
    this.wisa = const WisaConnection(),
    this.azure = const AzureConnection(),
    SmartschoolConnection? smartschool,
    this.wisaRules = const [],
    this.wisaRuleProvenance = const <String, RuleProvenance>{},
    this.smartschoolRules = const [],
    this.smartschoolRoots = defaultSmartschoolRoots,
    this.wisaSchools = const [],
    this.staffWifi = defaultStaffWifi,
    this.studentWifi = defaultStudentWifi,
  }) : _smartschool = smartschool;

  /// The school prefix used by the linker to scope Azure users to this school
  /// (INV-22). Legacy `SettingsState.SchoolPrefix`.
  final String schoolPrefix;

  /// Whether verbose diagnostics are enabled. Legacy `SettingsState.DebugMode`.
  final bool debugMode;

  /// WISA connection profile (endpoint, credentials seam, work-date pair).
  final WisaConnection wisa;

  /// Azure AD / Office 365 connection profile (app registration + domain).
  final AzureConnection azure;

  // Held nullable so the constructor can stay `const` — [SmartschoolConnection]
  // normalizes its label arrays in a body initializer and so has no const ctor.
  final SmartschoolConnection? _smartschool;

  /// Smartschool connection profile (endpoint, credentials seam, group paths,
  /// grade/year vocabulary).
  SmartschoolConnection get smartschool =>
      _smartschool ?? SmartschoolConnection();

  /// WISA import rules applied at snapshot construction (spec §3.11).
  final List<WisaImportRule> wisaRules;

  /// Provenance for the persisted [wisaRules], keyed by [wisaRuleKey] (#285).
  ///
  /// Keyed rather than positional, and separate from the rules themselves,
  /// because the rule types belong to `wisa_api` and know nothing about
  /// operators — on the wire the two travel in one object (see
  /// [encodeWisaRule]), and only here are they two values. A rule with no entry
  /// is one persisted before #285; [provenanceOf] answers `null` for it and the
  /// view says `onbekend`.
  ///
  /// The key is the same identity [WisaImportRules] de-duplicates on, so two
  /// operators earning the same rule collapse to one decision carrying the
  /// **first** one's provenance — deliberately, since that is the decision the
  /// document has been standing on.
  final Map<String, RuleProvenance> wisaRuleProvenance;

  /// Who added [rule], when, and for whom — or `null` when the document records
  /// nothing about it (#285).
  RuleProvenance? provenanceOf(WisaImportRule rule) =>
      wisaRuleProvenance[wisaRuleKey(rule)];

  /// Smartschool import rules applied at snapshot construction (spec §3.11).
  final List<SmartschoolImportRule> smartschoolRules;

  /// The Smartschool group roots the pull is scoped to (#351).
  ///
  /// The connector walks these subtrees and nothing else, so an account that
  /// sits only in a beheerders or externen group never enters the snapshot —
  /// and cannot become a `LinkedStaff` of its own downstream, where the
  /// student/staff split is decided on `Basisrol` alone. Matched on
  /// `normalizeGroupName`, like the import rules.
  ///
  /// [defaultSmartschoolRoots] until an operator says otherwise. **Empty means
  /// unscoped**: the whole forest, as every pull did before #351 — the escape
  /// hatch for a tenant whose tree has no such roots.
  final List<String> smartschoolRoots;

  /// The WiFi network printed on a **staff** password sheet (#368).
  ///
  /// [defaultStaffWifi] until an operator says otherwise, so a document written
  /// before the fields existed prints exactly what it printed before. An empty
  /// [WifiNetwork.ssid] is a decision, not a gap: it omits the WiFi block from
  /// the sheet entirely.
  final WifiNetwork staffWifi;

  /// The WiFi network printed on a **student** password sheet (#368) — the
  /// [staffWifi] counterpart, defaulting to [defaultStudentWifi].
  final WifiNetwork studentWifi;

  /// Per-WISA-school ownership entries, keyed by school id. Empty means no
  /// school has been marked managed yet — the group-membership plumbing #113
  /// slice 2 reads, but no action fires here.
  final List<WisaSchoolProfile> wisaSchools;

  /// The set of WISA school ids the operator manages — the `ours`-flagged
  /// entries of [wisaSchools] (#178). This is what the linker joins student
  /// membership against so `wisaPresence` is authoritative from Settings, and
  /// since #286 it is the *only* source of ownership. Empty means ownership is
  /// unconfigured, which every reader treats as "every school counts" rather
  /// than "no school is ours" — the honest answer for an install that has not
  /// filled the WISA-scholen list in yet.
  Set<int> get managedWisaSchoolIds => <int>{
        for (final p in wisaSchools)
          if (p.ours) p.schoolId,
      };

  /// The set of WISA school ids the operator marked *virtual* — the
  /// `virtual`-flagged entries of [wisaSchools] (#203). A sync flags exactly
  /// these schools, so the connector pulls them with the
  /// [WisaConnection.virtualWorkDate] instead of the ordinary work date; empty
  /// means no school is virtual and every school pulls with the ordinary one.
  Set<int> get virtualWisaSchoolIds => <int>{
        for (final p in wisaSchools)
          if (p.virtual) p.schoolId,
      };

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    String? schoolPrefix,
    bool? debugMode,
    WisaConnection? wisa,
    AzureConnection? azure,
    SmartschoolConnection? smartschool,
    List<WisaImportRule>? wisaRules,
    Map<String, RuleProvenance>? wisaRuleProvenance,
    List<SmartschoolImportRule>? smartschoolRules,
    List<String>? smartschoolRoots,
    List<WisaSchoolProfile>? wisaSchools,
    WifiNetwork? staffWifi,
    WifiNetwork? studentWifi,
  }) {
    return AppSettings(
      schoolPrefix: schoolPrefix ?? this.schoolPrefix,
      debugMode: debugMode ?? this.debugMode,
      wisa: wisa ?? this.wisa,
      azure: azure ?? this.azure,
      smartschool: smartschool ?? this.smartschool,
      wisaRules: wisaRules ?? this.wisaRules,
      wisaRuleProvenance: wisaRuleProvenance ?? this.wisaRuleProvenance,
      smartschoolRules: smartschoolRules ?? this.smartschoolRules,
      smartschoolRoots: smartschoolRoots ?? this.smartschoolRoots,
      wisaSchools: wisaSchools ?? this.wisaSchools,
      staffWifi: staffWifi ?? this.staffWifi,
      studentWifi: studentWifi ?? this.studentWifi,
    );
  }

  /// Serializes to a JSON-encodable map. No secret value is written — the
  /// profiles emit only a [SecretRef] name.
  Map<String, dynamic> toJson() {
    return {
      'schoolPrefix': schoolPrefix,
      'debugMode': debugMode,
      'wisa': wisa.toJson(),
      'smartschool': smartschool.toJson(),
      'azure': azure.toJson(),
      // Each rule's provenance rides inside its own object (#285), so a stored
      // rule and the record of who decided it can never come apart. A rule the
      // document knows nothing about encodes exactly as it did before #285.
      'wisaRules': <Map<String, dynamic>>[
        for (final rule in wisaRules)
          encodeWisaRule(rule, provenance: provenanceOf(rule)),
      ],
      'smartschoolRules': smartschoolRules.map(encodeSmartschoolRule).toList(),
      'smartschoolRoots': smartschoolRoots,
      'wisaSchools': wisaSchools.map((p) => p.toJson()).toList(),
      'staffWifi': staffWifi.toJson(),
      'studentWifi': studentWifi.toJson(),
    };
  }

  /// Reconstructs an [AppSettings] from a map produced by [toJson].
  ///
  /// Missing keys fall back to the constructor defaults so an older or
  /// partial config still loads. Throws [FormatException] (via the rule
  /// codecs) if a rule carries an unknown `type` tag.
  ///
  /// This is also where the one-shot #277 migration runs: a persisted
  /// `markAsVirtual` rule becomes the matching school's
  /// [WisaSchoolProfile.virtual] flag. It lives here rather than in the app
  /// because both halves — the rules and the school rows — are in this one
  /// document, so no fetch has to complete first and every operator's session
  /// reaches the same answer. It rewrites nothing by itself: the migrated flag
  /// is simply what the document means from now on, and the next ordinary save
  /// writes it back without the rule.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final wisa = (json['wisaRules'] as List<dynamic>?) ?? const [];
    final smartschool =
        (json['smartschoolRules'] as List<dynamic>?) ?? const [];
    final roots = json['smartschoolRoots'] as List<dynamic>?;
    final wisaConn = json['wisa'] as Map<String, dynamic>?;
    final smartschoolConn = json['smartschool'] as Map<String, dynamic>?;
    final azureConn = json['azure'] as Map<String, dynamic>?;
    final wisaSchools = (json['wisaSchools'] as List<dynamic>?) ?? const [];
    final staffWifi = json['staffWifi'] as Map<String, dynamic>?;
    final studentWifi = json['studentWifi'] as Map<String, dynamic>?;
    // The rule and its provenance share one object on the wire (#285) and are
    // two values in memory, so they are split in one pass rather than by
    // decoding the list twice.
    //
    // A retired rule kind decodes as null and is dropped, provenance and all
    // (#286): the document loads, and the entry is gone from the next save.
    //
    // `markAsVirtual` (#277) is retired the same way but not merely dropped —
    // it was live configuration. Its school code is collected here and handed to
    // `adoptRetiredVirtualMarks` below, which sets the WISA-scholen grid's own
    // per-school `virtual` flag instead. Provenance goes with the rule: the mark
    // now belongs to a school row, which records none.
    final wisaRules = <WisaImportRule>[];
    final wisaRuleProvenance = <String, RuleProvenance>{};
    final retiredVirtualCodes = <String>{};
    for (final r in wisa) {
      final encoded = r as Map<String, dynamic>;
      final retiredVirtual = retiredVirtualCodeOf(encoded);
      if (retiredVirtual != null) retiredVirtualCodes.add(retiredVirtual);
      final rule = decodeWisaRule(encoded);
      if (rule == null) continue;
      wisaRules.add(rule);
      final provenance = decodeWisaRuleProvenance(encoded);
      if (provenance != null) {
        wisaRuleProvenance[wisaRuleKey(rule)] = provenance;
      }
    }
    return AppSettings(
      schoolPrefix: (json['schoolPrefix'] as String?) ?? '',
      debugMode: (json['debugMode'] as bool?) ?? false,
      wisa: wisaConn == null
          ? const WisaConnection()
          : WisaConnection.fromJson(wisaConn),
      smartschool: smartschoolConn == null
          ? null
          : SmartschoolConnection.fromJson(smartschoolConn),
      azure: azureConn == null
          ? const AzureConnection()
          : AzureConnection.fromJson(azureConn),
      wisaRules: wisaRules,
      wisaRuleProvenance: wisaRuleProvenance,
      smartschoolRules: [
        for (final r in smartschool)
          decodeSmartschoolRule(r as Map<String, dynamic>),
      ],
      // Absent ⇒ the defaults (#351): a document written before the roots
      // existed is one that never chose to pull the whole tree, it simply had
      // no say. Present-but-empty is a choice, and it is honoured — that is how
      // a tenant with no such roots turns the scoping off.
      smartschoolRoots: roots == null
          ? defaultSmartschoolRoots
          : <String>[for (final r in roots) r as String],
      // Absent ⇒ the literals the sheets used to hardcode (#368), for the same
      // reason the roots above adopt their defaults: a document written before
      // the fields existed never chose to print no WiFi block, and re-defaulting
      // is what keeps the first sheets after an upgrade whole. Present is taken
      // as given — an emptied SSID is the operator turning the block off.
      staffWifi: staffWifi == null
          ? defaultStaffWifi
          : WifiNetwork.fromJson(staffWifi),
      studentWifi: studentWifi == null
          ? defaultStudentWifi
          : WifiNetwork.fromJson(studentWifi),
      wisaSchools: adoptRetiredVirtualMarks(
        <WisaSchoolProfile>[
          for (final p in wisaSchools)
            WisaSchoolProfile.fromJson(p as Map<String, dynamic>),
        ],
        retiredVirtualCodes,
      ),
    );
  }
}
