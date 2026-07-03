# Changelog

## 0.1.0 (unreleased)

Initial scaffold of the Layer-5 orchestration package for the Arcadia Account
Manager port (issue #69). Persistence **seams** only — no orchestration logic.

- `SettingsStore` interface with `InMemorySettingsStore` and
  `FileSettingsStore`, over the `AppSettings` config model (school prefix,
  debug flag, and the per-connector import-rule sets). Import-rule JSON codecs
  keep serialization out of the pure connector rule types.
- `PasswordQueueStore` interface with `InMemoryPasswordQueueStore` and
  `FilePasswordQueueStore`, over the `PasswordEntry` model — the port's
  counterpart of the legacy `PasswordManager`.
- Re-exports `account_core`'s `PersonIdResolver` and `account_store`'s
  `FilePersonIdResolver` as the identity seam and its default, so the whole
  persistence surface is available from one import.
