import 'dart:convert';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// A [CosmosTransport] that replays a scripted queue of responses and records
/// every outgoing request, so [HttpCosmosClient]'s URL building, auth/date/
/// partition-key headers and continuation paging are testable with no account.
class _FakeTransport implements CosmosTransport {
  _FakeTransport(this._responses);

  final List<CosmosResponse> _responses;
  final List<CosmosRequest> requests = [];
  int _i = 0;

  @override
  Future<CosmosResponse> send(CosmosRequest request) async {
    requests.add(request);
    if (_i >= _responses.length) {
      throw StateError('no scripted response for request #${_i + 1}');
    }
    return _responses[_i++];
  }
}

CosmosResponse _ok(Object body) =>
    CosmosResponse(statusCode: 200, body: jsonEncode(body));

/// The 429 Cosmos answers a write burst with once the request rate exceeds the
/// account's provisioned throughput, carrying its `x-ms-retry-after-ms` hint.
CosmosResponse _throttled({int? retryAfterMs}) => CosmosResponse(
      statusCode: 429,
      headers: {
        if (retryAfterMs != null) 'x-ms-retry-after-ms': '$retryAfterMs',
      },
      body: '{"code":"TooManyRequests","message":"The request rate is too '
          'large. Please retry after sometime."}',
    );

/// A token provider handing out a different token per call, so a test can prove
/// a retry re-reads the (short-lived) bearer token rather than replaying the
/// first attempt's headers.
class _CountingTokenProvider implements CosmosTokenProvider {
  int calls = 0;

  @override
  Future<String> cosmosAccessToken() async => 'token-${++calls}';
}

HttpCosmosClient _client(_FakeTransport transport) => HttpCosmosClient(
      config: const CosmosConfig(
        endpoint: 'https://acct.documents.azure.com:443/',
        database: 'accountmanager',
      ),
      transport: transport,
      // A URL-safe shape like a real JWT (dots/dashes/underscores) so the test
      // pins that those survive the auth-header encoding unescaped.
      tokens: const StaticCosmosTokenProvider('ab.cd-ef_gh'),
      // Fixed clock so the x-ms-date header is deterministic.
      now: () => DateTime.utc(2026, 7, 4, 10, 4, 38),
    );

/// A client whose 429 retry loop is fully deterministic and instant: the backoff
/// is recorded into [slept] instead of being waited out, and the jitter draw is
/// pinned, so the retry path is asserted without a single wall-clock delay
/// (#196).
HttpCosmosClient _retryingClient(
  _FakeTransport transport, {
  required List<Duration> slept,
  CosmosRetryPolicy retry = const CosmosRetryPolicy(),
  CosmosThrottleGovernor? governor,
  CosmosTokenProvider? tokens,
  double roll = 0.0,
}) =>
    HttpCosmosClient(
      config: const CosmosConfig(
        endpoint: 'https://acct.documents.azure.com:443/',
        database: 'accountmanager',
      ),
      transport: transport,
      tokens: tokens ?? const StaticCosmosTokenProvider('ab.cd-ef_gh'),
      now: () => DateTime.utc(2026, 7, 4, 10, 4, 38),
      retry: retry,
      governor: governor,
      sleep: (d) async => slept.add(d),
      jitterRoll: () => roll,
    );

void main() {
  group('HttpCosmosClient request building', () {
    test('a point read builds the doc URL and the AAD auth/date headers',
        () async {
      final transport = _FakeTransport([
        _ok({'id': 'settings'})
      ]);
      final doc = await _client(transport).readDocument(
        container: 'settings',
        id: 'settings',
        partitionKey: 'settings',
      );

      expect(doc, {'id': 'settings'});
      final req = transport.requests.single;
      expect(req.method, 'GET');
      expect(
        // Uri normalizes the default https port (:443) away — harmless.
        req.url.toString(),
        'https://acct.documents.azure.com/dbs/accountmanager/colls/'
        'settings/docs/settings',
      );
      // Cosmos AAD scheme: the whole type=aad&ver=1.0&sig=<token> string,
      // URL-encoded as one header value.
      expect(req.headers['authorization'],
          'type%3Daad%26ver%3D1.0%26sig%3Dab.cd-ef_gh');
      expect(req.headers['x-ms-date'], 'Sat, 04 Jul 2026 10:04:38 GMT');
      expect(req.headers['x-ms-version'], HttpCosmosClient.apiVersion);
      expect(req.headers['x-ms-documentdb-partitionkey'], '["settings"]');
    });

    test('a missing document reads as null (404), not an error', () async {
      final transport = _FakeTransport([const CosmosResponse(statusCode: 404)]);
      final doc = await _client(transport).readDocument(
        container: 'settings',
        id: 'settings',
        partitionKey: 'settings',
      );
      expect(doc, isNull);
    });

    test('createDocument returns true on 201 and posts the body', () async {
      final transport =
          _FakeTransport([const CosmosResponse(statusCode: 201, body: '{}')]);
      final created = await _client(transport).createDocument(
        container: 'identity',
        partitionKey: 'identity',
        document: {'id': 'a', 'naturalKey': 'wisa:1'},
      );

      expect(created, isTrue);
      final req = transport.requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), endsWith('/colls/identity/docs'));
      expect(jsonDecode(req.body!), {'id': 'a', 'naturalKey': 'wisa:1'});
      expect(req.headers.containsKey('x-ms-documentdb-is-upsert'), isFalse);
    });

    test('createDocument returns false on a 409 conflict (no throw)', () async {
      final transport = _FakeTransport([
        const CosmosResponse(statusCode: 409, body: '{"code":"Conflict"}'),
      ]);
      final created = await _client(transport).createDocument(
        container: 'identity',
        partitionKey: 'identity',
        document: {'id': 'b', 'naturalKey': 'wisa:1'},
      );
      expect(created, isFalse);
    });

    test('upsertDocument sets the is-upsert header', () async {
      final transport =
          _FakeTransport([const CosmosResponse(statusCode: 200, body: '{}')]);
      await _client(transport).upsertDocument(
        container: 'settings',
        partitionKey: 'settings',
        document: {'id': 'settings'},
      );
      expect(transport.requests.single.headers['x-ms-documentdb-is-upsert'],
          'true');
    });

    test('a point read surfaces the _etag from the body', () async {
      final transport = _FakeTransport([
        _ok({'id': 'settings', '_etag': '"abc"'}),
      ]);
      final doc = await _client(transport).readDocument(
        container: 'settings',
        id: 'settings',
        partitionKey: 'settings',
      );
      expect(doc!['_etag'], '"abc"');
    });

    test('a point read falls back to the etag response header', () async {
      final transport = _FakeTransport([
        const CosmosResponse(
          statusCode: 200,
          headers: {'etag': '"hdr"'},
          body: '{"id":"settings"}',
        ),
      ]);
      final doc = await _client(transport).readDocument(
        container: 'settings',
        id: 'settings',
        partitionKey: 'settings',
      );
      expect(doc!['_etag'], '"hdr"');
    });

    test('a conditioned upsert sends If-Match and returns the new etag',
        () async {
      final transport = _FakeTransport([
        const CosmosResponse(
          statusCode: 200,
          headers: {'etag': '"v2"'},
          body: '{"id":"q"}',
        ),
      ]);
      final outcome = await _client(transport).upsertDocument(
        container: 'passwordQueue',
        partitionKey: 'queue',
        document: {'id': 'q'},
        ifMatch: '"v1"',
      );
      expect(outcome.applied, isTrue);
      expect(outcome.etag, '"v2"');
      expect(transport.requests.single.headers['If-Match'], '"v1"');
    });

    test('a stale conditioned upsert (412) yields WriteOutcome.stale, no throw',
        () async {
      final transport = _FakeTransport([
        const CosmosResponse(
          statusCode: 412,
          body: '{"code":"PreconditionFailed"}',
        ),
      ]);
      final outcome = await _client(transport).upsertDocument(
        container: 'passwordQueue',
        partitionKey: 'queue',
        document: {'id': 'q'},
        ifMatch: '"stale"',
      );
      expect(outcome.applied, isFalse);
      expect(outcome.stale, isTrue);
    });

    test('an unconditioned upsert omits If-Match and is always applied',
        () async {
      final transport =
          _FakeTransport([const CosmosResponse(statusCode: 200, body: '{}')]);
      final outcome = await _client(transport).upsertDocument(
        container: 'settings',
        partitionKey: 'settings',
        document: {'id': 'settings'},
      );
      expect(outcome.applied, isTrue);
      expect(
          transport.requests.single.headers.containsKey('If-Match'), isFalse);
    });

    test('a 412 without an If-Match still throws (unexpected precondition)',
        () async {
      // A 412 with no conditioned write is not the modelled stale outcome — it
      // is an unexpected error and must surface, not be swallowed.
      final transport = _FakeTransport([
        const CosmosResponse(statusCode: 412, body: '{"code":"X"}'),
      ]);
      await expectLater(
        _client(transport).upsertDocument(
          container: 'settings',
          partitionKey: 'settings',
          document: {'id': 'settings'},
        ),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 412)),
      );
    });

    test('deleteDocument tolerates a 404 as already-gone', () async {
      final transport = _FakeTransport([const CosmosResponse(statusCode: 404)]);
      await _client(transport).deleteDocument(
        container: 'identity',
        id: 'a',
        partitionKey: 'identity',
      );
      expect(transport.requests.single.method, 'DELETE');
    });

    test('a query posts application/query+json with bound parameters',
        () async {
      final transport = _FakeTransport([
        _ok({
          'Documents': [
            {'naturalKey': 'wisa:1', 'personId': 'p1'},
          ],
        }),
      ]);
      final rows = await _client(transport).queryDocuments(
        container: 'identity',
        partitionKey: 'identity',
        query: 'SELECT c.naturalKey FROM c WHERE ARRAY_CONTAINS(@keys, '
            'c.naturalKey)',
        parameters: {
          '@keys': ['wisa:1']
        },
      );

      expect(rows, [
        {'naturalKey': 'wisa:1', 'personId': 'p1'}
      ]);
      final req = transport.requests.single;
      expect(req.headers['Content-Type'], 'application/query+json');
      expect(req.headers['x-ms-documentdb-isquery'], 'true');
      expect(req.headers['x-ms-max-item-count'], '-1');
      final body = jsonDecode(req.body!) as Map<String, dynamic>;
      expect(body['parameters'], [
        {
          'name': '@keys',
          'value': ['wisa:1'],
        }
      ]);
    });

    test('a query follows x-ms-continuation across pages', () async {
      final transport = _FakeTransport([
        CosmosResponse(
          statusCode: 200,
          headers: const {'x-ms-continuation': 'PAGE2'},
          body: jsonEncode({
            'Documents': [
              {'naturalKey': 'a'},
            ],
          }),
        ),
        _ok({
          'Documents': [
            {'naturalKey': 'b'},
          ],
        }),
      ]);

      final rows = await _client(transport).queryDocuments(
        container: 'identity',
        partitionKey: 'identity',
        query: 'SELECT c.naturalKey FROM c',
      );

      expect(rows.map((r) => r['naturalKey']), ['a', 'b']);
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].headers.containsKey('x-ms-continuation'),
          isFalse);
      expect(transport.requests[1].headers['x-ms-continuation'], 'PAGE2');
    });

    test(
        'ensureContainer on a present container reads metadata and does not '
        'create it', () async {
      final transport = _FakeTransport([
        _ok({'id': 'decisions'})
      ]);
      final created = await _client(transport)
          .ensureContainer(container: 'decisions', partitionKeyPath: '/pk');

      expect(created, isFalse);
      final req = transport.requests.single;
      expect(req.method, 'GET');
      expect(
          req.url.toString(), endsWith('/dbs/accountmanager/colls/decisions'));
    });

    test('ensureContainer creates the container when the metadata read 404s',
        () async {
      final transport = _FakeTransport([
        const CosmosResponse(statusCode: 404),
        const CosmosResponse(statusCode: 201, body: '{"id":"decisions"}'),
      ]);
      final created = await _client(transport)
          .ensureContainer(container: 'decisions', partitionKeyPath: '/pk');

      expect(created, isTrue);
      expect(transport.requests, hasLength(2));
      final create = transport.requests[1];
      expect(create.method, 'POST');
      expect(create.url.toString(), endsWith('/dbs/accountmanager/colls'));
      expect(jsonDecode(create.body!), {
        'id': 'decisions',
        'partitionKey': {
          'paths': ['/pk'],
          'kind': 'Hash',
          'version': 2,
        },
      });
    });

    test('ensureContainer treats a create 409 as already-created (concurrent)',
        () async {
      final transport = _FakeTransport([
        const CosmosResponse(statusCode: 404),
        const CosmosResponse(statusCode: 409, body: '{"code":"Conflict"}'),
      ]);
      final created = await _client(transport)
          .ensureContainer(container: 'decisions', partitionKeyPath: '/pk');
      expect(created, isFalse);
    });

    test('ensureContainer surfaces a create 403 (identity cannot provision)',
        () async {
      // The honest failure mode: on an AAD-only account whose identity may not
      // create containers, a genuinely missing container surfaces loudly rather
      // than as a later silent item-write 404 (#150).
      final transport = _FakeTransport([
        const CosmosResponse(statusCode: 404),
        const CosmosResponse(
          statusCode: 403,
          body: '{"code":"Forbidden","message":"no container-create right"}',
        ),
      ]);
      await expectLater(
        _client(transport)
            .ensureContainer(container: 'decisions', partitionKeyPath: '/pk'),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('a non-2xx (other than 404/409) throws CosmosException', () async {
      final transport = _FakeTransport([
        const CosmosResponse(
          statusCode: 403,
          body: '{"code":"Forbidden","message":"no data-plane role"}',
        ),
      ]);

      await expectLater(
        _client(transport).readDocument(
          container: 'settings',
          id: 'settings',
          partitionKey: 'settings',
        ),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.code, 'code', 'Forbidden')
            .having((e) => e.message, 'message', 'no data-plane role')),
      );
    });
  });

  group('HttpCosmosClient 429 throttling (#196)', () {
    test(
        'a throttled write is retried and succeeds — the 429 never reaches the '
        'caller', () async {
      // The bug: a single 429 during the persist burst became a CosmosException
      // that unwound writeMaterialized and left the shared containers half
      // written. Cosmos is only asking us to slow down.
      final transport = _FakeTransport([
        _throttled(retryAfterMs: 400),
        _throttled(retryAfterMs: 400),
        _ok({'id': 'a1', '_etag': 'e9'}),
      ]);
      final slept = <Duration>[];

      final outcome =
          await _retryingClient(transport, slept: slept).upsertDocument(
        container: 'linkedAccounts',
        document: const {'id': 'a1'},
        partitionKey: '1',
      );

      expect(outcome.applied, isTrue);
      expect(outcome.etag, 'e9');
      expect(transport.requests, hasLength(3),
          reason: 'two throttled attempts, then the write that landed');
      expect(slept, hasLength(2));
    });

    test('the wait honours x-ms-retry-after-ms as a floor, jittered beyond it',
        () async {
      // Cosmos says exactly how long to wait; the client must not retry sooner.
      // The jitter (pinned to its maximum draw here) is added on top so a burst
      // of throttled writes does not re-converge on the same instant.
      final transport = _FakeTransport([
        _throttled(retryAfterMs: 800),
        _ok({'id': 'a1'}),
      ]);
      final slept = <Duration>[];

      await _retryingClient(transport, slept: slept, roll: 1.0).upsertDocument(
        container: 'linkedAccounts',
        document: const {'id': 'a1'},
        partitionKey: '1',
      );

      // The server hint (800 ms) beats the first exponential step (250 ms), and
      // the default 0.5 jitter fraction at a full draw adds half of it.
      expect(slept.single, const Duration(milliseconds: 1200));
    });

    test('with no server hint the backoff grows exponentially, capped',
        () async {
      final transport = _FakeTransport([
        for (var i = 0; i < 6; i++) _throttled(),
        _ok({'id': 'a1'}),
      ]);
      final slept = <Duration>[];

      await _retryingClient(
        transport,
        slept: slept,
        retry: const CosmosRetryPolicy(
          baseDelay: Duration(milliseconds: 100),
          maxDelay: Duration(milliseconds: 800),
        ),
      ).upsertDocument(
        container: 'linkedAccounts',
        document: const {'id': 'a1'},
        partitionKey: '1',
      );

      expect(
          slept.map((d) => d.inMilliseconds), [100, 200, 400, 800, 800, 800]);
    });

    test(
        'a request that stays throttled surfaces the 429 once attempts run out',
        () async {
      // Bounded, not infinite: if the account genuinely cannot absorb the write,
      // the operator must still be told rather than the sync hanging forever.
      final transport = _FakeTransport([
        for (var i = 0; i < 3; i++) _throttled(retryAfterMs: 100),
      ]);
      final slept = <Duration>[];

      await expectLater(
        _retryingClient(
          transport,
          slept: slept,
          retry: const CosmosRetryPolicy(maxAttempts: 3),
        ).upsertDocument(
          container: 'linkedAccounts',
          document: const {'id': 'a1'},
          partitionKey: '1',
        ),
        throwsA(isA<CosmosException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.code, 'code', 'TooManyRequests')),
      );
      expect(transport.requests, hasLength(3));
      expect(slept, hasLength(2), reason: 'no sleep after the last attempt');
    });

    test('a retry rebuilds its headers with a fresh token and date', () async {
      // A retry can be seconds after the first attempt; replaying the original
      // x-ms-date / bearer token would eventually be rejected outright.
      final tokens = _CountingTokenProvider();
      final transport = _FakeTransport([
        _throttled(retryAfterMs: 50),
        _ok({'id': 'a1'}),
      ]);

      await _retryingClient(transport, slept: [], tokens: tokens)
          .upsertDocument(
        container: 'linkedAccounts',
        document: const {'id': 'a1'},
        partitionKey: '1',
      );

      expect(tokens.calls, 2);
      expect(transport.requests.first.headers['authorization'],
          isNot(transport.requests.last.headers['authorization']));
      expect(transport.requests.last.headers['authorization'],
          contains('token-2'));
      // …and it is still the same request otherwise.
      expect(transport.requests.last.body, transport.requests.first.body);
      expect(
          transport.requests.last.headers['x-ms-documentdb-is-upsert'], 'true');
    });

    test('a throttled read is retried too, and a 404 still reads as null',
        () async {
      final transport = _FakeTransport([
        _throttled(retryAfterMs: 50),
        const CosmosResponse(statusCode: 404),
      ]);

      final doc = await _retryingClient(transport, slept: []).readDocument(
        container: 'settings',
        id: 'settings',
        partitionKey: 'settings',
      );

      expect(doc, isNull);
      expect(transport.requests, hasLength(2));
    });

    test('throttling narrows the shared write fan-out and reports it once',
        () async {
      // The adaptive half of the fix: retrying alone keeps offering the same
      // load to an account that already said "too much".
      final reported = <String>[];
      final governor = CosmosThrottleGovernor(
        onReport: reported.add,
        recoverAfter: 2,
      );
      final transport = _FakeTransport([
        _throttled(retryAfterMs: 100),
        _throttled(retryAfterMs: 100),
        _ok({'id': 'a1'}),
      ]);

      await _retryingClient(transport, slept: [], governor: governor)
          .upsertDocument(
        container: 'linkedAccounts',
        document: const {'id': 'a1'},
        partitionKey: '1',
      );

      expect(governor.throttles, 2);
      expect(governor.concurrency, 6,
          reason: '24 halved twice while the account was throttling');
      // One line for the burst, not one per 429 (a real burst is thousands).
      // It is reported into the operator's Log panel, so it is Dutch (#266).
      expect(reported, hasLength(1));
      expect(reported.single, contains('Cosmos beperkt het tempo (429)'));
      expect(
        reported.single,
        contains('het aantal gelijktijdige schrijfacties verlaagd naar 12'),
        reason: 'the operator sees the persist slow down, not silence',
      );
      expect(reported.single, isNot(contains('throttling')));
    });
  });

  group('CosmosRetryPolicy (#196)', () {
    const policy = CosmosRetryPolicy(
      baseDelay: Duration(milliseconds: 200),
      maxDelay: Duration(seconds: 2),
      jitterFraction: 0.5,
    );

    test('doubles per attempt and never exceeds maxDelay', () {
      List<int> curve(double roll) => [
            for (var a = 1; a <= 6; a++)
              policy.delayFor(attempt: a, roll: roll).inMilliseconds,
          ];
      expect(curve(0.0), [200, 400, 800, 1600, 2000, 2000]);
    });

    test('jitter only ever adds, bounded by the jitter fraction', () {
      final base = policy.delayFor(attempt: 3, roll: 0.0).inMilliseconds;
      final jittered = policy.delayFor(attempt: 3, roll: 1.0).inMilliseconds;
      expect(base, 800);
      expect(jittered, 1200);
      expect(policy.delayFor(attempt: 3, roll: 0.5).inMilliseconds,
          inInclusiveRange(base, jittered));
    });

    test("the server's retry-after wins when it is longer than the backoff",
        () {
      expect(
        policy
            .delayFor(
              attempt: 1,
              roll: 0.0,
              retryAfter: const Duration(seconds: 5),
            )
            .inMilliseconds,
        5000,
        reason: 'the account knows its own recovery better than we do',
      );
      // …but a short hint never shortens our own backoff.
      expect(
        policy
            .delayFor(
              attempt: 4,
              roll: 0.0,
              retryAfter: const Duration(milliseconds: 10),
            )
            .inMilliseconds,
        1600,
      );
    });
  });

  group('CosmosThrottleGovernor (#196)', () {
    test('halves on throttle down to a floor that still makes progress', () {
      final g = CosmosThrottleGovernor(maxConcurrency: 24, minConcurrency: 2);
      expect(g.concurrency, 24);
      for (var i = 0; i < 10; i++) {
        g.recordThrottle(attempt: 1, wait: Duration.zero);
      }
      expect(g.concurrency, 2, reason: 'never zero — the write must continue');
      expect(g.isNarrowed, isTrue);
    });

    test('recovers slowly, one step per run of clean requests', () {
      final g = CosmosThrottleGovernor(
        maxConcurrency: 8,
        minConcurrency: 2,
        recoverAfter: 3,
      );
      g.recordThrottle(attempt: 1, wait: Duration.zero); // 8 → 4
      expect(g.concurrency, 4);

      for (var i = 0; i < 2; i++) {
        g.recordSuccess();
      }
      expect(g.concurrency, 4,
          reason: 'a couple of clean writes is not enough');
      g.recordSuccess();
      expect(g.concurrency, 5);

      for (var i = 0; i < 9; i++) {
        g.recordSuccess();
      }
      expect(g.concurrency, 8);
      expect(g.isNarrowed, isFalse);
      // Widening past the ceiling would re-create the stampede.
      g.recordSuccess();
      expect(g.concurrency, 8);
    });

    test('reports the start of a burst, the recovery, and exhaustion', () {
      final reported = <String>[];
      final g = CosmosThrottleGovernor(
        maxConcurrency: 4,
        minConcurrency: 2,
        recoverAfter: 1,
        onReport: reported.add,
      );

      g.recordThrottle(attempt: 1, wait: const Duration(milliseconds: 250));
      g.recordThrottle(attempt: 2, wait: const Duration(milliseconds: 500));
      expect(reported, hasLength(1), reason: 'one line per burst, not per 429');

      // 2 → 3 is still narrowed (silent); only the return to the full width is
      // worth a line.
      g.recordSuccess();
      expect(reported, hasLength(1));
      g.recordSuccess();
      expect(reported, hasLength(2));
      // All three reports go into the operator's Log panel, so all three are
      // Dutch (#266).
      expect(reported.last, contains('Cosmos beperkt het tempo niet meer'));

      g.recordThrottle(attempt: 8); // out of attempts
      expect(
        reported.last,
        'Cosmos beperkt het tempo nog steeds na 8 pogingen — deze aanvraag '
        'wordt opgegeven.',
      );
      for (final english in <String>['throttling', 'eased', 'giving up']) {
        expect(
          reported.where((m) => m.contains(english)),
          isEmpty,
          reason: english,
        );
      }
    });
  });
}
