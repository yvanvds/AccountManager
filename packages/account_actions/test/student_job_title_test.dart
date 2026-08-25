/// The Office 365 student licence needs **both** halves of one dynamic-group
/// rule (#358):
///
///     (user.companyName -eq "<PREFIX>") and (user.jobTitle -eq "LeerlingSec")
///
/// The port wrote `companyName` and never `jobTitle`, so every account it
/// created landed outside the group and stayed unlicensed. The legacy app wrote
/// the opposite half. This file pins the create writing both, and the repair
/// that fixes the accounts already in that state.
library;

import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  List<Type> types(Iterable<StudentAction> actions) =>
      actions.map((a) => a.runtimeType).toList();

  /// [ActionResult.azure] as the connector record it actually is —
  /// `account_core`'s interface carries only the linking keys, and `jobTitle`
  /// is one of the fields below it.
  az.AzureUser azureOf(ActionResult result) => result.azure! as az.AzureUser;

  /// A Graph transport that answers everything [AddStudentToAzure] asks on its
  /// way to a successful create: no account holds the WISA id, the projected UPN
  /// is free, and the POST is accepted.
  RecordingGraphTransport createTransport() => RecordingGraphTransport(
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
          if (req.method == 'POST') {
            return az.GraphResponse(
              statusCode: 201,
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'id': 'az-new',
                'userPrincipalName': 'jan.peeters@student.school.example',
              }),
            );
          }
          return const az.GraphResponse(statusCode: 204);
        },
      );

  group('AddStudentToAzure writes the job title on create (#358)', () {
    test('the POST body carries both halves of the licensing rule', () async {
      final transport = createTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      final post = transport.requests.singleWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body!) as Map<String, dynamic>;
      expect(body['companyName'], 'SSM');
      expect(body['jobTitle'], 'LeerlingSec',
          reason: 'without it the account never joins the licensing group');
      // …and the record spliced back into the snapshot says so too, so the
      // repair below is not raised against an account that was just created
      // correctly.
      expect(azureOf(result).jobTitle, 'LeerlingSec');
    });

    test('the change set names the field, so the operator sees it up front',
        () {
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);
      final change = action.describeChanges();
      expect(
        change.fields.singleWhere((f) => f.field == 'jobTitle').after,
        'LeerlingSec',
      );
    });

    test('the dry run projects it and writes nothing', () async {
      final transport = createTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);

      final result = await action.apply(connectors, ApplyOptions.dry);

      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(azureOf(result).jobTitle, 'LeerlingSec');
    });

    test('a basisschool writes its own value, not a hard-coded one', () async {
      final transport = createTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStudentToAzure(
        linked(wisa: wisaStudent()),
        StudentActionConfig(
          schoolPrefix: 'SSM',
          azureDomain: 'school.example',
          studentJobTitle: 'LeerlingBas',
          newAccountPassword: () => 'FakeP4ss!',
        ),
      );

      await action.apply(connectors, const ApplyOptions());

      final post = transport.requests.singleWhere((r) => r.method == 'POST');
      expect(
        (jsonDecode(post.body!) as Map<String, dynamic>)['jobTitle'],
        'LeerlingBas',
      );
    });
  });

  group('ModifyAzureJobTitle repairs a linked student (#358)', () {
    test('a mismatch produces the repair action, and only it', () {
      // The moved-up pupil the live audit found: created years ago by a
      // basisschool, still stamped `LeerlingBas`, holding no licence.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: 'LeerlingBas'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureJobTitle]);
      final change = actions.single.describeChanges();
      expect(change.system, Origin.azure);
      expect(change.fields.single.before, 'LeerlingBas');
      expect(change.fields.single.after, 'LeerlingSec');
    });

    test('a blank job title fires it too — the state this port creates', () {
      // The bug's own footprint. A repair that refused to fire on an unset field
      // would leave every account the port ever made unlicensed forever, the
      // same self-perpetuating shape #224 fixed for `companyName`.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: null),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureJobTitle]);
      expect(actions.single.describeChanges().fields.single.before, isNull);
    });

    test('a match produces nothing', () {
      expect(
        studentActionsFor(
          linked(
            wisa: wisaStudent(),
            smartschool: ssAccount(),
            azure: azureUser(jobTitle: 'LeerlingSec'),
          ),
          cfg,
        ),
        isEmpty,
      );
    });

    test('the comparison is case-insensitive and trimmed (INV-12)', () {
      expect(
        studentActionsFor(
          linked(
            wisa: wisaStudent(),
            smartschool: ssAccount(),
            azure: azureUser(jobTitle: ' leerlingsec '),
          ),
          cfg,
        ),
        isEmpty,
      );
    });

    test('it PATCHes jobTitle alone and returns the mutated record', () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureJobTitle(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: 'LeerlingBas'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.azure);
      final patch = transport.requests.singleWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, contains('az-1'));
      expect(
        jsonDecode(patch.body!),
        <String, dynamic>{'jobTitle': 'LeerlingSec'},
        reason: 'a one-field correction, not a rewrite of the record',
      );
      expect(azureOf(result).jobTitle, 'LeerlingSec');
      // Everything else on the record is left exactly as it was.
      expect(azureOf(result).companyName, 'SSM');
      expect(azureOf(result).department, '3A');
    });

    test('the dry run writes nothing and projects the corrected record',
        () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureJobTitle(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: null),
        ),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);

      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(azureOf(result).jobTitle, 'LeerlingSec');
    });

    test('it writes the configured value, never one derived from the prefix',
        () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureJobTitle(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: 'LeerlingSec'),
        ),
        StudentActionConfig(
          schoolPrefix: 'SSM',
          azureDomain: 'school.example',
          studentJobTitle: 'LeerlingBas',
          newAccountPassword: () => 'FakeP4ss!',
        ),
      );

      // Same prefix, different kind of school — so the account that is in step
      // for a secondary school is the one that needs repairing here.
      expect(action.evaluate(), isTrue);
      await action.apply(connectors, const ApplyOptions());
      final patch = transport.requests.singleWhere((r) => r.method == 'PATCH');
      expect(
        jsonDecode(patch.body!),
        <String, dynamic>{'jobTitle': 'LeerlingBas'},
      );
    });
  });

  group('the repair is derived from WISA, never from companyName (#358)', () {
    test('an Azure-only orphan carrying our prefix is never re-stamped', () {
      // The regression this guards: 20 accounts in the live tenant carry
      // `LeerlingBas` **under our prefix**. Stamping `LeerlingSec` on everything
      // that carries the prefix would hand genuine basisschool pupils a
      // secondary licence they are not entitled to. WISA is the authority, so
      // the repair only ever reaches the modify branch — which an orphan with no
      // WISA row cannot enter.
      final actions = studentActionsFor(
        linked(azure: azureUser(companyName: 'SSM', jobTitle: 'LeerlingBas')),
        cfg,
      );
      expect(actions.whereType<ModifyAzureJobTitle>(), isEmpty);
      expect(types(actions), [RemoveStudentFromAzure]);
    });

    test('a student who left our school for a sibling one is left alone', () {
      // Still in the group's WISA, so their Azure account is kept (#134) — but
      // they are no longer ours to classify, and the lifecycle branch they fall
      // to carries no field repairs at all.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(jobTitle: 'LeerlingBas'),
          wisaPresence: WisaPresence.groupOnly,
        ),
        cfg,
      );
      expect(actions.whereType<ModifyAzureJobTitle>(), isEmpty);
    });

    test('a half-provisioned student gets the create, not the repair', () {
      // No Smartschool account yet, so the record is incomplete: the lifecycle
      // branch runs and the job title rides along on the Azure create instead.
      final actions = studentActionsFor(
        linked(wisa: wisaStudent(), azure: azureUser(jobTitle: null)),
        cfg,
      );
      expect(actions.whereType<ModifyAzureJobTitle>(), isEmpty);
      expect(types(actions), [AddStudentToSmartschool]);
    });
  });
}
