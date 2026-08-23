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

    test('Smartschool only → the delete, alone (#313/#328)', () {
      // The notice used to stand alone and tell the operator to go and delete
      // the class by hand in Smartschool — a row whose whole content was an
      // instruction to go elsewhere. #313 put the delete beside it as a radio
      // pair; #328 dropped the no-op half, so the delete is the whole row.
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));
      expect(actions.map((a) => a.runtimeType), [DeleteSmartschoolClass]);
    });

    test('Smartschool only, but undeletable → the lone notice (#328)', () {
      // The remainder the delete cannot act on: no code to address `delClass`
      // to. Exactly one of the two readings ever fires.
      final actions =
          groupActionsFor(linkedGroup(smartschool: ssGroup(code: ' ')));
      expect(actions.map((a) => a.runtimeType), [DoNotImportFromSmartschool]);
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

    test('an empty class states the wait-or-delete notice as context (#329)',
        () {
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: false),
      );
      final empty = actions.whereType<CreateInSmartschool>().single;
      final ignore = actions.whereType<DoNotImportFromWisa>().single;

      // There is nothing to create for an empty class, so the blacklist is the
      // lone decision and the notice rides beside it as context — never as the
      // other half of a radio pair, which is what it was until #329.
      expect(empty.canApply, isFalse);
      expect(empty.noticeFor, classImportAlternative);
      expect(empty.alternativeGroup, isNull);
      expect(empty.isDefaultAlternative, isFalse);

      expect(ignore.alternativeGroup, classImportAlternative);
      expect(ignore.isDefaultAlternative, isFalse);
      // The polarity is gone, so this flag is the whole of what keeps a bulk
      // pass off an empty class (#293/#326).
      expect(ignore.canApplyToAll, isFalse);
    });

    test('a populated class keeps its two-writes either/or, and one default',
        () {
      // The genuine choice: both halves write, so the radios stay and exactly
      // one of them is pre-selected.
      final actions = groupActionsFor(
        linkedGroup(wisa: wisaGroup()),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      final alternatives = actions
          .where((a) => a.alternativeGroup == classImportAlternative)
          .toList();

      expect(
        alternatives.map((a) => a.runtimeType),
        [AddToSmartschool, DoNotImportFromWisa],
      );
      expect(alternatives.every((a) => a.canApply), isTrue);
      expect(alternatives.where((a) => a.isDefaultAlternative), hasLength(1));
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

    test('a Smartschool leftover carries no alternative key at all (#328)', () {
      // It had one of its own until #328 — the pending list bulk-applies per
      // situation key, so the leftovers were kept out of the new-class subset.
      // The pair it keyed is gone: "laat deze klas staan" and "doe niets" are
      // the same act, and the operator performs the second by not pressing
      // Toepassen. What keeps `delClass` off every bulk path is the #293
      // sanction the delete withholds, read by both bulk paths since #326.
      final actions = groupActionsFor(linkedGroup(smartschool: ssGroup()));
      final delete = actions.whereType<DeleteSmartschoolClass>().single;

      expect(actions.map((a) => a.runtimeType), [DeleteSmartschoolClass]);
      expect(delete.alternativeGroup, isNull,
          reason: 'one action, so no alternative group and no radio pair');
      expect(delete.alternativeGroup, isNot(classImportAlternative));
      expect(delete.alternativeGroup, isNot(namesakeClassAlternative));
      expect(delete.isDefaultAlternative, isFalse);
      expect(delete.canApplyToAll, isFalse);
    });

    test('the leftover notice is a lone "(manueel)" row, never a half (#328)',
        () {
      final actions =
          groupActionsFor(linkedGroup(smartschool: ssGroup(code: ' ')));
      final notice = actions.whereType<DoNotImportFromSmartschool>().single;

      expect(notice.canApply, isFalse);
      expect(notice.alternativeGroup, isNull);
      expect(notice.isDefaultAlternative, isFalse);
      expect(actions.whereType<DeleteSmartschoolClass>(), isEmpty,
          reason: 'the two readings partition the leftovers — never both');
    });

    test('the namesake notice (#225) is context on a choice of its own (#329)',
        () {
      // The notice takes the create's place for a class Smartschool already
      // carries — but not the create's *side*: "go and make that group
      // official" is not something an apply can run. The blacklist is the lone
      // decision, under its own key, because "this class is already there, go
      // fix its flag" is a different situation from "create this class" and
      // must not share a bulk apply with it.
      final actions = groupActionsFor(
        linkedGroup(
          wisa: wisaGroup(name: '2G'),
          smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
        ),
        placementFor: (_) => groupPlacement(containsStudents: true),
      );
      final notice = actions.whereType<ClassExistsAsSmartschoolGroup>().single;
      final ignore = actions.whereType<DoNotImportFromWisa>().single;

      expect(notice.canApply, isFalse);
      expect(notice.noticeFor, namesakeClassAlternative);
      expect(notice.alternativeGroup, isNull);
      expect(notice.isDefaultAlternative, isFalse);

      expect(ignore.alternativeGroup, namesakeClassAlternative);
      expect(
        ignore.alternativeGroup,
        isNot(classImportAlternative),
        reason: 'a namesake class is not bulk-applied with the new classes',
      );
      expect(ignore.isDefaultAlternative, isFalse);
      // What holds #250 now that the polarity is gone.
      expect(ignore.canApplyToAll, isFalse);
      // Dispatch order still puts the situation before the proposal: it is the
      // order the card states them in.
      expect(actions.indexOf(notice), lessThan(actions.indexOf(ignore)));
    });

    test('the blacklist stands alone with its notice beside it (#250/#329)',
        () {
      // #250's shape: the creates refuse a namesake class, so `class-import`
      // was left holding only `DoNotImportFromWisa` — and a lone option is
      // always the selected one, which made "Apply to all" blacklist the class.
      // The lone-ness is back on purpose; the sanction is what refuses the bulk
      // pass now, and the reading the operator needs is still on the card.
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
        final notices = actions
            .where((a) => a.noticeFor == ignore.alternativeGroup)
            .toList();

        expect(siblings, hasLength(1),
            reason: 'nothing this app can do competes with the blacklist here');
        expect(ignore.canApplyToAll, isFalse,
            reason: 'no bulk pass may write it — the whole of #250 now');
        expect(
          notices.map((a) => a.runtimeType),
          [ClassExistsAsSmartschoolGroup],
          reason: 'the reading it contradicts is still on the card, as context',
        );
      }
    });
  });

  group('a notice is context, never an alternative (#329)', () {
    // The rule the whole alternative-group mechanism rests on, asserted over
    // the dispatch itself rather than over the widget that renders it: an
    // action with no automated write may not stand in an either/or, because
    // "here is what is wrong" and "here is the one thing the app can do" are
    // not comparable answers to one question. Such an action declares
    // `noticeFor` and rides along as context instead.
    //
    // Every fixture below is one that raises an informational action, so the
    // assertion has something to bite on in all three families.

    void expectNoNoOpAlternatives(Iterable<Object> actions) {
      for (final a in actions) {
        final (String? group, String? notice, bool canApply, bool isDefault) =
            switch (a) {
          GroupAction() => (
              a.alternativeGroup,
              a.noticeFor,
              a.canApply,
              a.isDefaultAlternative
            ),
          StudentAction() => (
              a.alternativeGroup,
              a.noticeFor,
              a.canApply,
              a.isDefaultAlternative
            ),
          StaffAction() => (
              a.alternativeGroup,
              a.noticeFor,
              a.canApply,
              a.isDefaultAlternative
            ),
          _ => throw StateError('unclassified action ${a.runtimeType}'),
        };
        final String what = a.runtimeType.toString();

        if (group != null) {
          expect(canApply, isTrue,
              reason: '$what stands in the "$group" either/or, so it must '
                  'write something');
        }
        if (notice != null) {
          expect(canApply, isFalse,
              reason: '$what is context, so it must have no automated write');
          expect(group, isNull,
              reason: '$what is context, so it is not one of the answers');
          expect(isDefault, isFalse,
              reason: '$what is not an option and cannot be the default one');
        }
      }
    }

    test('the group family', () {
      final populations = <List<GroupAction>>[
        // A namesake class, with and without students (#225/#250).
        for (final hasStudents in const [true, false])
          groupActionsFor(
            linkedGroup(
              wisa: wisaGroup(name: '2G'),
              smartschoolNamesake: ssGroupNode(code: 'G2G', name: '2G'),
            ),
            placementFor: (_) => groupPlacement(containsStudents: hasStudents),
          ),
        // A new class, empty and populated (#244).
        for (final hasStudents in const [true, false])
          groupActionsFor(
            linkedGroup(wisa: wisaGroup()),
            placementFor: (_) => groupPlacement(containsStudents: hasStudents),
          ),
        // The two leftovers, deletable and not (#327/#328).
        groupActionsFor(linkedGroup(smartschool: ssGroup())),
        groupActionsFor(linkedGroup(smartschool: ssGroup(code: ' '))),
      ];

      for (final actions in populations) {
        expectNoNoOpAlternatives(actions);
      }
      expect(
        populations.expand((a) => a).where((a) => !a.canApply),
        isNotEmpty,
        reason: 'the fixtures must actually raise informational actions',
      );
    });

    test('the student family', () {
      final populations = <List<StudentAction>>[
        // The family's informational member (#245): a student missing from
        // their own Office 365 class group.
        studentActionsFor(
          fullySynced(),
          config(),
          placementFor: (_) => classPlacement(),
          azurePlacementFor: (_) => const AzureClassPlacement(
            className: '3A',
            groupName: 'SSM-3A',
            groupExists: true,
          ),
        ),
        // The family's one either/or (#110): a departed student, unregister or
        // delete — two real writes.
        studentActionsFor(
          linked(smartschool: ssAccount(), azure: azureUser()),
          config(),
          placementFor: (_) => classPlacement(),
        ),
      ];

      for (final actions in populations) {
        expectNoNoOpAlternatives(actions);
      }
      expect(
        populations.expand((a) => a).where((a) => !a.canApply),
        isNotEmpty,
        reason: 'the fixtures must actually raise an informational action',
      );
      expect(
        populations.expand((a) => a).where(
            (a) => a.alternativeGroup == smartschoolDepartureAlternative),
        isNotEmpty,
        reason: 'and an either/or, so both halves of the rule are exercised',
      );
    });

    test('the staff family', () {
      // Every staff action is applyable today, so this asserts the other half
      // of the rule: an either/or made only of writes is exactly what the staff
      // import decision is, and it keeps its radios.
      final actions = staffActionsFor(
        linkedStaff(wisa: wisaStaff()),
        staffConfig(),
      );

      expectNoNoOpAlternatives(actions);
      expect(
        actions.where((a) => a.alternativeGroup == staffImportAlternative),
        isNotEmpty,
        reason: 'the fixture must actually raise an either/or',
      );
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
