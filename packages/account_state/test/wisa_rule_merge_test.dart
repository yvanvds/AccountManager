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
        earned: const <WisaImportRule>[DontImportUserFromWisa('SMIT')],
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
          MarkAsVirtual('V1'),
        ]),
        earned: const <WisaImportRule>[DontImportClass('3C')],
      );

      expect(merged!.settings.wisaRules.map((r) => r.runtimeType).toList(),
          <Type>[ReplaceInstitute, MarkAsVirtual, DontImportClass]);
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
        earned: const <WisaImportRule>[DontImportClass('3C')],
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
          earned: const <WisaImportRule>[DontImportClass('3C')],
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
        earned: <WisaImportRule>[
          DontImportClass(sameClass),
          const DontImportUserFromWisa('SMIT'),
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
        earned: const <WisaImportRule>[
          DontImportClass('3C'),
          DontImportClass('3C'),
        ],
      );

      expect(merged!.settings.wisaRules, hasLength(1));
      expect(merged.added, hasLength(1));
    });

    test('returns null for an empty earned set', () {
      expect(
        mergeEarnedWisaRules(
          stored: const AppSettings(),
          earned: const <WisaImportRule>[],
        ),
        isNull,
      );
    });

    test('round-trips through the settings codec', () {
      // The merged document is what the store writes, so the appended rule has
      // to survive the wire shape #263's pull reads back.
      final merged = mergeEarnedWisaRules(
        stored: const AppSettings(),
        earned: const <WisaImportRule>[DontImportUserFromWisa('SMIT')],
      )!;

      final restored = AppSettings.fromJson(merged.settings.toJson());

      expect(
        (restored.wisaRules.single as DontImportUserFromWisa).userCode,
        'SMIT',
      );
    });
  });
}
