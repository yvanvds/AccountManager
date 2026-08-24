import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final cfg = config();

  List<Type> types(Iterable<StudentAction> actions) =>
      actions.map((a) => a.runtimeType).toList();

  LinkedAccount completeStudent({
    ss.SmartschoolAccount? smartschool,
    az.AzureUser? azure,
    String classGroup = '3A',
  }) =>
      linked(
        wisa: wisaStudent(classGroup: classGroup),
        smartschool: smartschool ?? ssAccount(),
        azure: azure ?? azureUser(),
      );

  // -------------------------------------------------------------------------
  // Dispatch (#55): MoveToSmartschoolClassGroup is opt-in via placementFor.
  // -------------------------------------------------------------------------
  group('dispatch — MoveToSmartschoolClassGroup gated on placementFor', () {
    test('no placementFor → no class move (backward-compatible with #46)', () {
      final actions = studentActionsFor(completeStudent(), cfg);
      expect(actions.whereType<MoveToSmartschoolClassGroup>(), isEmpty);
    });

    test('placement whose target differs from the current class → move fires',
        () {
      final actions = studentActionsFor(
        completeStudent(),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3A',
          currentClass: ssGroup(code: '3B', name: '3B'),
        ),
      );
      expect(types(actions), [MoveToSmartschoolClassGroup]);
    });

    test('placement whose target equals the current class → no move', () {
      final actions = studentActionsFor(
        completeStudent(),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3A',
          currentClass: ssGroup(code: '3A', name: '3A'),
        ),
      );
      expect(actions.whereType<MoveToSmartschoolClassGroup>(), isEmpty);
    });

    test('student in no class yet (currentClass null) → move fires', () {
      final actions = studentActionsFor(
        completeStudent(),
        cfg,
        placementFor: (_) => classPlacement(className: '3A'),
      );
      expect(types(actions), [MoveToSmartschoolClassGroup]);
    });

    test('ANS/BNS student is excluded even when the class differs', () {
      for (final cg in ['ANS1', 'BNS2']) {
        final actions = studentActionsFor(
          completeStudent(classGroup: cg),
          cfg,
          placementFor: (_) => classPlacement(
            className: cg,
            currentClass: ssGroup(code: '3B', name: '3B'),
          ),
        );
        expect(
          actions.whereType<MoveToSmartschoolClassGroup>(),
          isEmpty,
          reason: '$cg must not raise a standalone class move',
        );
      }
    });

    test('the move leads the Smartschool modifiers (#338)', () {
      // Legacy ran the move late — after StemID and BirthPlace — and that order
      // is what damaged 66 careers: `saveUser` writes the stamboeknummer to the
      // *last* schoolloopbaan row, which is the running year's until the move
      // has created next year's. So the move now leads, and the rest of the
      // Smartschool modifiers keep their legacy order behind it.
      final actions = studentActionsFor(
        completeStudent(
          smartschool: ssAccount(
            birthPlace: 'Antwerpen', // ≠ WISA 'Gent' → BirthPlace fires
            mail: 'jan.peeters@school.example', // base domain → StudentEmail
          ),
        ),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3A',
          currentClass: ssGroup(code: '3B', name: '3B'),
        ),
      );
      expect(types(actions), [
        MoveToSmartschoolClassGroup,
        ModifySmartschoolBirthPlace,
        ModifySmartschoolStudentEmail,
      ]);
    });

    test('placementFor is not consulted for a WISA-less lifecycle account', () {
      var called = false;
      studentActionsFor(
        linked(smartschool: ssAccount(status: 'actief')),
        cfg,
        placementFor: (_) {
          called = true;
          return classPlacement();
        },
      );
      expect(called, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The ours-classes guard (#333). The widest bulk action in the app must never
  // propose a class our own WISA school does not have — whatever named it.
  // -------------------------------------------------------------------------
  group('dispatch — a move only ever targets one of our own classes', () {
    test('a target our WISA school does not have raises nothing at all', () {
      // The class is in the Smartschool tree, so the write would go through:
      // only the WISA inventory says this is another school's class.
      final actions = studentActionsFor(
        completeStudent(classGroup: '3HWa'),
        cfg,
        placementFor: (_) => classPlacement(
          className: '3HWa',
          currentClass: ssGroup(code: '3MWW1', name: '3MWW1'),
          tree: [
            ssGroup(code: '3MWW1', name: '3MWW1'),
            ssGroup(code: '3HWa', name: '3HWa'),
          ],
          ourClasses: const {'3MWW1'},
        ),
      );
      expect(actions.whereType<MoveToSmartschoolClassGroup>(), isEmpty);
    });

    test(
        'a target that is ours but not in Smartschool yet still fires — the '
        'September rollover the action exists for', () {
      // The over-tightening guard: gating on `resolveClass != null` instead
      // would suppress every move made before the new classes are created.
      final actions = studentActionsFor(
        completeStudent(classGroup: '4B'),
        cfg,
        placementFor: (_) => classPlacement(
          className: '4B',
          currentClass: ssGroup(code: '3C', name: '3C'),
          tree: [ssGroup(code: '3C', name: '3C')],
          ourClasses: const {'4B'},
        ),
      );
      expect(types(actions), [MoveToSmartschoolClassGroup]);
    });

    test('a sub-grouped class is matched in the widened form it will write',
        () {
      // `1A A` is what the placement names and what the move would write, so it
      // is the form the guard has to recognize — the bare `1A` is a different
      // class as far as this write is concerned.
      final actions = studentActionsFor(
        completeStudent(classGroup: '1A'),
        cfg,
        placementFor: (_) => classPlacement(
          className: '1A A',
          currentClass: ssGroup(code: '1A B', name: '1A B'),
          ourClasses: const {'1A', '1A A', '1A B'},
        ),
      );
      expect(types(actions), [MoveToSmartschoolClassGroup]);
    });

    test('a widened name our inventory does not carry is still refused', () {
      final actions = studentActionsFor(
        completeStudent(classGroup: '1A'),
        cfg,
        placementFor: (_) => classPlacement(
          className: '1A A',
          currentClass: ssGroup(code: '1A', name: '1A'),
          ourClasses: const {'1A'},
        ),
      );
      expect(actions.whereType<MoveToSmartschoolClassGroup>(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Purity (INV-40/42).
  // -------------------------------------------------------------------------
  group('MoveToSmartschoolClassGroup — evaluate / describeChanges are pure',
      () {
    MoveToSmartschoolClassGroup move({
      Group? currentClass,
      String className = '3A',
    }) =>
        MoveToSmartschoolClassGroup(
          completeStudent(),
          cfg,
          classPlacement(className: className, currentClass: currentClass),
        );

    test('describeChanges reports the class before/after', () {
      final change =
          move(currentClass: ssGroup(code: '3B', name: '3B')).describeChanges();
      expect(change.system, Origin.smartschool);
      final field = change.fields.single;
      expect(field.field, 'class');
      expect(field.before, '3B');
      expect(field.after, '3A');
    });

    test('a student in no class reports an empty "before"', () {
      final change = move().describeChanges();
      expect(change.fields.single.before, '');
      expect(change.fields.single.after, '3A');
    });

    test('evaluate does not mutate the bound record', () {
      final ss = ssAccount();
      final action = MoveToSmartschoolClassGroup(
        linked(wisa: wisaStudent(), smartschool: ss, azure: azureUser()),
        cfg,
        classPlacement(currentClass: ssGroup(code: '3B', name: '3B')),
      );
      action.evaluate();
      expect(identical(action.account.smartschool, ss), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Apply — MoveToSmartschoolClassGroup.
  // -------------------------------------------------------------------------
  group('MoveToSmartschoolClassGroup — apply', () {
    MoveToSmartschoolClassGroup move({
      List<Group> tree = const [],
      String className = '3A',
    }) =>
        MoveToSmartschoolClassGroup(
          linked(
            wisa: wisaStudent(),
            smartschool: ssAccount(uid: 'jan.peeters'),
            azure: azureUser(),
          ),
          cfg,
          classPlacement(
            className: className,
            currentClass: ssGroup(code: '3B', name: '3B'),
            tree: tree,
          ),
        );

    test('dry run: no SOAP call, returns the (still-existing) account',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move().apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect(result.smartschool?.uid, 'jan.peeters');
    });

    test('real apply: calls saveUserToClass, returns applied + record',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move().apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUserToClass'), isTrue);
      expect(result.system, Origin.smartschool);
      expect(result.smartschool?.uid, 'jan.peeters');
      // The record is unchanged by a move, so the class it landed in is the
      // only thing the State layer can reseat the membership from (#341).
      expect(result.movedToClass?.id.value, '3A');
    });

    test('a dry run names no class — nothing moved (#341)', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move().apply(connectors, ApplyOptions.dry);
      expect(result.movedToClass, isNull);
    });

    test('a failed move names no class — nothing moved (#341)', () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move().apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.movedToClass, isNull);
    });

    test('unresolved target class → failed, no write', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move(className: '9Z', tree: [ssGroup()])
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error.toString(), contains('does not exist'));
      expect(transport.soapActions, isEmpty);
    });

    test('non-official target (e.g. Leerlingen) → failed, no write', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move(
        className: 'Leerlingen',
        tree: [ssGroupNode(name: 'Leerlingen')],
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(result.error.toString(), contains('only official classes'));
      expect(transport.soapActions, isEmpty);
    });

    test('saveUserToClass returns a non-zero code → failed (retry-safe)',
        () async {
      final transport = RecordingSmartschoolTransport(resultCode: 1);
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await move().apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(transport.calledMethod('saveUserToClass'), isTrue);
      expect(result.error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Apply — AddStudentToSmartschool class placement step.
  // -------------------------------------------------------------------------
  group('AddStudentToSmartschool — class placement on add', () {
    AddStudentToSmartschool add({
      ClassPlacement? placement,
      String classGroup = '3A',
    }) =>
        AddStudentToSmartschool(
          linked(
            wisa: wisaStudent(
              firstName: 'Jan',
              name: 'Peeters',
              classGroup: classGroup,
            ),
            azure: azureUser(upn: 'jan.peeters@student.school.example'),
          ),
          cfg,
          placement: placement,
        );

    test('no placement → account created but not placed (as in #46)', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add().apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.smartschool, isNotNull);
      expect(transport.calledMethod('saveUserToClass'), isFalse);
    });

    test('placement → account created then moved into its class', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        placement: classPlacement(tree: [ssGroup(code: '3A', name: '3A')]),
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUserToClass'), isTrue);
    });

    test('dry run with placement → no writes at all', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        placement: classPlacement(tree: [ssGroup(code: '3A', name: '3A')]),
      ).apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
    });

    test('ANS/BNS student targets the (non-official) Leerlingen root → no move',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        classGroup: 'ANS1',
        placement: classPlacement(tree: [ssGroupNode(name: 'Leerlingen')]),
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      // Leerlingen is not an official class, so the move is (correctly) skipped.
      expect(transport.calledMethod('saveUserToClass'), isFalse);
    });

    test('a class our WISA school does not have is never enrolled into (#333)',
        () async {
      // The create's own placement step needs the same guard as the standalone
      // move: a create must not be the way a foreign class name gets written.
      // The class resolves in Smartschool and is official, so nothing else
      // here would have stopped it.
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        classGroup: '3HWa',
        placement: classPlacement(
          className: '3HWa',
          tree: [ssGroup(code: '3HWa', name: '3HWa')],
          ourClasses: const {'3A'},
        ),
      ).apply(connectors, const ApplyOptions());

      // The create is still the action's success criterion (INV-41).
      expect(result.outcome, ActionOutcome.applied);
      expect(result.smartschool, isNotNull);
      expect(transport.calledMethod('saveUserToClass'), isFalse);
    });

    test('a failed placement move does not fail the create (best-effort)',
        () async {
      // saveUser (+ QR parameter) succeed; only saveUserToClass fails.
      final transport = RecordingSmartschoolTransport(
        resultFor: (action) => action.contains('saveUserToClass') ? 1 : null,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        placement: classPlacement(tree: [ssGroup(code: '3A', name: '3A')]),
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.smartschool, isNotNull);
      expect(transport.calledMethod('saveUserToClass'), isTrue);
    });
  });
}
