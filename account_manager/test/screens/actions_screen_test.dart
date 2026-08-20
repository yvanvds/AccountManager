import 'package:account_core/account_core.dart' show Address;
import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A tall viewport so the drill-down tree and a drilled-into classroom's tiles
/// lay out without the assertions tripping on the fold.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Drills a Leerlingen top-level node — a merged "Jaar N" or the
/// "Niet toegewezen" bucket — straight into one of its classrooms. #210 dropped
/// the school level, so exactly one accordion sits above the class.
Future<void> _drill(
  WidgetTester tester, {
  required String node,
  required String classroom,
}) async {
  await tester.tap(find.text(node));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(classroom));
  await tester.tap(find.text(classroom));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ActionsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-dry-run')), findsNothing);
  });

  testWidgets(
      'the Actions tab browses actions by year → class drill-down and loads one '
      "classroom's actions on demand via readClassroom (#154)",
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    // A sync on the Reconcile screen populates the shared controller; drive it
    // programmatically, then open the Actions tab over the same controller.
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The rollup tree is the browser; the flat list is gone. The top of it is
    // the grade-year, never the school (#210). No classroom is loaded until the
    // operator drills into one.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('Jaar 3'), findsOneWidget);
    expect(find.text('School 1'), findsNothing);
    expect(harness.controller.selectedClassroom, isNull);
    expect(harness.controller.classroomAccounts, isNull);
    expect(find.byKey(const ValueKey('actions-classroom-back')), findsNothing);

    // Drill in: only the 3C classroom's accounts load (via readClassroom), and
    // that class's pending action tile builds.
    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(harness.controller.selectedClassroom?.classroom, '3C');
    expect(harness.controller.classroomAccounts, hasLength(1));
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // Back to the overview tree.
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(find.text('Jaar 3'), findsOneWidget);
  });

  testWidgets(
      'the global Dry-run all / Apply all act across all classes (#154)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Dry-run everything from the header — no drill needed, nothing written.
    await tester.tap(find.byKey(const ValueKey('actions-dry-run')));
    await tester.pumpAndSettle();
    expect(find.text('Dry-run result'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply everything: confirm the dialog, the Smartschool write happens.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Apply pending actions?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty);
  });

  testWidgets('cancelling the apply dialog writes nothing (#154)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(find.text('Apply result'), findsNothing);
  });

  /// A WISA-departed scenario: [count] Smartschool-only active accounts (no
  /// WISA, no Azure), each raising the mutually-exclusive unregister/delete
  /// choice (#110). They land in the "Niet toegewezen" → "Zonder klas" bucket
  /// (#210 collapsed its always-synthetic grade level away).
  ReconcileHarness departedHarness({int count = 1}) => ReconcileHarness(
        wisa: wisaSnap(students: const []),
        smartschool: ssSnap(
          groups: const [],
          accounts: [
            for (var i = 0; i < count; i++)
              ssAccount(
                uid: 'user$i',
                accountId: '$i',
                mail: 'user$i@student.school.example',
              ),
          ],
          memberships: const [],
        ),
        azure: azSnap(users: const []),
      );

  testWidgets(
      'a departed student in the drill-down renders one entry with a '
      'unregister/delete choice; picking delete applies delete (#110/#154)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = departedHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Niet toegewezen', classroom: 'Zonder klas');

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final id = entry.targetId;
    final entryKey = ValueKey('entry-student-$id');
    expect(find.byKey(entryKey), findsOneWidget);

    await tester.ensureVisible(find.byKey(entryKey));
    await tester.tap(find.byKey(entryKey));
    await tester.pumpAndSettle();

    final unregisterAlt = ValueKey('alt-$id-UnregisterStudentFromSmartschool');
    final deleteAlt = ValueKey('alt-$id-DeleteStudentFromSmartschool');
    expect(find.byKey(unregisterAlt), findsOneWidget);
    expect(find.byKey(deleteAlt), findsOneWidget);

    await tester.tap(find.byKey(deleteAlt));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.soap.soapActions, isNotEmpty,
        reason: 'delete is a real Smartschool write');
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary);
    expect(summaries, contains('Verwijder dit account uit Smartschool'));
    expect(summaries, isNot(contains('Schrijf de leerling uit in Smartschool')),
        reason: 'only the chosen alternative runs — never both');
  });

  testWidgets(
      "a same-situation subset in one class offers a bulk apply per row's "
      'choice (#110/#154)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = departedHarness(count: 2);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Niet toegewezen', classroom: 'Zonder klas');

    expect(
        find.textContaining('accounts in the same situation'), findsOneWidget);
    final key = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student')
        .situationKey;
    final bulkApply = ValueKey('situation-apply-$key');
    expect(find.byKey(bulkApply), findsOneWidget);

    await tester.ensureVisible(find.byKey(bulkApply));
    await tester.tap(find.byKey(bulkApply));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Apply result'), findsOneWidget);
    expect(harness.controller.applyResults, hasLength(2));
  });

  testWidgets(
      "a large class's actions virtualize: only a bounded number of entry "
      'tiles build, and scrolling builds/unloads them (#111/#154)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = departedHarness(count: 2000);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Niet toegewezen', classroom: 'Zonder klas');

    // All 2000 sit in this one class, each one pending entry.
    expect(harness.controller.classroomPendingEntries, hasLength(2000));

    final entryTiles = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-'),
    );
    final builtInitially = entryTiles.evaluate().length;
    expect(builtInitially, greaterThan(0));
    expect(builtInitially, lessThan(200),
        reason: 'virtualized: on-screen tiles only, not all 2000');

    final entries = harness.controller.classroomPendingEntries;
    final firstKey = ValueKey('entry-student-${entries.first.targetId}');
    final lastKey = ValueKey('entry-student-${entries.last.targetId}');
    expect(find.byKey(lastKey), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(lastKey),
      5000,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 200,
    );
    expect(find.byKey(lastKey), findsOneWidget);
    expect(find.byKey(firstKey), findsNothing,
        reason: 'the first tile unloaded once scrolled far off-screen');
  });

  // --- School-less student drill-down (#210) -------------------------------

  testWidgets(
      'the Leerlingen overview opens on grade-years merged across the managed '
      'schools, with no school level anywhere (#210)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = twoSchoolHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The years are the accordion, in a pinned order; neither school is a node.
    expect(find.text('Jaar 1'), findsOneWidget);
    expect(find.text('Jaar 3'), findsOneWidget);
    expect(find.text('School 1'), findsNothing);
    expect(find.text('School 2'), findsNothing);
    // The synthetic non-numeric bucket never renders as "Jaar Overig".
    expect(find.text('Overige klassen'), findsOneWidget);
    expect(find.text('Jaar Overig'), findsNothing);

    // "Jaar 1" holds both schools' first years side by side…
    await tester.tap(find.text('Jaar 1'));
    await tester.pumpAndSettle();
    expect(find.text('1A'), findsOneWidget);
    expect(find.text('1B'), findsOneWidget);

    // …and opening one still targets that class's own school partition.
    await tester.ensureVisible(find.text('1B'));
    await tester.tap(find.text('1B'));
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom?.classroom, '1B');
    expect(harness.controller.selectedClassroom?.school, '2');
    expect(harness.controller.classroomAccounts, hasLength(1));
  });

  // --- Personeel / Leerlingen family tabs (#179) ---------------------------

  testWidgets(
      'the Actions view splits staff and student actions into Personeel and '
      'Leerlingen tabs, each drilling only its own family (#179)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // One student (default fixture) plus one WISA staff member, so both
    // families carry a rollup node.
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The horizontal family tab bar carries both tabs.
    expect(
        find.byKey(const ValueKey('actions-tab-leerlingen')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-tab-personeel')), findsOneWidget);

    // The counts are partitioned by family, and together they sum the total —
    // nothing dropped or double-counted.
    expect(harness.controller.staffPendingCount, greaterThan(0));
    expect(harness.controller.studentPendingCount, greaterThan(0));
    expect(
      harness.controller.staffPendingCount +
          harness.controller.studentPendingCount,
      harness.controller.totalPendingCount,
    );

    // Default tab = Leerlingen: the merged grade-year is the drill root (#210)
    // and the class-groups node shows; the staff ("Personeel") node does not.
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-groups')), findsWidgets);
    expect(
        find.byKey(const ValueKey('rollup-school-school|staff')), findsNothing);

    // Switch to Personeel: the staff node appears and the student grade /
    // class-groups nodes are gone — each tab shows only its own family.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-school-school|staff')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsNothing);
    expect(find.byKey(const ValueKey('rollup-groups')), findsNothing);
  });

  testWidgets(
      'switching tabs mid-drill closes the open classroom so each tab opens at '
      'its own overview (#179)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Drill into a student class on the Leerlingen tab.
    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(harness.controller.selectedClassroom?.classroom, '3C');
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);

    // Switching to Personeel closes the drill-down; that tab opens at its own
    // staff overview rather than showing the student class.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom, isNull);
    expect(find.byKey(const ValueKey('actions-classroom-back')), findsNothing);
    expect(find.byKey(const ValueKey('rollup-school-school|staff')),
        findsOneWidget);
  });

  // --- Classroom filters: toggle + name search (#187) ----------------------

  testWidgets(
      'the Leerlingen classroom toggle shows only accounts with actions, and '
      'that tab carries no name search (#187)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // A passive-session class with a mix: one student with an applyable action,
    // one without. The toggle must narrow to the former (its `hasPending`).
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
      matAccount(id: 's2', label: 'Kees Bakker', withAction: false),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    // Both accounts show unfiltered; the Leerlingen tab has no search box.
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Kees Bakker'), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-search')), findsNothing);

    // Toggle "only with actions": the action-free account drops out.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Kees Bakker'), findsNothing);
  });

  testWidgets(
      'the Personeel classroom search matches any part of the name in any '
      'order and combines with the only-with-actions toggle (#187/#217)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // Three staff in the one synthetic Personeel class: two share the surname
    // "Smit" (one with an action, one without) and one distinct voornaam.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matStaff(id: 't1', label: 'Anna Smit', withAction: true),
      matStaff(id: 't2', label: 'Bram Jansen', withAction: false),
      matStaff(id: 't3', label: 'Clara Smit', withAction: false),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Switch to the Personeel tab and drill into its single staff class.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rollup-school-school|staff')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('rollup-grade-grade|staff|Personeel')));
    await tester.pumpAndSettle();
    final staffClass = find
        .byKey(const ValueKey('rollup-class-class|staff|Personeel|Personeel'));
    await tester.ensureVisible(staffClass);
    await tester.tap(staffClass);
    await tester.pumpAndSettle();

    // All three show; the Personeel tab carries the search box.
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Bram Jansen'), findsOneWidget);
    expect(find.text('Clara Smit'), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-search')), findsOneWidget);

    // Search on the naam "Smit": both Smits match, Jansen drops.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsOneWidget);
    expect(find.text('Bram Jansen'), findsNothing);

    // Search on the voornaam "Bram": only Jansen matches.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'bram');
    await tester.pump();
    expect(find.text('Bram Jansen'), findsOneWidget);
    expect(find.text('Anna Smit'), findsNothing);
    expect(find.text('Clara Smit'), findsNothing);

    // Both halves, in the stored order and reversed (#217): either way round
    // finds the one person. Reversed used to return nothing, because the needle
    // was matched as one contiguous substring of "Voornaam Naam".
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'anna smit');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit anna');
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    expect(find.text('Bram Jansen'), findsNothing);

    // Every part must occur: parts taken from two different people match
    // neither, rather than matching both.
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'anna jansen');
    await tester.pump();
    expect(
        find.text('Geen accounts die aan de filter voldoen.'), findsOneWidget);

    // Combine the toggle with the search: search "Smit" AND only-with-actions
    // keeps just Anna (Clara matches the name but has no action).
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit');
    await tester.pump();
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('Anna Smit'), findsOneWidget);
    expect(find.text('Clara Smit'), findsNothing);
    expect(find.text('Bram Jansen'), findsNothing);

    // A query matching nothing shows the filter-empty line, not the class-empty
    // one.
    await tester.enterText(find.byKey(const ValueKey('actions-search')), 'zzz');
    await tester.pump();
    expect(
        find.text('Geen accounts die aan de filter voldoen.'), findsOneWidget);
  });

  // --- Address diff in the drill-down (#153) -------------------------------
  const wisaAddr = Address(
    street: 'Koophandelstraat',
    houseNumber: '32',
    postalCode: '3270',
    city: 'Scherpenheuvel',
    country: 'BE',
  );
  Address ssAddr({String postalCode = '3270'}) => Address(
        street: 'Koophandelstraat',
        houseNumber: '32',
        houseNumberAdd: '',
        postalCode: postalCode,
        city: 'Scherpenheuvel',
        country: 'België',
      );
  ReconcileHarness addressHarness(
          {required Address ss, required Address wisa}) =>
      ReconcileHarness(
        wisa: wisaSnap(students: [wisaStudent(address: wisa)]),
        smartschool: ssSnap(
          groups: [ssGroup('3C', code: '3C_ss')],
          accounts: [ssAccount(address: ss)],
          memberships: [member('jane', '3C_ss')],
        ),
      );

  testWidgets(
      'a real postalCode drift raises the address action in the class and its '
      'expanded diff shows only the differing field (#153/#154)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = addressHarness(ss: ssAddr(), wisa: wisaAddr);
    harness.wisaResult = wisaSnap(students: [
      wisaStudent(
        address: const Address(
          street: 'Koophandelstraat',
          houseNumber: '32',
          postalCode: '3271',
          city: 'Scherpenheuvel',
          country: 'BE',
        ),
      ),
    ]);
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(find.text('Wijzig het adres in Smartschool'), findsWidgets);

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    final entryKey = ValueKey('entry-student-${entry.targetId}');
    await tester.ensureVisible(find.byKey(entryKey));
    await tester.tap(find.byKey(entryKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('postalCode: 3270 → 3271'), findsOneWidget);
    expect(find.textContaining('street:'), findsNothing);
    expect(find.textContaining('city:'), findsNothing);
  });

  // --- Passive-session drill-downs (no pull, no link) ----------------------

  testWidgets(
      'a passive session drills into a classroom read-only via readClassroom, '
      'loading only that class (#115/#154)', (WidgetTester tester) async {
    // Tall, like its siblings: the read-only notice #214 added above the list
    // costs the first card its place on an 800×600 fold, and this test is about
    // which class was read, not about where the fold falls.
    _useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Overzicht'), findsOneWidget);
    // The stored view projects to the same school-less tree the syncing
    // session rendered (#210).
    expect(find.text('Jaar 3'), findsOneWidget);
    expect(find.text('School 1'), findsNothing);
    expect(s2.controller.linked, isNull,
        reason: 'link() is never called in a passive session');
    // Nothing loaded until the operator drills in.
    expect(s2.controller.classroomAccounts, isNull);

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    // Only the 3C class was read; the read-only account tile renders.
    expect(s2.controller.classroomAccounts, hasLength(1));
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);
  });

  testWidgets(
      'the Klasgroepen drill-down proposes only classes of the schools we '
      'manage, and describes ours rather than the sibling class that shares '
      'its name (#205)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = foreignClassGroupHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('rollup-groups')));
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    // Our own populated class is the one and only proposal…
    expect(find.text('1A'), findsOneWidget);
    expect(find.text('Voeg deze klas toe aan Smartschool'), findsOneWidget);
    // …and the sibling school's class is never offered: applying it would
    // create another school's class in our Smartschool.
    expect(find.text('9Z'), findsNothing);

    // Expanding it shows *our* class's data — the sibling `1A` used to arrive
    // first and shadow ours, so the proposal described the wrong class.
    await tester.tap(find.byKey(const ValueKey('entry-group-1A')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Onze eerste klas'), findsOneWidget);
    expect(find.textContaining('Klas van een andere school'), findsNothing);
  });

  testWidgets(
      'a passive session surfaces the Klasgroepen node and opens the group '
      'detail (#119/#154)', (WidgetTester tester) async {
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rollup-groups')), findsOneWidget);
    expect(find.text('Klasgroepen'), findsWidgets);

    await tester.ensureVisible(find.byKey(const ValueKey('rollup-groups')));
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions-groups-back')), findsOneWidget);
    expect(find.text('2B'), findsWidgets);
    expect(
        find.textContaining('Deze klas bestaat in Smartschool'), findsWidgets);
    expect(s2.controller.linked, isNull);

    await tester.tap(find.byKey(const ValueKey('actions-groups-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-groups')), findsOneWidget);
  });

  testWidgets(
      "a generation bump refetches the passive Actions overview's freshness "
      '(#108)', (WidgetTester tester) async {
    final linkedStore = InMemoryLinkedStore();
    final snapshots = InMemorySnapshotStore();

    final s1 = ReconcileHarness(store: snapshots, linkedStore: linkedStore);
    await s1.controller.sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Generatie 1'), findsOneWidget);

    s1.wisaResult = wisaSnap(
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
      students: [wisaStudent(classGroup: '3D')],
    );
    await s1.controller.sync();
    await s2.controller.onStoreChanged(2);
    await tester.pumpAndSettle();

    expect(find.textContaining('Generatie 2'), findsOneWidget);
    expect(find.textContaining('Generatie 1'), findsNothing);
  });

  testWidgets(
      "the overview's freshness stamp carries the date once the shared state "
      'is no longer from today (#192)', (WidgetTester tester) async {
    // The shared view was materialized at kFixtureDate, a past day. Time-only
    // rendered that as "Generatie 1 · 02:00 door …" —
    // indistinguishable from a view materialized minutes ago, the same
    // confusion #192 fixes on the Reconcile last-sync box.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Derived here rather than through the production formatter, so this pins
    // the rendered text instead of restating the implementation.
    final DateTime t = kFixtureDate.toLocal();
    final String dm = '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}';
    final String hhmm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';

    expect(find.textContaining('Generatie 1 · $dm'), findsOneWidget);
    expect(find.textContaining('Generatie 1 · $hhmm'), findsNothing,
        reason: 'a stamp from a past day is never rendered as bare time');
  });

  // --- The read-only drill-down state (#214) -------------------------------

  final readOnly = find.byKey(const ValueKey('actions-read-only'));
  final readOnlySync = find.byKey(const ValueKey('actions-read-only-sync'));

  testWidgets(
      'a passive classroom drill-down announces itself as read-only, styles '
      'its cards inert and offers the sync (#214)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // A passive session: the shared documents are there to read, but nothing is
    // linked, so no choice, dry-run or apply exists for the accounts below.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The overview itself is browsable as ever — only a drill-down, where the
    // actions are supposed to be actionable, carries the notice.
    expect(readOnly, findsNothing);

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(harness.controller.linked, isNull);

    // The state is named instead of silently swapping in static cards.
    expect(readOnly, findsOneWidget);
    expect(find.text('Alleen-lezen overzicht'), findsOneWidget);
    expect(find.textContaining('nog niet gesynchroniseerd'), findsOneWidget);

    // …with the sync affordance right there, and live.
    expect(tester.widget<FilledButton>(readOnlySync).onPressed, isNotNull);

    // The account card is styled as the inert thing it is, rather than passing
    // for one of the interactive entry tiles.
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    final candidate = tester.widget<Text>(
      find.text('• Wijzig de klas in Smartschool'),
    );
    expect(
      candidate.style?.color,
      Theme.of(tester.element(readOnly)).disabledColor,
      reason: 'a summary nobody can act on is not rendered as live body text',
    );
  });

  testWidgets(
      'the passive Klasgroepen drill-down carries the same read-only '
      'announcement (#214)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('rollup-groups')));
    await tester.tap(find.byKey(const ValueKey('rollup-groups')));
    await tester.pumpAndSettle();

    expect(s2.controller.linked, isNull);
    expect(find.byKey(const ValueKey('actions-groups-back')), findsOneWidget);
    expect(readOnly, findsOneWidget,
        reason: 'the group drill-down falls back to the same static tiles');
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
  });

  testWidgets(
      'an active session drills into the same class with no read-only notice — '
      'those tiles really are interactive (#214)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    expect(harness.controller.linked, isNotNull);
    expect(readOnly, findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(find.byKey(const ValueKey('rollup-groups')), findsNothing);
  });

  testWidgets(
      'a session whose sync failed is told the sync failed, not that it never '
      'ran (#214)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // The second reproduction path of #214: the pass died before it could link
    // (the Azure delta-token failure of #213 was one such), so this session has
    // an error *and* no linked view. `_fail` leaves any previously linked view
    // untouched, so this wording is only ever reached when there was none.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store)
      ..wisaError = StateError('WISA host unreachable');
    await harness.controller.sync();
    expect(harness.controller.error, contains('WISA host unreachable'));
    expect(harness.controller.linked, isNull);

    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    expect(readOnly, findsOneWidget);
    expect(find.textContaining('De laatste sync is mislukt'), findsOneWidget);
    expect(find.textContaining('nog niet gesynchroniseerd'), findsNothing);
  });

  testWidgets(
      "the read-only banner's sync is disabled and named when another operator "
      'holds the lease (#214/#108)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final snapshots = InMemorySnapshotStore();
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(store: snapshots, linkedStore: linkedStore)
        .controller
        .sync();
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

    final s2 = await ReconcileHarness.resume(
      store: snapshots,
      linkedStore: linkedStore,
    );
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    expect(readOnly, findsOneWidget);
    expect(tester.widget<FilledButton>(readOnlySync).onPressed, isNull);
    expect(find.textContaining('mieke@school'), findsOneWidget,
        reason: 'a dead button needs its reason on screen too');
  });
}
