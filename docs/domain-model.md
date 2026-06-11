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

> **OQ-1:** Are `code` and `wisaId` ever genuinely different identifiers, or always the same value? The linker uses `wisaId` to match Azure (`EmployeeId`), but the "AddToSmartschool" staff action uses `code` as Smartschool `AccountID`. If they're always equal in real data, we collapse to one field.

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
| `department` | `String?` | Holds school prefix for staff |

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
class LinkedGroup { ... }
class LinkedStaff  { ... }
```

See INV-5, INV-6. The `confidence` field replaces the implicit "alumni" and "placeholder" states that today are encoded in which fields are null. A former member surfaces as an Azure-only record (confidence `Medium`) so the action engine can raise a remove action for it (§7).

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
| `MarkAsVirtual` | WISA | WorkDate | schoolCode |

Rules are applied **at snapshot construction time** (inside the connector or just after), not at link time. The legacy code interleaves them; we don't.

## 4. Identity scheme

| Identifier | Lives on | Format | Linking role |
|---|---|---|---|
| `PersonId` | `Person` | Opaque local UUID | Internal stable key. See OQ-3. |
| `WisaId` | WisaStudent, WisaStaff, AzureUser.employeeId | String | WISA primary; cross-system bridge to Azure |
| `WisaStaffCode` | WisaStaff | String | Staff-scope key; possibly equal to `WisaId` (OQ-1) |
| `nationalId` | Person, WisaStudent | String (rijksregisternr) | Identity attribute; **not** used for linking |
| `stemId` | Person/Wisa/Smartschool | String/int | Attribute; not a primary key |
| `upn` | AzureUser | Email-format | Azure primary; also the legacy linker key |
| `mail` | SmartschoolAccount | Email | Legacy linker key; should equal UPN in steady state |
| `smartschoolUid` | SmartschoolAccount | String | Smartschool login key |

**Cross-system equalities the linker depends on:**

- `AzureUser.upn` ≡ `SmartschoolAccount.mail` (when both exist) — **case-insensitive, trimmed** (INV-12)
- `AzureUser.employeeId` ≡ `WisaStudent.wisaId` (or `WisaStaff.wisaId`)
- `SmartschoolAccount.accountId` ≡ `WisaStudent.wisaId` (a `ModifyAccountID` action enforces this)

## 5. Invariants

### Account / person

- **INV-10 [I]:** Every `WisaStudent` has a non-null, non-empty `wisaId`. *Legacy assumes; CSV may produce empty rows.*
- **INV-11 [I]:** No two `WisaStudent`s share a `wisaId`. *Assumed, not checked.*
- **INV-12 [D]:** `mail` and `upn` are compared **case-insensitively** and trimmed. *Legacy `.Equals()` is case-sensitive — a latent bug we don't preserve.*
- **INV-13 [I]:** Two Smartschool accounts may legitimately share a `mail` only via the co-account mechanism. The legacy linker silently drops one when this happens; see INV-23.

### Linking

- **INV-20 [D]:** `link` is a **pure function**: `(WisaSnapshot, SmartschoolSnapshot, AzureSnapshot) → LinkedSnapshot`. Same input ⇒ same output.
- **INV-21 [D]:** Every WISA student appears in **exactly one** `LinkedAccount`.
- **INV-22 [D]:** Every Azure user with `companyName == schoolPrefix` (students) or `department contains schoolPrefix` (staff) appears in **exactly one** `LinkedAccount`, even after the person has left the school (so the engine can raise a remove action).
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
  - Snapshots are cached to disk for offline-first UI render.

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

- **OQ-1:** `WisaStaff.code` vs `WisaStaff.wisaId` — same identifier in different costume, or genuinely two IDs? Inspect real data to decide.
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
