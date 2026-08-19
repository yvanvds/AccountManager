import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// What a `SELECT c.id, c.pk[, c.contentHash] FROM c` projection returns: the
/// named fields only, and — as Cosmos does — with a field the stored document
/// does not carry simply absent rather than null. Shared by the fakes below so
/// none of them silently hands the store back a whole document.
Map<String, dynamic> _projection(Map<String, dynamic> doc, String query) => {
      'id': doc['id'],
      'pk': doc['pk'],
      if (query.contains('c.$contentHashField') &&
          doc.containsKey(contentHashField))
        contentHashField: doc[contentHashField],
    };

/// A small in-memory [CosmosClient] covering the query shapes
/// [CosmosLinkedStore] issues: `SELECT * FROM c`, the classroom filter, and the
/// `SELECT c.id, c.pk, c.contentHash FROM c` projection — honouring
/// [partitionKey] scoping via each document's `pk` field.
class _FakeClient implements CosmosClient {
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};
  int deletes = 0;

  /// Upserts per container, so a test can assert what a re-sync actually wrote
  /// (#200) rather than only what the container ended up holding.
  final Map<String, int> upserts = {};

  int upsertsTo(String container) => upserts[container] ?? 0;

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
    upserts[container] = upsertsTo(container) + 1;
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
      return [for (final d in rows) _projection(d, query)];
    }
    return rows;
  }

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      true;
}

/// A [CosmosClient] that models an account where only *provisioned* containers
/// accept items: every item operation on a container not yet [ensureContainer]d
/// throws the `404 NotFound` the real account returns for a write to a
/// non-existent container. Reproduces the #150 bug — `putDecision` 404s until
/// the `decisions` container is provisioned.
class _EnforcingFakeClient implements CosmosClient {
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};
  final Set<String> _containers = {};

  Map<String, Map<String, dynamic>> _c(String name) {
    if (!_containers.contains(name)) {
      throw CosmosException(
        404,
        '{"code":"NotFound","message":"Resource Not Found: container '
        '\\"$name\\" is not provisioned."}',
      );
    }
    return _store.putIfAbsent(name, () => {});
  }

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      _containers.add(container);

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
    final docs = _c(container);
    final id = document['id'] as String;
    if (docs.containsKey(id)) return false;
    docs[id] = Map.of(document);
    return true;
  }

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    _c(container)[document['id'] as String] = Map.of(document);
    return const WriteOutcome.applied('etag');
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    _c(container).remove(id);
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async =>
      [for (final d in _c(container).values) Map<String, dynamic>.from(d)];
}

/// A [CosmosClient] that yields on every upsert (so writes can overlap) and
/// records the peak number of concurrent upserts — to prove [writeMaterialized]
/// fans out with *bounded* concurrency rather than one-at-a-time or unbounded
/// (#168).
class _ConcurrencyClient implements CosmosClient {
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};
  int inFlight = 0;
  int peakInFlight = 0;
  int upserts = 0;

  Map<String, Map<String, dynamic>> _c(String name) =>
      _store.putIfAbsent(name, () => {});

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    inFlight++;
    upserts++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    // Yield twice so overlapping calls actually interleave before any completes.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _c(container)[document['id'] as String] = Map.of(document);
    inFlight--;
    return const WriteOutcome.applied('etag');
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async {
    if (query.contains('SELECT c.id, c.pk')) {
      return [for (final d in _c(container).values) _projection(d, query)];
    }
    return [for (final d in _c(container).values) Map<String, dynamic>.from(d)];
  }

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async =>
      _c(container)[id];

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    _c(container)[document['id'] as String] = Map.of(document);
    return true;
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    _c(container).remove(id);
  }

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      true;
}

/// A [CosmosClient] that stands in for the real client's throttle reporting: it
/// drives the shared [CosmosThrottleGovernor] on a script (throttle early,
/// recover later) and records how many upserts were in flight at the moment each
/// one started — so the write fan-out's *reaction* to throttling is observable
/// without a Cosmos account (#196).
class _AdaptiveClient implements CosmosClient {
  _AdaptiveClient(
    this.governor, {
    required this.throttleAt,
    required this.recoverFrom,
  });

  final CosmosThrottleGovernor governor;

  /// The 1-based upsert number that reports a 429 (as the client's retry loop
  /// would after absorbing one).
  final int throttleAt;

  /// From this upsert on, every write lands cleanly, so the governor's slow
  /// recovery widens the fan-out again.
  final int recoverFrom;

  final Map<String, Map<String, Map<String, dynamic>>> _store = {};

  /// In-flight upserts at the start of each upsert, in issue order.
  final List<int> inFlightAt = [];
  int _inFlight = 0;
  int upserts = 0;

  Map<String, Map<String, dynamic>> _c(String name) =>
      _store.putIfAbsent(name, () => {});

  /// The widest fan-out seen over upserts `[from, to)`.
  int peakOver(int from, int to) => inFlightAt
      .sublist(from.clamp(0, inFlightAt.length), to.clamp(0, inFlightAt.length))
      .fold(0, (a, b) => a > b ? a : b);

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    _inFlight++;
    upserts++;
    inFlightAt.add(_inFlight);
    if (upserts == throttleAt) {
      governor.recordThrottle(attempt: 1, wait: Duration.zero);
    } else if (upserts >= recoverFrom) {
      governor.recordSuccess();
    }
    // Yield twice so overlapping calls actually interleave before any completes.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _c(container)[document['id'] as String] = Map.of(document);
    _inFlight--;
    return const WriteOutcome.applied('etag');
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async {
    if (query.contains('SELECT c.id, c.pk')) {
      return [for (final d in _c(container).values) _projection(d, query)];
    }
    return [for (final d in _c(container).values) Map<String, dynamic>.from(d)];
  }

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async =>
      _c(container)[id];

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    _c(container)[document['id'] as String] = Map.of(document);
    return true;
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    _c(container).remove(id);
  }

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      true;
}

/// A [CosmosClient] whose upsert throws once — the terminal failure a persist
/// hits when Cosmos has run out of retry attempts. Counts every upsert so a test
/// can prove the sibling workers stopped instead of running on unawaited (#196).
class _FailingClient implements CosmosClient {
  _FailingClient({required this.failAfter});

  final int failAfter;
  int upserts = 0;
  bool thrown = false;

  @override
  Future<WriteOutcome> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
    String? ifMatch,
  }) async {
    upserts++;
    await Future<void>.delayed(Duration.zero);
    if (!thrown && upserts >= failAfter) {
      thrown = true;
      throw const CosmosException(
        429,
        '{"code":"TooManyRequests","message":"The request rate is too large."}',
      );
    }
    return const WriteOutcome.applied('etag');
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async =>
      null;

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async =>
      true;

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {}

  @override
  Future<bool> ensureContainer({
    required String container,
    required String partitionKeyPath,
  }) async =>
      true;
}

/// Lets every pending microtask/timer-zero callback run, so a test can prove
/// nothing *further* happens after an awaited call returned.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final DateTime _d = DateTime.utc(2026, 7, 1);

MaterializedAccount _account(String id,
        {String school = '1', String classroom = '3C', String? schoolLabel}) =>
    MaterializedAccount(
      id: core.LinkedAccountId(id),
      school: school,
      schoolLabel: schoolLabel ?? 'School $school',
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

    test(
        'putDecision 404s until the decisions container is provisioned, then '
        'persists (#150)', () async {
      final client = _EnforcingFakeClient();
      final store = CosmosLinkedStore(client);
      final decision = acceptedDuplicateDecision(
        accountId: const core.LinkedAccountId('p0'),
        mail: 'shared@school.example',
        uids: const ['admin', 'user'],
        decidedBy: 'op@school.example',
        decidedAt: _d,
      );

      // The bug: with the decisions container not provisioned, the accept write
      // fails with the same 404 the operator saw ("Kon de acceptatie niet
      // opslaan: CosmosException(404 ...)").
      await expectLater(
        store.putDecision(decision),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );

      // Provisioning the containers closes the gap: the same write now round-
      // trips and the acceptance survives.
      await ensureContainers(client);
      await store.putDecision(decision);
      expect(await store.readDecisions(), hasLength(1));
    });

    test('deleteDecision removes the decision doc (revoke, #109)', () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      final decision = acceptedDuplicateDecision(
        accountId: const core.LinkedAccountId('p0'),
        mail: 'shared@school.example',
        uids: const ['admin', 'user'],
        decidedBy: 'op@school.example',
        decidedAt: _d,
      );

      await store.putDecision(decision);
      expect(await store.readDecisions(), hasLength(1));

      await store.deleteDecision(decision);
      expect(await store.readDecisions(), isEmpty);
    });

    test(
        'a full-size view writes with bounded concurrency and reports progress '
        '(#168)', () async {
      final client = _ConcurrencyClient();
      final store = CosmosLinkedStore(client);
      final progress = <String>[];

      // A large account set: enough to cross the progress-report interval and to
      // exercise the bounded fan-out.
      final accounts = [
        for (var i = 0; i < 2500; i++) _account('p$i', classroom: 'c${i % 30}'),
      ];

      await store.writeMaterialized(
        _view(accounts),
        syncedBy: 'op@school.example',
        at: _d,
        onProgress: progress.add,
      );

      // Every account doc was upserted…
      expect(client.upserts, greaterThanOrEqualTo(2500));
      // …with overlap (not strictly serial), but bounded — never a stampede of
      // thousands of simultaneous writes.
      expect(client.peakInFlight, greaterThan(1),
          reason: 'the write fans out rather than crawling one at a time');
      expect(client.peakInFlight, lessThanOrEqualTo(24),
          reason: 'concurrency is capped so it never stampedes throughput');
      // The long write ticked visibly: interim lines plus a final full count for
      // the big account container.
      expect(progress, isNotEmpty);
      expect(progress.where((m) => m.startsWith('Persisting accounts:')),
          isNotEmpty);
      expect(progress, contains('Persisting accounts: 1000/2500…'));
      expect(progress, contains('Persisting accounts: 2500/2500…'));

      // The whole set round-trips despite the batching.
      expect((await store.readRollups()).isNotEmpty, isTrue);
    });

    test(
        'the write fan-out narrows while Cosmos throttles and widens again as '
        'it eases (#196)', () async {
      // #168 fixed the fan-out at 24 on the assumption that stayed "well under
      // the throughput that would trip sustained throttling". At real volume it
      // does not, so the width has to follow the account instead of guessing it.
      final governor = CosmosThrottleGovernor(
        maxConcurrency: 16,
        minConcurrency: 2,
        recoverAfter: 5,
      );
      // The account absorbs the opening writes, then throttles — the shape of
      // the real run, where the burst only exceeds the RU/s budget once it is
      // properly under way.
      final client = _AdaptiveClient(
        governor,
        throttleAt: 30,
        recoverFrom: 150,
      );
      final store = CosmosLinkedStore(client, governor: governor);
      final accounts = [
        for (var i = 0; i < 600; i++) _account('p$i', classroom: 'c${i % 30}'),
      ];

      await store.writeMaterialized(
        _view(accounts),
        syncedBy: 'op@school.example',
        at: _d,
      );

      // It started wide…
      expect(client.peakOver(0, 20), greaterThan(8),
          reason: 'an unthrottled account gets the full fan-out');
      // …then the 429 halved the ceiling and the extra workers retired, so the
      // throttled stretch never runs wider than the narrowed ceiling.
      expect(client.peakOver(60, 140), lessThanOrEqualTo(8),
          reason: 'the writer stops pushing the load the account rejected');
      // …and once the writes land cleanly again the pool refills.
      expect(client.peakOver(300, 600), greaterThan(8),
          reason: 'one transient 429 must not cost the rest of the persist its '
              'speed');
      expect(governor.concurrency, 16);
      // The whole set still round-trips despite the narrowing.
      expect(client.upserts, greaterThanOrEqualTo(600));
      expect((await store.readClassroom(school: '1', classroom: 'c0')),
          isNotEmpty);
    });

    test(
        'a terminal write failure stops the sibling workers instead of letting '
        'them run on (#196)', () async {
      // The second consequence in the bug report: Future.wait rejected on the
      // first error while 23 other workers kept firing upserts into the very
      // account that had just been reported as failed.
      final client = _FailingClient(failAfter: 40);
      final store = CosmosLinkedStore(client);
      final accounts = [
        for (var i = 0; i < 4000; i++) _account('p$i', classroom: 'c${i % 30}'),
      ];

      await expectLater(
        store.writeMaterialized(
          _view(accounts),
          syncedBy: 'op@school.example',
          at: _d,
        ),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );

      // The error surfaced only once every worker had wound down…
      final atFailure = client.upserts;
      expect(atFailure, lessThan(4000),
          reason: 'the pass aborts rather than writing the whole set anyway');
      await _settle();
      expect(client.upserts, atFailure,
          reason: 'not one more write after the operator was told it failed');
    });

    test('an unchanged re-sync writes no documents at all (#200)', () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      final accounts = [
        for (var i = 0; i < 50; i++) _account('p$i', classroom: 'c${i % 5}'),
      ];
      final groups = [_group('9Z'), _group('8A')];

      await store.writeMaterialized(
        _view(accounts, groups: groups),
        syncedBy: 'op@school.example',
        at: _d,
      );
      final accountWrites = client.upsertsTo(linkedAccountsContainer);
      final rollupWrites = client.upsertsTo(rollupsContainer);
      expect(accountWrites, 50, reason: 'the first sync writes the whole set');
      expect(rollupWrites, greaterThan(0));

      // The identical view again — the everyday case, where nothing about the
      // three systems moved since the last pass.
      final progress = <String>[];
      await store.writeMaterialized(
        _view(accounts, generation: 2, groups: groups),
        syncedBy: 'op@school.example',
        at: _d,
        onProgress: progress.add,
      );

      // Not one per-document write: the whole ~4k-doc burst that trips the
      // serverless account's 429s simply does not happen.
      expect(client.upsertsTo(linkedAccountsContainer), accountWrites);
      expect(client.upsertsTo(linkedGroupsContainer), groups.length);
      expect(client.upsertsTo(rollupsContainer), rollupWrites);
      expect(client.deletes, 0, reason: 'nothing departed, nothing deleted');
      // The operator is told the pass was a no-op rather than seeing silence.
      expect(
          progress, contains('Persisting accounts: 50 unchanged, 0 to write…'));
      // …and the view is still whole and still readable.
      expect(await store.readClassroom(school: '1', classroom: 'c0'),
          hasLength(10));
      expect(await store.readGroups(), hasLength(2));
      // The generation bump is unconditional, so every passive session still
      // learns there is a new view (#116).
      expect((await store.readSyncState()).generation, 2);
    });

    test('a changed document is still written on a re-sync (#200)', () async {
      // The correctness risk of skipping: a hash computed over too little would
      // silently drop a real change on the floor.
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      final accounts = [
        for (var i = 0; i < 20; i++) _account('p$i', classroom: '3C'),
      ];

      await store.writeMaterialized(
        _view(accounts),
        syncedBy: 'op@school.example',
        at: _d,
      );
      final afterFirst = client.upsertsTo(linkedAccountsContainer);

      // One account moved class; everything else is identical.
      final moved = [
        _account('p0', classroom: '4A'),
        for (var i = 1; i < 20; i++) _account('p$i', classroom: '3C'),
      ];
      await store.writeMaterialized(
        _view(moved, generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );

      expect(client.upsertsTo(linkedAccountsContainer), afterFirst + 1,
          reason: 'exactly the one changed account was rewritten');
      final threeC = await store.readClassroom(school: '1', classroom: '3C');
      expect(threeC.map((a) => a.id.value), isNot(contains('p0')));
      final fourA = await store.readClassroom(school: '1', classroom: '4A');
      expect(fourA.map((a) => a.id.value), ['p0']);
    });

    test('a renamed school label reaches the store on a re-sync (#204/#200)',
        () async {
      // The school label is baked into every account document and into the
      // school rollup, so a better label only becomes visible if the
      // changed-document-only write (#200) actually rewrites them. The hash
      // covers the whole document, so it does — this pins that down.
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      List<MaterializedAccount> withLabel(String label) => [
            for (var i = 0; i < 5; i++) _account('p$i', schoolLabel: label),
          ];

      await store.writeMaterialized(
        _view(withLabel('School 1')),
        syncedBy: 'op@school.example',
        at: _d,
      );
      final afterFirst = client.upsertsTo(linkedAccountsContainer);
      final rollupsAfterFirst = client.upsertsTo(rollupsContainer);

      await store.writeMaterialized(
        _view(withLabel('Instituut Sancta Maria-A (ISMAA)'), generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );

      expect(client.upsertsTo(linkedAccountsContainer), afterFirst + 5,
          reason: 'every account carries the changed label');
      expect(client.upsertsTo(rollupsContainer), greaterThan(rollupsAfterFirst),
          reason: 'the school rollup the drill-down renders is rewritten too');
      final stored = await store.readClassroom(school: '1', classroom: '3C');
      expect(stored.first.schoolLabel, 'Instituut Sancta Maria-A (ISMAA)');
      final school = (await store.readRollups())
          .firstWhere((r) => r.level == RollupLevel.school);
      expect(school.label, 'Instituut Sancta Maria-A (ISMAA)');
    });

    test('a change buried in a nested candidate action is not skipped (#200)',
        () async {
      // The hash covers the whole serialized document, so a change anywhere in
      // it — not just in the top-level fields — still reaches the store.
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      MaterializedAccount withSummary(String summary) => MaterializedAccount(
            id: const core.LinkedAccountId('p0'),
            school: '1',
            schoolLabel: 'School 1',
            gradeYear: '3',
            classroom: '3C',
            role: core.PersonRole.student,
            isStaff: false,
            confidence: core.LinkConfidence.high,
            label: 'Jane p0',
            inWisa: true,
            inSmartschool: true,
            inAzure: true,
            candidates: [
              CandidateAction(
                family: 'student',
                kind: 'MoveToSmartschoolClassGroup',
                system: core.Origin.smartschool,
                summary: summary,
              ),
            ],
          );

      await store.writeMaterialized(
        _view([withSummary('Move to 3C')]),
        syncedBy: 'op@school.example',
        at: _d,
      );
      await store.writeMaterialized(
        _view([withSummary('Move to 4A')], generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );

      expect(client.upsertsTo(linkedAccountsContainer), 2);
      final stored = await store.readClassroom(school: '1', classroom: '3C');
      expect(stored.single.candidates.single.summary, 'Move to 4A');
    });

    test('a document stored before #200 carries no hash and is rewritten once',
        () async {
      final client = _FakeClient();
      final store = CosmosLinkedStore(client);
      final account = _account('p0');
      // A pre-#200 document: the same content, stored without a content hash.
      await client.upsertDocument(
        container: linkedAccountsContainer,
        partitionKey: account.school,
        document: account.toJson(),
      );

      await store.writeMaterialized(
        _view([account]),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(client.upsertsTo(linkedAccountsContainer), 2,
          reason: 'an unhashed stored doc is rewritten so it gains its hash');

      // …and from then on it is skipped like any other unchanged document.
      await store.writeMaterialized(
        _view([account], generation: 2),
        syncedBy: 'op@school.example',
        at: _d,
      );
      expect(client.upsertsTo(linkedAccountsContainer), 2);
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
