import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

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
