# Changelog

## 0.1.0 (unreleased)

Initial scaffold of the persistence layer for the Arcadia Account Manager
port (issue #42).

- `FilePersonIdResolver`: a JSON-file-backed implementation of
  `account_core`'s `PersonIdResolver`. Loads a `naturalKey -> PersonId` map
  from disk, mints a UUID for unseen keys, and persists the updated map. Keeps
  UUID minting and I/O out of the linker (OQ-3, INV-20).
