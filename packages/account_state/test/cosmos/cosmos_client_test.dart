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
}
