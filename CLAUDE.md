# Arcadia Account Manager

## Project goal

Port the existing **Arcadia Account Manager** desktop application from
**WPF / .NET Framework 4.8** to **Flutter / Dart**. The original application
synchronizes user accounts and class groups between WISA, Smartschool, and
Azure AD / Office 365 for a Belgian secondary-school group.

## Repository layout

- `legacy-wpf/` — the original C#/WPF solution. **Read-only reference
  material.** Do not modify any file under this directory. Use it only to
  understand existing behaviour, domain rules, and connector quirks.
- `packages/` — pure-Dart library packages. Everything that is not the
  Flutter app lives here as a workspace member. Current and planned packages:
  - `packages/account_core/` — canonical domain model (entities, enums,
    identity types, password generator, `ILog` sink). No Flutter, no I/O.
    Every other package depends on it.
  - Planned: `packages/wisa_api/`, `packages/smartschool_api/`,
    `packages/azure_api/`, `packages/account_linker/`, action engine.
- `account_manager/` — the Flutter app (UI + state). Depends on the
  `packages/*` libraries via `path:` dependencies. Currently empty.
- `pubspec.yaml` (repo root) — Dart workspace definition listing the
  workspace members and shared dev-dependencies.
- `analysis_options.yaml` (repo root) — lint/analyzer config applied to
  every workspace member.
- `docs/domain-model.md` — spec the port implements against.
- `docs/port-plan.md` — running document describing the port strategy.
- `PROJECT_OVERVIEW.md` — authoritative architectural reference for the legacy
  application; the source of truth alongside the code under `legacy-wpf/`.

## Working with this repo

- The authoritative architectural references are `docs/domain-model.md`
  and `PROJECT_OVERVIEW.md`, together with the source under `legacy-wpf/`.
  Read these to understand any subsystem before porting it.
- Treat `legacy-wpf/` as immutable. Bug fixes, refactors, and feature work all
  belong in the new Dart/Flutter packages.
- Everything that is not the Flutter app is a workspace package under
  `packages/`. Each package is pure Dart (no Flutter imports) so it can be
  unit-tested headlessly and reused from any Dart frontend.
- `account_manager/` is the Flutter app and depends on the `packages/*`
  libraries.

## Port order

When porting work begins, follow the order below. Each layer is self-contained
and testable before moving to the next.

1. **Domain** — `IAccount`, `IGroup`, `IRule`, enums, password generator.
2. **Connectors** — WISA, Smartschool, Azure (ported one at a time).
3. **Linker** — cross-system reconciliation (`LinkedAccounts`, `LinkedGroups`,
   `LinkedStaffMembers`).
4. **Action engine** — group / student / staff action families and parsers.
5. **State** — `ApplicationState` and the per-system `*State` classes.
6. **Views** — Flutter UI (Dashboard, Klassen, Accounts, Passwords, Acties,
   Settings, Log panel).
