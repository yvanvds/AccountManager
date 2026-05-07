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
- `account_api/` — will become a **pure Dart package** containing the domain
  model, the WISA / Smartschool / Azure connectors, the linker, and the action
  engine. Currently empty.
- `account_manager/` — will become the **Flutter app** (UI + state). It will
  depend on `account_api/` via a `path:` dependency. The two packages together
  form a Dart workspace. Currently empty.
- `docs/port-plan.md` — running document describing the port strategy.
- `PROJECT_OVERVIEW.md` — authoritative architectural reference for the legacy
  application; the source of truth alongside the code under `legacy-wpf/`.

## Working with this repo

- The authoritative architectural reference is `PROJECT_OVERVIEW.md` together
  with the source under `legacy-wpf/`. Read these to understand any subsystem
  before porting it.
- Treat `legacy-wpf/` as immutable. Bug fixes, refactors, and feature work all
  belong in the new Dart/Flutter packages.
- `account_api/` is pure Dart (no Flutter imports) so it can be unit-tested
  headlessly and reused from any Dart frontend.
- `account_manager/` is the Flutter app and depends on `account_api/`.

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
