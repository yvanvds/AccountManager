# Changelog

## 0.1.0 (unreleased)

Initial WISA SOAP connector for the Arcadia Account Manager port (issue #20).

- `WisaConnector` — single-instance hand-rolled SOAP client against the
  WISA `GetCSVData` operation.
- Per-system source records: `WisaStudent`, `WisaStaff`, `WisaClassGroup`,
  `WisaSchool` (implement the abstract interfaces from `account_core`).
- `WisaSnapshot` — immutable per-sync result, implements
  `account_core.Snapshot`.
- Import rules applied at snapshot construction:
  `ReplaceInstitute`, `DontImportClass`, `DontImportUserFromWisa`,
  `MarkAsVirtual`.
- Dual workdate support (real + virtual) for schools marked virtual.
- CSV parser with Belgian date format support and quoted-field handling.
- Pluggable SOAP transport for headless record-and-replay tests.
