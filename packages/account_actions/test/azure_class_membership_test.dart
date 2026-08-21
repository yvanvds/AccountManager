import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The per-student view of Office 365 class-group membership (#245) — the half
/// of #228 that reports the roster diff on the *account* rather than only on the
/// class row in Klasgroepen.
///
/// [AzureClassPlacement] arrives injected, exactly as [ClassPlacement] does, so
/// these tests drive the action straight from a placement; the State layer test
/// (`account_state/test/azure_class_groups_test.dart`) covers deriving one from
/// a real linked view.
AzureClassPlacement placement({
  String className = '3A',
  String? groupName = 'SSM-3A',
  bool groupExists = true,
  bool isMember = true,
  List<String> strayGroupNames = const [],
}) =>
    AzureClassPlacement(
      className: className,
      groupName: groupName,
      groupExists: groupExists,
      isMember: isMember,
      strayGroupNames: strayGroupNames,
    );

List<StudentAction> _dispatch(
  LinkedAccount account,
  AzureClassPlacement azure,
) =>
    studentActionsFor(
      account,
      config(),
      placementFor: (_) => classPlacement(),
      azurePlacementFor: (_) => azure,
    );

void main() {
  group('the action reports the placement it is handed (#245)', () {
    test('a student in their own class group raises nothing', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(),
      );
      expect(action.evaluate(), isFalse);
    });

    test('a student missing from their own class group is reported', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(isMember: false),
      );
      expect(action.evaluate(), isTrue);
      final changes = action.describeChanges();
      expect(changes.system, Origin.azure);
      expect(changes.summary, contains('Ontbreekt in de Office 365-klasgroep'));
      expect(changes.summary, contains('SSM-3A'));
      expect(changes.fields.single.after, 'SSM-3A');
    });

    test('a student still in the group of a class they left is reported', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(strayGroupNames: const ['SSM-2B']),
      );
      expect(action.evaluate(), isTrue);
      final changes = action.describeChanges();
      expect(changes.summary, contains('Staat nog in de Office 365-klasgroep'));
      expect(changes.summary, contains('SSM-2B'));
      expect(changes.fields.single.before, 'SSM-2B');
    });

    test('the wrong-class case names both groups in one line', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(isMember: false, strayGroupNames: const ['SSM-2B']),
      );
      expect(action.evaluate(), isTrue);
      final changes = action.describeChanges();
      expect(changes.summary, contains('verkeerde Office 365-klasgroep'));
      expect(changes.summary, contains('SSM-2B in plaats van SSM-3A'));
      expect(changes.fields.single.before, 'SSM-2B');
      expect(changes.fields.single.after, 'SSM-3A');
    });

    test('a class whose group does not exist yet raises nothing', () {
      // The class-level CreateAzureClassGroup is the work there, and since #245
      // it chains straight into the roster sync — reporting it once per student
      // of the class would be pure noise.
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(groupExists: false, isMember: false),
      );
      expect(action.evaluate(), isFalse);
    });

    test('a student with no Office 365 account raises nothing', () {
      // AddStudentToAzure is their action; a group they cannot be a member of
      // is not yet their account's problem.
      final action = AzureClassGroupMembership(
        linked(wisa: wisaStudent(), smartschool: ssAccount()),
        config(),
        placement(isMember: false),
      );
      expect(action.evaluate(), isFalse);
    });
  });

  group('informational, so the class row stays the single write (#245)', () {
    test('canApply is false and apply throws', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(isMember: false),
      );
      expect(action.canApply, isFalse);
      expect(
        () => action.apply(const Connectors(), const ApplyOptions()),
        throwsUnsupportedError,
      );
    });

    test('every other student action stays applyable', () {
      final actions = studentActionsFor(
        linked(wisa: wisaStudent()),
        config(),
      );
      expect(actions, isNotEmpty);
      for (final action in actions) {
        expect(action.canApply, isTrue, reason: '${action.runtimeType}');
      }
    });
  });

  group('dispatch wiring (#245)', () {
    test('the modify branch raises it beside MoveToSmartschoolClassGroup', () {
      final actions = _dispatch(fullySynced(), placement(isMember: false));
      expect(
        actions.map((a) => a.runtimeType),
        contains(AzureClassGroupMembership),
      );
    });

    test('a lifecycle account never gets one', () {
      // A student with no Smartschool account falls to the lifecycle branch,
      // where the class-placement actions of both systems are out of scope.
      final actions = _dispatch(
        linked(wisa: wisaStudent(), azure: azureUser()),
        placement(isMember: false),
      );
      expect(
        actions.map((a) => a.runtimeType),
        isNot(contains(AzureClassGroupMembership)),
      );
    });

    test('without the callback the dispatch is exactly as it was before #245',
        () {
      final actions = studentActionsFor(
        fullySynced(),
        config(),
        placementFor: (_) => classPlacement(),
      );
      expect(
        actions.map((a) => a.runtimeType),
        isNot(contains(AzureClassGroupMembership)),
      );
    });

    test('the callback is not consulted for a sibling-school student', () {
      // A groupOnly student's class is not ours to place (#134/#222), so the
      // resolver is never asked about them.
      var calls = 0;
      studentActionsFor(
        linked(
          wisa: wisaStudent(),
          smartschool: ssAccount(),
          azure: azureUser(),
          wisaPresence: WisaPresence.groupOnly,
        ),
        config(),
        azurePlacementFor: (_) {
          calls++;
          return placement();
        },
      );
      expect(calls, 0);
    });
  });

  group('purity (INV-40)', () {
    test('evaluate and describeChanges are deterministic', () {
      final action = AzureClassGroupMembership(
        fullySynced(),
        config(),
        placement(isMember: false, strayGroupNames: const ['SSM-2B']),
      );
      expect(action.evaluate(), action.evaluate());
      expect(
        action.describeChanges().summary,
        action.describeChanges().summary,
      );
    });
  });
}
