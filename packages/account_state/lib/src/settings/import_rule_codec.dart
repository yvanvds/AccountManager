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
    MarkAsVirtual() => {'type': 'markAsVirtual', 'schoolCode': rule.schoolCode},
    MarkAsOurs() => {'type': 'markAsOurs', 'schoolCode': rule.schoolCode},
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
/// Throws [FormatException] on an unknown or missing `type` tag so a corrupt
/// config surfaces loudly rather than silently dropping rules.
WisaImportRule decodeWisaRule(Map<String, dynamic> json) {
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
      return MarkAsVirtual(json['schoolCode'] as String);
    case 'markAsOurs':
      return MarkAsOurs(json['schoolCode'] as String);
    default:
      throw FormatException('Unknown WisaImportRule type: $type');
  }
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
