import 'dart:async';

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
        contains('WISA ophalen met werkdatum 01/09/2025.'),
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
        contains('WISA ophalen met werkdatum 01/07/2026.'),
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
        contains('WISA ophalen met werkdatum 01/09/2026; virtuele werkdatum '
            '01/10/2026 voor V.'),
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
      expect(messages, contains('WISA ophalen met werkdatum 01/09/2026.'));
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
        'WISA ophalen met werkdatum 01/09/2026; virtuele werkdatum '
        '01/10/2026 voor Virtuele school, school 8.',
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

    test("unions the persisted rules with the session's own (#263)", () async {
      // Both halves reach one pull: the `MarkAsVirtual` this session earned and
      // the `DontImportClass` the operator saved a moment ago.
      final wire = RecordingWisaSoap();
      final rules = WisaImportRules()..add(const wapi.MarkAsVirtual('S1'));
      final live = LiveSettings(_settings());
      final syncer = wisaSyncer(
        wapi.WisaConnector.fromParts(
          server: 'wisa.example',
          port: 9000,
          database: 'db',
          username: 'u',
          password: 'p',
          transport: wire,
        ),
        settings: live,
        rules: rules,
      );

      final first = await syncer(null);
      expect(first.schools.single.isVirtual, isTrue,
          reason: 'the session rule already marks the school virtual');
      expect(first.classGroups, hasLength(1));

      live.publish(_settings().copyWith(
        wisaRules: const <wapi.WisaImportRule>[wapi.DontImportClass('3C')],
      ));

      final pruned = await syncer(null);
      expect(pruned.classGroups, isEmpty,
          reason: 'the saved rule reached the pull');
      expect(pruned.schools.single.isVirtual, isTrue,
          reason: 'and the session rule was not lost composing it');
    });
  });

  group('a WISA import rule saved in Instellingen reaches the pull (#263)', () {
    test('the very next pull applies it, with no relaunch', () async {
      // The reported bug. `bootstrapReconcile` seeded the shared
      // `WisaImportRules` holder from the document it loaded at startup and
      // nothing ever published a saved document back into it, so a rule on the
      // settings document only ever reached the pull of the *next* launch.
      final wire = RecordingWisaSoap();
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(
        (harness.app.wisa.snapshot as wapi.WisaSnapshot).classGroups,
        hasLength(1),
      );

      live.publish(_settings().copyWith(
        wisaRules: const <wapi.WisaImportRule>[wapi.DontImportClass('3C')],
      ));
      await harness.controller.sync();

      expect(
        (harness.app.wisa.snapshot as wapi.WisaSnapshot).classGroups,
        isEmpty,
        reason: 'the pass the operator reached for applied the saved rule',
      );
    });

    test('a rule dropped from the document stops applying too', () async {
      // The other half of the freeze: a holder seeded once could never let go
      // of a rule, so un-ignoring a class needed a relaunch as well.
      final live = LiveSettings(_settings().copyWith(
        wisaRules: const <wapi.WisaImportRule>[wapi.DontImportClass('3C')],
      ));
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );

      await harness.controller.sync();
      expect(
        (harness.app.wisa.snapshot as wapi.WisaSnapshot).classGroups,
        isEmpty,
      );

      live.publish(_settings());
      await harness.controller.sync();

      expect(
        (harness.app.wisa.snapshot as wapi.WisaSnapshot).classGroups,
        hasLength(1),
      );
    });

    test('blocks Check for drift until a Synchroniseer has pulled with it',
        () async {
      // A drift pass never re-reads WISA, so between the save and the sync it
      // would relink the roster the rule never reached — and publish that to
      // every other operator.
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );
      await harness.controller.sync();
      expect(harness.controller.canCheckDrift, isTrue);

      live.publish(_settings().copyWith(
        wisaRules: const <wapi.WisaImportRule>[wapi.DontImportClass('3C')],
      ));

      expect(
        harness.controller.driftBlockedReason,
        'WISA-instellingen gewijzigd — synchroniseer eerst.',
      );
      expect(harness.controller.canCheckDrift, isFalse);

      await harness.controller.sync();
      expect(harness.controller.driftBlockedReason, isNull);
    });

    test('a rule an apply earned never arms the drift gate', () async {
      // Session rules are not on any settings document, and the apply that
      // earns one re-syncs WISA itself — so the gate must stay open.
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(
        wisaTransport: RecordingWisaSoap(),
        liveSettings: live,
      );
      await harness.controller.sync();

      harness.applier.wisaRules.add(const wapi.DontImportClass('3C'));

      expect(harness.controller.driftBlockedReason, isNull);
      expect(harness.controller.canCheckDrift, isTrue);
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
      // launch. Check for drift re-reads Smartschool unconditionally, so it is
      // one of the two passes that adopt a rule — and a rule change never arms
      // #238's WISA gate, so drift is offered. (Since #259 Synchroniseer adopts
      // it too; that is the group below.)
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

  group('Synchroniseer re-pulls a system whose settings moved (#259)', () {
    test('a saved import rule prunes the very next Synchroniseer', () async {
      // The reported bug. #99's smart sync leaves a system this session already
      // holds alone, so the operator saved a `DiscardSmartschoolGroup`, pressed
      // Synchroniseer, and got "geen accountwijzigingen nodig" — over the very
      // save it had skipped. Only Check for drift adopted it, and nothing said
      // so.
      final wire = GroupTreeSoap();
      final live = LiveSettings(_settings());
      final harness =
          ReconcileHarness(smartschoolTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(harness.ssSyncs, 1);
      expect(
        harness.app.smartschool.snapshot?.groups.map((g) => g.id.value),
        <String>['SCH', 'ORG', 'HID', 'KLA', 'C1A'],
      );

      live.publish(_settings().copyWith(
        smartschoolRules: const <ss.SmartschoolImportRule>[
          ss.DiscardSmartschoolGroup('Organisatie'),
        ],
      ));
      await harness.controller.sync();

      expect(
        harness.app.smartschool.snapshot?.groups.map((g) => g.id.value),
        <String>['SCH', 'KLA', 'C1A'],
        reason: 'the pass the operator reached for applied the saved rule',
      );
      expect(harness.ssSyncs, 2);
      // …and it did not claim there was nothing to do, which is the
      // user-visible half of the bug.
      expect(harness.controller.noChangesNeeded, isFalse);
      expect(
        harness.log.entries
            .map((e) => e.message)
            .where((m) => m.contains('geen accountwijzigingen nodig')),
        isEmpty,
      );
      // The re-pull says why it happened, in the panel the operator reads.
      expect(
        harness.log.entries.map((e) => e.message),
        contains('Smartschool-instellingen gewijzigd — Smartschool wordt '
            'opnieuw opgehaald.'),
      );
    });

    test('a saved school prefix re-scopes the very next Synchroniseer',
        () async {
      final wire = RecordingGraph();
      final live = LiveSettings(_settings());
      final harness =
          ReconcileHarness(azureTransport: wire, liveSettings: live);

      await harness.controller.sync();
      expect(_userFilters(wire).last, contains('GBS'));

      live.publish(_settings().copyWith(schoolPrefix: 'SSM'));
      await harness.controller.sync();

      expect(_userFilters(wire).last, contains('SSM'),
          reason: 'no drift check needed, and no relaunch');
      expect(harness.azSyncs, 2);
      expect(harness.controller.noChangesNeeded, isFalse);
    });

    test('the smart sync still skips a system nothing asked for', () async {
      // The behaviour #99 exists for has to survive: an unchanged WISA and an
      // untouched settings document is still "nothing to do", with no re-pull
      // of the two systems this session already holds.
      final harness = ReconcileHarness(liveSettings: LiveSettings(_settings()));
      await harness.controller.sync();
      expect((harness.ssSyncs, harness.azSyncs), (1, 1));

      await harness.controller.sync();

      expect((harness.ssSyncs, harness.azSyncs), (1, 1));
      expect(harness.controller.noChangesNeeded, isTrue);
    });

    test('a WISA-only save leaves Smartschool and Azure alone', () async {
      // The fingerprints are per system on purpose: a werkdatum is a WISA pull
      // input and must not cost a Smartschool read or a full tenant re-read.
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      await harness.controller.sync();

      live.publish(_settings(workDate: _pinned(DateTime(2026, 9, 1))));

      expect(harness.controller.systemsAwaitingSettings, isEmpty);
      expect(harness.controller.pendingSettingsReason, isNull);
      await harness.controller.sync();
      expect((harness.ssSyncs, harness.azSyncs), (1, 1));
    });

    test('the screen names the systems waiting, until a pass applies them',
        () async {
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      await harness.controller.sync();
      expect(harness.controller.pendingSettingsReason, isNull);

      live.publish(_settings().copyWith(
        schoolPrefix: 'SSM',
        smartschoolRules: const <ss.SmartschoolImportRule>[
          ss.DiscardSmartschoolGroup('Organisatie'),
        ],
      ));

      expect(
        harness.controller.systemsAwaitingSettings,
        <core.Origin>{core.Origin.smartschool, core.Origin.azure},
      );
      expect(
        harness.controller.pendingSettingsReason,
        'Instellingen voor Smartschool en Azure AD gewijzigd — '
        'synchroniseer om ze toe te passen.',
      );
      // Nothing is refused meanwhile — the next pass adopts them by itself.
      expect(harness.controller.canCheckDrift, isTrue);

      await harness.controller.sync();
      expect(harness.controller.pendingSettingsReason, isNull);
    });

    test('a drift check clears it too, so no sync re-pulls for it twice',
        () async {
      // Drift re-reads both systems unconditionally, so it really has adopted
      // the save; the stamp has to record that or the next Synchroniseer would
      // pay for a change already applied.
      final live = LiveSettings(_settings());
      final harness = ReconcileHarness(liveSettings: live);
      await harness.controller.sync();

      live.publish(_settings().copyWith(schoolPrefix: 'SSM'));
      expect(harness.controller.pendingSettingsReason, isNotNull);

      await harness.controller.checkDrift();
      expect(harness.controller.pendingSettingsReason, isNull);
      expect(harness.azSyncs, 2);

      await harness.controller.sync();
      expect(harness.azSyncs, 2, reason: 'the drift pass already applied it');
    });

    test('a save landing mid-pull stays pending rather than being credited',
        () async {
      // The stamp names the settings the pull *started* with, exactly as #238's
      // WISA one does — a document published while Smartschool was on the wire
      // was never asked for.
      final live = LiveSettings(_settings());
      final gate = Completer<void>();
      final harness = ReconcileHarness(liveSettings: live, azureGate: gate);

      final pass = harness.controller.sync();
      await Future<void>.delayed(Duration.zero);
      live.publish(_settings().copyWith(schoolPrefix: 'SSM'));
      gate.complete();
      await pass;

      expect(
        harness.controller.systemsAwaitingSettings,
        contains(core.Origin.azure),
        reason: 'the pull that was already in flight never saw the save',
      );
    });

    test('a harness with no settings holder never arms it', () async {
      final harness = ReconcileHarness();
      await harness.controller.sync();

      expect(harness.controller.systemsAwaitingSettings, isEmpty);
      expect(harness.controller.pendingSettingsReason, isNull);
    });
  });

  group('Synchroniseer re-links when a link input moved (#264)', () {
    /// A new intake: one WISA student of a managed school with no Azure account
    /// yet, so the pass proposes creating one — and the proposed UPN is built
    /// from the Azure domain, a setting **no** pull ever asks about.
    ReconcileHarness intakeFrom(LiveSettings live) => ReconcileHarness(
          wisa: wisaSnap(
            students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
            schools: [wisaSchool(1, ours: true)],
          ),
          smartschool: ssSnap(
            groups: [ssGroup('3C', code: '3C_ss')],
            accounts: const [],
            memberships: const [],
          ),
          azure: azSnap(users: const []),
          ourSchoolIds: const {1},
          liveSettings: live,
        );

    /// The `userPrincipalName` the pending "create an Office 365 account"
    /// proposes for the student — what the operator reads off the tile.
    String proposedUpn(ReconcileHarness h) => h.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .choices
        .expand((c) => c.selected.changes.fields)
        .firstWhere((f) => f.field == 'userPrincipalName')
        .after!;

    test('a saved Azure domain reaches the very next Synchroniseer', () async {
      // The reported bug. Every input of the pull was unchanged, so #99's smart
      // sync returned before `_relink()` — and the domain, which only the link
      // consumes, was adopted by **Check for drift** alone while Synchroniseer
      // reported "geen accountwijzigingen nodig" over the save.
      final live = LiveSettings(_settings());
      final harness = intakeFrom(live);

      await harness.controller.sync();
      expect(proposedUpn(harness), 'jane.doe@student.school.example');

      live.publish(_settings()
          .copyWith(azure: const AzureConnection(domain: 'nieuw.example')));
      expect(
        harness.controller.pendingSettingsReason,
        'Instellingen voor de koppeling gewijzigd — '
        'synchroniseer om ze toe te passen.',
      );

      await harness.controller.sync();

      expect(proposedUpn(harness), 'jane.doe@student.nieuw.example',
          reason: 'the pass the operator reached for adopted the save');
      // …and it did not claim there was nothing to do, which is the
      // user-visible half of the bug.
      expect(harness.controller.noChangesNeeded, isFalse);
      expect(
        harness.log.entries
            .map((e) => e.message)
            .where((m) => m.contains('geen accountwijzigingen nodig')),
        isEmpty,
      );
      // The re-link says why it happened, in the panel the operator reads…
      expect(
        harness.log.entries.map((e) => e.message),
        contains('Koppelingsinstellingen gewijzigd — de koppeling wordt '
            'opnieuw berekend.'),
      );
      // …the notice is gone, because the pass applied it…
      expect(harness.controller.pendingSettingsReason, isNull);
      // …and it cost no network at all: this is a re-link, not a re-pull.
      expect((harness.ssSyncs, harness.azSyncs), (1, 1));
    });

    test('a saved Smartschool class tree is adopted too', () async {
      // The second of the two link-only inputs: the tree decides where a newly
      // created class hangs, and the parent it resolves to is on the tile.
      final tree = _settings().copyWith(
        smartschool: SmartschoolConnection(studentGroup: 'LLN'),
      );
      final live = LiveSettings(tree);
      final harness = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(classGroup: '3C')],
          schools: [wisaSchool(1, ours: true)],
          classGroups: [wisaClassGroup('3C')],
        ),
        smartschool: ssSnap(
          groups: [
            ssGroup('Leerlingen',
                code: 'LLN', official: false, type: core.GroupType.group),
            ssGroup('School',
                code: 'SCH', official: false, type: core.GroupType.group),
          ],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
        liveSettings: live,
      );

      String parentOf(ReconcileHarness h) => h.controller.pendingEntries
          .firstWhere((e) => e.family == 'group')
          .choices
          .expand((c) => c.selected.changes.fields)
          .firstWhere((f) => f.field == 'parent')
          .after!;

      await harness.controller.sync();
      expect(parentOf(harness), 'LLN');

      live.publish(tree.copyWith(
        smartschool: SmartschoolConnection(studentGroup: 'SCH'),
      ));
      await harness.controller.sync();

      expect(parentOf(harness), 'SCH');
      expect((harness.ssSyncs, harness.azSyncs), (1, 1),
          reason: 'the tree is a link input, not a pull input');
    });

    test('the smart sync still says nothing to do when no link input moved',
        () async {
      // The behaviour #99 exists for has to survive: a save that touches
      // nothing any pass depends on is still "nothing to do".
      final live = LiveSettings(_settings());
      final harness = intakeFrom(live);
      await harness.controller.sync();

      final base = _settings();
      live.publish(base.copyWith(
        smartschool: base.smartschool.copyWith(testUser: 'proefaccount'),
      ));

      expect(harness.controller.linkAwaitingSettings, isFalse);
      await harness.controller.sync();
      expect(harness.controller.noChangesNeeded, isTrue);
    });

    test('a drift check adopts it too, so no sync re-links for it twice',
        () async {
      // Drift re-links unconditionally, so it really has applied the save; the
      // stamp has to record that or the next Synchroniseer would fall through
      // for a change already adopted.
      final live = LiveSettings(_settings());
      final harness = intakeFrom(live);
      await harness.controller.sync();

      live.publish(_settings()
          .copyWith(azure: const AzureConnection(domain: 'nieuw.example')));
      expect(harness.controller.linkAwaitingSettings, isTrue);

      await harness.controller.checkDrift();
      expect(proposedUpn(harness), 'jane.doe@student.nieuw.example');
      expect(harness.controller.linkAwaitingSettings, isFalse);
      expect(harness.controller.pendingSettingsReason, isNull);

      await harness.controller.sync();
      expect(harness.controller.noChangesNeeded, isTrue,
          reason: 'the drift pass already applied it');
    });

    test('the screen names the link beside the systems waiting', () async {
      final live = LiveSettings(_settings());
      final harness = intakeFrom(live);
      await harness.controller.sync();

      live.publish(_settings().copyWith(
        schoolPrefix: 'SSM',
        azure: const AzureConnection(domain: 'nieuw.example'),
        smartschoolRules: const <ss.SmartschoolImportRule>[
          ss.DiscardSmartschoolGroup('Organisatie'),
        ],
      ));

      expect(
        harness.controller.pendingSettingsReason,
        'Instellingen voor Smartschool, Azure AD en de koppeling gewijzigd — '
        'synchroniseer om ze toe te passen.',
      );
      // Nothing is refused meanwhile — the next pass adopts them by itself.
      expect(harness.controller.canCheckDrift, isTrue);
    });

    test('a save landing before the link is adopted by that very link',
        () async {
      // The fingerprint is read where `applier.link()` samples the document,
      // not when the pass started, so a save that lands while the pass is still
      // pulling is applied by it — and stamped, rather than left pending over a
      // link that honoured it.
      final live = LiveSettings(_settings());
      final gate = Completer<void>();
      final harness = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(wisaId: 'W7', classGroup: '3C')],
          schools: [wisaSchool(1, ours: true)],
        ),
        smartschool: ssSnap(
          groups: [ssGroup('3C', code: '3C_ss')],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
        liveSettings: live,
        azureGate: gate,
      );

      final pass = harness.controller.sync();
      await Future<void>.delayed(Duration.zero);
      live.publish(_settings()
          .copyWith(azure: const AzureConnection(domain: 'nieuw.example')));
      gate.complete();
      await pass;

      expect(proposedUpn(harness), 'jane.doe@student.nieuw.example');
      expect(harness.controller.linkAwaitingSettings, isFalse);
    });

    test('a harness with no settings holder never arms it', () async {
      final harness = ReconcileHarness();
      await harness.controller.sync();

      expect(harness.controller.linkAwaitingSettings, isFalse);
      expect(harness.controller.pendingSettingsReason, isNull);
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
