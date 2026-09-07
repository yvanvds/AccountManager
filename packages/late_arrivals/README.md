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

### The reason list ([#405][405])

What the operator is choosing *between* while the student stands there: an
ordered list of reasons, each a label plus a flag saying whether it counts as a
valid one.

```dart
for (final reason in settings.lateArrivalReasons) {
  // One flat row of buttons, in this order. The invalid ones are marked in
  // place, never split into a second step.
}

// On a press:
final motivation = composeMotivation(now, reason.label);   // "08:14 – Verkeer"
final flag = reason.withoutValidReason;                    // what #404 writes
```

- **The flag belongs to the reason, not to a second click.** Oversleeping is not
  a delayed bus, but asking the operator to say so separately would slow down
  exactly the moment that has to be fast.
- **The list is shared, not per-machine.** It lives in `AppSettings`, the
  document every desk reads, and is edited under *Instellingen → Algemeen*. If
  each desk kept its own, Smartschool would end up holding "bus", "de bus" and
  "vertraging bus" as three different reasons and the data would be worthless
  afterwards. Because the Settings screen publishes every save into
  `LiveSettings`, an edit reaches an open scan tab without a restart.
- **A default list ships** (`defaultLateArrivalReasons`), so the desk works
  before anybody has configured anything — and an emptied list re-adopts it,
  since a desk with no buttons cannot register the student in front of it.
- **Order is the operator's.** `normalizeLateArrivalReasons` trims, drops blanks
  and collapses duplicate spellings case-insensitively (first wins), but never
  reorders or groups the invalid entries away.

### The ticket ([#406][406])

What the student walks away with, as the bytes an Epson TM-m30III turns into
paper.

```dart
final bytes = composeTicketForRecord(record, logo: defaultTicketLogo);
// ...hand to account_manager's LateArrivalPrinter, which opens one socket to
// port 9100 and is done with it.
```

- **A pure function, and that is the design.** The printer lives at a reception
  desk, not on a build agent, so the layout has to be assertable without one.
  Everything that touches a socket is in `account_manager`; everything that
  decides what the paper says is here, and the tests read the byte stream back.
- **Name, class, arrival time, logo — and nothing else.** No reason, no barcode;
  the epic is explicit. The **time is the point**: it is the teacher's evidence
  of *when* the student was at the desk, and the one thing Smartschool cannot
  hold, because its Presence module only knows am/pm half-days. It is therefore
  the largest thing on the ticket, and it is the *scan* time — taken off the
  record the journal already flushed, so a slow printer cannot move it.
- **Raw ESC/POS, never a printer driver.** `escpos.dart` is the vocabulary of
  one ticket, not a printer library: initialise, code page, align, size,
  emphasis, raster, feed, cut. The code page is `WPC1252` and text is encoded to
  match, because on the factory default (PC437) half the Flemish surnames in the
  school come out as different letters.
- **The logo is a bitmap this package carries** (`TicketLogo`), authored as
  ASCII art and scaled — a picture a reviewer can read, in a package that has no
  I/O to open a PNG with. `defaultTicketLogoArt` is a **placeholder** monogram;
  replacing it is editing those rows and nothing else.
- **Everything the hardware might contradict is in one file.**
  `ticket_metrics.dart` holds the paper width, the print width in dots, the feed
  before the cut and the cut variant, with a note on what to check first when
  the printer is finally plugged in.

### The Cosmos mirror ([#403][403])

The journal survives the app dying. It does nothing at all for the *laptop*
dying — and the agreed fallback for that is that a colleague picks the morning up
on her own machine. So every journalled record and every status change is also
copied to the shared Cosmos account epic [#112][112] already keeps the operator
state in.

```dart
final mirror = LateArrivalMirror(store: cosmosMirrorStore, deskId: hostName);
final journal = await LateArrivalJournal.open(store, sink: mirror);

final recovery = await mirror.reconcile(day: today, local: journal.records);
for (final entry in recovery.outstanding) {
  // What the other desk registered and never drained. Show it; pick it up.
}
```

- **It sits behind the journal, never in front of it.** The sink method is
  `void`: the record is already flushed by the time it is called, the ticket
  prints off the journal's future, and a slow or dead Cosmos changes the desk's
  timing by nothing.
- **Failures are retried and never lose the record.** A failed write stays
  queued and backs off; after a few consecutive failures the worker stands down
  and reports itself `degraded`, which is what puts a persistent outage in front
  of the operator instead of in a log file. Nothing is dropped — the next
  registration, `retryNow()`, or the next `reconcile()` picks the queue up.
- **The desk is part of the shared key.** The journal's `<day>-<sequence>` id is
  unique only on the machine that wrote it; a stand-in operator's fresh journal
  mints the same ids. Documents are `<day>|<desk>|<sequence>`, partitioned by
  the school day, so a day's registrations across every desk are one
  single-partition read.
- **No claims, no locks, on purpose.** Two machines draining the same entry is
  accepted: a presence save updates the half-day cell rather than duplicating a
  row, and presences are reviewed afterwards.

`LateArrivalMirrorStore` is the remote seam; `account_state`'s
`CosmosLateArrivalMirrorStore` binds it to the `lateArrivals` container, and
`InMemoryLateArrivalMirrorStore` is what tests bind.

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

[112]: https://github.com/yvanvds/AccountManager/issues/112
[138]: https://github.com/yvanvds/AccountManager/issues/138
[400]: https://github.com/yvanvds/AccountManager/issues/400
[401]: https://github.com/yvanvds/AccountManager/issues/401
[402]: https://github.com/yvanvds/AccountManager/issues/402
[403]: https://github.com/yvanvds/AccountManager/issues/403
[405]: https://github.com/yvanvds/AccountManager/issues/405
[406]: https://github.com/yvanvds/AccountManager/issues/406
