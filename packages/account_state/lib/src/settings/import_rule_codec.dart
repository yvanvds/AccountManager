/// JSON codecs for the connector import-rule sealed types.
///
/// The rule types ([WisaImportRule], [SmartschoolImportRule]) live in the
/// connector packages and are intentionally free of any serialization concern
/// — they model snapshot-time behaviour, nothing more. This package owns the
/// on-disk representation, so the mapping between a rule and its JSON shape is
/// quarantined here rather than leaking into the pure domain types.
///
/// The wire shape is a tagged object: `{ "type": "<tag>", ... }`. Tags are
/// stable strings (not enum indices) so reordering the sealed hierarchy never
/// changes a persisted config.
///
/// A WISA rule's object also carries its [RuleProvenance] — who added it, when,
/// and for whom (#285) — beside the rule's own fields rather than in a parallel
/// structure, so the two can never come apart on the wire.
library;

import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

import 'rule_provenance.dart';

/// Encodes a [WisaImportRule] to its tagged-JSON map, with [provenance] — when
/// known — merged in beside the rule's own fields (#285).
///
/// The provenance keys (`subject`, `addedBy`, `addedAt`) are disjoint from every
/// rule's own, and omitting them yields exactly the object every version before
/// #285 wrote. That matters beyond backward compatibility: `wisaPullFingerprint`
/// encodes the rules **without** provenance, because who typed a rule changes
/// nothing about what the pull returns, and a re-stamped rule must not arm
/// #238's drift gate.
Map<String, dynamic> encodeWisaRule(
  WisaImportRule rule, {
  RuleProvenance? provenance,
}) {
  final Map<String, dynamic> encoded = switch (rule) {
    DontImportClass() => {
        'type': 'dontImportClass',
        'className': rule.className
      },
    DontImportUserFromWisa() => {
        'type': 'dontImportUserFromWisa',
        'userCode': rule.userCode,
      },
    ReplaceInstitute() => {
        'type': 'replaceInstitute',
        'original': rule.original,
        'replacement': rule.replacement,
      },
  };
  final Map<String, dynamic> extra = provenance?.toJson() ?? const {};
  if (extra.isEmpty) return encoded;
  return <String, dynamic>{...encoded, ...extra};
}

/// Reads the [RuleProvenance] out of a map produced by [encodeWisaRule], or
/// `null` when it carries none — which is every rule persisted before #285.
///
/// Split from [decodeWisaRule] rather than folded into it because the rule types
/// are `wisa_api`'s and must stay free of it: the rule and its provenance travel
/// in one object but are two values, and only this package holds both.
RuleProvenance? decodeWisaRuleProvenance(Map<String, dynamic> json) =>
    RuleProvenance.fromJson(json);

/// Decodes a tagged-JSON map produced by [encodeWisaRule].
///
/// Returns `null` for a **retired** tag — a rule kind this app no longer has:
/// the `markAsOurs` dropped by #286 and the `markAsVirtual` dropped by #277. A
/// document another operator (or an older build) wrote still loads; the entry is
/// simply ignored and disappears from the document the next time it is saved.
/// Both school-marking rules duplicated the WISA-scholen grid in Settings, which
/// marks by school **id** and is now the only surface for either flag.
///
/// `markAsOurs` can be dropped outright, the rule having done nothing for years.
/// `markAsVirtual` was live, so it is not merely dropped: [retiredVirtualCodeOf]
/// reads its school code back out of the same object, and `AppSettings.fromJson`
/// carries the mark over to the grid's per-school flag (#277).
///
/// Throws [FormatException] on an unknown or missing `type` tag so a corrupt
/// config surfaces loudly rather than silently dropping rules.
WisaImportRule? decodeWisaRule(Map<String, dynamic> json) {
  final type = json['type'];
  switch (type) {
    case 'dontImportClass':
      return DontImportClass(json['className'] as String);
    case 'dontImportUserFromWisa':
      return DontImportUserFromWisa(json['userCode'] as String);
    case 'replaceInstitute':
      return ReplaceInstitute(
        original: json['original'] as String,
        replacement: json['replacement'] as String,
      );
    case 'markAsVirtual':
    case 'markAsOurs':
      return null;
    default:
      throw FormatException('Unknown WisaImportRule type: $type');
  }
}

/// The school code a persisted, now-retired `markAsVirtual` entry marked — or
/// `null` for every other entry, retired or live (#277).
///
/// Exists because [decodeWisaRule] deliberately answers `null` for the retired
/// tag and so cannot hand the code back: the mark is real configuration, not
/// dead weight, and it has to reach the WISA-scholen grid's per-school `virtual`
/// flag before the entry is dropped. Kept here with the rest of the wire shape
/// so no reader outside this file has to know the tag's spelling.
///
/// A malformed entry (no `schoolCode`, or a non-string one) answers `null`
/// rather than throwing: it marked no school when it was live either, and a
/// settings document must not fail to load over a rule kind that no longer
/// exists.
String? retiredVirtualCodeOf(Map<String, dynamic> json) {
  if (json['type'] != 'markAsVirtual') return null;
  final code = json['schoolCode'];
  return code is String ? code : null;
}

/// Encodes a [SmartschoolImportRule] to its tagged-JSON map.
Map<String, dynamic> encodeSmartschoolRule(SmartschoolImportRule rule) {
  switch (rule) {
    case DiscardSmartschoolGroup():
      return {'type': 'discardSmartschoolGroup', 'groupName': rule.groupName};
    case NoSmartschoolSubgroups():
      return {'type': 'noSmartschoolSubgroups', 'groupName': rule.groupName};
  }
}

/// Decodes a tagged-JSON map produced by [encodeSmartschoolRule].
///
/// Throws [FormatException] on an unknown or missing `type` tag.
SmartschoolImportRule decodeSmartschoolRule(Map<String, dynamic> json) {
  final type = json['type'];
  switch (type) {
    case 'discardSmartschoolGroup':
      return DiscardSmartschoolGroup(json['groupName'] as String);
    case 'noSmartschoolSubgroups':
      return NoSmartschoolSubgroups(json['groupName'] as String);
    default:
      throw FormatException('Unknown SmartschoolImportRule type: $type');
  }
}
