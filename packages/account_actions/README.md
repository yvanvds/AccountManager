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

### `canApply` and `canApplyToAll`

Two independent flags, on all three families:

| Flag | Question | Default |
|---|---|---|
| `canApply` | Can the app write this at all? `false` for an informational action, whose `apply` throws. | `true` |
| `canApplyToAll` | May it be written to **many** records in one pass? (#293) | `false` |

`canApply` is the mechanism, `canApplyToAll` is the sanction, and the sanction
presupposes the mechanism — `canApplyToAll` is never `true` where `canApply` is
`false`.

`canApplyToAll` ports legacy's `AccountAction.canBeAppliedToAll`, which the two
account families carried and granted deliberately, action by action. The line it
draws: **mechanical corrections and provisioning** may go in bulk;
**destructive** actions (delete, unregister, remove, and the blacklists, which
are destructive in effect) and **judgement** actions — the name and address
modifiers, where the operator is meant to look at the record — never do.

It lives on the action rather than in a list of kinds held by the screen: such a
list drifts from what the domain sanctions, and an action added later silently
inherits whatever the list's default happens to be. Declared here, a new action
is withheld until someone decides otherwise.

The group family had no legacy answer to port — the legacy Klassen view offered
no bulk apply at all — so each of its four grants is a decision recorded in the
action's own doc comment. `SyncAzureClassGroupMembers` is the headline one: at
the September rollover every class's Office 365 roster is wrong at once, the
diff is computed per class from the roster already held, and the write is
idempotent with removals limited to our own students.

`test/can_apply_to_all_test.dart` pins the exact granted set per family. Its
classification switches are exhaustive over the sealed families, so adding an
action makes that file fail to compile until the new action is classified.

## Dispatch (§6.3)

`studentActions(snapshot, config)` walks the snapshot's student records and,
per record, applies the legacy `AccountActionParser` rule:

- **Any system missing** → only the lifecycle actions (`AddStudentToAzure`,
  `AddStudentToSmartschool`, `UnregisterStudentFromSmartschool`,
  `DeleteStudentFromSmartschool`, `RemoveStudentFromAzure`) are considered.
- **All three present** → only the modify/sync actions (`ModifyAzure*`,
  `ModifyAccountId`, `ModifySmartschool*`) are considered.

The two sets never coexist for one record, exactly as in legacy.

### Unlocked follow-ups (#230)

Dispatch is a pure function of the record **as it stands**, which cannot express
a chain. Provisioning a brand-new student is one: `AddStudentToSmartschool`
builds its account with the Azure UPN as the `mail`, so it evaluates false until
`AddStudentToAzure` has run, and a WISA-only student is therefore offered exactly
one create even though they need two.

`StudentAction.unlocks` names the action types a write may unlock on the same
target — `AddStudentToAzure.unlocks == {AddStudentToSmartschool}`, everything
else empty. It stays a pure, constant declaration: it says what *may* follow,
never what must, and the follow-up's own `evaluate()` still decides.

Acting on it belongs to the State layer, not here: `StateApplier.applyStudent`
re-reads the follow-up from the **relinked** view's own dispatch and runs it, so
the operator's one apply provisions the student end to end. It must be the
relinked record and never a projection — `createPrincipalName` resolves a UPN
collision by suffixing, so the UPN that landed can differ from the one
`describeChanges()` projected, and the Smartschool account would carry the wrong
`mail`.

`GroupAction.unlocks` is the same mechanism for the group family (#245), not a
second one: `CreateAzureClassGroup.unlocks == {SyncAzureClassGroupMembers}`,
because Graph creates a group **empty** — the roster is a separate write — so
creating `SSM-2F` used to leave a class group with nobody in it until the
operator clicked again. `StateApplier.applyGroup` chains it against the relinked
record, which is the only place the id Graph just minted exists. The walk skips
an informational follow-up, so a `canApply == false` action is never applied.

`StaffAction.unlocks` completes the set (#240): the staff family has the very
same two-pass shape as the student one — `AddStaffToSmartschool` builds its
account with the Azure UPN as the `mail` — so
`AddStaffToAzure.unlocks == {AddStaffToSmartschool}` and
`StateApplier.applyStaff` chains it exactly as `applyStudent` does. The applier
runs **one** walk for all three families, parameterized by the typed dispatch it
reads and the target identity; the bounds are therefore identical everywhere:
nothing chains off a dry run or a failed write, each action type runs at most
once per chain, an informational action is never run, and a failed link stops
the chain.

`staffActions(snapshot, config)` does the same over the snapshot's staff
records. The legacy staff parser writes the modify branch as `if (OK)` rather
than `else`, but sets `OK = false` inside the missing branch, so the two
branches are mutually exclusive just like the student parser. The staff
lifecycle set is `AddStaffToAzure`, `AddStaffToSmartschool`,
`RemoveStaffFromSmartschool`, `DontImportStaffFromWisa`, `RemoveStaffFromAzure`;
the modify set is `UpdateStaffWisaName`, `ModifySmartschoolStaffEmail`,
`SetStaffCopyCode`. Staff bridge to Smartschool
by `WisaStaff.code` (not `wisaId`) — `AddStaffToSmartschool` and
`UpdateStaffWisaName` write the code into `accountId` (spec §4, OQ-1), while the
numeric `wisaId` becomes the copy-code.

`groupActions(snapshot)` walks the snapshot's class groups, ported from the
legacy `GroupActionParser`. The split is on the WISA/Smartschool **pair** rather
than all three systems; the Office 365 class-group actions added in #228/#271
(`CreateAzureClassGroup`, `SyncAzureClassGroupMembers`,
`AzureClassGroupWithoutClass`, `DeleteAzureClassGroup`) are orthogonal to a
class's Smartschool state and ride alongside **both** branches:

- **Missing from WISA or Smartschool** → the lifecycle-style actions, in legacy
  parser order: `DoNotImportFromWisa` (WISA-only class; adds a `DontImportClass`
  rule), `AddToSmartschool` (WISA-only class **with students**; creates the
  official class in Smartschool), `CreateInSmartschool` (WISA-only class with
  **no** students; informational), and `DoNotImportFromSmartschool` (orphan
  Smartschool class; informational). A WISA-only class therefore raises
  `DoNotImportFromWisa` plus exactly one of `AddToSmartschool` /
  `CreateInSmartschool` — or, when Smartschool already carries the name on a
  group the linker could not adopt (#225), the informational
  `ClassExistsAsSmartschoolGroup` in place of both creates.

  These are never independent to-dos: `DoNotImportFromWisa` shares an
  `alternativeGroup` key with the reading it contradicts, so the pending list
  renders one either/or and an apply runs only the picked half. The key is
  `classImportAlternative` for a genuinely new class (#244) and
  `namesakeClassAlternative` for one Smartschool already has (#250), which keeps
  the two situations in separate bulk-apply subsets. The default is always the
  provisioning/diagnosis half, never the blacklist.
- **Azure-only, class-shaped** (a group whose class stopped running) → the
  `staleClassGroupAlternative` pair of #271: the informational
  `AzureClassGroupWithoutClass` (leave it standing) and the applyable
  `DeleteAzureClassGroup`. The notice is the default, so a bulk apply over stale
  groups writes nothing and a delete — which takes the group's mailbox, Team and
  files with it — is only ever the pick an operator made on that one row. A
  prefixed group whose remainder is *not* class-shaped (`SSM - GOK`,
  `SSM-OKAN`) is not orphaned by the linker at all and so raises nothing.
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

## Office 365 class placement (#245)

`AzureClassGroupMembership` is the Azure counterpart of
`MoveToSmartschoolClassGroup`: it reports, **on the student's own account**, that
they are missing from their class's `<PREFIX>-<KLAS>` group, or still sitting in
the group of a class they left — the per-account half of #228, which reported the
roster diff only on the class row. It reads an injected `AzureClassPlacement`
(target class, its group's display name, whether the group exists, whether they
are in it, and which of our class groups they are in but should not be), wired
through the opt-in `azurePlacementFor` callback of `studentActions` /
`studentActionsFor`. Without the callback the dispatch is exactly as it was
before #245.

It is **informational** (`canApply == false`) — the first student action that is.
Class-group membership is a class-level fact with exactly one automated remedy,
`SyncAzureClassGroupMembers`, which rewrites the whole roster in one batched
write; a per-account write would ask Graph to add the same member twice whenever
an "apply all" pass ran both, and would count one unit of work twice. So the
account row diagnoses and names the class, and the class row applies. Both are
derived from the same `AzureClassGroupResolver` indexes in `account_state`, so
they cannot disagree — and a class whose group does not exist yet, or a group
whose class has vanished, is deliberately silent per student: neither has a
per-student remedy (`CreateAzureClassGroup` and the
`AzureClassGroupWithoutClass` / `DeleteAzureClassGroup` pair own those).

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
- **No staff `department` repair — the field is not ours to write (#237).** A
  staff member's Azure `department` is maintained by other software and holds a
  **comma-separated list of school prefixes** (`GBS,SSM`), one per school the
  teacher is currently active at. We read it — the linker's `contains` test
  (INV-22) is exactly the right question, "is this teacher active at our
  school?" — and we never write it on an account that already exists.
  `ModifyStaffAzureSchool` (#233) did, and it was destructive: it fired whenever
  the list did not *start with* our prefix, which is every teacher we are not
  listed first for, and its "repair" split on a ` - ` separator a comma list has
  none of, so `GBS,SSM` was rewritten to a bare `SSM` — deleting the sibling
  school's claim. Removed whole rather than narrowed. `AddStaffToAzure` still
  writes the bare prefix when it **creates** an account, which destroys nothing.
  The two problems #233 was actually aimed at — the bulk read's
  `startswith(department, …)` leg missing staff whose list does not lead with us,
  and a staff member who leaves WISA going invisible instead of raising
  `RemoveStaffFromAzure` — are tracked as their own issues.
- Smartschool `uid` uniqueness for new accounts is the caller's concern (the
  State layer holds the account set); the default builder is deliberately
  simple.

## Testing

Pure `evaluate`/`describeChanges`/dispatch tests need no connectors. The
`apply` tests drive the real connectors backed by recording fake transports, so
a dry run can assert **zero** writes and a real apply can assert the exact call
and the returned mutated record.
