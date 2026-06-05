import 'dart:convert';

import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  GraphClient clientWith(FakeGraphTransport transport) => GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
      );

  group('load (\$filter + \$select bulk read)', () {
    late FakeGraphTransport transport;
    late UserManager users;

    setUp(() {
      transport = FakeGraphTransport((req) {
        if (req.url.queryParameters[r'$skiptoken'] == 'PAGE2') {
          return jsonOk(readFixture('users_page2.json'));
        }
        return jsonOk(readFixture('users_page1.json'));
      });
      users = UserManager(clientWith(transport));
    });

    test('issues the expected \$filter and \$select query strings', () async {
      await users.load('GBS');
      final first = transport.requests.first;
      expect(first.method, 'GET');
      expect(
        first.url.queryParameters[r'$filter'],
        "companyName eq 'GBS' or startswith(department,'GBS')",
      );
      expect(
        first.url.queryParameters[r'$select'],
        'id,userPrincipalName,employeeId,displayName,givenName,surname,'
        'companyName,department,accountEnabled',
      );
      expect(first.url.queryParameters[r'$count'], 'true');
    });

    test('sends ConsistencyLevel: eventual for the advanced query', () async {
      await users.load('GBS');
      expect(
        transport.requests.first.headers['ConsistencyLevel'],
        'eventual',
      );
    });

    test('follows pagination and maps every page to AzureUser', () async {
      final result = await users.load('GBS');
      expect(result.map((u) => u.upn), [
        'ann.peeters@student.school.example',
        'bram.janssens@student.school.example',
        'carla.maes@school.example',
      ]);
    });

    test('escapes single quotes in the prefix', () async {
      await users.load("O'Brien");
      expect(
        transport.requests.first.url.queryParameters[r'$filter'],
        "companyName eq 'O''Brien' or startswith(department,'O''Brien')",
      );
    });
  });

  group('delta', () {
    test(
        'uses the supplied token, filters by prefix, captures removals + token',
        () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.queryParameters[r'$skiptoken'] == 'DELTA2') {
          return jsonOk(readFixture('users_delta_final.json'));
        }
        return jsonOk(readFixture('users_delta_page1.json'));
      });
      final users = UserManager(clientWith(transport));

      final delta = await users.delta('OLDTOKEN', 'GBS');

      expect(
        transport.requests.first.url.queryParameters[r'$deltatoken'],
        'OLDTOKEN',
      );
      // bram (GBS) + dirk (GBS) are in prefix; evy (OTHER) is filtered out.
      expect(
        delta.changed.map((u) => u.upn),
        containsAll(<String>[
          'bram.janssens@student.school.example',
          'dirk.nieuw@student.school.example',
        ]),
      );
      expect(
        delta.changed.any((u) => u.upn.endsWith('@other.example')),
        isFalse,
      );
      expect(delta.removedIds, ['00000000-0000-0000-0000-000000000001']);
      expect(delta.deltaToken, 'NEWDELTA456');
    });

    test('latestDeltaToken primes a token via \$deltatoken=latest', () async {
      final transport = FakeGraphTransport((req) {
        expect(req.url.queryParameters[r'$deltatoken'], 'latest');
        return jsonOk(readFixture('delta_latest.json'));
      });
      final users = UserManager(clientWith(transport));
      expect(await users.latestDeltaToken(), 'PRIMEDTOKEN123');
    });
  });

  group('getUser', () {
    test('returns the parsed user', () async {
      final transport =
          FakeGraphTransport.constant(jsonOk(readFixture('user_single.json')));
      final users = UserManager(clientWith(transport));
      final user = await users.getUser('ann.peeters@student.school.example');
      expect(user?.employeeId, 'W1001');
    });

    test('returns null on 404', () async {
      final transport = FakeGraphTransport.constant(
        graphError(404, 'Request_ResourceNotFound', 'not found'),
      );
      final users = UserManager(clientWith(transport));
      expect(await users.getUser('ghost@school.example'), isNull);
    });
  });

  group('createUser', () {
    test('POSTs the Graph body with passwordProfile and default nickname',
        () async {
      final transport = FakeGraphTransport.constant(
        jsonOk({
          'id': 'new-id',
          'userPrincipalName': 'k.l@student.school.example',
        }),
      );
      final users = UserManager(clientWith(transport));

      final created = await users.createUser(
        userPrincipalName: 'k.l@student.school.example',
        displayName: 'K L',
        password: 'Secret123!',
        givenName: 'K',
        surname: 'L',
        employeeId: 'W2',
        department: '3A',
        companyName: 'GBS',
        jobTitle: 'LeerlingSec',
      );

      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      expect(transport.last.method, 'POST');
      expect(body['userPrincipalName'], 'k.l@student.school.example');
      expect(body['mailNickname'], 'k.l');
      expect(body['accountEnabled'], true);
      expect(body['employeeId'], 'W2');
      expect(body['jobTitle'], 'LeerlingSec');
      expect(
        (body['passwordProfile'] as Map)['password'],
        'Secret123!',
      );
      expect(
        (body['passwordProfile'] as Map)['forceChangePasswordNextSignIn'],
        false,
      );
      expect(created.id, 'new-id');
    });
  });

  group('updateUser', () {
    test('PATCHes only the provided fields', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final users = UserManager(clientWith(transport));
      await users.updateUser('id-1', department: '4A', employeeId: 'W9');
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      expect(transport.last.method, 'PATCH');
      expect(body.keys, containsAll(<String>['department', 'employeeId']));
      expect(body.containsKey('displayName'), isFalse);
    });

    test('no-op when nothing to change (no request issued)', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final users = UserManager(clientWith(transport));
      await users.updateUser('id-1');
      expect(transport.requests, isEmpty);
    });
  });

  group('deleteUser', () {
    test('issues DELETE on the user resource', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final users = UserManager(clientWith(transport));
      await users.deleteUser('ann.peeters@student.school.example');
      expect(transport.last.method, 'DELETE');
      // The UPN is percent-encoded into the path segment.
      expect(transport.last.url.path, contains('ann.peeters'));
      expect(
        Uri.decodeComponent(transport.last.url.pathSegments.last),
        'ann.peeters@student.school.example',
      );
    });
  });

  group('createPrincipalName', () {
    test('strips accents, lowercases, suffixes on collision', () async {
      var calls = 0;
      final transport = FakeGraphTransport((req) {
        calls++;
        // First candidate exists, second is free.
        if (calls == 1) return jsonOk(readFixture('user_single.json'));
        return graphError(404, 'Request_ResourceNotFound', 'not found');
      });
      final users = UserManager(clientWith(transport));

      final upn = await users.createPrincipalName(
        'Désiré',
        'Müller',
        'school.example',
        isStudent: true,
      );
      expect(upn, 'desire.muller2@student.school.example');
    });

    test('staff land under the bare domain', () async {
      final transport = FakeGraphTransport.constant(
        graphError(404, 'Request_ResourceNotFound', 'not found'),
      );
      final users = UserManager(clientWith(transport));
      final upn = await users.createPrincipalName(
        'Jan',
        'Peeters',
        'school.example',
        isStudent: false,
      );
      expect(upn, 'jan.peeters@school.example');
    });
  });
}
