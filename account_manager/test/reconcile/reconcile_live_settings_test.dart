import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'reconcile_fakes.dart';

/// A settings document with a valid WISA profile and the given werkdatum pair /
/// school marks.
AppSettings _settings({
  WorkDateSetting workDate = const WorkDateSetting(),
  WorkDateSetting virtualWorkDate = const WorkDateSetting(),
  List<WisaSchoolProfile> schools = const <WisaSchoolProfile>[],
}) =>
    AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: workDate,
        virtualWorkDate: virtualWorkDate,
      ),
      wisaSchools: schools,
    );

WorkDateSetting _pinned(DateTime date) =>
    WorkDateSetting(isNow: false, date: date);

void main() {
  group('the WISA pull reads the operator settings live (#238)', () {
    test('a werkdatum saved after bootstrap reaches the very next pull',
        () async {
      // The reconcile stack bootstraps on a document pinned to the 2025 school
      // year, exactly as a session opened before the rollover does.
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final wire = RecordingWisaSoap();
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(wire.werkdatums, <String>['01/09/2025']);

      // The operator advances the werkdatum in Instellingen and saves. Before
      // #238 the syncer had closed over the bootstrap document, so this pull
      // still asked WISA for 01/09/2025 — only a relaunch changed it.
      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));
      await harness.controller.sync();

      expect(wire.werkdatums, <String>['01/09/2025', '01/09/2026']);
    });

    test('a virtual school pulls with the saved virtuele werkdatum', () async {
      // School 99 is marked virtual in Settings (#203), so its rows must come
      // from the *virtual* werkdatum — and both dates are read live.
      final live = LiveSettings(_settings(
        workDate: _pinned(DateTime(2025, 9, 1)),
        virtualWorkDate: _pinned(DateTime(2025, 9, 1)),
      ));
      final wire = RecordingWisaSoap(schools: const <(int, String, String)>[
        (1, 'School 1', 'S1'),
        (99, 'Virtuele school', 'V'),
      ]);
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      live.publish(_settings(
        workDate: _pinned(DateTime(2026, 9, 1)),
        virtualWorkDate: _pinned(DateTime(2026, 10, 1)),
        schools: const <WisaSchoolProfile>[
          WisaSchoolProfile(
              schoolId: 99, code: 'V', name: 'Virtuele school', virtual: true),
        ],
      ));
      await harness.controller.sync();

      // The ordinary school got the werkdatum, the virtual one the virtuele
      // werkdatum — both as just saved.
      final byWerkdatum = <String, Set<String>>{};
      for (final q in wire.queries) {
        if (q.$3.isEmpty) continue;
        byWerkdatum.putIfAbsent(q.$2, () => <String>{}).add(q.$3);
      }
      expect(byWerkdatum['1'], <String>{'01/09/2026'});
      expect(byWerkdatum['99'], <String>{'01/10/2026'});
    });

    test('the pull really lands the roster it asked for', () async {
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2026, 9, 1))));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );

      await harness.controller.sync();

      final snapshot = harness.app.wisa.snapshot as wapi.WisaSnapshot;
      expect(snapshot.students.single.wisaId.value, '1');
      expect(snapshot.schools.single.id, 1);
    });
  });

  group('Check for drift refuses a stale WISA roster (#238)', () {
    test('is available while the WISA settings have not moved', () async {
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final harness = ReconcileHarness(liveSettings: live);

      expect(harness.controller.driftBlockedReason, isNull);
      expect(harness.controller.canCheckDrift, isTrue);

      // A save that touches nothing the WISA pull depends on leaves it open.
      live.publish(_settings(workDate: _pinned(DateTime(2025, 9, 1)))
          .copyWith(schoolPrefix: 'GBS'));
      expect(harness.controller.canCheckDrift, isTrue);
    });

    test('a saved werkdatum blocks it, with a reason, until a sync runs',
        () async {
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final harness = ReconcileHarness(liveSettings: live);
      await harness.controller.sync();
      expect(harness.controller.canCheckDrift, isTrue);

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));

      expect(
        harness.controller.driftBlockedReason,
        'WISA-instellingen gewijzigd — synchroniseer eerst.',
      );
      expect(harness.controller.canCheckDrift, isFalse);

      // And it is a real refusal, not just a disabled button: nothing is
      // pulled, nothing is relinked, nothing is published to the other
      // operators.
      final ss = harness.ssSyncs;
      final az = harness.azSyncs;
      await harness.controller.checkDrift();
      expect(harness.ssSyncs, ss);
      expect(harness.azSyncs, az);
      expect(
        harness.log.entries.map((e) => e.message),
        contains('WISA-instellingen gewijzigd — synchroniseer eerst.'),
      );

      // The Synchroniseer the message asks for clears it: WISA has now been
      // pulled with the saved werkdatum.
      await harness.controller.sync();
      expect(harness.controller.driftBlockedReason, isNull);
      expect(harness.controller.canCheckDrift, isTrue);
    });

    test('a virtual-school mark blocks it too', () async {
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      await harness.controller.sync();

      live.publish(_settings(schools: const <WisaSchoolProfile>[
        WisaSchoolProfile(schoolId: 99, code: 'V', name: 'V', virtual: true),
      ]));
      expect(harness.controller.canCheckDrift, isFalse);
    });

    test('repaints the screen when a save arrives from Instellingen', () async {
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      var notifications = 0;
      harness.controller.addListener(() => notifications++);

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));
      await Future<void>.delayed(Duration.zero);

      expect(notifications, greaterThan(0),
          reason: 'the reconcile screen is kept alive across tab switches, so '
              'only a controller notification can disable its drift button');
    });

    test('a harness with no settings holder never arms the gate', () async {
      final harness = ReconcileHarness();
      await harness.controller.sync();
      expect(harness.controller.driftBlockedReason, isNull);
      expect(harness.controller.canCheckDrift, isTrue);
    });
  });

  group('wisaSyncer', () {
    test('reads the rules live too, so a DontImportFromWisa apply lands (#72)',
        () async {
      // The settings holder must not have cost the rules their liveness: both
      // are read at pull time, so a rule accumulated between two passes still
      // prunes the second one.
      final wire = RecordingWisaSoap();
      final rules = WisaImportRules();
      final syncer = wisaSyncer(
        wapi.WisaConnector.fromParts(
          server: 'wisa.example',
          port: 9000,
          database: 'db',
          username: 'u',
          password: 'p',
          transport: wire,
        ),
        settings: LiveSettings(_settings()),
        rules: rules,
      );

      expect((await syncer(null)).classGroups, hasLength(1));
      rules.add(const wapi.DontImportClass('3C'));
      expect((await syncer(null)).classGroups, isEmpty);
    });
  });
}
