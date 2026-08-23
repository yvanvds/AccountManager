import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' show Origin;
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

/// #296 — one action, applied across the **whole school**, with the cohort
/// resolvable before anything is written.
///
/// At the September rollover every student changes class group, so
/// `MoveToSmartschoolClassGroup` fires for the entire roster; doing that one
/// account at a time is not a workflow anyone follows. What makes it safe where
/// the global "Alles toepassen" of #294 was not is that the cohort is one
/// *decision* (#292) whose action carries the bulk sanction (#293) — so the
/// operator can read one description and know what the pass does to everyone in
/// it.
///
/// These pin the resolution the screen builds its affordance from: which
/// decisions get one at all, who is in the cohort, and that arming it writes
/// nothing.
void main() {
  const String move = 'Wijzig de klas in Smartschool';
  const String moveKey = 'student|MoveToSmartschoolClassGroup';
  const String renameKey = 'student|ModifyAzureName';

  PendingDecision decisionOf(
    ReconcileHarness h, {
    required String target,
    required String situationId,
  }) {
    final entry =
        h.controller.pendingEntries.firstWhere((e) => e.target == target);
    return PendingDecision(
      entry: entry,
      choice: entry.choices.singleWhere((c) => c.situationId == situationId),
    );
  }

  List<String> summariesOf(ReconcileHarness h) =>
      h.controller.applyResults!.map((r) => r.changes.summary).toList();

  group('the sanction reaches the pending list (#293/#296)', () {
    test("an option carries its action's canApplyToAll", () async {
      final h = rolloverHarness();
      await h.controller.sync();

      final sam =
          h.controller.pendingEntries.firstWhere((e) => e.target == 'Sam Sels');
      final flags = <String, bool>{
        for (final c in sam.choices) c.situationId: c.canApplyToAll,
      };

      expect(flags, <String, bool>{
        // Legacy granted the rollover move `canBeAppliedToAll`; this is the
        // action #296 exists for.
        'MoveToSmartschoolClassGroup': true,
        // A rename is a judgement call — the operator is meant to look at the
        // record.
        'ModifyAzureName': false,
      });
    });

    test('a destructive either/or is sanctioned on neither side', () async {
      // Unregister *vs* delete: #293 withholds both, so the decision gets no
      // school-wide affordance whichever way the operator resolves it.
      final h = ReconcileHarness(
        wisa: wisaSnap(students: const []),
        smartschool: ssSnap(
          groups: const [],
          accounts: [
            ssAccount(uid: 'jane', accountId: '1'),
            ssAccount(uid: 'john', accountId: '2'),
          ],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
      );
      await h.controller.sync();

      final entry = h.controller.pendingEntries.first;
      final choice = entry.choices.single;
      expect(choice.alternatives.map((a) => a.canApplyToAll),
          everyElement(isFalse));
      expect(
        h.controller
            .applyToAllCohort(PendingDecision(entry: entry, choice: choice)),
        isNull,
        reason: 'a delete over the whole school off one dialog is exactly what '
            'the sanction exists to refuse',
      );
    });
  });

  group('the cohort is the school, not the class (#296)', () {
    test('every student needing the move is in it', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      final cohort = h.controller.applyToAllCohort(
        decisionOf(h,
            target: 'Sam Sels', situationId: 'MoveToSmartschoolClassGroup'),
      )!;

      expect(cohort.key, moveKey);
      expect(cohort.label, move);
      expect(
        cohort.decisions.map((d) => d.entry.target),
        <String>['Sam Sels', 'Sara Segers', 'Tom Tas'],
        reason: 'armed from one card, resolved over the whole roster',
      );
    });

    test('a decision the action withholds gets no cohort at all', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      expect(
        h.controller.applyToAllCohort(
          decisionOf(h, target: 'Sam Sels', situationId: 'ModifyAzureName'),
        ),
        isNull,
      );
      expect(h.controller.applyToAllCohortFor(renameKey), isNull,
          reason: 'and not by the back door either — the members are what is '
              'checked, so the key cannot smuggle one in');
    });

    test('the cohort is exactly what the pass will write', () async {
      final h = rolloverHarness();
      await h.controller.sync();
      final cohort = h.controller.applyToAllCohortFor(moveKey)!;

      // Length, applyable count and the confirmation's change count are one
      // resolution — so the N on the button cannot over-claim.
      expect(cohort.length, 3);
      expect(cohort.applyableCount, 3);
      final scope = h.controller.applyScopeForDecisions(cohort.decisions);
      expect(scope.systems,
          <Origin>[Origin.smartschool, Origin.smartschool, Origin.smartschool]);
      expect(scope.chained, isEmpty);
    });

    test('resolving the cohort writes that decision and no other', () async {
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller
          .applyDecisions(h.controller.applyToAllCohortFor(moveKey)!.decisions);

      expect(summariesOf(h), <String>[move, move, move]);
      expect(
        h.graph.requests.where((r) => r.method == 'PATCH'),
        isEmpty,
        reason: "Sam's Office 365 rename shares his card and was never armed",
      );
    });
  });

  group('a member is in on its own selected alternative (#296)', () {
    test('only the sanctioned pick of a mixed either/or joins', () async {
      // The staff import decision mixes the two: "create in Office 365" is
      // sanctioned, "never import this person" is a blacklist and is withheld.
      // So a colleague set to the blacklist must not be swept along by a cohort
      // armed from a colleague set to the create.
      final h = newStaffChoiceHarness();
      await h.controller.sync();
      final key = 'staff|${actions.staffImportAlternative}';
      expect(h.controller.applyToAllCohortFor(key)!.length, 2);

      final second = h.controller.pendingEntries
          .where((e) => e.family == 'staff')
          .toList()[1];
      h.controller.chooseAlternative(
        entry: second,
        group: actions.staffImportAlternative,
        kind: 'DontImportStaffFromWisa',
      );

      final narrowed = h.controller.applyToAllCohortFor(key)!;
      expect(narrowed.length, 1);
      expect(narrowed.decisions.single.entry.targetId, isNot(second.targetId));
    });

    test('re-reading by key is what keeps a live review honest', () async {
      // The screen holds the key, never the members, precisely so a pick
      // changed mid-review moves the account out of the list, out of N and out
      // of the write together. Captured members would have applied the
      // resolution the operator changed their mind about.
      final h = newStaffChoiceHarness();
      await h.controller.sync();
      final key = 'staff|${actions.staffImportAlternative}';
      final armed = h.controller.applyToAllCohortFor(key)!;

      for (final entry
          in h.controller.pendingEntries.where((e) => e.family == 'staff')) {
        h.controller.chooseAlternative(
          entry: entry,
          group: actions.staffImportAlternative,
          kind: 'DontImportStaffFromWisa',
        );
      }

      expect(armed.length, 2, reason: 'the captured list is now stale…');
      expect(h.controller.applyToAllCohortFor(key), isNull,
          reason: '…and re-reading is what notices');
    });
  });

  group('arming resolves, it does not write (#296)', () {
    test('resolving the cohort touches no connector', () async {
      final h = rolloverHarness();
      await h.controller.sync();
      final soap = h.soap.soapActions.length;
      final graph = h.graph.requests.length;

      h.controller.applyToAllCohort(
        decisionOf(h,
            target: 'Sam Sels', situationId: 'MoveToSmartschoolClassGroup'),
      );

      expect(h.soap.soapActions, hasLength(soap));
      expect(h.graph.requests, hasLength(graph));
      expect(h.controller.applyResults, isNull);
    });

    test('a dry-run over the cohort leaves it standing', () async {
      // The pass the operator reads *before* pressing the one beside it, so it
      // must not dissolve the review it was started from.
      final h = rolloverHarness();
      await h.controller.sync();

      await h.controller.dryRunDecisions(
          h.controller.applyToAllCohortFor(moveKey)!.decisions);

      expect(h.controller.dryRunResults, hasLength(3));
      expect(h.soap.soapActions.where((a) => a.endsWith('#saveUserToClass')),
          isEmpty);
      expect(h.controller.applyToAllCohortFor(moveKey)!.length, 3);
    });
  });
}
