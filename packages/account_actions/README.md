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

### A notice is context, not an alternative (#329)

The rule the whole alternative mechanism rests on, and the third flag on all
three families:

| Flag | Question | Default |
|---|---|---|
| `alternativeGroup` | Which either/or is this action one **answer** to? | `null` |
| `noticeFor` | Which decision is this informational action **context** for? | `null` |

**Every member of an `alternativeGroup` writes.** An action whose `canApply` is
`false` may never join one: "here is what is wrong, go fix it by hand over
there" and "here is the one thing this app can do about it" are not comparable
answers to a single question, so offering them as radios asks the operator to
choose between a diagnosis and a resolution — and makes every such card
ambiguous about whether a decision is owed at all. Such an action declares
`noticeFor` instead; `collapseAlternatives` lifts it out of the option list and
hands it to the decision it names, which the UI states above its own proposal,
marked `(manueel)`, with no radio and no apply of its own.

`noticeFor` is therefore non-null only where `canApply` is `false`, and never
together with a non-null `alternativeGroup`. `test/group_dispatch_test.dart`
asserts both over the student, staff and group dispatches.

Two group actions carry one: `ClassExistsAsSmartschoolGroup` (#225/#250) and
`CreateInSmartschool` (#244). Both were the pre-selected half of a pair with
`DoNotImportFromWisa` until #329. Being the default did a second job — it kept
the blacklist out of a bulk pass — and that job belongs to `canApplyToAll`,
withheld since #293 and honoured by every bulk affordance since #326. A guard
that holds only while a default holds is not a guard.

The four informational actions that carry **no** `noticeFor`
(`AzureClassGroupMembership`, `DoNotImportFromSmartschool`,
`AzureClassGroupWithoutClass`, `AzureClassGroupNotManageable`) each fire exactly
where no decision can be raised, so the row *is* the notice and there is nothing
for it to be context for.

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
`SetStaffCopyCode`, `ClaimStaffForAzureSchool`. Staff bridge to Smartschool
by `WisaStaff.code` (not `wisaId`) — `AddStaffToSmartschool` and
`UpdateStaffWisaName` write the code into `accountId` (spec §4, OQ-1), while the
numeric `wisaId` becomes the copy-code.

`groupActions(snapshot)` walks the snapshot's class groups, ported from the
legacy `GroupActionParser`. The split is on the WISA/Smartschool **pair** rather
than all three systems; the Office 365 class-group actions added in
#228/#271/#331 (`CreateAzureClassGroup`, `SyncAzureClassGroupMembers`,
`AzureClassGroupNotManageable`, `AzureClassGroupWithoutClass`,
`DeleteAzureClassGroup`) are orthogonal to a class's Smartschool state and ride
alongside **both** branches:

- **Missing from WISA or Smartschool** → the lifecycle-style actions, in legacy
  parser order: `DoNotImportFromWisa` (WISA-only class; adds a `DontImportClass`
  rule), `AddToSmartschool` (WISA-only class **with students**; creates the
  official class in Smartschool), `CreateInSmartschool` (WISA-only class with
  **no** students; informational), and — for an orphan Smartschool class —
  `DeleteSmartschoolClass` (#313; `delClass` on the class code), which since
  #328 is the **whole** of what that row proposes. A WISA-only class
  therefore raises `DoNotImportFromWisa` plus exactly one of `AddToSmartschool` /
  `CreateInSmartschool` — or, when Smartschool already carries the name on a
  group the linker could not adopt (#225), the informational
  `ClassExistsAsSmartschoolGroup` in place of both creates.

  These are never independent to-dos, but they are not all the same relation
  either. A **populated** new class is a genuine either/or: `AddToSmartschool`
  and `DoNotImportFromWisa` share the `classImportAlternative` key, both write,
  and an apply runs only the picked half (#244). An **empty** class and a
  **namesake** class have nothing for this app to create, so
  `DoNotImportFromWisa` is the lone decision under its key — `classImportAlternative`
  and `namesakeClassAlternative` respectively, still distinct so the two
  situations keep separate bulk-apply subsets (#250) — and the informational
  action beside it declares `noticeFor` on that same key and rides along as
  card context (#329). The default of a real either/or is always the
  provisioning half, never the blacklist.

  The **Smartschool leftovers** had a third such key until #328. It went for the
  reason the Office 365 one did (see below): its default half was an
  informational "laat deze klas staan", and the operator performs that by not
  pressing **Toepassen**. What keeps `delClass` — which takes the class, every
  membership and every subgroup with it — out of a bulk pass is
  `canApplyToAll == false` (#293), read by both bulk paths since #326.
  `DoNotImportFromSmartschool` survives as the lone `(manueel)` notice for a
  leftover the delete cannot address (a non-official group, or one naming no
  class code). The reading the default *also* carried — that early in a school
  year the WISA snapshot lags, so a live class can read as a leftover — is a
  fact about the situation rather than a resolution, and is stated on the
  delete's own card (`WISA: kent deze klas (nog) niet — …`).
- **Azure-only, class-shaped** (a group whose class stopped running) →
  `DeleteAzureClassGroup` (#271), and since #327 that is the **whole** of what
  the row proposes. It used to be one radio of a pair whose default half was an
  informational "laat de groep staan"; that half was a no-op — the operator
  performs it by not pressing **Toepassen** — so the card asked them to record a
  non-decision. The delete takes the group's mailbox, Team and files with it, and
  what keeps it out of every bulk pass is `canApplyToAll == false` (#293), read
  by both bulk paths since #326, rather than the polarity of a pair.
  `AzureClassGroupWithoutClass` survives as the lone `(manueel)` notice for a
  stale group the delete cannot address — a record naming no Azure object id,
  or (since #331) a group Exchange Online masters, where the notice states the
  shape and sends the operator there. A prefixed group whose remainder is *not*
  class-shaped (`SSM - GOK`, `SSM-OKAN`) is not orphaned by the linker at all
  and so raises nothing.
- **A class group Graph will not manage** (#331) → the informational
  `AzureClassGroupNotManageable` in place of `SyncAzureClassGroupMembers`. A
  mail-enabled security group or a distribution list is mastered by Exchange
  Online, so every add and every remove is refused: `SSM-1A` in the live tenant
  is one, and its 38 membership changes failed wholesale on every pass until the
  proposal stopped being made. `AzureGroup.canManageMembership` is the whole
  test, read off Graph's `mailEnabled` + `groupTypes` rather than inferred from
  `securityEnabled` + `mail`. The two readings partition a class whose roster
  differs, so exactly one row appears.
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
`UnsupportedError`. `CreateInSmartschool` and `ClassExistsAsSmartschoolGroup`
are the two that declare `noticeFor` (see above), so they are read as context on
the blacklist beside them rather than offered as answers. The two deletes — `DeleteAzureClassGroup` and
`DeleteSmartschoolClass` — carry no record back at all: they set
`ActionResult.removed`, and the State layer drops the record from the owning
snapshot rather than patching it.

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
(the caller computes the sub-group suffix, `Student.ClassName`), a
`resolveClass(name)` tree lookup, and an `isOurClass(name)` predicate. It is
**opt-in**: `studentActions` /
`studentActionsFor` take a `placementFor` callback; without it the dispatch is
exactly as it shipped in #46 (account created but not placed, no class move).
The future State layer builds a `ClassPlacement` per student from the Smartschool
snapshot's memberships and group tree. Both the standalone move and the create
placement guard the target the way legacy `MoveUserToClass` does — only an
**official** class node is a valid destination (the ported `moveUserToClass`
connector leaves that guard to the caller), so an ANS/BNS student whose
"Leerlingen" target is non-official is correctly not moved.

Both also refuse a class that is **not ours** (#333): `isOurClass(name)` answers
from the managed schools' WISA class inventory, so a placement naming a sibling
school's class — or any class our own school does not have — raises no move and
enrols no new account, rather than producing a proposal an operator can apply to
the whole school. The question is asked of WISA, not of the Smartschool tree: at
the September rollover the target class legitimately does not exist in
Smartschool yet, so gating on `resolveClass != null` would suppress the very
moves the action exists for. A class that is ours but missing from Smartschool
still fails loudly at apply time.

## Staff group seat (#374)

Smartschool's `saveUser` seats **every** account it creates in the platform
default group, `Leerlingen`, whatever role the account carries. A staff create
therefore has two unconditional follow-up writes, which legacy
`Action\StaffAccount\AddToSmartschool.Apply` performs and this port had dropped:

```csharp
await GroupManager.AddUserToGroup(smartschool, Root.Find("Leerkrachten"));
await GroupManager.RemoveUserFromGroup(smartschool, Root.Find("Leerlingen"));
```

`AddStaffToSmartschool` takes a third injectable, `StaffPlacement`, carrying the
resolved `Leerkrachten` node and the default group's name (plus its node, when
the snapshot has one). The asymmetry is the API's:
`saveUserToClassesAndGroups` addresses a group by **code**, so the add needs the
resolved node, while `removeUserFromGroup` addresses one by **name** and happens
whether or not our root-scoped pull saw the node. It is **opt-in** on
`staffActions` / `staffActionsFor` — one value for the whole snapshot, not a
per-record callback, because the seat asks nothing about the person. Without it
the create behaves exactly as it did before #374.

Both writes are **best-effort** (INV-41), like the student class placement: the
create is the success criterion, and a failed seat must not fail — and so retry
— a `saveUser` that already landed. Unlike the student placement, though,
*every* way a seat misses produces an `ActionResult.warnings` line, not only a
throw: a mis-placed student is re-caught next pass by
`MoveToSmartschoolClassGroup`, whereas nothing re-examines a staff member's
Smartschool group membership at all, so a missed seat has no safety net and the
operator has to hear about it.

Each write that lands names its group (`ActionResult.joinedGroup` /
`leftGroup`), so the State layer can splice the membership without a re-pull.
That splice is deliberately not the class one: a class seat *replaces* the one
official class Smartschool allows, while these are plain group rows, so the
patch adds one row and drops another and leaves everything else alone.

The group **names** are constants (`smartschoolStaffGroupName`,
`smartschoolDefaultGroupName`), not settings. #374 asked the question and this is
the answer: `Leerkrachten` was already being guessed in several places, and a
fourth configurable name beside `AppSettings.smartschoolRoots` and the Passwords
screen's own `staffGroupName` would add a guess rather than remove one.

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
per-student remedy (`CreateAzureClassGroup` and `DeleteAzureClassGroup` own
those).

When the class row has no remedy either — every group this student's row names
is mastered by Exchange Online (#331) — the diagnosis stands but the instruction
changes: `AzureClassPlacement.unmanagedGroupNames` names those groups, and the
summary sends the operator to Exchange Online instead of to a class card that no
longer offers "werk het ledenbestand bij". Deliberately *every* and not *any*: a
student missing from a group we manage while stuck in one we do not still has a
write waiting on the class that can take it.

## Deferred (documented divergences)

- **`AddToAzureStaffGroup`** / **`AddToStaffGroup`** and the `-Personeel` group
  placement inside `AddStaffToAzure` are **not** ported: they evaluate against
  Office 365 group membership, which `LinkedStaff` does not carry. Same
  membership-aware follow-up.

  The Smartschool half of that sentence used to be here too, and it was wrong
  (#374). `AddStaffToSmartschool`'s `Leerkrachten` / `Leerlingen` writes evaluate
  against nothing at all — they are unconditional post-create plumbing, add to
  one fixed-name group and remove from another — so they were dropped by
  association with the two actions that really do read membership. See
  [Staff group seat](#staff-group-seat-374). That fix is forward-only, and #378
  decided what to do about the accounts mis-seated before it: **a one-off tool**,
  [`packages/smartschool_api/tool/staff_seat_repair.dart`](../smartschool_api/tool/staff_seat_repair.dart),
  not a standing action. A standing action would have to carry Smartschool group
  membership on `LinkedStaff` — the same follow-up above — to keep proposing a
  repair that, after #374, nothing can produce any more. The audit half of that
  tool counted **0** mis-seated accounts on this school's tenant, which is the
  other reason: this create is not bulk-applyable (#293), so it appears never to
  have run in anger before the fix landed.
- **`ChangeEmail`** (legacy) is dead code — not wired into the parser — and is
  intentionally omitted.
- **`SetStaffCopyCode` idempotency fix.** Legacy `SetCopyCode` compares the
  *zero-padded* copy-code against Smartschool's `fax`, but writes back the
  *unpadded* `wisaId` — so a sub-4-digit id makes the action re-trigger forever.
  We write the padded code to both `fax` and the `PINCODE CANON` parameter, so
  the action converges after one apply.
- **Staff gender on create.** Legacy `AddToSmartschool` hard-codes `Female` for
  new staff (WISA staff rows carry no gender); preserved verbatim.
- **No staff `department` *repair* — the list is not ours to rewrite (#237).** A
  staff member's Azure `department` is maintained by other software and holds a
  **comma-separated list of school prefixes** (`GBS,SSM`), one per school the
  teacher is currently active at. We read it — the linker's `contains` test
  (INV-22) is exactly the right question, "is this teacher active at our
  school?" — and nothing here rewrites it. `ModifyStaffAzureSchool` (#233) did,
  and it was destructive: it fired whenever the list did not *start with* our
  prefix, which is every teacher we are not listed first for, and its "repair"
  split on a ` - ` separator a comma list has none of, so `GBS,SSM` was rewritten
  to a bare `SSM` — deleting the sibling school's claim. Removed whole rather
  than narrowed.

  **What we do instead is our own entry, and only ever our own entry.**
  `ClaimStaffForAzureSchool` (#373) *appends* our prefix for a staff member WISA
  places in a school we manage whose list does not name us (`SBE` → `SBE,SSM`),
  and `ReleaseStaffFromAzureSchool` (#349) *strikes* that same entry back out
  when they leave (`GBS,SSM,KAV` → `GBS,KAV`). Both leave every other entry
  verbatim and in order, and both decide "are we in the list" by an exact
  list-item match (`departmentSchools` / `departmentSchoolsExcept`) rather than
  by the substring test the read side uses — read wide, write narrow, so a
  longer school code that merely contains our prefix is never struck and never
  suppresses a claim. `AddStaffToAzure` still writes the bare prefix when it
  **creates** an account, which destroys nothing. What stays forbidden is a
  rewrite: re-ordering, case-folding, de-duplicating, or replacing the list.

  The claim is also what keeps the other #233 problem shrinking without widening
  the Azure bulk read's `startswith(department, …)` `$filter`, which #268 ruled
  cannot be widened: every account it claims is one the fast path finds next
  time, instead of one that depends on the `employeeId` back-fill forever.
- Smartschool `uid` uniqueness for new accounts is the caller's concern (the
  State layer holds the account set); the default builder is deliberately
  simple.

## Testing

Pure `evaluate`/`describeChanges`/dispatch tests need no connectors. The
`apply` tests drive the real connectors backed by recording fake transports, so
a dry run can assert **zero** writes and a real apply can assert the exact call
and the returned mutated record.
