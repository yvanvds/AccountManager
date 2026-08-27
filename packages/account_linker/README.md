# account_linker

Pure, deterministic cross-system linker for the Arcadia Account Manager port.
Exposes a single function:

```dart
LinkedSnapshot link(
  WisaSnapshot wisa,
  SmartschoolSnapshot smartschool,
  AzureSnapshot azure,
  PersonIdResolver resolver, {
  required String schoolPrefix,
});
```

It reconciles the three connector snapshots into one record per person —
`LinkedAccount` for students, `LinkedStaff` for staff — plus per-system counts
and any non-fatal warnings. The function is a pure function of its inputs and
the `resolver` state (INV-20): all impurity (minting/persisting the stable
`PersonId`) is delegated to the injected `PersonIdResolver`, so `link` itself
does no I/O. It is the WPF-free, test-covered port of legacy
`LinkedAccounts.DoRelink` + `LinkedStaffMembers.DoRelink`.

## Linking keys

Students and staff are split out of Smartschool's single flat account list by
`SmartschoolAccount.role`: `teacher`/`director` ⇒ staff, everything else ⇒
student (`accountType` is always `student` for a primary record, so it cannot
discriminate). The two populations are linked by **different** Smartschool
bridges.

| Pair | Student bridge | Staff bridge |
|---|---|---|
| Smartschool ↔ WISA | `accountId` ≡ `WisaStudent.wisaId` | `accountId` ≡ **`WisaStaff.code`** |
| Azure ↔ WISA | `employeeId` ≡ `WisaStudent.wisaId` | `employeeId` ≡ `WisaStaff.wisaId` |
| Smartschool ↔ Azure | `mail` ≡ `upn` | `mail` ≡ `upn` |

All comparisons are trimmed and case-insensitive (INV-12).

**`employeeId` is not unique in the tenant** (INV-26, #360). It is the strongest
bridge there is, but the live tenant holds pairs of Azure accounts answering to
one WISA id — two runs of this app made them months apart, under different UPN
normalisations. So the Azure bridge *picks* rather than links: the extra accounts
land on `LinkedAccount.azureDuplicates` / `LinkedStaff.azureDuplicates` (with
`azureCandidates` giving the whole set, adopted first), and every colliding id
raises a `DuplicateAzureEmployeeId` warning. They are deliberately **not** kept
as Azure orphans — an orphan reads as a departed student and draws a delete on
an account that may be the one holding the mailbox. Resolving the pair is the
operator's job; the linker only reports it.

Azure "orphans" — users present only in Azure, kept so the action engine can
raise a removal — are split per INV-22: a student carries `companyName ==
schoolPrefix`; a staff member carries a `department` that **contains** the
prefix.

The two halves are **not** mutually exclusive in the tenant, and one account can
satisfy both — `companyName` says which *school* an account belongs to, never
what its holder is (#358). So the two passes could each keep the same Azure user:
a teacher stamped with the student `companyName` became a `LinkedStaff` *and* an
Azure-only `LinkedAccount`, and the app then proposed deleting their Office 365
account. **One Azure object id belongs to at most one linked record** (INV-27,
#386): the disputed account goes to the stronger claim — a record anchored by a
WISA row or a Smartschool account beats one that exists only because of the stamp
under dispute, and between two unanchored records staff wins — and an
`AzureAccountClaimedTwice` warning names it either way.

Both tests live in `account_core` (`studentBelongsToSchool` /
`staffBelongsToSchool`, and their union `belongsToSchool`) rather than here
(#279). The Azure connector's client-side reads must apply the identical rule:
a read *wider* than the linker is merely wasteful, but a read *narrower* than
the linker is silently lossy — the linker never gets to ask about a row the
read already dropped.

## OQ-1 — `WisaStaff.code` vs `WisaStaff.wisaId` (RESOLVED)

> **Question:** Are a staff member's `code` and `wisaId` ever genuinely
> different identifiers, or always the same value? If always equal we could
> collapse them to one field.

**Finding: they are genuinely distinct — keep both fields.**

Inspected against a real production WISA staff export (194 staff members, the
gitignored `artifacts/wisaStaff.json` redacted into
`packages/wisa_api/test/fixtures/sma_sync_per.csv`):

- `code == wisaId` in **0 / 194** records; they differ in **all** of them.
- `wisaId` is purely numeric in 194 / 194 (e.g. `493`, `426`, `309`).
- `code` is a short alphabetic surname-mnemonic in 184 / 194 (e.g. `ARNAU`,
  `BEECK`, `BENSC`); the remainder add a disambiguating digit on collision.

The two identifiers are not interchangeable and each bridges a different
system: `code` is what the staff "AddToSmartschool" action writes as the
Smartschool internal number (so it bridges Smartschool), while `wisaId` is the
numeric WISA primary key that equals Azure's `employeeId` (so it bridges
Azure). `wisaId` may additionally be empty for some staff, whereas `code` is
always present — another reason they cannot collapse.

Consequence for the linker: staff match Smartschool on `code` and Azure on
`wisaId`. A staff record reaches `high` confidence only when all three systems
are present **and** `upn == mail`, `accountId == code`, and `employeeId ==
wisaId` all agree; anything weaker is `medium`.

See `docs/domain-model.md` §3.4, §4, and §9 (OQ-1).
