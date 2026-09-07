# late_arrivals

Late-arrival ("te-laatregistratie") support for the Arcadia Account Manager
port. Pure Dart — no Flutter, no I/O, no network.

At the reception desk a handheld QR scanner reads a student card, the operator
picks a reason, a ticket prints, and a "Te laat" presence is written to
Smartschool in the background (epic
[#399](https://github.com/yvanvds/AccountManager/issues/399)). This package
holds the parts of that flow that are pure logic.

## What is here

### The scan resolver ([#401][401])

The first thing that happens after a scan, and the only thing that happens while
the operator is still waiting.

```dart
final resolver = ScanResolver.fromSmartschool(smartschoolSnapshot);

switch (resolver.resolve(rawScannerInput)) {
  case ScanRegisterable(:final student, :final internalUserId, :final classGroupId):
    // Show the name + class, print the ticket, queue the presence write.
  case ScanIncomplete(:final student, :final blockers):
    // Known student; say which repair is needed and fall back to a manual
    // registration.
  case ScanUnknown(:final code):
    // "Leerling onbekend" — the operator enters the absence in Smartschool.
  case ScanAmbiguous(:final smartschoolUids):
    // Two accounts share this Internnummer; refuse rather than guess.
  case ScanEmpty():
    // Only scanner noise arrived. Stay silent.
}
```

Building the resolver walks the snapshot once; `resolve` is a constant-time
hash lookup, because the desk has a queue and the name has to appear the instant
the scanner beeps. Nothing here touches the network.

### The journal ([#402][402])

An append-only log of registrations, one `.jsonl` file per school day, written
**before** the ticket prints.

```dart
final journal = await LateArrivalJournal.open(store);

for (final record in journal.pending) {
  // Everything a crash left undrained, in order. Hand to the drain worker (#404).
}

final record = await journal.register(
  scan: scanResult,               // the ScanRegisterable above
  scannedAt: DateTime.now(),      // the moment of the scan, not of the write
  reasonLabel: 'Bus te laat',
  reasonIsValid: true,
);
// ...only now print the ticket and free the scanner input.

await journal.markSent(record.id);
await journal.markConfirmed(record.id);   // or markFailed(id, error)
```

Four properties carry it, and each one only shows itself when something goes
wrong:

- **The ordering is the guarantee.** `register` completes only once the line is
  *flushed*, and the ticket prints after. A student who walked off with a ticket
  is therefore always on disk; a line on disk whose ticket never printed is the
  harmless direction, and is the one the app is deliberately biased towards.
- **Append-only, folded on read.** A registration is one self-contained line;
  every status change (`pending` → `sent` → `confirmed` | `failed`) is a smaller
  line naming the same id. Nothing is ever rewritten in place, so a crash can
  only damage the tail — and `open` discards a torn trailing line rather than the
  day. `JournalRecovery` reports what had to be dropped instead of hiding it.
- **Ordering per student is strict.** A presence save *updates* the half-day cell
  rather than appending a row, so a student scanned twice must have the later
  scan applied last, or the desk's correction is silently undone. `pending` and
  `recordsOf(uid)` both answer in scan order, in this session and after a reload.
- **The day files roll off.** A fully drained day past the retention window is
  deleted; a day that still owes Smartschool a write is kept however old it is.

The reason is stored as a **label plus a valid/invalid flag**, not as a reference
into the shared, editable reason list ([#405][405]): a registration must still say
what was chosen after somebody renames or removes the entry.

`JournalStore` is the file seam — pure Dart, no path. `account_manager/`'s
`FileJournalStore` binds it to
`%APPDATA%\AccountManager\late-arrivals\late-arrivals-YYYY-MM-DD.jsonl`, beside
`preferences.json` and the token cache. `InMemoryJournalStore` is what tests bind
and what a build with nowhere to write falls back to.

## Where the data comes from

Settled by the investigation in [#400][400]:

| what | source |
|---|---|
| the scanned code | `SmartschoolAccount.accountId` — the "Internnummer", which holds the student's WISA id by operator convention |
| Smartschool internal user id | `SmartschoolAccount.internalUserId`, parsed from `referenceIdentifier` ([#138][138]). Present for all 1409 accounts in the Aug 2026 full-site capture |
| Presence `classGroupId` | `core.Group.sourceId` of the student's official class, **passed straight through** — the connector's group id *is* the Presence module's `groupID` (`SSM1A` is `298` on both sides) |

Two consequences worth keeping in mind when changing this package:

- **The `SmartschoolSnapshot`, not the materialized view.** `referenceIdentifier`
  is carried by neither `MaterializedAccount` nor the narrow
  `core.SmartschoolAccount` interface. It *is* persisted on the cold snapshot
  every session seeds at launch, which is what the resolver is built from.
- **Never match a class on `adminNumber`.** It is not unique: 124 official
  classes carry 63 distinct values, and `1A` and `1C` share
  `6246 / 125252`. Matching on it would register a late arrival against the
  wrong class. Class *name* is collision-free and is the only sound fallback if
  one is ever needed.

The snapshot is handed to the resolver rather than fetched by it: this is a
pure-Dart workspace member and knows nothing about application state.

## The four outcomes, and why they are four

An operator's remedy differs per outcome, so the resolver refuses to collapse
them:

- `ScanUnknown` — nobody carries this code. Enter the absence by hand.
- `ScanIncomplete` — a *known* student the app cannot address. `ScanBlocker`
  says which of the three reasons it is, and in particular tells
  "class known by name but its Presence id is unknown"
  (`noClassGroupId` — the member-less classes of [#400][400]) apart from
  "no official class at all" (`noOfficialClass`).
- `ScanAmbiguous` — two students share the code; guessing would mark the wrong
  child present.
- `ScanEmpty` — a stray Enter is not an unknown student.

## Tests

```
dart test packages/late_arrivals/test
```

[138]: https://github.com/yvanvds/AccountManager/issues/138
[400]: https://github.com/yvanvds/AccountManager/issues/400
[401]: https://github.com/yvanvds/AccountManager/issues/401
[402]: https://github.com/yvanvds/AccountManager/issues/402
[405]: https://github.com/yvanvds/AccountManager/issues/405
