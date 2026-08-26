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

## Running the app from source (Windows)

The Azure AD app-registration values are school-specific and are **not** baked
into the binary — they come from `--dart-define` at run time
([aad_app_config.dart](account_manager/lib/src/auth/aad_app_config.dart)).
A build started without them launches, but `isConfigured` is `false`, so the
sign-in gate shows **"Not configured"** and every screen that needs a token —
Settings included — stays unreachable.

Copy [aad.local.json.example](account_manager/aad.local.json.example) to
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

Everything else — Cosmos, Key Vault, Blob, SignalR endpoints — resolves in three
layers (#370): this machine's `%APPDATA%\AccountManager\connection.json`, then
the `--dart-define` values the build carried, then the provisioned-infrastructure
defaults in `StoreEndpoints`
([reconcile_bootstrap.dart](account_manager/lib/src/reconcile/reconcile_bootstrap.dart)).
The merge is per field, so a file naming only the Cosmos account leaves the rest
where the build put them, and an install with no file behaves exactly as it did
before the file existed.

The file is written from **Instellingen → Verbinding**, which also has a
*Verbinding testen* button (a read-only round-trip to Cosmos and Key Vault). That
tab renders and saves even when the settings document cannot be loaded — a wrong
endpoint must not lock the operator out of the screen that fixes the endpoint. A
malformed or unreadable `connection.json` falls back to the defaults with a
warning on that tab rather than failing the launch. It holds endpoint URIs only,
never a key or a token.

The `.*.env` files in the repo root are unrelated to running the app: they hold
credentials for the opt-in live integration tests
([tool/live-tests.ps1](tool/live-tests.ps1)).

The SonarCloud badges above will activate once the operator finishes the SonarCloud project setup — see [.github/workflows/ci.yml](.github/workflows/ci.yml) for the steps.
