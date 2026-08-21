import 'dart:convert';

import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  GraphClient clientWith(FakeGraphTransport transport) => GraphClient(
        transport: transport,
        auth: const StaticAuthProvider('T'),
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
        'id,displayName,securityEnabled,mail,mailNickname',
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
      expect(
        log.messages.where((m) => m.contains('groepen opgehaald')).toList(),
        ['Azure: 20 groepen opgehaald…', 'Azure: 40 groepen opgehaald…'],
      );
    });

    test('emits no progress line below the first 20 threshold', () async {
      final transport = FakeGraphTransport((req) => routeWithGroups(req, 5));
      final log = RecordingLog();
      final groups = GroupManager(clientWith(transport), log: log);

      await groups.listGroups('GBS');

      expect(
        log.messages.where((m) => m.contains('groepen opgehaald')),
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
      expect(created.isUnified, isTrue);
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
          "mailNickname eq 'GBS-2A'");
      expect(transport.last.headers['ConsistencyLevel'], 'eventual');
      expect(found?.id, 'g-1');
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
  });
}
