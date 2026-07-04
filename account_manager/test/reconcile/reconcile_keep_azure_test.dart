import 'package:account_actions/account_actions.dart' as actions;
import 'package:flutter_test/flutter_test.dart';

import 'reconcile_fakes.dart';

/// #134 — a student who left *our* school but is still in a sibling group
/// school surfaces the Smartschool departure in the reconcile pending list yet
/// **keeps** their Azure account (no `RemoveStudentFromAzure`), and applying the
/// departure never touches Azure. Mirrors `reconcile_pending_choice_test`.
void main() {
  group('keep-Azure sibling-school departure (#134)', () {
    test(
        'the departed student raises the Smartschool unregister/delete choice, '
        'never an Azure removal', () async {
      final h = movedToSiblingHarness();
      await h.controller.sync();

      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'student');
      final choice = entry.choices.single;
      expect(choice.isChoice, isTrue);
      expect(
        choice.alternatives.map((a) => a.kind),
        containsAll(<String>[
          'UnregisterStudentFromSmartschool',
          'DeleteStudentFromSmartschool',
        ]),
      );
      expect(choice.selected.kind, 'UnregisterStudentFromSmartschool',
          reason: 'unregister (keep the account) is the safe default');

      // No Azure removal anywhere in the pending set — the account is kept.
      final allKinds = h.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind);
      expect(allKinds, isNot(contains('RemoveStudentFromAzure')));
    });

    test('applying the departure writes to Smartschool and never touches Azure',
        () async {
      final h = movedToSiblingHarness();
      await h.controller.sync();
      final entry =
          h.controller.pendingEntries.firstWhere((e) => e.family == 'student');

      await h.controller.applyEntry(entry);

      final summaries =
          h.controller.applyResults!.map((r) => r.changes.summary).toList();
      expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
      expect(summaries, isNot(contains('Verwijder Azure account')));
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      // The real Smartschool write ran; Azure (Graph) was never called.
      expect(h.soap.soapActions, isNotEmpty);
      expect(h.graph.requests, isEmpty, reason: 'Azure account is kept');
    });
  });
}
