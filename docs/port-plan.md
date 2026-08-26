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
  re-sync (a `DontImportFromWisa` rule is accumulated *and* applied to the WISA
  snapshot in place — since #345 that path re-syncs nothing either).
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
  `DontImportUserFromWisa`) and Smartschool (`DiscardSmartschoolGroup`,
  `NoSmartschoolSubgroups`) rules, round-tripped through `SettingsStore` via the
  tagged-JSON codecs. The legacy school-marking rules are not among them:
  `MarkAsVirtual` (#277) and `MarkAsOurs` (#286) are the per-school
  `WisaSchoolProfile` flags in the same document, keyed by school id.

Two seams keep the model clean:

- **`SecretProvider` / `SecretRef`.** The legacy config stored the WISA password
  and Smartschool passphrase in cleartext. The port models each secret as a
  `SecretRef` (a stable pointer) on its profile and resolves the value through a
  `SecretProvider`; `toJson` emits only the ref name, so **no credential is ever
  written to the settings blob**. Phase B backs the same seam with Key Vault.
- **Clock injection.** `WorkDateSetting.resolve(now)` takes the current time as
  an argument instead of reading `DateTime.now()` internally, so the model has
  no hidden clock and round-trips deterministically.

### Phase B — centralized Azure SQL persistence *(epic #74, in progress)*

Swap the file-backed defaults (`FilePersonIdResolver`, `FileSettingsStore`,
`FilePasswordQueueStore`) and the `InMemorySecretProvider` for centralized
adapters — Azure SQL for the shared state, Key Vault for the secrets — so the
tool can move to team maintenance. Nothing above the seams changes.

Sliced into per-adapter issues: **#82** foundation, **#83** settings, **#84**
secrets, **#85** PersonId resolver, **#86** password queue, plus **#89** the
concrete ODBC/FFI `SqlConnectionFactory` deferred out of #83.

**#85 — resolve-ahead PersonId seam.** The one place a seam swap *does* ripple
above it: the pure `link()` calls `PersonIdResolver.resolve` synchronously, but
a DB read is async, so the Azure SQL resolver cannot mint lazily on a miss the
way `FilePersonIdResolver` does. Instead it mints **ahead** of the pass — a new
`PreparablePersonIdResolver.prepare(keys)` runs the transactional mint-or-fetch
(insert-if-absent under the natural-key primary key, then read back the winner,
so concurrent operators converge on one id) before any `LinkedAccount` is built,
and `resolve` becomes a total in-memory lookup. `account_linker.naturalKeysFor`
enumerates the exact key set from the same record-building passes `link` uses,
and the State layer drives it through the async `LinkedState.recomputeAsync` /
`fromApplicationAsync` (so `StateApplier.link` now returns a `Future`). A
file/in-memory resolver is not preparable and keeps minting lazily, so the sync
`recompute` path is unchanged.

**Provisioned infrastructure** (subscription *Yvan's Azure*, region
`belgiumcentral`, resource group `accountmanager-rg`):

| Resource | Name | Notes |
|---|---|---|
| Cosmos DB account | `accountmanager-cosmos-arcadia` (`https://accountmanager-cosmos-arcadia.documents.azure.com/`) | SQL API, **serverless**, AAD-only (`disableLocalAuth`); operator holds *Cosmos DB Built-in Data Contributor*. Replaced the SQL server below (#114). |
| Cosmos database | `accountmanager` | Containers: `identity` (pk `/pk` single logical partition, unique key `/naturalKey`), `settings` (pk `/id`), `passwordQueue` (pk `/pk`), plus the materialized-view containers `linkedAccounts` (pk `/pk`), `linkedGroups` (pk `/pk`), `rollups` (pk `/pk`), `decisions` (pk `/pk`), `syncState` (pk `/id`, TTL enabled for the lease), and `snapshots` (pk `/id`). Provisioned by the checked-in idempotent script [`tool/provision-cosmos.ps1`](../tool/provision-cosmos.ps1) (control-plane `az cosmosdb sql …`) — data-plane RBAC cannot create containers. Bootstrap runs an idempotent `ensureContainers` preflight (a metadata read, no create on the provisioned account) over the materialized-view set so a never-stood-up container surfaces at startup rather than as a silent item-write 404 (#150). |
| Key Vault | `accountmanager-kv` (`https://accountmanager-kv.vault.azure.net/`) | RBAC-authorized; operator holds *Key Vault Secrets Officer*. |
| ~~SQL server / database~~ | ~~`accountmanager-sql-arcadia`~~ | **Retired (#114).** Deleted; the ODBC/FFI path is gone. |

Firewall allows Azure services plus the operator's client IP. AAD-only means
every connection carries a per-operator bearer token minted for
`https://database.windows.net/` — no shared database secret exists.

> **Superseded by #114 (Cosmos migration).** The ODBC/FFI decision below is kept
> for history. The shared state moved off Azure SQL onto Cosmos DB — the data is
> document-shaped, Cosmos needs no native driver (pure-Dart HTTPS+JSON,
> cross-platform), has no cold-start pause, and keeps the AAD/no-stored-secret
> property via data-plane RBAC. See "Phase B → Cosmos migration" below.

**Connectivity decision (spike, #82): ODBC Driver 18 via FFI.** Dart has no
production-grade pure-Dart Azure SQL / TDS driver; the community Flutter plugins
(`mssql_connection`, `sql_conn`) are method-channel/mobile-oriented, not pure
Dart. Since the frontend is a **Windows desktop** app (Phase C), the adapters
will use FFI over the Microsoft **ODBC Driver 18 for SQL Server** (`msodbcsql18`,
a standard redistributable bundled with the installer), authenticated with the
AAD token. A REST front (Data API builder / Function) was rejected because it
reintroduces the hosting the epic deliberately avoids. The DB + AAD-only +
token-auth round-trip was **proven end to end** during the spike (connect →
create table → insert → read back `roundtrip-ok` → drop, `SUSER_SNAME()` =
the operator UPN). The `account_state` connection/auth seam (`SqlConnection` /
`SqlConnectionFactory` / `AadTokenProvider`) is in place, and **#89 landed the
concrete `OdbcSqlConnectionFactory`**: `dart:ffi` over `odbc32.dll` →
`msodbcsql18`, authenticated by packing the AAD token into
`SQL_COPT_SS_ACCESS_TOKEN`, with `query` / `execute` / `transaction` / `close`
over the seam. The driver-free decisions (connection string, token packing,
column-type mapping) are factored out and unit-tested offline; the FFI caller
itself is Windows-only and can't be unit-tested headlessly, so it is exercised
by the three adapters' opt-in, write-capable live round-trips (settings,
PersonId resolver, password queue) — now wired to the real driver and run
manually per the live-testing policy, skipped by default when no token is set.

**Key Vault secrets (#84).** `KeyVaultSecretProvider` backs the `SecretProvider`
seam against `accountmanager-kv`, replacing `InMemorySecretProvider` so the WISA
password, Smartschool passphrase, and OAuth/token material leave the settings
blob for good. Unlike the SQL side there is no native driver: the vault
data-plane is plain HTTPS, so the adapter uses `package:http` behind a swappable
`KeyVaultTransport` seam (mirroring `azure_api`'s `GraphTransport`) and AAD auth
goes through a `KeyVaultTokenProvider` scoped to `https://vault.azure.net/`
(operator identity, no stored secret). A `SecretRef.name` maps to a vault secret
name via `KeyVaultSecretProvider.secretNameFor`: vault names allow only
`[0-9a-zA-Z-]` and are matched case-insensitively, so every character outside
`[0-9a-z]` (the config refs' `.`, and any uppercase) is escaped as `-` + two
lowercase hex digits, round-tripping regardless of case folding. The adapter is
fully covered by fake-transport unit tests, and — because it only reads — its
opt-in live check (`KeyVaultLiveConfig`) is a genuine read against the vault, not
a skipped placeholder.

**Shared password queue (#86).** `AzureSqlPasswordQueueStore` backs the
`PasswordQueueStore` seam against the same Azure SQL database, replacing
`FilePasswordQueueStore` so the pending-password queue is shared rather than
sitting on the generating operator's disk — the whole point being that one
operator generates the passwords and another prints the sheets. Both
`PasswordAccountKind`s live in one `dbo.PasswordQueue` table (the `Kind` column
discriminates them, collapsing the legacy `Passwords.json` / `CoPasswords.json`
split), every `PasswordEntry` field a typed column. `load`/`save` follow the
same fresh-connection-per-call, whole-queue-replace-in-one-transaction shape as
the settings store. Unlike the other Phase B tables it holds live plaintext
passwords by design: they are **short-lived**, drained by a post-distribution
`save` of the remaining (usually empty) list, and stored as the password itself
rather than a Key Vault `SecretRef` because a one-shot distribution secret has no
identity to resolve later. Covered by seam-fake unit tests; its write-capable
live round-trip stays skipped until #89 (manual/opt-in per the live-testing
policy, never in the read-only CI set).

### Phase B → Cosmos migration (#114, epic #112)

The multi-operator re-evaluation (epic #112) moved the shared state off Azure SQL
onto **Cosmos DB (serverless) + Blob**. #114 stands up the account/containers and
ports the three existing seams, retiring the SQL/ODBC layer:

- **Client seam.** A pure-Dart data-plane client (`account_state/lib/src/cosmos/`)
  replaces `SqlConnection`/`SqlConnectionFactory` and the whole `sql/odbc/*`
  FFI layer. `CosmosClient` (point read / create / upsert / delete / paged query)
  runs over a swappable `CosmosTransport` (mirroring `KeyVaultTransport`), AAD-
  authenticated with a per-request bearer token for `https://cosmos.azure.com`
  in Cosmos's `type=aad&ver=1.0&sig=<token>` header scheme. No `msodbcsql18`, no
  `ffi` dependency.
- **PersonId (the riskiest seam).** `CosmosPersonIdResolver` replaces the SQL
  guarded insert with a **conditional create on the `identity` container**: the
  `/naturalKey` unique key admits only the first create for a key and rejects the
  rest with `409`, so the loser adopts the winner's id — the direct analogue of
  `INSERT … WHERE NOT EXISTS`. The `PreparablePersonIdResolver.prepare(keys)`
  batch-read contract (warm cache, chunked `ARRAY_CONTAINS` query) is preserved,
  and creates fan out under a concurrency bound rather than the old sequential
  per-key round-trips.
- **Stores.** `CosmosSettingsStore` and `CosmosPasswordQueueStore` each persist a
  **single JSON document** (the config; the whole queue), reusing the existing
  `toJson`/`fromJson` codecs — a single-document upsert is atomic, so the
  whole-replace semantics carry over with no transaction.
- **Provisioning.** The database and containers are stood up by the checked-in
  idempotent script [`tool/provision-cosmos.ps1`](../tool/provision-cosmos.ps1) —
  the source of truth for the full nine-container set (partition keys, the
  `identity` `/naturalKey` unique key, and the `syncState` TTL). The same script
  also provisions the **Blob Storage** side the cold-snapshot overflow store
  needs (#161): the `Microsoft.Storage` provider registration, the AAD-only
  (`--allow-shared-key-access false`, mirroring Cosmos `disableLocalAuth`)
  `accountmanagerarcadia` account, the `snapshots` overflow container, and —
  optionally, via `-OperatorObjectId` — the operator's *Storage Blob Data
  Contributor* data role. It runs the control-plane `az cosmosdb sql
  database/container create` and `az storage account/container create` commands,
  each guarded by an `exists`/presence check so it is safe to re-run against an
  already-provisioned account, because data-plane RBAC cannot create databases,
  containers, or storage accounts. So the
  launch-time `CREATE TABLE` DDL is gone. Bootstrap runs an idempotent
  `ensureContainers` preflight over the
  materialized-view containers: on the provisioned account it is a cheap metadata
  read that creates nothing, but a genuinely un-provisioned container (or a fresh
  dev/emulator account) is created where the identity may, and otherwise surfaces
  loudly at startup — closing the gap where the never-stood-up `decisions`
  container turned "accept duplicate mail" into a silent item-write 404 (#150).
- **Where the account lives (#370).** `StoreEndpoints` — Cosmos endpoint +
  database, Key Vault URI, Blob endpoint + container, SignalR endpoint + hub —
  resolves in three layers: this machine's
  `%APPDATA%\AccountManager\connection.json`, then `--dart-define`, then the
  compiled defaults, merged **per field**. The file is edited in Instellingen →
  Verbinding, which renders and saves without a loaded settings document: the
  settings document lives behind these very coordinates, so it cannot store them,
  and a wrong endpoint may not lock the operator out of the screen that repairs
  it. A malformed file degrades to the defaults with a visible warning instead of
  failing the launch. Endpoint URIs only — every secret stays in Key Vault behind
  `SecretProvider`, and tokens stay in the AAD broker cache.
- **Live test.** Write-capable round-trip (`cosmos_live_test.dart`), manual/opt-in
  per the live-testing policy — restores or deletes everything it writes, never
  in the read-only CI set. Run via `/live-tests cosmos`.

The cold containers (`snapshots` + Blob, `linkedAccounts`, `decisions`,
`rollups`, `syncState`) are stood up by their own epic-#112 children — the Blob
storage account and its `snapshots` overflow container now by the same
`provision-cosmos.ps1` script (#161).

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
