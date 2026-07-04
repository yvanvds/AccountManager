import 'package:account_manager/src/screens/passwords_screen.dart';
import 'package:account_state/account_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../reconcile/reconcile_fakes.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

PasswordEntry _entry({
  required String pid,
  String name = 'Jane Doe',
  String uid = 'jane.doe',
  String? smartschool = 'SS-pw',
  String? azure = 'AZ-pw',
}) =>
    PasswordEntry(
      personId: PersonId(pid),
      kind: PasswordAccountKind.account,
      accountName: uid,
      displayName: name,
      mail: '$uid@student.school.example',
      classGroup: '3C',
      smartschoolPassword: smartschool,
      azurePassword: azure,
    );

void main() {
  testWidgets('shows the not-configured panel when AAD is absent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const PasswordsScreen(bootstrap: null)));
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.byKey(const ValueKey('passwords-refresh')), findsNothing);
  });

  testWidgets('lists the pending entries the shared queue holds',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await harness.passwordQueue.save([
      _entry(pid: 'p1', name: 'Jane Doe', uid: 'jane.doe'),
      _entry(pid: 'p2', name: 'Jan Peeters', uid: 'jan.peeters', azure: null),
    ]);

    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Jan Peeters'), findsOneWidget);
    // Jane has both backends; Jan only Smartschool.
    expect(find.text('SS-pw'), findsWidgets);
    expect(find.text('AZ-pw'), findsOneWidget);
    expect(find.text('2 wachtwoorden wachten op verdeling.'), findsOneWidget);
  });

  testWidgets('copy puts the password on the clipboard',
      (WidgetTester tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final harness = ReconcileHarness();
    await harness.passwordQueue.save([_entry(pid: 'p1')]);
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('password-copy-ss-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('password-copy-azure-p1')));
    await tester.pumpAndSettle();

    expect(copied, ['SS-pw', 'AZ-pw']);
  });

  testWidgets(
      'marking an entry distributed drains it from the shared queue and shows '
      'the empty state', (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await harness.passwordQueue.save([_entry(pid: 'p1', name: 'Jane Doe')]);
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.text('Jane Doe'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('password-distribute-p1')));
    await tester.pumpAndSettle();

    // The row is gone from the view and, crucially, from the persisted queue —
    // draining means saving the remainder so the other operators no longer see
    // it.
    expect(find.text('Jane Doe'), findsNothing);
    expect(find.byKey(const ValueKey('passwords-empty')), findsOneWidget);
    expect(await harness.passwordQueue.load(), isEmpty);
  });

  testWidgets('an empty queue renders the all-distributed state',
      (WidgetTester tester) async {
    final harness = ReconcileHarness();
    await tester
        .pumpWidget(_wrap(PasswordsScreen(bootstrap: harness.bootstrap)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('passwords-empty')), findsOneWidget);
    expect(find.text('Geen wachtwoorden in de wachtrij.'), findsOneWidget);
  });
}
