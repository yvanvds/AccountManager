import 'dart:async';

import 'package:account_manager/src/auth/auth.dart';
import 'package:account_manager/src/auth/sign_in_gate.dart';
import 'package:azure_api/azure_api.dart' show AzureCredentials;
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_broker.dart';

void main() {
  final graph = AadResource.graph(AzureCredentials(
    clientId: 'client-123',
    tenantId: 'tenant-abc',
    azureDomain: 'school.example',
    schoolPrefix: 'GBS',
  ));

  Widget host(SignInSession session, {AadResource? resource}) => MaterialApp(
        theme: PlinkTheme.paper.copyWith(
          extensions: const <ThemeExtension<dynamic>>[
            PlinkProductAccent(Color(0xFF17796B)),
          ],
        ),
        home: SignInGate(
          session: session,
          graph: resource,
          child: const Text('APP CONTENT'),
        ),
      );

  testWidgets('reveals the app once the silent token is acquired',
      (tester) async {
    final broker = FakeBroker(silent: (_) => fakeToken('AT'));
    await tester.pumpWidget(host(SignInSession(broker), resource: graph));
    await tester.pumpAndSettle();

    expect(find.text('APP CONTENT'), findsOneWidget);
    expect(broker.silentCalls, ['graph']);
  });

  testWidgets('shows the signing-in panel while acquisition is in flight',
      (tester) async {
    // A broker whose silent acquisition never completes keeps the gate in the
    // signing-in phase.
    final stuck = _StuckBroker();
    await tester.pumpWidget(host(SignInSession(stuck), resource: graph));
    await tester.pump();

    expect(find.text('Aanmelden…'), findsOneWidget);
    expect(find.text('APP CONTENT'), findsNothing);
  });

  testWidgets('shows an error with retry when sign-in fails, then recovers',
      (tester) async {
    var attempts = 0;
    final broker = FakeBroker(
      silent: (_) => null,
      interactive: (_) {
        attempts++;
        if (attempts == 1) {
          throw const AadBrokerException('network down', code: 'broker_error');
        }
        return fakeToken('AT');
      },
    );
    await tester.pumpWidget(host(SignInSession(broker), resource: graph));
    await tester.pumpAndSettle();

    expect(find.text('Kon je niet aanmelden'), findsOneWidget);
    expect(find.text('network down'), findsOneWidget);
    expect(find.text('APP CONTENT'), findsNothing);

    await tester.tap(find.text('Probeer opnieuw'));
    await tester.pumpAndSettle();

    expect(find.text('APP CONTENT'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('a cancelled sign-in reads as cancelled, not a raw error',
      (tester) async {
    final broker = FakeBroker(
      silent: (_) => null,
      interactive: (_) => throw const AadBrokerException(
        'The user cancelled the request.',
        code: 'user_cancelled',
      ),
    );
    await tester.pumpWidget(host(SignInSession(broker), resource: graph));
    await tester.pumpAndSettle();

    expect(find.text('Het aanmelden is geannuleerd.'), findsOneWidget);
  });

  testWidgets('reveals the app directly when AAD is not configured',
      (tester) async {
    final broker = FakeBroker();
    await tester.pumpWidget(host(SignInSession(broker), resource: null));
    await tester.pumpAndSettle();

    expect(find.text('APP CONTENT'), findsOneWidget);
    // Never attempted an acquisition.
    expect(broker.silentCalls, isEmpty);
    expect(broker.interactiveCalls, isEmpty);
  });
}

/// A broker whose silent leg never completes — used to observe the in-flight
/// signing-in state.
class _StuckBroker implements AadBroker {
  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) =>
      Completer<BrokerToken?>().future;

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) =>
      Completer<BrokerToken>().future;
}
