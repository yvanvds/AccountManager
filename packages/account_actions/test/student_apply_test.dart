import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  group('dry run performs no writes (PAIN-3)', () {
    test('ModifyAccountId dry run: no SOAP call, projected record returned',
        () {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifyAccountId(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
        cfg,
      );

      return action.apply(connectors, ApplyOptions.dry).then((result) {
        expect(result.outcome, ActionOutcome.dryRun);
        expect(transport.soapActions, isEmpty);
        expect(result.smartschool?.accountId, 'W1');
      });
    });

    test('DeleteFromSmartschool dry run: no write, removed flag set', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = DeleteStudentFromSmartschool(
        linked(smartschool: ssAccount()),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(result.removed, isTrue);
      expect(transport.soapActions, isEmpty);
    });

    test('ModifyAzureStudentEmail dry run: no Graph request', () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureStudentEmail(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(upn: 'jan.peeters@school.example'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.requests, isEmpty);
      expect(result.azure?.upn, 'jan.peeters@student.school.example');
    });
  });

  group('real apply performs the write and returns the mutated record (#40)',
      () {
    test('ModifyAccountId: calls changeInternNumber, returns updated record',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifyAccountId(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: ssAccount(accountId: 'W9'),
          azure: azureUser(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('changeInternNumber'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.smartschool?.accountId, 'W1');
    });

    test('ModifyAzureStudentEmail: PATCHes the user, returns new UPN',
        () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = ModifyAzureStudentEmail(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(upn: 'jan.peeters@school.example'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.sent('PATCH', pathContains: 'users'), isTrue);
      expect(result.azure?.upn, 'jan.peeters@student.school.example');
    });

    test('AddStudentToAzure: creates the user and returns it', () async {
      final transport = RecordingGraphTransport(
        handler: (req) {
          if (req.method == 'GET' &&
              (req.url.queryParameters[r'$filter'] ?? '')
                  .startsWith('employeeId in')) {
            // The tenant holds no account for this WISA id (#224).
            return az.GraphResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'value': const <Object>[]}),
            );
          }
          if (req.method == 'GET') {
            // No existing user with the candidate UPN → it is unique.
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
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.sent('POST', pathContains: 'users'), isTrue);
      expect(result.azure?.id, 'az-new');
      expect(result.azure?.employeeId, 'W1');
    });

    test(
        'AddStudentToAzure: refuses to create when the tenant already has an '
        'account with this employeeId (#224)', () async {
      // The duplicate this guards: the account is invisible to the school-
      // scoped pull (no companyName, another school's department), so the
      // snapshot says "no Azure account" and the dispatcher raises the create.
      // `createPrincipalName` would resolve the UPN collision by suffixing, so
      // the create *succeeds* and the person silently ends up with two.
      final transport = RecordingGraphTransport(
        handler: (req) {
          if (req.method == 'GET' &&
              (req.url.queryParameters[r'$filter'] ?? '')
                  .startsWith('employeeId in')) {
            return az.GraphResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'value': [
                  {
                    'id': 'az-transferred',
                    'userPrincipalName': 'alfio.ambre@student.other.example',
                    'employeeId': 'W1',
                    'department': 'OTHER-3A',
                  },
                ],
              }),
            );
          }
          // Everything a create needs is deliberately available: the projected
          // UPN is free (404) and the POST would succeed. So an unguarded apply
          // creates the duplicate cleanly — this test's failure mode without
          // the guard is "it created one", not "it errored on the way".
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
                'id': 'az-duplicate',
                'userPrincipalName': 'jan.peeters@student.school.example',
              }),
            );
          }
          return const az.GraphResponse(statusCode: 204);
        },
      );
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStudentToAzure(linked(wisa: wisaStudent()), cfg);

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.failed);
      expect(transport.sent('POST'), isFalse, reason: 'nothing was created');
      expect(result.azure, isNull);
      // The operator is told what to do about it, and which account it is.
      expect('${result.error}', contains('W1'));
      expect('${result.error}', contains('alfio.ambre@student.other.example'));
    });

    test('AddStudentToSmartschool: saves account, mail = Azure UPN', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddStudentToSmartschool(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          azure: azureUser(upn: 'jan.peeters@student.school.example'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUser'), isTrue);
      expect(result.smartschool?.accountId, 'W1');
      expect(result.smartschool?.mail, 'jan.peeters@student.school.example');
    });
  });

  group('apply is retry-safe (INV-41): a failed write does not corrupt state',
      () {
    test('a non-zero Smartschool result → failed outcome, error captured',
        () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final smartschool = ssAccount(accountId: 'W9');
      final action = ModifyAccountId(
        linked(
          wisa: wisaStudent(wisaId: 'W1'),
          smartschool: smartschool,
          azure: azureUser(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
      // The source record is untouched — the action can be retried.
      expect(smartschool.accountId, 'W9');
    });
  });

  group('group-wide leave: applying the dispatched resolution (#134)', () {
    test(
        'keep-Azure — a sibling-school departure applies the Smartschool '
        'unregister and leaves Azure untouched', () async {
      final soap = RecordingSmartschoolTransport();
      final graph = RecordingGraphTransport();
      final connectors = Connectors(
        smartschool: smartschoolConnector(soap),
        azure: azureConnector(graph),
      );
      // The student moved to a sibling group school: all three systems present,
      // but WISA only in a school we don't manage (groupOnly).
      final account = linked(
        wisa: wisaStudent(),
        smartschool: ssAccount(status: 'actief'),
        azure: azureUser(companyName: 'SSM'),
        wisaPresence: WisaPresence.groupOnly,
        wisaClassGroups: const {2: '3A'},
      );
      final dispatched = studentActionsFor(account, cfg);

      // Apply the safe default (unregister) — never the Azure removal.
      final unregister =
          dispatched.whereType<UnregisterStudentFromSmartschool>().single;
      final result = await unregister.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.smartschool);
      expect(soap.soapActions, isNotEmpty, reason: 'the unregister ran');
      // Azure was never touched — the account is kept.
      expect(graph.requests, isEmpty);
      expect(dispatched.whereType<RemoveStudentFromAzure>(), isEmpty);
    });

    test(
        'delete-both — a whole-group departure with only Azure left applies '
        'the Azure removal', () async {
      final graph = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(graph));
      // Absent from WISA everywhere, no Smartschool: the terminal delete-both
      // stage the two-phase resolution reaches once Smartschool is gone.
      final account =
          linked(azure: azureUser(id: 'az-gone', companyName: 'SSM'));
      final dispatched = studentActionsFor(account, cfg);

      final remove = dispatched.whereType<RemoveStudentFromAzure>().single;
      final result = await remove.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.removed, isTrue);
      expect(graph.sent('DELETE', pathContains: 'az-gone'), isTrue);
    });
  });
}
