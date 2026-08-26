import 'dart:async';
import 'dart:convert';

import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartschool_api/smartschool_api.dart' as ss;

import '../reconcile/reconcile_fakes.dart';

/// A Smartschool snapshot shaped like the Passwords screen needs it: a
/// "Leerlingen" root holding one class (3C) with one student, and a "Personeel"
/// group with one staff member.
ss.SmartschoolSnapshot _snap() => ss.SmartschoolSnapshot(
      fetchedAt: kFixtureDate,
      groups: <core.Group>[
        core.Group(
          id: const core.GroupId('leerlingen'),
          name: 'Leerlingen',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
        ssGroup('3C', code: '3C', type: core.GroupType.classGroup)
            .copyUnderLeerlingen(),
        core.Group(
          id: const core.GroupId('personeel'),
          name: 'Personeel',
          description: '',
          type: core.GroupType.group,
          official: false,
          origin: core.Origin.smartschool,
        ),
      ],
      accounts: <ss.SmartschoolAccount>[
        ssAccount(uid: 'jane', accountId: '1', mail: 'jane@student.school'),
        ssAccount(uid: 'anna.smit', accountId: '2', mail: 'anna@school'),
      ],
      memberships: <ss.SmartschoolMembership>[
        member('jane', '3C'),
        member('anna.smit', 'personeel'),
      ],
    );

extension on core.Group {
  core.Group copyUnderLeerlingen() => core.Group(
        id: id,
        name: name,
        description: description,
        type: type,
        official: official,
        origin: origin,
        parentId: const core.GroupId('leerlingen'),
      );
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const PasswordsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Niet geconfigureerd'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passwords-tab-leerlingen')), findsNothing);
  });

  testWidgets('renders the Leerlingen and Personeel tabs',
      (WidgetTester tester) async {
    final harness = ReconcileHarness(ssInitial: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('passwords-tab-leerlingen')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passwords-tab-personeel')), findsOneWidget);
    expect(find.text('Wachtwoorden'), findsOneWidget);
  });

  testWidgets(
      'the class tree tracks a sync that lands after this tab was opened '
      '(#287)', (WidgetTester tester) async {
    // The screen used to capture `app.smartschool.snapshot` once, at bootstrap.
    // A session that opened Wachtwoorden before its first sync — or before it
    // adopted the shared state — therefore stayed on that empty tree for the
    // rest of its life, however many syncs landed behind it.
    final harness = ReconcileHarness(smartschool: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    final class3c = find.byKey(const ValueKey('password-class-3C'));
    expect(class3c, findsNothing, reason: 'nothing synced yet');

    // A pass on another tab brings the group tree in.
    await harness.controller.sync();
    await tester.pumpAndSettle();

    expect(class3c, findsOneWidget);
    await tester.tap(class3c);
    await tester.pumpAndSettle();
    expect(find.text('jane'), findsOneWidget);
  });

  testWidgets(
      'Leerlingen: select a class, check a target, generate → confirm pushes '
      'live and reports success (#180)', (WidgetTester tester) async {
    final harness = ReconcileHarness(ssInitial: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Select the class from the tree; its student appears.
    await tester.tap(find.byKey(const ValueKey('password-class-3C')));
    await tester.pumpAndSettle();
    expect(find.text('jane'), findsOneWidget);

    // Generate is disabled with nothing checked.
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('passwords-generate')))
          .onPressed,
      isNull,
    );

    // Check Jane's Smartschool target, then generate → confirm.
    await tester
        .tap(find.byKey(const ValueKey('passwords-cell-jane-smartschool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate-confirm')));
    await tester.pumpAndSettle();

    // A live Smartschool push happened and the screen reports success.
    expect(harness.passwordBackends.smartschoolPushes, hasLength(1));
    expect(harness.passwordBackends.smartschoolPushes.single.$1, 'jane');
    expect(find.byKey(const ValueKey('passwords-message')), findsOneWidget);
    // The generated sheet can now be printed.
    expect(
      tester
          .widget<OutlinedButton>(
              find.byKey(const ValueKey('passwords-export-students')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'Leerlingen: printing the queued sheets writes a PDF and opens it for '
      'printing (#195)', (WidgetTester tester) async {
    final harness = ReconcileHarness(ssInitial: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    // Generate a password for Jane so the print queue holds a sheet.
    await tester.tap(find.byKey(const ValueKey('password-class-3C')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('passwords-cell-jane-smartschool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passwords-generate-confirm')));
    await tester.pumpAndSettle();

    final print = find.byKey(const ValueKey('passwords-export-students'));
    await tester.tap(print);
    await tester.pumpAndSettle();

    // A real PDF was written — not the old browser-printable HTML — and handed
    // to the platform viewer so the operator can print straight away.
    expect(harness.passwordWrites, hasLength(1));
    expect(harness.passwordWrites.single.$1, 'leerling-wachtwoorden.pdf');
    expect(
      latin1.decode(harness.passwordWrites.single.$2.sublist(0, 5)),
      '%PDF-',
    );
    expect(harness.passwordOpens, hasLength(1));
    // The queue drained on a successful export, so the button goes quiet again.
    expect(tester.widget<OutlinedButton>(print).onPressed, isNull);
  });

  testWidgets(
      'Personeel: filter, select a member, reset both pushes both backends '
      '(#180)', (WidgetTester tester) async {
    final harness = ReconcileHarness(ssInitial: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    // The staff member is listed; select them.
    await tester.tap(find.byKey(const ValueKey('passwords-staff-anna.smit')));
    await tester.pumpAndSettle();

    // Reset both → confirm. The Personeel tab carries a filter TextField whose
    // blinking cursor keeps `pumpAndSettle` from ever settling, so drive the
    // dialog with explicit frames instead.
    await tester.tap(find.byKey(const ValueKey('passwords-staff-reset-both')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .tap(find.byKey(const ValueKey('passwords-staff-reset-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Both a Smartschool and an Azure push happened, sharing one password.
    expect(harness.passwordBackends.smartschoolPushes, hasLength(1));
    expect(harness.passwordBackends.azurePushes, hasLength(1));
    expect(harness.passwordBackends.smartschoolPushes.single.$3,
        harness.passwordBackends.azurePushes.single.$2);
  });

  testWidgets(
      'Personeel: the list is alphabetical and the field picker is gone '
      '(#186/#215)', (WidgetTester tester) async {
    // Three staff seeded out of alphabetical order across mixed casing; the
    // Personeel tab must render the list sorted by the displayed "Voornaam
    // Naam" name, with a single search box and no Naam/Voornaam/Gebruiker
    // selector beside it.
    final harness = ReconcileHarness(ssInitial: staffOrderSnap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    // One search box, no field picker (#215).
    expect(
        find.byKey(const ValueKey('passwords-staff-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-filter-field')),
        findsNothing);
    for (final label in const <String>['Naam', 'Voornaam', 'Gebruiker']) {
      expect(find.text(label), findsNothing,
          reason: 'the $label option belonged to the dropped field picker');
    }

    // The tiles render top-to-bottom in alphabetical order: alice, Bob, Charlie.
    double y(String uid) =>
        tester.getTopLeft(find.byKey(ValueKey('passwords-staff-$uid'))).dy;
    expect(y('alice'), lessThan(y('bob')));
    expect(y('bob'), lessThan(y('charlie')));
  });

  testWidgets('Personeel filter narrows the staff list',
      (WidgetTester tester) async {
    final harness = ReconcileHarness(ssInitial: _snap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('passwords-staff-anna.smit')),
        findsOneWidget);

    // Focusing the field starts a blinking cursor, so drive with explicit
    // frames rather than pumpAndSettle.
    await tester.enterText(
        find.byKey(const ValueKey('passwords-staff-filter')), 'zzz');
    await tester.pump();
    expect(
        find.byKey(const ValueKey('passwords-staff-anna.smit')), findsNothing);
  });

  testWidgets(
      'Personeel: one box finds a staff member by any part of the name, in '
      'either order (#215)', (WidgetTester tester) async {
    // alice Bravo / Bob Alpha / Charlie Zulu. With the field picker gone the
    // operator types a fragment and gets the person — a surname fragment, a
    // given-name fragment and both halves typed the "wrong" way round all land
    // on the same tile, where picking the wrong field used to return nothing.
    final harness = ReconcileHarness(ssInitial: staffOrderSnap());
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
    await tester.pumpAndSettle();

    final filter = find.byKey(const ValueKey('passwords-staff-filter'));
    // The focused field's blinking cursor never settles, so pump frames.
    Future<void> search(String needle) async {
      await tester.enterText(filter, needle);
      await tester.pump();
    }

    // A surname fragment, cased the other way round.
    await search('BRAV');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-bob')), findsNothing);
    expect(find.byKey(const ValueKey('passwords-staff-charlie')), findsNothing);

    // Both halves, surname first — the order the tile does *not* display in.
    await search('bravo alice');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-bob')), findsNothing);

    // Parts from two different people match neither.
    await search('alice zulu');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsNothing);
    expect(find.byKey(const ValueKey('passwords-staff-charlie')), findsNothing);

    // Clearing the box brings everyone back.
    await search('');
    expect(find.byKey(const ValueKey('passwords-staff-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-staff-bob')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('passwords-staff-charlie')), findsOneWidget);
  });

  group('a generate/reset runs behind a modal progress dialog (#369)', () {
    // Generating for a class is one live password push per selected (row,
    // target) against Azure and Smartschool — seconds each, tens of seconds for
    // a class. All it used to show for that was greyed-out buttons and a 4px
    // bar in the page header: the grid kept the old rows, nothing said how far
    // along the run was, and the natural reaction to that is to click again
    // while a live push sequence is in flight.

    final Finder dialog =
        find.byKey(const ValueKey('passwords-progress-dialog'));

    /// The dialog's "n van N" line.
    String count(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('passwords-progress-count')))
        .data!;

    double bar(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(
          find.byKey(const ValueKey('passwords-progress-bar')),
        )
        .value!;

    /// A fresh gate per push, so a run can be walked push by push and the
    /// dialog observed on each — being unable to see the run go by is the whole
    /// bug.
    List<Completer<void>> gatePushes(ReconcileHarness harness) {
      final gates = <Completer<void>>[];
      harness.passwordBackends.gate = () async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      };
      return gates;
    }

    /// Drives frames without waiting for quiescence: once a dialog has taken
    /// and handed back focus, the Personeel tab's filter field blinks a cursor
    /// and `pumpAndSettle` never settles.
    Future<void> frames(WidgetTester tester, [int n = 12]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
        'Leerlingen: the dialog holds the operator, counts the pushes up and '
        'closes itself when the run ends', (WidgetTester tester) async {
      final harness = ReconcileHarness(ssInitial: passwordsSnap());
      final gates = gatePushes(harness);
      await tester
          .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      // Idle: no dialog.
      expect(dialog, findsNothing);

      // 3C holds two students; ticking the Smartschool column makes a two-push
      // run out of them.
      await tester.tap(find.byKey(const ValueKey('password-class-3C')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('passwords-bulk-smartschool')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('passwords-generate')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('passwords-generate-confirm')));
      await tester.pumpAndSettle();

      // Parked on the first push: the dialog is up, says what it is doing and
      // how far along it is — determinately, since the total is known up front.
      expect(dialog, findsOneWidget);
      expect(gates, hasLength(1));
      expect(find.text('Wachtwoorden genereren…'), findsOneWidget);
      expect(count(tester), '0 van 2');
      expect(bar(tester), 0.0);

      // Modal: neither the barrier nor Escape gets rid of it mid-run. A
      // half-pushed class is exactly the state this must not allow.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);

      // The second push: the count follows the run. Note that the first row's
      // selection has already been cleared by now, so a total re-read off
      // `selectedCount` would read "1 van 1" here.
      gates[0].complete();
      await tester.pumpAndSettle();
      expect(gates, hasLength(2));
      expect(dialog, findsOneWidget);
      expect(count(tester), '1 van 2');
      expect(bar(tester), 0.5);

      // The run ends: the dialog closes by itself and the outcome message is on
      // the screen behind it, exactly as before.
      gates[1].complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(harness.passwordBackends.smartschoolPushes, hasLength(2));
      expect(find.byKey(const ValueKey('passwords-message')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Personeel: a per-member reset gets the same dialog',
        (WidgetTester tester) async {
      final harness = ReconcileHarness(ssInitial: passwordsSnap());
      final gates = gatePushes(harness);
      await tester
          .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('passwords-tab-personeel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('passwords-staff-anna.smit')));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const ValueKey('passwords-staff-reset-both')));
      await frames(tester);
      await tester
          .tap(find.byKey(const ValueKey('passwords-staff-reset-confirm')));
      await frames(tester);

      // "Beide" is one run of two pushes — the same problem on a smaller scale.
      expect(dialog, findsOneWidget);
      expect(find.text('Wachtwoord resetten…'), findsOneWidget);
      expect(count(tester), '0 van 2');
      expect(gates, hasLength(1));

      gates[0].complete();
      await frames(tester);
      expect(dialog, findsOneWidget);
      expect(count(tester), '1 van 2');

      gates[1].complete();
      await frames(tester);
      expect(dialog, findsNothing);
      expect(harness.passwordBackends.smartschoolPushes, hasLength(1));
      expect(harness.passwordBackends.azurePushes, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });
}
