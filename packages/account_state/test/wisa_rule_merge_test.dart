import 'package:account_state/account_state.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

void main() {
  group('mergeEarnedWisaRules (#276)', () {
    test('appends an earned rule to an empty document', () {
      // The plain case: the first `DontImportFromWisa` apply of a fresh
      // installation. Before #276 nothing ever wrote here, so the rule lived
      // only in the process-lifetime holder and vanished on relaunch.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportUserFromWisa('SMIT')),
        ],
      );

      expect(merged, isNotNull);
      expect(merged!.settings.wisaRules.single, isA<DontImportUserFromWisa>());
      expect(
        (merged.settings.wisaRules.single as DontImportUserFromWisa).userCode,
        'SMIT',
      );
      expect(merged.added, hasLength(1));
    });

    test("keeps the operator's standing rules, and their order", () {
      // The document is shared configuration somebody curated by hand (#273);
      // an apply may only add to it.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(wisaRules: <WisaImportRule>[
          ReplaceInstitute(original: '111', replacement: '222'),
          DontImportUserFromWisa('SMIT'),
        ]),
        earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
      );

      expect(merged!.settings.wisaRules.map((r) => r.runtimeType).toList(),
          <Type>[ReplaceInstitute, DontImportUserFromWisa, DontImportClass]);
    });

    test('leaves every other field of the document untouched', () {
      // The store replaces the whole config document, so a merge that dropped a
      // field would silently un-configure the whole team.
      const stored = AppSettings(
        schoolPrefix: 'SMA',
        debugMode: true,
        wisa: WisaConnection(server: 'wisa.example', port: '9000'),
        smartschoolRules: <ss.SmartschoolImportRule>[
          ss.DiscardSmartschoolGroup('Oud'),
        ],
        wisaSchools: <WisaSchoolProfile>[
          WisaSchoolProfile(schoolId: 25, ours: true),
        ],
      );

      final merged = mergeEarnedWisaRules(
        stored: stored,
        earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
      )!;

      expect(merged.settings.schoolPrefix, 'SMA');
      expect(merged.settings.debugMode, isTrue);
      expect(merged.settings.wisa.server, 'wisa.example');
      expect(merged.settings.smartschoolRules, hasLength(1));
      expect(merged.settings.wisaSchools.single.ours, isTrue);
    });

    test('returns null when the document already carries the rule', () {
      // Applying the same opt-out twice — this session or another operator's —
      // must not grow the persisted list, and must not spend a settings write.
      expect(
        mergeEarnedWisaRules(
          stored: const AppSettings(
            wisaRules: <WisaImportRule>[DontImportClass('3C')],
          ),
          earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
        ),
        isNull,
      );
    });

    test('de-duplicates on WisaImportRules\' own keys, not on identity', () {
      // "Already persisted" has to mean exactly what "already earned this
      // session" means, or the two halves the pull unions would disagree about
      // what a duplicate is.
      // Built at runtime, so this is a different object carrying the same key.
      final sameClass = <String>['3', 'C'].join();
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(
          wisaRules: <WisaImportRule>[DontImportClass('3C')],
        ),
        earned: <EarnedWisaRule>[
          EarnedWisaRule(DontImportClass(sameClass)),
          const EarnedWisaRule(DontImportUserFromWisa('SMIT')),
        ],
      );

      expect(merged!.settings.wisaRules, hasLength(2));
      expect(merged.added.single, isA<DontImportUserFromWisa>());
    });

    test('collapses a rule the same pass earned twice', () {
      // One bulk pass can blacklist the same class through two entries; the
      // document must still grow by one.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportClass('3C')),
          EarnedWisaRule(DontImportClass('3C')),
        ],
      );

      expect(merged!.settings.wisaRules, hasLength(1));
      expect(merged.added, hasLength(1));
    });

    test('returns null for an empty earned set', () {
      expect(
        mergeEarnedWisaRules(
          stored: const AppSettings(),
          earned: const <EarnedWisaRule>[],
        ),
        isNull,
      );
    });

    test('round-trips through the settings codec', () {
      // The merged document is what the store writes, so the appended rule has
      // to survive the wire shape #263's pull reads back.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportUserFromWisa('SMIT')),
        ],
      )!;

      final restored = AppSettings.fromJson(merged.settings.toJson());

      expect(
        (restored.wisaRules.single as DontImportUserFromWisa).userCode,
        'SMIT',
      );
    });
  });

  group('provenance on an earned rule (#285)', () {
    final at = DateTime.utc(2026, 6, 30, 14, 5);

    test('stamps who added it, when, and for whom', () {
      // The whole point of the record: a `DontImportUserFromWisa` stores a bare
      // WISA code, so without this a colleague opening Instellingen next month
      // sees an opaque string and cannot tell what removing it would undo.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportUserFromWisa('SMIT'), subject: 'Jan Smit'),
        ],
        addedBy: 'ann@school.example',
        addedAt: at,
      )!;

      final provenance =
          merged.settings.provenanceOf(const DontImportUserFromWisa('SMIT'));
      expect(provenance, isNotNull);
      expect(provenance!.subject, 'Jan Smit');
      expect(provenance.addedBy, 'ann@school.example');
      expect(provenance.addedAt, at);
    });

    test('records what it knows when the subject name is unknown', () {
      // "By whom" is the load-bearing field — the record is a pointer to the
      // person who remembers — so a missing name must not cost the stamp.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
        addedBy: 'ann@school.example',
        addedAt: at,
      )!;

      final provenance =
          merged.settings.provenanceOf(const DontImportClass('3C'));
      expect(provenance!.subject, isEmpty);
      expect(provenance.addedBy, 'ann@school.example');
      expect(provenance.addedAt, at);
    });

    test('writes no provenance at all when the pass knows nothing', () {
      // An empty record is not the same as an absent one: the view reads absent
      // as "onbekend", and storing three empty strings would be a document
      // claiming to record something it does not.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
      )!;

      expect(merged.settings.wisaRuleProvenance, isEmpty);
      expect(merged.settings.provenanceOf(const DontImportClass('3C')), isNull);
    });

    test('keeps the first operator\'s stamp when two decisions collapse', () {
      // The union puts persisted rules first (#263) and the dedup key ignores
      // provenance, so two operators earning the same rule collapse to one. The
      // standing decision — the one the document has been running on — keeps its
      // author. Deliberate, not incidental.
      final first = RuleProvenance(
        subject: 'Jan Smit',
        addedBy: 'ann@school.example',
        addedAt: DateTime.utc(2026, 1, 1),
      );
      final merged = mergeEarnedWisaRules(
        stored: AppSettings(
          wisaRules: const <WisaImportRule>[DontImportUserFromWisa('SMIT')],
          wisaRuleProvenance: <String, RuleProvenance>{
            'user:SMIT': first,
          },
        ),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportUserFromWisa('SMIT'), subject: 'J. Smit'),
          EarnedWisaRule(DontImportClass('3C'), subject: '3C'),
        ],
        addedBy: 'bob@school.example',
        addedAt: at,
      )!;

      expect(merged.settings.provenanceOf(const DontImportUserFromWisa('SMIT')),
          first);
      expect(
        merged.settings.provenanceOf(const DontImportClass('3C'))!.addedBy,
        'bob@school.example',
      );
    });

    test('leaves the provenance of untouched rules alone', () {
      final standing = RuleProvenance(
        addedBy: 'ann@school.example',
        addedAt: DateTime.utc(2025, 9, 1),
      );
      final merged = mergeEarnedWisaRules(
        stored: AppSettings(
          wisaRules: const <WisaImportRule>[
            ReplaceInstitute(original: '111', replacement: '222'),
          ],
          wisaRuleProvenance: <String, RuleProvenance>{
            'institute:111': standing,
          },
        ),
        earned: const <EarnedWisaRule>[EarnedWisaRule(DontImportClass('3C'))],
        addedBy: 'bob@school.example',
        addedAt: at,
      )!;

      expect(
        merged.settings.provenanceOf(
          const ReplaceInstitute(original: '111', replacement: '222'),
        ),
        standing,
      );
    });

    test('survives the round-trip the store writes and #263 reads back', () {
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <EarnedWisaRule>[
          EarnedWisaRule(DontImportUserFromWisa('SMIT'), subject: 'Jan Smit'),
        ],
        addedBy: 'ann@school.example',
        addedAt: at,
      )!;

      final restored = AppSettings.fromJson(merged.settings.toJson());
      final provenance =
          restored.provenanceOf(const DontImportUserFromWisa('SMIT'))!;

      expect(provenance.subject, 'Jan Smit');
      expect(provenance.addedBy, 'ann@school.example');
      expect(provenance.addedAt, at);
    });

    test('does not move the WISA pull fingerprint', () {
      // Who typed a rule changes nothing about what WISA returns, so a
      // re-stamped document must not arm #238's drift gate — and the apply
      // path's own re-credit (#276) depends on that staying true.
      const stored = AppSettings(
        wisaRules: <WisaImportRule>[DontImportClass('3C')],
      );
      final stamped = stored.copyWith(
        wisaRuleProvenance: <String, RuleProvenance>{
          'class:3C': RuleProvenance(
            subject: '3C',
            addedBy: 'ann@school.example',
            addedAt: at,
          ),
        },
      );

      expect(wisaPullFingerprint(stamped), wisaPullFingerprint(stored));
    });
  });
}
