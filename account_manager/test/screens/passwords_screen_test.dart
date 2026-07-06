import 'package:account_core/account_core.dart' as core;
import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:flutter/material.dart';
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

    expect(find.text('Not configured'), findsOneWidget);
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
}
