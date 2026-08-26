import 'package:account_actions/account_actions.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// `AddStaffToSmartschool`'s group seat (#374).
///
/// Smartschool's `saveUser` puts **every** account it creates in the platform
/// default group, so a staff create has to add the staff group and leave the
/// default one afterwards. Legacy did; the port dropped both writes with the
/// genuinely membership-aware `AddToStaffGroup` / `AddToAzureStaffGroup`, and
/// every staff account it ever made ended up in the student subtree.
void main() {
  final cfg = staffConfig();

  AddStaffToSmartschool add({StaffPlacement? placement}) =>
      AddStaffToSmartschool(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
        placement: placement,
      );

  /// The value of `<name>` in the [index]-th recorded envelope.
  String? arg(RecordingSmartschoolTransport t, int index, String name) =>
      RegExp('<$name[^>]*>([^<]*)</$name>')
          .firstMatch(t.envelopes[index])
          ?.group(1);

  int indexOf(RecordingSmartschoolTransport t, String method) =>
      t.soapActions.indexWhere((a) => a.endsWith('#$method'));

  group('AddStaffToSmartschool — group seat on create', () {
    test('no placement → account created and left where saveUser put it',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add().apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.smartschool, isNotNull);
      expect(transport.calledMethod('saveUserToClassesAndGroups'), isFalse);
      expect(transport.calledMethod('removeUserFromGroup'), isFalse);
      expect(result.joinedGroup, isNull);
      expect(result.leftGroup, isNull);
      expect(result.warnings, isEmpty,
          reason: 'no seat was asked for, so nothing missed');
    });

    test(
        'placement → the account is added to Leerkrachten and removed from '
        'Leerlingen, in that order', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.warnings, isEmpty);

      // The create first (`saveAccount` is a `saveUser` plus its parameter
      // write), then the two compensating writes in legacy's order.
      expect(
        transport.soapActions.map((a) => a.split('#').last),
        <String>[
          'saveUser',
          'saveUserParameter',
          'saveUserToClassesAndGroups',
          'removeUserFromGroup',
        ],
      );

      // The asymmetry the API imposes: the add takes a group **code**, the
      // removal a group **name**.
      final addIndex = indexOf(transport, 'saveUserToClassesAndGroups');
      expect(arg(transport, addIndex, 'userIdentifier'), 'anna.smit');
      expect(arg(transport, addIndex, 'csvList'), 'LK');
      expect(arg(transport, addIndex, 'keepOld'), '1',
          reason: 'the seat must not wipe the memberships it does not know of');

      final removeIndex = indexOf(transport, 'removeUserFromGroup');
      expect(arg(transport, removeIndex, 'userIdentifier'), 'anna.smit');
      expect(arg(transport, removeIndex, 'class'), 'Leerlingen');

      // Both landed, so both are named for the State layer to splice.
      expect(result.joinedGroup?.id.value, 'LK');
      expect(result.leftGroup?.id.value, 'LLN');
    });

    test('dry run with a placement → no writes at all', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, ApplyOptions.dry);
      expect(result.outcome, ActionOutcome.dryRun);
      expect(transport.soapActions, isEmpty);
      expect(result.joinedGroup, isNull);
      expect(result.leftGroup, isNull);
    });

    test('a refused add leaves the create successful and warns', () async {
      final transport = RecordingSmartschoolTransport(
        resultFor: (a) => a.endsWith('#saveUserToClassesAndGroups') ? 1 : 0,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied,
          reason: 'the create is the success criterion (INV-41)');
      expect(result.joinedGroup, isNull,
          reason: 'a refused add seated nobody, so it may claim nothing');
      expect(result.warnings.single, contains('Leerkrachten'));
      // Independent writes: the worse half of the bug still gets fixed.
      expect(result.leftGroup?.id.value, 'LLN');
    });

    test('a thrown remove leaves the create successful and warns', () async {
      final transport = RecordingSmartschoolTransport(
        throwFor: (a) =>
            a.endsWith('#removeUserFromGroup') ? StateError('boom') : null,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied,
          reason: 'a throw inside the seat must not fail the create around it');
      expect(result.smartschool?.uid, 'anna.smit');
      expect(result.joinedGroup?.id.value, 'LK');
      expect(result.leftGroup, isNull);
      expect(result.warnings.single, contains('Leerlingen'));
      expect(result.warnings.single, contains('boom'));
    });

    test('a refused remove leaves the create successful and warns', () async {
      final transport = RecordingSmartschoolTransport(
        resultFor: (a) => a.endsWith('#removeUserFromGroup') ? 1 : 0,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.leftGroup, isNull);
      expect(result.warnings.single, contains('Leerlingen'));
    });

    test('a thrown add leaves the create successful and warns', () async {
      final transport = RecordingSmartschoolTransport(
        throwFor: (a) => a.endsWith('#saveUserToClassesAndGroups')
            ? StateError('gateway')
            : null,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(result.joinedGroup, isNull);
      expect(result.warnings.single, contains('gateway'));
      expect(result.leftGroup?.id.value, 'LLN');
    });

    test('no Leerkrachten node in the tree → no add write, but a warning',
        () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement(withStaffGroup: false))
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUserToClassesAndGroups'), isFalse,
          reason: 'the add is addressed by code — there is no code to send');
      expect(result.warnings.single, contains('Leerkrachten'));
      // Nothing about the missing node stops the account leaving the student
      // subtree, which is the half that pollutes it.
      expect(transport.calledMethod('removeUserFromGroup'), isTrue);
      expect(result.leftGroup?.id.value, 'LLN');
    });

    test(
        'an official Leerkrachten node → no add write, but a warning '
        '(Smartschool refuses group adds on official classes)', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        placement: staffPlacement(
          staffGroup: ssGroup(code: 'LK', name: smartschoolStaffGroupName),
        ),
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      expect(transport.calledMethod('saveUserToClassesAndGroups'), isFalse);
      expect(result.joinedGroup, isNull);
      expect(result.warnings.single, contains('officiële klas'));
    });

    test(
        'the default group is absent from the snapshot → the removal still '
        'goes out, and names nothing to splice', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result =
          await add(placement: staffPlacement(withDefaultGroup: false))
              .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      // Smartschool seats the account there whether our root-scoped pull saw
      // the node or not, so the write is addressed by name regardless.
      final removeIndex = indexOf(transport, 'removeUserFromGroup');
      expect(arg(transport, removeIndex, 'class'), 'Leerlingen');
      expect(result.leftGroup, isNull,
          reason: 'there is no local membership row to drop');
      expect(result.warnings, isEmpty,
          reason:
              'the removal landed; only the local splice had nothing to do');
    });

    test('a renamed default group is removed by its configured name', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(
        placement: staffPlacement(defaultGroupName: 'Alle leerlingen'),
      ).apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.applied);
      final removeIndex = indexOf(transport, 'removeUserFromGroup');
      expect(arg(transport, removeIndex, 'class'), 'Alle leerlingen');
    });

    test('a failed create never reaches the seat', () async {
      final transport = RecordingSmartschoolTransport(
        resultFor: (a) => a.endsWith('#saveUser') ? 1 : 0,
      );
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final result = await add(placement: staffPlacement())
          .apply(connectors, const ApplyOptions());
      expect(result.outcome, ActionOutcome.failed);
      expect(transport.calledMethod('saveUserToClassesAndGroups'), isFalse);
      expect(transport.calledMethod('removeUserFromGroup'), isFalse);
    });
  });

  group('the dispatch wires the seat', () {
    test('staffActionsFor threads the placement into the create', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final create = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
        placement: staffPlacement(),
      ).whereType<AddStaffToSmartschool>().single;

      await create.apply(connectors, const ApplyOptions());
      expect(transport.calledMethod('saveUserToClassesAndGroups'), isTrue);
      expect(transport.calledMethod('removeUserFromGroup'), isTrue);
    });

    test('without a placement the dispatch is exactly as it was', () async {
      final transport = RecordingSmartschoolTransport();
      final connectors =
          Connectors(smartschool: smartschoolConnector(transport));

      final create = staffActionsFor(
        linkedStaff(wisa: wisaStaff(), azure: azureStaff()),
        cfg,
      ).whereType<AddStaffToSmartschool>().single;

      await create.apply(connectors, const ApplyOptions());
      expect(
        transport.soapActions.map((a) => a.split('#').last),
        <String>['saveUser', 'saveUserParameter'],
        reason: 'the create and nothing else, exactly as before #374',
      );
    });
  });

  group('the group names are stated once', () {
    test('they are the names legacy hard-codes', () {
      expect(smartschoolStaffGroupName, 'Leerkrachten');
      expect(smartschoolDefaultGroupName, 'Leerlingen');
    });

    test('a placement defaults its removal target to the default group name',
        () {
      expect(const StaffPlacement().defaultGroupName, 'Leerlingen');
      expect(const StaffPlacement().staffGroup, isNull);
      expect(const StaffPlacement().defaultGroup, isNull);
    });
  });
}
