import 'package:account_actions/account_actions.dart';
import 'package:account_core/account_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('groupActionsFor mirrors the legacy GroupActionParser split', () {
    test('present in both, in sync → no action', () {
      expect(groupActionsFor(fullySyncedGroup()), isEmpty);
    });

    test('present in both, data drifts → ModifySmartschoolData', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(description: 'Nieuw'),
          smartschool: ssGroup(description: 'Oud'),
        ),
      );
      expect(actions.map((a) => a.runtimeType), [ModifySmartschoolData]);
    });

    test('WISA only, no placement → DoNotImportFromWisa only (#54 behaviour)',
        () {
      final actions = groupActionsFor(linkedGroup(wisa: wisaGroup()));
      expect(actions.map((a) => a.runtimeType), [DoNotImportFromWisa]);
    });

    test('WISA only with students → DoNotImportFromWisa + AddToSmartschool',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromWisa, AddToSmartschool],
      );
    });

    test('WISA only, empty class → DoNotImportFromWisa + CreateInSmartschool',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: false),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromWisa, CreateInSmartschool],
      );
    });

    test('placement is not consulted for a both-present class', () {
      var called = false;
      final actions = groupActionsFor(
        fullySyncedGroup(),
        placementFor: (_) {
          called = true;
          return groupPlacement();
        },
      );
      expect(actions, isEmpty);
      expect(called, isFalse, reason: 'only WISA-only classes need placement');
    });

    test('Smartschool only → DoNotImportFromSmartschool (informational)', () {
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));
      expect(actions.map((a) => a.runtimeType), [DoNotImportFromSmartschool]);
    });

    test('orphan group with neither WISA nor Smartschool → no action', () {
      // Neither missing-branch action evaluates (each needs its own system),
      // and there is no Azure group action.
      expect(groupActionsFor(linkedGroup()), isEmpty);
    });
  });

  group('groupActions over a LinkedSnapshot', () {
    test('emits actions per group record, in snapshot order', () {
      final snapshot = LinkedSnapshot.fromRecords(
        accounts: const [],
        staff: const [],
        groups: [
          linkedGroup(wisa: wisaGroup(name: '1A')), // WISA-only → don't import
          fullySyncedGroup(), // clean → none
          linkedGroup(
            wisa: wisaGroup(description: 'Nieuw'),
            smartschool: ssGroup(description: 'Oud'),
          ), // drift → modify
        ],
      );

      final actions = groupActions(snapshot);
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromWisa, ModifySmartschoolData],
      );
    });

    test('threads placementFor so WISA-only classes gain a create action', () {
      final snapshot = LinkedSnapshot.fromRecords(
        accounts: const [],
        staff: const [],
        groups: [
          linkedGroup(wisa: wisaGroup(name: '1A')), // WISA-only, has students
          fullySyncedGroup(), // clean → none, placement untouched
        ],
      );

      final actions = groupActions(
        snapshot,
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromWisa, AddToSmartschool],
      );
    });
  });
}
