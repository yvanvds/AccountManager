import 'dart:async';

import 'package:account_actions/account_actions.dart' show ActionOutcome;
import 'package:account_core/account_core.dart' show Address, Origin;
import 'package:account_manager/src/reconcile/reconcile_controller.dart'
    show ApplyScope;
import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart' show SmartschoolAccount;

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

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-dry-run')), findsNothing);
  });

  testWidgets('a failed bootstrap offers a retry, in Dutch (#253)',
      (WidgetTester tester) async {
    // The stand-in panels are as operator-facing as the tree they replace, so
    // they speak the same language as it. The retry itself is the point of the
    // panel: a second attempt has to be one button away.
    var attempts = 0;
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: () async {
      attempts++;
      if (attempts == 1) throw StateError('geen verbinding');
      return ReconcileHarness().bootstrap();
    })));
    await tester.pumpAndSettle();

    expect(find.text('Kan het Acties-scherm niet openen'), findsOneWidget);
    final retry = find.byKey(const ValueKey('actions-bootstrap-retry'));
    expect(find.descendant(of: retry, matching: find.text('Probeer opnieuw')),
        findsOneWidget);

    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Kan het Acties-scherm niet openen'), findsNothing);
    expect(find.text('Acties'), findsOneWidget);
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
    expect(find.text('Resultaat van de dry-run'), findsOneWidget);
    expect(harness.soap.soapActions, isEmpty);

    // Apply everything: confirm the dialog, the Smartschool write happens.
    await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
    await tester.tap(find.byKey(const ValueKey('actions-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Openstaande acties toepassen?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
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
    await tester.tap(find.text('Annuleer'));
    await tester.pumpAndSettle();

    expect(harness.soap.soapActions, isEmpty);
    expect(find.text('Resultaat van het toepassen'), findsNothing);
  });

  group('the apply-confirmation dialog says what the pass really writes (#234)',
      () {
    // The sentence used to be hard-coded — "This writes N change(s) to
    // Smartschool and Azure AD" — for every action, so a single Graph PATCH on
    // one display name announced a write to a system it never touches. These
    // pin the sentence itself; the widget/e2e cases below prove the screen
    // feeds it the right scope.
    ApplyScope scope(List<Origin> systems, {Set<Origin> chained = const {}}) =>
        ApplyScope(systems: systems, chained: chained);

    test('one Azure change names Office 365 only', () {
      expect(
        applyConfirmationMessage(scope(<Origin>[Origin.azure])),
        'Dit schrijft 1 wijziging naar Office 365. Doe eerst een dry-run om '
        'de exacte wijzigingen te bekijken.',
      );
    });

    test('a mixed selection names each system it really targets', () {
      expect(
        applyConfirmationMessage(
          scope(<Origin>[Origin.azure, Origin.smartschool, Origin.azure]),
        ),
        startsWith('Dit schrijft 3 wijzigingen naar Smartschool en '
            'Office 365.'),
      );
    });

    test('the WISA opt-out family claims no write at all', () {
      // DontImportStaffFromWisa & co carry Origin.wisa on their ChangeSet, but
      // WISA is read-only here: what they produce is an import rule.
      final message = applyConfirmationMessage(scope(<Origin>[Origin.wisa]));
      expect(
        message,
        startsWith('Dit bewaart 1 importregel blijvend voor iedereen (er wordt '
            'niets naar WISA geschreven).'),
      );
      expect(message, isNot(contains('schrijft 1 wijziging')));
    });

    test('the rule is announced as permanent and shared (#276)', () {
      // The rule is written to the shared settings document, so it outlives the
      // session and every other operator inherits it. A sentence that read like
      // a one-run decision would be the operator's only warning before an
      // irreversible-looking click.
      final message = applyConfirmationMessage(scope(<Origin>[Origin.wisa]));
      expect(message, contains('blijvend'));
      expect(message, contains('voor iedereen'));
    });

    test('a rule beside a real write is counted apart from it', () {
      expect(
        applyConfirmationMessage(scope(<Origin>[Origin.azure, Origin.wisa])),
        startsWith('Dit schrijft 1 wijziging naar Office 365 en bewaart 1 '
            'importregel blijvend voor iedereen (er wordt niets naar WISA '
            'geschreven).'),
      );
    });

    test('a chained follow-up names its system, without inflating the count',
        () {
      // A new student's Office 365 create writes Smartschool too (#230/#240).
      // Whether it runs is decided by the follow-up's own evaluate after the
      // first write, so it is named, never counted.
      expect(
        applyConfirmationMessage(
          scope(<Origin>[Origin.azure], chained: <Origin>{Origin.smartschool}),
        ),
        startsWith('Dit schrijft 1 wijziging naar Office 365. Een vervolgactie '
            'kan ook naar Smartschool schrijven.'),
      );
    });

    test('nothing selected claims nothing', () {
      expect(
        applyConfirmationMessage(ApplyScope.empty),
        startsWith('Dit schrijft niets.'),
      );
    });
  });

  /// A student who is in all three systems and in sync except for their Azure
  /// `displayName` — the exact report in #234: one `ModifyAzureName`, a single
  /// Graph `PATCH`, and nothing whatsoever for Smartschool.
  ReconcileHarness nameDriftHarness() => ReconcileHarness(
        wisa: wisaSnap(
          students: [wisaStudent(wisaId: '1', classGroup: '3C')],
          schools: [wisaSchool(1)],
          classGroups: [wisaClassGroup('3C', adminCode: 'a3')],
        ),
        smartschool: ssSnap(
          groups: [ssGroup('3C', code: '3C_ss', untis: '3C')],
          accounts: [ssAccount()],
          memberships: [member('jane', '3C_ss')],
        ),
        // displayName left empty — the one thing that differs from WISA.
        azure: azSnap(users: [azUser()]),
      );

  testWidgets(
      'applying one Azure-only action announces Office 365, not "Smartschool '
      'and Azure AD" (#234)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = nameDriftHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    final entry = harness.controller.pendingEntries
        .firstWhere((e) => e.family == 'student');
    expect(
      entry.choices.map((c) => c.selected.changes.summary),
      <String>['Wijzig de naam in Azure'],
      reason: 'the fixture raises exactly the action the bug report names',
    );

    final id = entry.targetId;
    await tester.ensureVisible(find.byKey(ValueKey('entry-student-$id')));
    await tester.tap(find.byKey(ValueKey('entry-student-$id')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(find.text('Toepassen voor ${entry.target}?'), findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching:
            find.textContaining('Dit schrijft 1 wijziging naar Office 365.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('Smartschool')),
      findsNothing,
      reason: 'the pass never touches Smartschool',
    );
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
    // An unregister carries no field diff, so the detail under the radios is
    // the lifecycle note — in Dutch, like the rest of the screen (#253).
    expect(find.text('Levenscyclusactie — geen wijzigingen per veld.'),
        findsOneWidget);

    await tester.tap(find.byKey(deleteAlt));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
    await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
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
        find.textContaining('accounts in dezelfde situatie'), findsOneWidget);
    final key = harness.controller.classroomPendingSituations.single.key;
    final bulkApply = ValueKey('situation-apply-$key');
    expect(find.byKey(bulkApply), findsOneWidget);

    // Switch the second row to delete, leaving the first on the default. The
    // header hands the pass the entries it is *showing*, so the pick has to
    // survive the rebuild that publishes it (#110/#252).
    final second = harness.controller.classroomPendingEntries[1].targetId;
    await tester.ensureVisible(find.byKey(ValueKey('entry-student-$second')));
    await tester.tap(find.byKey(ValueKey('entry-student-$second')));
    await tester.pumpAndSettle();
    final deleteAlt =
        find.byKey(ValueKey('alt-$second-DeleteStudentFromSmartschool'));
    await tester.ensureVisible(deleteAlt);
    await tester.tap(deleteAlt);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(bulkApply));
    await tester.tap(find.byKey(bulkApply));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.controller.applyResults, hasLength(2));
    final summaries =
        harness.controller.applyResults!.map((r) => r.changes.summary).toList();
    expect(summaries, contains('Schrijf de leerling uit in Smartschool'));
    expect(summaries, contains('Verwijder dit account uit Smartschool'),
        reason: "the bulk pass runs each row's own chosen alternative");
  });

  testWidgets(
      "a class's bulk apply stops at that class: the identical situation in "
      'another class is left untouched (#252)', (WidgetTester tester) async {
    // Three students in one situation — a stale Office 365 name — split across
    // two classes: Sam and Sara in 3C, Tom in 3D. The bulk header lives inside
    // one class and counts one class, but the pass behind it used to resolve
    // its situation key back through the whole linked view, so pressing
    // "Alles toepassen (2)" in 3C wrote Tom too.
    _useTallWindow(tester);
    final harness = crossClassSituationHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    final inClass = harness.controller.classroomPendingEntries;
    expect(inClass, hasLength(2), reason: '3C holds Sam and Sara');
    final key = harness.controller.classroomPendingSituations.single.key;
    expect(
      harness.controller.pendingSituations
          .firstWhere((c) => c.key == key)
          .length,
      3,
      reason: "Tom's 3D entry is the very same situation, group-wide",
    );

    // The button's own count is the class's, and so is what it writes.
    final bulkApply = find.byKey(ValueKey('situation-apply-$key'));
    await tester.ensureVisible(bulkApply);
    expect(tester.widget<FilledButton>(bulkApply).child, isA<Text>());
    expect(
        find.descendant(
            of: bulkApply, matching: find.text('Alles toepassen (2)')),
        findsOneWidget);

    await tester.tap(bulkApply);
    await tester.pumpAndSettle();
    // The confirmation quotes the same two writes, not three (#234).
    expect(find.textContaining('2 wijzigingen'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    expect(harness.controller.applyResults, hasLength(2),
        reason: 'one write per account of the open class');
    final patched = harness.graph.requests
        .where((r) => r.method == 'PATCH')
        .map((r) => r.url.path)
        .toList();
    expect(patched, hasLength(2));
    expect(patched.any((p) => p.endsWith(kSam3C)), isTrue);
    expect(patched.any((p) => p.endsWith(kSara3C)), isTrue);
    expect(patched.any((p) => p.endsWith(kTom3D)), isFalse,
        reason: 'the operator never opened 3D — it must not be written');
    // …and Tom's work is still pending, waiting for someone to open his class.
    expect(
      harness.controller.pendingSituations
          .firstWhere((c) => c.key == key)
          .length,
      1,
    );
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

    // Default tab = Leerlingen: the merged grade-year is the drill root (#210);
    // the staff ("Personeel") node does not show. Neither does a class-groups
    // node — since #227 the classes are a top-level tab of their own, so this
    // tree carries accounts only.
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-groups')), findsNothing);
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

  // --- The global Acties filter + the Personeel name search (#187/#226) -----

  testWidgets(
      'the global filter lists only accounts with actions inside an opened '
      'Leerlingen class, is set in exactly one place, and gives the full class '
      'back when switched off (#187/#226)', (WidgetTester tester) async {
    _useTallWindow(tester);
    // A passive-session class with a mix: one student with an applyable action,
    // one without. The filter must narrow to the former (its `hasPending`).
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
      matAccount(id: 's2', label: 'Kees Bakker', withAction: false),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // One switch, on the Acties tab itself and already on — the operator never
    // sets it per class (#226).
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    // The action-free account is already out, with nothing touched in here; the
    // Leerlingen tab has no search box, and no second copy of the switch.
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Kees Bakker'), findsNothing);
    expect(find.byKey(const ValueKey('actions-search')), findsNothing);
    expect(toggle, findsOneWidget,
        reason: 'the filter is not settable in two places');

    // Switched off, the class is the full inventory again.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Kees Bakker'), findsOneWidget);
  });

  testWidgets(
      'the Personeel classroom search matches any part of the name in any '
      'order and combines with the only-with-actions filter (#187/#217/#226)',
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

    // The global filter is on by default (#226); this half of the test is about
    // the name search, so start from the full inventory.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
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

    // Combine the two: search "Smit" AND the global only-with-actions filter
    // back on keeps just Anna (Clara matches the name but has no action).
    await tester.enterText(
        find.byKey(const ValueKey('actions-search')), 'smit');
    await tester.pump();
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
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

  // --- The filter thins out the jaar → klas tree (#226) --------------------

  /// A passive-session view shaped for the tree filter: Jaar 3 has one class
  /// with work (3A) and one without (3B); Jaar 4 has two classes and nothing to
  /// do in either; Jaar 5 has a single class with nothing to do.
  Future<ReconcileHarness> filterTreeHarness() async => ReconcileHarness(
        linkedStore: await seededLinkedStore(<MaterializedAccount>[
          matAccount(
              id: 's1',
              label: 'Jane Doe',
              gradeYear: '3',
              classroom: '3A',
              withAction: true),
          matAccount(
              id: 's2', label: 'Kees Bakker', gradeYear: '3', classroom: '3B'),
          matAccount(
              id: 's3', label: 'Piet Peeters', gradeYear: '4', classroom: '4A'),
          matAccount(
              id: 's4', label: 'Marie Maes', gradeYear: '4', classroom: '4B'),
          matAccount(
              id: 's5', label: 'Sam Sels', gradeYear: '5', classroom: '5A'),
        ]),
      );

  testWidgets(
      'with the filter on, the jaar → klas tree drops the classrooms and the '
      'whole years with nothing pending, and says how many it hid (#226)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = await filterTreeHarness();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Only the year that still has work is an accordion at all.
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|4')), findsNothing,
        reason: "both of Jaar 4's classes are done — the year goes with them");
    expect(find.byKey(const ValueKey('rollup-grade-grades|5')), findsNothing,
        reason: 'Jaar 5 has one class and nothing to do in it');

    // The hiding is announced, so a year the operator expected is explained
    // rather than merely absent: 3B, Jaar 4 and Jaar 5.
    expect(find.byKey(const ValueKey('actions-filter-hidden')), findsOneWidget);
    expect(find.textContaining('Verborgen door de filter: 3'), findsOneWidget);

    // Inside the surviving year, only the class with work is listed.
    await tester.tap(find.byKey(const ValueKey('rollup-grade-grades|3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3A')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|3|3B')), findsNothing,
        reason: 'a ticked-off class is not rendered under the filter');

    // Switched off, the tree is the full inventory again — every year, every
    // class, and nothing left for the note to explain.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|4')), findsOneWidget);
    expect(find.byKey(const ValueKey('rollup-grade-grades|5')), findsOneWidget);
    expect(find.byKey(const ValueKey('actions-filter-hidden')), findsNothing);
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3B')),
        findsOneWidget);
  });

  testWidgets(
      'a view with nothing pending says the filter hid it all — not that there '
      'is no overview (#226)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe'),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions-filter-all-hidden')),
        findsOneWidget);
    expect(find.textContaining('Zet de filter af'), findsOneWidget);
    expect(find.text('Nog geen gematerialiseerd overzicht.'), findsNothing,
        reason: 'there *is* a materialized overview — the filter is hiding it');

    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('actions-filter-all-hidden')), findsNothing);
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
  });

  testWidgets(
      'the filter switch survives a Leerlingen ↔ Personeel tab change, and '
      'thins the Personeel tree the same way (#226)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // One student and one staff member, neither carrying an action: both trees
    // are empty under the filter and full without it.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe'),
      matStaff(id: 't1', label: 'Anna Smit'),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    expect(tester.widget<Switch>(toggle).value, isTrue);

    // Personeel obeys the same switch: its school node has no work under it, so
    // it is gone too, with the same explanation in its place.
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue,
        reason: 'the mode outlives the tab it was set on');
    expect(
        find.byKey(const ValueKey('rollup-school-school|staff')), findsNothing);
    expect(find.byKey(const ValueKey('actions-filter-all-hidden')),
        findsOneWidget);

    // Switch it off from the Personeel tab: the staff tree comes back.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-school-school|staff')),
        findsOneWidget);

    // Back to Leerlingen, and the off state came along — the tab change used to
    // reset it, which is why the filter had to be re-flipped constantly (#226).
    await tester.tap(find.byKey(const ValueKey('actions-tab-leerlingen')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.byKey(const ValueKey('rollup-grade-grades|3')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('actions-filter-all-hidden')), findsNothing);
  });

  // --- The single-open accordion and its open path (#235) ------------------

  testWidgets(
      'drilling into a class and pressing Overzicht comes back to the '
      'grade-year it was opened from, still expanded (#235)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = twoSchoolHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(harness.controller.selectedClassroom?.classroom, '3C');

    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|3|3C')), findsOneWidget,
        reason: 'Overzicht used to come back to a fully collapsed tree');
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|1|1A')), findsNothing,
        reason: 'the years that were closed stay closed');
    // The open node is remembered a level above the tiles, which is what let it
    // survive them being disposed for the detail view.
    expect(harness.controller.expandedPath, <String>['rollup-grade-grades|3']);
  });

  testWidgets('opening a grade-year closes the one that was open (#235)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = twoSchoolHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Jaar 1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-class-class|1|1|1A')),
        findsOneWidget);

    await tester.ensureVisible(find.text('Jaar 3'));
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-class-class|1|3|3C')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|1|1A')), findsNothing,
        reason: 'several grade-years could be open at once before #235');
    expect(harness.controller.expandedPath, <String>['rollup-grade-grades|3']);

    // Tapping the open year again shuts it, leaving nothing open.
    await tester.ensureVisible(find.text('Jaar 3'));
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(harness.controller.expandedPath, isEmpty);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|3|3C')), findsNothing);
  });

  testWidgets(
      'the nested Personeel tree keeps the school open under an opened '
      'grade-year, and both open across a drill-down (#235)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // The staff tree is school → grade-year → class, so "one open node" has to
    // mean one per level: a flat single-open key would collapse the school out
    // from under the very year it was used to reach.
    final harness = ReconcileHarness(
      wisa: wisaSnap(students: [wisaStudent()], staff: [wisaStaff()]),
    );
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-tab-personeel')));
    await tester.pumpAndSettle();

    final school = find.byKey(const ValueKey('rollup-school-school|staff'));
    await tester.ensureVisible(school);
    await tester.tap(school);
    await tester.pumpAndSettle();
    final grade =
        find.byKey(const ValueKey('rollup-grade-grade|staff|Personeel'));
    await tester.ensureVisible(grade);
    await tester.tap(grade);
    await tester.pumpAndSettle();

    final klas = find
        .byKey(const ValueKey('rollup-class-class|staff|Personeel|Personeel'));
    expect(klas, findsOneWidget,
        reason: 'the school stayed open under the grade-year it revealed');
    expect(harness.controller.expandedPath, <String>[
      'rollup-school-school|staff',
      'rollup-grade-grade|staff|Personeel',
    ]);

    await tester.ensureVisible(klas);
    await tester.tap(klas);
    await tester.pumpAndSettle();
    expect(harness.controller.selectedClassroom?.classroom, 'Personeel');

    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(klas, findsOneWidget,
        reason: 'both levels of the staff path come back open');
  });

  testWidgets(
      'a grade-year the filter hides is forgotten rather than re-opening when '
      'the filter goes off again (#226/#235)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = await filterTreeHarness();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Filter off: the full inventory, including the years with nothing to do.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rollup-grade-grades|4')));
    await tester.pumpAndSettle();
    expect(harness.controller.expandedPath, <String>['rollup-grade-grades|4']);

    // Filter back on: Jaar 4 has nothing pending, so it is gone — and with it
    // the memory of it being open.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-grade-grades|4')), findsNothing);
    expect(harness.controller.expandedPath, isEmpty);

    // Off once more: Jaar 4 is back, collapsed like every other node.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rollup-grade-grades|4')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|4|4A')), findsNothing,
        reason: 'a node hidden in between must not resurrect its open state');
  });

  testWidgets(
      "a re-sync forgets the open node instead of aiming it at a generation "
      'that no longer has it (#235)', (WidgetTester tester) async {
    _useTallWindow(tester);
    final harness = ReconcileHarness();
    await harness.controller.sync();
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    expect(harness.controller.expandedPath, <String>['rollup-grade-grades|3']);

    // WISA moved the student, so this pass really re-links and re-materializes
    // rather than taking the unchanged shortcut.
    harness.wisaResult = wisaSnap(
      students: [wisaStudent(classGroup: '3D')],
      fetchedAt: kFixtureDate.add(const Duration(hours: 1)),
    );
    await harness.controller.sync();
    await tester.pumpAndSettle();

    expect(harness.controller.expandedPath, isEmpty);
    expect(
        find.byKey(const ValueKey('rollup-class-class|1|3|3D')), findsNothing,
        reason: 'the tree comes back collapsed, not half-open');
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
      'a seeded session adopts the shared state and still reads only the class '
      'it drills into (#115/#154/#287)', (WidgetTester tester) async {
    // Tall, like its siblings: the notice above the list costs the first card
    // its place on an 800×600 fold, and this test is about which class was
    // read, not about where the fold falls.
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
    // Since #287 the cold seed is linked on open, so this session can act — and
    // it got there without asking any of the three systems for anything.
    expect(s2.controller.linked, isNotNull);
    expect(s2.controller.adoptedFrom?.syncedBy, 'operator@school.example');
    // The drill-down is still lazy: nothing is read until the operator opens a
    // class, and then only that class.
    expect(s2.controller.classroomAccounts, isNull);

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    expect(s2.controller.classroomAccounts, hasLength(1));
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);
  });

  testWidgets(
      'a read-only session badges an either/or once and lists it as the one '
      'choice it is (#251)', (WidgetTester tester) async {
    // A passive session over a departed student's stored doc: it carries the
    // unregister *and* the delete, which are two readings of one situation the
    // operator resolves once. The class node used to advertise 2 and the card
    // listed both as separate bullets, so a class with one leaver read as two
    // pieces of work — and since #226 that same count decides what is visible.
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(
        id: 's1',
        label: 'Jane Doe',
        classroom: '3C',
        candidates: departureChoice(),
      ),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // The class node in the tree: one decision, badged once.
    await tester.tap(find.text('Jaar 3'));
    await tester.pumpAndSettle();
    final klas3C = find.byKey(const ValueKey('rollup-class-class|1|3|3C'));
    await tester.ensureVisible(klas3C);
    expect(
        find.descendant(of: klas3C, matching: find.text('1')), findsOneWidget,
        reason: 'one leaver is one pending decision, not two');
    expect(find.descendant(of: klas3C, matching: find.text('2')), findsNothing);

    // Drilling in, the card says the same thing: one line, marked as the choice
    // it is, with the alternative behind it rather than beside it.
    await tester.ensureVisible(find.text('3C'));
    await tester.tap(find.text('3C'));
    await tester.pumpAndSettle();
    expect(harness.controller.linked, isNull, reason: 'passive session');
    expect(find.text('• Schrijf de leerling uit in Smartschool (keuze)'),
        findsOneWidget);
    expect(find.text('• Verwijder dit account uit Smartschool'), findsNothing,
        reason: 'the delete is the alternative, not a second to-do');
  });

  testWidgets(
      'a read-only account card marks an informational candidate "(manueel)" '
      '(#255)', (WidgetTester tester) async {
    // A passive session over a student who sits in the wrong Office 365 class
    // group (#245): the write belongs to the class row, so this candidate only
    // diagnoses and the card's badge counts it zero. The card used to render
    // every candidate as a bare bullet, so this line read exactly like due work
    // beside a (0) badge — while the group tile and the interactive tile have
    // both marked it "(manueel)" all along.
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(
        id: 's1',
        label: 'Sam Sels',
        classroom: '3C',
        candidates: wrongAzureClassGroupNotice(),
      ),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Nothing here is applyable, so the work list hides the class until the
    // inventory toggle is flipped (#226) — the state the unmarked line was most
    // misleading in.
    final toggle = find.byKey(const ValueKey('actions-only-with-actions'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(harness.controller.linked, isNull, reason: 'passive session');
    expect(find.text('Sam Sels'), findsOneWidget);

    expect(
      find.text('• Zit in de verkeerde Office 365-klasgroep: GBS-1A in plaats '
          'van GBS-1B. Werk het ledenbestand van beide klassen bij. (manueel)'),
      findsOneWidget,
      reason: 'the operator must be able to tell manual work from due work',
    );

    // …and it stays a "(manueel)" line, never a "(keuze)" one: it stands alone.
    expect(find.textContaining('(keuze)'), findsNothing);
  });

  testWidgets(
      'a read-only account card leaves an applyable candidate unmarked (#255)',
      (WidgetTester tester) async {
    // The other half of the same rule: marking must distinguish, so an ordinary
    // applyable candidate keeps its bare summary.
    _useTallWindow(tester);
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');
    expect(find.text('• Wijzig de klas in Smartschool'), findsOneWidget);
    expect(find.textContaining('(manueel)'), findsNothing);
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

  testWidgets(
      "the overview's freshness stamp names the werkdatum the roster was "
      'pulled with (#247)', (WidgetTester tester) async {
    // "Wie synchroniseerde, wanneer" says when the pass ran, never which school
    // year it describes — and WISA answers *as of* a date, so a pull made on
    // the wrong side of the rollover reads here exactly like a class that went
    // missing (#239). The stamp comes off the shared per-system record, so this
    // passive session reads the date without having run the pull.
    final store = await seededLinkedStore(
      <MaterializedAccount>[
        matAccount(id: 's1', label: 'Jane Doe', withAction: true),
      ],
      systemSyncs: <Origin, SystemSyncMeta>{
        Origin.wisa: SystemSyncMeta(
          syncedBy: 'operator@school.example',
          at: kFixtureDate,
          workDate: DateTime(2025, 9, 1),
        ),
      },
    );
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // In the wire's own dd/MM/yyyy, the way the Log panel's pull line and the
    // `Werkdatum` SOAP parameter both spell it.
    expect(find.textContaining('· werkdatum 01/09/2025'), findsOneWidget);
  });

  testWidgets(
      'a shared view synced before the werkdatum was recorded renders the '
      'stamp unchanged (#247)', (WidgetTester tester) async {
    // The store in production already holds views written without it, and a
    // Smartschool/Azure-only stamp never has one. Neither may invent a date,
    // and neither may lose the "wie, wanneer" half over its absence.
    final store = await seededLinkedStore(<MaterializedAccount>[
      matAccount(id: 's1', label: 'Jane Doe', withAction: true),
    ]);
    final harness = ReconcileHarness(linkedStore: store);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.textContaining('werkdatum'), findsNothing);
    expect(
      find.textContaining('Generatie 1'),
      findsOneWidget,
      reason: 'the who/when half stands on its own',
    );
  });

  testWidgets(
      'the stamp names the werkdatum the stored view was pulled with, not the '
      'one Instellingen now holds (#247)', (WidgetTester tester) async {
    // The disagreement the issue is about. #238 made the werkdatum live, so
    // between a save and the next Synchroniseer the setting says one school
    // year and the installed roster is another. Driven over the *production*
    // WISA pull, so the date on screen is the one that really went out.
    final live = LiveSettings(AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2025, 9, 1)),
      ),
    ));
    final wire = RecordingWisaSoap();
    final harness = ReconcileHarness(wisaTransport: wire, liveSettings: live);
    await harness.controller.sync();
    expect(wire.werkdatums, <String>['01/09/2025']);

    // The operator moves the werkdatum to the new school year and saves. Until
    // they sync, the overview below is still the old year's.
    live.publish(AppSettings(
      wisa: WisaConnection(
        server: 'wisa.example',
        port: '9000',
        workDate: WorkDateSetting(isNow: false, date: DateTime(2026, 9, 1)),
      ),
    ));

    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.textContaining('· werkdatum 01/09/2025'), findsOneWidget);
    expect(find.textContaining('01/09/2026'), findsNothing,
        reason: 'a saved werkdatum describes the next pull, not this view');
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
    // Since #287 the notice names *why* there is nothing to act on rather than
    // reporting the absence of a sync: this session holds no seeded snapshot to
    // build a view from, which is a thing only a pull can fix.
    expect(
      find.textContaining('Geen opgeslagen momentopname voor WISA, '
          'Smartschool en Azure AD'),
      findsOneWidget,
    );

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
      'a session that adopted the shared state says whose sync it is working '
      'from, and its tiles are the interactive ones (#287)',
      (WidgetTester tester) async {
    _useTallWindow(tester);
    // Operator A syncs; operator B opens Acties five minutes later and never
    // presses Synchroniseer. Before #287 that second session got the
    // "nog niet gesynchroniseerd" read-only notice and static cards, after
    // minutes of WISA/Smartschool/Azure traffic were the only way out of it.
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
    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    // The shared-state notice replaces the read-only one, and names the pull.
    expect(readOnly, findsNothing);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsOneWidget);
    expect(find.text('Gedeelde synchronisatie'), findsOneWidget);
    expect(find.textContaining('operator@school.example'), findsWidgets);

    // The tiles below it really are interactive — no locks, real entry tiles —
    // and no system was asked for anything to get here.
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-')),
      findsWidgets,
    );
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);

    // Both passes stay within reach for an operator who wants something
    // fresher; taking one makes the view this session's own.
    final sync = find.byKey(const ValueKey('actions-shared-state-sync'));
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('actions-shared-state-drift')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();

    expect(s2.wisaSyncs, 1);
    expect(s2.controller.adoptedFrom, isNull);
    expect(find.byKey(const ValueKey('actions-shared-state')), findsNothing);
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
    final linkedStore = InMemoryLinkedStore();
    await ReconcileHarness(linkedStore: linkedStore).controller.sync();
    await linkedStore.acquireLease(owner: 'mieke@school', now: kFixtureDate);

    // Deliberately *not* a seeded session: since #287 one of those adopts the
    // shared state and gets the interactive tiles plus [SharedStateNotice]
    // instead. This is the session with nothing to build a view from, which is
    // the one the read-only banner is for.
    final s2 = ReconcileHarness(linkedStore: linkedStore);
    await tester.pumpWidget(_wrap(ActionsScreen(bootstrap: s2.bootstrap)));
    await tester.pumpAndSettle();

    await _drill(tester, node: 'Jaar 3', classroom: '3C');

    expect(readOnly, findsOneWidget);
    expect(tester.widget<FilledButton>(readOnlySync).onPressed, isNull);
    expect(find.textContaining('mieke@school'), findsOneWidget,
        reason: 'a dead button needs its reason on screen too');
  });

  group('a pass runs behind a modal progress dialog (#243)', () {
    // An "Apply to all" over a September situation group writes hundreds of
    // accounts, one connector round-trip at a time, for minutes. Its only
    // feedback used to be greyed-out buttons plus an indeterminate bar in a
    // page header the operator had long scrolled past — so a running pass was
    // indistinguishable from a hung app, nothing named the account being
    // written, and nothing stopped them scrolling away mid-write.

    /// Two departed Smartschool-only students with **different names**, so an
    /// assertion that the dialog names the account in flight is a real one.
    ReconcileHarness twoDeparted({Future<void> Function()? gate}) =>
        ReconcileHarness(
          applyGate: gate,
          wisa: wisaSnap(students: const []),
          smartschool: ssSnap(
            groups: const [],
            accounts: <SmartschoolAccount>[
              ssAccount(
                uid: 'user0',
                accountId: '0',
                mail: 'user0@student.school.example',
                givenName: 'Jan',
                surname: 'Peeters',
              ),
              ssAccount(
                uid: 'user1',
                accountId: '1',
                mail: 'user1@student.school.example',
                givenName: 'Sofie',
                surname: 'Claes',
              ),
            ],
            memberships: const [],
          ),
          azure: azSnap(users: const []),
        );

    /// The text of one line of the progress dialog.
    String line(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    final Finder dialog = find.byKey(const ValueKey('actions-progress-dialog'));

    testWidgets(
        'an apply holds the operator in a non-dismissible dialog that names '
        'each account and action as it goes, and closes itself when the pass '
        'ends', (WidgetTester tester) async {
      _useTallWindow(tester);
      // One fresh gate per action, so the pass can be walked step by step and
      // the text observed on each — the bug is precisely that nobody could see
      // which account was being written.
      final gates = <Completer<void>>[];
      final harness = twoDeparted(gate: () async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      });
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      // Idle: no dialog.
      expect(dialog, findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
      await tester.tap(find.byKey(const ValueKey('actions-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      // Parked on the first action: the dialog is up, headed as an apply, and
      // says how far along it is and on whom.
      expect(dialog, findsOneWidget);
      expect(gates, hasLength(1));
      expect(find.text('Acties toepassen…'), findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 2');
      expect(
          line(tester, 'actions-progress-step'), startsWith('Jan Peeters —'));
      expect(line(tester, 'actions-progress-step'), contains('Smartschool'));

      // Determinate, and it is a real bar — the motionless indeterminate sweep
      // is exactly what this replaces (#176).
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('actions-progress-bar')),
      );
      expect(bar.value, 0.0);

      // Modal: tapping the barrier does not get rid of it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);

      // The second action: the text follows the pass to the next account.
      gates[0].complete();
      await tester.pumpAndSettle();
      expect(gates, hasLength(2));
      expect(dialog, findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 2 van 2');
      expect(
          line(tester, 'actions-progress-step'), startsWith('Sofie Claes —'));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('actions-progress-bar')),
            )
            .value,
        0.5,
      );

      // The pass ends: the dialog closes by itself, leaving the results.
      gates[1].complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Resultaat van het toepassen'), findsOneWidget);
      expect(harness.controller.applyResults, hasLength(2));
      expect(harness.soap.soapActions, isNotEmpty);
    });

    testWidgets(
        'a dry-run gets the same dialog — just as slow, and it used to be just '
        'as silent', (WidgetTester tester) async {
      _useTallWindow(tester);
      final gate = Completer<void>();
      final harness = twoDeparted(gate: () => gate.future);
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      // A dry-run needs no confirmation, so it goes straight into the pass.
      await tester.ensureVisible(find.byKey(const ValueKey('actions-dry-run')));
      await tester.tap(find.byKey(const ValueKey('actions-dry-run')));
      await tester.pumpAndSettle();

      expect(dialog, findsOneWidget);
      expect(find.text('Dry-run bezig…'), findsOneWidget);
      expect(find.text('Er wordt niets geschreven.'), findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 2');
      expect(
          line(tester, 'actions-progress-step'), startsWith('Jan Peeters —'));

      gate.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Resultaat van de dry-run'), findsOneWidget);
      expect(harness.soap.soapActions, isEmpty);
    });

    testWidgets('a pass whose writes fail still clears the dialog',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      // The worst case for a modal: the pass blows up. Leaving the dialog up
      // would lock the operator out of the app entirely, so its lifetime is
      // bound to the pass's future, not to anything observed about the results.
      final gate = Completer<void>();
      final harness = twoDeparted(gate: () async {
        await gate.future;
        throw StateError('Smartschool weigerde de schrijfactie');
      });
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const ValueKey('actions-apply')));
      await tester.tap(find.byKey(const ValueKey('actions-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(dialog, findsNothing,
          reason: 'a failed pass must not trap anyone');
      expect(find.text('Resultaat van het toepassen'), findsOneWidget);
      expect(
        harness.controller.applyResults!.map((r) => r.outcome),
        everyElement(ActionOutcome.failed),
      );
      expect(
        find.textContaining('Smartschool weigerde de schrijfactie'),
        findsWidgets,
      );
    });

    testWidgets('the per-situation and per-entry affordances run behind it too',
        (WidgetTester tester) async {
      _useTallWindow(tester);
      var gate = Completer<void>();
      final harness = twoDeparted(gate: () => gate.future);
      await harness.controller.sync();
      await tester
          .pumpWidget(_wrap(ActionsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();
      await _drill(tester, node: 'Niet toegewezen', classroom: 'Zonder klas');

      // The same-situation bulk dry-run.
      final key = harness.controller.classroomPendingSituations.single.key;
      final bulkDryRun = find.byKey(ValueKey('situation-dry-run-$key'));
      await tester.ensureVisible(bulkDryRun);
      await tester.tap(bulkDryRun);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(find.text('Dry-run bezig…'), findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 2');
      gate.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      // The per-entry apply, which is a pass of exactly one.
      gate = Completer<void>();
      final entry = harness.controller.pendingEntries
          .firstWhere((e) => e.target == 'Sofie Claes');
      final id = entry.targetId;
      await tester.ensureVisible(find.byKey(ValueKey('entry-student-$id')));
      await tester.tap(find.byKey(ValueKey('entry-student-$id')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('entry-apply-$id')));
      await tester.tap(find.byKey(ValueKey('entry-apply-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('actions-apply-confirm')));
      await tester.pumpAndSettle();

      expect(dialog, findsOneWidget);
      expect(line(tester, 'actions-progress-count'), 'Actie 1 van 1');
      expect(
          line(tester, 'actions-progress-step'), startsWith('Sofie Claes —'));
      gate.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Resultaat van het toepassen'), findsOneWidget);
    });
  });
}
