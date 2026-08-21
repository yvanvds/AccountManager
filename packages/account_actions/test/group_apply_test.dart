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
            sourceId: 298,
          ),
        ),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveClass'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.group?.instituteNumber, '999999');
      expect(result.group?.description, 'Nieuw');
      // Untouched fields are preserved on the mutated record, including the
      // Smartschool-internal group id this write never touches (#138).
      expect(result.group?.adminNumber, 7);
      expect(result.group?.name, '3A');
      expect(result.group?.sourceId, 298);
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

  group('ModifySmartschoolData converges a drifted Untis code (#65)', () {
    test('Untis-only drift: applies and sets untis to the class name',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      // Institute + description agree; only Untis has drifted.
      final action = ModifySmartschoolData(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(untis: 'stale-untis'),
        ),
      );

      expect(action.evaluate(), isTrue);
      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveClass'), isTrue);
      // Converged to the class name (legacy's fixed remediation target).
      expect(result.group?.untis, '3A');
    });
  });

  group('AddToSmartschool creates an official class (#65)', () {
    test('dry run: no SOAP call, projected class returned', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddToSmartschool(
        linkedGroup(wisa: wisaGroup(name: '3A')),
        groupPlacement(),
      );

      final result = await action.apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect(result.group?.id.value, '3A');
      expect(result.group?.official, isTrue);
      expect(result.group?.origin, Origin.smartschool);
      expect(result.group?.parentId?.value, 'jaar-3');
      // Untis is seeded from the class name (legacy group.Untis = wisa.Name).
      expect(result.group?.untis, '3A');
    });

    test('real apply: calls saveClass and returns the created class', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddToSmartschool(
        linkedGroup(
          wisa: wisaGroup(
            name: '3A',
            instituteNumber: '123456',
            adminNumber: 42,
          ),
        ),
        groupPlacement(),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveClass'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.group?.instituteNumber, '123456');
      expect(result.group?.adminNumber, 42);
    });

    test('unresolvable parent: fails instead of legacy silent no-op (INV-41)',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddToSmartschool(
        linkedGroup(wisa: wisaGroup()),
        groupPlacement(withParent: false),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
      // No write was attempted.
      expect(transport.soapActions, isEmpty);
    });

    test('a failed saveClass surfaces as a failure (INV-41)', () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = AddToSmartschool(
        linkedGroup(wisa: wisaGroup()),
        groupPlacement(),
      );

      final result = await action.apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
    });
  });

  group('CreateInSmartschool is informational (#65)', () {
    test('canApply is false and apply throws UnsupportedError', () {
      final action = CreateInSmartschool(
        linkedGroup(wisa: wisaGroup()),
        groupPlacement(containsStudents: false),
      );
      expect(action.canApply, isFalse);
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });
  });

  group('ClassExistsAsSmartschoolGroup is informational (#225)', () {
    test('canApply is false and apply throws UnsupportedError', () {
      final action = ClassExistsAsSmartschoolGroup(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
      );
      expect(action.canApply, isFalse);
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });

    test('a non-official namesake reads as "not an official class"', () {
      final action = ClassExistsAsSmartschoolGroup(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
      );
      expect(action.evaluate(), isTrue);
      final changes = action.describeChanges();
      expect(changes.system, Origin.smartschool);
      expect(changes.summary, contains('geen officiële klas'));
      // The operator has to find the group in Smartschool: name and code.
      expect(
        changes.fields.map((f) => '${f.field}:${f.before}'),
        containsAll(<String>['name:2G', 'code:G2G']),
      );
    });

    test('an official namesake reads as a spelling mismatch instead', () {
      final action = ClassExistsAsSmartschoolGroup(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroup(code: 'C2G', name: '2 G'),
        ),
      );
      expect(action.evaluate(), isTrue);
      final changes = action.describeChanges();
      expect(changes.summary, contains('andere schrijfwijze'));
      expect(changes.summary, isNot(contains('geen officiële klas')));
      expect(
        changes.fields.map((f) => '${f.field}:${f.before}'),
        contains('name:2 G'),
      );
    });

    test('does not evaluate without a namesake, or once the class is linked',
        () {
      expect(
        ClassExistsAsSmartschoolGroup(linkedGroup(wisa: wisaGroup()))
            .evaluate(),
        isFalse,
      );
      expect(
        ClassExistsAsSmartschoolGroup(
          linkedGroup(
            wisa: wisaGroup(),
            smartschool: ssGroup(),
            smartschoolNamesake: ssGroupNode(),
          ),
        ).evaluate(),
        isFalse,
      );
    });
  });
}
