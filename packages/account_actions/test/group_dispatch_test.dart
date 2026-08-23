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

    test('WISA only with students → AddToSmartschool + DoNotImportFromWisa',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      expect(
        actions.map((a) => a.runtimeType),
        // The create leads the blacklist it is an alternative to (#244).
        [AddToSmartschool, DoNotImportFromWisa],
      );
    });

    test('WISA only, empty class → CreateInSmartschool + DoNotImportFromWisa',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: false),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [CreateInSmartschool, DoNotImportFromWisa],
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

    test(
        'WISA only, but Smartschool already has the name → the notice replaces '
        'the create (#225)', () {
      // The `2G` of #225: WISA has the populated class, Smartschool has a group
      // of the same name that is not flagged official, so the linker could not
      // adopt it. Offering to create the class would ask Smartschool for a
      // duplicate name.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [ClassExistsAsSmartschoolGroup, DoNotImportFromWisa],
      );
    });

    test('the namesake notice also displaces the empty-class notice (#225)',
        () {
      // Same shape with an empty WISA class: "delete this class, it has no
      // students" is the wrong advice for a class that *is* provisioned
      // downstream.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
        placementFor: (_) => groupPlacement(containsStudents: false),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [ClassExistsAsSmartschoolGroup, DoNotImportFromWisa],
      );
    });

    test('the namesake notice needs no placement to be raised (#225)', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
      );
      expect(
        actions.map((a) => a.runtimeType),
        [ClassExistsAsSmartschoolGroup, DoNotImportFromWisa],
      );
    });

    test('a linked class never carries the namesake notice (#225)', () {
      // Defensive: the linker only sets the namesake on an unlinked class, but
      // the both-present branch must not raise it even if one arrived.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(),
          smartschool: ssGroup(),
          smartschoolNamesake: ssGroupNode(code: 'G3A', name: '3A'),
        ),
      );
      expect(actions, isEmpty);
    });

    test('Smartschool only → the leave-it/delete-it pair (#313)', () {
      // The notice used to stand alone and tell the operator to go and delete
      // the class by hand in Smartschool — a row whose whole content was an
      // instruction to go elsewhere.
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));
      expect(
        actions.map((a) => a.runtimeType),
        [DoNotImportFromSmartschool, DeleteSmartschoolClass],
      );
    });

    test('orphan group with neither WISA nor Smartschool → no action', () {
      // Neither missing-branch action evaluates (each needs its own system),
      // and there is no Azure group action.
      expect(groupActionsFor(linkedGroup()), isEmpty);
    });
  });

  group('the WISA-only class is one choice, not two to-dos (#244)', () {
    test('create + do-not-import share one key, the create leading as default',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      final create = actions.whereType<AddToSmartschool>().single;
      final ignore = actions.whereType<DoNotImportFromWisa>().single;

      // Same key ⇒ the pending list collapses them into one either/or choice
      // and an apply runs only the picked one. Both used to return null, so
      // "apply all" created the class *and* blacklisted the name it created.
      expect(create.alternativeGroup, classImportAlternative);
      expect(ignore.alternativeGroup, create.alternativeGroup);

      // Polarity: provisioning leads, blacklisting is a deliberate pick.
      expect(create.isDefaultAlternative, isTrue);
      expect(ignore.isDefaultAlternative, isFalse);
      expect(actions.indexOf(create), lessThan(actions.indexOf(ignore)));
    });

    test('an empty class defaults to the informational wait-or-delete notice',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: false),
      );
      final empty = actions.whereType<CreateInSmartschool>().single;
      final ignore = actions.whereType<DoNotImportFromWisa>().single;

      expect(empty.alternativeGroup, classImportAlternative);
      expect(ignore.alternativeGroup, classImportAlternative);
      // It stands in for the create, so it takes the default with it — and it
      // cannot be applied, so a bulk apply writes nothing for an empty class.
      expect(empty.isDefaultAlternative, isTrue);
      expect(empty.canApply, isFalse);
      expect(ignore.isDefaultAlternative, isFalse);
    });

    test('exactly one default is ever offered — the creates never co-occur',
        () {
      for (final hasStudents in const [true, false]) {
        final actions = groupActionsFor(
          linkedGroup(wisa: wisaGroup()),
          placementFor: (_) => groupPlacement(containsStudents: hasStudents),
        );
        final alternatives = actions
            .where((a) => a.alternativeGroup == classImportAlternative)
            .toList();
        expect(alternatives, hasLength(2));
        expect(
          alternatives.where((a) => a.isDefaultAlternative),
          hasLength(1),
          reason: 'containsStudents picks exactly one of the two creates',
        );
      }
    });

    test('a class present in both systems carries no alternatives', () {
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(description: 'Nieuw'),
          smartschool: ssGroup(description: 'Oud'),
        ),
      );
      expect(actions.single.alternativeGroup, isNull);
    });

    test('the Smartschool-only orphan notice leads a choice of its own (#313)',
        () {
      // A key of its own, for the reason the namesake pair has one: the pending
      // list bulk-applies per situation key, and "this Smartschool class is not
      // in WISA" is not the situation "this WISA class is not in Smartschool".
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));
      final notice = actions.whereType<DoNotImportFromSmartschool>().single;
      final delete = actions.whereType<DeleteSmartschoolClass>().single;

      expect(notice.alternativeGroup, staleSmartschoolClassAlternative);
      expect(delete.alternativeGroup, staleSmartschoolClassAlternative);
      expect(notice.alternativeGroup, isNot(classImportAlternative));
      expect(notice.alternativeGroup, isNot(namesakeClassAlternative));

      // Polarity: the informational notice leads and is the default, so a bulk
      // apply writes *nothing* for a Smartschool leftover and the delete stays
      // a deliberate, per-row pick.
      expect(notice.isDefaultAlternative, isTrue);
      expect(notice.canApply, isFalse);
      expect(delete.isDefaultAlternative, isFalse);
      expect(delete.canApplyToAll, isFalse);
      expect(actions.indexOf(notice), lessThan(actions.indexOf(delete)));
    });

    test('the namesake notice (#225) leads a choice of its own (#250)', () {
      // The notice takes the create's place for a class Smartschool already
      // carries, so it takes the create's side of the either/or too — under its
      // own key, because "this class is already there, go fix its flag" is a
      // different situation from "create this class" and must not share a bulk
      // apply with it.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      final notice = actions.whereType<ClassExistsAsSmartschoolGroup>().single;
      final ignore = actions.whereType<DoNotImportFromWisa>().single;

      expect(notice.alternativeGroup, namesakeClassAlternative);
      expect(ignore.alternativeGroup, namesakeClassAlternative);
      expect(
        notice.alternativeGroup,
        isNot(classImportAlternative),
        reason: 'a namesake class is not bulk-applied with the new classes',
      );

      // Polarity: the informational notice leads and is the default, so a bulk
      // apply writes *nothing* for a class the operator was told to repair by
      // hand — blacklisting it stays a deliberate pick (#250).
      expect(notice.isDefaultAlternative, isTrue);
      expect(notice.canApply, isFalse);
      expect(ignore.isDefaultAlternative, isFalse);
      expect(actions.indexOf(notice), lessThan(actions.indexOf(ignore)));
    });

    test('the blacklist is never the lone member of a choice (#250)', () {
      // The bug: the creates refuse a namesake class, so `class-import` was
      // left holding only `DoNotImportFromWisa` — and a lone option is always
      // the selected one, which made "Apply to all" blacklist the class.
      for (final hasStudents in const [true, false]) {
        final actions = groupActionsFor(
          linkedGroup(
            wisa: wisaGroup(name: '2G'),
            smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
          ),
          placementFor: (_) => groupPlacement(containsStudents: hasStudents),
        );
        final ignore = actions.whereType<DoNotImportFromWisa>().single;
        final siblings = actions
            .where((a) => a.alternativeGroup == ignore.alternativeGroup)
            .toList();

        expect(siblings, hasLength(2),
            reason: 'the blacklist always has the reading it contradicts '
                'beside it');
        expect(siblings.where((a) => a.isDefaultAlternative), hasLength(1));
        expect(
          siblings.singleWhere((a) => a.isDefaultAlternative).canApply,
          isFalse,
          reason: 'nothing is written for a namesake class by default',
        );
      }
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
        [AddToSmartschool, DoNotImportFromWisa],
      );
    });
  });
}
