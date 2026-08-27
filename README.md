# Arcadia Account Manager

[![CI](https://github.com/yvanvds/AccountManager/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/yvanvds/AccountManager/actions/workflows/ci.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_AccountManager&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=yvanvds_AccountManager)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_AccountManager&metric=coverage)](https://sonarcloud.io/summary/new_code?id=yvanvds_AccountManager)

Synchronises user accounts and class groups between WISA, Smartschool, and Azure AD / Office 365 for a Belgian secondary-school group.

This repository is in transition from a WPF / .NET Framework 4.8 desktop application to a **Flutter / Dart** application.

- **Project goal, layout, port order:** [CLAUDE.md](CLAUDE.md)
- **Architectural reference:** [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md)
- **Spec for the port:** [docs/domain-model.md](docs/domain-model.md)
- **Legacy WPF code (read-only reference):** [legacy-wpf/](legacy-wpf/)
- **Releasing / installing:** [docs/release-process.md](docs/release-process.md)

## Installing the app (Windows)

Operators install from a [GitHub
Release](https://github.com/yvanvds/AccountManager/releases): download
`AccountManager-Setup-vX.Y.Z.exe` and run it. The install is **per user**, into
`%LOCALAPPDATA%\Programs\AccountManager` — no administrator password needed.

The installer is **not code-signed**, so the first install shows *"Windows heeft
uw pc beveiligd"*. That is expected, not a virus warning: click **Meer
informatie**, then **Toch uitvoeren**.

An installed app checks GitHub for a newer release on launch and offers it in a
bar above the navigation rail. The check is non-blocking and silent when it
fails, and an update is **never** applied without the operator accepting it. The
running version, a manual check and the reason a check failed all live in
**Instellingen → Verbinding → Versie**. Sign-in and connection settings
(`%APPDATA%\AccountManager\`) survive an update.

Tagging, rolling back, and the rest of the process: see
[docs/release-process.md](docs/release-process.md).

### First run on a fresh install

A newly installed copy is **not configured to sign in**, and that is by design:
the school's tenant id, client id and domain are not in this (public) repository,
so no build can ship them. The first launch therefore lands on *"Niet
geconfigureerd"* with a **Naar Instellingen** button.

Fill in **Instellingen → Verbinding → Azure AD** — client id, tenant id, Azure
domain, school prefix — press **Verbinding bewaren**, and restart the app. That
writes `%APPDATA%\AccountManager\connection.json`, which the next launch reads.
No rebuild and no command line are involved; before #384 there was no way to do
this from an installed copy at all.

The backend coordinates on the same tab (Cosmos, Key Vault, Blob, SignalR) ship
with working defaults, so they usually need nothing.

## Running the app from source (Windows)

The Azure AD app-registration values are school-specific and are **not** baked
into the binary
([aad_app_config.dart](account_manager/lib/src/auth/aad_app_config.dart)) — this
repository is public. A build started without them launches, but `isConfigured`
is `false`, so every screen that needs a token stands down. **Instellingen stays
open**: it is where the values are supplied.

For a checkout, `--dart-define` is the convenient layer. Copy
[aad.local.json.example](account_manager/aad.local.json.example) to
`account_manager/aad.local.json` (gitignored), fill it in, then:

```powershell
cd account_manager
flutter run -d windows --dart-define-from-file=aad.local.json
```

Or press <kbd>F5</kbd> in VS Code — **Account Manager (Windows)** in
[.vscode/launch.json](.vscode/launch.json) passes the same flag.

The client id must be a **public-client** app registration with
`http://localhost:8765/auth-redirect` registered under *Authentication → Mobile
and desktop applications*; sign-in opens the system browser and captures the
redirect there. See
[README-aad-broker.md](account_manager/windows/runner/README-aad-broker.md) for
the loopback flow and the (not yet wired) native WAM broker.

### How the bootstrap resolves

The Azure AD app registration (#384) and the backend coordinates — Cosmos, Key
Vault, Blob, SignalR (#370) — live in one local file and resolve in the same
three layers, outermost first:

1. this machine's `%APPDATA%\AccountManager\connection.json`;
2. the `--dart-define` values the build carried;
3. the compiled defaults — the provisioned-infrastructure endpoints in
   `StoreEndpoints`
   ([reconcile_bootstrap.dart](account_manager/lib/src/reconcile/reconcile_bootstrap.dart)),
   and **empty strings** for the four Azure AD values.

The merge is per field, so a file naming only the Cosmos account leaves the rest
where the build put them, and a file written before #384 — endpoints only, no
Azure AD keys — still loads exactly as it did.

The file is written from **Instellingen → Verbinding**, which also has a
*Verbinding testen* button (a read-only round-trip to Cosmos and Key Vault). That
tab renders and saves even when the settings document cannot be loaded *and* when
Azure AD is not configured at all — a wrong endpoint must not lock the operator
out of the screen that fixes the endpoint, and the screen that fixes sign-in
cannot sit behind sign-in. A malformed or unreadable `connection.json` falls back
to the defaults with a warning on that tab rather than failing the launch.

Saving takes effect on the next launch, which the tab says out loud. Changing the
**tenant** additionally drops the cached tokens in
`%APPDATA%\AccountManager\auth\`: they were issued by the old tenant's STS and
have the wrong audience from that point on.

The file holds endpoint URIs and app-registration identifiers, and nothing else —
never a key, a token or a credential. Tokens live in the DPAPI-encrypted broker
cache; WISA and Smartschool credentials live in Key Vault.

The `.*.env` files in the repo root are unrelated to running the app: they hold
credentials for the opt-in live integration tests
([tool/live-tests.ps1](tool/live-tests.ps1)).

The SonarCloud badges above will activate once the operator finishes the SonarCloud project setup — see [.github/workflows/ci.yml](.github/workflows/ci.yml) for the steps.
