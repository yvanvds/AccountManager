# late_arrivals

Late-arrival ("te-laatregistratie") support for the Arcadia Account Manager
port. Pure Dart — no Flutter, no I/O, no network.

At the reception desk a handheld QR scanner reads a student card, the operator
picks a reason, a ticket prints, and a "Te laat" presence is written to
Smartschool in the background (epic
[#399](https://github.com/yvanvds/AccountManager/issues/399)). This package
holds the parts of that flow that are pure logic.

## What is here

The **scan resolver** ([#401][401]) — the first thing that happens after a
scan, and the only thing that happens while the operator is still waiting.

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
