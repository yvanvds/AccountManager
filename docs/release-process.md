# Release process (Windows)

How a build gets from this repository onto an operator's machine, and how it
gets back off again when it shouldn't have. Introduced by
[#371](https://github.com/yvanvds/AccountManager/issues/371).

## The short version

```powershell
# 1. Bump the version in account_manager/pubspec.yaml, commit, merge to develop.
# 2. Tag the merged commit and push the tag.
git tag v1.1.0
git push origin v1.1.0
# 3. Watch .github/workflows/release.yml. It publishes the installer.
```

Everything else on this page is what those three lines mean.

## The pieces

| Piece | Where |
| --- | --- |
| Version (single source of truth) | `account_manager/pubspec.yaml` → `version:` |
| Installer script | [`installer/AccountManager.iss`](../installer/AccountManager.iss) |
| Release workflow | [`.github/workflows/release.yml`](../.github/workflows/release.yml) |
| In-app update check | `account_manager/lib/src/update/` |
| Published artifacts | <https://github.com/yvanvds/AccountManager/releases> |

## The version is `pubspec.yaml`, not the tag

`version:` in `account_manager/pubspec.yaml` is the only place a version number
is written down. Everything else derives from it:

- The Flutter tool stamps it into the Windows executable's **version resource**.
- The app reads that resource back at runtime (`readInstalledVersion`), which is
  what it displays and what the update check compares against.
- The release workflow passes it to `ISCC` as `AppVersion`, which names the
  asset and sets the installer's own version.

The **tag does not set the version, it claims one.** The workflow parses
`pubspec.yaml`, compares it to the tag, and fails the run if they disagree — so
a tag pushed against an un-bumped `pubspec.yaml` stops there instead of shipping
an installer that lies to the update check.

The `+N` build number after the version (`1.0.0+1`) is not part of a release
identity. Nothing compares on it.

## Tagging

1. Bump `version:` in `account_manager/pubspec.yaml` on a normal PR into
   `develop`. Semver: patch for fixes, minor for features, major for anything
   an operator has to be told about.
2. After it merges, tag **the merge commit**:

   ```powershell
   git checkout develop
   git pull
   git tag v1.1.0
   git push origin v1.1.0
   ```

3. The `Release` workflow runs on the tag. It builds `flutter build windows
   --release`, compiles the Inno Setup script, and publishes
   `AccountManager-Setup-v1.1.0.exe` as a GitHub Release asset with install
   instructions in the notes.

Tags are `vX.Y.Z`. The workflow's trigger filter (`v*.*.*`) and the app's tag
parser both assume it.

### Dry run

`Release` also has a **workflow_dispatch** trigger. It runs the identical build
and installer compile and publishes *nothing* — the installer lands as a
workflow artifact on the run's summary page. Use it after changing this
workflow, the `.iss`, or the pinned Flutter version, so the first time the real
pipeline runs is not also the first time it is tested.

## What the installer does

Per-user, and that is the load-bearing decision rather than a preference:

- Installs to `%LOCALAPPDATA%\Programs\AccountManager` with
  `PrivilegesRequired=lowest`. **No UAC, ever.** A Program Files install would
  need elevation on every update, which would make a silent auto-update
  impossible.
- A fixed `AppId` GUID, so a new version upgrades the existing install in place
  instead of stacking a second copy beside it. **Never change that GUID.**
- `CloseApplications=yes`, so the restart manager deals with a running copy.
- **Never touches `%APPDATA%\AccountManager\`.** That holds the DPAPI-encrypted
  token cache and the `connection.json` bootstrap (#370 endpoints, #384 Azure
  AD). Nothing in the script lists it under `[Files]` or `[UninstallDelete]`; the
  only code that can remove it is the explicit prompt at uninstall, which
  defaults to *No* and is skipped entirely in a silent uninstall.

Build one by hand:

```powershell
cd account_manager
flutter build windows --release
cd ..
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DAppVersion=1.1.0 installer\AccountManager.iss
# -> build\installer\AccountManager-Setup-v1.1.0.exe
```

`AppVersion` defaults to `0.0.0`, so a bare `ISCC installer\AccountManager.iss`
compiles as a syntax check.

## What a new operator does on first launch

**An installed copy cannot sign in until it is told which app registration to use
(#384).** That is deliberate and cannot be shipped away: the school's tenant id,
client id and Azure domain are not in this repository, which is public, so no
published build can carry them.

So the first launch of a fresh install is *expected* to land on **"Niet
geconfigureerd"**, with a **Naar Instellingen** button. Hand the operator four
values and one instruction:

1. **Instellingen → Verbinding → Azure AD**
2. Fill in client id, tenant id, Azure domain and school prefix.
3. **Verbinding bewaren**.
4. **Restart the app.** The tab says so; a running session keeps the app
   registration it started with.

That writes `%APPDATA%\AccountManager\connection.json`, which every later launch
reads. The backend coordinates in the section below it ship with working
defaults and normally need nothing.

### Skipping the typing: a seed beside the executable (#387)

For a fleet, hand the four values over once instead of per machine. Drop a
`connection.json` into the **install directory** —
`%LOCALAPPDATA%\Programs\AccountManager\connection.json` — and every launch reads
it, so the operator opens an install that is already configured:

```json
{
  "aadClientId": "…",
  "aadTenantId": "…",
  "aadDomain": "school.onmicrosoft.com",
  "schoolPrefix": "GBS"
}
```

Same keys as the `%APPDATA%` file, and any subset of them: name only the Azure AD
half, only the endpoints, or both. Deploy it with whatever already reaches the
machines — Intune, a login script, a technician with a USB stick.

Four rules it follows, and each is load-bearing:

- **The installer must never carry it.** The published installer is a public
  artifact; baking the school's tenant and client id into it publishes them
  exactly as committing them to this repository would. A file placed by hand
  next to an installed copy publishes nothing. See *Deliberately not done*.
- **`%APPDATA%` wins, per field.** An operator who corrects one value in
  Instellingen keeps that correction; everything they did not touch still comes
  from the seed.
- **Nothing ever writes it.** **Verbinding bewaren** always writes `%APPDATA%`,
  so a correction outlives whatever upgrade or re-deploy next rewrites the
  install directory. The seed is read fresh on every launch and never copied
  inward, which is what lets you re-point a whole fleet by replacing that one
  file — including on machines that have already been launched.
- **A broken one cannot brick a launch.** Malformed JSON there degrades to the
  layer under it with a warning on the Verbinding tab, exactly as a malformed
  `%APPDATA%` file does.

**Instellingen → Verbinding** names which of the two files answered, and says
when a `%APPDATA%` file is shadowing the seed. That line is the first thing to
read when an edit to the seed appears to do nothing.

Two things worth knowing when supporting this:

- Changing the **tenant** wipes `%APPDATA%\AccountManager\auth\`. Cached tokens
  were issued by the old tenant's STS, so they can only be rejected afterwards;
  the operator signs in again once.
- The tab renders and saves with Azure AD unconfigured *and* with Cosmos
  unreachable, both at once. If it ever does not, that is the bug — the screen
  that fixes sign-in must never sit behind sign-in.

## What the app does

On launch, **release builds only** (`autoCheck: kReleaseMode` in `main()` — a
`flutter run` checkout and every integration-test launch stay off the network):

1. Reads its own version from the executable's version resource.
2. Fetches `https://api.github.com/repos/yvanvds/AccountManager/releases/latest`,
   unauthenticated. The repository is public, so **no token is stored on any
   operator's machine**; the anonymous limit is 60 requests/hour/IP against one
   check per launch.
3. If the published version is higher, a bar appears above the navigation rail
   offering it. **Bijwerken** downloads the installer to `%TEMP%` and runs it
   with `/SILENT /NOCANCEL /NORESTART /RELAUNCH=1`, then exits so the installer
   can replace the files. `/RELAUNCH=1` is read by the script's own
   `WantsRelaunch` check and is what starts the new version back up — a plain
   `postinstall` entry is skipped under `/SILENT`.

Three things it deliberately does **not** do:

- **Block.** The check is fired from the shell's `initState` and awaited by
  nobody. The first frame is already on screen while it is in flight.
- **Interrupt.** A failed, offline or rate-limited check produces a log line and
  nothing else: no dialog, no banner, no toast. The reason is readable on demand
  in **Instellingen → Verbinding → Versie**, which is also where the running
  version is shown and where a manual check lives.
- **Update without consent.** `apply()` is reached from a button and from
  nothing else. There is no timer and no "always update" setting; the consent is
  per update, because the cost of getting it wrong is a restart in the middle of
  a sync.

## SmartScreen

There is no code-signing certificate, so **the first manual install shows
"Windows heeft uw pc beveiligd"**: *Meer informatie* → *Toch uitvoeren*. This is
expected and is written into every release's notes so it does not read as a
virus warning. Reputation never accrues at a handful of downloads per release.

The auto-update path is expected to avoid the warning, because the installer is
written by our own Dart HTTP client with `IOSink` rather than by a zone-aware
downloader, so it should carry no Mark-of-the-Web (`Zone.Identifier`) stream.

> **Unverified.** This has not been observed on a real machine yet — see the
> open checklist below. If it turns out not to hold, operators see the warning
> on *every* update and that belongs in the release notes.

Note also that **Smart App Control** (clean Windows 11 installs) can block
unsigned binaries outright regardless of Mark-of-the-Web.

## Rolling back

There is no downgrade path in the app — the update check only ever offers
something *newer*. A bad release is rolled back by publishing a good one.

1. **Stop the bleeding.** Delete or mark the bad release as a pre-release on
   GitHub. `/releases/latest` skips drafts and pre-releases, so installs stop
   being offered it immediately, on their next launch. Nothing else is needed to
   halt the spread.
2. **Ship the fix forward.** Revert the offending commits on `develop`, bump
   `pubspec.yaml` to a *higher* version than the bad one (`1.1.1`, not `1.0.9`),
   and tag that. Installs that already took the bad version get the fix through
   the normal update path.
3. **For an operator already stuck**, the manual route is to download the good
   installer from the Releases page and run it. It upgrades in place over the
   bad version and keeps `%APPDATA%\AccountManager\`.

Never re-tag a version number that has already been published. The update check
compares versions, not contents: an install already on `1.1.0` will not notice a
different `1.1.0`.

## Open, needs a real machine

These cannot be settled from CI and are the remaining acceptance criteria of
#371:

- [ ] Install `vN`, publish `vN+1`, and watch an installed copy notice, update,
      and come back with its settings and cached sign-in intact.
- [ ] Confirm the Mark-of-the-Web / SmartScreen behaviour described above, and
      write the answer down here.
- [ ] Confirm an update does not invalidate the cached AAD tokens. Expected not
      to — same tenant, same client id, same DPAPI user scope, and the installer
      never touches `%APPDATA%` — but it has not been observed.

## Deliberately not done

- **Seeding `connection.json` from the installer.** Raised as an open question in
  #371 and re-opened by #384, which put the Azure AD app registration in the same
  file — a seeded file would make a fresh install work with no typing at all,
  which is genuinely attractive. The answer is still **no**, for a reason that
  did not apply before: **the installer is a public artifact.** Baking the
  school's tenant id and client id into it publishes them exactly as committing
  them to this repository would, and the whole point of keeping them out of the
  repo is that they are not published. A CI secret does not change that — it only
  moves where the published bytes come from.

  The older argument still holds for the endpoint half: the compiled
  `StoreEndpoints` defaults already point a fresh install at the right backend,
  and on an *upgrade* a seeded file would overwrite the correction an operator
  made in **Instellingen → Verbinding**.

  What is left of the idea — an *optional* bootstrap file placed next to the
  executable by IT, which the app reads when `%APPDATA%` has none — publishes
  nothing and still spares the typing. That shipped as **#387**; see *Skipping
  the typing* above. It changes nothing here: the installer still carries no
  school-specific value, and the seed is placed by whoever deploys the machines.
- **Code signing.** No certificate exists. Buying one removes the SmartScreen
  section above and is its own issue.
- **Delta updates, staged rollouts, forced updates.** A full installer download
  is fine at this size and cadence.
- **macOS/Linux packaging.** The app is Windows-only in practice.
