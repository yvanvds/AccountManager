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
    /// The one leftover the delete cannot address: no code for a `delClass`.
    /// Since #328 that is the only shape the notice fires on at all.
    LinkedGroup undeletable({String description = 'Klas 3A'}) =>
        linkedGroup(smartschool: ssGroup(code: ' ', description: description));

    test('canApply is false and apply throws UnsupportedError', () {
      final action = DoNotImportFromSmartschool(undeletable());
      expect(action.canApply, isFalse);
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });

    test('it no longer sends the operator into Smartschool by hand (#313)', () {
      // The dead end #271 removed on the Office 365 side: a row whose whole
      // content was "go and do this somewhere else". The notice states the
      // class instead of instructing — unchanged by #328, which only narrowed
      // where it fires.
      final change =
          DoNotImportFromSmartschool(undeletable()).describeChanges();

      expect(change.summary,
          'Laat deze klas staan — ze bestaat in Smartschool maar niet in WISA');
      expect(change.summary, isNot(contains('Verwijder ze manueel')));
      expect(change.system, Origin.smartschool);
      // Stated, never diffed: this reading writes nothing, so nothing moves.
      // No code here, because a class naming one is deleted rather than noticed.
      expect(change.fields.map((f) => '${f.field}:${f.before}'),
          ['omschrijving:Klas 3A']);
      expect(
        change.fields.every((f) => f.shape == FieldChangeShape.statement),
        isTrue,
      );
      expect(change.fields.every((f) => f.after == null), isTrue);
    });

    test('a class with no description states only the facts it has (#313)', () {
      final change = DoNotImportFromSmartschool(undeletable(description: ''))
          .describeChanges();
      expect(change.fields, isEmpty,
          reason: 'an empty statement renders as a bare `omschrijving: `');
    });

    test('it never stands beside the delete (#328)', () {
      // The two readings partition the leftovers: "laat deze klas staan" and
      // "doe niets" are the same act, so a class the app can delete proposes
      // the delete and nothing else.
      expect(
        groupActionsFor(linkedGroup(smartschool: ssGroup()))
            .whereType<DoNotImportFromSmartschool>(),
        isEmpty,
      );
      expect(
        groupActionsFor(undeletable()).map((a) => a.runtimeType),
        [DoNotImportFromSmartschool],
      );
    });
  });

  group('a Smartschool class WISA does not have proposes a delete (#313)', () {
    test('the delete is the whole row, with no radio pair (#328)', () {
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));

      expect(
        actions.map((a) => a.runtimeType),
        [DeleteSmartschoolClass],
        reason: 'the no-op "laat deze klas staan" is not an option (#328) — '
            'the operator performs it by not pressing Toepassen',
      );
      expect(actions.single.alternativeGroup, isNull);
      expect(actions.single.isDefaultAlternative, isFalse);
    });

    test('the delete describes what goes with the class', () {
      final change = DeleteSmartschoolClass(linkedGroup(smartschool: ssGroup()))
          .describeChanges();

      expect(change.system, Origin.smartschool);
      expect(change.summary,
          'Verwijder de klas 3A uit Smartschool — ze bestaat niet in WISA');
      expect(
        change.fields.map((f) => f.field),
        ['code', 'omschrijving', 'WISA', 'lidmaatschappen en subgroepen'],
      );
      expect(
        change.fields.every((f) => f.shape == FieldChangeShape.statement),
        isTrue,
        reason: 'an inventory of what goes, not four fields being cleared',
      );
    });

    test('the card warns that WISA may simply be lagging (#328)', () {
      // The reading the pre-selected notice used to carry. It is context on the
      // situation, not a resolution: the card proposes a delete the operator
      // may ignore, and this is what tells them when to.
      final change = DeleteSmartschoolClass(linkedGroup(smartschool: ssGroup()))
          .describeChanges();
      final warning =
          change.fields.singleWhere((f) => f.field == 'WISA').before!;

      expect(warning, contains('(nog) niet'));
      expect(warning, contains('loopt WISA achter'));
      expect(warning, contains('controleer'));
      expect(
        change.fields.indexWhere((f) => f.field == 'WISA'),
        lessThan(
          change.fields
              .indexWhere((f) => f.field == 'lidmaatschappen en subgroepen'),
        ),
        reason: 'it sits with the class facts, before the inventory of what '
            'the delete takes',
      );
      expect(
        groupActionsFor(linkedGroup(smartschool: ssGroup()))
            .map((a) => a.describeChanges().summary),
        isNot(contains(contains('Laat deze klas staan'))),
        reason: 'stated as context, never offered as a second option',
      );
    });

    test('apply calls delClass with the class code and reports it removed',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = DeleteSmartschoolClass(
        // The code differs from the name on purpose: `delClass` takes the code.
        linkedGroup(smartschool: ssGroup(code: 'C3A', name: '3A')),
      );

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.applied);
      expect(result.system, Origin.smartschool);
      expect(result.removed, isTrue,
          reason: 'the State layer drops it from the snapshot');
      expect(result.group, isNull, reason: 'a delete carries no record back');
      expect(transport.calledMethod('delClass'), isTrue);
      expect(transport.envelopes.single, contains('C3A'));
      expect(transport.envelopes.single, isNot(contains('>3A<')),
          reason: 'the class is addressed by its code, not its name');
    });

    test('a dry run of the delete writes nothing (PAIN-3)', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = DeleteSmartschoolClass(
        linkedGroup(smartschool: ssGroup(code: 'C3A')),
      );

      final result = await action.apply(connectors, ApplyOptions.dry);

      expect(result.outcome, ActionOutcome.dryRun);
      expect(result.removed, isTrue);
      expect(transport.soapActions, isEmpty);
    });

    test('a refused delClass surfaces as a failure (INV-41)', () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));
      final action = DeleteSmartschoolClass(
        linkedGroup(smartschool: ssGroup(code: 'C3A')),
      );

      final result = await action.apply(connectors, const ApplyOptions());

      expect(result.outcome, ActionOutcome.failed);
      expect(result.error, isNotNull);
      expect(result.removed, isFalse,
          reason: 'nothing was removed, so nothing may be dropped');
    });

    test('a record naming no class code raises no delete', () {
      final actions =
          groupActionsFor(linkedGroup(smartschool: ssGroup(code: ' ')));
      expect(actions.whereType<DoNotImportFromSmartschool>(), hasLength(1));
      expect(actions.whereType<DeleteSmartschoolClass>(), isEmpty,
          reason: 'there is nothing to address the delClass to');
    });

    test('an organisational group is never offered for deletion', () {
      // The linker only ever seeds an orphan from an *official* class, so this
      // shape does not reach the dispatch — but a delete must not inherit its
      // whole scope from a filter one layer away.
      final actions = groupActionsFor(
        linkedGroup(smartschool: ssGroupNode(code: 'leerlingen')),
      );
      expect(actions.whereType<DeleteSmartschoolClass>(), isEmpty);
    });

    test('a class WISA still has is offered no delete', () {
      expect(
        groupActionsFor(fullySyncedGroup()).whereType<DeleteSmartschoolClass>(),
        isEmpty,
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
