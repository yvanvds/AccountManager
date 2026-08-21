import 'package:account_actions/account_actions.dart' as actions;
import 'package:account_manager/src/reconcile/reconcile_controller.dart';
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
      // Re-read the subset after the choice (the list is rebuilt), exactly as
      // the screen does: `chooseAlternative` notifies, the bulk header rebuilds,
      // and it hands the pass the entries it is showing (#252).
      final chosen = h.controller.pendingEntries
          .where((e) => e.family == 'student')
          .toList();

      await h.controller.applyEntries(chosen);

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

  group('pendingEntries memoization (#111)', () {
    test('repeated reads return the identical cached list', () async {
      final h = departedHarness();
      await h.controller.sync();

      final first = h.controller.pendingEntries;
      final second = h.controller.pendingEntries;
      expect(identical(first, second), isTrue,
          reason: 'the entries are built once and cached, not per read');
    });

    test('choosing an alternative invalidates the cache', () async {
      final h = departedHarness();
      await h.controller.sync();

      final before = h.controller.pendingEntries;
      h.controller.chooseAlternative(
        entry: before.firstWhere((e) => e.family == 'student'),
        group: actions.smartschoolDepartureAlternative,
        kind: 'DeleteStudentFromSmartschool',
      );
      final after = h.controller.pendingEntries;

      expect(identical(before, after), isFalse,
          reason: 'a new pick must rebuild the entries so the choice shows');
      // …and the pick is reflected in the freshly built entry.
      final entry = after.firstWhere((e) => e.family == 'student');
      expect(
          entry.choices.single.selected.kind, 'DeleteStudentFromSmartschool');
    });

    test('a re-link rebuilds the cache from the fresh view', () async {
      final h = departedHarness();
      await h.controller.sync();
      final before = h.controller.pendingEntries;

      // A drift re-read re-links, replacing the linked view.
      await h.controller.checkDrift();
      final after = h.controller.pendingEntries;

      expect(identical(before, after), isFalse,
          reason: 'a fresh linked view must not serve a stale cached list');
    });
  });

  group('a new class is one choice, not two to-dos (#244)', () {
    const String create = 'Voeg deze klas toe aan Smartschool';
    const String ignore = 'Negeer deze klas bij het importeren uit WISA';

    List<String> summariesOf(ReconcileHarness h) =>
        h.controller.applyResults!.map((r) => r.changes.summary).toList();

    /// Whether the pass actually asked Smartschool to save a class. The
    /// recorded SOAP action is the fully-qualified `…V3#saveClass`.
    bool savedAClass(ReconcileHarness h) =>
        h.soap.soapActions.any((a) => a.endsWith('#saveClass'));

    test('the create and the blacklist collapse into one choice, create first',
        () async {
      final h = newClassChoiceHarness();
      await h.controller.sync();

      final entry = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      final choice = entry.choices.singleWhere(
        (c) => c.situationId == actions.classImportAlternative,
      );

      expect(choice.isChoice, isTrue,
          reason: 'either import the class or stop offering it — never both');
      expect(
        choice.alternatives.map((a) => a.kind),
        ['AddToSmartschool', 'DoNotImportFromWisa'],
        reason: 'the create leads the radio pair',
      );
      expect(choice.selected.kind, 'AddToSmartschool',
          reason: 'adding new classes is the normal start-of-year operation');
    });

    test('applying the default creates the class and blacklists nothing',
        () async {
      final h = newClassChoiceHarness();
      await h.controller.sync();
      final pulls = h.wisaSyncs;
      final entry = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');

      await h.controller.applyEntry(entry);

      expect(summariesOf(h), contains(create));
      expect(summariesOf(h), isNot(contains(ignore)),
          reason: 'the rule would drop the class we just created');
      expect(savedAClass(h), isTrue);
      expect(h.wisaSyncs, pulls,
          reason: 'no import rule was added, so WISA was never re-pulled');
    });

    test('choosing the blacklist applies it alone, creating nothing', () async {
      final h = newClassChoiceHarness();
      await h.controller.sync();
      final entry = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');

      h.controller.chooseAlternative(
        entry: entry,
        group: actions.classImportAlternative,
        kind: 'DoNotImportFromWisa',
      );
      final chosen = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      await h.controller.applyEntry(chosen);

      expect(summariesOf(h), contains(ignore));
      expect(summariesOf(h), isNot(contains(create)));
      expect(savedAClass(h), isFalse);
    });

    test(
        '"apply to all" over the situation creates every class and '
        'blacklists none', () async {
      // The report's headline: 21 new classes were created and then, in the
      // same pass, each had a DontImportClass rule written on the very name it
      // had just been created under.
      final h = newClassChoiceHarness();
      await h.controller.sync();
      final entries = h.controller.groupPendingEntries;
      expect(entries.map((e) => e.targetId), containsAll(<String>['1A', '1B']));

      final key = entries.firstWhere((e) => e.targetId == '1A').situationKey;
      final subset = entries.where((e) => e.situationKey == key).toList();
      expect(
        subset.map((e) => e.targetId),
        containsAll(<String>['1A', '1B']),
        reason: 'both new classes are the same situation, bulk-applied at once',
      );
      final pulls = h.wisaSyncs;

      await h.controller.applyEntries(subset);

      final summaries = summariesOf(h);
      expect(summaries.where((s) => s == create), hasLength(2));
      expect(summaries, isNot(contains(ignore)));
      expect(h.wisaSyncs, pulls);
    });

    test(
        'an empty class defaults to its notice, so a bulk apply writes '
        'nothing for it', () async {
      // The empty-class reading takes the create's place inside the same
      // choice. It is informational, so the entry offers no apply at all until
      // the operator deliberately picks "ignore this class".
      final h = siblingPopulatedClassHarness();
      await h.controller.sync();

      final entry = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      final choice = entry.choices.singleWhere(
        (c) => c.situationId == actions.classImportAlternative,
      );

      expect(choice.selected.kind, 'CreateInSmartschool');
      expect(choice.selected.canApply, isFalse);
      expect(entry.canApply, isFalse,
          reason: 'nothing to write for an empty class until the operator '
              'picks the opt-out');
      expect(
        choice.alternatives.map((a) => a.kind),
        containsAll(<String>['CreateInSmartschool', 'DoNotImportFromWisa']),
      );
    });
  });

  group('a class Smartschool already has is never blacklisted (#250)', () {
    const String notice =
        'Deze klas bestaat in Smartschool maar is geen officiële klas';
    const String ignore = 'Negeer deze klas bij het importeren uit WISA';
    const String create = 'Voeg deze klas toe aan Smartschool';

    List<String> summariesOf(ReconcileHarness h) =>
        h.controller.applyResults!.map((r) => r.changes.summary).toList();

    PendingAccountEntry entryFor(ReconcileHarness h, String id) =>
        h.controller.groupPendingEntries.firstWhere((e) => e.targetId == id);

    PendingChoice importChoiceOf(PendingAccountEntry entry) =>
        entry.choices.singleWhere(
          (c) => c.alternatives.any((a) => a.kind == 'DoNotImportFromWisa'),
        );

    test('the notice and the blacklist collapse into one choice, notice first',
        () async {
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final choice = importChoiceOf(entryFor(h, '2G'));

      expect(choice.situationId, actions.namesakeClassAlternative);
      expect(choice.isChoice, isTrue,
          reason: 'repair it by hand or stop offering it — never both, and '
              'never a choice of one');
      expect(
        choice.alternatives.map((a) => a.kind),
        ['ClassExistsAsSmartschoolGroup', 'DoNotImportFromWisa'],
        reason: 'the notice leads the radio pair',
      );
      expect(choice.selected.kind, 'ClassExistsAsSmartschoolGroup');
      expect(choice.selected.canApply, isFalse,
          reason: 'the default writes nothing: the repair is a hand edit');
    });

    test('a namesake class is not pooled with the new classes for bulk apply',
        () async {
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();

      expect(
        importChoiceOf(entryFor(h, '1A')).situationId,
        actions.classImportAlternative,
      );
      expect(
        entryFor(h, '2G').situationKey,
        isNot(entryFor(h, '1A').situationKey),
        reason: '"create this class" and "this class is already there" are two '
            'situations, so they get two bulk headers',
      );
      expect(entryFor(h, '2G').situationKey, entryFor(h, '2H').situationKey);
    });

    test('"apply to all" creates the new classes and blacklists no namesake',
        () async {
      // The report's headline: Apply to all wrote a DontImportClass rule on
      // every class the #225 notice had just told the operator to repair by
      // hand.
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final pulls = h.wisaSyncs;

      await h.controller.applyEntries(h.controller.groupPendingEntries);

      final summaries = summariesOf(h);
      expect(summaries, isNot(contains(ignore)),
          reason: 'the rule would drop the classes the notice says to repair');
      expect(summaries.where((s) => s == create), hasLength(2),
          reason: 'the genuinely new classes are still created');
      expect(
        h.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        hasLength(2),
        reason: '2G and 2H already exist downstream — never created again',
      );
      expect(h.wisaSyncs, pulls,
          reason: 'no import rule was added, so WISA was never re-pulled');
    });

    test('the operator can still blacklist a namesake class deliberately',
        () async {
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final entry = entryFor(h, '2G');
      expect(importChoiceOf(entry).selected.canApply, isFalse,
          reason: 'the import decision writes nothing until the operator '
              'picks the opt-out (the class\'s Office 365 group is a '
              'separate, orthogonal decision)');

      h.controller.chooseAlternative(
        entry: entry,
        group: actions.namesakeClassAlternative,
        kind: 'DoNotImportFromWisa',
      );
      final chosen = entryFor(h, '2G');
      expect(chosen.canApply, isTrue);

      await h.controller.applyEntry(chosen);

      expect(summariesOf(h), contains(ignore));
      expect(summariesOf(h), isNot(contains(notice)));
    });
  });

  group('a new staff member is one choice, not two to-dos (#248)', () {
    const String createAzure = 'Maak een nieuw Office 365 account';
    const String createSs = 'Maak een nieuw Smartschool account';
    const String ignore = 'Negeer dit account bij het importeren uit WISA';

    List<String> summariesOf(ReconcileHarness h) =>
        h.controller.applyResults!.map((r) => r.changes.summary).toList();

    List<PendingAccountEntry> staffEntries(ReconcileHarness h) =>
        h.controller.pendingEntries.where((e) => e.family == 'staff').toList();

    test('the create and the blacklist collapse into one choice, create first',
        () async {
      final h = newStaffChoiceHarness();
      await h.controller.sync();

      final entry = staffEntries(h).first;
      final choice = entry.choices.singleWhere(
        (c) => c.situationId == actions.staffImportAlternative,
      );

      expect(entry.choices, hasLength(1),
          reason: 'the two contradictory actions are one decision, not two');
      expect(choice.isChoice, isTrue,
          reason: 'either provision them or stop importing them — never both');
      expect(
        choice.alternatives.map((a) => a.kind),
        ['AddStaffToAzure', 'DontImportStaffFromWisa'],
        reason: 'the create leads the radio pair',
      );
      expect(choice.selected.kind, 'AddStaffToAzure',
          reason: 'provisioning a new hire is the normal operation');
    });

    test('applying the default provisions both accounts and blacklists nothing',
        () async {
      // The #240 chain still runs: the Azure create unlocks the Smartschool
      // create. What must not follow is the WISA opt-out that used to ride
      // along on the same click.
      final h = newStaffChoiceHarness();
      await h.controller.sync();
      final pulls = h.wisaSyncs;

      await h.controller.applyEntry(staffEntries(h).first);

      expect(summariesOf(h), <String>[createAzure, createSs]);
      expect(summariesOf(h), isNot(contains(ignore)),
          reason: 'the rule would drop the teacher we just provisioned');
      expect(h.graph.createdUsers, hasLength(1));
      expect(h.wisaSyncs, pulls,
          reason: 'no import rule was added, so WISA was never re-pulled');
    });

    test('choosing the blacklist applies it alone, provisioning nothing',
        () async {
      final h = newStaffChoiceHarness();
      await h.controller.sync();
      final entry = staffEntries(h).first;

      h.controller.chooseAlternative(
        entry: entry,
        group: actions.staffImportAlternative,
        kind: 'DontImportStaffFromWisa',
      );
      await h.controller.applyEntry(
        staffEntries(h).firstWhere((e) => e.targetId == entry.targetId),
      );

      expect(summariesOf(h), contains(ignore));
      expect(summariesOf(h), isNot(contains(createAzure)));
      expect(h.graph.createdUsers, isEmpty);
    });

    test(
        '"apply to all" over the situation provisions every new hire and '
        'blacklists none', () async {
      final h = newStaffChoiceHarness();
      await h.controller.sync();
      final entries = staffEntries(h);
      expect(entries, hasLength(2));

      final key = entries.first.situationKey;
      final subset = entries.where((e) => e.situationKey == key).toList();
      expect(
        subset,
        hasLength(2),
        reason: 'both new hires are the same situation, bulk-applied at once',
      );
      final pulls = h.wisaSyncs;

      await h.controller.applyEntries(subset);

      final summaries = summariesOf(h);
      expect(summaries.where((s) => s == createAzure), hasLength(2));
      expect(summaries.where((s) => s == createSs), hasLength(2));
      expect(summaries, isNot(contains(ignore)));
      expect(h.wisaSyncs, pulls);
    });
  });
}
