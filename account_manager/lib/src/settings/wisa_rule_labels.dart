/// How a WISA import rule reads to the operator.
///
/// Shared rather than private to the Settings view: since #276 a
/// `DontImportFromWisa` apply writes its rule to the settings document, and the
/// Log panel has to name the rule it just made permanent in exactly the words
/// the Instellingen → Wisa list uses — otherwise the operator reads about one
/// thing on Synchronisatie and finds another under Instellingen.
library;

import 'package:account_state/account_state.dart';
import 'package:wisa_api/wisa_api.dart';

import '../format/timestamps.dart';

/// How one WISA import rule reads in the settings list and the log.
String describeWisaRule(WisaImportRule rule) => switch (rule) {
      DontImportClass(:final className) =>
        'Klas niet importeren uit WISA: $className',
      DontImportUserFromWisa(:final userCode) =>
        'Gebruiker niet importeren uit WISA: $userCode',
      ReplaceInstitute(:final original, :final replacement) =>
        'Vervang instituut: $original → $replacement',
      MarkAsVirtual(:final schoolCode) => 'Markeer als virtueel: $schoolCode',
    };

/// What a provenance field reads as when the document records nothing for it
/// (#285).
///
/// Named rather than blank on purpose. A rule persisted before #285 — or one an
/// unsigned-in session added — genuinely has no answer, and an empty cell reads
/// like nobody did it; "onbekend" says the record is missing, which is the true
/// statement and the one that tells the reader to go and ask.
const String unknownProvenance = 'onbekend';

/// Whom a persisted rule was added *for*: the subject's name as it read when the
/// rule was created, never re-resolved against a later WISA pull (#285).
String describeRuleSubject(RuleProvenance? provenance) =>
    (provenance?.subject.isNotEmpty ?? false)
        ? provenance!.subject
        : unknownProvenance;

/// When a persisted rule was added, as its own readable stamp (#285).
String describeRuleAddedAt(RuleProvenance? provenance) {
  final at = provenance?.addedAt;
  return at == null ? unknownProvenance : formatRuleStamp(at);
}

/// Which operator added a persisted rule (#285) — the load-bearing field, since
/// the record is a pointer to the person who remembers rather than the
/// explanation itself.
String describeRuleAddedBy(RuleProvenance? provenance) =>
    (provenance?.addedBy.isNotEmpty ?? false)
        ? provenance!.addedBy
        : unknownProvenance;
