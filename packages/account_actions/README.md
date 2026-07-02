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
the modify set is `UpdateStaffWisaName`, `ModifySmartschoolStaffEmail`,
`SetStaffCopyCode`. Staff bridge to Smartschool by `WisaStaff.code` (not
`wisaId`) — `AddStaffToSmartschool` and `UpdateStaffWisaName` write the code
into `accountId` (spec §4, OQ-1), while the numeric `wisaId` becomes the
copy-code.

`groupActions(snapshot)` walks the snapshot's class groups, ported from the
legacy `GroupActionParser`. The split is on the WISA/Smartschool **pair** rather
than all three systems (there is no Azure group action):

- **Missing from WISA or Smartschool** → the lifecycle-style actions:
  `DoNotImportFromWisa` (WISA-only class; adds a `DontImportClass` rule) and
  `DoNotImportFromSmartschool` (orphan Smartschool class; informational).
- **Present in both** → only `ModifySmartschoolData` (sync institute number and
  description down from WISA).

A group action returns its mutated record through `ActionResult.group` (a
`Group`), not `ActionResult.smartschool` (a `SmartschoolAccount`). It takes no
config — the shippable group actions derive everything from the WISA/Smartschool
pair. `DoNotImportFromWisa`, like the staff `DontImportFromWisa`, writes nothing
and returns a `WisaImportRule` via `ActionResult.wisaRule`.
`DoNotImportFromSmartschool` is **informational** (`canApply == false`, legacy
`CanBeApplied == false`): it surfaces a diagnosis and its `apply` throws
`UnsupportedError`.

## Configuration

`StudentActionConfig` injects the values legacy hard-coded: `schoolPrefix`, the
base `azureDomain` and derived `studentDomain`, a password provider for created
accounts, and a Smartschool `uid` builder. `StaffActionConfig` is the same
minus `studentDomain` — staff live on the base `azureDomain`. The group family
needs no config.

## Deferred (documented divergences)

- **`MoveToSmartschoolClassGroup`** and the class-group placement inside
  `AddStudentToSmartschool` are **not** ported here: they need the Smartschool
  group tree / a student's current class membership, which the `LinkedAccount`
  record does not carry. They belong with a `Membership`-aware input (follow-up).
- **`AddToAzureStaffGroup`** / **`AddToStaffGroup`** and the `-Personeel` /
  `Leerkrachten` group placements inside `AddStaffToAzure` /
  `AddStaffToSmartschool` are **not** ported: they evaluate against Office 365 /
  Smartschool group membership, which `LinkedStaff` does not carry. Same
  membership-aware follow-up.
- **Group `AddToSmartschool`** / **`CreateInSmartschool`** are **not** ported:
  both branch on the WISA class's `ContainsStudents()`, and `AddToSmartschool`
  additionally needs the Smartschool group tree to resolve a parent
  (`GetLogicalParent`) — neither is carried by the canonical `LinkedGroup`
  (`Group`), the same membership/tree gap as the student/staff placements above.
  Tracked in the group follow-up.
- **Group Untis-drift detection.** Legacy `ModifySmartschoolData` also syncs the
  Untis id, but the canonical `Group` drops `untis`, so drift on *Untis alone*
  can't trigger the action. When it *does* fire (institute number / description
  drift), the `saveClass` write still sets `untis = name` — legacy's own
  remediation target — so Untis converges. Full detection waits on a `Group.untis`
  field (group follow-up).
- **`ChangeEmail`** (legacy) is dead code — not wired into the parser — and is
  intentionally omitted.
- **`SetStaffCopyCode` idempotency fix.** Legacy `SetCopyCode` compares the
  *zero-padded* copy-code against Smartschool's `fax`, but writes back the
  *unpadded* `wisaId` — so a sub-4-digit id makes the action re-trigger forever.
  We write the padded code to both `fax` and the `PINCODE CANON` parameter, so
  the action converges after one apply.
- **Staff gender on create.** Legacy `AddToSmartschool` hard-codes `Female` for
  new staff (WISA staff rows carry no gender); preserved verbatim.
- Smartschool `uid` uniqueness for new accounts is the caller's concern (the
  State layer holds the account set); the default builder is deliberately
  simple.

## Testing

Pure `evaluate`/`describeChanges`/dispatch tests need no connectors. The
`apply` tests drive the real connectors backed by recording fake transports, so
a dry run can assert **zero** writes and a real apply can assert the exact call
and the returned mutated record.
