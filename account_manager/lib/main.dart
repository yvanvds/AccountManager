import 'dart:io';

import 'package:account_state/account_state.dart' show LiveSettings;
import 'package:azure_api/azure_api.dart'
    show
        EncryptedTokenCache,
        InMemoryTokenCache,
        LoopbackAuthorizer,
        TokenCache;
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/aad_app_config.dart';
import 'src/auth/aad_broker.dart';
import 'src/auth/composite_broker.dart';
import 'src/auth/dpapi.dart';
import 'src/auth/file_token_cache.dart';
import 'src/auth/loopback_aad_broker.dart';
import 'src/auth/method_channel_aad_broker.dart';
import 'src/auth/sign_in_session.dart';
import 'src/reconcile/reconcile_bootstrap.dart';
import 'src/settings/settings_bootstrap.dart';

void main() {
  // Azure AD app-registration values come from --dart-define (see
  // AadAppConfig); an unconfigured build still launches, gated into a
  // "not configured" state rather than a failed sign-in.
  final config = AadAppConfig.fromEnvironment();

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

  runApp(
    AccountManagerApp(
      session: session,
      graph: config.isConfigured ? config.graph : null,
      // The reconcile stack (settings from Azure SQL, secrets from Key Vault,
      // the three connectors) is assembled lazily, the first time a screen that
      // needs it is opened — after the sign-in gate has a session to mint tokens
      // from. Memoized so the Reconcile and Passwords screens share **one** stack
      // (and so one queue instance links an apply to the Passwords view); a
      // failed attempt is not cached, so the reconcile screen's retry re-runs it.
      reconcileBootstrap: config.isConfigured
          ? _memoizeOnSuccess(
              () => bootstrapReconcile(
                session: session,
                aad: config,
                liveSettings: liveSettings,
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
              () => bootstrapSettings(
                session: session,
                liveSettings: liveSettings,
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
  final path = '$appData\\AccountManager\\auth\\$resourceId.token';
  return EncryptedTokenCache(
    inner: FileTokenCache(path),
    encrypt: Dpapi.protect,
    decrypt: Dpapi.unprotect,
  );
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
