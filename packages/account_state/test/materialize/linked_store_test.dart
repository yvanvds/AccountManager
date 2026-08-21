/// Unit coverage for the multi-operator behaviour the [InMemoryLinkedStore]
/// models: the sync/drift lease (acquire / renew / expire / block, #108), the
/// per-system last-sync metadata merge, and the narrow post-apply write-back
/// (#254). The Cosmos wire shape is covered separately by
/// `cosmos_linked_store_test`.
library;

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A student document in [classroom] of school [school], carrying [pending]
/// applyable candidates.
MaterializedAccount _account(
  String id, {
  String school = '1',
  String gradeYear = '3',
  String classroom = '3C',
  int pending = 0,
}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: 'School $school',
      gradeYear: gradeYear,
      classroom: classroom,
      role: core.PersonRole.student,
      isStaff: false,
      confidence: core.LinkConfidence.high,
      label: 'Jane $id',
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      candidates: [
        for (var i = 0; i < pending; i++)
          CandidateAction(
            family: 'student',
            kind: 'Candidate$i',
            system: core.Origin.smartschool,
            summary: 'Do thing $i',
          ),
      ],
    );

MaterializedGroup _group(String name, {int pending = 0}) => MaterializedGroup(
      id: core.LinkedAccountId(materializedGroupId(name)),
      label: name,
      confidence: core.LinkConfidence.high,
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      candidates: [
        for (var i = 0; i < pending; i++)
          CandidateAction(
            family: 'group',
            kind: 'GroupCandidate$i',
            system: core.Origin.smartschool,
            summary: 'Fix thing $i',
          ),
      ],
    );

void main() {
  final t0 = DateTime.utc(2026, 7, 4, 9, 0);
  MaterializedView view({int generation = 1}) => MaterializedView(
        generation: generation,
        accounts: const [],
        rollups: const [],
      );

  /// A store already holding a materialized view: two students in 3C (one with
  /// work), one in 3D (with work), and two class groups (one with work).
  Future<InMemoryLinkedStore> seeded() async {
    final store = InMemoryLinkedStore();
    final accounts = [
      _account('p0', pending: 1),
      _account('p1'),
      _account('p2', classroom: '3D', pending: 1),
    ];
    final groups = [_group('3C', pending: 1), _group('3D')];
    await store.writeMaterialized(
      MaterializedView(
        generation: 1,
        accounts: accounts,
        groups: groups,
        rollups: [
          ...buildRollups(accounts),
          // The single Klasgroepen node `materialize` adds over the group docs.
          Rollup(
            level: RollupLevel.groups,
            key: groupsPartition,
            parentKey: null,
            school: groupsPartition,
            label: 'Klasgroepen',
            gradeYear: '',
            classroom: '',
            accountCount: groups.length,
            pendingCount: 1,
          ),
        ],
      ),
      syncedBy: 'jan@school',
      at: t0,
    );
    return store;
  }

  Future<Rollup?> node(InMemoryLinkedStore store, String key) async {
    final rollups = await store.readRollups();
    for (final r in rollups) {
      if (r.key == key) return r;
    }
    return null;
  }

  group('sync/drift lease', () {
    test('acquire succeeds when free and readLease returns the live lease',
        () async {
      final store = InMemoryLinkedStore();

      final out = await store.acquireLease(owner: 'jan@school', now: t0);
      expect(out.acquired, isTrue);
      expect(out.lease.owner, 'jan@school');
      expect(out.lease.expiresAt, t0.add(syncLeaseTtl));

      expect((await store.readLease(t0))?.owner, 'jan@school');
    });

    test('a second operator is blocked while a live lease is held', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      final out = await store.acquireLease(owner: 'mieke@school', now: t0);
      expect(out.acquired, isFalse);
      expect(out.heldByOther, isTrue);
      expect(out.lease.owner, 'jan@school',
          reason: 'names the blocking holder');
    });

    test('re-acquiring your own live lease succeeds (idempotent)', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      final out = await store.acquireLease(
        owner: 'jan@school',
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(out.acquired, isTrue);
    });

    test('an expired lease frees for another operator to take over', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);
      final afterExpiry = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));

      // The lease reads as gone once expired…
      expect(await store.readLease(afterExpiry), isNull);
      // …and another operator can take it.
      final out =
          await store.acquireLease(owner: 'mieke@school', now: afterExpiry);
      expect(out.acquired, isTrue);
      expect(out.lease.owner, 'mieke@school');
    });

    test('renew pushes the expiry so the lease is not lost mid-work', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      // Heartbeat just before expiry.
      final beat = t0.add(syncLeaseTtl).subtract(const Duration(seconds: 5));
      final renewed = await store.renewLease(owner: 'jan@school', now: beat);
      expect(renewed.acquired, isTrue);

      // A moment after the *original* expiry the lease is still live.
      final pastOriginal = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));
      expect((await store.readLease(pastOriginal))?.owner, 'jan@school');
    });

    test('renew reports the lease was lost after expiry + takeover', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);
      final afterExpiry = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));
      await store.acquireLease(owner: 'mieke@school', now: afterExpiry);

      final lost =
          await store.renewLease(owner: 'jan@school', now: afterExpiry);
      expect(lost.acquired, isFalse);
      expect(lost.lease.owner, 'mieke@school');
    });

    test('release frees the lease immediately for the next operator', () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      await store.releaseLease(owner: 'jan@school');
      expect(await store.readLease(t0), isNull);

      final out = await store.acquireLease(owner: 'mieke@school', now: t0);
      expect(out.acquired, isTrue);
    });

    test('release by a non-owner is a no-op (cannot free a taken lease)',
        () async {
      final store = InMemoryLinkedStore();
      await store.acquireLease(owner: 'jan@school', now: t0);

      await store.releaseLease(owner: 'mieke@school');
      expect((await store.readLease(t0))?.owner, 'jan@school');
    });
  });

  group('per-system sync metadata', () {
    test('writeMaterialized records the systems pulled this pass', () async {
      final store = InMemoryLinkedStore();

      await store.writeMaterialized(
        view(),
        syncedBy: 'jan@school',
        at: t0,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t0),
        },
      );

      final state = await store.readSyncState();
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school');
      expect(state.systems[core.Origin.wisa]?.at, t0);
    });

    test('a system not pulled this pass keeps its earlier stamp', () async {
      final store = InMemoryLinkedStore();
      // Pass 1 pulls WISA.
      await store.writeMaterialized(
        view(),
        syncedBy: 'jan@school',
        at: t0,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t0),
        },
      );
      // Pass 2 (drift) pulls only Azure, by a different operator.
      final t1 = t0.add(const Duration(hours: 1));
      await store.writeMaterialized(
        view(generation: 2),
        syncedBy: 'mieke@school',
        at: t1,
        systemSyncs: {
          core.Origin.azure: SystemSyncMeta(syncedBy: 'mieke@school', at: t1),
        },
      );

      final state = await store.readSyncState();
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school',
          reason: 'WISA keeps pass 1');
      expect(state.systems[core.Origin.azure]?.syncedBy, 'mieke@school');
    });

    test('recordSystemSync merges without bumping the generation', () async {
      final store = InMemoryLinkedStore();
      await store.writeMaterialized(view(), syncedBy: 'jan@school', at: t0);
      expect((await store.readSyncState()).generation, 1);

      final t1 = t0.add(const Duration(hours: 1));
      await store.recordSystemSync({
        core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: t1),
      });

      final state = await store.readSyncState();
      expect(state.generation, 1, reason: 'a metadata touch is not a new view');
      expect(state.systems[core.Origin.wisa]?.at, t1);
    });
  });

  group('writeApplied — the narrow post-apply write (#254)', () {
    test('patches only the touched document and the nodes above it', () async {
      // The seam exists because the alternative — republishing the whole ~9.6k
      // -document view per apply — is not affordable. So a one-row apply must
      // leave every other document and every other node exactly as it was.
      final store = await seeded();

      final write = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'jan@school',
        at: t0,
      );

      expect(write.written, isTrue);
      expect((await node(store, 'class|1|3|3C'))!.pendingCount, 0,
          reason: "p0's work is done");
      expect((await node(store, 'class|1|3|3C'))!.accountCount, 2,
          reason: 'nobody left the class');
      expect((await node(store, 'grade|1|3'))!.pendingCount, 1,
          reason: "p2's work in 3D is untouched and still summed above");
      expect((await node(store, 'school|1'))!.pendingCount, 1);
      expect((await node(store, 'class|1|3|3D'))!.pendingCount, 1);
      expect((await node(store, groupsPartition))!.pendingCount, 1,
          reason: 'the class groups were not part of this pass');
      final threeC = await store.readClassroom(school: '1', classroom: '3C');
      expect(
        threeC.singleWhere((a) => a.id.value == 'p0').candidates,
        isEmpty,
        reason: 'the stored document itself dropped the applied candidate',
      );
      expect(threeC.singleWhere((a) => a.id.value == 'p1').hasPending, isFalse);
    });

    test('bumps the generation once and stamps who applied it', () async {
      final store = await seeded();

      final write = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'mieke@school',
        at: t0,
      );

      expect(write.generation, 2);
      final state = await store.readSyncState();
      expect(state.generation, 2,
          reason: 'the session that wrote it is current, not ahead of it');
      expect(state.updatedBy, 'mieke@school');
      expect(state.updatedAt, t0);
    });

    test('stands down while another operator holds the sync lease', () async {
      // That pass is republishing the whole view from a fresher link than ours;
      // a narrow patch on top of it — let alone a generation bump past it —
      // would be a local correction outranking the shared view.
      final store = await seeded();
      await store.acquireLease(owner: 'mieke@school', now: t0);

      final write = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'jan@school',
        at: t0,
      );

      expect(write.written, isFalse);
      expect(write.deferredTo?.owner, 'mieke@school');
      expect((await store.readSyncState()).generation, 1);
      expect((await node(store, 'class|1|3|3C'))!.pendingCount, 1,
          reason: 'nothing was written');
    });

    test('our own lease does not block us', () async {
      final store = await seeded();
      await store.acquireLease(owner: 'jan@school', now: t0);

      final write = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'jan@school',
        at: t0,
      );
      expect(write.written, isTrue);
    });

    test('an expired lease does not block either', () async {
      final store = await seeded();
      await store.acquireLease(owner: 'mieke@school', now: t0);
      final afterExpiry = t0.add(syncLeaseTtl).add(const Duration(seconds: 1));

      final write = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'jan@school',
        at: afterExpiry,
      );
      expect(write.written, isTrue);
    });

    test('two operators applying different work compose, never clobber',
        () async {
      // The reason the rollups move by delta. Both sessions linked when 3C and
      // 3D each carried one pending decision; each clears its own. A rollup
      // written from either session's *own* picture of school 1 would put the
      // other's back.
      final store = await seeded();
      final a = await store.writeApplied(
        AppliedPatch(accounts: [_account('p0')]),
        appliedBy: 'jan@school',
        at: t0,
      );
      final b = await store.writeApplied(
        AppliedPatch(accounts: [_account('p2', classroom: '3D')]),
        appliedBy: 'mieke@school',
        at: t0,
      );

      expect([a.generation, b.generation], [2, 3],
          reason: 'each apply gets a generation of its own to broadcast');
      expect((await node(store, 'school|1'))!.pendingCount, 0);
      expect((await node(store, 'class|1|3|3C'))!.pendingCount, 0);
      expect((await node(store, 'class|1|3|3D'))!.pendingCount, 0);
      expect((await node(store, 'school|1'))!.accountCount, 3,
          reason: 'nobody was invented or lost along the way');
    });

    test('a document the apply removed is deleted and its node emptied',
        () async {
      // A student whose last account was just deleted has no document any more;
      // #227 aside, the same holds for a class group that is gone.
      final store = await seeded();

      await store.writeApplied(
        const AppliedPatch(removedAccountIds: ['p2']),
        appliedBy: 'jan@school',
        at: t0,
      );

      expect(await store.readClassroom(school: '1', classroom: '3D'), isEmpty);
      expect(await node(store, 'class|1|3|3D'), isNull,
          reason: 'an empty class is not a node the tree should offer');
      expect((await node(store, 'grade|1|3'))!.accountCount, 2);
      expect((await node(store, 'grade|1|3'))!.pendingCount, 1,
          reason: "p0's own work in 3C is nothing to do with p2's departure");
    });

    test('a class group patch moves the Klasgroepen node only', () async {
      final store = await seeded();

      await store.writeApplied(
        AppliedPatch(groups: [_group('3C')]),
        appliedBy: 'jan@school',
        at: t0,
      );

      final groups = await store.readGroups();
      expect(groups, hasLength(2), reason: 'the inventory keeps every class');
      expect(
        groups.singleWhere((g) => g.label == '3C').candidates,
        isEmpty,
      );
      expect((await node(store, groupsPartition))!.pendingCount, 0);
      expect((await node(store, groupsPartition))!.accountCount, 2);
      expect((await node(store, 'school|1'))!.pendingCount, 2,
          reason: 'the student half of the view was not part of this pass');
    });

    test('an empty patch writes nothing and bumps nothing', () async {
      // A pass whose every write was refused changed no document, so there is
      // nothing to nudge anybody about.
      final store = await seeded();

      final write = await store.writeApplied(
        const AppliedPatch(),
        appliedBy: 'jan@school',
        at: t0,
      );

      expect(write.written, isFalse);
      expect(write.deferredTo, isNull);
      expect((await store.readSyncState()).generation, 1);
    });

    test('a decision carried on the patched document survives the write',
        () async {
      // The derived documents are rewritten wholesale here as everywhere else,
      // so anything the caller does not re-attach is lost — which for an
      // operator decision would be silent data loss on exactly the accounts a
      // pass touched.
      final store = await seeded();
      final decision = AccountDecision(
        accountId: const core.LinkedAccountId('p0'),
        kind: DecisionKind.chosenAlternative,
        targetKind: 'Candidate0',
        decidedBy: 'jan@school',
        decidedAt: t0,
      );
      await store.putDecision(decision);

      await store.writeApplied(
        AppliedPatch(
          accounts: [
            _account('p0', pending: 1).withDecisions([decision])
          ],
        ),
        appliedBy: 'jan@school',
        at: t0,
      );

      final stored = (await store.readClassroom(school: '1', classroom: '3C'))
          .singleWhere((a) => a.id.value == 'p0');
      expect(stored.decisions, hasLength(1));
      expect(await store.readDecisions(), hasLength(1),
          reason: 'the decision documents themselves are never touched here');
    });
  });

  group('SyncState / SystemSyncMeta round-trip', () {
    test('json survives with per-system metadata', () {
      final state = SyncState(
        generation: 3,
        updatedAt: t0,
        updatedBy: 'jan@school',
        systems: {
          core.Origin.smartschool:
              SystemSyncMeta(syncedBy: 'mieke@school', at: t0),
        },
      );

      final back = SyncState.fromJson(state.toJson());
      expect(back.generation, 3);
      expect(back.systems[core.Origin.smartschool]?.syncedBy, 'mieke@school');
      expect(back.systems[core.Origin.smartschool]?.at, t0);
      expect(back.systems[core.Origin.smartschool]?.workDate, isNull,
          reason: 'only a WISA pull is made as of a werkdatum');
    });

    test("json carries a WISA stamp's werkdatum (#247)", () {
      // The date the installed roster was pulled as of. It has to survive the
      // store, or a passive session reading somebody else's sync would have no
      // way to tell which school year the view describes.
      final state = SyncState(
        generation: 3,
        updatedAt: t0,
        updatedBy: 'jan@school',
        systems: {
          core.Origin.wisa: SystemSyncMeta(
            syncedBy: 'jan@school',
            at: t0,
            workDate: DateTime(2026, 9, 1),
          ),
        },
      );

      final back = SyncState.fromJson(state.toJson());
      expect(back.systems[core.Origin.wisa]?.workDate, DateTime(2026, 9, 1));
    });

    test('a stamp written before #247 reads back without a werkdatum', () {
      // Forward-compatibility the other way round: the shared document in
      // Cosmos predates the field, and must still parse.
      final legacy = <String, dynamic>{
        'generation': 2,
        'systems': {
          'wisa': {'syncedBy': 'jan@school', 'at': t0.toIso8601String()},
        },
      };
      final back = SyncState.fromJson(legacy);
      expect(back.systems[core.Origin.wisa]?.at, t0);
      expect(back.systems[core.Origin.wisa]?.workDate, isNull);
    });
  });
}
