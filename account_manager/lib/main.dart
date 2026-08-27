import 'dart:io';

import 'package:account_state/account_state.dart' show LiveSettings;
import 'package:azure_api/azure_api.dart'
    show
        EncryptedTokenCache,
        InMemoryTokenCache,
        LoopbackAuthorizer,
        TokenCache;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/aad_broker.dart';
import 'src/auth/composite_broker.dart';
import 'src/auth/dpapi.dart';
import 'src/auth/file_token_cache.dart';
import 'src/auth/loopback_aad_broker.dart';
import 'src/auth/method_channel_aad_broker.dart';
import 'src/auth/sign_in_session.dart';
import 'src/reconcile/reconcile_bootstrap.dart';
import 'src/settings/connection_config.dart';
import 'src/settings/settings_bootstrap.dart';
import 'src/update/update_bootstrap.dart';

void main() => launchAccountManager();

/// The real launch, with exactly one seam in it.
///
/// [connection] is where this machine's bootstrap file lives; production passes
/// nothing and gets `%APPDATA%\AccountManager\connection.json`. An integration
/// test passes a throwaway store, so driving the *real* entry point can neither
/// depend on nor touch the operator's own configuration — which matters more
/// since #384, because that file now decides whether the app signs in at all.
Future<void> launchAccountManager({ConnectionStore? connection}) async {
  // Resolving the bootstrap is an async file read, and the values it carries
  // decide what `runApp` is handed, so the binding has to exist before the
  // await.
  WidgetsFlutterBinding.ensureInitialized();

  // Where this machine's backend lives and which Azure AD app registration it
  // signs in with (#370 endpoints, #384 AAD). Resolved **once**, here, and the
  // whole launch runs on that one answer: a launch that read the file twice
  // could sign in against one version of it and talk to the backend of another,
  // and the Verbinding tab promises a relaunch rather than a live swap anyway.
  //
  // The resolution never throws — a malformed file degrades to the compiled
  // defaults and says so in Instellingen → Verbinding.
  final store = connection ?? connectionStoreForThisMachine();
  final resolved = await store.read();

  // Azure AD app-registration values: this machine's connection.json over the
  // --dart-define values over the (empty) compiled defaults — see AadAppConfig.
  // An unconfigured build still launches, gated into a "not configured" state
  // rather than a failed sign-in, and Instellingen → Verbinding → Azure AD is
  // where that gate is opened from.
  final config = resolved.aad;

  // Two brokers, tried in order (see CompositeBroker):
  //   1. the native Windows WAM broker — silent, no prompt, on a school-account
  //      machine (falls through with `broker_unavailable` until the MSAL
  //      Runtime SDK is wired, see windows/runner/README-aad-broker.md);
  //   2. the interactive loopback OAuth flow — opens the system browser, works
  //      on any machine (the dev laptop today).
  final broker = CompositeBroker(<AadBroker>[
    MethodChannelAadBroker(
      clientId: config.clientId,
      authority: config.authority,
    ),
    LoopbackAadBroker.oauth(
      clientId: config.clientId,
      tenantId: config.tenantId,
      azureDomain: config.azureDomain,
      schoolPrefix: config.schoolPrefix,
      authorizer: LoopbackAuthorizer(launchBrowser: _openInBrowser).call,
      // Persist the sign-in across restarts (#103): each resource's OAuth
      // credentials are DPAPI-encrypted (user-scoped) on disk, so a returning
      // operator gets a silent acquisition instead of a browser round-trip.
      cacheFactory: _persistentTokenCache,
    ),
  ]);

  final session = SignInSession(broker);

  // One settings document, shared by the two otherwise-independent bootstraps
  // (#238). The Settings view publishes every document it loads or saves into
  // it; the reconcile stack's WISA pull reads it back at pull time, and the
  // reconcile screen refuses a drift check while a saved change has not been
  // synced yet. Without this shared instance the two stacks each held their own
  // copy and a save reached the connectors only on the next launch.
  final liveSettings = LiveSettings();

  // The backend coordinates this launch runs on — the same single resolution
  // the sign-in config above came from.
  final endpoints = resolved.endpoints;

  runApp(
    AccountManagerApp(
      session: session,
      graph: config.isConfigured ? config.graph : null,
      // The Verbinding tab's own seams. Wired unconditionally — including on a
      // build where AAD is not configured — because this is the tab that exists
      // to be reachable when nothing else is.
      connection: ConnectionServices(
        store: store,
        probe: (StoreEndpoints ends) =>
            probeConnectionLive(ends, session: session),
        // A saved tenant change makes every cached token the wrong audience
        // (#384), so they go.
        forgetTokens: _forgetCachedTokens,
      ),
      // The update check (#371). Wired unconditionally too — an install whose
      // AAD or Cosmos config is wrong is exactly the one that most needs to be
      // able to move to a build where it is not.
      //
      // `autoCheck: kReleaseMode` is the only gate: a release build is an
      // *installed* build, which is the only kind there is anything to update.
      // A `flutter run` checkout and every integration-test launch would
      // otherwise reach out to api.github.com on every start, and neither has an
      // installer to apply. The manual button in Instellingen still works.
      update: productionUpdateServices(autoCheck: kReleaseMode),
      // The reconcile stack (settings from Azure SQL, secrets from Key Vault,
      // the three connectors) is assembled lazily, the first time a screen that
      // needs it is opened — after the sign-in gate has a session to mint tokens
      // from. Memoized so the Reconcile and Passwords screens share **one** stack
      // (and so one queue instance links an apply to the Passwords view); a
      // failed attempt is not cached, so the reconcile screen's retry re-runs it.
      reconcileBootstrap: config.isConfigured
          ? _memoizeOnSuccess(
              () async => bootstrapReconcile(
                session: session,
                aad: config,
                liveSettings: liveSettings,
                endpoints: endpoints,
              ),
            )
          : null,
      // The settings seams (Cosmos-backed store + Key Vault secrets) are
      // assembled lazily the first time the Settings screen is opened, memoized
      // so repeat visits reuse the one store/provider. Kept separate from the
      // reconcile stack on purpose: the Settings view exists to fix an
      // incomplete config, so it must not depend on the connectors bootstrapping
      // successfully.
      settingsBootstrap: config.isConfigured
          ? _memoizeOnSuccess(
              () async => bootstrapSettings(
                session: session,
                liveSettings: liveSettings,
                endpoints: endpoints,
              ),
            )
          : null,
    ),
  );
}

/// Wraps [make] so all callers share the first successful `Future`, while a
/// failed attempt clears the cache so the next call retries. Keeps the reconcile
/// stack a singleton without breaking the reconcile screen's retry-on-error.
Future<T> Function() _memoizeOnSuccess<T>(Future<T> Function() make) {
  Future<T>? pending;
  return () {
    final existing = pending;
    if (existing != null) return existing;
    final started = make().then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        pending = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    pending = started;
    return started;
  };
}

/// The persistent, encrypted token cache for one resource: ciphertext in
/// `%APPDATA%\AccountManager\auth\<resource>.token`, DPAPI (user scope) as the
/// cipher — never a plaintext refresh token on disk. Outside Windows (or with
/// no APPDATA) sign-in still works, just per-run: in-memory only.
TokenCache _persistentTokenCache(String resourceId) {
  final appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) {
    return InMemoryTokenCache();
  }
  final path = '$_authCacheDirectory\\$resourceId.token';
  return EncryptedTokenCache(
    inner: FileTokenCache(path),
    encrypt: Dpapi.protect,
    decrypt: Dpapi.unprotect,
  );
}

/// Where [_persistentTokenCache] keeps its ciphertext, named once so the eraser
/// below cannot drift from the writer.
String get _authCacheDirectory =>
    '${Platform.environment['APPDATA']}\\AccountManager\\auth';

/// Deletes every cached token on this machine (#384).
///
/// Called when a save in Instellingen → Verbinding changes the **tenant**: the
/// cached tokens were issued by the old tenant's STS for the old tenant's
/// resources, so after the change every one of them has the wrong audience.
/// Keeping them buys nothing and costs a confusing failure — the next launch
/// would attempt a silent acquisition that can only be rejected, and would
/// report that as a broken sign-in rather than as the tenant change it is.
///
/// Best effort by design. A locked file means one stale ciphertext lingers,
/// which the broker discards on its first rejection anyway; it must never be a
/// reason for the save itself to fail.
Future<void> _forgetCachedTokens() async {
  final appData = Platform.environment['APPDATA'];
  if (!Platform.isWindows || appData == null || appData.isEmpty) return;
  final dir = Directory(_authCacheDirectory);
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // Best effort — see above.
  }
}

/// Opens [url] in the operator's default browser for the interactive
/// loopback sign-in. Uses the Windows shell URL handler; the loopback HTTP
/// server ([LoopbackAuthorizer]) captures the redirect back.
Future<void> _openInBrowser(Uri url) async {
  if (Platform.isWindows) {
    await Process.start('rundll32', <String>[
      'url.dll,FileProtocolHandler',
      url.toString(),
    ]);
    return;
  }
  // Best-effort for other desktop platforms.
  final opener = Platform.isMacOS ? 'open' : 'xdg-open';
  await Process.start(opener, <String>[url.toString()]);
}
