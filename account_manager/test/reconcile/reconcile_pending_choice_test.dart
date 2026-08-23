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

    test('the two departed accounts share one situation cohort', () async {
      final h = departedHarness();
      await h.controller.sync();

      final studentCohorts = h.controller.pendingSituations
          .where((c) => c.decisions.every((d) => d.entry.family == 'student'))
          .toList();
      expect(studentCohorts, hasLength(1),
          reason: 'both departed students are the same situation');
      expect(studentCohorts.single.length, 2);
      expect(
        studentCohorts.single.key,
        'student|${actions.smartschoolDepartureAlternative}',
        reason: 'a cohort is keyed by the one decision it groups (#292)',
      );
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

    test(
        'an apply pass refreshes the derived lists once, not once per write '
        '(#299)', () async {
      // A pass relinks after every write and notifies once per action to drive
      // the progress dialog (#243), so a screen listening to it re-derives the
      // whole school between one write and the next: `describeChanges()` over
      // every pending action, plus a materialize of every account. At the
      // September rollover that is thousands of writes, and the list being
      // re-derived is behind a modal nobody can read.
      // Three students in one situation — a rename each, which a real write
      // genuinely settles — so the pass makes three writes, three relinks and
      // a settled view to land on.
      final h = crossClassSituationHarness();
      await h.controller.sync();

      // Exactly what a rebuild reads, on exactly the notifications it rebuilds
      // on — so this counts the refreshes the screen would really have paid
      // for, not the cache misses in the abstract.
      final accountLists = <Object>[];
      final entryLists = <Object>[];
      void record() {
        final Object accounts = h.controller.linkedAccounts;
        if (!accountLists.any((o) => identical(o, accounts))) {
          accountLists.add(accounts);
        }
        final Object entries = h.controller.pendingEntries;
        if (!entryLists.any((o) => identical(o, entries))) {
          entryLists.add(entries);
        }
      }

      final cohort = h.controller.pendingSituations
          .firstWhere((c) => c.key == 'student|ModifyAzureName');
      expect(cohort.decisions, hasLength(3),
          reason: 'three students share the rename');

      // Run as cards rather than through the cohort seam: the rename is not
      // bulk-sanctioned (#293), so since #326 `applyDecisions` writes none of
      // it. What is under test here is the pinning of the derived lists across
      // a multi-write pass, and the whole-card pass is one — each of these
      // three cards carries the rename and nothing else.
      h.controller.addListener(record);
      await h.controller
          .applyEntries(cohort.decisions.map((d) => d.entry).toList());
      h.controller.removeListener(record);

      const reason = 'the view the pass started from, then the settled one — '
          'the three intermediate relinks are the ones nobody can read';
      expect(accountLists, hasLength(2), reason: reason);
      expect(entryLists, hasLength(2), reason: reason);

      // …and the second of each really is the settled view: the pass released
      // the pinned lists before it announced it was over.
      expect(
        h.controller.pendingSituations
            .where((c) => c.key == 'student|ModifyAzureName'),
        isEmpty,
        reason: 'the three renames were written, so nothing raises them again',
      );
      expect(identical(h.controller.pendingEntries, entryLists.last), isTrue);
      expect(identical(h.controller.linkedAccounts, accountLists.last), isTrue);
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

      final cohort = h.controller.groupPendingSituations.firstWhere(
          (c) => c.key == 'group|${actions.classImportAlternative}');
      expect(
        cohort.decisions.map((d) => d.entry.targetId),
        containsAll(<String>['1A', '1B']),
        reason: 'both new classes are the same situation, bulk-applied at once',
      );
      final pulls = h.wisaSyncs;

      await h.controller.applyDecisions(cohort.decisions);

      final summaries = summariesOf(h);
      expect(summaries.where((s) => s == create), hasLength(2));
      expect(summaries, isNot(contains(ignore)));
      expect(summaries, hasLength(2),
          reason: 'the cohort is one decision, so the pass writes that '
              "decision and nothing else on the classes' cards — their "
              'Office 365 groups are a decision of their own (#292)');
      expect(h.wisaSyncs, pulls);
    });

    test(
        'an empty class states its notice as context, with the blacklist as '
        'the lone action (#329)', () async {
      // There is nothing to create for an empty class, so the card proposes
      // exactly one thing and says why: "delete it by hand, or wait until it
      // has students". Until #329 that instruction was the pre-selected half of
      // a radio pair, which asked the operator to choose between a diagnosis
      // and the one write there is.
      final h = siblingPopulatedClassHarness();
      await h.controller.sync();

      final entry = h.controller.groupPendingEntries
          .firstWhere((e) => e.targetId == '1A');
      final choice = entry.choices.singleWhere(
        (c) => c.situationId == actions.classImportAlternative,
      );

      expect(choice.isChoice, isFalse, reason: 'no radio group');
      expect(choice.alternatives.map((a) => a.kind),
          <String>['DoNotImportFromWisa']);
      expect(choice.selected.kind, 'DoNotImportFromWisa');
      expect(
        choice.notices.map((a) => a.kind),
        <String>['CreateInSmartschool'],
        reason: 'the instruction survives as context on the decision',
      );
      expect(choice.notices.single.canApply, isFalse);
      expect(
        choice.notices.single.changes.summary,
        contains('bevat nog geen leerlingen'),
      );
    });

    test('no bulk pass writes DontImportClass on an empty class (#250/#329)',
        () async {
      // What replaces the polarity that used to keep the blacklist off this
      // path: the #293 sanction, which every bulk affordance reads since #326.
      // The blacklist is the *selected* resolution of an empty class now, so
      // this is the only thing standing between it and one press.
      final h = siblingPopulatedClassHarness();
      await h.controller.sync();
      final pulls = h.wisaSyncs;

      final cohort = h.controller.groupPendingSituations.firstWhere(
          (c) => c.key == 'group|${actions.classImportAlternative}');
      expect(cohort.decisions.map((d) => d.entry.targetId), contains('1A'));
      expect(
        cohort.bulkApplyable.map((d) => d.entry.targetId),
        isNot(contains('1A')),
        reason: 'the header offers this class nothing (#326)',
      );

      await h.controller.applyDecisions(cohort.decisions);

      expect(
        (h.controller.applyResults ?? const []).map((r) => r.changes.summary),
        isNot(contains(ignore)),
      );
      expect(h.wisaSyncs, pulls,
          reason: 'no import rule was added, so WISA was never re-pulled');
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

    test('the notice is context on the blacklist, not a radio beside it (#329)',
        () async {
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final choice = importChoiceOf(entryFor(h, '2G'));

      expect(choice.situationId, actions.namesakeClassAlternative);
      expect(choice.isChoice, isFalse,
          reason: '"go and make it official in Smartschool" is not something '
              'an apply can run, so it is not one of the answers');
      expect(
        choice.alternatives.map((a) => a.kind),
        <String>['DoNotImportFromWisa'],
      );
      expect(choice.selected.kind, 'DoNotImportFromWisa');
      expect(
        choice.notices.map((a) => a.kind),
        <String>['ClassExistsAsSmartschoolGroup'],
        reason: 'the repair instruction is still on the card, as context',
      );
      expect(choice.notices.single.canApply, isFalse);
      expect(choice.notices.single.changes.summary, contains(notice));
      expect(
        choice.notices.single.changes.fields.map((f) => f.field),
        contains('code'),
        reason: 'the group code is how the operator finds it in Smartschool',
      );
    });

    test('a namesake class is not pooled with the new classes for bulk apply',
        () async {
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();

      expect(
        importChoiceOf(entryFor(h, '1A')).situationId,
        actions.classImportAlternative,
      );
      final cohorts = h.controller.groupPendingSituations;
      final namesake = cohorts.firstWhere(
        (c) => c.key == 'group|${actions.namesakeClassAlternative}',
      );
      final fresh = cohorts.firstWhere(
        (c) => c.key == 'group|${actions.classImportAlternative}',
      );
      expect(
        namesake.decisions.map((d) => d.entry.targetId),
        <String>['2G', '2H'],
        reason: '"create this class" and "this class is already there" are two '
            'situations, so they get two bulk headers',
      );
      expect(
          fresh.decisions.map((d) => d.entry.targetId), <String>['1A', '1B']);
      expect(namesake.applyableCount, 0,
          reason: 'the blacklist withholds the #293 sanction, so this cohort '
              'offers nothing to apply in bulk even though it is now the '
              'selected resolution of both its rows (#326/#329)');
      expect(namesake.bulkApplyable, isEmpty);
    });

    test('no bulk pass blacklists a namesake class (#250/#329)', () async {
      // The report's headline: Apply to all wrote a DontImportClass rule on
      // every class the #225 notice had just told the operator to repair by
      // hand.
      //
      // What refused it then was the *polarity* of a radio pair — the notice
      // was the pre-selected half, so nothing was written unless the operator
      // flipped a radio, and flipping two of them armed the header anyway. The
      // notice is context now, so the blacklist is what every namesake row is
      // set to, and this pins the replacement guard directly: the #293 sanction
      // the blacklist withholds, refused at the bulk seam itself since #326.
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final pulls = h.wisaSyncs;

      final cohorts = h.controller.groupPendingSituations;
      final namesake = cohorts.firstWhere(
        (c) => c.key == 'group|${actions.namesakeClassAlternative}',
      );
      final fresh = cohorts.firstWhere(
        (c) => c.key == 'group|${actions.classImportAlternative}',
      );

      await h.controller.applyDecisions(namesake.decisions);
      expect(h.controller.applyResults, isNull,
          reason: 'every member is withheld, so the pass never starts');
      expect(
        h.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        isEmpty,
      );
      expect(h.wisaSyncs, pulls,
          reason: 'no import rule was added, so WISA was never re-pulled');
      expect(
        h.log.entries.map((e) => e.message),
        contains(contains('Overgeslagen in de groepsbewerking')),
        reason: 'a refused bulk write is stated, not swallowed (#326)',
      );

      // And the fix did not simply silence the list: the genuinely new classes
      // beside them are still created by their own cohort's bulk pass.
      await h.controller.applyDecisions(fresh.decisions);
      final summaries = summariesOf(h);
      expect(summaries.where((s) => s == create), hasLength(2));
      expect(summaries, isNot(contains(ignore)));
    });

    test('the per-card Toepassen writes the blacklist, and only that (#329)',
        () async {
      // The card proposes; it does not interrogate. The operator reads the
      // notice above it — "this class already exists in Smartschool, make it
      // official there" — and either presses Toepassen, which blacklists the
      // class, or ignores the card, which is a complete answer. What they are
      // no longer asked to do is record which of the two they meant.
      final h = namesakeClassChoiceHarness();
      await h.controller.sync();
      final entry = entryFor(h, '2G');

      expect(importChoiceOf(entry).selected.kind, 'DoNotImportFromWisa');
      expect(entry.canApply, isTrue);

      await h.controller.applyEntry(entry);

      expect(summariesOf(h), contains(ignore));
      expect(summariesOf(h), isNot(contains(notice)),
          reason: 'a notice is never dispatched — its apply throws');
      expect(
        h.soap.soapActions.where((a) => a.endsWith('#saveClass')),
        isEmpty,
        reason: '2G already exists downstream — never created',
      );
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

      final cohort = h.controller.pendingSituations.firstWhere(
          (c) => c.key == 'staff|${actions.staffImportAlternative}');
      expect(
        cohort.decisions.map((d) => d.entry.targetId),
        entries.map((e) => e.targetId),
        reason: 'both new hires are the same situation, bulk-applied at once',
      );
      final pulls = h.wisaSyncs;

      await h.controller.applyDecisions(cohort.decisions);

      final summaries = summariesOf(h);
      expect(summaries.where((s) => s == createAzure), hasLength(2));
      expect(summaries.where((s) => s == createSs), hasLength(2));
      expect(summaries, isNot(contains(ignore)));
      expect(h.wisaSyncs, pulls);
    });
  });
}
