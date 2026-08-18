# Test fixtures

Hand-authored, **synthetic** Smartschool payloads for the record-and-replay
connector tests. No real PII — all names, mails, addresses, and IDs are
invented. Refresh from real data with
[`tool/capture_responses.dart`](../../tool/capture_responses.dart), scrubbing
PII before committing anything derived from a capture.

The fake transport in [`connector_test.dart`](../connector_test.dart) wraps
these into SOAP responses:

- `group_tree.xml` — the decoded `getAllGroupsAndClasses` payload. The fake
  transport base64-encodes it into the `<return>` element, the way the live
  service delivers it. Mirrors the live shape: field values are `<![CDATA[…]]>`,
  subgroups are nested inside a `<children>` wrapper, and titulars are
  `<titu><user><username>…` (see #37 — a flat fixture hid the missing
  `<children>` descent).
- `accounts_<CODE>.json` — the `getAllAccountsExtended` JSON for the group
  with that code. `SCH` has no fixture: the fake returns the int code `19`
  ("no direct accounts").
- `error_codes.json` — the `returnJsonErrorCodes` table.

Scenarios encoded in the fixtures:

- **Multi-membership (PAIN-1):** `jand` is a direct account of both `C1A`
  and `GSPORT` → two membership rows, one deduplicated account record.
- **Disabled filtering:** `olduser` (`Status: uitgeschakeld`) is dropped.
- **Co-account slots:** `saral` has slot 1 (Moeder) populated and slot 3
  (Vader) partial; slot 2 is empty and must be dropped → two slots surfaced.
- **Duplicate mail (INV-13/23):** `miek` and `saral` share
  `shared@school.be`; both survive.
- **Smartschool-internal ids (#138):** accounts carry a `referenceIdentifier`
  (`4069_1001_0` → internal user id `1001`), except `saral`, whose truncated
  `4069` exercises the malformed case — raw value kept, `internalUserId` null.
  Each account's `groups` array carries the numeric group id (`C1A: 101`,
  `C1B: 102`, `GSPORT: 401`), which the sync backfills onto the group records
  by joining on the code. `GSPORT`'s id reaches the snapshot through `jand`'s
  `C1A` payload as well, and `SCH` — which has no account payload at all —
  stays unresolved (`sourceId == null`).
