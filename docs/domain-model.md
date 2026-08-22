# Arcadia Account Manager — Domain Model

**Status:** Draft. Will be reviewed before any Dart code is written.
**Companion docs:** [port-plan.md](port-plan.md) · [PROJECT_OVERVIEW.md](../PROJECT_OVERVIEW.md) · the legacy source under [legacy-wpf/](../legacy-wpf/).

## 1. Purpose

This document is the **spec** the Flutter/Dart port implements against. It captures the entities, identifiers, invariants, and operations the app actually depends on — extracted from the legacy WPF code but **not bound to its shape**.

The legacy code is the **behaviour oracle**: when the new code differs from it, we either point at a documented decision here, or we treat the divergence as a bug.

Every divergence from legacy gets a one-line rationale. We don't redesign during the port; we settle the model here first.

## 2. Conventions

- **INV-N** = numbered invariant. Tagged with confidence:
  - **E** = *Enforced* in legacy code (raises / refuses on violation)
  - **I** = *Implicit* in legacy code (assumed, not checked — may already be broken on real data)
  - **D** = *Decision* — a property we want to hold in the new code, not necessarily true today
- **OQ-N** = open question. Must be decided before coding the affected layer.
- **PAIN-N** = a known structural pain point we will fix during the port (see §8).

## 3. Entities

### 3.1 `Person`

The canonical record of a human (student or staff) independent of which systems hold an account for them.

| Field | Type | Notes |
|---|---|---|
| `id` | `PersonId` | Opaque local UUID. Stable across syncs. See OQ-3. |
| `role` | `PersonRole` | Student, Teacher, Director, Maintenance, IT, Support, Other |
| `givenName` | `String` | |
| `surname` | `String` | |
| `preferredName` | `String?` | "Roepnaam" — overrides given name in display contexts |
| `gender` | `Gender` | `Male` / `Female` / `X` (legacy `Transgender`) |
| `birthDate` | `Date?` | |
| `birthPlace` | `String?` | |
| `birthCountry` | `String?` | |
| `address` | `Address?` | See 3.2 |
| `mobilePhone` | `String?` | |
| `homePhone` | `String?` | |
| `nationalId` | `String?` | Rijksregisternummer |

**Why this split:** Legacy [`IAccount`](../legacy-wpf/AccountApi/IAccount.cs) mixes person identity, per-system account state, and bookkeeping. Separating `Person` from per-system records makes the linker's job explicit and lets us test it.

`mail` is **not** on `Person` — it lives on `AzureUser` (3.6). A person doesn't have a mail; their Azure account does.

### 3.2 `Address`

| Field | Type |
|---|---|
| `street` | `String` |
| `houseNumber` | `String` |
| `houseNumberAdd` | `String?` (bus/apartment) |
| `postalCode` | `String` |
| `city` | `String` |
| `country` | `String` |

The Smartschool connector concatenates `street + " " + houseNumber + ("/" + houseNumberAdd)?` into one string ([legacy-wpf/AccountApi/Smartschool/AccountManager.cs:57-59](../legacy-wpf/AccountApi/Smartschool/AccountManager.cs#L57-L59)). That's a connector serialisation concern, not a model concern.

### 3.3 `WisaStudent` (source record)

Immutable. Result of parsing one row of WISA's `SMA*` CSV.

| Field | Type | CSV col |
|---|---|---|
| `wisaId` | `WisaId` | 6 |
| `classGroup` | `String` | 0 |
| `classSubGroup` | `String` | 1 (`"00"` ≡ no subgroups) |
| `name` | `String` | 2 |
| `firstName` | `String` | 3 |
| `preferredName` | `String` | 4 |
| `birthDate` | `Date` | 5 |
| `stemId` | `String` | 7 (stamboeknummer, may be zero-padded) |
| `gender` | `Gender` | 8 (`"M"` → Male, else → Female) |
| `nationalId` | `String` | 9 |
| `birthPlace` | `String` | 10 |
| `nationality` | `String` | 11 |
| `address` | `Address` | 12-16 |
| `classChange` | `Date` | 17 |
| `schoolId` | `int` | set by [`ClassGroupManager.AddSchool`](../legacy-wpf/AccountApi/Wisa/ClassGroupManager.cs) |

### 3.4 `WisaStaff` (source record)

Immutable. Much smaller than `WisaStudent` ([legacy-wpf/AccountApi/Wisa/Staff.cs](../legacy-wpf/AccountApi/Wisa/Staff.cs)).

| Field | Type | Notes |
|---|---|---|
| `code` | `WisaStaffCode` | Primary key in WISA staff scope |
| `wisaId` | `WisaId?` | May be empty |
| `firstName` | `String` | |
| `lastName` | `String` | |

> **OQ-1 (RESOLVED — keep both fields):** `code` and `wisaId` are genuinely
> different identifiers. Verified against a real 194-row WISA staff export: they
> differ in 194/194 records (`wisaId` numeric, `code` an alphabetic
> surname-mnemonic; `wisaId` may also be empty while `code` never is). Each
> bridges a different system — the "AddToSmartschool" staff action writes `code`
> as the Smartschool `AccountID`, while `wisaId` equals Azure's `EmployeeId`.
> The linker matches staff to Smartschool on `code` and to Azure on `wisaId`.
> See `packages/account_linker/README.md` for the data and method.

### 3.5 `SmartschoolAccount` (source record)

| Field | Type | Notes |
|---|---|---|
| `uid` | `String` | Smartschool username |
| `accountId` | `String` | Operator convention: holds WISA's `wisaId` |
| `mail` | `String` | Linking key |
| `role` | `String` | `"Leerling"` / `"Leerkracht"` / `"Directie"` |
| `stemId` | `int` | Stamboeknummer (parsed to int by the connector) |
| `status` | `String` | `"actief"` / `"uitgeschakeld"` / ... |
| `accountType` | `AccountType` | `Student` or `CoAccount1..6` (parents/guardians) |
| `address`, `phones`, `name fields` | … | mirror Smartschool's flat shape |

The flat shape mirrors Smartschool's SOAP contract. It must **not** leak past the connector boundary into the linker.

### 3.6 `AzureUser` (source record)

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Azure object ID |
| `upn` | `String` | UserPrincipalName, primary linking key |
| `employeeId` | `String?` | Equals `WisaStudent.wisaId` or `WisaStaff.wisaId` |
| `displayName` | `String` | |
| `givenName` | `String` | |
| `surname` | `String` | |
| `companyName` | `String?` | School prefix; used to identify former members to remove |
| `department` | `String?` | Staff: a **comma-separated list of school prefixes** (`GBS,SSM`) — every school the teacher is currently active at. Owned by other software: we read it (`contains`, INV-22) and never write it on an existing account (#237); only account *creation* stamps our prefix. Students: the class group. |

### 3.7 `Group` and `Membership` — major redesign

Legacy [`IGroup`](../legacy-wpf/AccountApi/IGroup.cs) is a tree node owning a list of accounts. In Smartschool, accounts genuinely appear in multiple subtrees, which the legacy code handles via "skip if already seen" walks — a workaround for the wrong model.

We model `Group` and `Membership` separately:

```dart
class Group {
  final GroupId id;
  final String name;
  final String description;
  final GroupType type;          // Class | Group
  final bool official;            // true → real class (has students)
  final GroupId? parentId;        // tree edge, nullable for roots
  final String? instituteNumber;
  final int? adminNumber;
  final Origin origin;            // which system this Group came from
}

class Membership {                // first-class many-to-many
  final PersonId personId;
  final GroupId groupId;
  final AccountType accountType;  // Student or CoAccount1..6
  final Origin origin;            // which system witnessed this membership
}
```

This fixes [PAIN-1](#8-pain-points-to-fix-during-the-port). See INV-30, INV-31.

**Naming rule — the Office 365 class group (#228).** A class is addressable in
Office 365 as a **unified** (Microsoft 365) group named `<PREFIX>-<KLAS>`, whose
address is therefore `<PREFIX>-<KLAS>@<studentdomein>` (e.g.
`SSM-2A@student.arcadiascholen.be`), reusing the school prefix and student
domain the action config already carries. `<KLAS>` is the **bare** class name
(`WisaClassGroup.name`), never the sub-grouped `fullName`: **sub-groups get no
group of their own**, so `2F ECO` / `2F MAW` / `2F MOW` / `2F STEMW` all belong
to `SSM-2F`, and the group's membership is the union of their rosters. Bare
class names carry no spaces, so the name is used verbatim as the `mailNickname`
— a name that would not survive as one yields no proposal rather than a mangled
slug. Because `LinkedGroup` is keyed on the `fullName`, the bare name is carried
alongside it as `LinkedGroup.className`, which is also what the Azure side of
the group link matches on after stripping the prefix. Groups are never deleted
automatically; a class that vanished leaves an informational notice.

### 3.8 `Snapshot`

A per-system, **immutable** result of one sync.

```dart
class WisaSnapshot {
  final DateTime fetchedAt;
  final List<WisaStudent> students;
  final List<WisaStaff> staff;
  final List<WisaClassGroup> classGroups;
  final List<WisaSchool> schools;
}
class SmartschoolSnapshot { ... }
class AzureSnapshot {
  final DateTime fetchedAt;
  final String? deltaToken;       // for incremental syncs (Graph /users/delta)
  final List<AzureUser> users;
  final List<AzureGroup> groups;
}
```

See INV-4. The cached "last known good" snapshot lives on disk so the UI renders before the next sync finishes — same as the legacy `LoadLocalContent` flow, but typed.

### 3.9 `LinkedRecord`

Output of the linker. One record per identified person/group.

```dart
class LinkedAccount {
  final LinkedAccountId id;
  final PersonRole role;             // narrows to Student or Staff in practice
  final WisaStudent? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;   // High | Medium (former-member / WISA-only placeholder)
}
class LinkedGroup {
  final Group? wisa;                 // nullable: an orphan may lack a WISA anchor
  final Group? smartschool;
  final AzureGroup? azure;
  final LinkConfidence confidence;
}
class LinkedStaff  { ... }
```

See INV-5, INV-6. The `confidence` field replaces the implicit "alumni" and "placeholder" states that today are encoded in which fields are null. A former member surfaces as an Azure-only record (confidence `Medium`) so the action engine can raise a remove action for it (§7).

`LinkedGroup` is symmetric (#52): all three systems are optional (at least one is always present). WISA class groups seed records first, but a group that vanished from WISA while still present in Smartschool and/or Azure is kept as an orphan (confidence `Medium`) rather than dropped, so the action engine can raise a delete action for it — the group analogue of the Azure-only former-member record above. Only `official` Smartschool groups seed orphans; on the Azure side — which carries no `official`-style signal of its own — an unmatched group is kept only when the name it carries is **shaped like a class** (`^\d+[A-Za-z]+\d*$`: `2F`, `6BW`, `5WW1`), tested on the remainder after the school prefix is stripped (#271). The naming convention `<PREFIX>-<KLAS>` this app writes since #228 *is* that positive signal, which is why this is an allowlist; before #271 it was a denylist of four staff-group suffixes (`-Personeel`, `-Directie`, `-Secretariaat`, `-Leraren`), and since the Azure read is already prefix-scoped that kept every other prefixed group — subject, project and council groups included — as a class orphan.

The linker bundles its output into a `LinkedSnapshot`:

```dart
class LinkedSnapshot {
  final List<LinkedAccount> accounts;
  final List<LinkedStaff>   staff;
  final List<LinkedGroup>   groups;
  final LinkCounts wisa, smartschool, azure;   // total/linked/unlinked per system
  final List<LinkWarning> warnings;            // e.g. ResolveDuplicateMail (INV-23)
}
```

`LinkCounts` mirrors the legacy `LinkedAccounts` counters: a person counts toward a system's `linked` only when present in all three systems, otherwise `unlinked`. `LinkWarning` is a sealed type; its `ResolveDuplicateMail` variant carries the shared `mail` and every colliding Smartschool account (INV-23, PAIN-7).

### 3.10 `Action`

Sealed type hierarchy. One class per legacy action, grouped by family.

```dart
sealed class StudentAction { ... }
class AddStudentToSmartschool extends StudentAction { ... }
class ModifyAzureStudentEmail extends StudentAction { ... }
class MoveToSmartschoolClassGroup extends StudentAction { ... }
// ...

sealed class StaffAction { ... }
sealed class GroupAction { ... }
```

Every action has three operations, with **purity boundaries clearly drawn**:

```dart
bool evaluate(LinkedAccount account);                          // pure
ChangeSet describeChanges(LinkedAccount account);              // pure (for diff UI)
Future<ActionResult> apply(Connectors c, ApplyOptions opts);   // impure
```

See INV-40, INV-41, INV-42. `ApplyOptions` carries `dryRun: bool` (PAIN-3).

### 3.11 `ImportRule`

| Rule | Type | Action kind | Config |
|---|---|---|---|
| `DiscardSmartschoolGroup` | SS | Discard | groupName |
| `NoSmartschoolSubgroups` | SS | Discard | groupName |
| `DontImportClass` | WISA | Discard | className |
| `DontImportUserFromWisa` | WISA | Discard | userCode |
| `ReplaceInstitute` | WISA | Modify | from → to |

Rules are applied **at snapshot construction time** (inside the connector or just after), not at link time. The legacy code interleaves them; we don't.

The legacy school-marking rules `MarkAsVirtual` (WorkDate, schoolCode) and `MarkAsOurs` are **not** ported. Both flagged a `WisaSchool` by its short code, and both flags are the operator's WISA-scholen list in Instellingen instead, keyed by school **id**: `AppSettings.virtualWisaSchoolIds` decides which schools pull with the virtual werkdatum (#277) and `AppSettings.managedWisaSchoolIds` which schools we manage (#286). A settings document that still carries either rule loads; a persisted `MarkAsVirtual` is migrated onto the matching school's `virtual` flag on the way in.

## 4. Identity scheme

| Identifier | Lives on | Format | Linking role |
|---|---|---|---|
| `PersonId` | `Person` | Opaque local UUID | Internal stable key. See OQ-3. |
| `WisaId` | WisaStudent, WisaStaff, AzureUser.employeeId | String | WISA primary; cross-system bridge to Azure |
| `WisaStaffCode` | WisaStaff | String | Staff-scope key; **distinct** from `WisaId` (OQ-1 resolved). Bridges staff to Smartschool (`accountId`) |
| `nationalId` | Person, WisaStudent | String (rijksregisternr) | Identity attribute; **not** used for linking |
| `stemId` | Person/Wisa/Smartschool | String/int | Attribute; not a primary key |
| `upn` | AzureUser | Email-format | Azure primary; also the legacy linker key |
| `mail` | SmartschoolAccount | Email | Legacy linker key; should equal UPN in steady state |
| `smartschoolUid` | SmartschoolAccount | String | Smartschool login key |

**Cross-system equalities the linker depends on:**

- `AzureUser.upn` ≡ `SmartschoolAccount.mail` (when both exist) — **case-insensitive, trimmed** (INV-12)
- `AzureUser.employeeId` ≡ `WisaStudent.wisaId` (or `WisaStaff.wisaId`)
- `SmartschoolAccount.accountId` ≡ `WisaStudent.wisaId` for **students** (a `ModifyAccountID` action enforces this)
- `SmartschoolAccount.accountId` ≡ `WisaStaff.code` for **staff** (the "AddToSmartschool" staff action writes the code, not the wisaId — OQ-1)

## 5. Invariants

### Account / person

- **INV-10 [I]:** Every `WisaStudent` has a non-null, non-empty `wisaId`. *Legacy assumes; CSV may produce empty rows.*
- **INV-11 [I]:** No two `WisaStudent`s share a `wisaId`. *Assumed, not checked.*
- **INV-12 [D]:** `mail` and `upn` are compared **case-insensitively** and trimmed. *Legacy `.Equals()` is case-sensitive — a latent bug we don't preserve.*
- **INV-13 [I]:** Two Smartschool accounts may legitimately share a `mail` only via the co-account mechanism. The legacy linker silently drops one when this happens; see INV-23.

### Linking

- **INV-20 [D]:** `link` is a **pure function**: `(WisaSnapshot, SmartschoolSnapshot, AzureSnapshot) → LinkedSnapshot`. Same input ⇒ same output.
- **INV-21 [D]:** Every WISA student appears in **exactly one** `LinkedAccount`.
- **INV-22 [D]:** Every Azure user with `companyName == schoolPrefix` (students) or `department contains schoolPrefix` (staff) appears in **exactly one** `LinkedAccount`, even after the person has left the school (so the engine can raise a remove action). Both tests have a single implementation, `account_core`'s `studentBelongsToSchool` / `staffBelongsToSchool` (and their union `belongsToSchool`), which the linker, the Azure connector's client-side reads, and the staff-retention rule all call (#279). Blank prefix matches nobody. A connector read narrower than the linker is silently lossy — the linker never gets to ask about a row the read dropped — which is why the rule may not be re-implemented per package.
- **INV-23 [D]:** When two Smartschool accounts collide on `mail`, **both** end up in some `LinkedAccount`, never silently dropped. A `ResolveDuplicateMail` warning action is raised.

### Membership

- **INV-30 [D]:** `Membership` is many-to-many; one person can hold multiple memberships in the same system.
- **INV-31 [D]:** A student has **at most one** *official* class membership per snapshot. `MoveToSmartschoolClassGroup` enforces this when applied.

### Actions

- **INV-40 [D]:** Action `evaluate` is pure (no I/O, no globals, deterministic).
- **INV-41 [D]:** Action `apply` is retry-safe: transient failure does not corrupt linked state.
- **INV-42 [D]:** No action mutates a `Snapshot`. Side effects flow only through connectors. Snapshots are reproduced by re-syncing.

## 6. Operations

### 6.1 `sync(system) → Snapshot`

- **Pre:** Connector configured and reachable.
- **Post:** Returns a fresh snapshot. The previous snapshot is replaced only after success.
- **Notes:**
  - Azure connector uses Graph `$filter`, `$select`, and `/users/delta` from day one. The legacy "download 6000 users to filter ~1000" pattern is replaced (PAIN-2).
  - Raw snapshots are cold storage in the shared datastore (#107): only the sync/drift process reads them, seeding a fresh session instead of re-pulling.
  - **The derived linked view is materialized and persisted, not transient (#112/#115).** Superseding the earlier "derived state stays in RAM" stance: after `link()`, the sync process writes one document per linked account plus school/grade-year/classroom rollups to the shared store, so a passive session renders the reconcile overview cheaply from the store with no pull and no `link()`. Operator decisions live in separate documents and are re-attached on each sync.

### 6.2 `link(wisa, smartschool, azure) → LinkedSnapshot`

- **Pre:** Three snapshots (any may be empty).
- **Post:** `LinkedSnapshot` satisfying INV-20..23. Pure, deterministic.
- The algorithm is structurally the same as legacy [`LinkedAccounts.DoRelink`](../legacy-wpf/AccountManager/State/Linked/LinkedAccounts.cs) but extracted from WPF state and fixed for case-insensitive matching and duplicate-mail.

### 6.3 `evaluate(LinkedSnapshot) → List<Action>`

- **Pre:** A `LinkedSnapshot`.
- **Post:** Per `LinkedAccount`/`LinkedGroup`, the set of applicable actions. Pure.
- Dispatch preserves legacy semantics:
  - If any of `{wisa, smartschool, azure}` is missing on an account → only **add / remove / unregister** actions evaluate.
  - If all three present → only **modify** actions evaluate.

### 6.4 `apply(action, connectors, options) → ActionResult`

- **Pre:** `action.evaluate(target)` was true.
- **Post:** Side effect performed on the target system; logged with `Origin`.
- **Options:** `ApplyOptions {dryRun: bool, ...}`. Dry-run produces the same `ChangeSet` description but performs no writes (PAIN-3).
- **On failure:** action enters `Failed` with the captured error; can be retried.

## 7. Edge cases — keep or fix?

| Case | Legacy behaviour | New behaviour | Rationale |
|---|---|---|---|
| Former member (Azure-only w/ school prefix) | Preserved as Azure-only `LinkedAccount` | **Fix**: surface as Azure-only `LinkedAccount` (`confidence: Medium`); the action engine raises a remove action — we don't keep alumni | Students who leave are deleted, not retained |
| WISA-only student (no SS, no Azure) | Placeholder keyed by `WisaID` | **Keep**; surfaces "add" actions naturally | Drives onboarding |
| Two Smartschool accounts share `mail` | First wins, second lost silently | **Fix**: both retained, raise `ResolveDuplicateMail` warning | INV-23 |
| Case-sensitive mail/UPN comparison | `.Equals()` | **Fix**: case-insensitive + trim | INV-12 — latent bug |
| Smartschool multi-membership | Tree walk + skip-if-seen | **Fix**: first-class `Membership` | PAIN-1 |
| Co-accounts (parents) | Implicit via `AccountType` enum | **Keep enum**; passwords managed separately | Minimal scope expansion |
| Virtual school workdate | Per-rule flag on School | **Keep semantics**, model as `school.virtualUntil: Date?` | Same behaviour, clearer model |
| `ReplaceInstitute` rule | Mutates `ClassGroup` at parse | **Apply at snapshot construction**, record provenance | Auditable |
| QR token generation on save | Called every save | **Keep**; idempotent action `EnsureSmartschoolQRCode` | Same behaviour, named explicitly |

## 8. Pain points to fix during the port

- **PAIN-1: Smartschool multi-membership.** First-class `Membership` with bidirectional indexes (group→people, person→groups). See INV-30.
- **PAIN-2: Azure 6000-user bulk pull.** Connector uses Graph `$filter` + `$select` + `/users/delta` from the start. Probably the single largest perf win. See 6.1.
- **PAIN-3: No dry-run.** Every `apply` takes `ApplyOptions{dryRun}`. The action-detail dialog already shows a diff; dry-run reuses that path.
- **PAIN-4: Linker entangled with WPF state.** Lives in `account_linker` as pure functions. See INV-20, 6.2.
- **PAIN-5: No tests.** Each package ships unit tests. Linker gets property tests (e.g. "every WISA student is in exactly one LinkedAccount"). Connectors get record-and-replay fixture tests.
- **PAIN-6: Case-sensitive email matching.** INV-12. Latent bug carried for years.
- **PAIN-7: Silent duplicate-mail drop.** INV-13, INV-23.

## 9. Open questions (decide before coding)

- **OQ-1 (RESOLVED):** `WisaStaff.code` vs `WisaStaff.wisaId` — **genuinely two IDs.** Real data (194/194 staff differ) shows `code` is an alphabetic surname-mnemonic bridging Smartschool and `wisaId` is the numeric WISA key bridging Azure. Both fields are kept. See §3.4 and `packages/account_linker/README.md`.
- **OQ-2:** `Address` — strictly Belgian-format or free-form per country? Legacy assumes Belgian (street/house/box).
- **OQ-3:** `PersonId` lifecycle — derived (e.g. `wisaId` if present, `upn` otherwise) or freshly minted on first observation and stored in a local persistence layer? Affects the upgrade story when an alumni's only ID changes.
- **OQ-4:** Co-accounts (parents) — first-class `Person` linked via a `ParentOf` relation, or attribute-only as in legacy? Affects the Passwords feature.
- **OQ-5:** Are there actions the operator regularly suppresses on a per-row basis? If yes, model a `SuppressedActions` field on `LinkedAccount`.
- **OQ-6:** Retention policy for old `LinkedSnapshot`s — useful for "what changed since last week?" diffs, but storage cost grows.
- **OQ-7:** Headless mode (run a sync from a script / cron) in addition to the GUI — in scope for v1 or v2?

## 10. What this doc is NOT

- Not a UI design — views are derivative of this model.
- Not the implementation plan — see [port-plan.md](port-plan.md).
- Not a config-schema spec — config keys are documented in [PROJECT_OVERVIEW.md §7](../PROJECT_OVERVIEW.md).
- Not exhaustive on every per-system field. Full per-system schemas will live in each connector package's own docs as they're built.
