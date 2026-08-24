import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_core/account_core.dart' as core;
import 'package:account_state/account_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisa_api/wisa_api.dart' as wapi;

import 'reconcile_fakes.dart';

/// #349 — "medewerker uit dienst": the one resolution the dispatch cannot find.
///
/// WISA's staff export carries no employment status, so a teacher whose
/// dienstverband HR never closed arrives in every pull looking exactly like a
/// colleague who is staying. Nothing about her is pending, and until this
/// command existed nothing ever could be: the blacklist wanted her to have no
/// Smartschool account and the Smartschool removal wanted her gone from WISA, so
/// the two stood on each other's toes forever.
void main() {
  /// A teacher the school genuinely employs: present in all three systems and
  /// in step with every one of them, so she raises **no** decision at all.
  /// [department] is the comma list of schools other software maintains — the
  /// only thing the Office 365 half of a departure splits on.
  ReconcileHarness employed({
    String department = 'GBS',
    SettingsStore? settingsStore,
    LiveSettings? liveSettings,
  }) =>
      ReconcileHarness(
        wisa: wisaSnap(students: const [], staff: [wisaStaff()]),
        smartschool: ssSnap(
          groups: const [],
          accounts: [ssStaffAccount()],
          memberships: const [],
        ),
        azure: azSnap(users: [azStaffUser(department: department)]),
        settingsStore: settingsStore,
        liveSettings: liveSettings,
      );

  core.LinkedStaff theTeacher(ReconcileHarness h) => h.controller.liveStaffFor(
        h.controller.linked!.snapshot.staff.single.id.value,
      )!;

  group('the command exists only for the record on screen', () {
    test('she raises no decision, yet can be retired', () async {
      final h = employed();
      await h.controller.sync();

      expect(h.controller.pendingEntries.where((e) => e.family == 'staff'),
          isEmpty,
          reason: 'WISA reports her as employed, so §6.3 has nothing to say');
      expect(h.controller.canRetireStaff(theTeacher(h)), isTrue);
    });

    test('it is in no pending list, no cohort, and no count', () async {
      // The safety property. If a retirement could be reached from the pending
      // list it could be reached from a cohort, and a "Toepassen op alle" would
      // retire a staff room.
      final h = employed();
      await h.controller.sync();

      final kinds = h.controller.pendingEntries
          .expand((e) => e.choices)
          .expand((c) => c.alternatives)
          .map((a) => a.kind);
      expect(kinds, isNot(contains('RetireStaffMember')));
      expect(h.controller.staffPendingCount, 0);
      expect(h.controller.applyableCount, 0);
      expect(
        h.controller.pendingSituations.where((s) => s.key.startsWith('staff|')),
        isEmpty,
      );
    });

    test('the decision it builds refuses every bulk affordance', () async {
      final h = employed();
      await h.controller.sync();

      final decision = h.controller.retirementFor(theTeacher(h))!;
      expect(decision.canApply, isTrue);
      expect(decision.canApplyToAll, isFalse);
      expect(h.controller.applyToAllCohort(decision), isNull);
    });

    test('a teacher WISA has already let go is not a command case', () async {
      // She is an ordinary departed record by then, and the removals are on her
      // card — there is nothing left for the command to open.
      final h = ReconcileHarness(
        wisa: wisaSnap(students: const [], staff: const []),
        smartschool: ssSnap(
          groups: const [],
          accounts: [ssStaffAccount()],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
      );
      await h.controller.sync();

      expect(h.controller.canRetireStaff(theTeacher(h)), isFalse);
      expect(
        h.controller.pendingEntries
            .firstWhere((e) => e.family == 'staff')
            .choices
            .single
            .alternatives
            .map((a) => a.kind),
        containsAll(<String>[
          'DeactivateStaffInSmartschool',
          'RemoveStaffFromSmartschool',
        ]),
      );
    });
  });

  group('one command performs the whole retirement', () {
    test('the rule, the Smartschool account and the Office 365 account',
        () async {
      final h = employed();
      await h.controller.sync();

      await h.controller.retireStaff(theTeacher(h));

      expect(
        h.controller.applyResults!.map((r) => r.changes.summary),
        <String>[
          'Medewerker uit dienst — negeer dit account bij het importeren uit '
              'WISA',
          'Schakel het Smartschool account uit',
          'Verwijder Azure account',
        ],
      );
      expect(
        h.controller.applyResults!.map((r) => r.outcome),
        everyElement(actions.ActionOutcome.applied),
      );
      // Both writes really went out, and WISA — read-only — was not re-pulled.
      expect(
        h.soap.soapActions.any((a) => a.contains('setAccountStatus')),
        isTrue,
      );
      expect(h.graph.requests.any((r) => r.method == 'DELETE'), isTrue);
      expect(h.wisaSyncs, 1, reason: 'only the sync that started the session');
    });

    test('she is gone from the view the pass leaves behind', () async {
      final h = employed();
      await h.controller.sync();

      await h.controller.retireStaff(theTeacher(h));

      expect(h.controller.linked!.snapshot.staff, isEmpty);
      expect(h.controller.pendingEntries, isEmpty,
          reason: 'and nothing is proposed to re-create her');
    });

    test('a sibling school still claiming her keeps the Office 365 account',
        () async {
      final h = employed(department: 'GBS,OTHER');
      await h.controller.sync();

      await h.controller.retireStaff(theTeacher(h));

      expect(
        h.controller.applyResults!.map((r) => r.changes.summary),
        contains('Haal onze school uit het Office 365 account'),
      );
      expect(h.graph.requests.any((r) => r.method == 'DELETE'), isFalse,
          reason: "deleting it would destroy the sibling school's account");
    });

    test('the confirmation names all three systems (#234)', () async {
      final h = employed();
      await h.controller.sync();

      final scope = h.controller.retirementScope(theTeacher(h));
      expect(scope.systems, <core.Origin>[core.Origin.wisa]);
      expect(scope.chained,
          <core.Origin>{core.Origin.smartschool, core.Origin.azure});
    });

    test('a dry run writes nothing at all', () async {
      final h = employed();
      await h.controller.sync();

      await h.controller.retireStaff(theTeacher(h), dry: true);

      expect(h.controller.dryRunResults, isNotEmpty);
      expect(h.soap.soapActions, isEmpty);
      expect(h.graph.requests, isEmpty);
      expect(h.controller.linked!.snapshot.staff, hasLength(1));
    });

    test('the earned rule is persisted, so the next launch still has it (#276)',
        () async {
      // Without this the rule dies with the process, WISA keeps reporting her
      // active, and the app proposes re-creating the accounts it just removed.
      final settings = InMemorySettingsStore(const AppSettings());
      final h = employed(
        settingsStore: settings,
        liveSettings: LiveSettings(const AppSettings()),
      );
      await h.controller.sync();

      await h.controller.retireStaff(theTeacher(h));

      final saved = await settings.load();
      expect(
        saved.wisaRules
            .whereType<wapi.DontImportUserFromWisa>()
            .single
            .userCode,
        'SMIT',
      );
      // And it says who to ask about it (#285).
      expect(
        saved.provenanceOf(const wapi.DontImportUserFromWisa('SMIT'))!.subject,
        contains('Smit'),
      );
    });
  });
}
