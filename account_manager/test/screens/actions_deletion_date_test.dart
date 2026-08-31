/// The uitschrijvingsdatum prompt on the Acties screen (#394).
///
/// The property under test is never "a dialog appeared". It is that the date the
/// operator answered is the date Smartschool is told the student left — read off
/// the SOAP envelope — and that a batch of departures shares one answer without
/// it being typed again for each of them.
library;

import 'package:account_manager/src/reconcile/reconcile_controller.dart'
    show PendingAccountEntry, ReconcileController;
import 'package:account_manager/src/screens/action_tiles.dart'
    show confirmAndApply, deletionDateWarning, formatOfficialDate;
import 'package:account_manager/src/screens/actions_screen.dart';
import 'package:account_manager/src/settings/local_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

/// The screen under a preference scope, the way the real app builds it.
Widget _wrap(Widget child, {LocalPreferences? preferences}) =>
    LocalPreferencesScope(
      preferences: preferences ?? LocalPreferences.inMemory(),
      child: MaterialApp(home: Scaffold(body: child)),
    );

void _useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder _row(String id) => find.byKey(ValueKey('account-row-$id'));

/// A WISA-departed scenario: [count] Smartschool-only active accounts, each
/// raising the unregister/delete either-or (#110) — the dated decision.
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

List<String> _studentIds(ReconcileController controller) => <String>[
      for (final e in controller.pendingEntries)
        if (e.family == 'student') e.targetId,
    ];

Future<void> _open(
  WidgetTester tester,
  ReconcileHarness harness, {
  LocalPreferences? preferences,
}) async {
  await harness.controller.sync();
  // Tear any previous screen down first. `ActionsScreen` memoizes its bootstrap
  // in `initState`, so pumping a second one of the same type over the first
  // would reuse the old State — and the old controller — which is exactly the
  // confusion the restart case below is trying to avoid.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(_wrap(
    ActionsScreen(bootstrap: harness.bootstrap),
    preferences: preferences,
  ));
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String id) async {
  await tester.ensureVisible(_row(id));
  await tester.tap(_row(id));
  await tester.pumpAndSettle();
}

Future<void> _pressApply(WidgetTester tester, String id) async {
  final Finder apply = find.byKey(ValueKey('entry-apply-$id'));
  await tester.ensureVisible(apply);
  await tester.tap(apply);
  await tester.pumpAndSettle();
}

Finder get _dateDialog => find.byKey(const ValueKey('deletion-date-dialog'));
Finder get _dateValue => find.byKey(const ValueKey('deletion-date-value'));
Finder get _dateConfirm => find.byKey(const ValueKey('deletion-date-confirm'));
Finder get _dateCancel => find.byKey(const ValueKey('deletion-date-cancel'));
Finder get _datePick => find.byKey(const ValueKey('deletion-date-pick'));
Finder get _applyConfirm => find.byKey(const ValueKey('actions-apply-confirm'));

/// The uitschrijvingsdatum as it goes on the wire — Smartschool's own unpadded
/// `Y-M-D`, which is what `RecordingSoap.unregisteredOn` records.
String _onTheWire(DateTime date) => '${date.year}-${date.month}-${date.day}';

void main() {
  group('the uitschrijvingsdatum is asked for and reaches the wire (#394)', () {
    testWidgets('an unregister is stamped with the answered date, not today',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      // Something remembered, so the picker opens on a known month and the
      // answer cannot accidentally coincide with today.
      final prefs = LocalPreferences.inMemory();
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 3, 14));

      final harness = departedHarness();
      await _open(tester, harness, preferences: prefs);
      final String id = _studentIds(harness.controller).single;
      await _select(tester, id);
      await _pressApply(tester, id);

      // The prompt leads with what was remembered.
      expect(_dateDialog, findsOneWidget);
      expect(tester.widget<Text>(_dateValue).data, '2026-03-14');

      // The operator moves it to the day the student actually left.
      await tester.tap(_datePick);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('20'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('OK'),
      ));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_dateValue).data, '2026-03-20');

      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();

      // The confirmation quotes it back — the last place a stale date can be
      // caught before the write.
      expect(find.textContaining('De uitschrijvingsdatum is 2026-03-20.'),
          findsOneWidget);
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();

      // The point of the issue: the wire value.
      expect(harness.soap.unregisteredOn, <String>['2026-3-20'],
          reason: "Smartschool's own unpadded Y-M-D, and the answered day");
      expect(
        harness.controller.applyResults!.map((r) => r.changes.summary),
        contains('Schrijf de leerling uit in Smartschool'),
      );
    });

    testWidgets('the delete path gets the same treatment',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      final prefs = LocalPreferences.inMemory();
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 3, 14));

      final harness = departedHarness();
      await _open(tester, harness, preferences: prefs);
      final String id = _studentIds(harness.controller).single;
      await _select(tester, id);
      await tester
          .tap(find.byKey(ValueKey('alt-$id-DeleteStudentFromSmartschool')));
      await tester.pumpAndSettle();
      await _pressApply(tester, id);

      expect(_dateDialog, findsOneWidget);
      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();

      expect(harness.soap.deletedOn, <String>['2026-3-14'],
          reason: 'the delete carries the official date too — and never the '
              "API's 1-1-1 sentinel once one has been answered");
    });

    testWidgets('an action that carries no date never asks',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      // A student whose Smartschool email is wrong: a modify, not a departure.
      final harness = ReconcileHarness(
        wisa: wisaSnap(),
        smartschool: ssSnap(
          accounts: [ssAccount(mail: 'stale@student.school.example')],
        ),
        azure: azSnap(),
      );
      await _open(tester, harness);
      final List<String> ids = _studentIds(harness.controller);
      expect(ids, isNotEmpty, reason: 'the fixture raises student work');

      await _select(tester, ids.first);
      await _pressApply(tester, ids.first);

      expect(_dateDialog, findsNothing,
          reason: 'only the dated resolutions ask — every other pass is '
              'exactly as many clicks as it was');
      expect(_applyConfirm, findsOneWidget);
    });
  });

  group('cancelling applies nothing (#394)', () {
    testWidgets('cancelling the date writes nothing and offers no confirmation',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      final harness = departedHarness();
      await _open(tester, harness);
      final String id = _studentIds(harness.controller).single;
      await _select(tester, id);
      await _pressApply(tester, id);

      await tester.tap(_dateCancel);
      await tester.pumpAndSettle();

      expect(_applyConfirm, findsNothing, reason: 'no confirmation follows');
      expect(harness.soap.unregisteredOn, isEmpty);
      expect(harness.soap.soapActions, isEmpty);
      expect(harness.controller.applyResults, isNull);
      // The row is still there, still undecided.
      expect(_row(id), findsOneWidget);
    });

    testWidgets(
        'cancelling the confirmation writes nothing and remembers '
        'nothing', (WidgetTester tester) async {
      _useWideWindow(tester);
      final prefs = LocalPreferences.inMemory();
      await prefs.load();

      final harness = departedHarness();
      await _open(tester, harness, preferences: prefs);
      final String id = _studentIds(harness.controller).single;
      await _select(tester, id);
      await _pressApply(tester, id);
      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Annuleer'));
      await tester.pumpAndSettle();

      expect(harness.soap.soapActions, isEmpty);
      expect(harness.controller.applyResults, isNull);
      expect(prefs.lastDeletionDate, isNull,
          reason: 'a date thought better of at the confirmation must not '
              'become the default for the next student');
    });
  });

  group('the date is remembered across the batch (#394)', () {
    testWidgets(
        'the second student is pre-filled with the first answer, '
        'and it survives a restart', (WidgetTester tester) async {
      _useWideWindow(tester);
      // One store, two `LocalPreferences` over it — a restart, modelled the way
      // the app really loads it.
      final store = InMemoryLocalPreferenceStore();
      final first = LocalPreferences(store);
      await first.load();

      final harness = departedHarness(count: 2);
      await _open(tester, harness, preferences: first);
      final List<String> ids = _studentIds(harness.controller);
      expect(ids, hasLength(2));

      // Student one: pick a real departure date.
      await _select(tester, ids.first);
      await _pressApply(tester, ids.first);
      await tester.tap(_datePick);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('7'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('OK'),
      ));
      await tester.pumpAndSettle();
      final String answered = tester.widget<Text>(_dateValue).data!;
      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();
      expect(harness.soap.unregisteredOn, hasLength(1));

      // The app is restarted: a fresh preference object over the same store.
      final second = LocalPreferences(store);
      await second.load();
      expect(second.lastDeletionDate, isNotNull);
      expect(formatOfficialDate(second.lastDeletionDate!), answered);

      final restarted = departedHarness(count: 2);
      await _open(tester, restarted, preferences: second);
      final List<String> after = _studentIds(restarted.controller);
      await _select(tester, after.last);
      await _pressApply(tester, after.last);

      // No calendar this time: the answer is already in the field.
      expect(tester.widget<Text>(_dateValue).data, answered);
      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();

      expect(
        restarted.soap.unregisteredOn,
        <String>[_onTheWire(second.lastDeletionDate!)],
        reason: "the second student lands on the first one's date without it "
            'being typed again — the whole reason it is remembered',
      );
    });

    testWidgets('one pass over three students asks once and writes one date',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      final prefs = LocalPreferences.inMemory();
      await prefs.load();
      await prefs.setLastDeletionDate(DateTime(2026, 6, 30));

      final harness = departedHarness(count: 3);
      await _open(tester, harness, preferences: prefs);
      final List<PendingAccountEntry> entries = <PendingAccountEntry>[
        for (final e in harness.controller.pendingEntries)
          if (e.family == 'student') e,
      ];
      expect(entries, hasLength(3));

      // The seam every apply affordance goes through, driven over a
      // three-account pass: whatever offers such a pass, it asks here, once.
      final BuildContext context = tester.element(find.byType(ActionsScreen));
      final Future<bool> ran = confirmAndApply(
        context,
        controller: harness.controller,
        title: 'Toepassen op 3 accounts?',
        scope: harness.controller.applyScope(entries),
        apply: (DateTime? deletionDate) => harness.controller.applyEntries(
          entries,
          deletionDate: deletionDate,
        ),
      );
      await tester.pumpAndSettle();

      expect(_dateDialog, findsOneWidget, reason: 'exactly one prompt…');
      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();
      expect(_dateDialog, findsNothing, reason: '…and it is not asked again');
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();
      expect(await ran, isTrue);

      expect(
        harness.soap.unregisteredOn,
        <String>['2026-6-30', '2026-6-30', '2026-6-30'],
        reason: 'three students, one date, one question',
      );
    });
  });

  group('odd dates warn rather than block (#394)', () {
    test('the warning fires on the far side of a year and two years', () {
      final DateTime today = DateTime(2026, 6, 30);
      expect(deletionDateWarning(today, now: today), isNull);
      expect(deletionDateWarning(DateTime(2025, 9, 1), now: today), isNull,
          reason: 'backdating within the school career is the normal case');
      expect(deletionDateWarning(DateTime(2026, 9, 1), now: today), isNull,
          reason: 'a planned end-of-year departure is legitimate');
      expect(
        deletionDateWarning(DateTime(2030, 1, 1), now: today),
        contains('toekomst'),
      );
      expect(
        deletionDateWarning(DateTime(2019, 1, 1), now: today),
        contains('verleden'),
      );
    });

    testWidgets('an absurd date is remarked on but still applyable',
        (WidgetTester tester) async {
      _useWideWindow(tester);
      final prefs = LocalPreferences.inMemory();
      await prefs.load();
      // A date years in the past — a legitimate late correction, or a typo. The
      // app cannot know which, so it says what it noticed and lets the operator
      // decide.
      await prefs.setLastDeletionDate(DateTime(2015, 4, 1));

      final harness = departedHarness();
      await _open(tester, harness, preferences: prefs);
      final String id = _studentIds(harness.controller).single;
      await _select(tester, id);
      await _pressApply(tester, id);

      expect(
          find.byKey(const ValueKey('deletion-date-warning')), findsOneWidget);
      final FilledButton go = tester.widget<FilledButton>(_dateConfirm);
      expect(go.onPressed, isNotNull, reason: 'warned, never blocked');

      await tester.tap(_dateConfirm);
      await tester.pumpAndSettle();
      await tester.tap(_applyConfirm);
      await tester.pumpAndSettle();

      expect(harness.soap.unregisteredOn, <String>['2015-4-1']);
    });
  });
}
