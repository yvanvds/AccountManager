# Windows AAD token broker (`aad_broker.cpp`)

The native half of the app's Azure AD sign-in (issue #98). It registers the
`net.attr-x.arcadia/aad_broker` method channel and mints bearer tokens for the
signed-in Windows operator via the **WAM broker** (MSAL Runtime), silent-first
with an interactive fallback. The Dart half is
`lib/src/auth/method_channel_aad_broker.dart`.

## Current state

`aad_broker.cpp` ships with the **method channel wired and compiling**, but the
WAM implementation is gated behind `HAVE_MSAL_RUNTIME`, which is **not defined
by default**. Without it, both `acquireSilent` and `acquireInteractive` return
the channel error `broker_unavailable`, which the Dart layer surfaces as a clear
"token broker is not built into this binary" message.

This is deliberate: the real implementation links the MSAL Runtime
(`msalruntime.dll`) and can only be built with the SDK vendored and only
**verified on a school-account machine** (per the project's live-testing
policy — the silent WAM path cannot run in CI). Completing and verifying it is
the manual follow-up the issue's test plan calls out.

## Completing the WAM implementation

1. **Vendor the MSAL Runtime redistributable.** Obtain `Microsoft.Identity.Client.NativeInterop` /
   the MSAL Runtime C SDK (headers `MSALRuntime*.h` + `msalruntime.dll` +
   import lib). Place them under `windows/third_party/msalruntime/` and add the
   include/lib dirs and `msalruntime.lib` to `runner/CMakeLists.txt`. Copy the
   DLL next to the built exe (an `install(FILES ...)`/post-build copy step).

2. **Define `HAVE_MSAL_RUNTIME`** for the runner target in `CMakeLists.txt`:
   `target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_MSAL_RUNTIME)`.

3. **Implement `aad_broker_msal.{h,cpp}`** exposing:

   ```cpp
   // Acquires a token via MSAL Runtime. Exactly one of on_success / on_error
   // must be invoked, on the platform thread (see threading note).
   void AcquireBrokeredToken(
       bool interactive, HWND parent_window,
       const std::string& client_id, const std::string& authority,
       const std::vector<std::string>& scopes,
       std::function<void(const std::string& token, int64_t expires_on_ms,
                          const std::string& account)> on_success,
       std::function<void(const std::string& code,
                          const std::string& message)> on_error);
   ```

   Sketch of the MSAL Runtime C API flow:
   - `MSALRUNTIME_Startup()` once at process start.
   - `MSALRUNTIME_CreateAuthParameters(clientId, authority, &params)`, then
     `MSALRUNTIME_SetRequestedScopes(params, L"scope1 scope2 …")`.
   - Silent: `MSALRUNTIME_SignInSilentlyAsync(params, correlationId, cb, cbData, &async)`.
     Map "no cached account / interaction required" errors to code `no_account`
     so the Dart session falls back to interactive.
   - Interactive: `MSALRUNTIME_SignInInteractivelyAsync(parent_window, params,
     correlationId, accountHint, cb, cbData, &async)`. Map the user-cancelled
     status to code `user_cancelled`.
   - In the callback, on success read
     `MSALRUNTIME_GetRawAccessToken`, `MSALRUNTIME_GetAccessTokenExpiryTime`
     (seconds since epoch → multiply to ms), and the account id via
     `MSALRUNTIME_GetAccount` + `MSALRUNTIME_GetAccountId`. On failure read
     `MSALRUNTIME_GetError` / status / error code.
   - Release every handle (`MSALRUNTIME_Release*`).

   **Threading.** MSAL Runtime invokes its callback on a background thread, but
   `flutter::MethodResult` must be used on the platform (UI) thread. Marshal the
   outcome back — e.g. post a custom `WM_APP` message to `parent_window` with a
   heap-allocated result, and call `on_success`/`on_error` from the window proc.
   Do **not** block the platform thread waiting for the interactive callback:
   the sign-in UI parents to `parent_window` and blocking deadlocks it.

## Manual verification (school-account machine)

- On a laptop signed in to Windows with the school AAD account: launch with the
  `--dart-define`s set (`AAD_CLIENT_ID`, `AAD_TENANT_ID`, `AAD_DOMAIN`,
  `SCHOOL_PREFIX`) and confirm the app reaches the shell with **no prompt**
  (silent path).
- On a machine not signed in with a school account (dev laptop): confirm the
  WAM account picker appears, and after sign-in the app reaches the shell.
- Confirm a subsequent Azure SQL connection reuses the session with no second
  prompt.
