# Changelog

## 0.1.0 (unreleased)

Initial scaffold of the canonical domain model for the Arcadia Account
Manager port (issue #19).

- Identity value types: `PersonId`, `WisaId`, `WisaStaffCode`, `GroupId`,
  `LinkedAccountId`.
- Enums: `PersonRole`, `Gender`, `GroupType`, `AccountType`, `AccountState`,
  `ConnectionState`, `Origin`, `Rule`, `RuleType`, `RuleAction`,
  `LinkConfidence`.
- Entities: `Person`, `Address`, `Group`, `Membership` (with JSON
  round-trip).
- Interfaces: `Snapshot`, `WisaStudent`, `WisaStaff`, `SmartschoolAccount`,
  `AzureUser`, `AzureGroup` — to be implemented by connector packages.
- `LinkedAccount`, `LinkedStaff`, `LinkedGroup` shapes for the linker
  (Phase 2).
- `PersonIdResolver` interface (issue #42): maps a natural key to a stable
  `PersonId`. The linker depends on this interface only; the file-backed
  implementation lives in `account_store` (keeps `link()` pure — OQ-3,
  INV-20).
- `Password` generator ported faithfully from `legacy-wpf/AccountApi/Password.cs`.
- `ILog` sink interface.
