import 'package:account_state/account_state.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

AppSettings _settings({
  WorkDateSetting workDate = const WorkDateSetting(),
  WorkDateSetting virtualWorkDate = const WorkDateSetting(),
  List<WisaSchoolProfile> schools = const <WisaSchoolProfile>[],
}) =>
    AppSettings(
      wisa: WisaConnection(
        server: 'wisa.local',
        port: '9000',
        workDate: workDate,
        virtualWorkDate: virtualWorkDate,
      ),
      wisaSchools: schools,
    );

void main() {
  group('LiveSettings', () {
    test('hands back whatever was published last (#238)', () {
      final live = LiveSettings(_settings());
      expect(live.current.wisa.workDate.isNow, isTrue);

      final pinned = _settings(
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9, 1)),
      );
      live.publish(pinned);
      expect(live.current.wisa.workDate.date, DateTime(2026, 9, 1));
    });

    test('notifies listeners of every publish (#238)', () async {
      final live = LiveSettings();
      final seen = <String>[];
      final sub = live.changes.listen((s) => seen.add(s.schoolPrefix));
      addTearDown(sub.cancel);

      live.publish(const AppSettings(schoolPrefix: 'A'));
      live.publish(const AppSettings(schoolPrefix: 'B'));
      await Future<void>.delayed(Duration.zero);

      expect(seen, <String>['A', 'B']);
    });

    test('defaults to an empty document so a caller can wire it early', () {
      expect(LiveSettings().current.schoolPrefix, '');
    });
  });

  group('wisaPullFingerprint', () {
    test('changes when the werkdatum is pinned to a new date (#238)', () {
      final before = wisaPullFingerprint(_settings());
      final after = wisaPullFingerprint(_settings(
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9, 1)),
      ));
      expect(after, isNot(before));
    });

    test('changes when the virtuele werkdatum moves (#238)', () {
      final before = wisaPullFingerprint(_settings(
        virtualWorkDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9)),
      ));
      final after = wisaPullFingerprint(_settings(
        virtualWorkDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9)),
      ));
      expect(after, isNot(before));
    });

    test("changes when a school's virtual mark is flipped (#238)", () {
      const school = WisaSchoolProfile(schoolId: 99, code: 'V', name: 'V');
      final before = wisaPullFingerprint(_settings(schools: const [school]));
      final after = wisaPullFingerprint(
        _settings(schools: const [
          WisaSchoolProfile(
            schoolId: 99,
            code: 'V',
            name: 'V',
            virtual: true,
          )
        ]),
      );
      expect(after, isNot(before));
    });

    test('is stable for "volg de huidige datum" across two reads (#238)', () {
      // The whole reason this fingerprints the *setting* and not the resolved
      // date: `isNow: true` resolves to a different instant every pull, so
      // fingerprinting the resolved value would leave a drift check blocked
      // forever even though nothing was ever changed.
      final settings = _settings();
      expect(wisaPullFingerprint(settings), wisaPullFingerprint(settings));
      expect(
        wisaPullFingerprint(settings),
        wisaPullFingerprint(_settings()),
      );
    });

    test('ignores settings a WISA pull does not depend on (#238)', () {
      // The managed (`ours`) mark feeds the linker, not the pull, and the school
      // prefix feeds Azure — neither may arm the drift gate.
      final plain = _settings(
        schools: const [WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A')],
      );
      final managed = _settings(
        schools: const [
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true),
        ],
      );
      expect(wisaPullFingerprint(managed), wisaPullFingerprint(plain));
      expect(
        wisaPullFingerprint(plain.copyWith(schoolPrefix: 'GBS')),
        wisaPullFingerprint(plain),
      );
    });

    test('is insensitive to the order the virtual schools are stored in', () {
      const a =
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', virtual: true);
      const b =
          WisaSchoolProfile(schoolId: 2, code: 'B', name: 'B', virtual: true);
      expect(
        wisaPullFingerprint(_settings(schools: const [a, b])),
        wisaPullFingerprint(_settings(schools: const [b, a])),
      );
    });

    test('changes when a WISA import rule is saved (#263)', () {
      // The rules are pull inputs since #263 — the pull reads them from the
      // live document — so a saved rule must arm the drift gate exactly as a
      // moved werkdatum does, or "Check for drift" would keep relinking the
      // roster the rule never reached.
      final before = wisaPullFingerprint(_settings());
      final after = wisaPullFingerprint(_settings().copyWith(
        wisaRules: const <WisaImportRule>[DontImportClass('3C')],
      ));
      expect(after, isNot(before));
    });

    test('distinguishes two rules of the same kind (#263)', () {
      final base = _settings();
      expect(
        wisaPullFingerprint(base.copyWith(
          wisaRules: const <WisaImportRule>[DontImportClass('3C')],
        )),
        isNot(wisaPullFingerprint(base.copyWith(
          wisaRules: const <WisaImportRule>[DontImportClass('4C')],
        ))),
      );
    });

    test('is order-sensitive, because the connector applies rules in sequence',
        () {
      final base = _settings();
      expect(
        wisaPullFingerprint(base.copyWith(
          wisaRules: const <WisaImportRule>[
            DontImportClass('3C'),
            DontImportUserFromWisa('SMIT'),
          ],
        )),
        isNot(wisaPullFingerprint(base.copyWith(
          wisaRules: const <WisaImportRule>[
            DontImportUserFromWisa('SMIT'),
            DontImportClass('3C'),
          ],
        ))),
      );
    });

    test('is stable across two reads of the same rules (#263)', () {
      final settings = _settings().copyWith(
        wisaRules: const <WisaImportRule>[
          DontImportClass('3C'),
          DontImportUserFromWisa('SMIT'),
        ],
      );
      expect(wisaPullFingerprint(settings), wisaPullFingerprint(settings));
    });
  });

  group('smartschoolPullFingerprint (#259)', () {
    test('changes when the operator authors an import rule', () {
      final before = smartschoolPullFingerprint(_settings());
      final after = smartschoolPullFingerprint(_settings().copyWith(
        smartschoolRules: const [DiscardSmartschoolGroup('Organisatie')],
      ));
      expect(after, isNot(before));
    });

    test('changes when a rule is retargeted, not merely counted', () {
      final a = smartschoolPullFingerprint(_settings().copyWith(
        smartschoolRules: const [DiscardSmartschoolGroup('Organisatie')],
      ));
      final b = smartschoolPullFingerprint(_settings().copyWith(
        smartschoolRules: const [DiscardSmartschoolGroup('Personeel')],
      ));
      expect(a, isNot(b));
    });

    test('is order-sensitive, because the rules are applied in sequence', () {
      const a = DiscardSmartschoolGroup('Organisatie');
      const b = NoSmartschoolSubgroups('Klassen');
      expect(
        smartschoolPullFingerprint(
            _settings().copyWith(smartschoolRules: const [a, b])),
        isNot(smartschoolPullFingerprint(
            _settings().copyWith(smartschoolRules: const [b, a]))),
      );
    });

    test('ignores settings a Smartschool pull does not depend on', () {
      // The pull takes the rules and nothing else; the class tree, the prefix
      // and the werkdatum all feed other readers and must not force a re-pull.
      final base = _settings();
      expect(
        smartschoolPullFingerprint(base.copyWith(
          schoolPrefix: 'GBS',
          smartschool: base.smartschool.copyWith(studentGroup: 'SCHOOL'),
          wisa: base.wisa.copyWith(
            workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9)),
          ),
        )),
        smartschoolPullFingerprint(base),
      );
    });

    test('is stable across two reads of the same document', () {
      final settings = _settings().copyWith(
        smartschoolRules: const [DiscardSmartschoolGroup('Organisatie')],
      );
      expect(
        smartschoolPullFingerprint(settings),
        smartschoolPullFingerprint(settings),
      );
    });
  });

  group('azurePullFingerprint (#259)', () {
    test('changes when the school prefix moves', () {
      expect(
        azurePullFingerprint(_settings().copyWith(schoolPrefix: 'SSM')),
        isNot(azurePullFingerprint(_settings().copyWith(schoolPrefix: 'GBS'))),
      );
    });

    test("changes when a school's beheerd mark is flipped", () {
      // The managed set decides which WISA ids the `employeeId in (…)`
      // back-fill asks Azure about (#224/#231), so it is a pull input too.
      const school = WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A');
      expect(
        azurePullFingerprint(_settings(schools: const [school])),
        isNot(azurePullFingerprint(_settings(schools: const [
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true),
        ]))),
      );
    });

    test('is insensitive to the order the managed schools are stored in', () {
      const a =
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true);
      const b =
          WisaSchoolProfile(schoolId: 2, code: 'B', name: 'B', ours: true);
      expect(
        azurePullFingerprint(_settings(schools: const [a, b])),
        azurePullFingerprint(_settings(schools: const [b, a])),
      );
    });

    test('is insensitive to whitespace an operator typed around the prefix',
        () {
      expect(
        azurePullFingerprint(_settings().copyWith(schoolPrefix: '  GBS  ')),
        azurePullFingerprint(_settings().copyWith(schoolPrefix: 'GBS')),
      );
    });

    test('ignores settings an Azure pull does not depend on', () {
      // The virtual mark and the import rules belong to the other two pulls;
      // neither may cost the operator a full tenant re-read.
      final base = _settings();
      expect(
        azurePullFingerprint(base.copyWith(
          smartschoolRules: const [DiscardSmartschoolGroup('Organisatie')],
          wisaSchools: const [
            WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', virtual: true),
          ],
        )),
        azurePullFingerprint(base.copyWith(
          wisaSchools: const [
            WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A'),
          ],
        )),
      );
    });
  });

  group('linkFingerprint (#264)', () {
    test('changes when the Azure domain moves', () {
      // Every proposed UPN is built from it — and no pull asks Azure anything
      // about it, so nothing but this can make a sync adopt the save.
      expect(
        linkFingerprint(_settings()
            .copyWith(azure: const AzureConnection(domain: 'nieuw.example'))),
        isNot(linkFingerprint(_settings()
            .copyWith(azure: const AzureConnection(domain: 'oud.example')))),
      );
    });

    test('changes when the student-group root moves', () {
      final base = _settings();
      expect(
        linkFingerprint(base.copyWith(
          smartschool: base.smartschool.copyWith(studentGroup: 'LEERLINGEN'),
        )),
        isNot(linkFingerprint(base.copyWith(
          smartschool: base.smartschool.copyWith(studentGroup: 'SCHOOL'),
        ))),
      );
    });

    test('changes when a year code moves on a school that uses years', () {
      final base = _settings();
      SmartschoolConnection tree(List<String> years) => base.smartschool
          .copyWith(useYears: true, years: years, studentGroup: 'SCHOOL');
      expect(
        linkFingerprint(base.copyWith(
          smartschool: tree(const ['J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7']),
        )),
        isNot(linkFingerprint(base.copyWith(
          smartschool: tree(const ['J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'X7']),
        ))),
      );
    });

    test('ignores a year code the school does not use', () {
      // `classTreeFrom` honours the UseYears/UseGrades flags, so a label edited
      // on the scheme the school has switched off changes no placement — and
      // must not cost a re-link.
      final base = _settings();
      expect(
        linkFingerprint(base.copyWith(
          smartschool: base.smartschool.copyWith(
            years: const ['J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7'],
          ),
        )),
        linkFingerprint(base),
      );
    });

    test('changes when the school switches from years to grades', () {
      final base = _settings();
      final years = base.smartschool.copyWith(
        useYears: true,
        years: const ['J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7'],
        grades: const ['G1', 'G2', 'G3'],
      );
      expect(
        linkFingerprint(base.copyWith(smartschool: years)),
        isNot(linkFingerprint(base.copyWith(
          smartschool: years.copyWith(useYears: false, useGrades: true),
        ))),
      );
    });

    test('ignores the settings the three pull fingerprints already own', () {
      // The point of the split: a werkdatum, a prefix, a beheerd mark or an
      // import rule already forces the pull that adopts it, and the re-link
      // behind it. Only what *no* pull sees belongs here.
      final base = _settings();
      expect(
        linkFingerprint(base.copyWith(
          schoolPrefix: 'GBS',
          smartschoolRules: const [DiscardSmartschoolGroup('Organisatie')],
          wisaRules: const <WisaImportRule>[DontImportClass('3C')],
          wisaSchools: const [
            WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true),
          ],
          wisa: base.wisa.copyWith(
            workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9)),
          ),
        )),
        linkFingerprint(base),
      );
    });

    test('is insensitive to whitespace an operator typed around the domain',
        () {
      // Bootstrap trims it before the action configs ever see it.
      expect(
        linkFingerprint(_settings().copyWith(
          azure: const AzureConnection(domain: '  school.example  '),
        )),
        linkFingerprint(_settings().copyWith(
          azure: const AzureConnection(domain: 'school.example'),
        )),
      );
    });

    test('is stable across two reads of the same document', () {
      final settings = _settings().copyWith(
        azure: const AzureConnection(domain: 'school.example'),
        smartschool: SmartschoolConnection(
          studentGroup: 'SCHOOL',
          useGrades: true,
          grades: const ['G1', 'G2', 'G3'],
        ),
      );
      expect(linkFingerprint(settings), linkFingerprint(settings));
    });
  });

  group('connectionFingerprint (#246)', () {
    test('moves for every endpoint half a connector is built from', () {
      final base = _settings();
      final variants = <String, AppSettings>{
        'server': base.copyWith(wisa: base.wisa.copyWith(server: 'other.host')),
        'port': base.copyWith(wisa: base.wisa.copyWith(port: '9001')),
        'database': base.copyWith(wisa: base.wisa.copyWith(database: 'other')),
        'username': base.copyWith(wisa: base.wisa.copyWith(username: 'other')),
        'passwordRef': base.copyWith(
          wisa: base.wisa.copyWith(passwordRef: const SecretRef('wisa.pw2')),
        ),
        'uri': base.copyWith(
          smartschool: base.smartschool.copyWith(uri: 'other.smartschool.be'),
        ),
        'passphraseRef': base.copyWith(
          smartschool: base.smartschool
              .copyWith(passphraseRef: const SecretRef('ss.pass2')),
        ),
      };
      for (final entry in variants.entries) {
        expect(
          connectionFingerprint(entry.value),
          isNot(connectionFingerprint(base)),
          reason: 'changing ${entry.key} rebuilds a connector',
        );
      }
    });

    test('never carries a secret value — only the ref that names one', () {
      // The whole point of the SecretRef seam: nothing sensitive is ever
      // serialized, and a fingerprint is a string this app logs and renders
      // around. Rotating the secret behind an unchanged ref is a Key Vault
      // event, invisible (and irrelevant) here.
      final print = connectionFingerprint(_settings());
      expect(print, contains('wisa.password'));
      expect(print, isNot(contains('geheim')));
    });

    test('ignores everything #246 made live, so a live change never nags', () {
      // The values the running stack now adopts must not raise the
      // relaunch notice: the prefix, the domain, the managed/virtual marks, the
      // class tree, the rules and the werkdatum all reach the next pass.
      final base = _settings();
      final live = base.copyWith(
        schoolPrefix: 'GBS',
        azure: const AzureConnection(domain: 'school.example'),
        smartschool: base.smartschool.copyWith(
          studentGroup: 'SCHOOL',
          useYears: true,
          years: const ['1', '2', '3', '4', '5', '6', '7'],
        ),
        wisa: base.wisa.copyWith(
          workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9)),
        ),
        wisaSchools: const [
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true),
        ],
      );
      expect(connectionFingerprint(live), connectionFingerprint(base));
    });

    test('is insensitive to surrounding whitespace an operator typed', () {
      final base = _settings();
      final padded =
          base.copyWith(wisa: base.wisa.copyWith(server: '  wisa.local  '));
      expect(connectionFingerprint(padded), connectionFingerprint(base));
    });
  });
}
