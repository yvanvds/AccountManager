import 'dart:convert';

import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:wisa_api/wisa_api.dart' as wapi;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = staffConfig();

  group('dry run performs no writes (PAIN-3)', () {
    test('UpdateStaffWisaName dry run: no SOAP call, projected record returned',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = UpdateStaffWisaName(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect(result.smartschool?.accountId, 'SMIT');
    });

    test('RemoveStaffFromSmartschool dry run: no write, removed flag set',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = RemoveStaffFromSmartschool(
        linkedStaff(smartschool: ssStaff()),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(result.removed, isTrue);
      expect(transport.soapActions, isEmpty);
    });

    test('SetStaffCopyCode dry run: no write, padded fax projected', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = SetStaffCopyCode(
        linkedStaff(
          wisa: wisaStaff(wisaId: '42'),
          smartschool: ssStaff(fax: '9999'),
          azure: azureStaff(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect((result.smartschool! as ss.SmartschoolAccount).fax, '0042');
    });
  });

  group('real apply performs the write and returns the mutated record (#40)',
      () {
    test(
        'UpdateStaffWisaName: calls changeInternNumber, returns updated record',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = UpdateStaffWisaName(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: ssStaff(accountId: 'OLD'),
          azure: azureStaff(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('changeInternNumber'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.smartschool?.accountId, 'SMIT');
    });

    test('ModifySmartschoolStaffEmail: saves account, mail ← Azure UPN',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifySmartschoolStaffEmail(
        linkedStaff(
          wisa: wisaStaff(),
          smartschool: ssStaff(mail: 'anna.old@school.example'),
          azure: azureStaff(upn: 'anna.smit@school.example'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUser'), isTrue);
      expect(result.smartschool?.mail, 'anna.smit@school.example');
    });

    test('SetStaffCopyCode: saves account and writes the PINCODE parameter',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = SetStaffCopyCode(
        linkedStaff(
          wisa: wisaStaff(wisaId: '42'),
          smartschool: ssStaff(fax: '9999'),
          azure: azureStaff(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUser'), isTrue);
      expect(transport.calledMethod('saveUserParameter'), isTrue);
      expect((result.smartschool! as ss.SmartschoolAccount).fax, '0042');
    });

    test('AddStaffToAzure: creates the user on the base domain, returns it',
        () async {
      final transport = RecordingGraphTransport(
        handler: (req) {
          if (req.method == 'GET' &&
              (req.url.queryParameters[r'$filter'] ?? '')
                  .startsWith('employeeId in')) {
            // The tenant holds no account for this WISA id (#231).
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
                'userPrincipalName': 'anna.smit@school.example',
              }),
            );
          }
          return const az.GraphResponse(statusCode: 204);
        },
      );
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStaffToAzure(
        linkedStaff(wisa: wisaStaff(wisaId: '42')),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.sent('POST', pathContains: 'users'), isTrue);
      expect(result.azure?.id, 'az-new');
      expect(result.azure?.upn, 'anna.smit@school.example');
      expect(result.azure?.employeeId, '42');
      expect((result.azure! as az.AzureUser).department, 'SSM');
    });

    test(
        'AddStaffToAzure: refuses to create when the tenant already has an '
        'account with this employeeId (#231)', () async {
      // The duplicate this guards, the staff half of #224: the account is
      // invisible to the school-scoped pull (its `department` still names the
      // sibling group school the member moved in from), so the snapshot says
      // "no Azure account" and the dispatcher raises the create.
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
                    'id': 'az-moved',
                    'userPrincipalName': 'smit.anna@other.example',
                    'employeeId': '42',
                    'department': 'OTHER - Wiskunde',
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
                'userPrincipalName': 'anna.smit@school.example',
              }),
            );
          }
          return const az.GraphResponse(statusCode: 204);
        },
      );
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStaffToAzure(
        linkedStaff(wisa: wisaStaff(wisaId: '42')),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.failed);
      expect(transport.sent('POST'), isFalse, reason: 'nothing was created');
      expect(result.azure, isNull);
      // The operator is told what to do about it, and which account it is.
      expect('${result.error}', contains('42'));
      expect('${result.error}', contains('smit.anna@other.example'));
    });

    test(
        'AddStaffToAzure: a staff member with no wisaId is created without an '
        'employeeId lookup (#231)', () async {
      // `wisaId` is nullable on a staff row (`code` is the staff primary key,
      // OQ-1). There is nothing to look up — and nothing to stamp on the new
      // account either — so the guard must step aside rather than send Graph a
      // filter with an empty literal in it.
      final transport = RecordingGraphTransport(
        handler: (req) {
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
                'userPrincipalName': 'anna.smit@school.example',
              }),
            );
          }
          return const az.GraphResponse(statusCode: 204);
        },
      );
      final connectors = Connectors(azure: azureConnector(transport));
      final action = AddStaffToAzure(
        linkedStaff(wisa: wisaStaff(wisaId: null)),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(
        transport.requests.where(
          (r) => (r.url.queryParameters[r'$filter'] ?? '')
              .startsWith('employeeId in'),
        ),
        isEmpty,
      );
    });

    test('AddStaffToSmartschool: saves account, accountId ← WISA code',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddStaffToSmartschool(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT', wisaId: '42'),
          azure: azureStaff(upn: 'anna.smit@school.example'),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUser'), isTrue);
      expect(result.smartschool?.accountId, 'SMIT');
      expect(result.smartschool?.mail, 'anna.smit@school.example');
      // The WISA numeric id becomes the copy-code (fax).
      expect((result.smartschool! as ss.SmartschoolAccount).fax, '42');
    });

    test(
        'no staff action ever PATCHes an existing account\'s department (#237)',
        () async {
      // `department` is owned by other software and lists every school the
      // teacher is active at (`GBS,SSM`). The removed #233 repair fired on any
      // list our prefix did not lead and rewrote it to a bare `SSM`, deleting
      // the sibling school's claim. Nothing may write it again — asserted over
      // the whole staff family, not one action, so a reintroduction anywhere
      // fails here.
      for (final department in <String?>[
        'GBS,SSM',
        'SSM,GBS',
        'GBS',
        'OTHER - Wiskunde',
        null,
      ]) {
        final transport = RecordingGraphTransport();
        final connectors = Connectors(
          azure: azureConnector(transport),
          smartschool: smartschoolConnector(RecordingSmartschoolTransport()),
        );
        final staff = linkedStaff(
          wisa: wisaStaff(code: 'SMIT', wisaId: '42'),
          smartschool: ssStaff(accountId: 'OLD', fax: '9999'),
          azure: azureStaff(id: 'az-moved', department: department),
        );
        for (final action in staffActionsFor(staff, cfg)) {
          await action.apply(connectors, const ApplyOptions());
        }
        expect(
          transport.requests.where((r) => r.method == 'PATCH'),
          isEmpty,
          reason: 'department: $department',
        );
      }
    });

    test('RemoveStaffFromAzure: deletes the user', () async {
      final transport = RecordingGraphTransport();
      final connectors = Connectors(azure: azureConnector(transport));
      final action = RemoveStaffFromAzure(
        linkedStaff(azure: azureStaff(id: 'az-gone')),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.removed, isTrue);
      expect(transport.sent('DELETE', pathContains: 'users'), isTrue);
    });
  });

  group('DontImportStaffFromWisa returns a rule, touches no connector', () {
    test('apply returns a DontImportUserFromWisa rule keyed on the code',
        () async {
      final ssTransport = RecordingSmartschoolTransport();
      final azTransport = RecordingGraphTransport();
      final connectors = Connectors(
        smartschool: smartschoolConnector(ssTransport),
        azure: azureConnector(azTransport),
      );
      final action = DontImportStaffFromWisa(
        linkedStaff(wisa: wisaStaff(code: 'SMIT')),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.wisa);
      final rule = result.wisaRule;
      expect(rule, isA<wapi.DontImportUserFromWisa>());
      expect((rule! as wapi.DontImportUserFromWisa).userCode, 'SMIT');
      // WISA is read-only — no connector was called.
      expect(ssTransport.soapActions, isEmpty);
      expect(azTransport.requests, isEmpty);
    });

    test('dry run yields the same rule with a dryRun outcome', () async {
      final action = DontImportStaffFromWisa(
        linkedStaff(wisa: wisaStaff(code: 'SMIT')),
        cfg,
      );
      final result = await action.apply(const Connectors(), ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(
          (result.wisaRule! as wapi.DontImportUserFromWisa).userCode, 'SMIT');
    });
  });

  group('apply is retry-safe (INV-41): a failed write does not corrupt state',
      () {
    test('a non-zero Smartschool result → failed outcome, error captured',
        () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final smartschool = ssStaff(accountId: 'OLD');
      final action = UpdateStaffWisaName(
        linkedStaff(
          wisa: wisaStaff(code: 'SMIT'),
          smartschool: smartschool,
          azure: azureStaff(),
        ),
        cfg,
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
      // The source record is untouched — the action can be retried.
      expect(smartschool.accountId, 'OLD');
    });
  });
}
