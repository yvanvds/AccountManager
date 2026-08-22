import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  GraphClient clientWith(FakeGraphTransport transport) => GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('TEST-TOKEN'),
      );

  group('GraphClient.uri', () {
    test('joins base + path without dropping the version segment', () {
      final client = clientWith(FakeGraphTransport.constant(noContent()));
      expect(
        client.uri('users').toString(),
        'https://graph.microsoft.com/v1.0/users',
      );
    });

    test('attaches query parameters, percent-encoding values', () {
      final client = clientWith(FakeGraphTransport.constant(noContent()));
      final uri = client.uri(
        'users',
        query: {
          r'$select': 'id,displayName',
          r'$filter': "companyName eq 'GBS'",
        },
      );
      expect(uri.queryParameters[r'$select'], 'id,displayName');
      expect(uri.queryParameters[r'$filter'], "companyName eq 'GBS'");
    });
  });

  group('authentication', () {
    test('sets a Bearer token from the auth provider on every request',
        () async {
      final transport =
          FakeGraphTransport.constant(jsonOk({'value': <dynamic>[]}));
      final client = clientWith(transport);
      await client.getJson(client.uri('users'));
      expect(transport.last.headers['Authorization'], 'Bearer TEST-TOKEN');
      expect(transport.last.headers['Accept'], 'application/json');
    });

    test('non-2xx ⇒ GraphException carrying Graph error code/message',
        () async {
      final transport = FakeGraphTransport.constant(
        graphError(
          403,
          'Authorization_RequestDenied',
          'Insufficient privileges',
        ),
      );
      final client = clientWith(transport);
      expect(
        () => client.getJson(client.uri('users')),
        throwsA(
          isA<GraphException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'Authorization_RequestDenied')
              .having((e) => e.message, 'message', 'Insufficient privileges'),
        ),
      );
    });
  });

  group('failure logging (#229)', () {
    /// The Graph reply the operator's stale token drew.
    GraphResponse rejectedToken() => graphError(
          400,
          'Request_UnsupportedQuery',
          'DeltaLink older than 30 days is not supported.',
        );

    test('an opaque resume token never reaches the log, at any severity',
        () async {
      // The ~2.5 KB `$deltatoken` the failing URL carries is live tenant state
      // in a line the operator pastes into an issue.
      const secret = 'SUPER-SECRET-RESUME-TOKEN';
      final transport = FakeGraphTransport.constant(rejectedToken());
      final log = RecordingLog();
      final client = GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
        log: log,
      );

      await expectLater(
        client.getJson(
          client.uri('users/delta', query: {r'$deltatoken': secret}),
        ),
        throwsA(isA<GraphException>()),
      );

      expect(log.errors, hasLength(1));
      expect(log.errors.single, isNot(contains(secret)));
      expect(log.errors.single, contains('<redacted>'));
      // The rest of the URL — the part that says what was being asked — is
      // untouched, and so is Graph's own explanation.
      expect(log.errors.single, contains('users/delta'));
      expect(log.errors.single, contains('DeltaLink older than 30 days'));
    });

    test(
        'a paging \$skiptoken is redacted too, while \$deltatoken=latest stays'
        ' readable', () async {
      final transport = FakeGraphTransport.constant(
        graphError(400, 'Request_UnsupportedQuery', 'Bad page.'),
      );
      final log = RecordingLog();
      final client = GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
        log: log,
      );

      await expectLater(
        client.getJson(client.uri('users', query: {r'$skiptoken': 'PAGE-XYZ'})),
        throwsA(isA<GraphException>()),
      );
      // `latest` is Graph's own sentinel, not a secret — and it is what tells a
      // primed full read apart from a resume in the log.
      await expectLater(
        client.getJson(
          client.uri('users/delta', query: {r'$deltatoken': 'latest'}),
        ),
        throwsA(isA<GraphException>()),
      );

      expect(log.errors.first, isNot(contains('PAGE-XYZ')));
      expect(log.errors.first, contains('<redacted>'));
      expect(log.errors.last, contains('latest'));
      expect(log.errors.last, isNot(contains('<redacted>')));
    });

    test(
        'a failure the caller declared it expects is logged as a detail, not an '
        'error — and is still thrown', () async {
      final transport = FakeGraphTransport.constant(rejectedToken());
      final log = RecordingLog();
      final client = GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
        log: log,
      );

      await expectLater(
        client.getDelta(
          client.uri('users/delta', query: {r'$deltatoken': 'DEADTOKEN'}),
          expected: (e) => e.isRejectedDeltaToken,
        ),
        throwsA(isA<GraphException>()),
      );

      expect(log.errors, isEmpty,
          reason: 'the caller recovers — nothing here for the operator to act '
              'on');
      // The clause this client appends is Dutch since #266; the Graph body it
      // is appended to is quoted exactly as Graph sent it.
      expect(
        log.messages.single,
        contains('(afgehandeld — de synchronisatie herstelt hiervan)'),
      );
      expect(log.messages.single, isNot(contains('handled —')));
      expect(log.messages.single, contains('DeltaLink older than 30 days'));
      expect(log.messages.single, isNot(contains('DEADTOKEN')));
    });

    test('a failure outside the declared shape stays an error', () async {
      // Same status and code, a different cause: a genuinely malformed query
      // must stay loud even on the read that comes prepared for a dead token.
      final transport = FakeGraphTransport.constant(graphError(
        400,
        'Request_UnsupportedQuery',
        "Unsupported or invalid query filter clause specified for property "
            "'jobTitle'.",
      ));
      final log = RecordingLog();
      final client = GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
        log: log,
      );

      await expectLater(
        client.getDelta(
          client.uri('users/delta', query: {r'$deltatoken': 'DEADTOKEN'}),
          expected: (e) => e.isRejectedDeltaToken,
        ),
        throwsA(isA<GraphException>()),
      );

      expect(log.messages, isEmpty);
      expect(log.errors.single, contains('jobTitle'));
    });
  });

  group('pagination', () {
    test('getCollection follows @odata.nextLink across all pages', () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.queryParameters[r'$skiptoken'] == 'PAGE2') {
          return jsonOk(readFixture('users_page2.json'));
        }
        return jsonOk(readFixture('users_page1.json'));
      });
      final client = clientWith(transport);
      final rows = await client.getCollection(client.uri('users'));
      expect(rows, hasLength(3));
      expect(transport.requests, hasLength(2));
      // Page-1 headers are forwarded to the next page too.
    });

    test('getCollection forwards headers on every page', () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.queryParameters[r'$skiptoken'] == 'PAGE2') {
          return jsonOk(readFixture('users_page2.json'));
        }
        return jsonOk(readFixture('users_page1.json'));
      });
      final client = clientWith(transport);
      await client.getCollection(
        client.uri('users'),
        headers: const {'ConsistencyLevel': 'eventual'},
      );
      expect(
        transport.requests.every(
          (r) => r.headers['ConsistencyLevel'] == 'eventual',
        ),
        isTrue,
      );
    });
  });

  group('delta', () {
    test('getDelta gathers all pages and extracts the \$deltatoken', () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.queryParameters[r'$skiptoken'] == 'DELTA2') {
          return jsonOk(readFixture('users_delta_final.json'));
        }
        return jsonOk(readFixture('users_delta_page1.json'));
      });
      final client = clientWith(transport);
      final result = await client.getDelta(client.uri('users/delta'));
      expect(result.values, hasLength(4)); // 1 + (2 changed + 1 removed)
      expect(result.deltaToken, 'NEWDELTA456');
    });

    test(
        'a token carrying a literal "+" survives the deltaLink round trip '
        '(#213)', () async {
      // Graph tokens are opaque and are not form-encoded: a `+` in a deltaLink
      // is a `+`. Reading it back with Uri.queryParameters form-decodes it to a
      // space, and re-sending the mangled token earns the same misleading
      // "DeltaLink older than 30 days is not supported" 400 as a genuinely
      // expired one.
      const token = 'aB+cd/ef+gh';
      final transport = FakeGraphTransport((req) => jsonOk({
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/users/delta'
                '?\$deltatoken=$token',
            'value': const <Object>[],
          }));
      final client = clientWith(transport);

      final result = await client.getDelta(client.uri('users/delta'));

      expect(result.deltaToken, token);
      expect(result.deltaToken, isNot(contains(' ')));

      // …and the token that comes back is the one the next resume sends.
      await client.getDelta(
        client.uri('users/delta', query: {r'$deltatoken': result.deltaToken!}),
      );
      expect(transport.last.url.queryParameters[r'$deltatoken'], token);
    });
  });
}
