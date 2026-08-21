import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// Graph replies for the class-group writes: an empty `mailNickname` lookup
/// (nothing exists yet), an echoed create, and `204` for the `$batch`
/// membership calls.
az.GraphResponse _classGroupGraph(az.GraphRequest request) {
  if (request.method == 'GET') {
    return az.GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'value': const <Object>[]}),
    );
  }
  if (request.method == 'POST' && request.url.path.endsWith(r'/$batch')) {
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    final requests = (body['requests'] as List).cast<Map<String, dynamic>>();
    return az.GraphResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'responses': [
          for (final r in requests) {'id': r['id'], 'status': 204},
        ],
      }),
    );
  }
  if (request.method == 'POST' && request.url.path.endsWith('/groups')) {
    final body = Map<String, dynamic>.from(
      jsonDecode(request.body!) as Map<String, dynamic>,
    );
    return az.GraphResponse(
      statusCode: 201,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        ...body,
        'id': 'az-created',
        'mail': '${body['mailNickname']}@student.school.example',
      }),
    );
  }
  return const az.GraphResponse(statusCode: 204);
}

void main() {
  group('dispatch: one proposal per class, never per sub-group (#228)', () {
    test('a class with no Office 365 group raises the create', () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup(), smartschool: ssGroup()),
        azurePlanFor: (_) => azurePlan(),
      );
      expect(actions.map((a) => a.runtimeType), [CreateAzureClassGroup]);
      expect(actions.single.canApply, isTrue);
      expect(
        actions.single.describeChanges().summary,
        'Maak de Office 365-groep SSM-3A voor klas 3A',
      );
    });

    test('the create rides alongside the Smartschool lifecycle actions', () {
      // A WISA-only class needs both: a Smartschool class *and* its Office 365
      // group. The two families are orthogonal, so neither branch swallows the
      // other.
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: true),
        azurePlanFor: (_) => azurePlan(),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromWisa, AddToSmartschool, CreateAzureClassGroup],
      );
    });

    test('a sub-group record that does not own the class raises nothing', () {
      // `3A ECO` maps to the same group as `3A`; only the nominated owner
      // proposes the create, so the operator sees one row and not four.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '3A ECO'),
          smartschool: ssGroup(code: '3A ECO', name: '3A ECO'),
          className: '3A',
        ),
        azurePlanFor: (_) => azurePlan(owner: false),
      );
      expect(actions, isEmpty);
    });

    test('an empty class gets no group, mirroring CreateInSmartschool', () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup(), smartschool: ssGroup()),
        azurePlanFor: (_) => azurePlan(containsStudents: false),
      );
      expect(actions, isEmpty);
    });

    test('a class whose group already exists raises no create', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A'),
        ),
        azurePlanFor: (_) => azurePlan(),
      );
      expect(actions, isEmpty);
    });

    test('no plan at all ⇒ the dispatch is exactly as it was before #228', () {
      expect(groupActionsFor(fullySyncedGroup()), isEmpty);
      expect(
        groupActionsFor(
          linkedGroup(wisa: wisaGroup()),
          placementFor: (_) => groupPlacement(containsStudents: true),
        ).map((a) => a.runtimeType),
        [DoNotImportFromWisa, AddToSmartschool],
      );
    });
  });

  group('creating a class group is one chain, not two clicks (#245)', () {
    test('the create declares the roster sync as its follow-up', () {
      // Graph creates a group empty — membership is a separate write — so the
      // dispatcher, a pure function of the current record, can only offer the
      // create. Naming the follow-up here is what lets the State layer run the
      // roster against the relinked record, which is the only place the id
      // Graph minted exists.
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup(), smartschool: ssGroup()),
        azurePlanFor: (_) => azurePlan(),
      );
      final create = actions.single as CreateAzureClassGroup;
      expect(create.unlocks, <Type>{SyncAzureClassGroupMembers});
    });

    test('the roster sync ends the chain', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A'),
        ),
        azurePlanFor: (_) => azurePlan(membersToAdd: const ['az-1']),
      );
      expect(actions.single.unlocks, isEmpty);
    });

    test('every other group action unlocks nothing', () {
      // The chain is opt-in per action; a stray declaration would make the
      // applier write beyond what the operator selected.
      final groups = <LinkedGroup>[
        linkedGroup(wisa: wisaGroup()),
        linkedGroup(smartschool: ssGroup()),
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(untis: 'stale'),
        ),
        linkedGroup(
          azure: azureClassGroup('9Z'),
          className: '9Z',
        ),
      ];
      for (final group in groups) {
        for (final action in groupActionsFor(
          group,
          placementFor: (_) => groupPlacement(),
          azurePlanFor: (_) => azurePlan(membersToAdd: const ['az-1']),
        )) {
          if (action is CreateAzureClassGroup) continue;
          expect(action.unlocks, isEmpty, reason: '${action.runtimeType}');
        }
      }
    });
  });

  group('membership follows the roster (#228)', () {
    test('a roster difference raises the membership sync', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A', memberIds: const ['az-old']),
        ),
        azurePlanFor: (_) => azurePlan(
          membersToAdd: const ['az-new'],
          membersToRemove: const ['az-old'],
        ),
      );
      expect(actions.map((a) => a.runtimeType), [SyncAzureClassGroupMembers]);
      expect(
        actions.single.describeChanges().summary,
        'Werk het ledenbestand van SSM-3A bij (1 toevoegen, 1 verwijderen)',
      );
    });

    test('membership in sync raises nothing', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A', memberIds: const ['az-1']),
        ),
        azurePlanFor: (_) => azurePlan(),
      );
      expect(actions, isEmpty);
    });

    test('the projected record adds and removes exactly the named members',
        () async {
      final action = SyncAzureClassGroupMembers(
        linkedGroup(
          wisa: wisaGroup(),
          azure: azureClassGroup(
            '3A',
            memberIds: const ['az-teacher', 'az-left', 'az-stays'],
          ),
        ),
        azurePlan(
          membersToAdd: const ['az-joined'],
          membersToRemove: const ['az-left'],
        ),
      );

      final result = await action.apply(
        const Connectors(),
        const ApplyOptions(dryRun: true),
      );

      expect(result.outcome, ActionOutcome.dryRun);
      expect(
        (result.azureGroup! as az.AzureGroup).memberIds,
        ['az-teacher', 'az-stays', 'az-joined'],
        reason: 'the teacher this app cannot account for is left alone',
      );
    });
  });

  group('apply writes through Graph (#228)', () {
    test('a create POSTs a unified group after asking for the nickname',
        () async {
      final transport = RecordingGraphTransport(handler: _classGroupGraph);
      final action = CreateAzureClassGroup(
        linkedGroup(wisa: wisaGroup(description: 'Klas 3A')),
        azurePlan(),
      );

      final result = await action.apply(
        Connectors(azure: azureConnector(transport)),
        const ApplyOptions(),
      );

      expect(result.outcome, ActionOutcome.applied);
      expect(transport.sent('GET', pathContains: '/groups'), isTrue,
          reason: 'guard before create (#224\'s rule)');
      final post = transport.requests
          .firstWhere((r) => r.method == 'POST' && r.body != null);
      final body = jsonDecode(post.body!) as Map<String, dynamic>;
      expect(body['displayName'], 'SSM-3A');
      expect(body['mailNickname'], 'SSM-3A');
      expect(body['description'], 'Klas 3A');
      expect(body['groupTypes'], ['Unified']);
      expect((result.azureGroup! as az.AzureGroup).id, 'az-created');
    });

    test('a dry run writes nothing but projects the group', () async {
      final transport = RecordingGraphTransport(handler: _classGroupGraph);
      final action = CreateAzureClassGroup(
        linkedGroup(wisa: wisaGroup()),
        azurePlan(),
      );

      final result = await action.apply(
        Connectors(azure: azureConnector(transport)),
        const ApplyOptions(dryRun: true),
      );

      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(result.azureGroup!.mail, 'SSM-3A@student.school.example');
    });

    test('a nickname Graph already knows fails instead of duplicating',
        () async {
      final transport = RecordingGraphTransport(
        handler: (request) {
          if (request.method == 'GET') {
            return az.GraphResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'value': [
                  {
                    'id': 'g-existing',
                    'displayName': 'SSM-3A',
                    'mailNickname': 'SSM-3A',
                  },
                ],
              }),
            );
          }
          return _classGroupGraph(request);
        },
      );
      final action = CreateAzureClassGroup(
        linkedGroup(wisa: wisaGroup()),
        azurePlan(),
      );

      final result = await action.apply(
        Connectors(azure: azureConnector(transport)),
        const ApplyOptions(),
      );

      expect(result.outcome, ActionOutcome.failed);
      expect('${result.error}', contains('already has a group'));
      expect(transport.sent('POST', pathContains: '/groups'), isFalse);
    });

    test('a membership sync batches the adds and the removes', () async {
      final transport = RecordingGraphTransport(handler: _classGroupGraph);
      final action = SyncAzureClassGroupMembers(
        linkedGroup(
          wisa: wisaGroup(),
          azure: azureClassGroup('3A', memberIds: const ['az-left']),
        ),
        azurePlan(
          membersToAdd: const ['az-joined'],
          membersToRemove: const ['az-left'],
        ),
      );

      final result = await action.apply(
        Connectors(azure: azureConnector(transport)),
        const ApplyOptions(),
      );

      expect(result.outcome, ActionOutcome.applied);
      final batches = transport.requests
          .where((r) => r.url.path.endsWith(r'/$batch'))
          .map((r) => jsonDecode(r.body!) as Map<String, dynamic>)
          .expand((b) => (b['requests'] as List).cast<Map<String, dynamic>>())
          .toList();
      expect(batches.map((r) => r['method']), ['POST', 'DELETE']);
      expect(
        (result.azureGroup! as az.AzureGroup).memberIds,
        ['az-joined'],
      );
    });
  });

  group('a vanished class is reported, never deleted (#228)', () {
    LinkedGroup orphan(az.AzureGroup group, {String? className = '9Z'}) =>
        linkedGroup(azure: group, className: className);

    test('an app-shaped class group with no class raises the notice', () {
      final actions = groupActionsFor(orphan(azureClassGroup('9Z')));
      expect(actions.map((a) => a.runtimeType), [AzureClassGroupWithoutClass]);
      final action = actions.single;
      expect(action.canApply, isFalse,
          reason: 'groups are never deleted automatically');
      expect(
        action.describeChanges().summary,
        contains('De klas 9Z bestaat niet meer'),
      );
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });

    test('a security group or a hand-made Team is left unmentioned', () {
      // Not mail-enabled ⇒ not a group this app created.
      expect(
        groupActionsFor(orphan(az.AzureGroup(
          id: 'g',
          displayName: 'SSM-9Z',
          securityEnabled: true,
        ))),
        isEmpty,
      );
      // Mail-enabled, but its nickname is not the display name — somebody made
      // it by hand.
      expect(
        groupActionsFor(orphan(az.AzureGroup(
          id: 'g',
          displayName: 'SSM-Wiskunde',
          mail: 'wiskunde@school.example',
          mailNickname: 'wiskunde',
        ))),
        isEmpty,
      );
      // Outside our `<PREFIX>-` namespace ⇒ the linker never recovered a class
      // name for it.
      expect(
        groupActionsFor(orphan(azureClassGroup('9Z'), className: null)),
        isEmpty,
      );
    });

    test('a class that still exists never raises the notice', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A'),
        ),
        azurePlanFor: (_) => azurePlan(),
      );
      expect(actions, isEmpty);
    });
  });

  group('purity (INV-40)', () {
    test('evaluate and describeChanges are deterministic', () {
      final group = linkedGroup(
        wisa: wisaGroup(),
        azure: azureClassGroup('3A', memberIds: const ['az-left']),
      );
      final plan = azurePlan(
        membersToAdd: const ['az-joined'],
        membersToRemove: const ['az-left'],
      );
      for (final action in <GroupAction>[
        CreateAzureClassGroup(group, plan),
        SyncAzureClassGroupMembers(group, plan),
      ]) {
        expect(action.evaluate(), action.evaluate());
        expect(
          action.describeChanges().summary,
          action.describeChanges().summary,
        );
      }
      // The bound record is untouched by evaluation.
      expect(
        (group.azure! as az.AzureGroup).memberIds,
        ['az-left'],
      );
    });
  });
}
