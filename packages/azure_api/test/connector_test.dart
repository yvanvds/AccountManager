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

    test(
        'a per-pull schoolPrefix overrides the credentials\' frozen one (#246)',
        () async {
      // The prefix is operator-editable in Instellingen while the app runs, but
      // the credentials are baked in when bootstrap constructs the connector.
      // The caller therefore passes the prefix as it stands now; the
      // credentials' copy is only the default.
      final transport = FakeGraphTransport(route);
      await connectorWith(transport).sync(schoolPrefix: 'SSM');

      final bulk =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/users'));
      expect(bulk.url.queryParameters[r'$filter'], contains('SSM'));
      expect(bulk.url.queryParameters[r'$filter'], isNot(contains('GBS')));

      final groups =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/groups'));
      expect(groups.url.queryParameters[r'$filter'], contains('SSM'),
          reason: 'the group listing is scoped by the same prefix');
    });

    test('omitting it keeps the credentials\' prefix, as before #246',
        () async {
      final transport = FakeGraphTransport(route);
      await connectorWith(transport).sync();

      final bulk =
          transport.requests.firstWhere((r) => r.url.path.endsWith('/users'));
      expect(bulk.url.queryParameters[r'$filter'], contains('GBS'));
    });
  });

  group('drift-check progress logging (#177)', () {
    test('a full sync emits account and group progress while paging', () async {
      // azure_api is a pure-Dart package with no UI, so the end-to-end surface
      // for issue #177 is the connector driving the real managers + paging
      // GraphClient against a fake transport, with the progress lines landing
      // in the injected ILog exactly as they would in the app's Log panel.
      const groupCount = 45;
      GraphResponse pagedRoute(GraphRequest req) {
        final path = req.url.path;
        if (path.contains('/members')) {
          return jsonOk({'value': const <Object>[]});
        }
        if (path.contains('groups')) {
          return jsonOk({
            'value': [
              for (var i = 0; i < groupCount; i++)
                {'id': 'g$i', 'displayName': 'GBS-$i', 'securityEnabled': true},
            ],
          });
        }
        if (path.contains('users/delta')) {
          return jsonOk(readFixture('delta_latest.json'));
        }
        // Bulk /users read: 250 users across three pages (100 / 100 / 50).
        switch (req.url.queryParameters[r'$skiptoken']) {
          case 'P1':
            return usersPage(startIndex: 100, count: 100, nextSkipToken: 'P2');
          case 'P2':
            return usersPage(startIndex: 200, count: 50);
          default:
            return usersPage(startIndex: 0, count: 100, nextSkipToken: 'P1');
        }
      }

      final transport = FakeGraphTransport(pagedRoute);
      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
        log: log,
      );

      final snapshot = await connector.sync();

      expect(snapshot.users, hasLength(250));
      expect(snapshot.groups, hasLength(groupCount));
      expect(
        log.messages,
        containsAllInOrder(<String>[
          'Azure: 20 groepen opgehaald…',
          'Azure: 40 groepen opgehaald…',
        ]),
      );
      expect(
        log.messages,
        containsAllInOrder(<String>[
          'Azure: 100 accounts opgehaald…',
          'Azure: 200 accounts opgehaald…',
        ]),
      );
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

    test(
        'a delta walk that returns no deltaLink leaves no token rather than '
        'carrying the old one forward (#213)', () async {
      // Graph normally closes a delta walk with an `@odata.deltaLink`. When it
      // does not, the pre-fix connector re-shipped the token it was handed, so
      // the stored token stopped advancing while every sync still reported
      // success — and kept ageing until Graph refused it for being >30 days
      // old. No token at all is the honest answer: the next sync re-reads.
      GraphResponse noLinkRoute(GraphRequest req) {
        // Everything empty, and — the point of the test — the delta walk ends
        // with no `@odata.deltaLink`.
        return jsonOk({'value': const <Object>[]});
      }

      final connector = connectorWith(FakeGraphTransport(noLinkRoute));
      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: const [],
          groups: const [],
        ),
      );

      expect(snapshot.deltaToken, isNull,
          reason: 'a token that did not advance is dropped, never re-shipped');
    });
  });

  group('a resumed delta row is sparse (#288)', () {
    /// The account the previous snapshot holds, complete.
    const stored = AzureUser(
      id: 'az1',
      upn: 'jane.doe@student.school.example',
      employeeId: 'W1',
      displayName: 'Jane Doe',
      givenName: 'Jane',
      surname: 'Doe',
      companyName: 'GBS',
      department: '3C',
    );

    AzureSnapshot previousWith(List<AzureUser> users) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: users,
          groups: const [],
        );

    /// A delta walk answering with [rows] and nothing else — no groups, no bulk
    /// read, no back-fill hits.
    GraphResponse Function(GraphRequest) walkOf(
      List<Map<String, dynamic>> rows, {
      List<Map<String, dynamic>> backfill = const [],
    }) =>
        (req) {
          final path = req.url.path;
          if (path.contains('/members') || path.contains('groups')) {
            return jsonOk({'value': const <Object>[]});
          }
          if (path.contains('users/delta')) {
            return jsonOk({
              '@odata.deltaLink':
                  'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=T2',
              'value': rows,
            });
          }
          final filter = req.url.queryParameters[r'$filter'] ?? '';
          if (filter.startsWith('employeeId in')) {
            return jsonOk({'value': backfill});
          }
          return jsonOk({'value': const <Object>[]});
        };

    test('a hand-edit in Entra reaches the snapshot with the record intact',
        () async {
      // The report: an administrator renames someone in the O365 portal, the
      // resumed walk reports `{id, displayName}` — and the connector both
      // dropped the row (it names no school) and, for the rows it did keep,
      // upserted the fragment over the record, wiping the UPN and the
      // `employeeId → wisaId` bridge the linker joins on.
      final connector = connectorWith(FakeGraphTransport(walkOf(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'az1',
            'displayName': 'Janneke Doe',
            'givenName': 'Janneke',
          },
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [stored]),
      );

      expect(
        snapshot.users.single,
        stored.copyWith(displayName: 'Janneke Doe', givenName: 'Janneke'),
      );
    });

    test('a sparse row never blanks the record of a user it does not name',
        () async {
      final connector = connectorWith(FakeGraphTransport(walkOf(
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'az1', 'accountEnabled': false},
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [
          stored,
          AzureUser(
            id: 'az2',
            upn: 'jan.peeters@student.school.example',
            employeeId: 'W2',
            displayName: 'Jan Peeters',
            companyName: 'GBS',
          ),
        ]),
      );

      final byId = {for (final u in snapshot.users) u.id: u};
      expect(byId['az1'], stored.copyWith(accountEnabled: false));
      expect(byId['az2']?.displayName, 'Jan Peeters');
    });

    test(
        'the employeeId back-fill repairs a record instead of skipping it on '
        'object-id presence', () async {
      // The safety net was disarmed too: the back-fill re-fetched the right
      // record with the full `$select` and then dropped it on the floor because
      // the object id was already in the map. A record Graph just handed us
      // wins over one we are unsure about.
      const degraded = AzureUser(id: 'az1', upn: '', companyName: 'GBS');
      final connector = connectorWith(FakeGraphTransport(walkOf(
        const <Map<String, dynamic>>[],
        backfill: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'az1',
            'userPrincipalName': 'jane.doe@student.school.example',
            'employeeId': 'W1',
            'displayName': 'Jane Doe',
            'givenName': 'Jane',
            'surname': 'Doe',
            'companyName': 'GBS',
            'department': '3C',
            'accountEnabled': true,
          },
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [degraded]),
        expectedEmployeeIds: const ['W1'],
      );

      expect(snapshot.users.single, stored);
    });
  });

  group('a delta row that moves a user out of our school (#317)', () {
    /// The student as our snapshot holds her: ours, in step with WISA.
    const stored = AzureUser(
      id: 'az1',
      upn: 'jane.doe@student.school.example',
      employeeId: 'W1',
      displayName: 'Jane Doe',
      givenName: 'Jane',
      surname: 'Doe',
      companyName: 'GBS',
      department: '3C',
    );

    AzureSnapshot previousWith(List<AzureUser> users) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: users,
          groups: const [],
        );

    GraphResponse Function(GraphRequest) walkOf(
      List<Map<String, dynamic>> rows, {
      List<Map<String, dynamic>> backfill = const [],
    }) =>
        (req) {
          final path = req.url.path;
          if (path.contains('/members') || path.contains('groups')) {
            return jsonOk({'value': const <Object>[]});
          }
          if (path.contains('users/delta')) {
            return jsonOk({
              '@odata.deltaLink':
                  'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=T2',
              'value': rows,
            });
          }
          final filter = req.url.queryParameters[r'$filter'] ?? '';
          if (filter.startsWith('employeeId in')) {
            return jsonOk({'value': backfill});
          }
          return jsonOk({'value': const <Object>[]});
        };

    test('the account we held is dropped instead of surviving stale', () async {
      // The report: Graph says the account moved to a sibling school and the
      // snapshot goes on insisting it is ours. The walk dropped the row, and
      // `_applyDelta` only ever upserts what the walk kept — so nothing touched
      // the record, and nothing ever would: every later pass drops the same row
      // for the same reason.
      final connector = connectorWith(FakeGraphTransport(walkOf(
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'az1', 'companyName': 'OTHER'},
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [stored]),
      );

      expect(snapshot.users, isEmpty);
    });

    test('a student WISA still places here comes back, from Graph', () async {
      // The #224 leg and this one have to agree rather than fight. The record
      // leaves on the delta leg and the back-fill re-adopts it on the same pass
      // — with the account exactly as Graph holds it, so what the snapshot ends
      // up asserting is Graph's version and not the one we had.
      final connector = connectorWith(FakeGraphTransport(walkOf(
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'az1', 'companyName': 'OTHER'},
        ],
        backfill: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'az1',
            'userPrincipalName': 'jane.doe@student.school.example',
            'employeeId': 'W1',
            'displayName': 'Jane Doe',
            'givenName': 'Jane',
            'surname': 'Doe',
            'companyName': 'OTHER',
            'department': '3C',
            'accountEnabled': true,
          },
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [stored]),
        expectedEmployeeIds: const ['W1'],
      );

      expect(snapshot.users.single, stored.copyWith(companyName: 'OTHER'));
    });

    test('a row about a stranger still changes nothing', () async {
      // Unchanged behaviour, and the reason the bucket is keyed on what we
      // already hold: a sparse row we cannot classify is not evidence that
      // somebody left, and there is no record of ours to take away anyway.
      final connector = connectorWith(FakeGraphTransport(walkOf(
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'az-unknown', 'displayName': 'Someone Else'},
        ],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [stored]),
      );

      expect(snapshot.users.single, stored);
    });
  });

  group('rejected delta token (#213)', () {
    /// Routes a delta *resume* to [rejection] while the full-read path
    /// (`$deltatoken=latest` + the `$filter` bulk read) succeeds.
    GraphResponse Function(GraphRequest) rejectingRoute(
      GraphResponse rejection, {
      List<String>? resumeTokens,
    }) =>
        (req) {
          final path = req.url.path;
          if (path.contains('/members')) {
            return jsonOk(readFixture('group_members_3a.json'));
          }
          if (path.contains('groups')) {
            return jsonOk(readFixture('groups.json'));
          }
          if (path.contains('users/delta')) {
            final token = req.url.queryParameters[r'$deltatoken'];
            if (token == 'latest') {
              return jsonOk(readFixture('delta_latest.json'));
            }
            resumeTokens?.add(token ?? '');
            return rejection;
          }
          if (req.url.queryParameters[r'$skiptoken'] == 'PAGE2') {
            return jsonOk(readFixture('users_page2.json'));
          }
          return jsonOk(readFixture('users_page1.json'));
        };

    AzureSnapshot previousAt(DateTime at) => AzureSnapshot(
          fetchedAt: at,
          deltaToken: 'DEADTOKEN',
          users: const [
            AzureUser(id: '00000000-0000-0000-0000-000000000042', upn: 'old@x'),
          ],
          groups: const [],
        );

    test(
        'a 400 Request_UnsupportedQuery about an expired deltaLink falls back '
        'to a full read and primes a fresh token', () async {
      final resumeTokens = <String>[];
      final transport = FakeGraphTransport(rejectingRoute(
        graphError(
          400,
          'Request_UnsupportedQuery',
          'DeltaLink older than 30 days is not supported.',
        ),
        resumeTokens: resumeTokens,
      ));
      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
        log: log,
      );

      final snapshot = await connector.sync(
        deltaToken: 'DEADTOKEN',
        previous:
            previousAt(DateTime.now().subtract(const Duration(hours: 14))),
      );

      // The pass completed with a *complete* snapshot, not the previous user
      // list and not an exception.
      expect(resumeTokens, ['DEADTOKEN'], reason: 'tried once, then given up');
      expect(snapshot.users.map((u) => u.upn), [
        'ann.peeters@student.school.example',
        'bram.janssens@student.school.example',
        'carla.maes@school.example',
      ]);
      expect(snapshot.groups, hasLength(2));
      // …and with a fresh token, so the next sync resumes instead of hitting
      // the same dead token forever.
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');

      // The bulk read really was the $filter-scoped one (PAIN-2 holds on the
      // recovery path too).
      final bulk = transport.requests.firstWhere(
        (r) => r.url.path.endsWith('/users'),
      );
      expect(bulk.url.queryParameters[r'$filter'], isNotNull);

      // The operator is told what happened, with the rejected token's age —
      // the diagnostic that separates "genuinely old" from "stopped advancing".
      final recovery = log.messages.firstWhere(
        (m) => m.contains('weigerde het bewaarde deltatoken'),
      );
      // The age reads in Dutch units since #266 ("u", not "h").
      expect(recovery, contains('14u'));
      expect(recovery, contains('DeltaLink older than 30 days'));
    });

    test(
        'a pass that recovered logs no error at all, and never prints the dead '
        'token (#229)', () async {
      // The recovery of #213 worked, but the transport still logged the raw
      // Graph failure with `addError` — carrying the whole ~2.5 KB
      // `$deltatoken` in the URL — so a pass that fully recovered read as a
      // broken one in the operator's log.
      const dead = 'DEADTOKEN-2exa-dDwCZX0Ak-7duGZuSQD3Pc';
      final transport = FakeGraphTransport(rejectingRoute(graphError(
        400,
        'Request_UnsupportedQuery',
        'DeltaLink older than 30 days is not supported.',
      )));
      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
        log: log,
      );

      final snapshot = await connector.sync(
        deltaToken: dead,
        previous: previousAt(DateTime.now().subtract(const Duration(days: 46))),
      );

      // The pass really did recover.
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');
      expect(snapshot.users, hasLength(3));

      // Nothing red: a failure the connector handles is not logged at the same
      // severity as one it does not.
      expect(log.errors, isEmpty);

      // …and the resume token is nowhere in the log, at any severity.
      for (final line in [...log.messages, ...log.errors]) {
        expect(line, isNot(contains(dead)));
      }
      // The transport line is still there as a detail — the operator can see
      // what Graph actually said.
      expect(
        log.messages,
        contains(contains('DeltaLink older than 30 days')),
      );
      // And so is the connector's own explanation, with the token's age (#266
      // made the clause Dutch; the Graph body it quotes stays as Graph sent it).
      expect(
        log.messages,
        contains(contains('Graph weigerde het bewaarde deltatoken')),
      );
      expect(log.messages, contains(contains('bewaard ')));
      expect(
        log.messages,
        isNot(contains(contains('Graph rejected the stored delta token'))),
      );
    });

    test('Graph\'s documented 410 resyncRequired recovers the same way',
        () async {
      final transport = FakeGraphTransport(rejectingRoute(
        graphError(410, 'resyncRequired', 'Resync required.'),
      ));
      final connector = connectorWith(transport);

      final snapshot = await connector.sync(
        deltaToken: 'DEADTOKEN',
        previous: previousAt(DateTime.utc(2026, 6, 1)),
      );

      expect(snapshot.users, hasLength(3));
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');
    });

    test(
        'a 400 that is not about the delta token still fails the sync — a '
        'malformed query must stay loud', () async {
      final transport = FakeGraphTransport(rejectingRoute(
        graphError(
          400,
          'Request_UnsupportedQuery',
          "Unsupported or invalid query filter clause specified for property "
              "'jobTitle'.",
        ),
      ));
      final connector = connectorWith(transport);

      await expectLater(
        connector.sync(
          deltaToken: 'DEADTOKEN',
          previous: previousAt(DateTime.utc(2026, 6, 1)),
        ),
        throwsA(isA<GraphException>()),
      );
      expect(
        transport.requests.where((r) => r.url.path.endsWith('/users')),
        isEmpty,
        reason: 'no silent, expensive full read behind a real query bug',
      );
    });
  });

  group('employeeId back-fill (#224)', () {
    /// The transferred-in student's Graph row: our `employeeId`, **no**
    /// `companyName`, a `department` naming the school they came from, and a
    /// UPN whose given/family order the other school mangled. Neither leg of
    /// [UserManager.filterFor] matches it, so it is absent from every
    /// prefix-scoped read.
    const Map<String, dynamic> ambre = <String, dynamic>{
      'id': 'az-transferred',
      'userPrincipalName': 'alfio.ambre@student.other.example',
      'employeeId': 'W7',
      'displayName': 'Alfio Ambre',
      'department': 'OTHER-3A',
    };

    /// [route], plus an answer for the targeted `employeeId in (…)` lookup.
    GraphResponse Function(GraphRequest) routeWithBackfill({
      required List<String> lookups,
      List<Map<String, dynamic>> hits = const [ambre],
    }) =>
        (req) {
          final filter = req.url.queryParameters[r'$filter'] ?? '';
          if (req.url.path.endsWith('/users') &&
              filter.startsWith('employeeId in')) {
            lookups.add(filter);
            return jsonOk({'value': hits});
          }
          return route(req);
        };

    test(
        'a full sync adopts the account the school filter cannot see, asking '
        'only about the ids it could not account for', () async {
      final lookups = <String>[];
      final transport = FakeGraphTransport(routeWithBackfill(lookups: lookups));
      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
        log: log,
      );

      // `users_page1/2.json` carry W1001, W1002 and S2001; W7 is the transfer.
      final snapshot = await connector.sync(
        expectedEmployeeIds: const ['W1001', 'W1002', 'S2001', 'W7'],
      );

      // The three already-visible ids were never asked about — the bounded
      // pull (PAIN-2) stays bounded.
      expect(lookups, ["employeeId in ('W7')"]);
      // …and the missing account is in the snapshot, so the linker's
      // employeeId → wisaId bridge can reach it.
      final adopted = snapshot.users.singleWhere((u) => u.employeeId == 'W7');
      expect(adopted.id, 'az-transferred');
      expect(adopted.companyName, isNull);
      expect(snapshot.users, hasLength(4));
      expect(
        log.messages
            .any((m) => m.contains('1 bestaand(e) account(s) overgenomen')),
        isTrue,
      );
      expect(log.messages.any((m) => m.contains('adopted ')), isFalse);
    });

    test('an incremental sync adopts it too — the delta path is equally blind',
        () async {
      final lookups = <String>[];
      final transport = FakeGraphTransport(routeWithBackfill(lookups: lookups));
      final connector = connectorWith(transport);

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: const [],
          groups: const [],
        ),
        expectedEmployeeIds: const ['W7'],
      );

      expect(lookups, ["employeeId in ('W7')"]);
      expect(snapshot.users.map((u) => u.employeeId), contains('W7'));
    });

    test('no lookup at all when every expected id is already accounted for',
        () async {
      final lookups = <String>[];
      final transport = FakeGraphTransport(routeWithBackfill(lookups: lookups));
      final connector = connectorWith(transport);

      final snapshot =
          await connector.sync(expectedEmployeeIds: const ['W1001', 'S2001']);

      expect(lookups, isEmpty);
      expect(snapshot.users, hasLength(3));
    });

    test('an id the tenant has no account for changes nothing', () async {
      final transport = FakeGraphTransport(
        routeWithBackfill(lookups: <String>[], hits: const []),
      );
      final connector = connectorWith(transport);

      final snapshot = await connector.sync(expectedEmployeeIds: const ['W99']);
      expect(snapshot.users, hasLength(3));
    });

    test(
        'a Graph failure on the lookup logs and leaves the snapshot otherwise '
        'complete, rather than losing the whole pass', () async {
      GraphResponse failingLookup(GraphRequest req) {
        final filter = req.url.queryParameters[r'$filter'] ?? '';
        if (req.url.path.endsWith('/users') &&
            filter.startsWith('employeeId in')) {
          return graphError(400, 'Request_UnsupportedQuery', 'nope');
        }
        return route(req);
      }

      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: FakeGraphTransport(failingLookup),
        log: log,
      );

      final snapshot = await connector.sync(expectedEmployeeIds: const ['W7']);

      expect(snapshot.users, hasLength(3));
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');
      expect(
        log.errors.any((m) => m.contains('niet-gekoppelde employeeId(s)')),
        isTrue,
      );
      expect(log.errors.any((m) => m.contains('unmatched')), isFalse);
    });
  });

  group('an adopted record on the incremental path (#322)', () {
    /// The transfer as an earlier pass adopted her: our `employeeId`, no
    /// `companyName`, a `department` still naming the school she came from. No
    /// prefix-scoped read of ours returns her, and `_walkDelta` cannot keep a
    /// row about her either — the back-fill is the only leg that can.
    const adopted = AzureUser(
      id: 'az-transferred',
      upn: 'alfio.ambre@student.other.example',
      employeeId: 'W7',
      displayName: 'Alfio Ambre',
      department: 'OTHER-3A',
    );

    /// A student of ours, in step: both the bulk read and the walk see her.
    const ours = AzureUser(
      id: 'az-ours',
      upn: 'jane.doe@student.school.example',
      employeeId: 'W1',
      displayName: 'Jane Doe',
      companyName: 'GBS',
      department: '3C',
    );

    /// A staff member whose `department` lists us **second** (#237). The
    /// server-side `$filter` (`startswith`) misses her, but `belongsToSchool`
    /// keeps her, so the delta walk maintains her like any other account of
    /// ours and there is nothing for the back-fill to repair.
    const staff = AzureUser(
      id: 'az-staff',
      upn: 'anna.smit@school.example',
      employeeId: 'S9',
      displayName: 'Anna Smit',
      department: 'SSM,GBS',
    );

    /// Her account as Graph holds it *now*: somebody corrected the mangled
    /// name order and moved her into this year's class, before the token this
    /// session resumes from was minted.
    const Map<String, dynamic> ambreNow = <String, dynamic>{
      'id': 'az-transferred',
      'userPrincipalName': 'alfio.ambre@student.other.example',
      'employeeId': 'W7',
      'displayName': 'Ambre Alfio',
      'givenName': 'Alfio',
      'surname': 'Ambre',
      'department': 'OTHER-4B',
      'accountEnabled': true,
    };

    AzureSnapshot previousWith(List<AzureUser> users) => AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: users,
          groups: const [],
        );

    /// A pass where `/users/delta` reports **nothing at all** — the edit is
    /// older than our token, or an earlier walk dropped its row. [hits] is what
    /// the targeted `employeeId in (…)` lookup answers with; the bulk read
    /// answers empty and is counted, so a test can prove the pass really was
    /// the incremental one.
    GraphResponse Function(GraphRequest) silentWalk({
      required List<String> lookups,
      required List<String> bulkReads,
      List<Map<String, dynamic>> hits = const [ambreNow],
    }) =>
        (req) {
          final path = req.url.path;
          if (path.contains('/members') || path.contains('groups')) {
            return jsonOk({'value': const <Object>[]});
          }
          if (path.contains('users/delta')) {
            return jsonOk({
              '@odata.deltaLink':
                  'https://graph.microsoft.com/v1.0/users/delta?\$deltatoken=T2',
              'value': const <Object>[],
            });
          }
          final filter = req.url.queryParameters[r'$filter'] ?? '';
          if (filter.startsWith('employeeId in')) {
            lookups.add(filter);
            return jsonOk({'value': hits});
          }
          bulkReads.add(filter);
          return jsonOk({'value': const <Object>[]});
        };

    test(
        'it is re-read, so a drift no delta can report is repaired without a '
        'full read', () async {
      // The bug: `current` on an incremental pass is the *previous* user list
      // with the delta applied, so an adopted record marked its own id as
      // accounted for and the one leg that could refresh it never asked again.
      // A full read has no such blind spot — the record is simply absent from
      // the bulk result, so every full pass re-reads it — and this makes the
      // two legs agree.
      final lookups = <String>[];
      final bulkReads = <String>[];
      final connector = connectorWith(FakeGraphTransport(
        silentWalk(lookups: lookups, bulkReads: bulkReads),
      ));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [adopted, ours, staff]),
        expectedEmployeeIds: const ['W7', 'W1', 'S9'],
      );

      // Exactly the one id this pass could not read for itself. The student the
      // `$filter` covers and the staff member the walk maintains are still
      // never asked about, so the bounded pull (PAIN-2) stays bounded.
      expect(lookups, ["employeeId in ('W7')"]);
      expect(bulkReads, isEmpty, reason: 'still the incremental leg');

      final byId = {for (final u in snapshot.users) u.id: u};
      expect(
        byId['az-transferred'],
        const AzureUser(
          id: 'az-transferred',
          upn: 'alfio.ambre@student.other.example',
          employeeId: 'W7',
          displayName: 'Ambre Alfio',
          givenName: 'Alfio',
          surname: 'Ambre',
          department: 'OTHER-4B',
        ),
      );
      // …and nobody else moved.
      expect(byId['az-ours'], ours);
      expect(byId['az-staff'], staff);
    });

    test('a lookup that turns nothing up leaves the record standing', () async {
      // The snapshot's copy is the only one the app has. An empty answer is not
      // evidence the account is gone — Graph reports a deletion as an
      // `@removed` delta row, which `_applyDelta` already acts on.
      final lookups = <String>[];
      final connector = connectorWith(FakeGraphTransport(silentWalk(
        lookups: lookups,
        bulkReads: <String>[],
        hits: const [],
      )));

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [adopted]),
        expectedEmployeeIds: const ['W7'],
      );

      expect(lookups, ["employeeId in ('W7')"]);
      expect(snapshot.users.single, adopted);
    });

    test('a blank school prefix does not turn the whole snapshot into a lookup',
        () async {
      // `belongsToSchool` claims nobody for a blank prefix, so gating on it
      // without this guard would declare every record unaccounted for and ask
      // Graph about every expected id at once — unbounding the pull over a
      // school that is merely unconfigured.
      final lookups = <String>[];
      final connector = connectorWith(FakeGraphTransport(
        silentWalk(lookups: lookups, bulkReads: <String>[], hits: const []),
      ));

      await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: previousWith(const [adopted, ours, staff]),
        expectedEmployeeIds: const ['W7', 'W1', 'S9'],
        schoolPrefix: '',
      );

      expect(lookups, isEmpty);
    });
  });

  group('class-group back-fill by mailNickname (#280)', () {
    /// One Graph `/groups` row for the class group of #280: it still answers on
    /// `GBS-5WW1`, but its display name was renamed by hand, so
    /// `startswith(displayName,'GBS')` — the whole of `listGroups` — is blind to
    /// it forever.
    const Map<String, dynamic> renamed = <String, dynamic>{
      'id': 'g-renamed',
      'displayName': 'Klas van juf An',
      'mail': 'GBS-5WW1@student.school.example',
      'mailNickname': 'GBS-5WW1',
    };

    /// [route], plus an answer for the targeted `mailNickname in (…)` lookup.
    GraphResponse Function(GraphRequest) routeWithGroupBackfill({
      required List<String> lookups,
      List<Map<String, dynamic>> hits = const [renamed],
    }) =>
        (req) {
          final filter = req.url.queryParameters[r'$filter'] ?? '';
          if (req.url.path.endsWith('/groups') &&
              filter.startsWith('mailNickname in')) {
            lookups.add(filter);
            return jsonOk({'value': hits});
          }
          return route(req);
        };

    test(
        'a full sync adopts the group the prefix-scoped list cannot see, asking '
        'only about the nicknames it could not account for', () async {
      final lookups = <String>[];
      final transport =
          FakeGraphTransport(routeWithGroupBackfill(lookups: lookups));
      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: transport,
        log: log,
      );

      // `groups.json` carries GBS-3A and GBS-Staff; GBS-5WW1 is the renamed one.
      final snapshot = await connector.sync(
        expectedGroupMailNicknames: const ['GBS-3A', 'GBS-5WW1'],
      );

      // The group already on the list was never asked about — the bounded pull
      // (PAIN-2) stays bounded.
      expect(lookups, ["mailNickname in ('GBS-5WW1')"]);
      // …and the invisible group is in the snapshot, so the linker can reach it.
      final adopted =
          snapshot.groups.singleWhere((g) => g.mailNickname == 'GBS-5WW1');
      expect(adopted.id, 'g-renamed');
      expect(adopted.displayName, 'Klas van juf An');
      expect(snapshot.groups, hasLength(3));
      expect(
        log.messages
            .any((m) => m.contains('1 bestaande klasgroep(en) overgenomen')),
        isTrue,
      );
    });

    test('an incremental sync adopts it too — the group read is the same one',
        () async {
      final lookups = <String>[];
      final transport =
          FakeGraphTransport(routeWithGroupBackfill(lookups: lookups));
      final connector = connectorWith(transport);

      final snapshot = await connector.sync(
        deltaToken: 'OLDTOKEN',
        previous: AzureSnapshot(
          fetchedAt: DateTime.utc(2026, 6, 1),
          deltaToken: 'OLDTOKEN',
          users: const [],
          groups: const [],
        ),
        expectedGroupMailNicknames: const ['GBS-5WW1'],
      );

      expect(lookups, ["mailNickname in ('GBS-5WW1')"]);
      expect(snapshot.groups.map((g) => g.id), contains('g-renamed'));
    });

    test(
        'a nickname the prefix-scoped list already answers on is not looked up',
        () async {
      final lookups = <String>[];
      final transport =
          FakeGraphTransport(routeWithGroupBackfill(lookups: lookups));
      final connector = connectorWith(transport);

      // `GBS-3A` is on the list by display name and carries no `mailNickname`
      // in the fixture at all — the linker can already reach it, so asking
      // Graph about its address would buy nothing.
      final snapshot =
          await connector.sync(expectedGroupMailNicknames: const ['GBS-3A']);

      expect(lookups, isEmpty);
      expect(snapshot.groups, hasLength(2));
    });

    test('a nickname the tenant has no group for changes nothing', () async {
      final transport = FakeGraphTransport(
        routeWithGroupBackfill(lookups: <String>[], hits: const []),
      );
      final connector = connectorWith(transport);

      final snapshot =
          await connector.sync(expectedGroupMailNicknames: const ['GBS-9Z']);
      expect(snapshot.groups, hasLength(2));
    });

    test(
        'a Graph failure on the lookup logs and leaves the snapshot otherwise '
        'complete, rather than losing the whole pass', () async {
      GraphResponse failingLookup(GraphRequest req) {
        final filter = req.url.queryParameters[r'$filter'] ?? '';
        if (req.url.path.endsWith('/groups') &&
            filter.startsWith('mailNickname in')) {
          return graphError(400, 'Request_UnsupportedQuery', 'nope');
        }
        return route(req);
      }

      final log = RecordingLog();
      final connector = AzureConnector(
        credentials: credentials,
        authProvider: const StaticAuthProvider('T'),
        transport: FakeGraphTransport(failingLookup),
        log: log,
      );

      final snapshot =
          await connector.sync(expectedGroupMailNicknames: const ['GBS-5WW1']);

      expect(snapshot.groups, hasLength(2));
      expect(snapshot.users, hasLength(3));
      expect(snapshot.deltaToken, 'PRIMEDTOKEN123');
      expect(
        log.errors.any((m) => m.contains('klasgroep-adres(sen) niet opzoeken')),
        isTrue,
      );
    });
  });
}
