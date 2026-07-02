import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('dry run performs no writes (PAIN-3)', () {
    test(
        'ModifySmartschoolData dry run: no SOAP call, projected group returned',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(instituteNumber: '999999', description: 'Nieuw'),
          smartschool: ssGroup(instituteNumber: '123456', description: 'Oud'),
        ),
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect(result.group?.instituteNumber, '999999');
      expect(result.group?.description, 'Nieuw');
    });
  });

  group('real apply performs the write and returns the mutated group (#40)',
      () {
    test('ModifySmartschoolData: calls saveClass, returns synced group',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(instituteNumber: '999999', description: 'Nieuw'),
          smartschool: ssGroup(
            instituteNumber: '123456',
            description: 'Oud',
            adminNumber: 7,
          ),
        ),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveClass'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.group?.instituteNumber, '999999');
      expect(result.group?.description, 'Nieuw');
      // Untouched fields are preserved on the mutated record.
      expect(result.group?.adminNumber, 7);
      expect(result.group?.name, '3A');
    });

    test('a failed saveClass leaves the bound record untouched (INV-41)',
        () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final ss = ssGroup(instituteNumber: '123456', description: 'Oud');
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(instituteNumber: '999999', description: 'Nieuw'),
          smartschool: ss,
        ),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
      // The source record is untouched — the action can be retried.
      expect(ss.instituteNumber, '123456');
      expect(ss.description, 'Oud');
    });
  });

  group('DoNotImportFromWisa returns a rule, touches no connector', () {
    test('apply returns a DontImportClass rule keyed on the group name',
        () async {
      final ssTransport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(ssTransport));
      final action = DoNotImportFromWisa(
        linkedGroup(wisa: wisaGroup(name: '3A')),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.wisa);
      final rule = result.wisaRule;
      expect(rule, isA<wapi.DontImportClass>());
      expect((rule! as wapi.DontImportClass).className, '3A');
      // WISA is read-only — no connector was called.
      expect(ssTransport.soapActions, isEmpty);
    });

    test('dry run yields the same rule with a dryRun outcome', () async {
      final action = DoNotImportFromWisa(
        linkedGroup(wisa: wisaGroup(name: '3A')),
      );
      final result = await action.apply(const Connectors(), ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect((result.wisaRule! as wapi.DontImportClass).className, '3A');
    });
  });

  group('DoNotImportFromSmartschool is informational', () {
    test('canApply is false and apply throws UnsupportedError', () {
      final action = DoNotImportFromSmartschool(
        linkedGroup(smartschool: ssGroup()),
      );
      expect(action.canApply, isFalse);
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });
  });
}
