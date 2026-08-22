/// How a WISA import rule reads to the operator.
///
/// Shared rather than private to the Settings view: since #276 a
/// `DontImportFromWisa` apply writes its rule to the settings document, and the
/// Log panel has to name the rule it just made permanent in exactly the words
/// the Instellingen → Wisa list uses — otherwise the operator reads about one
/// thing on Synchronisatie and finds another under Instellingen.
library;

import 'package:wisa_api/wisa_api.dart';

/// How one WISA import rule reads in the settings list and the log.
String describeWisaRule(WisaImportRule rule) => switch (rule) {
      DontImportClass(:final className) =>
        'Klas niet importeren uit WISA: $className',
      DontImportUserFromWisa(:final userCode) =>
        'Gebruiker niet importeren uit WISA: $userCode',
      ReplaceInstitute(:final original, :final replacement) =>
        'Vervang instituut: $original → $replacement',
      MarkAsVirtual(:final schoolCode) => 'Markeer als virtueel: $schoolCode',
      MarkAsOurs(:final schoolCode) => 'Markeer als beheerd: $schoolCode',
    };
