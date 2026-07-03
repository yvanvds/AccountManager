# Port Plan

The running strategy for porting the **Arcadia Account Manager** from WPF /
.NET Framework 4.8 to Flutter / Dart. It records *how* the port is sequenced and
*where it currently stands*, so any contributor can see what is done, what is in
flight, and what each remaining slice depends on. The *what* — the target domain
model and invariants — lives in [`domain-model.md`](domain-model.md); the legacy
behaviour it ports from is catalogued in
[`../PROJECT_OVERVIEW.md`](../PROJECT_OVERVIEW.md).

## Strategy

- **Bottom-up, one layer at a time.** Each layer is pure Dart, headlessly
  unit-testable, and finished (with tests) before the next starts. The Flutter
  app sits on top and depends only on the packages, never the reverse.
- **Packages, not a monolith.** Everything that is not the Flutter app is a
  workspace member under `packages/`. No package imports Flutter, so the whole
  domain + connector + orchestration stack runs under `dart test` with zero UI,
  zero network, zero infra.
- **Seams for every side effect.** Disk, network, identity minting, secrets, and
  the system clock are each hidden behind an injected interface with an
  in-memory default. Production wires the real implementation; tests wire a
  fake. This is what keeps the layers testable and is the discipline the port
  exists to establish (the legacy linker was entangled with WPF state and had no
  tests).
- **Fix the four structural pain points as we cross them**, never in a big-bang
  rewrite: Smartschool multi-membership (PAIN-1), Azure delta-from-day-one
  (PAIN-2), dry-run apply (PAIN-3), and the missing test coverage (PAIN-4).

## Layer order and status

Ported in the order below (mirrors `CLAUDE.md`). Each layer is a package (or a
slice of one) landed behind its own issue/PR.

| # | Layer | Package(s) | Status |
|---|-------|-----------|--------|
| 1 | **Domain** — entities, enums, identity, password generator, `ILog` | `account_core` | ✅ done |
| 2 | **Connectors** — WISA, Smartschool, Azure (incl. import-rule types) | `wisa_api`, `smartschool_api`, `azure_api` | ✅ done |
| 3 | **Linker** — cross-system reconciliation (accounts, groups, staff) | `account_linker` | ✅ done |
| 4 | **Action engine** — group / student / staff action families + dry-run | `account_actions` | ✅ done |
| 5 | **State** — snapshots, link/apply orchestration, persistence seams | `account_state`, `account_store` | 🚧 in progress |
| 6 | **Views** — Flutter Windows desktop app (Plink design system) | `account_manager/` | ⬜ not started |

## Layer 5 — State & persistence (current)

Tracked under epic **#76**. The State layer owns the connector snapshots, drives
sync → link → apply, and persists the operator-tunable config. It is split into
three phases:

### Phase A — pure-Dart State layer *(in progress)*

Landed slices:

- **#69** — scaffold `account_state`; the `SettingsStore`, `PasswordQueueStore`,
  and `PersonIdResolver` persistence seams with in-memory + file defaults.
- **#70** — sync + snapshot ownership: `SystemState<S>` and `ApplicationState`,
  replacing a snapshot only on a successful `sync`.
- **#71** — link + placement: `LinkedState` re-derives the pure `link()` over the
  current snapshots, with membership/tree-dependent placement wired through a
  `PlacementResolver`.
- **#72** — apply + incremental refresh: `StateApplier` runs an action's dry-run
  capable `apply()`, then patches the owning snapshot and re-links with no
  re-sync (or accumulates a `DontImportFromWisa` rule and re-syncs WISA).
- **#73** — **settings/config model + import-rule sets** *(this slice)*. See below.

### Phase A / #73 — settings/config model

Fills out `AppSettings` from the two-field scaffold into the full config the
legacy `config.json` held, gathered from the per-system `*State` classes into
one immutable value:

- **Global flags** — `schoolPrefix`, `debugMode` (legacy `SettingsState`).
- **Three connection profiles**:
  - `WisaConnection` — server / port / database / username, plus the real and
    virtual **work-date pair** (`WorkDateSetting`, each with an `isNow` flag).
  - `SmartschoolConnection` — uri / testUser / student & staff group paths, the
    `useGrades` / `useYears` flags, and the fixed-length grade[3] / year[7]
    **label vocabulary**.
  - `AzureConnection` — clientId / tenantId / domain.
- **Import-rule sets** — the WISA (`ReplaceInstitute`, `DontImportClass`,
  `MarkAsVirtual`, `DontImportUserFromWisa`) and Smartschool
  (`DiscardSmartschoolGroup`, `NoSmartschoolSubgroups`) rules, round-tripped
  through `SettingsStore` via the tagged-JSON codecs.

Two seams keep the model clean:

- **`SecretProvider` / `SecretRef`.** The legacy config stored the WISA password
  and Smartschool passphrase in cleartext. The port models each secret as a
  `SecretRef` (a stable pointer) on its profile and resolves the value through a
  `SecretProvider`; `toJson` emits only the ref name, so **no credential is ever
  written to the settings blob**. Phase B backs the same seam with Key Vault.
- **Clock injection.** `WorkDateSetting.resolve(now)` takes the current time as
  an argument instead of reading `DateTime.now()` internally, so the model has
  no hidden clock and round-trips deterministically.

### Phase B — centralized Azure SQL persistence *(not started, epic #74)*

Swap the file-backed defaults (`FilePersonIdResolver`, `FileSettingsStore`,
`FilePasswordQueueStore`) and the `InMemorySecretProvider` for centralized
adapters — Azure SQL for the shared state, Key Vault for the secrets — so the
tool can move to team maintenance. Nothing above the seams changes.

### Phase C — Flutter Windows desktop app *(not started, epic #75)*

Port the six WPF pages (Dashboard, Klassen, Accounts, Passwords, Acties,
Settings, Log panel) onto the `account_state` orchestration surface, reusing the
Plink design system rather than a bespoke UI.

## Conventions for new slices

- One issue → one branch → one PR, each leaving the changed code covered by
  tests (unit for logic, integration for user-visible Flutter flows).
- Keep secrets, disk, network, and the clock behind their seams; never read them
  directly from a domain or orchestration type.
- Treat `legacy-wpf/` as immutable reference. Behaviour changes are recorded as
  "keep / fix" decisions in [`domain-model.md`](domain-model.md) §7, not silent
  drift.
