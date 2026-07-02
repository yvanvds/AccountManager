# account_actions

The **action engine** for the Arcadia Account Manager port (spec
`docs/domain-model.md` §3.10, §6.3–6.4). Given a `LinkedSnapshot` from
`account_linker`, it derives the add/remove/modify actions applicable to each
linked record and applies them — with a dry-run path — against the connector
write APIs.

## What ships here

This package currently implements the **student** family and its dispatcher.
Staff and group families are tracked as follow-ups to #46, mirroring how the
linker shipped student/staff/group as separate slices (#43/#44/#45).

## The shape of an action

`StudentAction` is a `sealed` base with one subclass per legacy
`Action\StudentAccount\*` class. Each action is **bound to its target**
`LinkedAccount` at construction (per §6.4's `apply(action, connectors,
options)`), and exposes three operations with a hard purity boundary:

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

## Configuration

`StudentActionConfig` injects the values legacy hard-coded: `schoolPrefix`, the
base `azureDomain` and derived `studentDomain`, a password provider for created
accounts, and a Smartschool `uid` builder.

## Deferred (documented divergences)

- **`MoveToSmartschoolClassGroup`** and the class-group placement inside
  `AddStudentToSmartschool` are **not** ported here: they need the Smartschool
  group tree / a student's current class membership, which the `LinkedAccount`
  record does not carry. They belong with a `Membership`-aware input (follow-up).
- **`ChangeEmail`** (legacy) is dead code — not wired into the parser — and is
  intentionally omitted.
- Smartschool `uid` uniqueness for new accounts is the caller's concern (the
  State layer holds the account set); the default builder is deliberately
  simple.

## Testing

Pure `evaluate`/`describeChanges`/dispatch tests need no connectors. The
`apply` tests drive the real connectors backed by recording fake transports, so
a dry run can assert **zero** writes and a real apply can assert the exact call
and the returned mutated record.
