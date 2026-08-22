import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/screens/home_screen.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'auth/fake_broker.dart';

void main() {
  testWidgets('app boots into the Plink-themed shell with a Home screen',
      (WidgetTester tester) async {
    // graph: null → AAD not configured, so the sign-in gate reveals the shell
    // directly (no acquisition attempted).
    await tester.pumpWidget(
      AccountManagerApp(session: SignInSession(FakeBroker()), graph: null),
    );
    await tester.pumpAndSettle();

    // The shell and its single Home destination are present, the rail naming
    // it in the operator's language (#257).
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);

    // …and the placeholder behind it speaks that language too (#265): the
    // first screen the operator lands on was the last one left in English.
    expect(find.text('ARCADIA · ACCOUNTSYNCHRONISATIE'), findsOneWidget);
    expect(
      find.textContaining('Stemt gebruikersaccounts en klasgroepen'),
      findsOneWidget,
    );
    expect(
      find.textContaining('het tabblad Synchronisatie.'),
      findsOneWidget,
    );
    expect(find.textContaining('Reconciles user accounts'), findsNothing);

    // The per-product accent is layered on the Plink foundations.
    final BuildContext context = tester.element(find.byType(HomeScreen));
    final PlinkProductAccent? accent =
        Theme.of(context).extension<PlinkProductAccent>();
    expect(accent, isNotNull);
    expect(accent!.accent, kProductAccent);
  });
}
