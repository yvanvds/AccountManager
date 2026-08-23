import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/screens/system_indicator.dart';
import 'package:account_state/account_state.dart' show CandidateAction;
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

CandidateAction _candidate({
  required String kind,
  required core.Origin system,
  bool canApply = true,
  String? alternativeGroup,
  bool isDefaultAlternative = false,
  String family = 'student',
}) =>
    CandidateAction(
      family: family,
      kind: kind,
      system: system,
      summary: kind,
      canApply: canApply,
      alternativeGroup: alternativeGroup,
      isDefaultAlternative: isDefaultAlternative,
    );

void main() {
  group('a cell shows the worst of presence and pending work (#298)', () {
    test('a record that is not there reads missing, work pending or not', () {
      expect(
        systemIndicatorState(present: false, hasWork: false),
        SystemIndicatorState.missing,
      );
      expect(
        systemIndicatorState(present: false, hasWork: true),
        SystemIndicatorState.missing,
        reason: 'not existing is the bigger fact; the work is usually the '
            'creation of it',
      );
    });

    test('a record that is there reads by its pending work', () {
      expect(
        systemIndicatorState(present: true, hasWork: true),
        SystemIndicatorState.needsWork,
      );
      expect(
        systemIndicatorState(present: true, hasWork: false),
        SystemIndicatorState.inOrder,
      );
    });
  });

  group('which systems a stored record has work in (#298)', () {
    test('an applyable candidate names its system', () {
      expect(
        workSystemsOfCandidates(<CandidateAction>[
          _candidate(
            kind: 'SyncAzureClassGroupMembers',
            system: core.Origin.azure,
            family: 'group',
          ),
        ]),
        <core.Origin>{core.Origin.azure},
      );
    });

    test('an informational candidate names none', () {
      // The concrete case the issue turns on: `AzureClassGroupMembership`
      // diagnoses an Office 365 roster problem the *class* row fixes, so a
      // student's Office 365 cell must stay green.
      expect(
        workSystemsOfCandidates(<CandidateAction>[
          _candidate(
            kind: 'AzureClassGroupMembership',
            system: core.Origin.azure,
            canApply: false,
          ),
        ]),
        isEmpty,
      );
      expect(
        systemIndicatorState(
          present: true,
          hasWork: workSystemsOfCandidates(<CandidateAction>[
            _candidate(
              kind: 'AzureClassGroupMembership',
              system: core.Origin.azure,
              canApply: false,
            ),
          ]).contains(core.Origin.azure),
        ),
        SystemIndicatorState.inOrder,
      );
    });

    test('an either/or is judged on the half that would actually run', () {
      // A stale class group's "leave it alone" notice is the default, so the
      // pair is not work until the operator switches to the delete.
      final notice = _candidate(
        kind: 'KeepStaleAzureClassGroup',
        system: core.Origin.azure,
        canApply: false,
        alternativeGroup: 'stale-group',
        isDefaultAlternative: true,
        family: 'group',
      );
      final delete = _candidate(
        kind: 'DeleteAzureClassGroup',
        system: core.Origin.azure,
        alternativeGroup: 'stale-group',
        family: 'group',
      );

      expect(
          workSystemsOfCandidates(<CandidateAction>[notice, delete]), isEmpty);
      expect(
        workSystemsOfCandidates(<CandidateAction>[
          _candidate(
            kind: 'KeepStaleAzureClassGroup',
            system: core.Origin.azure,
            canApply: false,
            alternativeGroup: 'stale-group',
          ),
          _candidate(
            kind: 'DeleteAzureClassGroup',
            system: core.Origin.azure,
            alternativeGroup: 'stale-group',
            isDefaultAlternative: true,
            family: 'group',
          ),
        ]),
        <core.Origin>{core.Origin.azure},
      );
    });

    test('two systems on one record are both named', () {
      expect(
        workSystemsOfCandidates(<CandidateAction>[
          _candidate(
            kind: 'AddClassToSmartschool',
            system: core.Origin.smartschool,
            family: 'group',
          ),
          _candidate(
            kind: 'CreateAzureClassGroup',
            system: core.Origin.azure,
            family: 'group',
          ),
        ]),
        <core.Origin>{core.Origin.smartschool, core.Origin.azure},
      );
    });
  });

  group('the live dispatch reads the same way (#298)', () {
    test(
        'the class carries the Office 365 work; its students carry none, '
        'because the write is one per class', () async {
      // The #245 fixture: both classes have their Office 365 group and are in
      // sync with Smartschool, so the only work anywhere is the Azure roster —
      // Jane is missing from GBS-1A, Sam sits in GBS-1A instead of GBS-1B.
      final harness = azureClassMembershipHarness();
      await harness.controller.sync();

      final klas = harness.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      expect(
        workSystemsOfEntry(klas),
        <core.Origin>{core.Origin.azure},
        reason: 'the roster write lands in Office 365, and the row must say so',
      );

      final students = harness.controller.pendingEntries
          .where((e) => e.family == 'student')
          .toList();
      expect(students, isNotEmpty);
      for (final student in students) {
        expect(
          student.choices.map((c) => c.selected.kind),
          everyElement('AzureClassGroupMembership'),
        );
        expect(
          workSystemsOfEntry(student),
          isEmpty,
          reason: '${student.target}: informational only — colouring it would '
              'paint every student orange at the rollover for work the Acties '
              'screen cannot do',
        );
      }
    });

    test('a class that is right everywhere has no work in any system',
        () async {
      final harness = azureClassGroupHarness();
      await harness.controller.sync();

      // `1A` is correct in all three systems, so it raises no entry at all.
      expect(
        harness.controller.groupPendingEntries.where((e) => e.targetId == '1A'),
        isEmpty,
      );
      for (final system in const <core.Origin>[
        core.Origin.wisa,
        core.Origin.smartschool,
        core.Origin.azure,
      ]) {
        expect(
          systemIndicatorState(present: true, hasWork: false),
          SystemIndicatorState.inOrder,
          reason: '$system',
        );
      }
    });
  });
}
