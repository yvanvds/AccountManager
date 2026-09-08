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
  - `packages/account_store/` — persistence seams (settings, PersonId
    resolution, password queue) with file-backed defaults.
  - `packages/wisa_api/`, `packages/smartschool_api/`, `packages/azure_api/` —
    the three connectors.
  - `packages/account_linker/` — the pure cross-system `link()`.
  - `packages/account_actions/` — the action engine.
  - `packages/account_state/` — sync / link / apply orchestration and the
    materialized shared state.
  - `packages/late_arrivals/` — late-arrival ("te laat") registration at the
    reception desk: the scan resolver and the value types the rest of that
    flow shares (epic #399).
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
- The root `analysis_options.yaml` carries an `analyzer.exclude:` block listing
  `build/**` and the six platform directories. **Leave it there** (#415).
  Running `flutter analyze` from the repo root runs the Flutter tool's
  `AnalysisOptionsMigration` against that file — the workspace root is the
  Flutter project root — and it rewrites the file unless all seven patterns are
  present verbatim. Renaming the paths to `account_manager/...` does not satisfy
  it; the bare patterns come back. Excluding them narrows nothing: those
  directories hold no analyzed Dart source. CI analyzes with `dart analyze`,
  which never runs the migration.
- Every workspace member is held to the root ruleset, `account_manager/`
  included (#418): the app's own `analysis_options.yaml` includes both
  `package:flutter_lints/flutter.yaml` and `../analysis_options.yaml`, so it
  gets the widget lints *and* the strict language modes. Keep both entries, and
  keep the app file's `analyzer.exclude:` block — the Flutter tool migrates that
  file too, since `flutter test` and `flutter build windows` run from
  `account_manager/`.

## Where a new end-to-end test goes

End-to-end scenarios live under `account_manager/integration_test/`, in a
handful of files:

| File | Holds |
| --- | --- |
| `app_launch_test.dart` | The default home. `app shell and log panel`, `sign-in`, `Synchronisatie and the shared state`, `Klasgroepen`, `Acties`, `Acties: leerlingen`, `Acties: personeel`, `Azure and Office 365`, `duplicate accounts and id collisions`, `Wachtwoorden`, `Instellingen`. |
| `late_arrivals_test.dart` | `Te laat` — late-arrival registration at the reception desk, and the fakes only it needs (ticket printer transport, refusal beep, scanner keystrokes, Presence writer). |
| `app_update_test.dart` | `app updates` — the release check, the offer bar and the release notes, over the `update_fakes.dart` release/version fakes and the installed-version reader. |
| `support/e2e_support.dart` | Not a suite. The helpers and fakes more than one of the above needs: `graph`, `useTallWindow`, `railTab`, `openSettingsTab`, `FakeBroker`, `fakeToken`. |

**How to run them.** One `flutter test` invocation per file — never a
directory-wide one:

```
flutter test integration_test/app_launch_test.dart -d windows
```

`flutter test integration_test -d windows` (the whole directory in one command)
**does not work** and never has: the Windows desktop device can only start the
app once per invocation, so the second file dies with *"Error waiting for a
debug connection: The log reader stopped unexpectedly, or never started"*
before any of its tests run. `--concurrency=1` does not help — it is the
device, not the scheduler. CI therefore loops one invocation per file
(`.github/workflows/dart.yml`, job `app-integration`), and the glob picks new
files up with no edit. Measured cost of an extra file: ~15–20 s of launch
overhead (#421).

**Working on one area? Run only its file.** That is the point of the split:
a change to `Te laat` is verified by `late_arrivals_test.dart` alone (~26 s)
instead of all 181 tests (~5 min).

- **Put a new `testWidgets` inside the group its feature belongs to** — do not
  append it at the end of a file. The flat-append habit is what grew
  `app_launch_test.dart` to 16k unnavigable lines in the first place.
- If no group fits, add a new group rather than leaving the test loose. Every
  `testWidgets` in these files is inside a group; keep it that way.
- **A new file only earns its launch when the area brings fakes of its own.**
  Otherwise put the group in `app_launch_test.dart`. Splitting for tidiness
  alone buys nothing and costs everyone ~15 s a run.
- Helpers used by more than one *file* belong in `support/e2e_support.dart`, so
  the fakes cannot drift apart. Helpers used by more than one group inside a
  file belong in that file's `main` preamble; a helper only one group needs can
  live inside that group.
- The fake classes at the bottom of each file are shared by every group in it.
  Changing one to suit a new test can disturb an older one — extend rather than
  repurpose.

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
