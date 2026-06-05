import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart';
import 'package:test/test.dart';

import 'support/fake_graph_transport.dart';

void main() {
  final credentials = AzureCredentials(
    clientId: 'c',
    tenantId: 't',
    azureDomain: 'school.example',
    schoolPrefix: 'GBS',
  );

  GraphResponse route(GraphRequest req) {
    final path = req.url.path;
    if (path.contains('/members')) {
      return jsonOk(readFixture('group_members_3a.json'));
    }
    if (path.contains('groups')) {
      return jsonOk(readFixture('groups.json'));
    }
    if (path.contains('users/delta')) {
      if (req.url.queryParameters[r'$deltatoken'] == 'latest') {
        return jsonOk(readFixture('delta_latest.json'));
      }
      if (req.url.queryParameters[r'$skiptoken'] == 'DELTA2') {
        return jsonOk(readFixture('users_delta_final.json'));
      }
      return jsonOk(readFixture('users_delta_page1.json'));
    }
    // plain /users bulk read
    if (req.url.queryParameters[r'$skiptoken'] == 'PAGE2') {
      return jsonOk(readFixture('users_page2.json'));
    }
    return jsonOk(readFixture('users_page1.json'));
  }

  AzureConnector connectorWith(FakeGraphTransport transport) => AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
      );

  group('first/full sync', () {
    test(
        'uses \$filter bulk read + primes a delta token, never an unfiltered '
        'delta', () async {
      final transport = FakeGraphTransport(route);
      final connector = connectorWith(transport);

      final snapshot = await connector.sync();

      expect(snapshot.origin, core.Origin.azure);
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');
      expect(snapshot.users.map((u) => u.upn), [
        'ann.peeters@student.school.example',
        'bram.janssens@student.school.example',
        'carla.maes@school.example',
      ]);
      expect(snapshot.groups, hasLength(2));

      // The bulk read went to /users with a $filter (the PAIN-2 contract),
      // not to an unfiltered /users/delta enumerating the whole tenant.
      final bulk = transport.requests.firstWhere(
        (r) => r.url.path.endsWith('/users'),
      );
      expect(bulk.url.queryParameters[r'$filter'], isNotNull);
    });
  });

  group('incremental sync', () {
    test('applies delta changes and removals on top of the previous snapshot',
        () async {
      final transport = FakeGraphTransport(route);
      final connector = connectorWith(transport);

      final previous = AzureSnapshot(
        fetchedAt: DateTime.utc(2026, 6, 1),
        deltaToken: 'OLDTOKEN',
        users: const [
          AzureUser(id: '00000000-0000-0000-0000-000000000001', upn: 'ann@x'),
          AzureUser(
            id: '00000000-0000-0000-0000-000000000002',
            upn: 'bram@x',
            department: '3A',
          ),
          AzureUser(id: '00000000-0000-0000-0000-000000000003', upn: 'carla@x'),
        ],
        groups: const [],
      );

      final snapshot =
          await connector.sync(deltaToken: 'OLDTOKEN', previous: previous);

      final byId = {for (final u in snapshot.users) u.id: u};
      // 0001 removed.
      expect(byId.containsKey('00000000-0000-0000-0000-000000000001'), isFalse);
      // 0002 updated (department 3A → 4A).
      expect(byId['00000000-0000-0000-0000-000000000002']?.department, '4A');
      // 0003 untouched.
      expect(byId.containsKey('00000000-0000-0000-0000-000000000003'), isTrue);
      // 0009 added.
      expect(byId.containsKey('00000000-0000-0000-0000-000000000009'), isTrue);
      // out-of-prefix 0050 never enters the snapshot.
      expect(byId.containsKey('00000000-0000-0000-0000-000000000050'), isFalse);
      expect(snapshot.deltaToken, 'NEWDELTA456');
    });

    test('delta sync issues /users/delta with the supplied token', () async {
      final transport = FakeGraphTransport(route);
      final connector = connectorWith(transport);
      await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: AzureSnapshot(
          fetchedAt: DateTime.utc(2026),
          users: const [],
          groups: const [],
        ),
      );
      final deltaCall = transport.requests.firstWhere(
        (r) => r.url.path.contains('users/delta'),
      );
      expect(deltaCall.url.queryParameters[r'$deltatoken'], 'OLDTOKEN');
    });
  });
}
