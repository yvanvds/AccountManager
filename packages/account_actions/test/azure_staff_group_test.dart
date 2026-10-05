import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The Office 365 staff group `<PREFIX>-Personeel` (#444): the seat
/// `AddStaffToAzure` performs after its create, and the standing repair
/// `AddStaffToAzureStaffGroup` (legacy `AddToStaffGroup`) with its
/// Exchange-mastered counterpart `AzureStaffGroupNotManageable`.
///
/// The placement arrives injected, exactly as `StaffPlacement` does, so these
/// tests drive the actions straight from one; the State layer test
/// (`account_state/test/azure_staff_groups_test.dart`) covers resolving it from
/// a real Azure snapshot.
void main() {
  final cfg = staffConfig();

  List<StaffAction> dispatch(
    LinkedStaff staff,
    AzureStaffGroupPlacement? placement,
  ) =>
      staffActionsFor(
        staff,
        cfg,
        azureGroupPlacementFor: placement == null ? null : (_) => placement,
      );

  /// `POST /groups/<id>/members/$ref` — one membership write.
  bool isMemberAdd(az.GraphRequest r) =>
      r.method == 'POST' && r.url.path.contains('/members/');

  /// The group ids the recorded membership writes were addressed to.
  List<String> joinedGroups(RecordingGraphTransport t) => <String>[
        for (final r in t.requests.where(isMemberAdd))
          RegExp(r'/groups/([^/]+)/members/').firstMatch(r.url.path)!.group(1)!,
      ];

  /// The directory object each recorded membership write added.
  List<String> addedMembers(RecordingGraphTransport t) => <String>[
        for (final r in t.requests.where(isMemberAdd))
          ((jsonDecode(r.body!) as Map<String, dynamic>)['@odata.id'] as String)
              .split('/')
              .last,
      ];

  az.GraphResponse refusal() => az.GraphResponse(
        statusCode: 400,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'error': {
            'code': 'Request_BadRequest',
            'message': 'Adding members is not supported for this group.',
          },
        }),
      );

  group('azureStaffGroupName — built from the prefix, never hard-coded', () {
    test('<PREFIX>-Personeel', () {
      expect(azureStaffGroupName('SSM'), 'SSM-Personeel');
      expect(azureStaffGroupName(' GBS '), 'GBS-Personeel');
    });

    test('a blank prefix names no group at all', () {
      expect(azureStaffGroupName(''), isNull);
      expect(azureStaffGroupName('   '), isNull);
      expect(azureStaffGroupName(null), isNull);
    });
  });

  group('dispatch: who is offered the membership', () {
    test('a colleague of ours outside the group gets the bulk-applyable write',
        () {
      final actions = dispatch(fullySyncedStaff(), azureStaffGroupPlacement());

      final join = actions.whereType<AddStaffToAzureStaffGroup>().single;
      expect(join.canApply, isTrue);
      expect(join.canApplyToAll, isTrue,
          reason: 'legacy AddToStaffGroup(…, true, true)');
      expect(actions.whereType<AzureStaffGroupNotManageable>(), isEmpty);
      expect(actions, hasLength(1),
          reason: 'a fully synced record owes nothing else');
    });

    test('a member of the group is offered nothing', () {
      final actions = dispatch(
        fullySyncedStaff(),
        azureStaffGroupPlacement(memberOf: {'az-personeel-team'}),
      );
      expect(actions, isEmpty);
    });

    test('a teacher who belongs only to a sibling school is left alone', () {
      final sibling = linkedStaff(
        wisa: wisaStaff(),
        smartschool: ssStaff(),
        azure: azureStaff(),
        wisaPresence: WisaPresence.groupOnly,
      );
      expect(
        dispatch(sibling, azureStaffGroupPlacement()).where((a) =>
            a is AddStaffToAzureStaffGroup ||
            a is AzureStaffGroupNotManageable),
        isEmpty,
      );
      // And the action itself agrees, whichever branch it is handed to.
      expect(
        AddStaffToAzureStaffGroup(sibling, cfg, azureStaffGroupPlacement())
            .evaluate(),
        isFalse,
      );
    });

    test('nobody is offered anything when the group does not exist', () {
      final actions = dispatch(
        fullySyncedStaff(),
        azureStaffGroupPlacement(groups: const []),
      );
      expect(actions, isEmpty,
          reason: 'a missing group is the tenant\'s problem, logged once — not '
              'one action per teacher');
    });

    test('no prefix, no group, no action', () {
      final actions = dispatch(
        fullySyncedStaff(),
        azureStaffGroupPlacement(groupName: null, groups: const []),
      );
      expect(actions, isEmpty);
    });

    test('without the placement the dispatch is exactly as before #444', () {
      expect(dispatch(fullySyncedStaff(), null), isEmpty);
    });

    test('a staff member with no Office 365 account has nothing to add yet',
        () {
      final actions = dispatch(
        linkedStaff(wisa: wisaStaff(), smartschool: ssStaff()),
        azureStaffGroupPlacement(),
      );
      expect(actions.whereType<AddStaffToAzureStaffGroup>(), isEmpty);
    });

    test('both groups of the name are enforced: only the missing one is joined',
        () {
      final placement = azureStaffGroupPlacement(
        groups: [azureStaffSecurityGroup(), azureStaffTeamGroup()],
        memberOf: {'az-personeel-sec'},
      );
      final join = dispatch(fullySyncedStaff(), placement)
          .whereType<AddStaffToAzureStaffGroup>()
          .single;
      expect(placement.joinableGroups.map((g) => g.id), ['az-personeel-team']);
      expect(join.evaluate(), isTrue);
    });

    test(
        'an Exchange-mastered group is diagnosed, never written — the notice '
        'stands alone when it is the only gap', () {
      final actions = dispatch(
        fullySyncedStaff(),
        azureStaffGroupPlacement(
            groups: [azureStaffMailEnabledSecurityGroup()]),
      );
      expect(actions.whereType<AddStaffToAzureStaffGroup>(), isEmpty);
      final notice = actions.whereType<AzureStaffGroupNotManageable>().single;
      expect(notice.canApply, isFalse);
      expect(notice.canApplyToAll, isFalse);
    });

    test(
        'a manageable and an Exchange-mastered gap raise one write and one '
        'notice', () {
      final actions = dispatch(
        fullySyncedStaff(),
        azureStaffGroupPlacement(groups: [
          azureStaffMailEnabledSecurityGroup(),
          azureStaffTeamGroup(),
        ]),
      );
      expect(actions.map((a) => a.runtimeType), [
        AddStaffToAzureStaffGroup,
        AzureStaffGroupNotManageable,
      ]);
    });
  });

  group('describeChanges: the group name and whether the account is in it', () {
    test('one line per group of the name, with its kind and membership', () {
      final changes = AddStaffToAzureStaffGroup(
        fullySyncedStaff(),
        cfg,
        azureStaffGroupPlacement(
          groups: [
            azureStaffSecurityGroup(),
            azureStaffTeamGroup(),
            azureStaffMailEnabledSecurityGroup(),
          ],
          memberOf: {'az-personeel-sec'},
        ),
      ).describeChanges();

      expect(changes.system, Origin.azure);
      expect(changes.summary,
          'Voeg het account toe aan de Office 365-groep SSM-Personeel');
      expect(changes.fields.map((f) => f.field), [
        'lid van SSM-Personeel (beveiligingsgroep)',
        'lid van SSM-Personeel (Microsoft 365-groep)',
        'lid van SSM-Personeel (mail-enabled beveiligingsgroep)',
      ]);
      // Already a member: stated, not moved.
      expect(changes.fields[0].shape, FieldChangeShape.statement);
      expect(changes.fields[0].before, 'ja');
      // The write this action performs.
      expect(changes.fields[1].shape, FieldChangeShape.transition);
      expect(changes.fields[1].before, 'nee');
      expect(changes.fields[1].after, 'ja');
      // Missing, but not ours to write.
      expect(changes.fields[2].shape, FieldChangeShape.statement);
      expect(changes.fields[2].before, contains('Exchange Online'));
    });

    test('the Exchange notice names the group, its kind, and where to go', () {
      final changes = AzureStaffGroupNotManageable(
        fullySyncedStaff(),
        cfg,
        azureStaffGroupPlacement(
            groups: [azureStaffMailEnabledSecurityGroup()]),
      ).describeChanges();
      expect(changes.summary, contains('SSM-Personeel'));
      expect(changes.summary, contains('mail-enabled beveiligingsgroep'));
      expect(changes.summary, contains('Exchange Online'));
      expect(
        changes.fields.every((f) => f.shape == FieldChangeShape.statement),
        isTrue,
        reason: 'nothing is written, so nothing moves',
      );
    });
  });

  group('AddStaffToAzureStaffGroup.apply', () {
    AddStaffToAzureStaffGroup join(AzureStaffGroupPlacement placement) =>
        AddStaffToAzureStaffGroup(fullySyncedStaff(), cfg, placement);

    test('dry run → no Graph call, nothing joined', () async {
      final transport = RecordingGraphTransport();
      final result = await join(azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(result.joinedAzureGroupIds, isEmpty);
    });

    test('adds the account to the group and names the group it joined',
        () async {
      final transport = RecordingGraphTransport();
      final result = await join(azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.azure);
      expect(joinedGroups(transport), ['az-personeel-team']);
      expect(addedMembers(transport), ['az-s1']);
      expect(result.joinedAzureGroupIds, ['az-personeel-team']);
      expect(result.azure?.id, 'az-s1',
          reason: 'the unchanged account says whose membership this is');
      expect(result.warnings, isEmpty);
    });

    test('joins every manageable group it is missing from, and only those',
        () async {
      final transport = RecordingGraphTransport();
      final result = await join(azureStaffGroupPlacement(groups: [
        azureStaffSecurityGroup(),
        azureStaffMailEnabledSecurityGroup(),
        azureStaffTeamGroup(),
      ])).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(joinedGroups(transport), ['az-personeel-sec', 'az-personeel-team'],
          reason: 'never the Exchange-mastered one: Graph refuses it');
      expect(result.joinedAzureGroupIds,
          ['az-personeel-sec', 'az-personeel-team']);
    });

    test('a partial refusal keeps the join that landed and warns', () async {
      final transport = RecordingGraphTransport(
        handler: (r) => r.url.path.contains('az-personeel-sec')
            ? refusal()
            : const az.GraphResponse(statusCode: 204),
      );
      final result = await join(azureStaffGroupPlacement(groups: [
        azureStaffSecurityGroup(),
        azureStaffTeamGroup(),
      ])).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied,
          reason: 'the Team join is real and must reach the snapshot');
      expect(result.joinedAzureGroupIds, ['az-personeel-team']);
      expect(result.warnings.single, contains('beveiligingsgroep'));
      expect(result.warnings.single, contains('Request_BadRequest'));
    });

    test('nothing landing is a failure, naming the group and Graph\'s reason',
        () async {
      final transport = RecordingGraphTransport(handler: (_) => refusal());
      final result = await join(azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.failed);
      expect(result.joinedAzureGroupIds, isEmpty);
      expect('${result.error}', contains('SSM-Personeel'));
      expect('${result.error}', contains('Request_BadRequest'));
    });

    test('the Exchange notice cannot be applied', () {
      final notice = AzureStaffGroupNotManageable(
        fullySyncedStaff(),
        cfg,
        azureStaffGroupPlacement(
            groups: [azureStaffMailEnabledSecurityGroup()]),
      );
      expect(
        () => notice.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });
  });

  group('AddStaffToAzure joins the new account to the staff group', () {
    /// Graph for an empty tenant that accepts the create and, unless
    /// [refuseJoin], the membership write.
    RecordingGraphTransport tenant({bool refuseJoin = false}) =>
        RecordingGraphTransport(
          handler: (req) {
            if (req.method == 'GET' &&
                (req.url.queryParameters[r'$filter'] ?? '')
                    .startsWith('employeeId in')) {
              return az.GraphResponse(
                statusCode: 200,
                headers: const {'content-type': 'application/json'},
                body: jsonEncode({'value': const <Object>[]}),
              );
            }
            if (req.method == 'GET') {
              return az.GraphResponse(
                statusCode: 404,
                body: jsonEncode({
                  'error': {'code': 'NotFound', 'message': 'no'},
                }),
              );
            }
            if (isMemberAdd(req)) {
              return refuseJoin
                  ? refusal()
                  : const az.GraphResponse(statusCode: 204);
            }
            if (req.method == 'POST') {
              return az.GraphResponse(
                statusCode: 201,
                headers: const {'content-type': 'application/json'},
                body: jsonEncode({
                  'id': 'az-new',
                  'userPrincipalName': 'anna.smit@school.example',
                }),
              );
            }
            return const az.GraphResponse(statusCode: 204);
          },
        );

    AddStaffToAzure create({
      AzureStaffGroupPlacement? placement,
      WisaPresence presence = WisaPresence.ours,
    }) =>
        AddStaffToAzure(
          linkedStaff(wisa: wisaStaff(), wisaPresence: presence),
          cfg,
          azureGroupPlacement: placement,
        );

    test('the created account is added to <PREFIX>-Personeel right after',
        () async {
      final transport = tenant();
      final result = await create(placement: azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.azure?.id, 'az-new');
      // The create first, then the seat — addressed to the account Graph just
      // minted, not to a projection.
      final posts = transport.requests.where((r) => r.method == 'POST');
      expect(posts.first.url.path, endsWith('/users'));
      expect(joinedGroups(transport), ['az-personeel-team']);
      expect(addedMembers(transport), ['az-new']);
      expect(result.joinedAzureGroupIds, ['az-personeel-team']);
      expect(result.warnings, isEmpty);
      expect(result.generatedPassword, isNotNull);
    });

    test('the confirmation names the group the create will join', () {
      final fields = create(placement: azureStaffGroupPlacement())
          .describeChanges()
          .fields;
      expect(
        fields
            .where((f) => f.field.startsWith('Office 365-groep'))
            .single
            .after,
        'SSM-Personeel',
      );
    });

    test('a missing group warns, and the account is still created', () async {
      final transport = tenant();
      final result = await create(
        placement: azureStaffGroupPlacement(groups: const []),
      ).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.azure?.id, 'az-new');
      expect(transport.requests.where(isMemberAdd), isEmpty);
      expect(result.joinedAzureGroupIds, isEmpty);
      expect(result.warnings.single, contains('SSM-Personeel'));
      expect(result.warnings.single, contains('bestaat niet'));
    });

    test(
        'an Exchange-mastered group is not written to, and the warning says '
        'where to go', () async {
      final transport = tenant();
      final result = await create(
        placement: azureStaffGroupPlacement(
          groups: [azureStaffMailEnabledSecurityGroup()],
        ),
      ).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(transport.requests.where(isMemberAdd), isEmpty);
      expect(result.warnings.single, contains('Exchange Online'));
    });

    test('a refused join warns, and the create still succeeds (INV-41)',
        () async {
      final transport = tenant(refuseJoin: true);
      final result = await create(placement: azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied,
          reason: 'the create is the success criterion');
      expect(result.azure?.id, 'az-new');
      expect(result.joinedAzureGroupIds, isEmpty,
          reason: 'a refused join seated nobody, so it may claim nothing');
      expect(result.warnings.single, contains('SSM-Personeel'));
      expect(result.warnings.single, contains('Request_BadRequest'));
    });

    test('no placement → the account is created and joins nothing', () async {
      final transport = tenant();
      final result = await create().apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.requests.where(isMemberAdd), isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('a sibling school\'s teacher is never put in our staff group',
        () async {
      final transport = tenant();
      final result = await create(
        placement: azureStaffGroupPlacement(),
        presence: WisaPresence.groupOnly,
      ).apply(
          Connectors(azure: azureConnector(transport)), const ApplyOptions());
      expect(transport.requests.where(isMemberAdd), isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('dry run → no writes at all, nothing joined', () async {
      final transport = tenant();
      final result = await create(placement: azureStaffGroupPlacement()).apply(
          Connectors(azure: azureConnector(transport)), ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(result.joinedAzureGroupIds, isEmpty);
    });
  });
}
