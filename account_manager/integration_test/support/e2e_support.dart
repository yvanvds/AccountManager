/// Helpers and fakes shared by more than one end-to-end file (#421).
///
/// `flutter test integration_test -d windows` starts a fresh app process per
/// test *file*, so the suite is split across a handful of files rather than one
/// (see `CLAUDE.md`, "Where a new end-to-end test goes"). Anything more than one
/// of those files needs lives here, so the fakes cannot drift apart; a helper
/// only one file uses stays in that file.
///
/// This file is deliberately not named `*_test.dart` — `flutter test
/// integration_test` collects test files by that suffix, and a support library
/// is not a suite.
library;

import 'package:account_manager/src/auth/auth.dart';
import 'package:azure_api/azure_api.dart' show AzureCredentials;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Graph resource every launch signs in against, over a fake tenant.
final AadResource graph = AadResource.graph(AzureCredentials(
  clientId: 'client-123',
  tenantId: 'tenant-abc',
  azureDomain: 'school.example',
  schoolPrefix: 'GBS',
));

/// Gives the app a tall viewport so the reconcile screen's below-the-fold
/// sections lay out without scrolling. The body is a lazy [CustomScrollView]
/// (#111), so off-screen slivers are not built; a tall window keeps the
/// presence-only assertions honest. Reset after each test.
void useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The navigation-rail entry labelled [label].
///
/// Scoped to the rail on purpose (#366). The app lands on Synchronisatie now,
/// so that screen's own heading is on stage from the very first frame and a
/// bare `find.text('Synchronisatie')` matches the rail entry *and* the
/// heading it leads to. Every rail tap goes through here, so the same holds
/// for whichever destination the shell happens to open on.
Finder railTab(String label) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    );

/// Switches the Settings view to the tab with [tabKey] (#140: config is split
/// across Algemeen / Wisa / Smartschool / Azure / Te laat tabs).
Future<void> openSettingsTab(WidgetTester tester, String tabKey) async {
  await tester.tap(find.byKey(ValueKey(tabKey)));
  await tester.pumpAndSettle();
}

/// A broker scripted per test — a fake WAM broker so no live tenant is touched.
class FakeBroker implements AadBroker {
  FakeBroker({this.silent, this.interactive});

  BrokerToken? Function(AadResource resource)? silent;
  BrokerToken Function(AadResource resource)? interactive;
  final List<String> silentCalls = <String>[];
  final List<String> interactiveCalls = <String>[];

  @override
  Future<BrokerToken?> acquireSilent(AadResource resource) async {
    silentCalls.add(resource.id);
    return silent?.call(resource);
  }

  @override
  Future<BrokerToken> acquireInteractive(AadResource resource) async {
    interactiveCalls.add(resource.id);
    final result = interactive?.call(resource);
    if (result == null) {
      throw const AadBrokerException('no interactive token');
    }
    return result;
  }
}

/// A broker token carrying [v] as its access token, valid for an hour.
BrokerToken fakeToken(String v) => BrokerToken(
      accessToken: v,
      expiresOn: DateTime.now().toUtc().add(const Duration(hours: 1)),
      account: 'operator@school.example',
    );
