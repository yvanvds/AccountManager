# account_core

Canonical domain model for the Arcadia Account Manager port.

- Pure Dart. No Flutter, no I/O, no connector SDKs.
- Defines entities (`Person`, `Address`, `Group`, `Membership`), identity
  value types, enums, the `Password` generator, the `ILog` sink, and the
  `Snapshot` / `LinkedRecord` shapes that the connector and linker
  packages build on.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md).
Legacy reference: [`legacy-wpf/AccountApi/`](../../legacy-wpf/AccountApi/)
(read-only).
