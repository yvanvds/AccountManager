# wisa_api

WISA SOAP connector for the Arcadia Account Manager port.

Pulls students, staff, class groups, and schools from a school's WISA
instance and produces immutable `WisaSnapshot`s. Pure Dart, headless-
testable (no Flutter, no UI coupling).

## SOAP approach

The WISA service speaks RPC-encoded SOAP 1.1 (see
[`legacy-wpf/WisaAPIService.wsdl`](../../legacy-wpf/WisaAPIService.wsdl)) and
exposes only three operations — `GetCSVData`, `GetXMLData`, `GetExportData`.
This connector hand-rolls the SOAP envelopes against the WSDL spec rather
than relying on Dart WSDL code generation, which is immature and would have
been more work to vet than to bypass.

The actual data lives in CSV blobs that WISA encodes as base64 inside the
SOAP response. The bulk of this package is therefore CSV parsing plus a
small SOAP envelope builder.

## Public surface

- `WisaConnector(server, port, db, user, password)` — one instance per
  WISA host. Matches legacy single-instance behaviour.
- `WisaConnector.sync(workDate, virtualWorkDate?, rules) -> WisaSnapshot`.
- `WisaConnector.testConnection() -> bool`.
- `WisaSnapshot` — immutable, includes `students`, `staff`, `classGroups`,
  `schools`, `fetchedAt`.
- `WisaImportRule` sealed hierarchy: `ReplaceInstitute`, `DontImportClass`,
  `DontImportUserFromWisa`, `MarkAsVirtual`. Rules are applied at snapshot
  construction, not at link time.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md) §3.3, §3.4,
§3.11. Legacy reference: [`legacy-wpf/AccountApi/Wisa/`](../../legacy-wpf/AccountApi/Wisa/).

## Live WISA access (capture script + integration test)

Two things in this package talk to a real WISA host: the manual capture
script in [`tool/capture_responses.dart`](tool/capture_responses.dart) and
the opt-in integration test at
[`test/integration/wisa_live_test.dart`](test/integration/wisa_live_test.dart).
Both read the same six environment variables:

| Variable         | Purpose                                  |
| ---------------- | ---------------------------------------- |
| `WISA_SERVER`    | Hostname of the WISA SOAP server         |
| `WISA_PORT`      | TCP port (integer)                       |
| `WISA_DATABASE`  | WISA database name                       |
| `WISA_USERNAME`  | API user                                 |
| `WISA_PASSWORD`  | API password                             |
| `WISA_SCHOOL_ID` | Integer ID of the school to capture/test |

Copy [`.wisa.env.example`](../../.wisa.env.example) at the repo root to
`.wisa.env` (gitignored) and fill in the real values. `.wisa.env` itself
is never committed.

When `WISA_USERNAME` is empty the integration test self-skips, so
`dart test` stays offline by default.

### CI

CI reads these as repository secrets in
[`.github/workflows/dart.yml`](../../.github/workflows/dart.yml):

- `test` job — offline `dart analyze` + `dart test`, always runs.
- `live-test` job — runs the integration test using `secrets.WISA_*`.
  Gated to this repository so fork PRs cannot trigger secret access.

Add the secrets at **Settings → Secrets and variables → Actions**, using
the same six names listed above.

### Capture script

Run from anywhere inside the repo, after exporting the env vars:

```sh
dart run packages/wisa_api/tool/capture_responses.dart
```

The script dumps raw SOAP XML + decoded CSV under
`packages/wisa_api/captures/<timestamp>/` (gitignored, local-only) and
prints an issue-#29 verdict for the `SyncKlas` response — i.e. whether
WISA quotes class-group descriptions that contain literal commas.
