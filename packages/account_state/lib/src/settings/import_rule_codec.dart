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
library;

import 'package:smartschool_api/smartschool_api.dart';
import 'package:wisa_api/wisa_api.dart';

/// Encodes a [WisaImportRule] to its tagged-JSON map.
Map<String, dynamic> encodeWisaRule(WisaImportRule rule) {
  switch (rule) {
    case DontImportClass():
      return {'type': 'dontImportClass', 'className': rule.className};
    case DontImportUserFromWisa():
      return {'type': 'dontImportUserFromWisa', 'userCode': rule.userCode};
    case ReplaceInstitute():
      return {
        'type': 'replaceInstitute',
        'original': rule.original,
        'replacement': rule.replacement,
      };
    case MarkAsVirtual():
      return {'type': 'markAsVirtual', 'schoolCode': rule.schoolCode};
  }
}

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
