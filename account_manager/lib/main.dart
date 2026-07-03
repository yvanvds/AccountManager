import 'dart:io';

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

  runApp(
    AccountManagerApp(
      session: session,
      graph: config.isConfigured ? config.graph : null,
      // The reconcile stack (settings from Azure SQL, secrets from Key Vault,
      // the three connectors) is assembled lazily, the first time the screen
      // is opened — after the sign-in gate has a session to mint tokens from.
      reconcileBootstrap: config.isConfigured
          ? () => bootstrapReconcile(session: session, aad: config)
          : null,
    ),
  );
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
