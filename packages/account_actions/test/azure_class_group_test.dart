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
        [AddToSmartschool, DoNotImportFromWisa, CreateAzureClassGroup],
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
        [AddToSmartschool, DoNotImportFromWisa],
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

    test('the create names the system its follow-up writes — its own (#234)',
        () {
      // The roster write lands in Office 365 too, so this chain reaches no
      // system the create does not already name and the confirmation dialog has
      // no second system to announce for it. Pinned against the follow-up's own
      // ChangeSet so the two cannot drift apart.
      final create = groupActionsFor(
        linkedGroup(wisa: wisaGroup(), smartschool: ssGroup()),
        azurePlanFor: (_) => azurePlan(),
      ).single as CreateAzureClassGroup;
      final followUp = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A'),
        ),
        azurePlanFor: (_) => azurePlan(membersToAdd: const ['az-1']),
      ).single as SyncAzureClassGroupMembers;
      expect(create.unlockedSystems, <Origin>{Origin.azure});
      expect(
          create.unlockedSystems, <Origin>{followUp.describeChanges().system});
      expect(create.unlockedSystems, <Origin>{create.describeChanges().system},
          reason: 'the chain stays inside Office 365');
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
      expect(actions.single.unlockedSystems, isEmpty);
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
          // …and so claims no second system on the confirmation dialog (#234).
          expect(action.unlockedSystems, isEmpty,
              reason: '${action.runtimeType}');
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

    test('the member numbers are counts, not before/after transitions (#300)',
        () {
      // The reported card read "leden toevoegen: ∅ → 21" — the diff template
      // claiming a field used to be empty and is becoming 21, which is not
      // what happens to anything. The numbers are quantities this write acts
      // on, and the description has to say so or every renderer repeats it.
      final fields = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          azure: azureClassGroup('3A', memberIds: const ['az-old']),
        ),
        azurePlanFor: (_) => azurePlan(
          membersToAdd: const ['az-new', 'az-second'],
          membersToRemove: const ['az-old'],
        ),
      ).single.describeChanges().fields;

      expect(
          fields.map((f) => f.field), ['leden toevoegen', 'leden verwijderen']);
      expect(fields.every((f) => f.shape == FieldChangeShape.count), isTrue);
      expect(fields.map((f) => f.after), ['2', '1']);
      expect(fields.every((f) => f.before == null), isTrue,
          reason: 'a count has no "before" half to diff against');
      expect(fields.first.toString(), 'FieldChange(leden toevoegen: 2)');
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
      // Dutch, and pointing at the one thing that resolves it — the Azure pull
      // now adopts a group by its nickname (#280), so "synchroniseer opnieuw"
      // is advice the operator can act on rather than a loop.
      expect('${result.error}',
          contains('Office 365 heeft al een groep op het adres SSM-3A'));
      expect('${result.error}', contains('Synchroniseer Azure opnieuw'));
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

  group('a vanished class: leave it standing, or delete it (#228/#271)', () {
    LinkedGroup orphan(az.AzureGroup group, {String? className = '9Z'}) =>
        linkedGroup(azure: group, className: className);

    test('an app-shaped class group with no class raises the either/or', () {
      final actions = groupActionsFor(orphan(azureClassGroup('9Z')));
      expect(
        actions.map((a) => a.runtimeType),
        [AzureClassGroupWithoutClass, DeleteAzureClassGroup],
        reason: 'the notice leads because it is the default of the pair',
      );
      expect(
        actions.map((a) => a.alternativeGroup),
        everyElement(staleClassGroupAlternative),
        reason: 'one choice, two radios — never two independent to-dos',
      );
    });

    test('the notice is the informational default, and never writes', () {
      final notice = groupActionsFor(orphan(azureClassGroup('9Z')))
          .whereType<AzureClassGroupWithoutClass>()
          .single;

      expect(notice.canApply, isFalse);
      expect(notice.isDefaultAlternative, isTrue,
          reason: 'a bulk apply over stale groups must write nothing at all');
      expect(
        notice.describeChanges().summary,
        'Laat de Office 365-groep SSM-9Z staan — klas 9Z bestaat niet meer '
        'in WISA of Smartschool',
      );
      expect(
        () => notice.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });

    test('the delete is applyable but never the default (#271)', () {
      final delete = groupActionsFor(orphan(azureClassGroup('9Z')))
          .whereType<DeleteAzureClassGroup>()
          .single;

      expect(delete.canApply, isTrue);
      expect(delete.isDefaultAlternative, isFalse,
          reason: 'deleting takes the mailbox, the Team and the files with it');
      expect(
        delete.describeChanges().summary,
        'Verwijder de Office 365-groep SSM-9Z van de verdwenen klas 9Z',
      );
      expect(
        delete.describeChanges().fields.map((f) => f.field),
        contains('postvak, Teams en bestanden'),
      );
      expect(delete.unlocks, isEmpty, reason: 'nothing follows a delete');
    });

    test('both halves state the group\'s facts, they do not diff them (#305)',
        () {
      // The notice's whole content is "this group stays", and under that
      // heading its two fields read "mail: SSM-9Z@… → ∅" and "leden: 21 → ∅" —
      // the address and the 21 members being cleared, which is what the *other*
      // radio does. Neither field is a value moving anywhere, so neither may be
      // described as one.
      final actions = groupActionsFor(
        orphan(azureClassGroup('9Z',
            memberIds: List<String>.generate(21, (int i) => 'az-$i'))),
      );

      final notice = actions
          .whereType<AzureClassGroupWithoutClass>()
          .single
          .describeChanges();
      expect(notice.fields.map((f) => f.field), ['mail', 'leden']);
      expect(
        notice.fields.every((f) => f.shape == FieldChangeShape.statement),
        isTrue,
        reason: 'a notice that writes nothing cannot describe a transition',
      );
      expect(notice.fields.map((f) => f.before),
          ['SSM-9Z@student.school.example', '21']);
      expect(notice.fields.every((f) => f.after == null), isTrue,
          reason: 'a statement has no half to move to');

      // The delete's arrow at least pointed at a real deletion, but its three
      // fields are still the inventory of what goes, not three fields being
      // cleared one by one — least of all "verdwijnen mee", never a value.
      final delete =
          actions.whereType<DeleteAzureClassGroup>().single.describeChanges();
      expect(delete.fields.map((f) => f.field),
          ['mail', 'leden', 'postvak, Teams en bestanden']);
      expect(
        delete.fields.every((f) => f.shape == FieldChangeShape.statement),
        isTrue,
      );
      expect(delete.fields.last.before, 'verdwijnen mee');
    });

    test('applying the delete asks Graph to delete that one group', () async {
      final transport = RecordingGraphTransport(handler: _classGroupGraph);
      final delete = DeleteAzureClassGroup(
        orphan(azureClassGroup('9Z', id: 'az-stale')),
      );

      final result = await delete.apply(
        Connectors(azure: azureConnector(transport)),
        const ApplyOptions(),
      );

      expect(result.outcome, ActionOutcome.applied);
      expect(result.removed, isTrue,
          reason: 'the State layer drops it from the snapshot');
      expect(result.azureGroup, isNull);
      final deletes =
          transport.requests.where((r) => r.method == 'DELETE').toList();
      expect(deletes, hasLength(1));
      expect(deletes.single.url.path, endsWith('/groups/az-stale'));
    });

    test('a dry run of the delete writes nothing', () async {
      final transport = RecordingGraphTransport(handler: _classGroupGraph);
      final delete = DeleteAzureClassGroup(
        orphan(azureClassGroup('9Z', id: 'az-stale')),
      );

      final result = await delete.apply(
        Connectors(azure: azureConnector(transport)),
        ApplyOptions.dry,
      );

      expect(result.outcome, ActionOutcome.dryRun);
      expect(result.removed, isTrue);
      expect(transport.sent('DELETE'), isFalse);
    });

    test('a group whose name is not class-shaped raises no delete (#271)', () {
      // The linker refuses to orphan these since #271, but a delete must not
      // inherit its scope from a filter one layer away.
      for (final name in const ['GOK', 'OKAN', 'Leerlingenraad', 'Personeel']) {
        final actions = groupActionsFor(
          orphan(azureClassGroup(name), className: name),
        );
        expect(actions, isEmpty,
            reason: '$name is not a class — and both halves move together');
      }
    });

    test('a record naming no Azure object id raises no delete (#271)', () {
      final actions = groupActionsFor(orphan(azureClassGroup('9Z', id: ' ')));
      expect(actions.whereType<AzureClassGroupWithoutClass>(), hasLength(1));
      expect(actions.whereType<DeleteAzureClassGroup>(), isEmpty,
          reason: 'there is nothing to address the DELETE to');
    });

    test(
        'a class group the legacy app created raises the pair too — it is no '
        'less stale for being a security group (#312)', () {
      // The reported bug. The `SSM-3ECO`-shaped groups in the live tenant are
      // plain security groups carrying no address at all, made by the WPF app
      // long before this port existed. `isUnified` is false for every one of
      // them, so the whole either/or went silent and each row was inventory
      // with an instruction to go elsewhere — the state #271 set out to remove.
      final actions = groupActionsFor(orphan(az.AzureGroup(
        id: 'g-legacy',
        displayName: 'SSM-9Z',
        securityEnabled: true,
        mailNickname: 'SSM-9Z',
      )));

      expect(
        actions.map((a) => a.runtimeType),
        [AzureClassGroupWithoutClass, DeleteAzureClassGroup],
        reason: 'the delete may not be limited to groups this port created',
      );
      expect(
        actions.map((a) => a.alternativeGroup),
        everyElement(staleClassGroupAlternative),
        reason: 'widened together, so the delete is never a lone reading',
      );
    });

    test('a group with no address states only the facts it has (#312)', () {
      final actions = groupActionsFor(orphan(az.AzureGroup(
        id: 'g-legacy',
        displayName: 'SSM-9Z',
        securityEnabled: true,
        mailNickname: 'SSM-9Z',
        memberIds: const ['az-1', 'az-2'],
      )));

      expect(
        actions
            .whereType<AzureClassGroupWithoutClass>()
            .single
            .describeChanges()
            .fields
            .map((f) => f.field),
        ['leden'],
        reason: 'a security group has no mail, and `mail: ` states nothing',
      );
      expect(
        actions
            .whereType<DeleteAzureClassGroup>()
            .single
            .describeChanges()
            .fields
            .map((f) => f.field),
        ['leden', 'postvak, Teams en bestanden'],
      );
    });

    test('a class group renamed by hand is still a stale class group (#312)',
        () {
      // The linker recovered `9Z` from the **nickname** (#280) — the address is
      // what makes a group ours and the display name is not to be trusted.
      // Requiring the two to be equal re-derived the opposite, stricter rule.
      final actions = groupActionsFor(orphan(az.AzureGroup(
        id: 'g-renamed',
        displayName: 'Klas van juf An',
        mail: 'SSM-9Z@student.school.example',
        mailNickname: 'SSM-9Z',
      )));

      expect(
        actions.map((a) => a.runtimeType),
        [AzureClassGroupWithoutClass, DeleteAzureClassGroup],
      );
    });

    test('a group the linker recovered no class name for is left unmentioned',
        () {
      // Outside our `<PREFIX>-` namespace ⇒ no class name was ever stamped on
      // the record, so there is nothing here to call stale.
      expect(
        groupActionsFor(orphan(azureClassGroup('9Z'), className: null)),
        isEmpty,
      );
      // Prefixed, but the remainder is a subject and not a class.
      expect(
        groupActionsFor(orphan(
          az.AzureGroup(
            id: 'g',
            displayName: 'SSM-Wiskunde',
            mail: 'wiskunde@school.example',
            mailNickname: 'SSM-Wiskunde',
          ),
          className: 'Wiskunde',
        )),
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
