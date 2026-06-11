# account_store

Persistence layer for the Arcadia Account Manager port.

- Pure Dart plus `dart:io`. No Flutter, no connector SDKs.
- Provides [`FilePersonIdResolver`](lib/src/file_person_id_resolver.dart), a
  file-backed implementation of `account_core`'s `PersonIdResolver`: it maps a
  natural key to a stable `PersonId` (UUID), minting and persisting a fresh
  UUID for any unseen key.

This package exists to quarantine the two things the linker must not contain —
UUID minting (non-determinism) and disk persistence (I/O) — behind the
injected `PersonIdResolver` interface, so `link()` stays a pure function
(decision OQ-3, invariant INV-20).

Spec: [`docs/domain-model.md`](../../docs/domain-model.md).
