# account_state

Layer-5 orchestration package for the Arcadia Account Manager port.

This is the seam-defining scaffold. It ships the **persistence interfaces**
the orchestration layer (sync → link → apply, settings, password generation)
will plug into, each with an in-memory default and a file-backed default — but
**no orchestration logic yet**. Later slices add the engine on top of these
seams without changing them.

Pure Dart plus `dart:io`. No Flutter, no UI coupling.

## Persist vs derive

The State layer holds two kinds of data, and only one kind is persisted here:

- **Persisted** — operator input and generated artefacts that must survive a
  restart and that nothing can recompute:
  - the **config** (`AppSettings`): school prefix, debug flag, and the
    per-connector **import-rule sets** — via `SettingsStore`;
  - the **PersonId map**: natural key → stable UUID — via `account_core`'s
    `PersonIdResolver` (default `account_store.FilePersonIdResolver`);
  - the **pending-password queue**: generated sheets awaiting export — via
    `PasswordQueueStore`.
- **Derived** — everything the linker and action engine recompute from the
  connector snapshots: `LinkedAccount`s, per-account/group action lists,
  dashboard counters. These are **never** stored here; they are a pure function
  of the snapshots plus the persisted PersonId map (INV-20). Caching a snapshot
  for fast first paint is a connector concern, not this package's.

Keeping I/O behind these interfaces is the same discipline `account_store`
applies to `PersonIdResolver`: the orchestration layer stays free of disk and
format details, so it can be unit-tested against the in-memory adapters with
zero network and zero infra.

## Seams

| Interface | Model | Defaults | Legacy counterpart |
|---|---|---|---|
| `SettingsStore` | `AppSettings` (+ import-rule codecs) | `InMemorySettingsStore`, `FileSettingsStore` | `config.json` / `SettingsState` |
| `PersonIdResolver` (from `account_core`) | `PersonId` | `FilePersonIdResolver` (from `account_store`) | — |
| `PasswordQueueStore` | `PasswordEntry` | `InMemoryPasswordQueueStore`, `FilePasswordQueueStore` | `PasswordManager` / `Passwords.json` |

## Scope notes

- `AppSettings` models the global flags and import-rule sets only. Connection
  credentials and the WISA workdate pair stay with the connectors' own
  live-config and are folded in by a later slice.
- `PasswordEntry` models the legacy `AccountPassword` fields; the co-account
  `Co1..Co6` addresses are deferred until the Passwords page is ported.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md) §7,
[`PROJECT_OVERVIEW.md`](../../PROJECT_OVERVIEW.md) §5–§7.
