import 'dart:convert';

import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  GraphClient clientWith(FakeGraphTransport transport) => GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
      );

  /// A client that writes into the same sink the manager does — the wiring
  /// `AzureConnector` builds. Needed wherever a test asserts on what a *failed*
  /// Graph reply put in the log, since that line comes from the client (#229).
  GraphClient loggingClientWith(
    FakeGraphTransport transport,
    RecordingLog log,
  ) =>
      GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
        log: log,
      );

  group('listGroups', () {
    late FakeGraphTransport transport;
    late GroupManager groups;

    setUp(() {
      transport = FakeGraphTransport((req) {
        if (req.url.path.contains('/members')) {
          return jsonOk(readFixture('group_members_3a.json'));
        }
        return jsonOk(readFixture('groups.json'));
      });
      groups = GroupManager(clientWith(transport));
    });

    test('filters by startswith(displayName, prefix) with \$select', () async {
      await groups.listGroups('GBS');
      final groupCall = transport.requests.first;
      expect(
        groupCall.url.queryParameters[r'$filter'],
        "startswith(displayName,'GBS')",
      );
      expect(
        groupCall.url.queryParameters[r'$select'],
        'id,displayName,securityEnabled,mailEnabled,groupTypes,mail,'
        'mailNickname',
      );
      expect(groupCall.headers['ConsistencyLevel'], 'eventual');
    });

    test('loads member ids for each group', () async {
      final result = await groups.listGroups('GBS');
      expect(result, hasLength(2));
      expect(result.first.displayName, 'GBS-3A');
      expect(result.first.memberIds, [
        '00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000002',
      ]);
    });
  });

  group('progress logging (#177)', () {
    GraphResponse routeWithGroups(GraphRequest req, int total) {
      if (req.url.path.contains('/members')) {
        return jsonOk({'value': const <Object>[]});
      }
      return jsonOk({
        'value': [
          for (var i = 0; i < total; i++)
            {'id': 'g$i', 'displayName': 'GBS-$i', 'securityEnabled': true},
        ],
      });
    }

    test('logs one line for every 20 groups pulled', () async {
      final transport = FakeGraphTransport((req) => routeWithGroups(req, 45));
      final log = RecordingLog();
      final groups = GroupManager(clientWith(transport), log: log);

      final result = await groups.listGroups('GBS');

      expect(result, hasLength(45));
      // The milestone lines only: since #266 the closing summary reads
      // "N groepen opgehaald voor …" and would otherwise match too.
      expect(
        log.messages.where((m) => m.endsWith('groepen opgehaald…')).toList(),
        ['Azure: 20 groepen opgehaald…', 'Azure: 40 groepen opgehaald…'],
      );
    });

    test('emits no progress line below the first 20 threshold', () async {
      final transport = FakeGraphTransport((req) => routeWithGroups(req, 5));
      final log = RecordingLog();
      final groups = GroupManager(clientWith(transport), log: log);

      await groups.listGroups('GBS');

      expect(
        log.messages.where((m) => m.endsWith('groepen opgehaald…')),
        isEmpty,
      );
    });
  });

  group('class-group creation (#228)', () {
    test('creates a mail-enabled unified group, not a security group',
        () async {
      final transport = FakeGraphTransport((req) => jsonOk({
            'id': 'g-new',
            'displayName': req.body == null
                ? ''
                : (jsonDecode(req.body!)
                    as Map<String, dynamic>)['displayName'],
            'mail': 'GBS-2A@student.school.example',
            'mailNickname': 'GBS-2A',
          }));
      final groups = GroupManager(clientWith(transport));

      final created = await groups.createGroup(
        displayName: 'GBS-2A',
        mailNickname: 'GBS-2A',
        description: 'Tweede jaar A',
      );

      expect(transport.last.method, 'POST');
      expect(transport.last.url.path, endsWith('/groups'));
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      expect(body['groupTypes'], ['Unified']);
      expect(body['mailEnabled'], isTrue);
      expect(body['securityEnabled'], isFalse);
      expect(body['displayName'], 'GBS-2A');
      expect(body['mailNickname'], 'GBS-2A');
      expect(body['description'], 'Tweede jaar A');

      expect(created.id, 'g-new');
      expect(created.mail, 'GBS-2A@student.school.example');
      expect(created.mailNickname, 'GBS-2A');
      // Graph's create echo leaves `groupTypes` out, and the record must still
      // read back as the one shape this method writes (#331) — otherwise the
      // group it just made would be filed as one whose membership Graph refuses
      // and the chained roster write would never be proposed.
      expect(created.isUnified, isTrue);
      expect(created.canManageMembership, isTrue);
      expect(created.memberIds, isEmpty,
          reason: 'membership is a separate write');
    });

    test('an empty description is left out of the body entirely', () async {
      final transport = FakeGraphTransport((_) => jsonOk({'id': 'g-new'}));
      final groups = GroupManager(clientWith(transport));
      await groups.createGroup(displayName: 'GBS-2A', mailNickname: 'GBS-2A');
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      expect(body.containsKey('description'), isFalse);
    });

    test('findByMailNickname filters on the nickname and returns the group',
        () async {
      final transport = FakeGraphTransport((_) => jsonOk({
            'value': [
              {
                'id': 'g-1',
                'displayName': 'GBS-2A',
                'mail': 'GBS-2A@student.school.example',
                'mailNickname': 'GBS-2A',
              },
            ],
          }));
      final groups = GroupManager(clientWith(transport));

      final found = await groups.findByMailNickname('GBS-2A');

      expect(transport.last.url.queryParameters[r'$filter'],
          "mailNickname in ('GBS-2A')");
      expect(transport.last.headers['ConsistencyLevel'], 'eventual');
      expect(found?.id, 'g-1');
      expect(transport.requests, hasLength(1),
          reason: 'the guard needs no member list');
    });

    test('findByMailNickname returns null when the tenant has none', () async {
      final transport =
          FakeGraphTransport((_) => jsonOk({'value': const <Object>[]}));
      final groups = GroupManager(clientWith(transport));
      expect(await groups.findByMailNickname('GBS-2A'), isNull);
    });

    test('a blank nickname short-circuits without a call', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final groups = GroupManager(clientWith(transport));
      expect(await groups.findByMailNickname('  '), isNull);
      expect(transport.requests, isEmpty);
    });
  });

  group('loadByMailNicknames (#280)', () {
    /// One Graph `/groups` row for a class group somebody renamed by hand: the
    /// address is still ours, the display name is not — the exact shape
    /// [GroupManager.listGroups]'s `startswith(displayName,…)` misses.
    Map<String, dynamic> renamed(String nickname) => <String, dynamic>{
          'id': 'g-$nickname',
          'displayName': 'Klas van juf An',
          'mail': '$nickname@student.school.example',
          'mailNickname': nickname,
        };

    test('asks Graph for exactly the nicknames, with the advanced-query header',
        () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final groups = GroupManager(clientWith(transport));

      await groups.loadByMailNicknames(['GBS-2A', 'GBS-2B']);

      expect(transport.requests, hasLength(1));
      final req = transport.last;
      expect(req.method, 'GET');
      expect(req.url.path, endsWith('/groups'));
      expect(
        req.url.queryParameters[r'$filter'],
        "mailNickname in ('GBS-2A','GBS-2B')",
      );
      expect(req.url.queryParameters[r'$count'], 'true');
      expect(
        req.url.queryParameters[r'$select'],
        'id,displayName,securityEnabled,mailEnabled,groupTypes,mail,'
        'mailNickname',
      );
      expect(req.headers['ConsistencyLevel'], 'eventual');
    });

    test(
        'returns the group the prefix-scoped list cannot see, with its members',
        () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.path.contains('/members')) {
          return jsonOk({
            'value': [
              {'id': 'az1'},
              {'id': 'az2'},
            ],
          });
        }
        return jsonOk({
          'value': [renamed('GBS-5WW1')],
        });
      });
      final groups = GroupManager(clientWith(transport));

      final found = await groups.loadByMailNicknames(['GBS-5WW1']);

      expect(found, hasLength(1));
      expect(found.single.mailNickname, 'GBS-5WW1');
      expect(found.single.displayName, 'Klas van juf An',
          reason: 'the display name is what was renamed away from us');
      expect(found.single.memberIds, ['az1', 'az2'],
          reason: 'an adopted group must be roster-diffable on the same pass');
    });

    test('withMembers: false skips the member reads entirely', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({
          'value': [renamed('GBS-5WW1')],
        }),
      );
      final groups = GroupManager(clientWith(transport));

      final found =
          await groups.loadByMailNicknames(['GBS-5WW1'], withMembers: false);

      expect(found.single.memberIds, isEmpty);
      expect(transport.requests, hasLength(1));
    });

    test('chunks a long nickname list and de-duplicates the result', () async {
      final nicknames = [for (var i = 0; i < 32; i++) 'GBS-$i'];
      final transport = FakeGraphTransport((req) {
        if (req.url.path.contains('/members')) {
          return jsonOk({'value': const <Object>[]});
        }
        // Every chunk answers with the same row, so a naive merge would report
        // it three times.
        return jsonOk({
          'value': [renamed('GBS-7')],
        });
      });
      final groups = GroupManager(clientWith(transport));

      final found = await groups.loadByMailNicknames(nicknames);

      final lookups = transport.requests
          .where((r) => !r.url.path.contains('/members'))
          .toList();
      expect(lookups, hasLength(3), reason: '15 + 15 + 2');
      expect(
        lookups.last.url.queryParameters[r'$filter'],
        "mailNickname in ('GBS-30','GBS-31')",
      );
      expect(found, hasLength(1));
    });

    test('blank and duplicate nicknames never reach Graph', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final groups = GroupManager(clientWith(transport));

      expect(await groups.loadByMailNicknames(const ['', '  ']), isEmpty);
      expect(transport.requests, isEmpty);

      await groups.loadByMailNicknames([' GBS-2A ', 'GBS-2A', '']);
      expect(
        transport.last.url.queryParameters[r'$filter'],
        "mailNickname in ('GBS-2A')",
      );
    });

    test('escapes a single quote in a nickname', () async {
      final transport = FakeGraphTransport(
        (_) => jsonOk({'value': <Object>[]}),
      );
      final groups = GroupManager(clientWith(transport));

      await groups.loadByMailNicknames(["GBS-O'1"]);
      expect(
        transport.last.url.queryParameters[r'$filter'],
        "mailNickname in ('GBS-O''1')",
      );
    });
  });

  group('membership writes', () {
    test('addMember POSTs an @odata.id directoryObjects ref', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final groups = GroupManager(clientWith(transport));
      await groups.addMember('g1', 'u1');
      expect(transport.last.method, 'POST');
      expect(transport.last.url.path, endsWith(r'/members/$ref'));
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      expect(
        body['@odata.id'],
        'https://graph.microsoft.com/v1.0/directoryObjects/u1',
      );
    });

    test('removeMember DELETEs the member ref', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final groups = GroupManager(clientWith(transport));
      await groups.removeMember('g1', 'u1');
      expect(transport.last.method, 'DELETE');
      expect(transport.last.url.path, endsWith(r'/members/u1/$ref'));
    });
  });

  group('group deletion (#271)', () {
    test('deleteGroup DELETEs the group resource itself, in Dutch', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final log = RecordingLog();
      await GroupManager(clientWith(transport), log: log).deleteGroup('g1');

      expect(transport.last.method, 'DELETE');
      expect(transport.last.url.path, endsWith('/groups/g1'),
          reason: 'the group, not one of its member refs');
      expect(log.messages, contains('Azure: groep g1 verwijderd.'));
    });

    test('an id with reserved characters is encoded', () async {
      final transport = FakeGraphTransport.constant(noContent());
      await GroupManager(clientWith(transport)).deleteGroup('a/b');
      expect(transport.last.url.path, endsWith('/groups/a%2Fb'));
    });
  });

  group('\$batch', () {
    test('coalesces many adds into one \$batch POST with relative urls',
        () async {
      final transport = FakeGraphTransport((req) {
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests = body['requests'] as List<dynamic>;
        return jsonOk({
          'responses': [
            for (final r in requests.cast<Map<String, dynamic>>())
              {'id': r['id'], 'status': 204},
          ],
        });
      });
      final groups = GroupManager(clientWith(transport));

      final results = await groups.addMembers('g1', ['u1', 'u2', 'u3']);

      expect(transport.requests, hasLength(1));
      expect(transport.last.url.path, endsWith(r'/$batch'));
      final body = jsonDecode(transport.last.body!) as Map<String, dynamic>;
      final reqs = (body['requests'] as List).cast<Map<String, dynamic>>();
      expect(reqs, hasLength(3));
      expect(reqs.first['method'], 'POST');
      expect(reqs.first['url'], r'/groups/g1/members/$ref');
      expect(results.every((r) => r.isSuccess), isTrue);
    });

    test('chunks batches larger than 20 sub-requests', () async {
      var batches = 0;
      final transport = FakeGraphTransport((req) {
        batches++;
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests = body['requests'] as List<dynamic>;
        return jsonOk({
          'responses': [
            for (final r in requests.cast<Map<String, dynamic>>())
              {'id': r['id'], 'status': 204},
          ],
        });
      });
      final groups = GroupManager(clientWith(transport));

      final userIds = List.generate(45, (i) => 'u$i');
      final results = await groups.addMembers('g1', userIds);

      expect(batches, 3); // 20 + 20 + 5
      expect(results, hasLength(45));
    });

    test('empty member list short-circuits without a call', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final groups = GroupManager(clientWith(transport));
      expect(await groups.addMembers('g1', const []), isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('removeMembers batches DELETE \$ref sub-requests', () async {
      final transport = FakeGraphTransport((req) {
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests =
            (body['requests'] as List).cast<Map<String, dynamic>>();
        return jsonOk({
          'responses': [
            for (final r in requests) {'id': r['id'], 'status': 204},
          ],
        });
      });
      final groups = GroupManager(clientWith(transport));

      final results = await groups.removeMembers('g1', ['u1', 'u2']);

      final reqs = (jsonDecode(transport.last.body!)
          as Map<String, dynamic>)['requests'] as List;
      expect(reqs, hasLength(2));
      expect((reqs.first as Map)['method'], 'DELETE');
      expect((reqs.first as Map)['url'], r'/groups/g1/members/u1/$ref');
      expect(results.every((r) => r.isSuccess), isTrue);
    });

    test('removeMembers short-circuits on an empty list', () async {
      final transport = FakeGraphTransport.constant(noContent());
      final groups = GroupManager(clientWith(transport));
      expect(await groups.removeMembers('g1', const []), isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('a non-object sub-response body is dropped, not crashed on', () async {
      // Graph base64-encodes a binary sub-response body. Nothing membership
      // writes ask for answers that way, but a parse that dies on it would take
      // the whole apply down with a message about types rather than about the
      // write — the opposite of what #330 is for.
      final transport = FakeGraphTransport(
        (_) => jsonOk({
          'responses': [
            {'id': '0', 'status': 400, 'body': 'not-an-object'},
          ],
        }),
      );
      final groups = GroupManager(clientWith(transport));

      final results = await groups.addMembers('g1', ['u1']);

      expect(results.single.status, 400);
      expect(results.single.body, isNull);
      expect(results.single.reason, '400');
    });
  });

  // Until #330 both batch writers logged an unconditional success line the
  // moment `execute` returned — so the wholesale refusal of #331 (a
  // mail-enabled security group whose membership Graph will not manage) was
  // written into the log as 38 changes that never happened.
  group('a membership batch is logged as it actually went (#330)', () {
    /// A `$batch` whose sub-requests Graph refuses with [status]/[code], except
    /// for the ids in [succeed].
    FakeGraphTransport refusing({
      int status = 400,
      String code = 'Request_BadRequest',
      String message = 'Adding members is not supported for this group.',
      Set<String> succeed = const {},
    }) =>
        FakeGraphTransport((req) {
          final body = jsonDecode(req.body!) as Map<String, dynamic>;
          final requests =
              (body['requests'] as List).cast<Map<String, dynamic>>();
          return jsonOk({
            'responses': [
              for (final r in requests)
                if (succeed.contains(r['id']))
                  {'id': r['id'], 'status': 204}
                else
                  {
                    'id': r['id'],
                    'status': status,
                    'body': {
                      'error': {'code': code, 'message': message},
                    },
                  },
            ],
          });
        });

    test('a wholesale refusal is an error naming what Graph said', () async {
      final log = RecordingLog();
      final groups = GroupManager(clientWith(refusing()), log: log);

      await groups.addMembers('g1', ['u1', 'u2', 'u3']);

      expect(
        log.errors,
        contains(
          'Azure: 0 van 3 leden toegevoegd aan groep g1 — 3 mislukt: '
          '400 Request_BadRequest: Adding members is not supported for this '
          'group.',
        ),
      );
      expect(
        log.messages,
        isNot(contains(contains('in batch toegevoegd'))),
        reason: 'the success line that used to be written regardless is gone',
      );
    });

    test('every refused member is traceable in the log', () async {
      final log = RecordingLog();
      final groups = GroupManager(
        clientWith(refusing(succeed: const {'0'})),
        log: log,
      );

      await groups.removeMembers('g1', ['u1', 'u2', 'u3']);

      // The partial success is stated honestly…
      expect(
        log.errors.single,
        startsWith('Azure: 1 van 3 leden verwijderd uit groep g1 — 2 mislukt:'),
      );
      // …and the two that failed are named, so a partial failure points at
      // accounts rather than at a count.
      expect(
        log.messages,
        containsAll(<String>[
          'Azure: groep g1 — u2 → 400 Request_BadRequest: Adding members is '
              'not supported for this group.',
          'Azure: groep g1 — u3 → 400 Request_BadRequest: Adding members is '
              'not supported for this group.',
        ]),
      );
      expect(
        log.messages,
        isNot(contains(contains('u1'))),
        reason: 'the member that went through is not detail worth reading',
      );
    });

    test('a batch that failed for mixed reasons says so', () async {
      final log = RecordingLog();
      final transport = FakeGraphTransport((req) {
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests =
            (body['requests'] as List).cast<Map<String, dynamic>>();
        return jsonOk({
          'responses': [
            for (final r in requests)
              {
                'id': r['id'],
                'status': r['id'] == '0' ? 400 : 404,
                'body': {
                  'error': {
                    'code': r['id'] == '0'
                        ? 'Request_BadRequest'
                        : 'Request_ResourceNotFound',
                    'message': 'Nope.',
                  },
                },
              },
          ],
        });
      });
      final groups = GroupManager(clientWith(transport), log: log);

      await groups.addMembers('g1', ['u1', 'u2']);

      expect(
        log.errors.single,
        'Azure: 0 van 2 leden toegevoegd aan groep g1 — 2 mislukt: '
        '400 Request_BadRequest: Nope. (en 1 andere fout(en))',
      );
    });

    test('a batch that fully succeeded stays an ordinary message', () async {
      final log = RecordingLog();
      final transport = FakeGraphTransport((req) {
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests =
            (body['requests'] as List).cast<Map<String, dynamic>>();
        return jsonOk({
          'responses': [
            for (final r in requests) {'id': r['id'], 'status': 204},
          ],
        });
      });
      final groups = GroupManager(clientWith(transport), log: log);

      await groups.addMembers('g1', ['u1', 'u2']);

      expect(log.errors, isEmpty);
      expect(
        log.messages,
        ['Azure: 2 van 2 leden toegevoegd aan groep g1.'],
      );
    });
  });

  // Everything this manager writes into an [ILog] lands in the app's Log panel
  // beside the Dutch the app layer writes there (#253/#257/#258), so it is
  // Dutch too (#266).
  group('operator log lines are Dutch (#266)', () {
    test('the group read reports what it pulled, for which prefix', () async {
      final transport = FakeGraphTransport((req) {
        if (req.url.path.contains('/members')) {
          return jsonOk({'value': const <Object>[]});
        }
        return jsonOk(readFixture('groups.json'));
      });
      final log = RecordingLog();

      await GroupManager(clientWith(transport), log: log).listGroups('GBS');

      expect(log.messages, contains('Azure: 2 groepen opgehaald voor "GBS".'));
      expect(log.messages, isNot(contains(contains('loaded '))));
    });

    test('a created class group and the membership writes are Dutch', () async {
      final created = FakeGraphTransport((_) => jsonOk({'id': 'g-new'}));
      final createLog = RecordingLog();
      await GroupManager(clientWith(created), log: createLog).createGroup(
        displayName: 'GBS-2A',
        mailNickname: 'GBS-2A',
      );
      expect(
        createLog.messages,
        contains('Azure: Microsoft 365-groep GBS-2A (GBS-2A) aangemaakt.'),
      );

      final wrote = FakeGraphTransport.constant(noContent());
      final writeLog = RecordingLog();
      final groups = GroupManager(clientWith(wrote), log: writeLog);
      await groups.addMember('g1', 'u1');
      await groups.removeMember('g1', 'u1');
      expect(
        writeLog.messages,
        containsAll(<String>[
          'Azure: u1 toegevoegd aan groep g1.',
          'Azure: u1 verwijderd uit groep g1.',
        ]),
      );

      final batched = FakeGraphTransport((req) {
        final body = jsonDecode(req.body!) as Map<String, dynamic>;
        final requests =
            (body['requests'] as List).cast<Map<String, dynamic>>();
        return jsonOk({
          'responses': [
            for (final r in requests) {'id': r['id'], 'status': 204},
          ],
        });
      });
      final batchLog = RecordingLog();
      final batchGroups = GroupManager(clientWith(batched), log: batchLog);
      await batchGroups.addMembers('g1', <String>['u1', 'u2']);
      await batchGroups.removeMembers('g1', <String>['u1', 'u2']);
      // Since #330 the line counts what the batch actually did rather than what
      // it was asked to do — still Dutch, and now also true.
      expect(
        batchLog.messages,
        containsAll(<String>[
          'Azure: 2 van 2 leden toegevoegd aan groep g1.',
          'Azure: 2 van 2 leden verwijderd uit groep g1.',
        ]),
      );

      // Not one of the five lines is still the English it used to be.
      for (final english in <String>[
        'created Microsoft 365 group',
        'added ',
        'removed ',
        'batch-added',
        'batch-removed',
      ]) {
        expect(
          <String>[
            ...createLog.messages,
            ...writeLog.messages,
            ...batchLog.messages,
          ].where((m) => m.contains(english)),
          isEmpty,
          reason: english,
        );
      }
    });
  });

  // A directory is a live system with other writers. Both group reads fan out
  // one member call per row the listing returned, so the list they are walking
  // is stale by construction and the member call is the leg that finds out.
  group('a group deleted between the listing and its member read (#356)', () {
    const names = ['GBS-3A', 'GBS-3B', 'GBS-3C'];
    const goneId = 'g-GBS-3B';

    /// Graph's own reply for a directory object that is no longer there — the
    /// one from the failing live run in #356, verbatim in shape.
    GraphResponse resourceNotFound() => graphError(
          404,
          'Request_ResourceNotFound',
          'Resource $goneId does not exist or one of its queried '
              'reference-property objects are not present.',
        );

    /// A `/groups` listing of [names] whose member read answers [failure] for
    /// [goneId] and an empty roster for everything else.
    FakeGraphTransport listingWhereOneMemberReadFails(GraphResponse failure) =>
        FakeGraphTransport((req) {
          if (!req.url.path.contains('/members')) {
            return jsonOk({
              'value': [
                for (final n in names)
                  {'id': 'g-$n', 'displayName': n, 'securityEnabled': true},
              ],
            });
          }
          return req.url.path.contains(goneId)
              ? failure
              : jsonOk({'value': const <Object>[]});
        });

    test('drops that one group and finishes the walk', () async {
      final transport = listingWhereOneMemberReadFails(resourceNotFound());
      final groups = GroupManager(clientWith(transport));

      final result = await groups.listGroups('GBS');

      expect(result.map((g) => g.displayName), ['GBS-3A', 'GBS-3C']);
      expect(
        transport.requests.where((r) => r.url.path.contains('/members')),
        hasLength(3),
        reason: 'the walk carried on past the failure to the last group',
      );
    });

    test('names the vanished group in Dutch, and logs no error', () async {
      final transport = listingWhereOneMemberReadFails(resourceNotFound());
      final log = RecordingLog();

      await GroupManager(loggingClientWith(transport, log), log: log)
          .listGroups('GBS');

      expect(
        log.messages,
        contains(
          'Azure: groep GBS-3B (g-GBS-3B) bestaat niet meer — ze is tijdens '
          'het ophalen uit Office 365 verwijderd en wordt overgeslagen.',
        ),
      );
      // The summary must not quietly claim a complete pull of two groups.
      expect(
        log.messages,
        contains(
          'Azure: 2 groepen opgehaald voor "GBS" (1 groep(en) overgeslagen '
          'omdat ze tijdens het ophalen verdwenen).',
        ),
      );
      // A pull that recovered is not a broken one (#229): the transport is told
      // this reply was expected, so nothing paints the operator's log red.
      expect(log.errors, isEmpty);
    });

    test('a group with no display name is still named by its object id',
        () async {
      final transport = FakeGraphTransport((req) {
        if (!req.url.path.contains('/members')) {
          return jsonOk({
            'value': [
              {'id': 'g-anon', 'securityEnabled': true},
            ],
          });
        }
        return resourceNotFound();
      });
      final log = RecordingLog();

      final result =
          await GroupManager(clientWith(transport), log: log).listGroups('GBS');

      expect(result, isEmpty);
      expect(
        log.messages,
        contains(startsWith('Azure: groep g-anon bestaat niet meer')),
      );
    });

    test('loadByMailNicknames drops it the same way', () async {
      final transport = FakeGraphTransport((req) {
        if (!req.url.path.contains('/members')) {
          return jsonOk({
            'value': [
              {'id': 'g-GBS-3A', 'displayName': 'Klas van juf An'},
              {'id': goneId, 'displayName': 'GBS-3B'},
            ],
          });
        }
        return req.url.path.contains(goneId)
            ? resourceNotFound()
            : jsonOk({'value': const <Object>[]});
      });
      final log = RecordingLog();

      final found =
          await GroupManager(loggingClientWith(transport, log), log: log)
              .loadByMailNicknames(['GBS-3A', 'GBS-3B']);

      expect(found.map((g) => g.id), ['g-GBS-3A']);
      expect(
        log.messages,
        contains(
            startsWith('Azure: groep GBS-3B (g-GBS-3B) bestaat niet meer')),
      );
      expect(log.errors, isEmpty);
    });

    // The whole risk of the tolerance. Reporting any of these as "a tenant with
    // fewer groups" would hand the action engine a pile of destructive
    // proposals — it reads a missing Azure group as one to create, or as a
    // class that is gone.
    final stillFatal = <String, GraphResponse>{
      'an expired token (401)': graphError(
        401,
        'InvalidAuthenticationToken',
        'Access token has expired.',
      ),
      'a refusal (403)': graphError(
        403,
        'Authorization_RequestDenied',
        'Insufficient privileges to complete the operation.',
      ),
      'throttling (429)': graphError(
        429,
        'TooManyRequests',
        'Too many requests.',
      ),
      'a Graph outage (503)': graphError(
        503,
        'serviceNotAvailable',
        'Service unavailable.',
      ),
      'a 404 with no Graph error envelope': const GraphResponse(
        statusCode: 404,
        body: '<html>Not Found</html>',
      ),
      'a 404 carrying some other code': graphError(
        404,
        'Request_BadRequest',
        'Invalid object identifier.',
      ),
    };

    stillFatal.forEach((label, failure) {
      test('$label still fails the whole pull', () async {
        final transport = listingWhereOneMemberReadFails(failure);
        final log = RecordingLog();
        final groups =
            GroupManager(loggingClientWith(transport, log), log: log);

        await expectLater(
          groups.listGroups('GBS'),
          throwsA(
            isA<GraphException>().having(
              (e) => e.statusCode,
              'statusCode',
              failure.statusCode,
            ),
          ),
        );
        expect(log.errors, isNotEmpty, reason: 'and it is logged as an error');
        expect(
          log.messages.any((m) => m.contains('bestaat niet meer')),
          isFalse,
          reason: 'and never dressed up as a group that simply vanished',
        );
      });
    });

    test('a 404 from the group listing itself still fails', () async {
      // The tolerance is scoped to the member leg. A listing that 404s is not
      // "one group vanished", it is a read that never happened.
      final transport = FakeGraphTransport((_) => resourceNotFound());
      final groups = GroupManager(clientWith(transport));

      await expectLater(
        groups.listGroups('GBS'),
        throwsA(isA<GraphException>()),
      );
    });

    test('loadMemberIds called directly is still loud', () async {
      // A caller asking about one named group wants to hear that it is gone.
      final transport = FakeGraphTransport((_) => resourceNotFound());
      final groups = GroupManager(clientWith(transport));

      await expectLater(
        groups.loadMemberIds(goneId),
        throwsA(isA<GraphException>()),
      );
    });
  });
}
