#ifndef RUNNER_AAD_BROKER_H_
#define RUNNER_AAD_BROKER_H_

#include <flutter/flutter_engine.h>

#include <Windows.h>

// Registers the `net.attr-x.arcadia/aad_broker` method channel on |engine|.
//
// The channel is the native half of the Dart `MethodChannelAadBroker`
// (issue #98): it mints Azure AD bearer tokens for the signed-in Windows
// operator via the WAM broker (MSAL Runtime), silent-first with an interactive
// fallback. |parent_window| is the HWND the interactive account picker parents
// to.
//
// Two methods are handled, each taking {clientId, authority, scopes} and
// returning {accessToken, expiresOn (ms since epoch, UTC), account}:
//   - `acquireSilent`      — no-prompt acquisition; errors with code
//                            `no_account` when silent is not possible.
//   - `acquireInteractive` — shows the WAM sign-in UI.
//
// Failures surface as channel errors whose code the Dart layer maps onto
// `AadBrokerException` (`broker_unavailable`, `user_cancelled`, `no_account`,
// …).
void RegisterAadBroker(flutter::FlutterEngine* engine, HWND parent_window);

#endif  // RUNNER_AAD_BROKER_H_
