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
