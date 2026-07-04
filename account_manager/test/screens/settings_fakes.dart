/// Shared fakes for the Settings view tests (#106): the in-memory store and
/// secret provider the seam already ships, bundled behind the bootstrap closure
/// the screen expects.
library;

import 'package:account_manager/src/settings/settings_bootstrap.dart';
import 'package:account_state/account_state.dart';

/// One assembled Settings stack over the in-memory seams — a headless stand-in
/// for the Cosmos store + Key Vault provider, so a widget/integration test
/// drives the real screen with zero infra.
class SettingsHarness {
  SettingsHarness({
    AppSettings initial = const AppSettings(),
    Map<SecretRef, String> secrets = const {},
  })  : store = InMemorySettingsStore(initial),
        secrets = InMemorySecretProvider(secrets);

  final InMemorySettingsStore store;
  final InMemorySecretProvider secrets;

  SettingsServices get services =>
      SettingsServices(store: store, secrets: secrets);

  /// A ready-made bootstrap closure for [SettingsScreen]/[AccountManagerApp].
  Future<SettingsServices> Function() get bootstrap => () async => services;
}
