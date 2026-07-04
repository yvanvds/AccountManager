import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/reconcile/log_buffer.dart';
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

/// A [SignalPublisher] whose every publish throws — to prove a broadcast
/// failure is swallowed and never fails the pass that triggered it (#116).
class _ThrowingPublisher implements SignalPublisher {
  @override
  Future<void> publish(ChangeSignal signal) async =>
      throw StateError('signalr down');
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
