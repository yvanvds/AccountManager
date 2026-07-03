# account_state

Layer-5 orchestration package for the Arcadia Account Manager port.

It ships the **persistence interfaces** the orchestration layer (sync → link →
apply, settings, password generation) plugs into, each with an in-memory
default and a file-backed default, plus the first slice of orchestration on top
of them: **snapshot ownership and `sync`**. Later slices add link/apply without
changing these seams.

Pure Dart plus `dart:io`. No Flutter, no UI coupling.

## Sync + snapshot ownership

The State layer owns the three connector snapshots and drives syncs
(domain-model §6.1):

- `SystemState<S>` holds one system's last-good snapshot, its `lastSync`
  (stamped from the snapshot's `fetchedAt`), and a **transient** connection-test
  state (`ConnectionState`, starts `unknown` every session, never persisted).
  `sync()` calls an injected `Syncer<S>` and replaces the stored snapshot only
  on success — a failed sync leaves the previous snapshot and `lastSync`
  intact. It mirrors a legacy per-system `*State` but carries no config, disk,
  or observers.
- `ApplicationState` owns the three `SystemState`s and exposes
  `sync(Origin) → Future<Snapshot>`, dispatching to the matching system.

The connector and its per-sync parameters live behind the `Syncer` seam
(`Future<S> Function(S? previous)`), so this layer stays connector-agnostic and
unit-testable against fakes. The `previous` argument is what threads
incremental state: `azureSyncer` reads `previous.deltaToken` to run
`/users/delta` from day one (PAIN-2) instead of re-pulling the whole tenant.
WISA and Smartschool do a full read each sync, so their syncers are the
one-liner `(_) => connector.sync(...)` written at the wiring site, where the
WISA workdate and import-rule sets (folded in by a later slice) are available.

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
| `SecretProvider` | `SecretRef` → value | `InMemorySecretProvider` | inline secrets in `config.json` |
| `PersonIdResolver` (from `account_core`) | `PersonId` | `FilePersonIdResolver` (from `account_store`) | — |
| `PasswordQueueStore` | `PasswordEntry` | `InMemoryPasswordQueueStore`, `FilePasswordQueueStore` | `PasswordManager` / `Passwords.json` |

## Config model

`AppSettings` gathers everything the legacy per-system `*State` classes each
persisted into one immutable value (PROJECT_OVERVIEW §6.2):

- global flags — `schoolPrefix`, `debugMode` (legacy `SettingsState`);
- three **connection profiles** — `WisaConnection` (endpoint + the real/virtual
  `WorkDateSetting` pair), `SmartschoolConnection` (endpoint, group paths, the
  `useGrades`/`useYears` flags and fixed-length grade/year label arrays), and
  `AzureConnection` (app registration + domain);
- the per-connector **import-rule sets** applied at snapshot construction
  (spec §3.11).

**Secrets never enter the blob.** The WISA password and Smartschool passphrase
are modeled as a `SecretRef` on their profile and resolved through a
`SecretProvider`; `toJson` emits only the (non-sensitive) ref name. Phase B
swaps `InMemorySecretProvider` for a Key-Vault-backed implementation without
touching anything above the seam. `WorkDateSetting.resolve(now)` keeps the live
clock out of the model, mirroring `WisaLiveConfig.resolveWorkDate`.

## Scope notes

- `PasswordEntry` models the legacy `AccountPassword` fields; the co-account
  `Co1..Co6` addresses are deferred until the Passwords page is ported.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md) §7,
[`PROJECT_OVERVIEW.md`](../../PROJECT_OVERVIEW.md) §5–§7. Overall strategy:
[`docs/port-plan.md`](../../docs/port-plan.md).
