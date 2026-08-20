## 0.1.0 (unreleased)

Initial Microsoft Graph connector for Azure AD / Office 365 (issue #22).

- `AzureConnector.sync({deltaToken})` builds an `AzureSnapshot` using Graph
  `$filter`, `$select` and `/users/delta` from day one — no full 6000-user
  bulk pull (PAIN-2).
- Models: `AzureUser`, `AzureGroup` (implement the `account_core` source-record
  interfaces), `AzureSnapshot` with a round-trippable on-disk cache.
- Hand-rolled OAuth2 auth-code-with-PKCE over `package:oauth2`; pluggable
  encrypted `TokenCache` (the Flutter app supplies a `flutter_secure_storage`
  backing; an `InMemoryTokenCache` ships for tests).
- `UserManager`: filtered/$select read, `/users/delta`, and user CRUD
  (`getUser`, `createUser`, `updateUser`, `deleteUser`) mirroring the legacy
  `UserManager.cs` surface.
- Password writes request `User-PasswordProfile.ReadWrite.All` (the least
  privileged permission for the `passwordProfile` property; requires admin
  consent), and a refused write surfaces as
  `AzurePasswordPermissionException` naming the missing permission/role
  instead of a bare `GraphException` (#216).
- `GroupManager`: prefixed group list and membership add/remove, with `$batch`
  coalescing for multi-write membership operations.
- Record-and-replay fixture tests over a swappable Graph transport; opt-in,
  read-only live integration test.
