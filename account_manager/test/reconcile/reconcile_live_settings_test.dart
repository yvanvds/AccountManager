import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/reconcile_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;
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

  group('a WISA pull names the werkdatum it asked for (#239)', () {
    test('names the resolved werkdatum, exactly as it went on the wire',
        () async {
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final wire = RecordingWisaSoap();
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      await harness.controller.sync();

      // The date the operator can read matches the date WISA was asked for —
      // the point of the line, and the only way an empty Acties can be told
      // apart from a pull that landed on last year's roster.
      expect(wire.werkdatums, <String>['01/09/2025']);
      expect(
        harness.log.entries.map((e) => e.message),
        contains('Pulling WISA with werkdatum 01/09/2025.'),
      );
    });

    test('names the date a "volg de huidige datum" werkdatum resolved to',
        () async {
      // The default setting, and the one that produces the reported symptom: a
      // pass run before the school-year rollover silently pulls the previous
      // year. The line has to name the *resolved* date, not "vandaag".
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: LiveSettings(_settings()),
      );

      await harness.controller.sync();

      expect(
        harness.log.entries.map((e) => e.message),
        // The harness clock is fixed at kFixtureDate (2026-07-01).
        contains('Pulling WISA with werkdatum 01/07/2026.'),
      );
    });

    test('names the virtuele werkdatum, and the school that used it', () async {
      final live = LiveSettings(_settings(
        workDate: _pinned(DateTime(2026, 9, 1)),
        virtualWorkDate: _pinned(DateTime(2026, 10, 1)),
        schools: const <WisaSchoolProfile>[
          WisaSchoolProfile(
              schoolId: 99, code: 'V', name: 'Virtuele school', virtual: true),
        ],
      ));
      final wire = RecordingWisaSoap(schools: const <(int, String, String)>[
        (1, 'School 1', 'S1'),
        (99, 'Virtuele school', 'V'),
      ]);
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      await harness.controller.sync();

      expect(wire.werkdatums, <String>['01/09/2026', '01/10/2026']);
      expect(
        harness.log.entries.map((e) => e.message),
        contains('Pulling WISA with werkdatum 01/09/2026; virtuele werkdatum '
            '01/10/2026 for V.'),
      );
    });

    test('leaves the virtuele werkdatum unmentioned when no school used it',
        () async {
      // A second date no query carried would read as if some of the roster came
      // from it. The pull says only what it asked.
      final live = LiveSettings(_settings(
        workDate: _pinned(DateTime(2026, 9, 1)),
        virtualWorkDate: _pinned(DateTime(2026, 10, 1)),
      ));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );

      await harness.controller.sync();

      final messages = harness.log.entries.map((e) => e.message);
      expect(messages, contains('Pulling WISA with werkdatum 01/09/2026.'));
      expect(messages.where((m) => m.contains('virtuele werkdatum')), isEmpty);
    });

    test('falls back to the long name when a school carries no code', () {
      expect(
        wisaPullMessage(
          schools: const <wapi.WisaSchool>[
            wapi.WisaSchool(
                id: 7, name: 'Virtuele school', code: '  ', isVirtual: true),
            wapi.WisaSchool(id: 8, name: '', code: '', isVirtual: true),
          ],
          workDate: DateTime(2026, 9, 1),
          virtualWorkDate: DateTime(2026, 10, 1),
        ),
        'Pulling WISA with werkdatum 01/09/2026; virtuele werkdatum '
        '01/10/2026 for Virtuele school, school 8.',
      );
    });
  });

  group('the shared state carries the werkdatum it was pulled with (#247)', () {
    DateTime? storedWerkdatum(ReconcileHarness h) =>
        h.controller.syncState.systems[core.Origin.wisa]?.workDate;

    test('a sync stamps the WISA meta with the date it asked WISA for',
        () async {
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final wire = RecordingWisaSoap();
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      await harness.controller.sync();

      expect(wire.werkdatums, <String>['01/09/2025']);
      expect(storedWerkdatum(harness), DateTime(2025, 9, 1));
    });

    test('the stamp names the pull, not whatever Instellingen now says',
        () async {
      // The case the issue exists for. #238 made the werkdatum live, so the
      // setting and the installed roster routinely disagree: the operator moves
      // the date to the new school year and, until they press Synchroniseer,
      // the shared view is still last year's. The stamp must say *pulled*.
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );
      await harness.controller.sync();

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));

      expect(storedWerkdatum(harness), DateTime(2025, 9, 1),
          reason: 'a save is not a pull');
    });

    test('a "volg de huidige datum" pull stamps the date it resolved to',
        () async {
      // The default setting, and the one that produces the reported symptom:
      // the stamp has to name the resolved date, not the fact that it follows
      // the clock.
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: LiveSettings(_settings()),
      );

      await harness.controller.sync();

      // The harness clock is fixed at kFixtureDate (2026-07-01), and the stamp
      // is the instant the pull resolved — not a re-ask a moment later, which
      // is the whole reason it rides out on the snapshot.
      expect(storedWerkdatum(harness), kFixtureDate);
      expect(wapi.formatWerkdatum(storedWerkdatum(harness)!), '01/07/2026');
    });

    test('a passive session reads the same werkdatum off the shared store',
        () async {
      // The whole point of putting it on the shared record rather than in this
      // session's log: an operator who never ran the pass can still tell which
      // school year the view in front of them describes.
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final syncer = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
        store: snapshots,
        linkedStore: linkedStore,
      );
      await syncer.controller.sync();

      final passive = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await passive.controller.loadOverview();

      expect(storedWerkdatum(passive), DateTime(2025, 9, 1));
    });

    test('a drift pass that does not re-pull WISA keeps the roster stamp',
        () async {
      // Check-for-drift re-reads Smartschool and Azure only, so the roster —
      // and the date it is as of — is still the one the last sync installed.
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );
      await harness.controller.sync();
      await harness.controller.checkDrift();

      expect(harness.controller.syncState.generation, 2,
          reason: 'the drift pass really did rewrite the view');
      expect(storedWerkdatum(harness), DateTime(2025, 9, 1));
    });

    test('the "WISA unchanged" shortcut still records the new werkdatum',
        () async {
      // A werkdatum change that lands the identical roster skips the re-link,
      // but the view is now known to describe a different date — and the light
      // metadata write is what has to carry it.
      final live =
          LiveSettings(_settings(workDate: _pinned(DateTime(2025, 9, 1))));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );
      await harness.controller.sync();
      final generation = harness.controller.syncState.generation;

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));
      await harness.controller.sync();

      expect(harness.controller.syncState.generation, generation,
          reason: 'an unchanged roster is not a new view');
      expect(storedWerkdatum(harness), DateTime(2026, 9, 1));
    });

    test('a scripted pull that never named a werkdatum stamps none', () async {
      // Every other harness builds its WISA snapshot by hand, and a snapshot
      // restored from a pre-#247 document carries no date either. Neither may
      // be given one it does not have.
      final harness = ReconcileHarness();
      await harness.controller.sync();

      expect(harness.controller.syncState.systems[core.Origin.wisa], isNotNull);
      expect(storedWerkdatum(harness), isNull);
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

  group('the rest of the reconcile stack reads settings live too (#246)', () {
    /// The #178 fixture, but with ownership coming from the settings document
    /// rather than a constructor argument: one student enrolled in school 2 and
    /// fully present in our Smartschool + Azure, and no `MarkAsOurs` flag on the
    /// WISA schools — so who is managed is decided solely by [live].
    ReconcileHarness managedFrom(LiveSettings live) => ReconcileHarness(
          wisa: wisaSnap(
            students: [wisaStudent(schoolId: 2)],
            schools: [wisaSchool(1), wisaSchool(2)],
          ),
          smartschool: ssSnap(
            groups: const [],
            accounts: [ssAccount()],
            memberships: const [],
          ),
          azure: azSnap(users: [azUser()]),
          liveSettings: live,
        );

    AppSettings withSchools(List<WisaSchoolProfile> schools) =>
        _settings(schools: schools);

    test("a school's beheerd mark reaches the very next relink", () async {
      // The headline symptom: the operator marks a school managed in
      // Instellingen, and the Actions view keeps hiding its students until the
      // app is relaunched.
      final live = LiveSettings(withSchools(const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 1, code: 'S1', name: 'School 1', ours: true),
        WisaSchoolProfile(schoolId: 2, code: 'S2', name: 'School 2'),
      ]));
      final harness = managedFrom(live);

      await harness.controller.sync();
      expect(harness.applier.ourSchoolIds, const {1});
      var linked = await harness.applier.link();
      expect(linked.snapshot.accounts.single.wisaPresence,
          core.WisaPresence.groupOnly,
          reason: "school 2 is not ours, so its student is out of scope");

      live.publish(withSchools(const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 1, code: 'S1', name: 'School 1', ours: true),
        WisaSchoolProfile(
            schoolId: 2, code: 'S2', name: 'School 2', ours: true),
      ]));

      expect(harness.applier.ourSchoolIds, const {1, 2});
      linked = await harness.applier.link();
      expect(
          linked.snapshot.accounts.single.wisaPresence, core.WisaPresence.ours,
          reason: 'no relaunch: the relink honoured the save');
    });

    test('a beheerd mark does not block Check for drift', () async {
      // #238 refuses drift while the *WISA pull inputs* have moved, because
      // drift never re-pulls WISA. Ownership is not one of them — it is applied
      // at link time — so drift is exactly the pass that adopts it.
      final live = LiveSettings(withSchools(const <WisaSchoolProfile>[
        WisaSchoolProfile(schoolId: 2, code: 'S2', name: 'School 2'),
      ]));
      final harness = managedFrom(live);
      await harness.controller.sync();

      live.publish(withSchools(const <WisaSchoolProfile>[
        WisaSchoolProfile(
            schoolId: 2, code: 'S2', name: 'School 2', ours: true),
      ]));

      expect(harness.controller.driftBlockedReason, isNull);
      await harness.controller.checkDrift();
      expect(harness.controller.linked?.snapshot.accounts.single.wisaPresence,
          core.WisaPresence.ours);
    });

    test('the Smartschool import rules are read at pull time', () async {
      // #241 authored them; before #246 the pull closed over the bootstrap
      // document, so a rule saved in Instellingen pruned nothing until the next
      // launch. The pass that adopts it is **Check for drift** — the one that
      // re-reads Smartschool at all (#99's smart sync leaves it alone once this
      // session has it) — and a rule change never arms #238's WISA gate, so
      // drift is offered.
      final wire = GroupTreeSoap();
      final live = LiveSettings(_settings());
      final harness =
          ReconcileHarness(smartschoolTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(
        harness.app.smartschool.snapshot?.groups.map((g) => g.id.value),
        <String>['SCH', 'ORG', 'HID', 'KLA', 'C1A'],
      );

      live.publish(_settings().copyWith(
        smartschoolRules: const <ss.SmartschoolImportRule>[
          ss.DiscardSmartschoolGroup('Organisatie'),
        ],
      ));
      expect(harness.controller.driftBlockedReason, isNull);
      await harness.controller.checkDrift();

      expect(
        harness.app.smartschool.snapshot?.groups.map((g) => g.id.value),
        <String>['SCH', 'KLA', 'C1A'],
        reason: 'the saved rule pruned the very next pull, subtree and all',
      );
    });

    test('the Azure pull scopes by the school prefix as it now stands',
        () async {
      final wire = RecordingGraph();
      final live = LiveSettings(_settings());
      final harness =
          ReconcileHarness(azureTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(_userFilters(wire).last, contains('GBS'));

      live.publish(_settings().copyWith(schoolPrefix: 'SSM'));
      await harness.controller.checkDrift();

      expect(_userFilters(wire).last, contains('SSM'),
          reason: 'a saved prefix re-scopes the pull without a relaunch');
    });

    // The companion guard — that a moved prefix drops the delta token so no
    // old-prefix user survives the pass — is proved in `account_state`'s
    // `application_state_test`, over a transport that actually primes one;
    // `RecordingGraph` answers every collection read empty, so it never gets a
    // deltaLink and every pass here is a full read anyway.

    test('the school profiles the drill-down is labelled from are live',
        () async {
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      expect(harness.controller.schoolProfiles, isEmpty);

      live.publish(withSchools(const <WisaSchoolProfile>[
        WisaSchoolProfile(
          schoolId: 25,
          code: 'ISMAA',
          name: 'Instituut Sancta Maria-A',
          ours: true,
        ),
      ]));

      expect(harness.controller.schoolProfiles.single.code, 'ISMAA');
    });
  });

  group('a connection profile the session cannot adopt says so (#246)', () {
    test('stays silent while only live-adoptable values move', () async {
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      expect(harness.controller.relaunchRequiredReason, isNull);

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))).copyWith(
        schoolPrefix: 'GBS',
        wisaSchools: const <WisaSchoolProfile>[
          WisaSchoolProfile(schoolId: 1, code: 'A', name: 'A', ours: true),
        ],
      ));

      expect(harness.controller.relaunchRequiredReason, isNull,
          reason: 'every one of these reaches the running stack now');
    });

    test('names the relaunch when a WISA endpoint moves under the session',
        () async {
      // The connectors were constructed from the bootstrap document — a live
      // SQL connection and a resolved Key Vault secret — so this session keeps
      // talking to the old server. Saying so is the whole point: syncing the
      // *previous* WISA host while Instellingen shows a new one is the silent
      // stale-input failure #238 set out to end.
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);

      live.publish(AppSettings(
        wisa: const WisaConnection(server: 'nieuw.example', port: '9000'),
      ));

      expect(
        harness.controller.relaunchRequiredReason,
        'Verbindingsinstellingen gewijzigd — deze sessie blijft de vorige '
        'gebruiken tot de app herstart wordt.',
      );
      // Nothing is refused, though — the operator may have edited a profile
      // they are not using, and stranding them would be worse than the notice.
      expect(harness.controller.canCheckDrift, isTrue);
    });

    test('a harness with no settings holder never nags', () {
      expect(ReconcileHarness().controller.relaunchRequiredReason, isNull);
    });
  });
}

/// The `$filter` of every prefix-scoped `/users` bulk read [wire] saw, in
/// order — the targeted `employeeId in (…)` back-fill lookups (#224) hit the
/// same path but carry no prefix, so they are left out.
List<String> _userFilters(RecordingGraph wire) => <String>[
      for (final r in wire.requests)
        if (r.url.path.endsWith('/users'))
          if (!(r.url.queryParameters[r'$filter'] ?? '')
              .startsWith('employeeId in'))
            r.url.queryParameters[r'$filter'] ?? '',
    ];
