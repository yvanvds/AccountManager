---
name: live-tests
description: Run the opt-in live integration tests against the real WISA, Smartschool, Azure, Cosmos, and SignalR hosts. Loads the local .*.env credential files and mints a fresh token via the Azure CLI where needed (a stored bearer token expires in ~1h). The connector syncs are read-only; the Cosmos data-store round-trip and the SignalR broadcast are write-capable and self-contained (manual/opt-in only, not CI) per the project's live-testing policy. User-invocable as /live-tests; pass a target name (wisa, smartschool, azure, cosmos, signalr) to run just one.
---

# Run live integration tests

Drives each connector's `test/integration/` suite against its real host,
provisioning credentials from the gitignored `.wisa.env`, `.smartschool.env`,
and `.azure.env` files. Wraps [`tool/live-tests.ps1`](../../../tool/live-tests.ps1).

## When to use

- The user invokes `/live-tests` (optionally `/live-tests azure`).
- The user asks to run the live/integration tests against real WISA,
  Smartschool, or Azure.

The connector tests (WISA / Smartschool / Azure) hit production school systems
and are **read-only** (sync only) by design — never extend them to writes here.
The **Cosmos** target is different: it exercises the app's own datastore, so it
is **write-capable** (round-trips the settings/queue documents, mints a
disposable identity key) but restores or deletes everything it writes. Per the
live-testing policy it is manual/opt-in only and never runs in CI. The
**SignalR** target (#124) opens a real subscriber WebSocket and broadcasts a
probe signal to prove the round-trip, so it is **write-capable** too (the probe
carries a sentinel generation and no data, and writes to no store) and is
likewise manual/opt-in only.

## Prerequisites

1. The relevant `.*.env` file(s) exist at the repo root, populated from the
   matching `.<name>.env.example`. A missing file just self-skips that
   connector (its test skips when its trigger var is empty).
2. **Azure only:** `az login` has been run with an account that can read the
   directory. The script mints a fresh Graph token via
   `az account get-access-token`; it does not read a stored token.

## Steps

1. Pick the scope from the argument: `wisa`, `smartschool`, `azure`, `cosmos`,
   `signalr`, or (no argument) all of them.
2. Run the helper from the repo root:
   ```powershell
   ./tool/live-tests.ps1            # all targets
   ./tool/live-tests.ps1 -Only azure
   ./tool/live-tests.ps1 -Only cosmos
   ./tool/live-tests.ps1 -Only signalr
   ```
3. Report the result. The Azure sync takes ~30s (per-group member fetch); the
   test carries a 3-minute timeout. Each connector logs counts only, never row
   contents or credentials.
4. If Azure fails with an auth error (`401`, "JWT is not well formed",
   "token expired"), the cause is almost always that `az login` is stale —
   re-run `az login` and try again. Do **not** paste a long-lived token into
   `.azure.env`.

## Notes

- The script sets credentials into the current process environment; they
  persist for the rest of the shell session. Open a fresh shell to clear them.
- CI runs these same tests but authenticates Azure via OIDC federation (no
  stored secret) — see [.github/workflows/dart.yml](../../../.github/workflows/dart.yml).