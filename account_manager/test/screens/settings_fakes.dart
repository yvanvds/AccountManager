/// Shared fakes for the Settings view tests (#106): the in-memory store and
/// secret provider the seam already ships, bundled behind the bootstrap closure
/// the screen expects.
library;

import 'package:account_manager/src/settings/settings_bootstrap.dart';
import 'package:account_state/account_state.dart';
import 'package:wisa_api/wisa_api.dart';

/// One assembled Settings stack over the in-memory seams — a headless stand-in
/// for the Cosmos store + Key Vault provider, so a widget/integration test
/// drives the real screen with zero infra.
class SettingsHarness {
  SettingsHarness({
    AppSettings initial = const AppSettings(),
    Map<SecretRef, String> secrets = const {},
    this.fetchWisaSchools,
    this.liveSettings,
  })  : store = InMemorySettingsStore(initial),
        secrets = InMemorySecretProvider(secrets);

  final InMemorySettingsStore store;
  final InMemorySecretProvider secrets;

  /// Optional WISA school-list fetcher (#142). When null the screen shows the
  /// fetch button disabled/without a wired fetcher; pass [FakeWisaSchoolFetcher]
  /// to drive the fetch flow offline.
  final WisaSchoolFetcher? fetchWisaSchools;

  /// The shared settings holder the screen publishes every loaded/saved
  /// document into (#238). Pass a [ReconcileHarness]'s own holder to model what
  /// production does — one instance behind both bootstraps — so a save in
  /// Instellingen reaches the running reconcile stack.
  final LiveSettings? liveSettings;

  SettingsServices get services => SettingsServices(
        store: store,
        secrets: secrets,
        fetchWisaSchools: fetchWisaSchools,
        liveSettings: liveSettings,
      );

  /// A ready-made bootstrap closure for [SettingsScreen]/[AccountManagerApp].
  Future<SettingsServices> Function() get bootstrap => () async => services;
}

/// A scripted [WisaSchoolFetcher] for tests: returns a canned school list and
/// records the connection + password it was called with, so a test can assert
/// the fetch was wired through the real screen without touching a live WISA.
class FakeWisaSchoolFetcher {
  FakeWisaSchoolFetcher(this.schools);

  final List<WisaSchool> schools;
  int calls = 0;
  WisaConnection? lastConnection;
  String? lastPassword;

  Future<List<WisaSchool>> call(
    WisaConnection connection,
    String password,
  ) async {
    calls++;
    lastConnection = connection;
    lastPassword = password;
    return schools;
  }
}
