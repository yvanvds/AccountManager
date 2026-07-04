import 'package:account_actions/account_actions.dart' as actions;
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

/// #110 — the pending list groups one entry per account, renders the mutually
/// exclusive unregister/delete resolutions as a single choice, and applies only
/// the chosen alternative (never both), per-entry or per-situation.
void main() {
  /// A WISA-departed scenario: two Smartschool accounts with no WISA record and
  /// no Azure account, so each is an active Smartschool-only account whose
  /// dispatcher yields the unregister *vs* delete alternatives.
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

  group('grouping + alternatives (#110)', () {
    test(
        'one entry per departed account, each with a single unregister/delete '
        'choice defaulting to unregister', () async {
      final h = departedHarness();
      await h.controller.sync();

      final entries = h.controller.pendingEntries
          .where((e) => e.family == 'student')
          .toList();
      expect(entries, hasLength(2),
          reason: 'one entry per account, not per action');

      final entry = entries.first;
      expect(entry.choices, hasLength(1),
          reason:
              'the two mutually-exclusive actions collapse into one choice');
      final choice = entry.choices.single;
      expect(choice.isChoice, isTrue);
      expect(choice.alternatives, hasLength(2));
      expect(
        choice.alternatives.map((a) => a.kind),
        containsAll(<String>[
          'UnregisterStudentFromSmartschool',
          'DeleteStudentFromSmartschool',
        ]),
      );
      expect(choice.selected.kind, 'UnregisterStudentFromSmartschool',
          reason: 'unregister (keep the account) is the safe default');
    });

    test('the two departed accounts share one situation subset', () async {
      final h = departedHarness();
      await h.controller.sync();

      final studentSituations = h.controller.pendingSituations
          .where((s) => s.every((e) => e.family == 'student'))
          .toList();
      expect(studentSituations, hasLength(1),
          reason: 'both departed students are the same situation');
      expect(studentSituations.single, hasLength(2));
    });
  });

  group('apply runs exactly the chosen alternative (#110)', () {
    test('the default (unregister) applies unregister, not delete', () async {
      final h = departedHarness();
      await h.controller.sync();
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'student');

      await h.controller.applyEntry(entry);

      final summaries =
          h.controller.applyResults!.map((r) => r.changes.summary).toList();
      expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
      expect(
          summaries, isNot(contains('Verwijder dit account uit Smartschool')));
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
    });

    test('choosing delete applies delete, not unregister', () async {
      final h = departedHarness();
      await h.controller.sync();
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'student');

      h.controller.chooseAlternative(
        entry: entry,
        group: actions.smartschoolDepartureAlternative,
        kind: 'DeleteStudentFromSmartschool',
      );
      // Re-read the entry after the choice (the list is rebuilt).
      final chosen = h.controller.pendingEntries
          .firstWhere((e) => e.targetId == entry.targetId);
      expect(
          chosen.choices.single.selected.kind, 'DeleteStudentFromSmartschool');

      await h.controller.applyEntry(chosen);

      final summaries =
          h.controller.applyResults!.map((r) => r.changes.summary).toList();
      expect(summaries, contains('Verwijder dit account uit Smartschool'));
      expect(
          summaries, isNot(contains('Schrijf de leerling uit in Smartschool')));
    });

    test('situation bulk apply runs each entry\'s own chosen alternative',
        () async {
      final h = departedHarness();
      await h.controller.sync();
      final entries = h.controller.pendingEntries
          .where((e) => e.family == 'student')
          .toList();

      // Leave the first on the default (unregister); switch the second to delete.
      h.controller.chooseAlternative(
        entry: entries[1],
        group: actions.smartschoolDepartureAlternative,
        kind: 'DeleteStudentFromSmartschool',
      );

      final key = entries.first.situationKey;
      await h.controller.applySituation(key);

      final summaries =
          h.controller.applyResults!.map((r) => r.changes.summary).toList();
      expect(summaries, hasLength(2), reason: 'one write per account');
      expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
      expect(summaries, contains('Verwijder dit account uit Smartschool'));
    });

    test('applyableCount counts the chosen resolution once, not both',
        () async {
      final h = departedHarness();
      await h.controller.sync();
      // Two departed students → two writes (one resolution each), not four.
      expect(h.controller.applyableCount, 2);
    });
  });
}
