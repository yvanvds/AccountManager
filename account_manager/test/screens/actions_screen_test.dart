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

/// Drills school → grade → classroom in the rollup tree.
Future<void> _drill(
  WidgetTester tester, {
  required String school,
  required String grade,
  required String classroom,
}) async {
  await tester.tap(find.text(school));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Jaar $grade'));
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

    // The rollup tree is the browser; the flat list is gone. No classroom is
    // loaded until the operator drills into one.
    expect(find.text('Overzicht'), findsOneWidget);
    expect(find.text('School 1'), findsOneWidget);
    expect(harness.controller.selectedClassroom, isNull);
    expect(harness.controller.classroomAccounts, isNull);
    expect(find.byKey(const ValueKey('actions-classroom-back')), findsNothing);

    // Drill in: only the 3C classroom's accounts load (via readClassroom), and
    // that class's pending action tile builds.
    await _drill(tester, school: 'School 1', grade: '3', classroom: '3C');
    expect(harness.controller.selectedClassroom?.classroom, '3C');
    expect(harness.controller.classroomAccounts, hasLength(1));
    expect(
        find.byKey(const ValueKey('actions-classroom-back')), findsOneWidget);
    expect(find.text('Wijzig de klas in Smartschool'), findsWidgets);

    // Back to the overview tree.
    await tester.tap(find.byKey(const ValueKey('actions-classroom-back')));
    await tester.pumpAndSettle();
    expect(find.text('School 1'), findsOneWidget);
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
  /// choice (#110). They land in the "Niet toegewezen" → "Overig" → "Zonder
  /// klas" bucket.
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

    await _drill(tester,
        school: 'Niet toegewezen', grade: 'Overig', classroom: 'Zonder klas');

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

    await _drill(tester,
        school: 'Niet toegewezen', grade: 'Overig', classroom: 'Zonder klas');

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

    await _drill(tester,
        school: 'Niet toegewezen', grade: 'Overig', classroom: 'Zonder klas');

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

    await _drill(tester, school: 'School 1', grade: '3', classroom: '3C');
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
    expect(find.text('School 1'), findsOneWidget);
    expect(s2.controller.linked, isNull,
        reason: 'link() is never called in a passive session');
    // Nothing loaded until the operator drills in.
    expect(s2.controller.classroomAccounts, isNull);

    await _drill(tester, school: 'School 1', grade: '3', classroom: '3C');

    // Only the 3C class was read; the read-only account tile renders.
    expect(s2.controller.classroomAccounts, hasLength(1));
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(s2.wisaSyncs, 0);
    expect(s2.ssSyncs, 0);
    expect(s2.azSyncs, 0);
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
}
