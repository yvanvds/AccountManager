import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A small in-memory [CosmosClient] covering the query shapes
/// [CosmosLinkedStore] issues: `SELECT * FROM c`, the classroom filter, and the
/// `SELECT c.id, c.pk FROM c` id/pk projection — honouring [partitionKey]
/// scoping via each document's `pk` field.
class _FakeClient implements CosmosClient {
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};
  int deletes = 0;

  /// Conditioned upserts rejected as stale (412) — for the concurrency test.
  int staleWrites = 0;
  int _etagSeq = 0;

  String _nextEtag() => 'etag-${++_etagSeq}';

  Map<String, Map<String, dynamic>> _c(String name) =>
      _store.putIfAbsent(name, () => {});

  List<Map<String, dynamic>> _all(String container, String? pk) => [
        for (final d in _c(container).values)
          if (pk == null || d['pk'] == pk) Map<String, dynamic>.from(d),
      ];

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    final d = _c(container)[id];
    return d == null ? null : Map<String, dynamic>.from(d);
  }

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    final id = document['id'] as String;
    // Model Cosmos's atomic create: a 409 (→ false) when the id already exists.
    // The sync/drift lease relies on this to keep two acquirers from both
    // "creating" the lease document.
    if (_c(container).containsKey(id)) return false;
    _c(container)[id] = Map.of(document)..['_etag'] = _nextEtag();
    return true;
  }

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    final id = document['id'] as String;
    if (ifMatch != null && _c(container)[id]?['_etag'] != ifMatch) {
      staleWrites++;
      return const WriteOutcome.stale();
    }
    final etag = _nextEtag();
    _c(container)[id] = Map.of(document)..['_etag'] = etag;
    return WriteOutcome.applied(etag);
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    if (_c(container).remove(id) != null) deletes++;
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async {
    var rows = _all(container, partitionKey);
    if (query.contains('c.classroom = @classroom')) {
      final want = parameters['@classroom'];
      rows = [
        for (final d in rows)
          if (d['classroom'] == want) d
      ];
    }
    if (query.contains('SELECT c.id, c.pk')) {
      return [
        for (final d in rows) {'id': d['id'], 'pk': d['pk']},
      ];
    }
    return rows;
  }
}

final DateTime _d = DateTime.utc(2026, 7, 1);

MaterializedAccount _account(String id,
        {String school = '1', String classroom = '3C'}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: 'School $school',
      gradeYear: '3',
      classroom: classroom,
      role: core.PersonRole.student,
      isStaff: false,
      confidence: core.LinkConfidence.high,
      label: 'Jane $id',
      inWisa: true,
      inSmartschool: true,
      inAzure: true,
      candidates: const [
        CandidateAction(
          family: 'student',
          kind: 'MoveToSmartschoolClassGroup',
          system: core.Origin.smartschool,
          summary: 'Move',
        ),
      ],
    );

MaterializedGroup _group(String name) => MaterializedGroup(
      id: core.LinkedAccountId('group|$name'),
      label: name,
      confidence: core.LinkConfidence.medium,
      inWisa: false,
      inSmartschool: true,
      inAzure: false,
      candidates: const [
        CandidateAction(
          family: 'group',
          kind: 'DoNotImportFromSmartschool',
          system: core.Origin.smartschool,
          summary: 'Orphan',
          canApply: false,
        ),
      ],
    );

MaterializedView _view(
  List<MaterializedAccount> accounts, {
  int generation = 1,
  List<MaterializedGroup> groups = const [],
}) =>
    MaterializedView(
      generation: generation,
      accounts: accounts,
      groups: groups,
      rollups: buildRollups(accounts),
    );

void main() {
  group('CosmosLinkedStore', () {
    test('write then read: sync state, rollups, classroom drill-down',
        () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);

      await store.writeMaterialized(
        _view([_account('p0'), _account('p1', classroom: '3C')]),
        syncedBy: 'op@school.example',
        at: _d,
      );

      final state = await store.readSyncState();
      expect(state.generation, 1);
      expect(state.updatedBy, 'op@school.example');

      final rollups = await store.readRollups();
      expect(
          rollups.where((r) => r.level == RollupLevel.classroom), hasLength(1));

      final classroom = await store.readClassroom(school: '1', classroom: '3C');
      expect(classroom.map((a) => a.id.value), containsAll(['p0', 'p1']));
    });

    test('write then read: group docs, deleted on a groupless re-sync (#119)',
        () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);

      await store.writeMaterialized(
        _view([_account('p0')], groups: [_group('9Z'), _group('8A')]),
        syncedBy: 'op@school.example',
        at: _d,
      );

      final groups = await store.readGroups();
      expect(groups.map((g) => g.label), containsAll(['9Z', '8A']));
      expect(groups.every((g) => g.school == groupsPartition), isTrue);

      // A re-sync with no groups deletes the stragglers.
      await store.writeMaterialized(
        _view([_account('p0')], generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(await store.readGroups(), isEmpty);
    });

    test('a re-sync deletes the docs no longer present', () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);

      await store.writeMaterialized(
        _view([_account('p0'), _account('p1')]),
        syncedBy: 'op@school.example',
        at: _d,
      );
      // Second sync: p1 is gone.
      await store.writeMaterialized(
        _view([_account('p0')], generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );

      final remaining = await store.readClassroom(school: '1', classroom: '3C');
      expect(remaining.map((a) => a.id.value), ['p0']);
      expect((await store.readSyncState()).generation, 2);
    });

    test('putDecision round-trips and writeMaterialized drops the ones passed',
        () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      final decision = AccountDecision(
        accountId: const core.LinkedAccountId('p0'),
        kind: DecisionKind.chosenAlternative,
        targetKind: 'MoveToSmartschoolClassGroup',
        decidedBy: 'op@school.example',
        decidedAt: _d,
      );

      await store.putDecision(decision);
      expect(await store.readDecisions(), hasLength(1));

      await store.writeMaterialized(
        _view([_account('p0')]),
        syncedBy: 'op@school.example',
        at: _d,
        droppedDecisions: [decision],
      );
      expect(await store.readDecisions(), isEmpty);
    });

    test('reading before any sync yields the initial generation', () async {
      final store = CosmosLinkedStore(_FakeClient());
      expect((await store.readSyncState()).generation, 0);
      expect(await store.readRollups(), isEmpty);
    });

    test('writeMaterialized persists per-system sync metadata (#108)',
        () async {
      final store = CosmosLinkedStore(_FakeClient());

      await store.writeMaterialized(
        _view([_account('p0')]),
        syncedBy: 'jan@school',
        at: _d,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: _d),
        },
      );

      final state = await store.readSyncState();
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school');
      expect(state.systems[core.Origin.wisa]?.at, _d);
    });

    test('recordSystemSync merges into the doc without bumping generation',
        () async {
      final store = CosmosLinkedStore(_FakeClient());
      await store.writeMaterialized(
        _view([_account('p0')]),
        syncedBy: 'jan@school',
        at: _d,
        systemSyncs: {
          core.Origin.wisa: SystemSyncMeta(syncedBy: 'jan@school', at: _d),
        },
      );

      final later = _d.add(const Duration(hours: 2));
      await store.recordSystemSync({
        core.Origin.azure: SystemSyncMeta(syncedBy: 'mieke@school', at: later),
      });

      final state = await store.readSyncState();
      expect(state.generation, 1, reason: 'metadata touch is not a view write');
      expect(state.systems[core.Origin.wisa]?.syncedBy, 'jan@school');
      expect(state.systems[core.Origin.azure]?.syncedBy, 'mieke@school');
    });
  });

  group('CosmosLinkedStore putDecision ETag concurrency (#121)', () {
    AccountDecision decisionFor(String accountId, {String by = 'op@school'}) =>
        AccountDecision(
          accountId: core.LinkedAccountId(accountId),
          kind: DecisionKind.chosenAlternative,
          targetKind: 'MoveToSmartschoolClassGroup',
          decidedBy: by,
          decidedAt: _d,
        );

    test('two applies to different accounts both succeed with no contention',
        () async {
      // The two operators share the one centralized account.
      final client = _FakeClient();
      final a = CosmosLinkedStore(client);
      final b = CosmosLinkedStore(client);

      await Future.wait([
        a.putDecision(decisionFor('p0')),
        b.putDecision(decisionFor('p1')),
      ]);

      final decisions = await CosmosLinkedStore(client).readDecisions();
      expect(
          decisions.map((d) => d.accountId.value), containsAll(['p0', 'p1']));
      expect(client.staleWrites, 0,
          reason: 'different docs never share an ETag, so no write is stale');
    });

    test('two applies to the same decision doc serialize via the ETag',
        () async {
      final client = _FakeClient();
      // Seed the decision doc so both concurrent writers take the conditioned
      // upsert path (rather than one racing an atomic create).
      await CosmosLinkedStore(client)
          .putDecision(decisionFor('p0', by: 'seed'));

      final a = CosmosLinkedStore(client);
      final b = CosmosLinkedStore(client);
      await Future.wait([
        a.putDecision(decisionFor('p0', by: 'jan')),
        b.putDecision(decisionFor('p0', by: 'mieke')),
      ]);

      // One writer's If-Match went stale and it re-read the winner's ETag and
      // retried — so both converge to a single, present decision doc.
      expect(client.staleWrites, greaterThanOrEqualTo(1),
          reason: 'the same doc under two writers must race at least once');
      final decisions = await CosmosLinkedStore(client).readDecisions();
      expect(decisions, hasLength(1));
      expect(['jan', 'mieke'], contains(decisions.single.decidedBy));
    });
  });

  group('CosmosLinkedStore sync/drift lease (#108)', () {
    test('acquire creates the lease doc; readLease returns it', () async {
      final store = CosmosLinkedStore(_FakeClient());

      final out = await store.acquireLease(owner: 'jan@school', now: _d);
      expect(out.acquired, isTrue);
      expect((await store.readLease(_d))?.owner, 'jan@school');
    });

    test('a second operator is blocked by a live lease', () async {
      final client = _FakeClient();
      final a = CosmosLinkedStore(client);
      final b = CosmosLinkedStore(client);
      await a.acquireLease(owner: 'jan@school', now: _d);

      final out = await b.acquireLease(owner: 'mieke@school', now: _d);
      expect(out.acquired, isFalse);
      expect(out.lease.owner, 'jan@school');
    });

    test('release deletes the doc so the next acquire succeeds', () async {
      final client = _FakeClient();
      final a = CosmosLinkedStore(client);
      final b = CosmosLinkedStore(client);
      await a.acquireLease(owner: 'jan@school', now: _d);

      await a.releaseLease(owner: 'jan@school');
      expect(await a.readLease(_d), isNull);

      final out = await b.acquireLease(owner: 'mieke@school', now: _d);
      expect(out.acquired, isTrue);
    });

    test('an expired lease is taken over, and readLease treats it as gone',
        () async {
      final client = _FakeClient();
      final a = CosmosLinkedStore(client);
      final b = CosmosLinkedStore(client);
      await a.acquireLease(owner: 'jan@school', now: _d);
      final afterExpiry = _d.add(syncLeaseTtl).add(const Duration(seconds: 1));

      expect(await b.readLease(afterExpiry), isNull);
      final out = await b.acquireLease(owner: 'mieke@school', now: afterExpiry);
      expect(out.acquired, isTrue);
      expect((await b.readLease(afterExpiry))?.owner, 'mieke@school');
    });
  });
}
