import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('RuleProvenance (#285)', () {
    test('normalizes its timestamp to UTC', () {
      // The settings document is shared; two operators must not read the same
      // rule as added at two different times because one of them saved it with
      // a local stamp.
      final local = DateTime(2026, 6, 30, 14, 5);
      final provenance = RuleProvenance(addedAt: local);

      expect(provenance.addedAt!.isUtc, isTrue);
      expect(provenance.addedAt!.isAtSameMomentAs(local), isTrue);
    });

    test('omits the fields it does not know', () {
      // An absent field and an empty one are different claims: absent means
      // "not recorded", which the view renders as "onbekend".
      final json = RuleProvenance(addedBy: 'ann@school.example').toJson();

      expect(json.keys, <String>['addedBy']);
    });

    test('an all-empty record is no record', () {
      expect(RuleProvenance().isEmpty, isTrue);
      expect(RuleProvenance.fromJson(<String, dynamic>{}), isNull);
    });

    test('an unparseable timestamp degrades instead of throwing', () {
      // The rule itself still applies perfectly; refusing to load the whole
      // tenant configuration over a cosmetic metadata string would be worse than
      // the missing stamp.
      final provenance = RuleProvenance.fromJson(<String, dynamic>{
        'addedBy': 'ann@school.example',
        'addedAt': 'niet-een-datum',
      });

      expect(provenance!.addedBy, 'ann@school.example');
      expect(provenance.addedAt, isNull);
    });
  });

  group('the persisted rule carries its provenance (#285)', () {
    final at = DateTime.utc(2026, 6, 30, 14, 5);

    test('encodes beside the rule, in the same object', () {
      // Rule and provenance travel together on the wire so they can never come
      // apart — a parallel array keyed by position is exactly what a hand-edited
      // Cosmos document would desynchronize.
      final json = encodeWisaRule(
        const DontImportUserFromWisa('SMIT'),
        provenance: RuleProvenance(
          subject: 'Jan Smit',
          addedBy: 'ann@school.example',
          addedAt: at,
        ),
      );

      expect(json, <String, dynamic>{
        'type': 'dontImportUserFromWisa',
        'userCode': 'SMIT',
        'subject': 'Jan Smit',
        'addedBy': 'ann@school.example',
        'addedAt': at.toIso8601String(),
      });
    });

    test('encodes exactly as before when there is none', () {
      // The shape every version before #285 wrote, byte for byte — which is what
      // keeps `wisaPullFingerprint` stable across the upgrade.
      expect(
        encodeWisaRule(const DontImportClass('3C')),
        <String, dynamic>{'type': 'dontImportClass', 'className': '3C'},
      );
    });

    test('the rule decodes unchanged from an object carrying provenance', () {
      // `wisa_api`'s rule classes are untouched by this feature: the extra keys
      // are simply not theirs to know about.
      final json = encodeWisaRule(
        const DontImportClass('3C'),
        provenance: RuleProvenance(addedBy: 'ann@school.example', addedAt: at),
      );

      expect((decodeWisaRule(json) as DontImportClass).className, '3C');
    });

    test('a document written before #285 reads as no provenance', () {
      // The acceptance criterion: those rules must render honestly as
      // "onbekend", which means the decode has to answer null rather than an
      // empty record that looks like a real one.
      final legacy = jsonDecode(jsonEncode(<String, dynamic>{
        'wisaRules': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'dontImportClass', 'className': '3C'},
        ],
      })) as Map<String, dynamic>;

      final settings = AppSettings.fromJson(legacy);

      expect(settings.wisaRules, hasLength(1));
      expect(settings.wisaRuleProvenance, isEmpty);
      expect(settings.provenanceOf(const DontImportClass('3C')), isNull);
    });

    test('the document round-trips provenance for every rule that has it', () {
      final settings = AppSettings(
        wisaRules: const <WisaImportRule>[
          DontImportClass('3C'),
          DontImportUserFromWisa('SMIT'),
        ],
        wisaRuleProvenance: <String, RuleProvenance>{
          'user:SMIT': RuleProvenance(
            subject: 'Jan Smit',
            addedBy: 'ann@school.example',
            addedAt: at,
          ),
        },
      );

      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );

      expect(restored.provenanceOf(const DontImportClass('3C')), isNull);
      expect(
        restored.provenanceOf(const DontImportUserFromWisa('SMIT'))!.subject,
        'Jan Smit',
      );
      expect(
        restored.provenanceOf(const DontImportUserFromWisa('SMIT'))!.addedAt,
        at,
      );
    });

    test('provenance for a rule no longer on the document is not written', () {
      // The map is keyed, not positional, so a stale entry cannot resurface
      // attached to some later rule: nothing writes what no rule claims.
      final settings = AppSettings(
        wisaRules: const <WisaImportRule>[DontImportClass('3C')],
        wisaRuleProvenance: <String, RuleProvenance>{
          'user:SMIT': RuleProvenance(addedBy: 'ann@school.example'),
        },
      );

      final encoded = settings.toJson()['wisaRules'] as List<dynamic>;

      expect(encoded.single, <String, dynamic>{
        'type': 'dontImportClass',
        'className': '3C',
      });
    });

    test('wisaRuleKey is the key WisaImportRules de-duplicates on', () {
      // Provenance keys on it, so the two must not be allowed to drift: a
      // duplicate for the holder has to be the same decision for the document.
      final holder = WisaImportRules();
      expect(holder.add(const DontImportClass('3C')), isTrue);
      expect(holder.add(DontImportClass(<String>['3', 'C'].join())), isFalse);
      expect(
        wisaRuleKey(const DontImportClass('3C')),
        wisaRuleKey(DontImportClass(<String>['3', 'C'].join())),
      );
    });
  });
}
