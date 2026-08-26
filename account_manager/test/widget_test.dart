import 'package:account_manager/src/app.dart';
import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/screens/reconcile_screen.dart';
import 'package:account_manager/src/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'auth/fake_broker.dart';

void main() {
  testWidgets(
      'app boots into the Plink-themed shell, landing on Synchronisatie with '
      'the rail in work order (#366)', (WidgetTester tester) async {
    // graph: null → AAD not configured, so the sign-in gate reveals the shell
    // directly (no acquisition attempted).
    await tester.pumpWidget(
      AccountManagerApp(session: SignInSession(FakeBroker()), graph: null),
    );
    await tester.pumpAndSettle();

    // The shell renders, and the destination behind the first rail entry is the
    // one the session begins on — no Start placeholder to click past (#366).
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(ReconcileScreen), findsOneWidget);

    // The rail holds exactly the five destinations, in the order the operator
    // is meant to work: Klasgroepen is upstream of Acties, so it sits above it.
    final NavigationRail rail =
        tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(
      rail.destinations.map((d) => (d.label as Text).data).toList(),
      <String>[
        'Synchronisatie',
        'Klasgroepen',
        'Acties',
        'Wachtwoorden',
        'Instellingen',
      ],
    );
    expect(rail.selectedIndex, 0, reason: 'a launch lands on Synchronisatie');

    // Start and the placeholder copy it carried are gone, not merely unselected.
    expect(find.text('Start'), findsNothing);
    expect(find.text('Account Manager'), findsNothing);
    expect(
      find.textContaining('Stemt gebruikersaccounts en klasgroepen'),
      findsNothing,
    );

    // The shell does not read as headerless without Start: the landing screen
    // carries its own eyebrow, in the operator's language (#265).
    expect(find.text('ARCADIA · SYNCHRONISATIE'), findsOneWidget);
    expect(find.text('Niet geconfigureerd'), findsOneWidget);

    // The per-product accent is layered on the Plink foundations.
    final BuildContext context = tester.element(find.byType(ReconcileScreen));
    final PlinkProductAccent? accent =
        Theme.of(context).extension<PlinkProductAccent>();
    expect(accent, isNotNull);
    expect(accent!.accent, kProductAccent);
  });
}
