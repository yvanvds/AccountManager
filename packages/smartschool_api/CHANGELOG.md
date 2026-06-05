## 0.1.0

- Initial Smartschool SOAP (V3) connector.
- `SmartschoolConnector.sync()` builds a `SmartschoolSnapshot` from the
  group tree (`getAllGroupsAndClasses`) and per-group account contents
  (`getAllAccountsExtended`), preserving co-account slots and emitting one
  membership row per (account, group) so multi-membership survives.
- Account writes: `saveAccount`, `setPassword`, `forcePasswordReset`,
  `updateQrCode` (+ `Roepnaam`). Group/membership/lifecycle writes:
  `saveGroup`, `saveClass`, `deleteClass`, `moveUserToClass`,
  `addUserToGroup`, `removeUserFromGroup`, `deleteUser`,
  `unregisterStudent`, `changeUid`, `changeAccountId`, `setAccountStatus`.
- Import rules `DiscardSmartschoolGroup` and `NoSmartschoolSubgroups`
  applied at snapshot construction.
- Record-and-replay fixture tests; opt-in live integration test.
