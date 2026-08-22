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

  group('progress logging (#177)', () {
    test('logs one line for every 100 accounts pulled while paging', () async {
      // 250 users across three pages of 100 / 100 / 50.
      final transport = FakeGraphTransport((req) {
        switch (req.url.queryParameters[r'$skiptoken']) {
          case 'P1':
            return usersPage(startIndex: 100, count: 100, nextSkipToken: 'P2');
          case 'P2':
            return usersPage(startIndex: 200, count: 50);
          default:
            return usersPage(startIndex: 0, count: 100, nextSkipToken: 'P1');
        }
      });
      final log = RecordingLog();
      final users = UserManager(clientWith(transport), log: log);

      final result = await users.load('GBS');

      expect(result, hasLength(250));
      // A line at each full hundred crossed (250 → 100 and 200), not the tail.
      expect(
        log.messages.where((m) => m.contains('accounts opgehaald')).toList(),
        ['Azure: 100 accounts opgehaald…', 'Azure: 200 accounts opgehaald…'],
      );
    });

    test('emits no progress line below the first 100 threshold', () async {
      final transport =
          FakeGraphTransport((_) => usersPage(startIndex: 0, count: 3));
      final log = RecordingLog();
      final users = UserManager(clientWith(transport), log: log);

      await users.load('GBS');

      expect(
        log.messages.where((m) => m.contains('accounts opgehaald')),
        isEmpty,
      );
    });

    test('loadClientFiltered logs progress on the same cadence', () async {
      final transport = FakeGraphTransport((req) {
        switch (req.url.queryParameters[r'$skiptoken']) {
          case 'P1':
            return usersPage(startIndex: 100, count: 50);
          default:
            return usersPage(startIndex: 0, count: 100, nextSkipToken: 'P1');
        }
      });
      final log = RecordingLog();
      final users = UserManager(clientWith(transport), log: log);

      await users.loadClientFiltered('GBS');

      expect(
        log.messages.where((m) => m.contains('accounts opgehaald')).toList(),
        ['Azure: 100 accounts opgehaald…'],
      );
    });

    test('no progress lines are emitted when no log sink is attached',
        () async {
      final transport =
          FakeGraphTransport((_) => usersPage(startIndex: 0, count: 100));
      final users = UserManager(clientWith(transport));
      // Must not throw despite a page crossing the 100 threshold.
      expect(await users.load('GBS'), hasLength(100));
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

  group('setPassword (#180)', () {
    test('PATCHes a passwordProfile onto the user', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final users = UserManager(clientWith(transport));
      await users.setPassword('id-1', 'Bacoxy7!');
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      final profile = body['passwordProfile'] as Map<String, dynamic>;
      expect(transport.last.method, 'PATCH');
      expect(transport.last.url.path, contains('users/id-1'));
      expect(profile['password'], 'Bacoxy7!');
      // Defaults to forcing a change on next sign-in, mirroring the legacy reset.
      expect(profile['forceChangePasswordNextSignIn'], isTrue);
    });

    test('honours forceChangePasswordNextSignIn: false', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final users = UserManager(clientWith(transport));
      await users.setPassword(
        'jane.doe@student.school.example',
        'Bacoxy7!',
        forceChangePasswordNextSignIn: false,
      );
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      final profile = body['passwordProfile'] as Map<String, dynamic>;
      expect(profile['forceChangePasswordNextSignIn'], isFalse);
      // The UPN is percent-encoded into the path segment.
      expect(
        Uri.decodeComponent(transport.last.url.pathSegments.last),
        'jane.doe@student.school.example',
      );
    });

    test('a refused write (403) names the permission and role gap (#216)',
        () async {
      // What the tenant actually answered: `User.ReadWrite.All` does not
      // authorise a passwordProfile write, so Graph denies the PATCH. The bare
      // GraphException told the operator nothing actionable.
      final transport = FakeGraphTransport.constant(
        graphError(403, 'Authorization_RequestDenied',
            'Insufficient privileges to complete the operation.'),
      );
      final users = UserManager(clientWith(transport));

      final error = await users
          .setPassword('anna.smit@school.example', 'Bacoxy7!')
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<AzurePasswordPermissionException>());
      final refusal = error! as AzurePasswordPermissionException;
      expect(refusal.target, 'anna.smit@school.example');
      expect(refusal.code, 'Authorization_RequestDenied');
      expect(refusal.cause.statusCode, 403);
      expect(refusal.toString(), contains('anna.smit@school.example'));
      expect(
          refusal.toString(), contains('User-PasswordProfile.ReadWrite.All'));
      expect(refusal.toString(), contains('User Administrator'));
    });

    test('any other Graph failure still propagates as a GraphException',
        () async {
      final transport = FakeGraphTransport.constant(
        graphError(400, 'Request_BadRequest', 'password too weak'),
      );
      final users = UserManager(clientWith(transport));
      await expectLater(
        users.setPassword('id-1', 'x'),
        throwsA(isA<GraphException>()),
      );
    });
  });

  group('AzureCredentials scopes (#216)', () {
    test('requests the least-privileged passwordProfile write permission', () {
      final credentials = AzureCredentials(
        clientId: 'c',
        tenantId: 't',
        azureDomain: 'school.example',
        schoolPrefix: 'GBS',
      );
      expect(
        credentials.scopes,
        containsAll(<String>[
          'https://graph.microsoft.com/User.ReadWrite.All',
          'https://graph.microsoft.com/Group.ReadWrite.All',
          'https://graph.microsoft.com/User-PasswordProfile.ReadWrite.All',
        ]),
      );
      // The broad older alternative is deliberately not requested: it grants
      // everything the signed-in operator can do directory-wide.
      expect(
        credentials.scopes,
        isNot(contains('https://graph.microsoft.com/'
            'Directory.AccessAsUser.All')),
      );
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

  group('loadByEmployeeIds (#224)', () {
    /// One Graph `/users` row for a transferred-in student: the employeeId is
    /// ours, the companyName is unset and the department still names the school
    /// they came from — the exact shape [UserManager.load]'s `$filter` misses.
    Map<String, dynamic> transferred(String employeeId) => <String, dynamic>{
          'id': 'az-$employeeId',
          'userPrincipalName': 'alfio.ambre@student.other.example',
          'employeeId': employeeId,
          'displayName': 'Alfio Ambre',
          'department': 'OTHER-3A',
        };

    test('asks Graph for exactly the ids, with the advanced-query header',
        () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final users = UserManager(clientWith(transport));

      await users.loadByEmployeeIds(['W1', 'W2']);

      expect(transport.requests, hasLength(1));
      final req = transport.last;
      expect(req.method, 'GET');
      expect(req.url.path, endsWith('/users'));
      expect(
        req.url.queryParameters[r'$filter'],
        "employeeId in ('W1','W2')",
      );
      expect(req.url.queryParameters[r'$count'], 'true');
      expect(req.headers['ConsistencyLevel'], 'eventual');
      // The pull stays as narrow as the bulk read's (PAIN-2).
      expect(
        req.url.queryParameters[r'$select'],
        'id,userPrincipalName,employeeId,displayName,givenName,surname,'
        'companyName,department,accountEnabled',
      );
    });

    test('returns the accounts the school filter cannot see', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({
          'value': [transferred('W7')],
        }),
      );
      final users = UserManager(clientWith(transport));

      final found = await users.loadByEmployeeIds(['W7']);

      expect(found, hasLength(1));
      expect(found.single.employeeId, 'W7');
      expect(found.single.companyName, isNull);
      expect(found.single.upn, 'alfio.ambre@student.other.example');
    });

    test('chunks a long id list and de-duplicates the result', () async {
      final ids = [for (var i = 0; i < 32; i++) 'W$i'];
      final transport = FakeGraphTransport(
        (_) => jsonOk({
          // Every chunk answers with the same row, so a naive merge would
          // report it three times.
          'value': [transferred('W7')],
        }),
      );
      final users = UserManager(clientWith(transport));

      final found = await users.loadByEmployeeIds(ids);

      expect(transport.requests, hasLength(3), reason: '15 + 15 + 2');
      expect(
        transport.requests.last.url.queryParameters[r'$filter'],
        "employeeId in ('W30','W31')",
      );
      expect(found, hasLength(1));
    });

    test('blank and duplicate ids never reach Graph', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final users = UserManager(clientWith(transport));

      expect(await users.loadByEmployeeIds(const ['', '  ']), isEmpty);
      expect(transport.requests, isEmpty);

      await users.loadByEmployeeIds([' W1 ', 'W1', '']);
      expect(
        transport.last.url.queryParameters[r'$filter'],
        "employeeId in ('W1')",
      );
    });

    test('escapes a single quote in an id', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final users = UserManager(clientWith(transport));

      await users.loadByEmployeeIds(["O'1"]);
      expect(
        transport.last.url.queryParameters[r'$filter'],
        "employeeId in ('O''1')",
      );
    });

    test('findByEmployeeId returns the hit, or null when the tenant has none',
        () async {
      final hit = FakeGraphTransport(
        (_) => jsonOk({
          'value': [transferred('W7')],
        }),
      );
      expect(
        (await UserManager(clientWith(hit)).findByEmployeeId('W7'))?.id,
        'az-W7',
      );

      final miss = FakeGraphTransport((_) => jsonOk({'value': <Object>[]}));
      expect(
        await UserManager(clientWith(miss)).findByEmployeeId('W7'),
        isNull,
      );
    });
  });

  // Every line this manager writes into an [ILog] lands in the app's Log panel,
  // beside the Dutch the app layer writes there (#253/#257/#258), so it is
  // Dutch too (#266). The API and these test names are not.
  group('operator log lines are Dutch (#266)', () {
    test('the bulk read reports what it pulled, for which prefix', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk(readFixture('users_page2.json')),
      );
      final log = RecordingLog();

      await UserManager(clientWith(transport), log: log).load('GBS');

      expect(
          log.messages, contains('Azure: 1 gebruikers opgehaald voor "GBS".'));
      expect(log.messages, isNot(contains(contains('loaded '))));
    });

    test('the client-filtered read says so, in Dutch', () async {
      final transport = FakeGraphTransport(
        (_) => usersPage(startIndex: 0, count: 2),
      );
      final log = RecordingLog();

      await UserManager(clientWith(transport), log: log)
          .loadClientFiltered('GBS');

      expect(
        log.messages,
        contains(contains('gebruikers opgehaald (lokaal gefilterd) voor '
            '"GBS".')),
      );
      expect(log.messages, isNot(contains(contains('client-filtered'))));
    });

    test('a delta walk reports its changed/removed counts in Dutch', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({
          '@odata.deltaLink':
              'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=T',
          'value': const <Object>[],
        }),
      );
      final log = RecordingLog();

      await UserManager(clientWith(transport), log: log).delta('OLD', 'GBS');

      expect(
        log.messages,
        contains('Azure: delta voor "GBS" — 0 gewijzigd, 0 verwijderd.'),
      );
      expect(log.messages, isNot(contains(contains('changed, '))));
    });

    test('the employeeId back-fill lookup reports in Dutch', () async {
      final transport =
          FakeGraphTransport((_) => jsonOk({'value': <Object>[]}));
      final log = RecordingLog();

      await UserManager(clientWith(transport), log: log)
          .loadByEmployeeIds(<String>['W7']);

      expect(
        log.messages,
        contains('Azure: 1 employeeId(s) rechtstreeks opgezocht — '
            '0 bestaand(e) account(s) gevonden.'),
      );
      expect(log.messages, isNot(contains(contains('looked up'))));
    });

    test('the write lines — create, update, delete, reset — are Dutch',
        () async {
      final created = FakeGraphTransport.constant(
        jsonOk({'id': 'new-id', 'userPrincipalName': 'k.l@school.example'}),
      );
      final createLog = RecordingLog();
      await UserManager(clientWith(created), log: createLog).createUser(
        userPrincipalName: 'k.l@school.example',
        displayName: 'K L',
        password: 'Secret123!',
        givenName: 'K',
        surname: 'L',
      );
      expect(
        createLog.messages,
        contains('Azure: gebruiker k.l@school.example aangemaakt.'),
      );

      final patched = FakeGraphTransport.constant(noContent());
      final patchLog = RecordingLog();
      final users = UserManager(clientWith(patched), log: patchLog);
      await users.updateUser('id-1', department: '4A');
      await users.deleteUser('id-1');
      await users.setPassword('id-1', 'Bacoxy7!');
      expect(
        patchLog.messages,
        containsAll(<String>[
          'Azure: gebruiker id-1 bijgewerkt.',
          'Azure: gebruiker id-1 verwijderd.',
          'Azure: wachtwoord van id-1 opnieuw ingesteld.',
        ]),
      );
      // None of the English these five lines used to be survives anywhere.
      for (final english in <String>[
        'created user',
        'updated user',
        'deleted user',
        'reset password',
      ]) {
        expect(
          <String>[...createLog.messages, ...patchLog.messages]
              .where((m) => m.contains(english)),
          isEmpty,
          reason: english,
        );
      }
    });
  });
}
