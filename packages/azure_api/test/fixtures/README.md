# azure_api test fixtures

Synthetic Microsoft Graph payloads — no real PII. They drive the
record-and-replay tests via `FakeGraphTransport`, which routes by request path
and `$skiptoken`/`$deltatoken`.

The synthetic school prefix is `GBS`; the verified domain is `school.example`.

| Fixture | Represents | Exercises |
|---|---|---|
| `users_page1.json` | first `/users` page, with `@odata.nextLink` | pagination, `$filter`/`$select` read |
| `users_page2.json` | final `/users` page (staff via `department`) | pagination terminates |
| `users_delta_page1.json` | first `/users/delta` page, with `@odata.nextLink` | delta pagination |
| `users_delta_final.json` | final delta page: in-prefix change, out-of-prefix change, and an `@removed` entry | delta token capture, client-side prefix filter, removals |
| `delta_latest.json` | `$deltatoken=latest` reply (empty value, fresh `@odata.deltaLink`) | priming the first sync's resume token |
| `groups.json` | prefixed `/groups` collection | group list, `startswith(displayName,…)` |
| `group_members_3a.json` | `/groups/{id}/members` collection | member-id loading |
| `user_single.json` | single `/users/{id}` resource | `getUser` |

Capture new fixtures with `tool/capture_responses.dart` (redacts tokens) and
trim them to the minimum the test needs.
