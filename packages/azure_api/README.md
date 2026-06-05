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

### Server-side filter, and where it falls back

The bulk `$filter` is:

```
companyName eq '<prefix>' or startswith(department,'<prefix>')
```

Students carry the prefix in `companyName`; staff carry it at the **start** of
`department` (the legacy convention sets staff `department` to exactly the
prefix). Graph supports `eq` and `startswith` server-side on these properties,
but **not** `contains`. If an installation buries the prefix mid-string in
`department`, server-side `startswith` would miss those staff — use
`UserManager.loadClientFiltered`, which pulls with `$select` only and filters
client-side. The delta path always filters client-side, because `/users/delta`
does not honour these property filters.

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
