# account_actions

The **action engine** for the Arcadia Account Manager port (spec
`docs/domain-model.md` §3.10, §6.3–6.4). Given a `LinkedSnapshot` from
`account_linker`, it derives the add/remove/modify actions applicable to each
linked record and applies them — with a dry-run path — against the connector
write APIs.

## What ships here

This package implements the **student**, **staff**, and **group** families and
their dispatchers, mirroring how the linker shipped student/staff/group as
separate slices (#43/#44/#45). The group family (#54) ships the subset the
`LinkedGroup` model can express; the membership/tree-dependent group actions are
deferred (see **Deferred** below).

## The shape of an action

`StudentAction` (and its sibling `StaffAction`) is a `sealed` base with one
subclass per legacy `Action\StudentAccount\*` / `Action\StaffAccount\*` class.
Each action is **bound to its target** (`LinkedAccount` / `LinkedStaff`) at
construction (per §6.4's `apply(action, connectors, options)`), and exposes
three operations with a hard purity boundary:

| Operation | Purity | Purpose |
|---|---|---|
| `bool evaluate()` | pure (INV-40) | Does this action apply to the bound record? |
| `ChangeSet describeChanges()` | pure (INV-40) | The field-level diff, for the detail dialog. |
| `Future<ActionResult> apply(Connectors, ApplyOptions)` | impure | Perform the write (or, with `dryRun`, don't). |

`apply` is retry-safe (INV-41: a transient failure returns
`ActionOutcome.failed` without corrupting state) and never mutates the bound
record or its snapshot (INV-42: every changed record is a fresh copy).

### The mutated source record

`ActionResult` carries the **new or updated connector record** (`smartschool`
or `azure`), or `removed: true` for a delete. This lets the future State layer
patch its in-memory snapshot and re-run `link()` **without a network re-sync**
(the incremental-refresh constraint from #40).

The staff `DontImportFromWisa` action is the one exception: WISA is read-only,
so it performs no write. Instead it returns a `WisaImportRule` via
`ActionResult.wisaRule` (with `system: Origin.wisa`); the State layer adds the
rule to its import-rule set and re-syncs, which drops the ignored staff record
from the next snapshot.

### Dry run (PAIN-3)

`ApplyOptions(dryRun: true)` makes `apply` produce the same `ChangeSet` and the
same projected record while performing **no** writes. The detail dialog and the
"apply" button share this one path.

## Dispatch (§6.3)

`studentActions(snapshot, config)` walks the snapshot's student records and,
per record, applies the legacy `AccountActionParser` rule:

- **Any system missing** → only the lifecycle actions (`AddStudentToAzure`,
  `AddStudentToSmartschool`, `UnregisterStudentFromSmartschool`,
  `DeleteStudentFromSmartschool`, `RemoveStudentFromAzure`) are considered.
- **All three present** → only the modify/sync actions (`ModifyAzure*`,
  `ModifyAccountId`, `ModifySmartschool*`) are considered.

The two sets never coexist for one record, exactly as in legacy.

`staffActions(snapshot, config)` does the same over the snapshot's staff
records. The legacy staff parser writes the modify branch as `if (OK)` rather
than `else`, but sets `OK = false` inside the missing branch, so the two
branches are mutually exclusive just like the student parser. The staff
lifecycle set is `AddStaffToAzure`, `AddStaffToSmartschool`,
`RemoveStaffFromSmartschool`, `DontImportStaffFromWisa`, `RemoveStaffFromAzure`;
the modify set is `ModifyStaffAzureSchool`, `UpdateStaffWisaName`,
`ModifySmartschoolStaffEmail`, `SetStaffCopyCode`. Staff bridge to Smartschool
by `WisaStaff.code` (not `wisaId`) — `AddStaffToSmartschool` and
`UpdateStaffWisaName` write the code into `accountId` (spec §4, OQ-1), while the
numeric `wisaId` becomes the copy-code.

`groupActions(snapshot)` walks the snapshot's class groups, ported from the
legacy `GroupActionParser`. The split is on the WISA/Smartschool **pair** rather
than all three systems (there is no Azure group action):

- **Missing from WISA or Smartschool** → the lifecycle-style actions, in legacy
  parser order: `DoNotImportFromWisa` (WISA-only class; adds a `DontImportClass`
  rule), `AddToSmartschool` (WISA-only class **with students**; creates the
  official class in Smartschool), `CreateInSmartschool` (WISA-only class with
  **no** students; informational), and `DoNotImportFromSmartschool` (orphan
  Smartschool class; informational). A WISA-only class therefore raises
  `DoNotImportFromWisa` plus exactly one of `AddToSmartschool` /
  `CreateInSmartschool`.
- **Present in both** → only `ModifySmartschoolData` (sync institute number,
  Untis code, and description).

A group action returns its mutated record through `ActionResult.group` (a
`Group`), not `ActionResult.smartschool` (a `SmartschoolAccount`). It takes no
config — the group actions derive everything from the WISA/Smartschool pair plus,
for the two creation actions, an injected `GroupPlacement` (see below).
`DoNotImportFromWisa`, like the staff `DontImportFromWisa`, writes nothing and
returns a `WisaImportRule` via `ActionResult.wisaRule`. `DoNotImportFromSmartschool`
and `CreateInSmartschool` are **informational** (`canApply == false`, legacy
`CanBeApplied == false`): they surface a diagnosis and their `apply` throws
`UnsupportedError`.

### Group placement (#65)

`AddToSmartschool` and `CreateInSmartschool` are **membership-dependent**: both
branch on whether the WISA class currently holds students (legacy
`ContainsStudents()`), a signal a `LinkedGroup` does not carry, and
`AddToSmartschool` also needs the Smartschool group tree to resolve the parent
the new class hangs under (legacy `GetLogicalParent` → `Root.FindByCode`). They
take an injected `GroupPlacement` — the group analogue of `ClassPlacement` —
carrying `containsStudents` and the resolved `parent` group. It is **opt-in**:
`groupActions` / `groupActionsFor` take a `placementFor` callback invoked only
for WISA-only classes; without it the dispatch is exactly as it shipped in #54
(no creation actions). When `AddToSmartschool` cannot resolve a parent it reports
a failure rather than legacy's silent no-op. `AddToSmartschool` seeds the created
class's Untis from the class name (legacy `group.Untis = wisa.Name`) and carries
the institute and admin numbers projected onto the WISA `Group`
(`schoolCode`/`adminCode`).

## Configuration

`StudentActionConfig` injects the values legacy hard-coded: `schoolPrefix`, the
base `azureDomain` and derived `studentDomain`, a password provider for created
accounts, and a Smartschool `uid` builder. `StaffActionConfig` is the same
minus `studentDomain` — staff live on the base `azureDomain`. The group family
needs no config.

## Class placement (#55)

Two student actions are **membership-dependent** — they cannot be expressed as a
pure function of a `LinkedAccount`, because a `LinkedAccount` carries no
membership and no group tree (spec §3.7, PAIN-1, INV-31). They take a second
injectable, `ClassPlacement`, alongside `StudentActionConfig`:

- **`MoveToSmartschoolClassGroup`** (modify branch): fires when the student's
  target class name differs from their current Smartschool class, and moves them
  with `saveUserToClass`. The ANS/BNS adult-education classes are excluded here,
  exactly as legacy `Evaluate` skips them.
- **The placement step inside `AddStudentToSmartschool`** (lifecycle branch):
  after creating the account, best-effort-moves it into its class — the WISA
  `classGroup`, or the "Leerlingen" root for ANS/BNS (legacy `AddToSmartschool`
  chained `MoveToSmartschoolClassGroup.Move`).

`ClassPlacement` carries the student's `currentClass`, their target `className`
(the caller computes the sub-group suffix, `Student.ClassName`), and a
`resolveClass(name)` tree lookup. It is **opt-in**: `studentActions` /
`studentActionsFor` take a `placementFor` callback; without it the dispatch is
exactly as it shipped in #46 (account created but not placed, no class move).
The future State layer builds a `ClassPlacement` per student from the Smartschool
snapshot's memberships and group tree. Both the standalone move and the create
placement guard the target the way legacy `MoveUserToClass` does — only an
**official** class node is a valid destination (the ported `moveUserToClass`
connector leaves that guard to the caller), so an ANS/BNS student whose
"Leerlingen" target is non-official is correctly not moved.

## Deferred (documented divergences)

- **`AddToAzureStaffGroup`** / **`AddToStaffGroup`** and the `-Personeel` /
  `Leerkrachten` group placements inside `AddStaffToAzure` /
  `AddStaffToSmartschool` are **not** ported: they evaluate against Office 365 /
  Smartschool group membership, which `LinkedStaff` does not carry. Same
  membership-aware follow-up.
- **`ChangeEmail`** (legacy) is dead code — not wired into the parser — and is
  intentionally omitted.
- **`SetStaffCopyCode` idempotency fix.** Legacy `SetCopyCode` compares the
  *zero-padded* copy-code against Smartschool's `fax`, but writes back the
  *unpadded* `wisaId` — so a sub-4-digit id makes the action re-trigger forever.
  We write the padded code to both `fax` and the `PINCODE CANON` parameter, so
  the action converges after one apply.
- **Staff gender on create.** Legacy `AddToSmartschool` hard-codes `Female` for
  new staff (WISA staff rows carry no gender); preserved verbatim.
- **`ModifyStaffAzureSchool` is an addition, not a port.** The legacy staff
  family has no `department` repair, so an Azure account adopted by the
  `employeeId` back-fill (#231) never carried our marker and stayed invisible to
  the school-scoped bulk read forever (#233). It fires when `department` does not
  *start with* the school prefix — a missing one included, mirroring what #224
  taught the student `ModifyAzureSchool` about a null `companyName` — and it is
  `startswith`, not the linker's laxer `contains`, because that is the exact
  server-side test `UserManager.filterFor` applies. **Assumed value shape:**
  `<school>` or `<school> - <suffix>` (real data carries a subject suffix,
  `Arcadia - Wiskunde`), so only the leading school segment is replaced and any
  suffix is preserved. Legacy's staff `RemoveFromAzure` renders the field under
  an "Active Schools" header and both linkers test it with `contains`, so it may
  instead enumerate several schools — in which case replacing the head segment
  evicts a sibling school's claim and this needs to become a prepend. Tracked as
  #237.
- Smartschool `uid` uniqueness for new accounts is the caller's concern (the
  State layer holds the account set); the default builder is deliberately
  simple.

## Testing

Pure `evaluate`/`describeChanges`/dispatch tests need no connectors. The
`apply` tests drive the real connectors backed by recording fake transports, so
a dry run can assert **zero** writes and a real apply can assert the exact call
and the returned mutated record.
