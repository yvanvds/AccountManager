---
name: live-tests
description: Run the opt-in live integration tests against the real WISA, Smartschool, and Azure hosts. Loads the local .*.env credential files and, for Azure, mints a fresh read-only Graph token via the Azure CLI (a stored bearer token expires in ~1h). All live tests are read-only (sync only) per the project's live-testing policy. User-invocable as /live-tests; pass a connector name (wisa, smartschool, azure) to run just one.
---

# Run live integration tests

Drives each connector's `test/integration/` suite against its real host,
provisioning credentials from the gitignored `.wisa.env`, `.smartschool.env`,
and `.azure.env` files. Wraps [`tool/live-tests.ps1`](../../../tool/live-tests.ps1).

## When to use

- The user invokes `/live-tests` (optionally `/live-tests azure`).
- The user asks to run the live/integration tests against real WISA,
  Smartschool, or Azure.

These tests hit production school systems. They are **read-only** (sync only)
by design — never extend them to writes here; write coverage stays manual and
local per the live-testing policy.

## Prerequisites

1. The relevant `.*.env` file(s) exist at the repo root, populated from the
   matching `.<name>.env.example`. A missing file just self-skips that
   connector (its test skips when its trigger var is empty).
2. **Azure only:** `az login` has been run with an account that can read the
   directory. The script mints a fresh Graph token via
   `az account get-access-token`; it does not read a stored token.

## Steps

1. Pick the scope from the argument: `wisa`, `smartschool`, `azure`, or (no
   argument) all three.
2. Run the helper from the repo root:
   ```powershell
   ./tool/live-tests.ps1            # all connectors
   ./tool/live-tests.ps1 -Only azure
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