# azure_api

Microsoft Graph connector for the Arcadia Account Manager port. Reads Azure AD
/ Office 365 users and groups into an immutable `AzureSnapshot`, and performs
the user and group-membership writes the action set depends on. Pure Dart — no
Flutter, no UI coupling — so it is headless-testable and reusable from any Dart
frontend.

Spec: [`docs/domain-model.md`](../../docs/domain-model.md) §3.6 (`AzureUser`),
§3.8 (`AzureSnapshot`), §6.1 (sync), §8 (PAIN-2). Legacy reference
(read-only): [`legacy-wpf/AccountApi/Azure/`](../../legacy-wpf/AccountApi/Azure/).

## The PAIN-2 fix

The legacy connector downloads roughly **6000** tenant users to keep the
~1000 that belong to the school. This connector never does that:

- **First / full sync** — a `$filter` + `$select` bulk read scoped to the
  school (`UserManager.load`), so only the school's ~1000 users come down.
  It also primes a delta token (`$deltatoken=latest`) for next time.
- **Incremental sync** — `/users/delta` returns only the users that changed
  since the last token; the connector upserts and removes them on top of the
  previous snapshot.

`$select` is pinned to exactly the fields the port uses: `id`,
`userPrincipalName`, `employeeId`, `displayName`, `givenName`, `surname`,
`companyName`, `department`, `accountEnabled`.

### Delta-token lifetime (#213)

Graph refuses a delta link older than 30 days. Two rules keep that from ever
becoming a dead end:

- **The token on a snapshot is always minted during that snapshot's own sync** —
  from that pass's delta walk, or from `latestDeltaToken()` on a full read. A
  delta walk that ends without an `@odata.deltaLink` yields *no* token rather
  than re-shipping the one it was handed, so a token can never silently stop
  advancing and age out while every sync still reports success. The cost is one
  full read on the next pass; the benefit is that `AzureSnapshot.fetchedAt`
  truthfully dates the token it ships with.
- **A token Graph rejects is not fatal.** `sync` catches the rejection —
  `400 Request_UnsupportedQuery` naming the delta link, and the documented
  `410 Gone` / `resyncRequired` — logs it with the token's age, discards it, and
  falls back to a full read that primes a fresh token. A `400
  Request_UnsupportedQuery` that is *not* about the delta token (a malformed
  query) still throws, so a real bug stays loud instead of degrading into an
  expensive full read on every pass.
- **A recovered failure is never logged as an error.** `GraphClient` logs every
  non-2xx reply, and on its own cannot tell a rejection the caller handles from a
  fatal one — so a pass that fully recovered used to read as a broken one.
  `UserManager.delta` therefore hands the client the failure shape it expects
  (`GraphFailurePredicate`); a match is logged as an ordinary detail beside the
  connector's own explanation, everything else stays an error. Logged URLs also
  have their `$deltatoken` / `$skiptoken` values replaced with `<redacted>` at
  every severity — a resume token is kilobytes of live tenant state, and log
  lines end up pasted into issues. `$deltatoken=latest` is Graph's own sentinel,
  not a secret, and stays readable.

### Server-side filter, and where it falls back

The bulk `$filter` is:

```
companyName eq '<prefix>' or startswith(department,'<prefix>')
```

Students carry the prefix in `companyName`. Staff carry it in `department`,
which other software maintains as a **comma-separated list of every school
prefix the teacher is active at** (`GBS,SSM`) — so our prefix is at the *start*
of the value only when we happen to be listed first.

**The server-side leg cannot be widened** (#268). Graph offers `eq`,
`startswith`, `in` and `ne` on these properties and no `contains` at all;
`endswith` is limited to `mail` / `otherMails` / `userPrincipalName`, and
`$search` tokenizes only `displayName` / `description`. There is simply no OData
query for "our prefix somewhere in the list", and the only alternative is the
full-tenant read PAIN-2 exists to avoid. So the narrow fast path stays, and the
staff it misses are completed by the two legs that are *not* limited to what
OData can ask:

- **the `employeeId` back-fill (#231)** — the designed complement, not an
  accident. Every pass hands the connector the WISA ids it expects accounts for
  and it looks up the ones this `$filter` did not turn up, on the full read and
  the incremental one alike. Since #269 the caller also names the staff ids the
  *previous snapshot* already held for our school (`account_state`'s
  `retainedStaffEmployeeIds`), so an account does not leave the app's view on the
  pass WISA stops listing its owner — which is what lets the engine propose
  `RemoveStaffFromAzure` for someone who left. The id is remembered only while
  the Azure row still names our school in `department`, so it falls out by itself
  once the account is gone.
- **the client-side test** — the delta path always filters in Dart (`/users/delta`
  does not honour these property filters), and so does
  `UserManager.loadClientFiltered`. Neither is bound by OData, so both apply the
  real rule: `companyName` equals the prefix, **or** `department` *contains* it —
  the same test the linker applies (INV-22). Since #279 it is *literally* the
  same: `core.belongsToSchool` in `account_core` is the single definition both
  packages call, because a read narrower than the linker throws rows away before
  the linker can ask about them. Before #268 both inherited the
  server-side `startswith` instead, which silently dropped every delta change to
  a staff member listed second (their stale row survived from the previous
  snapshot, so nothing looked missing) and left `loadClientFiltered` unable to do
  the one thing it exists for.

`UserManager.loadClientFiltered` — `$select` only, filtered client-side — remains
the documented fallback for an installation that needs the bulk read *itself* to
see them, at the cost of a full-tenant read.

Note the field is read-only from here: writing our prefix over the list would
evict a sibling school's claim (#237). Only account creation stamps it.

## Authentication

OAuth2 **auth-code with PKCE** against the Microsoft identity platform, built
on [`package:oauth2`](https://pub.dev/packages/oauth2). This was chosen over
`msal_auth` / `aad_oauth`: those are Flutter platform plugins (native channels,
webviews) that are hard to unit-test headlessly and have uncertain Windows
desktop support. `oauth2` is pure Dart, accepts an injectable `http.Client`
(so the token exchange and refresh are covered by fakes), handles the S256
PKCE challenge internally, and sends no client secret — correct for a
native/desktop **public client**.

Acquisition order mirrors the legacy MSAL flow
(`AcquireTokenSilent` → `AcquireTokenInteractive`):

1. a valid cached token is returned as-is;
2. an expired token is refreshed silently;
3. otherwise an interactive sign-in runs.

The interactive leg is supplied by an `InteractiveAuthorizer` callback — the
package does not open browsers or bind sockets itself. `LoopbackAuthorizer` is
the desktop default (RFC 8252 loopback redirect); the Flutter app injects the
`BrowserLauncher` (`url_launcher` / `Process.start`).

### Delegated permissions

`AzureCredentials.scopes` defaults to the delegated set the connector needs:

- `User.ReadWrite.All`, `Group.ReadWrite.All` — the reads and the account /
  membership writes;
- `User-PasswordProfile.ReadWrite.All` — the password writes (`createUser`'s
  `passwordProfile` and `setPassword`). `User.ReadWrite.All` does **not**
  authorise that property, so without this one a reset comes back
  `403 Authorization_RequestDenied` (#216). It is the least-privileged
  permission for it; the older `Directory.AccessAsUser.All` covers it too but
  hands the app everything the operator can do directory-wide.

All three require **admin consent** on the app registration, and a newly added
permission only reaches a token after re-consent — a cached refresh token keeps
the scope set it was issued for. On top of the permission, a *delegated*
password write also needs the signed-in operator to hold a role allowed to
reset that account: User Administrator for ordinary users, Privileged
Authentication Administrator when the target is itself an administrator.

### Token cache (encrypted at rest)

The serialized credentials hold a **refresh token** and must be encrypted at
rest. The legacy connector used Windows DPAPI (`TokenCacheHelper.cs`). Here the
package defines a `TokenCache` interface and never writes plaintext to disk:

- the Flutter app supplies a `flutter_secure_storage`-backed implementation
  (DPAPI on Windows), **or**
- wraps any `TokenCache` in `EncryptedTokenCache`, which applies an injected
  cipher so the inner store only ever sees ciphertext.

`InMemoryTokenCache` ships for tests and as a safe non-persistent default.

## Public surface

- `AzureConnector(credentials, authProvider, transport?, log?)` —
  `sync({deltaToken, previous})` → `AzureSnapshot`.
- `UserManager` — `load`, `loadClientFiltered`, `delta`, `latestDeltaToken`,
  `getUser`, `userExists`, `createUser`, `updateUser`, `deleteUser`,
  `createPrincipalName`.
- `GroupManager` — `listGroups`, `loadMemberIds`, `addMember`, `removeMember`,
  and `$batch`-coalesced `addMembers` / `removeMembers`.
- `GraphClient` / `GraphTransport` — authenticated, paging-aware Graph access
  over a swappable transport.
- Auth: `AzureCredentials`, `AzureAuthProvider`, `OAuthAuthProvider`,
  `LoopbackAuthorizer`, `TokenCache` / `EncryptedTokenCache` /
  `InMemoryTokenCache`, `StaticAuthProvider`.
- Models: `AzureUser`, `AzureGroup`, `AzureSnapshot`, `UserDelta`.

## `$batch`

Membership changes are folded into Graph `$batch` calls (`GraphBatch`,
`GroupManager.addMembers` / `removeMembers`), chunked at Graph's 20-request
ceiling — something the legacy connector never did (one HTTP call per member).

## Testing

Offline unit tests use a record-and-replay `FakeGraphTransport` (records every
outgoing request, replays committed fixtures from
[`test/fixtures/`](test/fixtures/)) and a `StaticAuthProvider`. They assert the
exact `$filter`/`$select`/`$batch` the connector issues, delta-token
round-trips, pagination, and the auth flows (cache hit, silent refresh,
interactive fallback, encrypted-cache round-trip).

Run them:

```
dart test packages/azure_api/test
```

Line coverage is **≈88%**. The only deliberately-uncovered code is the real
interactive browser launch inside `LoopbackAuthorizer.launchBrowser`'s caller
wiring (the loopback capture itself *is* tested with a fake browser); the
token-exchange and refresh logic is fully covered.

### Live access

The opt-in [`test/integration/azure_live_test.dart`](test/integration/azure_live_test.dart)
runs **read-only** against a real tenant (per the project's live-testing
policy — CI live tests never write). It skips unless the `AZURE_*` env vars are
present, so `dart test` stays offline by default. See
[`.azure.env.example`](../../.azure.env.example) for the variables.

A Graph bearer token expires in ~1 hour, so the token is **never stored** —
it is minted fresh each run. Both contexts use the same dedicated read-only
app registration; only the way they authenticate to it differs.

**Locally** — run the helper, which loads `.azure.env` and mints a fresh
token via the Azure CLI before invoking the test:

```
./tool/live-tests.ps1 -Only azure   # or omit -Only to run all three connectors
```

It calls `az account get-access-token` under the hood, so `az login` must
have been run with an account that can read the directory. The full sync
fans out a per-group member fetch and takes ~30s; the test carries a 3-minute
`@Timeout` to suit.

**In CI** — the `live-test` job uses **OIDC workload-identity federation**
(`azure/login@v2`): GitHub issues a short-lived identity token, Azure trusts
this repo via a federated credential and mints a Graph token in-job. Nothing
is stored as a secret. Only `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_DOMAIN`, `AZURE_SCHOOL_PREFIX` are configured (identifiers + config,
not credentials).

#### One-time Azure setup (operator)

1. Register an app (or reuse one) and grant it the **application** Graph
   permissions `User.Read.All` and `Group.Read.All` — **no write scopes** —
   then grant admin consent. This makes the credential read-only at the
   directory level, which is the hard guarantee the live-testing policy
   requires.
2. Add a **federated credential** on that app for GitHub Actions: issuer
   `https://token.actions.githubusercontent.com`, subject matching this repo
   (e.g. `repo:yvanvds/AccountManager:ref:refs/heads/dev`), audience
   `api://AzureADTokenExchange`.
3. In the repo, set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_DOMAIN`,
   `AZURE_SCHOOL_PREFIX` (Settings → Secrets and variables → Actions). No
   token or client secret is ever added.

Refresh record-and-replay fixtures with
[`tool/capture_responses.dart`](tool/capture_responses.dart) (redacts tokens;
**scrub PII** before committing).
