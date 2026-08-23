import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' show Origin;
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

/// #292 — the **decision**, not the account, is the unit a bulk apply acts on.
///
/// The grouping used to key on the family plus the sorted set of *every*
/// decision on a card, so two students who both needed their Smartschool class
/// changed fell into different subsets the moment one of them also needed a
/// name fix — and the pass behind the header ran every selected option of every
/// card it was given, so applying "the class change" also wrote the name fix.
/// Both halves are fixed here: one decision, one cohort; and a cohort's apply
/// runs that decision alone.
void main() {
  const String move = 'Wijzig de klas in Smartschool';
  const String rename = 'Wijzig de naam in Azure';
  const String moveKey = 'student|MoveToSmartschoolClassGroup';
  const String renameKey = 'student|ModifyAzureName';

  SituationCohort cohort(ReconcileHarness h, String key) =>
      h.controller.pendingSituations.firstWhere((c) => c.key == key);

  PendingAccountEntry studentNamed(ReconcileHarness h, String name) =>
      h.controller.pendingEntries.firstWhere((e) => e.target == name);

  List<String> summariesOf(ReconcileHarness h) =>
      h.controller.applyResults!.map((r) => r.changes.summary).toList();

  List<String> graphPatches(ReconcileHarness h) => h.graph.requests
      .where((r) => r.method == 'PATCH')
      .map((r) => r.url.path)
      .toList();

  int smartschoolMoves(ReconcileHarness h) =>
      h.soap.soapActions.where((a) => a.endsWith('#saveUserToClass')).length;

  /// Two WISA-departed Smartschool accounts, each raising the unregister *vs*
  /// delete either/or — one cohort with two members that resolve differently.
  ReconcileHarness departedHarness() => ReconcileHarness(
        wisa: wisaSnap(students: const []),
        smartschool: ssSnap(
          groups: const [],
          accounts: [
            ssAccount(
              uid: 'jane',
              accountId: '1',
              mail: 'jane.doe@student.school.example',
            ),
            ssAccount(
              uid: 'john',
              accountId: '2',
              mail: 'john.roe@student.school.example',
            ),
          ],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
      );

  group('one decision, one cohort (#292)', () {
    test(
        'every student needing the class change is in its cohort, whatever '
        'else is on their card', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      expect(
        cohort(h, moveKey).decisions.map((d) => d.entry.target),
        <String>['Sam Sels', 'Sara Segers', 'Tom Tas'],
        reason: "Sam's stale Office 365 name used to file him under a "
            'combination of his own, so the class change reached two of three',
      );
      expect(cohort(h, moveKey).label, move);
    });

    test('a card with two decisions appears in both cohorts', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      expect(
        cohort(h, renameKey).decisions.map((d) => d.entry.target),
        <String>['Sam Sels'],
      );
      final sam = studentNamed(h, 'Sam Sels');
      expect(sam.choices.map((c) => c.situationId), <String>[
        'ModifyAzureName',
        'MoveToSmartschoolClassGroup',
      ]);
    });

    test('the cohort a screen renders is grouped from the rows it shows',
        () async {
      // The standing rule since #252: label, confirmation scope and write come
      // from one list. A search box narrows the entries, and the cohorts are
      // regrouped from what survived — never filtered back out of the whole
      // linked view.
      final h = rolloverHarness();
      await h.controller.sync();
      final shown = h.controller.pendingEntries
          .where((e) => e.family == 'student' && e.target != 'Tom Tas')
          .toList();

      final cohorts = ReconcileController.situationCohorts(shown);
      expect(
        cohorts.firstWhere((c) => c.key == moveKey).length,
        2,
        reason: 'Tom is off the screen, so no button may reach him',
      );
    });
  });

  group('a cohort applies its own decision and nothing else (#292)', () {
    test('the class change is written for all three, the name fix for none',
        () async {
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller.applyDecisions(cohort(h, moveKey).decisions);

      expect(summariesOf(h), <String>[move, move, move]);
      expect(smartschoolMoves(h), 3);
      expect(graphPatches(h), isEmpty,
          reason: "Sam's Office 365 name is a decision the operator did not "
              'press — a bulk pass that wrote it would be writing something '
              'nobody read on the header');
    });

    test("the decision the pass skipped is still Sam's to make afterwards",
        () async {
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller.applyDecisions(cohort(h, moveKey).decisions);

      expect(
        cohort(h, renameKey).decisions.map((d) => d.entry.target),
        <String>['Sam Sels'],
        reason: 'the pass answered one question and left the other open, '
            'rather than resolving it on his behalf',
      );
      expect(graphPatches(h), isEmpty);
    });

    test('each member still contributes its own selected alternative',
        () async {
      // Two departed students, one set to unregister and one to delete, applied
      // as cards — the #110 guarantee, unchanged by the move to per-decision
      // passes. Read as *cards* rather than as a cohort because neither
      // resolution is bulk-sanctioned: see the #326 test below, which is the
      // other half of this pair.
      final h = departedHarness();
      await h.controller.sync();
      final departure =
          cohort(h, 'student|${actions.smartschoolDepartureAlternative}');
      expect(departure.length, 2);

      h.controller.chooseAlternative(
        entry: departure.decisions.last.entry,
        group: actions.smartschoolDepartureAlternative,
        kind: 'DeleteStudentFromSmartschool',
      );
      // Re-read after the pick, exactly as the screen does: `chooseAlternative`
      // notifies and the entries are rebuilt.
      final chosen =
          cohort(h, 'student|${actions.smartschoolDepartureAlternative}');

      await h.controller
          .applyEntries(chosen.decisions.map((d) => d.entry).toList());

      expect(summariesOf(h), hasLength(2));
      expect(
          summariesOf(h), contains('Schrijf de leerling uit in Smartschool'));
      expect(summariesOf(h), contains('Verwijder dit account uit Smartschool'));
    });

    test('a bulk pass writes none of a situation #293 withholds (#326)',
        () async {
      // The same two departed students, through the bulk seam this time. Both
      // resolutions of the departure either/or are withheld from a bulk pass —
      // unregistering a student who merely fell out of a lagging WISA snapshot
      // is as wrong as deleting them — so the pass must write neither, however
      // the radios are set. It used to write both: the narrowing lived only in
      // the situation header's count, which asked whether the *selected* option
      // writes anything, and a flipped radio makes that true.
      final h = departedHarness();
      await h.controller.sync();
      final departure =
          cohort(h, 'student|${actions.smartschoolDepartureAlternative}');
      h.controller.chooseAlternative(
        entry: departure.decisions.last.entry,
        group: actions.smartschoolDepartureAlternative,
        kind: 'DeleteStudentFromSmartschool',
      );
      final chosen =
          cohort(h, 'student|${actions.smartschoolDepartureAlternative}');
      expect(chosen.decisions.every((d) => d.canApply), isTrue,
          reason: 'both rows are set to a resolution that writes something — '
              'the pre-#326 count would have read 2');
      expect(chosen.applyableCount, 0,
          reason: 'and not one of them may be written in bulk');
      expect(chosen.bulkApplyable, isEmpty);

      await h.controller.applyDecisions(chosen.decisions);

      expect(h.controller.applyResults, isNull,
          reason: 'the pass never started, so no verdict block appears');
      expect(
        h.soap.soapActions.where(
            (a) => a.endsWith('#delUser') || a.endsWith('#unregisterStudent')),
        isEmpty,
      );
    });

    test('the whole-card apply still writes every decision on that card',
        () async {
      // The convenience #292 deliberately keeps: it is not blind, because every
      // decision on the card is on screen above the button.
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller.applyEntry(studentNamed(h, 'Sam Sels'));

      expect(summariesOf(h), containsAll(<String>[rename, move]));
      expect(graphPatches(h), hasLength(1));
      expect(smartschoolMoves(h), 1);
    });
  });

  group('the confirmation dialog describes the one decision (#292)', () {
    test('a cohort scope counts and names only its own decision', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      final scope =
          h.controller.applyScopeForDecisions(cohort(h, moveKey).decisions);

      expect(
          scope.systems,
          <Origin>[
            Origin.smartschool,
            Origin.smartschool,
            Origin.smartschool,
          ],
          reason: 'three class changes — never the Office 365 rename that '
              "shares Sam's card");
      expect(scope.chained, isEmpty);
    });

    test('the whole-card scope over the same students still counts everything',
        () async {
      // The contrast that makes the narrowing visible: the same three accounts,
      // read as cards rather than as one decision, are four writes across two
      // systems.
      final h = rolloverHarness();
      await h.controller.sync();
      final students = h.controller.pendingEntries
          .where((e) => e.family == 'student')
          .toList();

      final scope = h.controller.applyScope(students);

      expect(scope.systems, hasLength(4));
      expect(scope.systems, contains(Origin.azure));
    });
  });

  group('a verdict still lands under the decision it answers (#283)', () {
    test('a per-decision pass routes its rows to the right block', () async {
      // A dry run settles nothing, so both of Sam's decisions are still on his
      // card to be answered — which is exactly the state that makes the routing
      // observable.
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller.dryRunDecisions(cohort(h, moveKey).decisions);

      final sam = studentNamed(h, 'Sam Sels');
      final moveChoice = sam.choices
          .singleWhere((c) => c.situationId == 'MoveToSmartschoolClassGroup');
      final renameChoice =
          sam.choices.singleWhere((c) => c.situationId == 'ModifyAzureName');

      expect(
        h.controller
            .applyOutcomesForChoice(sam, moveChoice)
            .map((r) => r.changes.summary),
        <String>[move],
      );
      expect(h.controller.applyOutcomesForChoice(sam, renameChoice), isEmpty,
          reason: 'the pass never touched that decision, so its block reports '
              'nothing');
      expect(h.controller.unroutedApplyOutcomesFor(sam), isEmpty);
    });
  });
}
