import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter_test/flutter_test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'reconcile_fakes.dart';

/// Collects every distinct [ApplyStep] [controller] publishes from now on — the
/// sequence the modal progress dialog renders as a pass walks its actions
/// (#243). A step is notified separately from the progress value, so listening
/// is the only way to see the ones a pass passed through.
List<ApplyStep> recordSteps(ReconcileController controller) {
  final steps = <ApplyStep>[];
  controller.addListener(() {
    final step = controller.applyStep;
    if (step != null && !identical(steps.lastOrNull, step)) steps.add(step);
  });
  return steps;
}

/// A [SignalPublisher] whose every publish throws — to prove a broadcast
/// failure is swallowed and never fails the pass that triggered it (#116).
class _ThrowingPublisher implements SignalPublisher {
  @override
  Future<void> publish(ChangeSignal signal) async =>
      throw StateError('signalr down');
}

/// An [InMemorySettingsStore] that counts its writes — so a test can prove the
/// sync-time school backfill (#207) writes only when it has something to fix.
class _RecordingSettingsStore extends InMemorySettingsStore {
  _RecordingSettingsStore(super.initial);

  int saves = 0;

  @override
  Future<void> save(AppSettings settings) {
    saves++;
    return super.save(settings);
  }
}

/// A settings store whose every read throws — models the store being down while
/// a sync tries to repair the school profiles (#207).
class _ThrowingSettingsStore implements SettingsStore {
  const _ThrowingSettingsStore(this.error);

  final String error;

  @override
  Future<AppSettings> load() async => throw StateError(error);

  @override
  Future<void> save(AppSettings settings) async {}
}

void main() {
  group('first sync', () {
    test('pulls all three systems and derives the linked view + actions',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      expect(h.wisaSyncs, 1);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(h.controller.error, isNull);
      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.controller.linked, isNotNull);
      // The fixture's one deterministic action: WISA says 3C, Smartschool 2B.
      expect(
        h.controller.linked!.studentActions
            .whereType<actions.MoveToSmartschoolClassGroup>(),
        hasLength(1),
      );
      expect(h.controller.pendingViews, isNotEmpty);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
    });
  });

  group('smart WISA diff', () {
    test('an unchanged WISA re-sync reports "no changes needed" and stops',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      // Fresh pull, identical content (a new fetchedAt must not count).
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(h.wisaSyncs, 2, reason: 'WISA itself is re-pulled to diff');
      expect(h.ssSyncs, 1, reason: 'Smartschool is not re-read by default');
      expect(h.azSyncs, 1, reason: 'Azure is not re-read by default');
      expect(identical(h.controller.linked, linkedBefore), isTrue,
          reason: 'the existing linked view is kept, no re-link');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('no account changes needed')),
      );
    });

    test('a changed WISA pull re-links without re-reading the other systems',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isFalse);
      expect(h.wisaSyncs, 2);
      expect(h.ssSyncs, 1);
      expect(h.azSyncs, 1);
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a WISA change re-derives the linked view');
    });
  });

  group('sync-complete log line (#162)', () {
    test('a completed sync logs a terminal ready line with the action count',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      // The count mirrors the relink summary's pendingActions.length (the
      // fixture derives four pending actions across the families), and the line
      // names the operator who ran the pass (#169).
      expect(
        h.log.entries.map((e) => e.message),
        contains('Sync complete — 4 pending action(s). Ready. '
            'Operator: operator@school.example.'),
      );
      // It is the *last* line — the operator sees it closing the pass.
      expect(
          h.log.entries.last.message,
          'Sync complete — 4 pending action(s). Ready. '
          'Operator: operator@school.example.');
    });

    test('an empty operator degrades gracefully — no dangling "by" (#169)',
        () async {
      final h = ReconcileHarness(syncedBy: '');

      await h.controller.sync();

      expect(h.log.entries.last.message,
          'Sync complete — 4 pending action(s). Ready.');
    });

    test('the "no changes needed" path also logs a ready line', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A later, identical WISA pull: the early-return no-change path.
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(
        h.log.entries.map((e) => e.message),
        contains('Sync complete — no account changes needed. Ready. '
            'Operator: operator@school.example.'),
      );
      expect(
          h.log.entries.last.message,
          'Sync complete — no account changes needed. Ready. '
          'Operator: operator@school.example.');
    });
  });

  group('persist resilience (#168)', () {
    test(
        'a stalled writeMaterialized times out, logs it, and returns the pass '
        'to ready so Synchronise re-enables', () async {
      final stalling = StallingLinkedStore();
      final h = ReconcileHarness(
        controllerStore: stalling,
        persistTimeout: const Duration(milliseconds: 50),
      );

      await h.controller.sync();

      // The persist step was reached but hung — the controller did not wait
      // forever: it timed out and finished the pass.
      expect(stalling.writeAttempted, isTrue);
      expect(h.controller.busy, isFalse,
          reason: 'a stalled persist must not leave the pass wedged');
      expect(h.controller.phase, ReconcilePhase.ready);
      // The operator sees the timeout, not silence.
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains('timed out')),
      );
      // The in-memory linked view is still usable this session.
      expect(h.controller.linked, isNotNull);
    });

    test(
        'a failing writeMaterialized is caught, logged, and the pass still '
        'reaches ready', () async {
      final failing = StallingLinkedStore(
        failWith: StateError('cosmos down'),
      );
      final h = ReconcileHarness(controllerStore: failing);

      await h.controller.sync();

      expect(h.controller.busy, isFalse);
      expect(h.controller.phase, ReconcilePhase.ready);
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains('Could not persist the linked view')),
      );
      expect(h.controller.linked, isNotNull);
    });
  });

  group('check for drift', () {
    test('re-reads Smartschool and Azure and re-links', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.checkDrift();

      expect(h.ssSyncs, 2);
      expect(h.azSyncs, 2);
      expect(h.wisaSyncs, 1, reason: 'drift check does not re-pull WISA');
      expect(h.controller.linked, isNotNull);
    });
  });

  group('settings school-profile backfill (#207)', () {
    // The reported settings document: entries written before a profile had a
    // `code`/`name` at all (#171/#194), so the Settings grid — the one view
    // that consults no snapshot — rendered "School 25" until the operator
    // pressed Scholen ophalen *and* Opslaan. Every sync already pulls the whole
    // school list, so it repairs them.
    const legacy = AppSettings(
      wisaSchools: <WisaSchoolProfile>[
        WisaSchoolProfile(schoolId: 25, ours: true),
        WisaSchoolProfile(schoolId: 27, virtual: true),
      ],
    );
    const pulled = <wapi.WisaSchool>[
      wapi.WisaSchool(id: 25, name: 'Instituut Sancta Maria-A', code: 'ISMAA'),
      wapi.WisaSchool(id: 27, name: 'Instituut Sancta Maria-B', code: 'ISMAB'),
    ];

    test('a sync fills the pulled names and codes into the stored profiles',
        () async {
      final settings = InMemorySettingsStore(legacy);
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );

      await h.controller.sync();

      final saved = await settings.load();
      expect(
        saved.wisaSchools.map((p) => p.name),
        ['Instituut Sancta Maria-A', 'Instituut Sancta Maria-B'],
      );
      expect(saved.wisaSchools.map((p) => p.code), ['ISMAA', 'ISMAB']);
      expect(saved.wisaSchools.first.ours, isTrue,
          reason: 'the managed mark is the operator\'s, never rewritten');
      expect(saved.wisaSchools.last.virtual, isTrue);
      expect(h.log.entries.where((e) => e.isError), isEmpty);
    });

    test('the unchanged-WISA shortcut still repairs the document', () async {
      // The repair runs before the smart-diff early return, so an operator
      // whose group has nothing to reconcile still gets named schools.
      final settings = InMemorySettingsStore(legacy);
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );
      await h.controller.sync();
      // Model the pre-fix document coming back (another operator saved over it)
      // and re-sync with identical WISA content.
      await settings.save(legacy);

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      final saved = await settings.load();
      expect(saved.wisaSchools.first.name, 'Instituut Sancta Maria-A');
    });

    test('nothing is written when every profile is already named', () async {
      final settings = _RecordingSettingsStore(const AppSettings(
        wisaSchools: <WisaSchoolProfile>[
          WisaSchoolProfile(
            schoolId: 25,
            code: 'ISMAA',
            name: 'Instituut Sancta Maria-A',
            ours: true,
          ),
        ],
      ));
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: settings,
      );

      await h.controller.sync();

      expect(settings.saves, 0,
          reason: 'a sync must not rewrite the settings document for nothing');
    });

    test('a failing settings store is logged, never fails the sync', () async {
      final h = ReconcileHarness(
        wisa: wisaSnap(schools: pulled),
        settingsStore: const _ThrowingSettingsStore('cosmos 503'),
      );

      await h.controller.sync();

      expect(h.controller.error, isNull);
      expect(h.controller.linked, isNotNull);
      expect(
        h.log.entries.where((e) => e.isError).map((e) => e.message),
        contains(contains('cosmos 503')),
      );
    });
  });

  group('cross-session snapshot persistence (#107)', () {
    test('a first sync persists all three snapshots to the store', () async {
      final store = InMemorySnapshotStore();
      final h = ReconcileHarness(store: store);

      await h.controller.sync();

      expect(
        store.storedSystems,
        containsAll([
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
      );
      expect(
          store.peek(core.Origin.azure)!.syncedBy, 'operator@school.example');
    });

    test('a fresh session seeded from the store reuses Smartschool + Azure',
        () async {
      final store = InMemorySnapshotStore();
      // Session 1 pulls and persists everything.
      await ReconcileHarness(store: store).controller.sync();

      // Session 2: a fresh controller over the same store.
      final resumed = await ReconcileHarness.resume(store: store);
      await resumed.controller.sync();

      // WISA is still pulled (the smart diff needs a fresh WISA read), but the
      // Smartschool and Azure snapshots are trusted from the store — no pull.
      expect(resumed.wisaSyncs, 1);
      expect(resumed.ssSyncs, 0,
          reason: 'Smartschool is seeded from the store, not re-pulled');
      expect(resumed.azSyncs, 0,
          reason: 'Azure is seeded from the store, not re-pulled');
      expect(resumed.controller.linked, isNotNull,
          reason: 'the linked view is derived from the seeded snapshots');
      expect(resumed.log.entries.where((e) => e.isError), isEmpty);
    });

    test('check-for-drift re-pulls and replaces the stored copies', () async {
      final store = InMemorySnapshotStore();
      await ReconcileHarness(store: store).controller.sync();
      expect(store.peek(core.Origin.smartschool)!.fetchedAt, kFixtureDate);

      final resumed = await ReconcileHarness.resume(store: store);
      // The drift pull returns snapshots stamped later than the stored copies.
      final driftAt = kFixtureDate.add(const Duration(hours: 3));
      resumed.ssResult = ssSnap(fetchedAt: driftAt);
      resumed.azResult = azSnap(fetchedAt: driftAt);

      await resumed.controller.checkDrift();

      // A drift check re-reads Smartschool + Azure from the connectors…
      expect(resumed.ssSyncs, 1);
      expect(resumed.azSyncs, 1);
      // …and replaces the stored snapshots with the fresh pulls.
      expect(store.peek(core.Origin.smartschool)!.fetchedAt, driftAt);
      expect(store.peek(core.Origin.azure)!.fetchedAt, driftAt);
    });

    test('the Azure delta token survives across sessions', () async {
      final store = InMemorySnapshotStore();
      final s1 = ReconcileHarness(
        store: store,
        azure: az.AzureSnapshot(
          fetchedAt: kFixtureDate,
          deltaToken: 'DELTA-42',
          users: [azUser()],
          groups: const [],
        ),
      );
      await s1.controller.sync();

      // The seeded Azure snapshot carries the delta token forward, priming the
      // next incremental /users/delta.
      final resumed = await ReconcileHarness.resume(store: store);
      expect(resumed.app.azure.snapshot?.deltaToken, 'DELTA-42');
    });
  });

  group('failures', () {
    test('a failing WISA sync surfaces the error and keeps the old view',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      h.wisaError = StateError('WISA host unreachable');
      await h.controller.sync();

      expect(h.controller.error, contains('WISA host unreachable'));
      expect(h.controller.busy, isFalse);
      expect(identical(h.controller.linked, linkedBefore), isTrue);
      expect(h.log.hasErrors, isTrue);
    });
  });

  group('dry-run', () {
    test('walks every applyable action with zero writes', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      await h.controller.dryRun();

      final results = h.controller.dryRunResults;
      expect(results, isNotNull);
      expect(results, isNotEmpty);
      expect(
        results!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.dryRun),
      );
      expect(
        results.map((r) => r.changes.summary),
        contains('Wijzig de klas in Smartschool'),
      );
      expect(h.soap.soapActions, isEmpty, reason: 'a dry run writes nothing');
      expect(h.graph.requests, isEmpty, reason: 'a dry run writes nothing');
      expect(h.controller.applyResults, isNull);
    });
  });

  group('apply', () {
    test('writes the pending actions and refreshes the linked view', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      final linkedBefore = h.controller.linked;

      await h.controller.applyAll();

      final results = h.controller.applyResults;
      expect(results, isNotNull);
      expect(
        results!
            .where((r) => r.changes.summary == 'Wijzig de klas in Smartschool')
            .single
            .outcome,
        actions.ActionOutcome.applied,
      );
      expect(h.soap.soapActions, isNotEmpty,
          reason: 'the class move is a real Smartschool write');
      expect(identical(h.controller.linked, linkedBefore), isFalse,
          reason: 'a real write re-links from the patched snapshot');
    });

    /// Every node of the overview tree keyed by its rollup key, with the count
    /// the badge renders — the whole projection #236 is about, in one map.
    Map<String, int> pendingByNode(ReconcileController c) => <String, int>{
          for (final root in c.studentRollups) ...<String, int>{
            root.key: root.pendingCount,
            for (final klas in c.studentChildrenOf(root))
              klas.key: klas.pendingCount,
          },
          if (c.groupRollup case final groups?) groups.key: groups.pendingCount,
        };

    /// The classroom node whose badge the fixture's one student action sits
    /// under: Sam's class, 3C of school 1.
    Rollup klas3C(ReconcileController c) => c
        .studentChildrenOf(
            c.studentRollups.singleWhere((r) => r.gradeYear == '3'))
        .singleWhere((r) => r.classroom == '3C');

    /// Sam's pending entry — the one applyable student action in the fixture.
    PendingAccountEntry samEntry(ReconcileController c) =>
        c.pendingEntries.singleWhere((e) => e.family == 'student');

    test('re-derives the counts the pass just changed, and only those (#236)',
        () async {
      // The badges read `Rollup.pendingCount` off `_rollups`, which only
      // [_persist] assigned — and that runs from `_relink()` alone. So an apply
      // left the drilled-in list (live, derived from `_linked`) and the overview
      // disagreeing until the next Synchroniseer.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      expect(klas3C(h.controller).pendingCount, 1);
      expect(h.controller.groupRollup!.pendingCount, 4);

      await h.controller.applyEntry(samEntry(h.controller));

      expect(h.controller.error, isNull);
      expect(klas3C(h.controller).pendingCount, 0,
          reason: 'the badge used to keep its pre-apply count until a re-sync');
      expect(
        h.controller.studentRollups
            .singleWhere((r) => r.gradeYear == '3')
            .pendingCount,
        0,
        reason: 'the grade-year above it is summed from the same rollups',
      );
      expect(h.controller.groupRollup!.pendingCount, 4,
          reason: 'a re-derivation of what changed, not a blanket reset');
    });

    test('a dry-run leaves every count exactly as it found it (#236)',
        () async {
      // The correction is gated on a *real* write: a projection changes nothing,
      // so it must not move a single badge.
      final h = appliedClassWorkHarness();
      await h.controller.sync();
      final before = pendingByNode(h.controller);
      expect(before.values, contains(greaterThan(0)));

      await h.controller.dryRun();

      expect(pendingByNode(h.controller), before);
      expect(h.soap.soapActions, isEmpty, reason: 'nothing was written');
      expect(h.graph.requests, isEmpty, reason: 'nothing was written');
    });

    test(
        'a pass with a refused write clears only what really went through '
        '(#236)', () async {
      // The counts must follow the writes, not the pass: the first action is
      // refused, the rest land. Sam's class keeps its badge while the class
      // groups lose theirs.
      var calls = 0;
      final h = appliedClassWorkHarness(applyGate: () async {
        if (++calls == 1) throw StateError('Office 365 weigerde dit');
      });
      await h.controller.sync();
      expect(klas3C(h.controller).pendingCount, 1);

      await h.controller.applyAll();

      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        containsAll(<actions.ActionOutcome>[
          actions.ActionOutcome.failed,
          actions.ActionOutcome.applied,
        ]),
      );
      expect(klas3C(h.controller).pendingCount, 1,
          reason: "the refused write left Sam's name as it was");
      expect(h.controller.groupRollup, isNull,
          reason: 'the class-group work that did land is gone');
    });

    test(
        'the refreshed counts are local — the shared store keeps its generation '
        '(#236, shared half in #254)', () async {
      // A deliberate choice, not an oversight: rewriting ~9.6k documents per
      // apply is not affordable, and bumping this session's generation would
      // gate out the very `onStoreChanged` that should overrule this
      // correction. Other operators catch up on the next sync.
      final h = appliedClassWorkHarness();
      Future<Rollup> stored3C() async => (await h.linkedStore.readRollups())
          .singleWhere((r) => r.classroom == '3C' && r.school == '1');

      await h.controller.sync();
      final before = await h.linkedStore.readSyncState();

      await h.controller.applyEntry(samEntry(h.controller));

      expect(
          (await h.linkedStore.readSyncState()).generation, before.generation,
          reason: 'no write, so no new generation');
      expect(h.controller.syncState.generation, before.generation,
          reason: 'the session must stay behind the store, never ahead of it');
      expect((await stored3C()).pendingCount, 1,
          reason: 'the stored view stays pre-apply until someone syncs (#254)');
      expect(klas3C(h.controller).pendingCount, 0,
          reason: '…while this session already reads the corrected count');
    });

    test('informational group actions are listed but never applied', () async {
      // An orphan Smartschool class (no WISA counterpart) surfaces the
      // informational DoNotImportFromSmartschool — visible in the pending
      // list, skipped by the apply pass (its apply() throws by contract).
      final h = ReconcileHarness(
        smartschool: ssSnap(
          groups: [
            ssGroup('2B', code: '2B_ss'),
            ssGroup('3C', code: '3C_ss'),
            ssGroup('9Z', code: '9Z_ss'),
          ],
        ),
      );
      await h.controller.sync();

      final informational = h.controller.pendingViews.where((v) => !v.canApply);
      expect(informational, isNotEmpty);
      expect(h.controller.applyableCount,
          lessThan(h.controller.pendingActions.length));

      await h.controller.applyAll();

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        isNot(contains(actions.ActionOutcome.failed)),
      );
    });
  });

  group('provisioning a WISA-only student (#230)', () {
    /// A new intake: one student in a managed school with neither a Smartschool
    /// nor an Office 365 account, and the Smartschool class they belong to.
    ReconcileHarness newIntakeHarness() => ReconcileHarness(
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
        );

    /// The student's own pending entry (the Smartschool class the fixture
    /// carries has no WISA counterpart, so it raises a group entry of its own).
    PendingAccountEntry studentEntry(ReconcileController controller) =>
        controller.pendingEntries.singleWhere((e) => e.family == 'student');

    test('is offered exactly one applyable entry', () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      final entry = studentEntry(h.controller);
      expect(entry.canApply, isTrue);
      expect(entry.choices.single.selected.kind, 'AddStudentToAzure');
    });

    test('applying it provisions both accounts and reports both writes',
        () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h.controller));

      expect(h.controller.error, isNull);
      expect(
        h.controller.applyResults!.map((r) => r.changes.summary),
        <String>[
          'Maak een nieuw Office 365 account',
          'Maak een nieuw Smartschool account',
        ],
        reason: 'one click, the whole provisioning chain',
      );
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      // Both writes really happened, and the linked view carries both records.
      expect(h.graph.createdUsers.single['employeeId'], 'W7');
      expect(h.soap.soapActions.any((a) => a.contains('saveUser')), isTrue);
      final linked = h.controller.linked!.snapshot.accounts.single;
      expect(linked.azure, isNotNull);
      expect(linked.smartschool, isNotNull);
    });

    test('the chained write is logged like any other', () async {
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentEntry(h.controller));

      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('Maak een nieuw Smartschool account')),
      );
    });

    test('a dry run projects only the write it can actually describe',
        () async {
      // The chain rides the incremental refresh, which a dry run does not
      // perform — so it stays a projection of the one write, with no Graph POST
      // and no Smartschool call behind it.
      final h = newIntakeHarness();
      await h.controller.sync();

      await h.controller.dryRunEntry(studentEntry(h.controller));

      expect(
        h.controller.dryRunResults!.map((r) => r.changes.summary),
        <String>['Maak een nieuw Office 365 account'],
      );
      expect(h.graph.createdUsers, isEmpty);
      expect(h.soap.soapActions, isEmpty);
    });

    test(
        'the published step counts planned actions and reports the chained '
        'write apart from them (#243)', () async {
      // The progress dialog's total can only ever be the *planned* actions:
      // dispatch is a pure function of the record as it stands, so the
      // Smartschool create does not exist until the Azure create has landed and
      // relinked. Folding it into the total would mean promising a number
      // nobody could know — so it is reported as a follow-up instead.
      final h = newIntakeHarness();
      await h.controller.sync();

      final steps = recordSteps(h.controller);
      await h.controller.applyAll();

      expect(steps.map((s) => s.total).toSet(), <int>{steps.length},
          reason: 'the planned total never moves mid-pass');
      expect(
          steps.map((s) => s.index), List.generate(steps.length, (i) => i + 1));
      expect(steps.first.summary, 'Maak een nieuw Office 365 account');
      expect(steps.first.followUps, 0);
      expect(steps.first.dry, isFalse);
      // The Azure create pulled the Smartschool create in behind it, so the
      // pass performed one write more than it planned actions.
      expect(h.controller.applyResults!.length, steps.length + 1);
      expect(steps.skip(1).map((s) => s.followUps), everyElement(1));
      // Nothing is in flight once the pass is over.
      expect(h.controller.applyStep, isNull);
    });
  });

  group('the pass publishes the step it is on (#243)', () {
    test('a dry-run names each action before it runs, and clears at the end',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      final steps = recordSteps(h.controller);
      await h.controller.dryRun();

      expect(steps, isNotEmpty);
      expect(steps.map((s) => s.dry), everyElement(isTrue));
      expect(steps.map((s) => s.target), everyElement(isNotEmpty));
      expect(steps.map((s) => s.summary), everyElement(isNotEmpty));
      expect(steps.last.index, steps.last.total);
      expect(h.controller.applyStep, isNull);
    });

    test('a sync publishes no step — it walks no actions', () async {
      final h = ReconcileHarness();
      final steps = recordSteps(h.controller);
      await h.controller.sync();

      expect(steps, isEmpty);
      expect(h.controller.applyStep, isNull);
    });
  });

  group('managed-school filter visibility (#230)', () {
    test('a sync says how many students the filter dropped', () async {
      // School 2 is not in the managed set, and its student owns no account of
      // ours — so they are (correctly, #178) kept out of the Actions view. That
      // used to happen with no node, no count and no log line, which is exactly
      // how a school the operator forgot to flag in Instellingen reads.
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [
            wisaStudent(wisaId: '1'),
            wisaStudent(wisaId: '2', schoolId: 2),
          ],
          schools: [wisaSchool(1), wisaSchool(2)],
        ),
        smartschool: ssSnap(
          groups: const [],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
      );

      await h.controller.sync();

      expect(
        h.log.entries.map((e) => e.message),
        contains('1 leerling(en) overgeslagen: '
            'niet in een school die we beheren.'),
      );
    });

    test('a sync with nothing dropped stays quiet', () async {
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(wisaId: '1')],
          schools: [wisaSchool(1)],
        ),
        smartschool: ssSnap(
          groups: const [],
          accounts: const [],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
        ourSchoolIds: const {1},
      );

      await h.controller.sync();

      expect(
        h.log.entries.map((e) => e.message),
        isNot(contains(contains('overgeslagen'))),
      );
    });
  });

  group('busy-pass progress (#176)', () {
    /// Records [ReconcileController.progress] on every notification, so a test
    /// can assert the pass stepped the bar forward through its stages even
    /// though the whole pass resolves within a single microtask flush.
    List<double> recordProgress(ReconcileController controller) {
      final seen = <double>[];
      controller.addListener(() => seen.add(controller.progress));
      return seen;
    }

    void expectMonotonic(List<double> values) {
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i - 1]),
            reason: 'progress must never move backwards: $values');
      }
    }

    test('a sync steps the bar forward through every stage', () async {
      final h = ReconcileHarness();
      final seen = recordProgress(h.controller);

      await h.controller.sync();

      expect(seen, isNotEmpty);
      expect(seen.first, 0.0, reason: 'a pass resets the bar to the start');
      expectMonotonic(seen);
      // The bar visited intermediate stages (systems pulled, linking,
      // persisting) rather than jumping straight to done — the "advances"
      // the issue asks for.
      expect(seen.where((v) => v > 0.0 && v < 1.0).length,
          greaterThanOrEqualTo(3));
      expect(h.controller.progress, greaterThanOrEqualTo(0.9));
    });

    test('an unchanged re-sync still advances past the start', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));

      final seen = recordProgress(h.controller);
      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      expect(seen.first, 0.0);
      expectMonotonic(seen);
      expect(seen.any((v) => v > 0.0), isTrue,
          reason: 'even the short no-changes path moves the bar off zero');
    });

    test('a drift check steps the bar forward through its stages', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      final seen = recordProgress(h.controller);
      await h.controller.checkDrift();

      expect(seen.first, 0.0);
      expectMonotonic(seen);
      expect(seen.where((v) => v > 0.0 && v < 1.0), isNotEmpty);
    });

    test('an apply advances once per action, reaching 1.0', () async {
      final h = manyDepartedHarness(count: 4);
      await h.controller.sync();
      expect(h.controller.applyableCount, 4);

      final seen = recordProgress(h.controller);
      await h.controller.applyAll();

      expect(seen.first, 0.0);
      expectMonotonic(seen);
      // One step per applied action: 0.25, 0.5, 0.75, 1.0.
      expect(seen, containsAllInOrder(<double>[0.25, 0.5, 0.75, 1.0]));
      expect(h.controller.progress, 1.0);
    });
  });

  group('materialized view (#115)', () {
    test('a sync writes per-account docs + rollups + bumps the generation',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      final state = await h.linkedStore.readSyncState();
      expect(state.generation, 1, reason: 'first sync bumps 0 → 1');
      expect(state.updatedBy, 'operator@school.example');

      expect(h.linkedStore.accountCount, 1);
      final rollups = await h.linkedStore.readRollups();
      final classroom =
          rollups.singleWhere((r) => r.level == RollupLevel.classroom);
      expect(classroom.accountCount, 1);
      expect(classroom.classroom, '3C');

      expect(h.controller.hasOverview, isTrue);
      expect(h.controller.syncState.generation, 1);
    });

    test(
        'school rollups are labelled from the persisted Settings profiles, '
        'not the school id (#204)', () async {
      // The regression: the label map was built solely from the WISA snapshot's
      // schools, so a session whose snapshot carries none (a cold seed written
      // before schools were serialized) baked `School 25` into every document.
      final h = namedSchoolHarness();

      await h.controller.sync();

      final rollups = await h.linkedStore.readRollups();
      final school = rollups.singleWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
      expect(school.label, isNot('School 25'));

      // The same label is baked into the per-account documents the drill-down
      // reads back, so a passive session sees it too.
      final accounts = await h.linkedStore.readClassroom(
        school: school.school,
        classroom: '3C',
      );
      expect(accounts.single.schoolLabel, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('a live WISA pull labels schools it carries itself (#204)', () async {
      // No Settings profile at all: the pulled school list still names the
      // school by its own two halves rather than by its id.
      final h = ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(schoolId: 25)],
          schools: const [
            wapi.WisaSchool(
              id: 25,
              name: 'Instituut Sancta Maria-A',
              code: 'ISMAA',
              isOurs: true,
            ),
          ],
        ),
      );

      await h.controller.sync();

      final rollups = await h.linkedStore.readRollups();
      final school = rollups.singleWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('re-sync bumps the generation again', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A changed WISA pull forces a re-link + re-materialize.
      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect((await h.linkedStore.readSyncState()).generation, 2);
    });

    test('a persisted decision survives a re-sync whose situation still exists',
        () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      // Stand in for what #110's UI will write: a decision on the pending move.
      final accountId = h.controller.linked!.studentActions.first.target.id;
      await h.linkedStore.putDecision(AccountDecision(
        accountId: accountId,
        kind: DecisionKind.chosenAlternative,
        targetKind: 'MoveToSmartschoolClassGroup',
        decidedBy: 'operator@school.example',
        decidedAt: kFixtureDate,
      ));

      // Re-sync (WISA changed but the move situation persists).
      h.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      final decisions = await h.linkedStore.readDecisions();
      expect(decisions, hasLength(1),
          reason: 'the move is still due, so the decision is kept');
      final classroom =
          await h.linkedStore.readClassroom(school: '1', classroom: '3D');
      expect(classroom.single.decisions, hasLength(1),
          reason: 'the surviving decision is re-attached to the account doc');
    });
  });

  group('category overview summaries (#163)', () {
    void expectSummary(CategorySummary s,
        {required int total, required int pending}) {
      expect(s.total, total);
      expect(s.pending, pending);
    }

    test('are empty before any sync', () {
      final h = ReconcileHarness();
      expectSummary(h.controller.studentSummary, total: 0, pending: 0);
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
      expectSummary(h.controller.groupSummary, total: 0, pending: 0);
    });

    test('sum the rollups per category after a sync', () async {
      final h = ReconcileHarness();
      await h.controller.sync();

      // One fixture student (School 1); the rollup pendingCount sums her
      // applyable candidate actions (as the Actions drill-down badges do).
      expectSummary(h.controller.studentSummary, total: 1, pending: 2);
      // No staff in the fixture ⇒ the staff bucket is absent.
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
      // Two Smartschool-only classes (2B, 3C) are informational group notices,
      // so they count toward the total but carry no applyable pending action.
      expectSummary(h.controller.groupSummary, total: 2, pending: 0);
    });

    test('departed students sum across the unassigned bucket, not staff',
        () async {
      // Three WISA-departed, Smartschool-only accounts, all in the synthetic
      // "unassigned" school — never the staff bucket. Each carries two applyable
      // candidates (the unregister + delete alternatives), so the rollup
      // pendingCount is 3 × 2.
      final h = manyDepartedHarness(count: 3);
      await h.controller.sync();

      expectSummary(h.controller.studentSummary, total: 3, pending: 6);
      expectSummary(h.controller.staffSummary, total: 0, pending: 0);
    });

    test('a passive session derives the summaries from the stored rollups',
        () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
          .controller
          .sync();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.linked, isNull);
      expectSummary(s2.controller.studentSummary, total: 1, pending: 2);
      expectSummary(s2.controller.groupSummary, total: 2, pending: 0);
    });
  });

  group('school-less student drill-down (#210)', () {
    test(
        'the top level is the grade-years merged across every managed school, '
        'with combined counts and no school node', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      // School 1 holds 1A + 3C, school 2 holds 1B + OKAN. The overview merges
      // the years: one "Jaar 1" spanning both schools' first years.
      expect(
        h.controller.studentRollups.map((r) => r.label),
        <String>['Jaar 1', 'Jaar 3', 'Overige klassen'],
        reason: 'ordering is pinned: years ascending, then the non-numeric one',
      );
      final jaar1 = h.controller.studentRollups.first;
      expect(jaar1.accountCount, 2, reason: "school 1's 1A plus school 2's 1B");
      expect(jaar1.pendingCount, greaterThan(0));

      // The school level is gone from the view — and never had a node label of
      // its own to fall back on.
      expect(
        h.controller.studentRollups.map((r) => r.level),
        everyElement(isNot(RollupLevel.school)),
      );
      expect(h.controller.studentRollups.map((r) => r.label),
          isNot(contains('School 1')));

      // …but the stored rollups keep it, so the aggregates that count by
      // RollupLevel.school (the badges, the category summaries) still have data.
      expect(h.controller.schoolRollups.map((r) => r.label),
          containsAll(<String>['School 1', 'School 2']));
      expect(h.controller.studentSummary.total, 4);
    });

    test(
        'a merged year lists both schools\' classrooms, each keeping its own '
        'partition so the drill-down still reads one partition', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      final jaar1 =
          h.controller.studentRollups.firstWhere((r) => r.label == 'Jaar 1');
      final classes = h.controller.studentChildrenOf(jaar1);
      expect(classes.map((r) => r.label), <String>['1A', '1B']);
      // The partition key of each class is its real school — what
      // `readClassroom(partitionKey: school)` targets.
      expect(classes.map((r) => r.school), <String>['1', '2']);

      // Opening one reads exactly that school's partition.
      await h.controller.openClassroom(classes.last);
      expect(h.controller.classroomAccounts, hasLength(1));
      expect(h.controller.classroomAccounts!.single.school, '2');
    });

    test('a non-numeric class group is never labelled "Jaar Overig"', () async {
      final h = twoSchoolHarness();
      await h.controller.sync();

      final other = h.controller.studentRollups.last;
      expect(other.label, 'Overige klassen');
      expect(other.gradeYear, 'Overig');
      expect(
        h.controller.studentChildrenOf(other).map((r) => r.label),
        <String>['OKAN'],
      );
    });

    test('"Niet toegewezen" expands straight to its classrooms', () async {
      // Three WISA-departed accounts: all land in the unassigned bucket, whose
      // grade level is always the synthetic "Overig" and carries no decision.
      final h = manyDepartedHarness(count: 3);
      await h.controller.sync();

      final roots = h.controller.studentRollups;
      expect(roots.map((r) => r.label), <String>['Niet toegewezen'],
          reason: 'no year node for a bucket that has no real year');
      final children = h.controller.studentChildrenOf(roots.single);
      expect(children.map((r) => r.label), <String>['Zonder klas']);
      expect(children.single.level, RollupLevel.classroom,
          reason: 'the always-empty grade level is skipped');
      expect(children.single.accountCount, 3);
    });

    test(
        'a passive session projects the same tree from the stored view, with '
        'its badges and header count untouched', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();
      final s1 = twoSchoolHarness();
      // Materialize through a first session, then read it back passively.
      final active = ReconcileHarness(
        store: snapshots,
        linkedStore: linkedStore,
        wisa: s1.wisaResult,
        smartschool: s1.ssResult,
        azure: s1.azResult,
        ourSchoolIds: const {1, 2},
      );
      await active.controller.sync();

      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.linked, isNull, reason: 'passive: never linked');
      expect(
        s2.controller.studentRollups.map((r) => r.label),
        active.controller.studentRollups.map((r) => r.label),
      );
      expect(
        s2.controller.studentRollups.map((r) => r.accountCount),
        active.controller.studentRollups.map((r) => r.accountCount),
      );
      // The counters read from RollupLevel.school rollups, which the view
      // projection deliberately left in the store.
      expect(
          s2.controller.totalPendingCount, active.controller.totalPendingCount);
      expect(s2.controller.studentPendingCount,
          active.controller.studentPendingCount);
      expect(
          s2.controller.staffPendingCount, active.controller.staffPendingCount);
      expect(s2.controller.totalPendingCount, greaterThan(0));
    });
  });

  group('materialized group actions (#119)', () {
    test('a sync materializes group docs + a group rollup', () async {
      // The fixture's two Smartschool-only classes (2B, 3C) raise the
      // informational orphan notice — the group family.
      final h = ReconcileHarness();

      await h.controller.sync();

      expect(h.linkedStore.groupCount, greaterThan(0));
      final groups = await h.linkedStore.readGroups();
      expect(groups.map((g) => g.label), containsAll(['2B', '3C']));
      expect(h.controller.groupRollup, isNotNull);
      expect(h.controller.groupRollup!.accountCount, groups.length);
    });

    test(
        'a passive session opens the Klasgroepen drill-down with no pull or '
        'link()', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      // Session 1 syncs and materializes the shared view.
      await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
          .controller
          .sync();

      // Session 2: a fresh, passive controller over the same stores.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      expect(s2.controller.groupRollup, isNotNull,
          reason: 'the group rollup came from the shared store');

      await s2.controller.openGroups();

      expect(s2.controller.showingGroups, isTrue);
      expect(s2.controller.groupDocs, isNotEmpty);
      // No connector pull and no linked view derived this session.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
      expect(s2.controller.linked, isNull);

      s2.controller.closeGroups();
      expect(s2.controller.showingGroups, isFalse);
      expect(s2.controller.groupDocs, isNull);
    });
  });

  group('passive session reads the store (#115)', () {
    test(
        'a resumed session renders the overview and drills into a classroom '
        'without any pull or link()', () async {
      final snapshots = InMemorySnapshotStore();
      final linkedStore = InMemoryLinkedStore();

      // Session 1 syncs and materializes the shared view.
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2: a fresh controller over the same stores, passive.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();

      // No connector pull and no linked view derived this session.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
      expect(s2.controller.linked, isNull, reason: 'link() was never called');

      // The overview came from the store.
      expect(s2.controller.hasOverview, isTrue);
      expect(s2.controller.syncState.generation, 1);
      final classroom = s2.controller.schoolRollups
          .expand((s) => s2.controller.childrenOf(s.key))
          .expand((g) => s2.controller.childrenOf(g.key))
          .single;

      await s2.controller.openClassroom(classroom);

      expect(s2.controller.selectedClassroom, classroom);
      expect(s2.controller.classroomAccounts, hasLength(1));
      // Still no pull.
      expect(s2.wisaSyncs, 0);
      expect(s2.ssSyncs, 0);
      expect(s2.azSyncs, 0);
    });
  });

  group('multi-operator coordination (#108)', () {
    test('a sync records per-system freshness (who/when) in the shared store',
        () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      final systems = (await h.linkedStore.readSyncState()).systems;
      expect(
          systems.keys,
          containsAll(<core.Origin>[
            core.Origin.wisa,
            core.Origin.smartschool,
            core.Origin.azure,
          ]));
      expect(systems[core.Origin.wisa]?.syncedBy, 'operator@school.example');
      expect(systems[core.Origin.wisa]?.at, kFixtureDate);
      // …and the controller mirrors it for the header.
      expect(h.controller.syncState.systems[core.Origin.azure]?.syncedBy,
          'operator@school.example');
    });

    test('the "WISA unchanged" path still stamps WISA freshness', () async {
      final h = ReconcileHarness();
      await h.controller.sync();
      // A later, identical WISA pull: no re-link, but WISA was still read.
      final later = kFixtureDate.add(const Duration(hours: 1));
      h.wisaResult = wisaSnap(fetchedAt: later);

      await h.controller.sync();

      expect(h.controller.noChangesNeeded, isTrue);
      final systems = (await h.linkedStore.readSyncState()).systems;
      expect(systems[core.Origin.wisa]?.at, later,
          reason: 'WISA freshness advances even with no view change');
      expect((await h.linkedStore.readSyncState()).generation, 1,
          reason: 'an unchanged sync does not bump the generation');
    });

    test(
        'a later WISA-only smart-sync keeps the Smartschool/Azure freshness '
        '(#170)', () async {
      final store = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: store);
      // First full sync: all three systems are pulled and stamped at the
      // fixture time.
      await h.controller.sync();
      final first = (await store.readSyncState()).systems;
      expect(
        first.keys,
        containsAll(<core.Origin>[
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
        reason: 'the first full sync records every system',
      );

      // A later smart-sync where only WISA changed: Smartschool and Azure are
      // not re-pulled (their in-session snapshots are present).
      final later = kFixtureDate.add(const Duration(hours: 1));
      h.wisaResult = wisaSnap(
        fetchedAt: later,
        students: [wisaStudent(classGroup: '3D')],
      );
      await h.controller.sync();

      expect(h.ssSyncs, 1,
          reason: 'Smartschool is not re-pulled by smart-sync');
      expect(h.azSyncs, 1, reason: 'Azure is not re-pulled by smart-sync');

      // The store must still carry all three — WISA advanced, the drift-checked
      // pair keeps its earlier stamp rather than being overwritten.
      final stored = (await store.readSyncState()).systems;
      expect(stored[core.Origin.wisa]?.at, later);
      expect(stored[core.Origin.smartschool]?.at, kFixtureDate);
      expect(stored[core.Origin.azure]?.at, kFixtureDate);
      // …and the operator stamp from the earlier pull survives too (#169).
      expect(
          stored[core.Origin.smartschool]?.syncedBy, 'operator@school.example');
      expect(stored[core.Origin.azure]?.syncedBy, 'operator@school.example');

      // The controller mirrors the merged store for the header line.
      final live = h.controller.syncState.systems;
      expect(
        live.keys,
        containsAll(<core.Origin>[
          core.Origin.wisa,
          core.Origin.smartschool,
          core.Origin.azure,
        ]),
      );
      expect(live[core.Origin.wisa]?.at, later);
      expect(live[core.Origin.smartschool]?.at, kFixtureDate);
      expect(live[core.Origin.azure]?.at, kFixtureDate);
    });

    test('a Check for drift stamps Smartschool and Azure freshness (#170)',
        () async {
      final store = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: store);
      await h.controller.sync();

      // Drift check re-pulls Smartschool and Azure at a later time.
      final later = kFixtureDate.add(const Duration(hours: 2));
      h.ssResult = ssSnap(fetchedAt: later);
      h.azResult = azSnap(fetchedAt: later);
      await h.controller.checkDrift();

      final systems = (await store.readSyncState()).systems;
      expect(systems[core.Origin.smartschool]?.at, later);
      expect(systems[core.Origin.azure]?.at, later);
      // WISA keeps its earlier sync stamp (drift does not re-pull it here).
      expect(systems[core.Origin.wisa]?.at, kFixtureDate);
    });

    test('a sync takes and releases the lease', () async {
      final h = ReconcileHarness();

      await h.controller.sync();

      // Released at the end of the pass — free for the next operator.
      expect(await h.linkedStore.readLease(kFixtureDate), isNull);
      expect(h.controller.syncLockedByOther, isFalse);
    });

    test("another operator's live lease blocks this session's sync", () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      // A different operator is mid-sync.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      await h.controller.sync();

      expect(h.wisaSyncs, 0, reason: 'the blocked sync never pulls');
      expect(h.controller.syncLockedByOther, isTrue);
      expect(h.controller.syncLockOwner, 'mieke@school');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('mieke@school')),
      );
    });

    test('a foreign lease blocks check-for-drift too', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      await h.controller.checkDrift();

      expect(h.ssSyncs, 0);
      expect(h.controller.syncLockedByOther, isTrue);
    });

    test('loadOverview surfaces a lock held by another operator', () async {
      final linkedStore = InMemoryLinkedStore();
      // Session 1 materializes an overview.
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();
      // A second operator grabs the lease.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

      final passive = ReconcileHarness(linkedStore: linkedStore);
      await passive.controller.loadOverview();

      expect(passive.controller.syncLockedByOther, isTrue);
      expect(passive.controller.syncLockOwner, 'mieke@school');
    });

    test('onStoreChanged refetches the overview and the open classroom',
        () async {
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 (the student sits in 3C).
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2 renders the shared overview and drills into 3C.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();
      final classroom3c = s2.controller.schoolRollups
          .expand((s) => s2.controller.childrenOf(s.key))
          .expand((g) => s2.controller.childrenOf(g.key))
          .singleWhere((c) => c.classroom == '3C');
      await s2.controller.openClassroom(classroom3c);
      expect(s2.controller.classroomAccounts, hasLength(1));

      // Session 1 moves the student to 3D and re-syncs → generation 2.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();
      expect((await linkedStore.readSyncState()).generation, 2);

      // The realtime layer (#116) will call this on the generation bump.
      await s2.controller.onStoreChanged(2);

      expect(s2.controller.syncState.generation, 2);
      // The open 3C shard was refetched — the student has left it.
      expect(s2.controller.classroomAccounts, isEmpty);
      // …and 3D now exists in the refreshed rollups.
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3D'),
      );
    });

    test('onStoreChanged is a no-op for a stale-or-equal generation', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = ReconcileHarness(linkedStore: linkedStore);
      await h.controller.sync();

      // Same generation the controller already holds → nothing refetched.
      await h.controller.onStoreChanged(1);
      expect(h.controller.syncState.generation, 1);
    });

    test(
        'resyncFromStore catches a reconnecting session up regardless of '
        'generation (#124)', () async {
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 (the student sits in 3C).
      final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
      await s1.controller.sync();

      // Session 2 renders the shared overview and drills into 3C.
      final s2 = await ReconcileHarness.resume(
        store: snapshots,
        linkedStore: linkedStore,
      );
      await s2.controller.loadOverview();
      final classroom3c = s2.controller.schoolRollups
          .expand((s) => s2.controller.childrenOf(s.key))
          .expand((g) => s2.controller.childrenOf(g.key))
          .singleWhere((c) => c.classroom == '3C');
      await s2.controller.openClassroom(classroom3c);
      expect(s2.controller.classroomAccounts, hasLength(1));

      // Session 1 moves the student to 3D → generation 2. Session 2 was
      // "disconnected" and never saw the nudge.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();

      // A reconnect drives the catch-up with no generation argument — it
      // re-reads unconditionally and the open 3C shard refreshes to empty.
      await s2.controller.resyncFromStore();
      expect(s2.controller.syncState.generation, 2);
      expect(s2.controller.classroomAccounts, isEmpty);
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3D'),
      );
    });
  });

  group('realtime signals (#116)', () {
    test('a sync publishes syncStarted → viewChanged → syncEnded', () async {
      final hub = InMemorySignalHub();
      final h = ReconcileHarness(hub: hub);

      await h.controller.sync();

      expect(hub.published.map((s) => s.kind), [
        ChangeSignalKind.syncStarted,
        ChangeSignalKind.viewChanged,
        ChangeSignalKind.syncEnded,
      ]);
      expect(hub.published.first.owner, h.syncedBy);
      final changed = hub.published[1];
      expect(changed.generation, 1);
      expect(changed.shard, isNull,
          reason: 'the sync path rewrites the whole view — no narrower shard');
      expect(hub.published.last.owner, h.syncedBy);
    });

    test('an unchanged WISA re-sync does not publish a viewChanged', () async {
      final hub = InMemorySignalHub();
      final h = ReconcileHarness(hub: hub);
      await h.controller.sync();
      final before = hub.published.length;

      // A fresh but identical WISA pull → "no changes needed", no re-link.
      h.wisaResult =
          wisaSnap(fetchedAt: kFixtureDate.add(const Duration(hours: 1)));
      await h.controller.sync();

      final second = hub.published.sublist(before);
      expect(second.map((s) => s.kind),
          isNot(contains(ChangeSignalKind.viewChanged)),
          reason: 'nothing materialized, so no view-change nudge');
      // The lease is still taken and released around the (no-op) pass.
      expect(second.map((s) => s.kind), [
        ChangeSignalKind.syncStarted,
        ChangeSignalKind.syncEnded,
      ]);
    });

    test("another session's viewChanged refetches this session's overview",
        () async {
      final hub = InMemorySignalHub();
      final linkedStore = InMemoryLinkedStore();
      final snapshots = InMemorySnapshotStore();

      // Session 1 materializes generation 1 and broadcasts.
      final s1 = ReconcileHarness(
          store: snapshots, linkedStore: linkedStore, hub: hub);
      await s1.controller.sync();

      // Session 2 renders the shared overview passively, on the same hub.
      final s2 = await ReconcileHarness.resume(
          store: snapshots, linkedStore: linkedStore, hub: hub);
      await s2.controller.loadOverview();
      expect(s2.controller.syncState.generation, 1);

      // Session 1 moves the student and re-syncs → generation 2 is broadcast.
      s1.wisaResult = wisaSnap(
        fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
        students: [wisaStudent(classGroup: '3D')],
      );
      await s1.controller.sync();
      await pumpEventQueue();

      // Session 2 caught up from the signal alone — no direct onStoreChanged.
      expect(s2.controller.syncState.generation, 2);
      expect(
        s2.controller.schoolRollups
            .expand((s) => s2.controller.childrenOf(s.key))
            .expand((g) => s2.controller.childrenOf(g.key))
            .map((c) => c.classroom),
        contains('3D'),
      );
    });

    test('a syncStarted signal locks a passive session; syncEnded unlocks',
        () async {
      final hub = InMemorySignalHub();
      final linkedStore = InMemoryLinkedStore();
      // A first session leaves an overview in the shared store (no hub, so it
      // does not publish into this test).
      await ReconcileHarness(linkedStore: linkedStore).controller.sync();

      final passive = ReconcileHarness(linkedStore: linkedStore, hub: hub);
      await passive.controller.loadOverview();
      expect(passive.controller.syncLockedByOther, isFalse);

      // Another operator takes the lease and nudges everyone.
      await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);
      await hub
          .publisher()
          .publish(const ChangeSignal.syncStarted(owner: 'mieke@school'));
      await pumpEventQueue();
      expect(passive.controller.syncLockedByOther, isTrue);
      expect(passive.controller.syncLockOwner, 'mieke@school');

      // They finish: release + nudge → the passive session re-enables.
      await linkedStore.releaseLease(owner: 'mieke@school');
      await hub
          .publisher()
          .publish(const ChangeSignal.syncEnded(owner: 'mieke@school'));
      await pumpEventQueue();
      expect(passive.controller.syncLockedByOther, isFalse);
    });

    test('a publish failure is logged but never fails the sync', () async {
      final h = ReconcileHarness(publisher: _ThrowingPublisher());

      await h.controller.sync();

      expect(h.controller.error, isNull, reason: 'the pass still succeeds');
      expect(h.controller.linked, isNotNull);
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('Could not publish a change signal')),
      );
    });
  });

  group('accepted duplicate-mail (#109)', () {
    test('a synced collision surfaces one warning with its colliding accounts',
        () async {
      final h = dupMailHarness();
      await h.controller.sync();

      final warnings = h.controller.duplicateWarnings;
      expect(warnings, hasLength(1));
      final w = warnings.single;
      expect(w.mail, 'shared@school.example');
      expect(w.accepted, isFalse);
      expect(w.accounts.map((a) => a.uid).toSet(), {'admin', 'user'});
      // The colliding accounts carry their display detail for the drill-down.
      expect(w.accounts.every((a) => a.name.isNotEmpty), isTrue);
      expect(w.accounts.every((a) => a.accountType == 'student'), isTrue);
    });

    test(
        'accepting persists a decision and demotes the warning; revoke restores',
        () async {
      final linkedStore = InMemoryLinkedStore();
      final h = dupMailHarness(linkedStore: linkedStore);
      await h.controller.sync();

      await h.controller.acceptDuplicate('shared@school.example');
      // Persisted as an acceptedDuplicate decision keyed to a colliding account.
      final stored = await linkedStore.readDecisions();
      expect(stored, hasLength(1));
      expect(stored.single.kind, DecisionKind.acceptedDuplicate);
      // …and the live warning is now demoted (accepted).
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      await h.controller.revokeDuplicate('shared@school.example');
      expect(await linkedStore.readDecisions(), isEmpty);
      expect(h.controller.duplicateWarnings.single.accepted, isFalse);
    });

    test('an accepted collision survives a re-sync (re-attached decision)',
        () async {
      final linkedStore = InMemoryLinkedStore();
      // A snapshot store makes the re-sync path materialize + merge decisions.
      final h = ReconcileHarness(
        wisa: wisaSnap(students: const []),
        smartschool: dupMailSnap(),
        azure: azSnap(users: const []),
        store: InMemorySnapshotStore(),
        linkedStore: linkedStore,
      );
      await h.controller.sync();
      await h.controller.acceptDuplicate('shared@school.example');
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      // Re-read Smartschool/Azure and re-link; the view is rewritten wholesale.
      await h.controller.checkDrift();

      // The decision survived the rewrite (merge re-attached it), still accepted.
      expect(await linkedStore.readDecisions(), hasLength(1));
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);
    });

    test('a changed colliding set re-warns even after acceptance', () async {
      final linkedStore = InMemoryLinkedStore();
      final h = dupMailHarness(linkedStore: linkedStore);
      await h.controller.sync();
      await h.controller.acceptDuplicate('shared@school.example');
      expect(h.controller.duplicateWarnings.single.accepted, isTrue);

      // A third account joins the same mail: re-read Smartschool via drift.
      h.ssResult = dupMailSnap(uids: const ['admin', 'user', 'intruder']);
      await h.controller.checkDrift();

      final w = h.controller.duplicateWarnings.single;
      expect(w.accounts, hasLength(3));
      expect(w.accepted, isFalse,
          reason: 'a new colliding account must re-surface the warning');
    });
  });

  group('LogBuffer', () {
    test('caps its entries and reports errors', () {
      final log = LogBuffer(capacity: 3, clock: () => kFixtureDate);
      for (var i = 0; i < 5; i++) {
        log.addMessage(core.Origin.wisa, 'message $i');
      }
      expect(log.entries, hasLength(3));
      expect(log.entries.first.message, 'message 2');
      expect(log.hasErrors, isFalse);

      log.addError(core.Origin.azure, 'boom');
      expect(log.hasErrors, isTrue);

      log.clear();
      expect(log.entries, isEmpty);
    });
  });
}
