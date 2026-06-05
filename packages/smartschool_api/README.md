# smartschool_api

Smartschool SOAP (V3) connector for the Arcadia Account Manager port.

Reads the group tree and student/staff/co-account records into an immutable
`SmartschoolSnapshot`, and performs the account, password, group,
membership, and lifecycle writes the legacy action set depends on. Pure
Dart, headless-testable (no Flutter, no UI coupling).

## SOAP approach

Smartschool speaks **RPC/encoded SOAP 1.1** (see
[`legacy-wpf/AccountApi/Web References/SS/V3.wsdl`](../../legacy-wpf/AccountApi/Web%20References/SS/V3.wsdl)),
with the operation namespace baked to the tenant URL
(`https://<site>.smartschool.be/Webservices/V3`). Every call authenticates
with a single *accesscode* passphrase (not a username/password pair).

This connector hand-rolls the SOAP envelopes against the WSDL rather than
relying on Dart WSDL code generation. Unlike WISA's single
`GetCSVData` operation, Smartschool exposes ~15 distinct operations with
three response shapes:

- `getAllGroupsAndClasses` → base64-encoded UTF-8 **XML** group tree;
- `getAllAccountsExtended` → **JSON** array of account records (or the bare
  int code `19` when a group has no direct accounts);
- writes (`saveUser`, `savePassword`, …) → a bare **int** result (`0` =
  success; any other value is an error code translated via
  `returnJsonErrorCodes`).

## Public surface

- `SmartschoolConnector.fromParts(site, accessCode)` — one instance per
  tenant per app run.
- `SmartschoolConnector.sync({rules}) -> SmartschoolSnapshot`.
- `SmartschoolSnapshot` — immutable: `groups` (flattened `core.Group`
  tree), `accounts` (`SmartschoolAccount`, co-account slots preserved,
  disabled accounts filtered), `memberships` (`SmartschoolMembership`, one
  row per (account, group) — multi-membership is **not** deduplicated,
  PAIN-1).
- Account writes: `saveAccount`, `setPassword`, `forcePasswordReset`,
  `updateQrCode`, `saveUserParameter`.
- Group / membership / lifecycle writes: `saveGroup`, `saveClass`,
  `deleteClass`, `moveUserToClass`, `addUserToGroup`, `removeUserFromGroup`,
  `deleteUser`, `unregisterStudent`, `changeUid`, `changeAccountId`,
  `setAccountStatus`.
- `SmartschoolImportRule` sealed hierarchy: `DiscardSmartschoolGroup`,
  `NoSmartschoolSubgroups`. Applied at snapshot construction.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md) §3.5, §3.7,
§3.11. Legacy reference:
[`legacy-wpf/AccountApi/Smartschool/`](../../legacy-wpf/AccountApi/Smartschool/).

## Co-accounts

Smartschool exposes up to six parent/guardian co-account slots per student
record (`*_coaccount1` … `*_coaccount6`). They are **not** separate
accounts — they live on the holder's record and share its UID. The legacy
`LoadFromJSON` discarded these fields; this connector preserves them as
`SmartschoolAccount.coAccounts` (`CoAccountSlot`). Passwords are never
returned by Smartschool, so a slot carries only descriptive fields.

## Live Smartschool access (capture script + integration test)

The manual capture script
([`tool/capture_responses.dart`](tool/capture_responses.dart)) and the
opt-in integration test
([`test/integration/smartschool_live_test.dart`](test/integration/smartschool_live_test.dart))
read two environment variables:

| Variable                 | Purpose                                            |
| ------------------------ | -------------------------------------------------- |
| `SMARTSCHOOL_SITE`       | Tenant subdomain (before `.smartschool.be`)        |
| `SMARTSCHOOL_ACCESSCODE` | Web-services passphrase from the tenant's settings |

Copy [`.smartschool.env.example`](../../.smartschool.env.example) at the
repo root to `.smartschool.env` (gitignored) and fill in the real values.
When `SMARTSCHOOL_ACCESSCODE` is empty the integration test self-skips, so
`dart test` stays offline by default. The live test is **read-only** (sync
only) per the project's live-testing policy.

> **Credential caveat.** Smartschool does **not** offer a read-only API
> tier: the single `SMARTSCHOOL_ACCESSCODE` passphrase is the same
> credential used for writes (create user, set password, …). So unlike the
> Azure connector — whose CI credential is read-only at the directory level —
> the read-only stance here is enforced **client-side** (the test calls only
> `sync()`), which is weaker than a credential-level guarantee. This is the
> deliberate, accepted trade-off the live-testing policy flags; it matches how
> the equally-capable `WISA_*` credential is used in CI. Write coverage stays
> in offline unit tests against recorded fixtures, never live.

### Capture script

Run from anywhere inside the repo, after exporting the env vars:

```sh
dart run packages/smartschool_api/tool/capture_responses.dart
```

The script dumps raw SOAP XML (accesscode redacted) + decoded payloads
under `packages/smartschool_api/captures/<timestamp>/` (gitignored,
local-only). Use it to refresh the record-and-replay test fixtures from
real data.
