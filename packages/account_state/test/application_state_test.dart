import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:azure_api/azure_api.dart';
import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:wisa_api/wisa_api.dart';

/// A [GraphTransport] that records outgoing requests and replays a response
/// from an injected router — the "recording fake transport" the issue's test
/// plan calls for.
class _RecordingGraphTransport implements GraphTransport {
  _RecordingGraphTransport(this._route);

  final List<GraphRequest> requests = [];
  final GraphResponse Function(GraphRequest) _route;

  @override
  Future<GraphResponse> send(GraphRequest request) async {
    requests.add(request);
    return _route(request);
  }
}

GraphResponse _jsonOk(Object body) => GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );

WisaSnapshot _emptyWisa() => WisaSnapshot(
      fetchedAt: DateTime.utc(2026),
      students: const [],
      staff: const [],
      classGroups: const [],
      schools: const [],
    );

SmartschoolSnapshot _emptySmartschool() => SmartschoolSnapshot(
      fetchedAt: DateTime.utc(2026),
      groups: const [],
      accounts: const [],
      memberships: const [],
    );

AzureSnapshot _emptyAzure() => AzureSnapshot(
      fetchedAt: DateTime.utc(2026),
      users: const [],
      groups: const [],
    );

void main() {
  group('ApplicationState.sync dispatch', () {
    late ApplicationState app;
    late List<core.Origin> synced;

    setUp(() {
      synced = [];
      SystemState<S> record<S extends core.Snapshot>(
        core.Origin system,
        S Function() make,
      ) =>
          SystemState<S>(
            system: system,
            syncer: (_) async {
              synced.add(system);
              return make();
            },
          );

      app = ApplicationState(
        wisa: record(core.Origin.wisa, _emptyWisa),
        smartschool: record(core.Origin.smartschool, _emptySmartschool),
        azure: record(core.Origin.azure, _emptyAzure),
      );
    });

    test('routes each concrete system to its own SystemState', () async {
      final w = await app.sync(core.Origin.wisa);
      final s = await app.sync(core.Origin.smartschool);
      final a = await app.sync(core.Origin.azure);

      expect(w, isA<WisaSnapshot>());
      expect(s, isA<SmartschoolSnapshot>());
      expect(a, isA<AzureSnapshot>());
      expect(synced,
          [core.Origin.wisa, core.Origin.smartschool, core.Origin.azure]);
      expect(app.wisa.lastSync, isNotNull);
    });

    test('rejects the non-syncable wildcards', () {
      expect(() => app.sync(core.Origin.all), throwsArgumentError);
      expect(() => app.sync(core.Origin.other), throwsArgumentError);
      expect(synced, isEmpty);
    });
  });

  group('azureSyncer + SystemState (delta from day one, PAIN-2)', () {
    // Minimal Graph router: no groups (skips member fan-out), one user on the
    // full read, an empty delta on the incremental pass.
    GraphResponse route(GraphRequest req) {
      final path = req.url.path;
      final q = req.url.queryParameters;
      if (path.contains('groups')) return _jsonOk({'value': <Object?>[]});
      if (path.contains('users/delta')) {
        if (q[r'$deltatoken'] == 'latest') {
          return _jsonOk({
            '@odata.deltaLink':
                'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=PRIMED1',
            'value': <Object?>[],
          });
        }
        return _jsonOk({
          '@odata.deltaLink':
              'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=PRIMED2',
          'value': <Object?>[],
        });
      }
      // Full /users bulk read (single page).
      return _jsonOk({
        'value': [
          {
            'id': '00000000-0000-0000-0000-000000000001',
            'userPrincipalName': 'ann@student.school.example',
            'companyName': 'GBS',
            'accountEnabled': true,
          },
        ],
      });
    }

    late _RecordingGraphTransport transport;
    late SystemState<AzureSnapshot> azure;

    setUp(() {
      transport = _RecordingGraphTransport(route);
      final connector = AzureConnector(
        credentials: AzureCredentials(
          clientId: 'c',
          tenantId: 't',
          azureDomain: 'school.example',
          schoolPrefix: 'GBS',
        ),
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
      );
      azure = SystemState<AzureSnapshot>(
        system: core.Origin.azure,
        syncer: azureSyncer(connector),
      );
    });

    test('first sync does a full read, stores the snapshot and stamps lastSync',
        () async {
      final snapshot = await azure.sync();

      expect(snapshot.users, hasLength(1));
      expect(snapshot.deltaToken, 'PRIMED1', reason: 'primed for next time');
      expect(azure.snapshot, same(snapshot));
      expect(azure.lastSync, snapshot.fetchedAt);

      // The full read hit /users with a $filter, not an unfiltered delta.
      final bulk =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/users'));
      expect(bulk.url.queryParameters[r'$filter'], isNotNull);
    });

    test('the next sync threads the primed token into /users/delta', () async {
      await azure.sync();
      final snapshot = await azure.sync();

      final deltaCall = transport.requests.lastWhere(
        (r) => r.url.path.contains('users/delta'),
      );
      expect(deltaCall.url.queryParameters[r'$deltatoken'], 'PRIMED1',
          reason: 'SystemState fed the stored snapshot back to azureSyncer');
      expect(snapshot.deltaToken, 'PRIMED2');
      expect(azure.lastSync, snapshot.fetchedAt);
    });
  });
}
