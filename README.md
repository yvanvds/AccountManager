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

## Running the app (Windows)

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

Everything else — Cosmos, Key Vault, Blob, SignalR endpoints — defaults to the
provisioned infrastructure in `StoreEndpoints`
([reconcile_bootstrap.dart](account_manager/lib/src/reconcile/reconcile_bootstrap.dart))
and only needs a `--dart-define` to point at a different environment.

The `.*.env` files in the repo root are unrelated to running the app: they hold
credentials for the opt-in live integration tests
([tool/live-tests.ps1](tool/live-tests.ps1)).

The SonarCloud badges above will activate once the operator finishes the SonarCloud project setup — see [.github/workflows/ci.yml](.github/workflows/ci.yml) for the steps.
