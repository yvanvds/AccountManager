/// A student's Azure `department` holds their class group, and until #359 it
/// was written once — at account creation — and never again. Accounts in the
/// live tenant still name the class their holder left years ago, basisschool
/// classes on secondary pupils among them.
///
/// This file pins the repair, and the two rules that keep it safe: it may only
/// ever be derived from a **linked WISA** row (the Azure field is output, never
/// input), and it may never reach a **staff** record, whose `department` is the
/// comma-separated school list other software owns (#237).
library;

import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  List<Type> types(Iterable<Object> actions) =>
      actions.map((a) => a.runtimeType).toList();

  /// [ActionResult.azure] as the connector record it actually is —
  /// `account_core`'s interface carries only the linking keys, and `department`
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

  group('AddStudentToAzure names the class it writes (#359)', () {
    test('the POST body carries the WISA class group', () async {
      final transport = createTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action =
          AddStudentToAzure(linked(wisa: wisaStudent(classGroup: '3A')), cfg);

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      final post = transport.requests.singleWhere((r) => r.method == 'POST');
      expect(
        (jsonDecode(post.body!) as Map<String, dynamic>)['department'],
        '3A',
      );
    });

    test('the change set names the field, so the operator sees it up front',
        () {
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);
      expect(
        action
            .describeChanges()
            .fields
            .singleWhere(
              (f) => f.field == 'department',
            )
            .after,
        '3A',
      );
    });
  });

  group('ModifyAzureDepartment repairs a linked student (#359)', () {
    test('a stale class produces the repair action, and only it', () {
      // The account the live tenant is full of: created years ago, still naming
      // the class its holder sat in then.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3A'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureDepartment]);
      final change = actions.single.describeChanges();
      expect(change.system, Origin.azure);
      expect(change.summary, 'Wijzig de klas in Azure');
      expect(change.fields.single.field, 'department');
      expect(change.fields.single.before, '1B');
      expect(change.fields.single.after, '3A');
    });

    test('a missing class fires it too — the adopted account of #224', () {
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3A'),
          smartschool: ssAccount(),
          azure: azureUser(department: null),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureDepartment]);
      expect(actions.single.describeChanges().fields.single.before, isNull);
    });

    test('a match produces nothing', () {
      expect(
        studentActionsFor(
          linked(
            wisa: wisaStudent(classGroup: '3A'),
            smartschool: ssAccount(),
            azure: azureUser(department: '3A'),
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
            wisa: wisaStudent(classGroup: '3A'),
            smartschool: ssAccount(),
            azure: azureUser(department: ' 3a '),
          ),
          cfg,
        ),
        isEmpty,
      );
    });

    test('a blank WISA class stands the repair down instead of clearing it',
        () {
      // WISA saying nothing is not WISA saying "no class". Writing the silence
      // through would wipe the one answer the record still had.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '  '),
          smartschool: ssAccount(),
          azure: azureUser(department: '3A'),
        ),
        cfg,
      );
      expect(actions.whereType<ModifyAzureDepartment>(), isEmpty);
    });

    test('it PATCHes department alone and returns the mutated record',
        () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureDepartment(
        linked(
          wisa: wisaStudent(classGroup: '3A'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
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
        <String, dynamic>{'department': '3A'},
        reason: 'a one-field correction, not a rewrite of the record',
      );
      expect(azureOf(result).department, '3A');
      // Everything else on the record is left exactly as it was — the two other
      // stamped fields above all, which have repairs of their own.
      expect(azureOf(result).companyName, 'SSM');
      expect(azureOf(result).jobTitle, 'LeerlingSec');
    });

    test('the dry run writes nothing and projects the corrected record',
        () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureDepartment(
        linked(
          wisa: wisaStudent(classGroup: '3A'),
          smartschool: ssAccount(),
          azure: azureUser(department: null),
        ),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);

      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(azureOf(result).department, '3A');
    });
  });

  group('the class is read from WISA and written to Azure, never back (#359)',
      () {
    test('an Azure-only orphan carrying our prefix is never re-stamped', () {
      // No WISA row, so nothing authoritative says what class this account's
      // holder is in — and the lifecycle branch it falls to carries no field
      // repairs at all. The stale `department` it holds is exactly what may not
      // be used as an answer.
      final actions = studentActionsFor(
        linked(azure: azureUser(companyName: 'SSM', department: '1B')),
        cfg,
      );
      expect(actions.whereType<ModifyAzureDepartment>(), isEmpty);
      expect(types(actions), [RemoveStudentFromAzure]);
    });

    test('a student who left our school for a sibling one is left alone', () {
      // Still in the group's WISA, so their Azure account is kept (#134) — but
      // their class is no longer ours to write.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3A'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
          wisaPresence: WisaPresence.groupOnly,
        ),
        cfg,
      );
      expect(actions.whereType<ModifyAzureDepartment>(), isEmpty);
    });

    test('a class our own WISA does not have is never written (#333)', () {
      // The guard that stands the Smartschool move down stands this write down
      // too: `3HWa` is a sibling school's class, and a name our inventory does
      // not carry is not one to write into our systems — in either system.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3HWa'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
        ),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3HWa',
          currentClass: ssGroup(code: '3C', name: '3C'),
          tree: [ssGroup(code: '3HWa', name: '3HWa')],
          ourClasses: const {'3C'},
        ),
      );
      expect(actions.whereType<ModifyAzureDepartment>(), isEmpty);
      expect(
        actions
            .expand((a) => a.describeChanges().fields)
            .expand((f) => <String?>[f.before, f.after]),
        isNot(contains('3HWa')),
      );
    });

    test('the same class, once our inventory carries it, is written', () {
      // The guard's other side — proof the case above is about the inventory
      // and not about the class name.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3HWa'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
        ),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3HWa',
          currentClass: ssGroup(code: '3HWa', name: '3HWa'),
          tree: [ssGroup(code: '3HWa', name: '3HWa')],
          ourClasses: const {'3HWa'},
        ),
      );
      expect(types(actions), [ModifyAzureDepartment]);
      expect(actions.single.describeChanges().fields.single.after, '3HWa');
    });

    test('with no placement wired the write goes ahead (pre-#333 reading)', () {
      // Nothing is known about the inventory, so nothing is standing the write
      // down — the same reading `ModifySmartschoolStemId` gives a null
      // placement.
      final actions = studentActionsFor(
        linked(
          wisa: wisaStudent(classGroup: '3HWa'),
          smartschool: ssAccount(),
          azure: azureUser(department: '1B'),
        ),
        cfg,
      );
      expect(types(actions), [ModifyAzureDepartment]);
    });

    test('a half-provisioned student gets the create, not the repair', () {
      // No Smartschool account yet, so the lifecycle branch runs and the class
      // rides along on the Smartschool create instead.
      final actions = studentActionsFor(
        linked(wisa: wisaStudent(), azure: azureUser(department: null)),
        cfg,
      );
      expect(actions.whereType<ModifyAzureDepartment>(), isEmpty);
      expect(types(actions), [AddStudentToSmartschool]);
    });
  });

  group('staff are out of reach of it (#237/#359)', () {
    test('a staff member whose department lists two schools raises no action',
        () {
      // The trap this issue names: `department` on a staff record is the
      // comma-separated list of schools other software maintains, and #237
      // established we must not rewrite it. `SSM,GBS` looks nothing like a
      // class, and a repair that reached it would collapse the list to ours.
      final actions = staffActionsFor(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(),
          azure: azureStaff(department: 'SSM,GBS'),
        ),
        staffConfig(),
      );
      expect(actions, isEmpty);
    });

    test('the repair is a StudentAction, so no staff dispatch can build one',
        () {
      // Structural, not a matter of the staff dispatch remembering: the sealed
      // family the action belongs to is the student one, and `staffActionsFor`
      // returns `StaffAction`s.
      expect(
        ModifyAzureDepartment(
          linked(
            wisa: wisaStudent(),
            smartschool: ssAccount(),
            azure: azureUser(),
          ),
          cfg,
        ),
        isA<StudentAction>(),
      );
      expect(
        staffActionsFor(
          linkedStaff(
            wisa: wisaStaff(),
            smartschool: ssStaff(),
            azure: azureStaff(department: 'SSM,GBS'),
          ),
          staffConfig(),
        ),
        everyElement(isA<StaffAction>()),
      );
    });
  });
}
