# Arcadia Account Manager - Project Overview

> **Scope: this document describes the legacy WPF application** under
> `legacy-wpf/`. It is the architectural reference for that code - the
> behaviour oracle the Flutter/Dart port is measured against - and is
> deliberately *not* a description of the port. See
> [§2](#2-migration-status-and-where-the-port-is-documented) for where the
> port's own model is written down.

## 1. Purpose

Arcadia Account Manager is a Windows desktop application that synchronizes user
accounts and class groups across three independent administrative platforms used
by a Belgian secondary-school group (VZW Arcadia / Sancta Maria, Aarschot):

| System          | Role                                                         |
| --------------- | ------------------------------------------------------------ |
| **WISA**        | School administration (authoritative source for students, staff, classes, schools, civil-status data). |
| **Smartschool** | Learning Management System (accounts, class groups, co-accounts for parents, QR-login codes). |
| **Azure AD / Office 365** | Identity provider for Microsoft 365 (mail, Teams, SharePoint). |

The tool reads data from each platform, *links* records that represent the same
person/group, computes the divergences, proposes per-record **Actions** to
reconcile them, and lets the operator apply those actions individually or in
bulk. It also generates and distributes passwords (PDFs) for new students,
co-accounts and staff members.

## 2. Migration status and where the port is documented

The project is being ported from WPF / .NET Framework 4.8 to **Flutter / Dart**.
The original C# code has been moved under `legacy-wpf/` and is preserved as
read-only reference material - it is what the rest of this document describes.

The port is well past its placeholder stage: most of the application's code is
now the Dart workspace under `packages/` plus the Flutter app in
`account_manager/` (see §3). **This document does not describe that code**, and
nothing here should be read as a statement about how the port behaves today.
The port's own model lives in:

- [docs/domain-model.md](docs/domain-model.md) - the **spec** the port
  implements against: entities, identifiers, numbered invariants, and the
  `sync` / `link` / `evaluate` / `apply` operations. Where the new code diverges
  from legacy, the rationale is recorded there.
- [docs/port-plan.md](docs/port-plan.md) - the running port strategy.
- the per-package `README.md` files under `packages/`. In particular
  [packages/account_actions/README.md](packages/account_actions/README.md)
  owns the rules that govern **what a card offers** - `canApply`,
  `canApplyToAll`, `alternativeGroup`, `noticeFor` - which have no counterpart
  in the legacy action model described in §6.4.
- [CLAUDE.md](CLAUDE.md) - repository conventions and port order.

## 3. Solution Layout

```
Accountmanager/
├── legacy-wpf/         Original C# / WPF solution (read-only) - what this document describes
│   ├── AccountApi/         Class library: domain model + connectors to WISA, Smartschool, Azure
│   ├── AccountManager/     WPF desktop application (WinExe) - the UI
│   ├── Setup/              Visual Studio Installer project (.vdproj)
│   ├── packages/           NuGet package cache (classic packages.config, not PackageReference)
│   ├── WisaAPIService.wsdl WSDL used to generate the WISA SOAP web reference
│   ├── MigrationBackup/    Visual Studio upgrade artefacts
│   └── AccountManager.sln  Visual Studio solution (two C# projects, .NET Framework 4.8)
├── packages/           Pure-Dart workspace packages - the port (documented in their own READMEs)
│   ├── account_core/       Canonical domain model: entities, id types, enums, password generator, ILog
│   ├── account_store/      File-backed PersonId resolver (stable local ids across syncs)
│   ├── wisa_api/           WISA SOAP connector -> WisaSnapshot
│   ├── smartschool_api/    Smartschool SOAP (V3) connector + account/group/password writes
│   ├── azure_api/          Microsoft Graph connector + user/group writes
│   ├── account_linker/     Pure, deterministic cross-system linker -> LinkedSnapshot
│   ├── account_actions/    Action engine: evaluate / describeChanges / apply, with a dry-run path
│   └── account_state/      Orchestration: sync, link, apply, materialize, settings, passwords,
│                           Cosmos / Blob / Key Vault / SignalR
├── account_manager/    Flutter application (depends on packages/* via path: dependencies)
├── docs/
│   ├── domain-model.md The spec the port implements against
│   └── port-plan.md    Running document describing the port strategy
├── tool/               PowerShell helpers (opt-in live integration tests, Cosmos provisioning)
├── pubspec.yaml        Dart workspace definition (lists the workspace members)
├── analysis_options.yaml  Lint/analyzer config applied to every workspace member
├── CLAUDE.md           Guidance for Claude Code sessions in this repo
├── PROJECT_OVERVIEW.md This document
└── README.md           Entry point: badges, how to run the Flutter app
```

The legacy Visual Studio solution `legacy-wpf/AccountManager.sln` contains two
C# projects targeting **.NET Framework 4.8**: `AccountApi` (class library) and
`AccountManager` (WPF WinExe).

The legacy application was published via ClickOnce to a SharePoint location
(`arcadiascholen.sharepoint.com`) - see `<PublishUrl>` and `<InstallUrl>` in
[AccountManager.csproj](legacy-wpf/AccountManager/AccountManager.csproj#L27-L37).

## 4. Technology Stack

| Layer            | Technology                                                                     |
| ---------------- | ------------------------------------------------------------------------------ |
| Runtime          | .NET Framework 4.8 (WinExe + Class Library)                                    |
| UI framework     | WPF                                                                            |
| UI styling       | MahApps.Metro 1.6.5, MaterialDesignThemes 2.5.1, MaterialDesignColors          |
| UI components    | Dragablz (tabbed pages), CalcBinding, DynamicExpresso                          |
| MVVM helpers     | Fody / PropertyChanged.Fody (auto-INotifyPropertyChanged weaving)              |
| JSON             | Newtonsoft.Json 12, System.Text.Json 6                                         |
| PDF generation   | PDFsharp + MigraDoc 1.50 (password sheets)                                     |
| WISA integration | SOAP web reference generated from `WisaAPIService.wsdl`                        |
| Smartschool API  | SOAP web reference (`Webservices/V3` on the school's Smartschool tenant)       |
| Azure AD         | Microsoft.Graph 4.37 + Microsoft.Identity.Client (MSAL) 4.46 with token cache  |
| Static analysis  | Microsoft.CodeAnalysis.FxCopAnalyzers 3.3.2                                    |
| Distribution     | ClickOnce, Setup.vdproj                                                        |

## 5. AccountApi - Domain Library

`AccountApi.dll` is the platform-agnostic API surface the WPF app consumes. It
contains:

### 5.1 Domain interfaces and enums

- [IAccount.cs](legacy-wpf/AccountApi/IAccount.cs) - canonical user record (UID, AccountID,
  RegisterID/rijksregisternummer, StemID/stamboeknummer, role, names, gender,
  birth data, address, phones, mail, group, status). Implemented by
  `Smartschool.Account`, `Wisa.Student`, `Wisa.Staff`, `Azure.User`.
- [IGroup.cs](legacy-wpf/AccountApi/IGroup.cs) - canonical class/group node, including
  hierarchical `Parent`/`Children`/`Accounts`, `LoadAccounts()`,
  `ApplyImportRules()`, JSON serialization, and `Equals` for diffing.
- [IRule.cs](legacy-wpf/AccountApi/IRule.cs) - import rules with `ShouldApply(obj)` and
  `Modify(obj)` semantics; rules can be `RuleType.SS_Import` or
  `RuleType.WISA_Import`, action `Discard`, `Modify`, or `WorkDate`.
- [Enums.cs](legacy-wpf/AccountApi/Enums.cs) -
  - `AccountRole` (Student / Teacher / Director / Maintenance / IT / Support / Other)
  - `AccountType` (Student + 6 co-accounts for Smartschool)
  - `AccountState`, `GenderType`, `GroupType`, `ConnectionState`, `Origin`
  - `Rule` enum: `SS_DiscardGroup`, `SS_NoSubGroups`, `WI_ReplaceInstitution`,
    `WI_DontImportClass`, `WI_MarkAsVirtual`, `WI_DontImportUser`.
- [ILog.cs](legacy-wpf/AccountApi/ILog.cs) - logger sink the connectors expect from the
  host app.
- [Password.cs](legacy-wpf/AccountApi/Password.cs) - generates 8-char passwords of the form
  `Capital + vowel + consonant + vowel + consonant + vowel + digit(2-9) + symbol(!?*)`;
  zero/one are intentionally avoided to prevent o/i confusion.

### 5.2 Smartschool connector ([legacy-wpf/AccountApi/Smartschool/](legacy-wpf/AccountApi/Smartschool/))

- `Connector.cs` - wraps the generated `V3Service` SOAP client. Holds the
  passphrase, paths to student/staff group roots, configurable grade and year
  suffixes, and the disposable service.
- `AccountManager.cs` - `Save(IAccount, pw1, pw2, pw3)` translates the canonical
  account to Smartschool's expected format (Dutch role names "Leerling",
  "Leerkracht", "Directie"; gender "m"/"f"; `stamboeknummer` zero-padded;
  street/house/box concatenated into a single string the server later splits)
  and calls `saveUser` over SOAP. After saving, `UpdateQRCode` is invoked so the
  account has a Smartschool QR-login token.
- `Group.cs` / `GroupManager.cs` - retrieves the Smartschool group tree, exposes
  `FindAccountByWisaID()` and other helpers used by the linker.
- `JSONAccount.cs` / `JSONGroup.cs` - on-disk caching format.
- `Error.cs` - downloads the official error code list and translates SOAP error
  numbers to messages.

### 5.3 WISA connector ([legacy-wpf/AccountApi/Wisa/](legacy-wpf/AccountApi/Wisa/))

- `Connector.cs` - wraps `WisaAPIServiceService` (SOAP). Authentication uses a
  username / password / database tuple (`TWISAAPICredentials`). The main entry
  point is `PerformQuery(name, values)` which returns the body of a CSV (the
  WISA service exposes named queries that return CSV blobs).
- `Student.cs`, `Staff.cs`, `School.cs`, `ClassGroup.cs` - typed records.
- `StudentManager.cs`, `StaffManager.cs`, `SchoolManager.cs`,
  `ClassGroupManager.cs` - orchestrate the `SMA*` queries (e.g. `SMATestCon`,
  `SMATestQ`) and parse CSV into the typed records.
- `Connector.ReplaceInstNumber` - dictionary used by the
  `WI_ReplaceInstitution` rule to remap institute numbers.

### 5.4 Azure connector ([legacy-wpf/AccountApi/Azure/](legacy-wpf/AccountApi/Azure/))

- `Connector.cs` - `IAuthenticationProvider` for Microsoft Graph. Singleton.
  Uses MSAL `PublicClientApplicationBuilder` with the configured `ClientID` and
  `TenantID`, requests scope `User.ReadWrite.All`, and falls back to interactive
  login (`AcquireTokenInteractive`) when silent acquisition fails. Tokens are
  cached on disk via `TokenCacheHelper` (DPAPI-protected file in
  `%LOCALAPPDATA%`).
- `User.cs` / `UserManager.cs` - Graph-backed CRUD over `users` (read, update
  display name, school/department, mail, employee id, delete, list).
- `Group.cs` / `GroupManager.cs` - Graph-backed group operations.
- The WPF window handle is supplied to MSAL so the auth dialog parents the
  app's main window.

### 5.5 Import rules ([legacy-wpf/AccountApi/Rules/](legacy-wpf/AccountApi/Rules/))

| Rule                            | Type        | Effect                                                   |
| ------------------------------- | ----------- | -------------------------------------------------------- |
| `DiscardSmartschoolGroup`       | SS Import   | Drop a Smartschool subtree from the linker.              |
| `NoSmartschoolSubgroups`        | SS Import   | Treat the named group as a leaf.                         |
| `ReplaceInstitute`              | WISA Import | Rewrite an institute number on import.                   |
| `DontImportClass`               | WISA Import | Skip a WISA class.                                       |
| `DontImportUserFromWisa`        | WISA Import | Skip a single WISA user.                                 |
| `MarkAsVirtual`                 | WISA Import | Mark a school's records as "virtual" (excluded from real syncs). |

Each rule serializes itself to JSON via `IRule.ToJson()` and is rebuilt by the
state layer when configuration is loaded.

## 6. AccountManager (WPF) - Architecture

The desktop client is organised as a single shell (`MainWindow`) hosting a
left-side menu, a swappable content area, and a permanently visible log panel
on the right.

### 6.1 Application shell

- [App.xaml](legacy-wpf/AccountManager/App.xaml) / [App.xaml.cs](legacy-wpf/AccountManager/App.xaml.cs) -
  empty WPF application shell.
- [MainWindow.xaml](legacy-wpf/AccountManager/MainWindow.xaml) - `MetroWindow` titled
  "Arcadia Account Manager", maximized at startup, MaterialDesign + MahApps
  themes. Layout is a 3-column grid:
  1. **200 px** - the sidebar `<menu:Menu/>` (see [Views/Menu/Menu.xaml](legacy-wpf/AccountManager/Views/Menu/Menu.xaml)).
  2. **\*** - the content host (`<Grid x:Name="Content"/>`), initially showing a
     "Loading..." spinner.
  3. **5 px GridSplitter + 400 px** - the persistent `<log:Log/>` panel.
  Wrapped in a `materialDesign:DialogHost` (`Identifier="RootDialog"`) so any
  ViewModel can pop modal MaterialDesign dialogs.
- [MainWindow.xaml.cs](legacy-wpf/AccountManager/MainWindow.xaml.cs) - on construction
  initializes `State.App.Instance` then calls `Wisa.Connect()`,
  `Smartschool.Connect()`, `Azure.Connect()`. On `Loaded`, awaits
  `Linked.Groups.ReLink()`, `Linked.Accounts.ReLink()`,
  `Linked.Staff.ReLink()`, then navigates to `Views.Dashboard.DashboardPage`.
  Exposes a static `Instance` and a `Navigate(UserControl)` helper used by the
  menu.

### 6.2 Application state ([legacy-wpf/AccountManager/State/](legacy-wpf/AccountManager/State/))

State is held in a singleton `State.App.Instance`
([ApplicationState.cs](legacy-wpf/AccountManager/State/ApplicationState.cs)) with five
sub-states:

| Sub-state    | Class                                                               | Responsibility |
| ------------ | ------------------------------------------------------------------- | -------------- |
| `Wisa`       | [WisaState.cs](legacy-wpf/AccountManager/State/Wisa/WisaState.cs)               | Connection settings (server, port, db, user, pw), workdate (real + virtual), import rules, and the loaded `Schools`, `Groups`, `Students`, `Staff`. |
| `Smartschool`| [SmartschoolState.cs](legacy-wpf/AccountManager/State/Smartschool/SmartschoolState.cs) | URI, passphrase, test user, student/staff group paths, grade/year labels, import rules, loaded `Groups`. |
| `Azure`      | [AzureState.cs](legacy-wpf/AccountManager/State/Azure/AzureState.cs)            | ClientID, TenantID, Domain, loaded `Accounts` and `Groups`. |
| `Settings`   | [SettingsState.cs](legacy-wpf/AccountManager/State/Settings/SettingsState.cs)   | Global flags: `DebugMode`, `SchoolPrefix`. |
| `Linked`     | [LinkedState.cs](legacy-wpf/AccountManager/State/Linked/LinkedState.cs)         | Cross-system linking results: `Groups`, `Accounts`, `Staff`. |

All state classes derive from `AbstractState` (observer/subject pattern -
[AbstractState.cs](legacy-wpf/AccountManager/State/AbstractState.cs)) and provide
`LoadConfig`, `SaveConfig`, `LoadContent`, `LoadLocalContent`, `SaveContent`.
Configuration is persisted as JSON in
`%APPDATA%\AccountManager\config.json` (see
[ApplicationState.cs:115-133](legacy-wpf/AccountManager/State/ApplicationState.cs#L115-L133));
cached domain content (the last successful pull from each backend) is
serialized into the same folder so the UI can render even when offline at
startup.

#### Linked accounts/groups/staff

The linking algorithm
([LinkedAccounts.cs:48-198](legacy-wpf/AccountManager/State/Linked/LinkedAccounts.cs#L48-L198)):

1. Walk Smartschool's "Leerlingen" subtree, keying every account by mail.
2. For each WISA student, look up the matching Smartschool account by `WisaID`;
   attach it to the existing entry if found, otherwise insert a placeholder
   keyed by WisaID.
3. For each Azure user:
   - Match by `UserPrincipalName` + `EmployeeId == WisaID`.
   - Otherwise rekey a WisaID-only entry to the UPN once Azure provides the mail.
   - Otherwise scan all entries for a `WisaID` match.
   - If still unmatched but the Azure user's `CompanyName` equals the
     configured school prefix, keep the user as a stand-alone Azure entry
     (alumni / orphan).
4. Counts of total, linked, and unlinked accounts per origin are recomputed for
   the dashboard badges.
5. For every linked account, `AccountActionParser.AddActions` evaluates each
   reconciliation candidate (see §6.4) and stores the resulting `Actions`.

Equivalent logic exists for `LinkedGroups` (class group linker) and
`LinkedStaffMembers` (staff linker).

### 6.3 ViewModels and Views

The application uses MVVM with Fody auto-`PropertyChanged` weaving and
`RelayCommand` / `RelayAsyncCommand` ([ViewModels/Base/](legacy-wpf/AccountManager/ViewModels/Base/)).
Views are WPF `UserControl`s, ViewModels are plain classes set as
`DataContext` in code-behind.

Top-level pages, accessed from the left-hand menu
([Menu.xaml](legacy-wpf/AccountManager/Views/Menu/Menu.xaml)):

| Menu entry  | View                                                                            | ViewModel                                                       |
| ----------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Overzicht   | [DashboardPage.xaml](legacy-wpf/AccountManager/Views/Dashboard/DashboardPage.xaml)         | [DashboardPage.cs](legacy-wpf/AccountManager/ViewModels/Dashboard/DashboardPage.cs) |
| Klassen     | [GroupsPage.xaml](legacy-wpf/AccountManager/Views/Groups/GroupsPage.xaml)                  | (per-tab VMs in code-behind)                                    |
| Accounts    | [AccountsPage.xaml](legacy-wpf/AccountManager/Views/Accounts/AccountsPage.xaml)            | per-tab VMs in `ViewModels/Accounts/`                           |
| Passwords   | [PasswordPage.xaml](legacy-wpf/AccountManager/Views/Passwords/PasswordPage.xaml)           | per-tab VMs in `ViewModels/Passwords/`                          |
| Acties      | [ActionsPage.xaml](legacy-wpf/AccountManager/Views/Actions/ActionsPage.xaml)               | `QRCodeAction.cs`, `TestButtonAction.cs`                        |
| Settings    | [SettingsPage.xaml](legacy-wpf/AccountManager/Views/Settings/SettingsPage.xaml)            | per-tab VMs in `ViewModels/Settings/`                           |

#### 6.3.1 Dashboard

Top row: three `GroupBox`es ("Wisa Sync", "Smartschool Sync", "Office365 Sync")
each show the timestamp of the last successful sync (rendered green / orange /
red by `GetColor(date)` in
[DashboardPage.cs:192-198](legacy-wpf/AccountManager/ViewModels/Dashboard/DashboardPage.cs#L192-L198))
and `Sync ...` buttons that trigger `SyncWisaGroupsCommand`,
`SyncWisaAccountsCommand`, `SyncSmartschoolAccountsCommand`,
`SyncAzureGroupsCommand`, `SyncAzureAccountsCommand`. While running,
`materialDesign:ButtonProgressAssist.IsIndicatorVisible` is bound to per-button
`Indicator*` properties for an indeterminate spinner.

Bottom: a `ListView` with three group boxes - `LinkedGroups`, `LinkedAccounts`,
`LinkedStaffMembers` - each showing a 3-column matrix (Wisa / Smartschool /
Office365) with totals, linked counts, and unlinked counts (red when > 0), plus
an "Opnieuw Linken" button to re-run the linker.

#### 6.3.2 Klassen / Accounts / Passwords / Settings

Each is a Dragablz `TabablzControl` containing per-system tabs:

- **Klassen** - Overview (linked groups), Wisa, Smartschool.
- **Accounts** - Leerlingen (linked students with action list), Personeel
  (linked staff with action list), Wisa, Office365, Smartschool (raw views per
  source).
- **Passwords** - Leerlingen, Personeel. Generates new passwords, lists
  pending password sheets, exports PDFs.
- **Settings** - General, Wisa, Azure, Smartschool. Each tab has form fields
  bound to the corresponding `ConfigValue<T>` in the relevant `*State`.

#### 6.3.3 Acties

`ActionsPage` lists application-wide bulk operations (currently `QRCodeAction`
and `TestButtonAction`) implemented as `UserControl`s with `RelayAsyncCommand`
buttons.

#### 6.3.4 Log panel ([Views/Log/](legacy-wpf/AccountManager/Views/Log/))

Right-hand pane visible on every page. Two `Badged` buttons (Errors /
Messages) toggle filters, an `Origin` combo box (`All`/`Wisa`/`SmartSchool`)
restricts by source. Each `LogEntry` carries `Source`, `Content`, and a
`Color` brush (Errors are red); the WPF view binds these directly. The
`MainWindow.Log` instance is what every `Connector` and `*State` calls into via
the `ILog` abstraction (`AddMessage`, `AddError`).

### 6.4 Action engine ([legacy-wpf/AccountManager/Action/](legacy-wpf/AccountManager/Action/))

The action layer is the heart of reconciliation. Every detected divergence
between Wisa, Smartschool, and Azure becomes a typed Action that the user can
inspect and apply.

> The port keeps the three families and most of the action names, but **not**
> this model: it adds mutually-exclusive alternatives, informational actions
> that are card context rather than an option, and a separate bulk sanction.
> Read [packages/account_actions/README.md](packages/account_actions/README.md)
> for those rules - the section below is legacy behaviour only.

Three action families, each with its own abstract base class:

- **Group actions** ([Action/Group/](legacy-wpf/AccountManager/Action/Group/)) -
  base [GroupAction.cs](legacy-wpf/AccountManager/Action/Group/GroupAction.cs).
  - `AddToSmartschool`, `CreateInSmartschool`, `ModifySmartschoolData`,
    `DoNotImportFromSmartschool`, `DoNotImportFromWisa`, `NoActionNeeded`.
  - Dispatch in [GroupActionParser.cs](legacy-wpf/AccountManager/Action/Group/GroupActionParser.cs).

- **Student actions** ([Action/StudentAccount/](legacy-wpf/AccountManager/Action/StudentAccount/)) -
  base [AccountAction.cs](legacy-wpf/AccountManager/Action/StudentAccount/AccountAction.cs).
  Apply signature: `Apply(LinkedAccount, DateTime deletionDate)`.
  - Add: `AddToAzure`, `AddToSmartschool`.
  - Modify (only when all three sources exist):
    `ModifyAzureStudentEmail`, `ModifyAzureName`, `ModifyAzureSchool`,
    `ModifySmartschoolStudentAddress`, `ModifyAccountID`,
    `ModifySmartschoolStemID`, `ModifySmartschoolBirthPlace`,
    `MoveToSmartschoolClassGroup`, `ModifySmartschoolStudentEmail`,
    `ModifySmartschoolName`.
  - Remove: `RemoveFromAzure`, `UnregisterSmartschool`,
    `DeleteFromSmartschool`, `ChangeEmail`.
  - `NoActionNeeded` is the default flag when everything is clean.
  - Dispatch in [AccountActionParser.cs](legacy-wpf/AccountManager/Action/StudentAccount/AccountActionParser.cs):
    when any of Wisa/Smartschool/Azure is missing, only the create/remove
    actions are evaluated; otherwise only the modify actions run.

- **Staff actions** ([Action/StaffAccount/](legacy-wpf/AccountManager/Action/StaffAccount/)) -
  base [AccountAction.cs](legacy-wpf/AccountManager/Action/StaffAccount/AccountAction.cs).
  - `AddToAzure`, `AddToSmartschool`, `AddToAzureStaffGroup`,
    `AddToStaffGroup`, `RemoveFromAzure`, `RemoveFromSmartschool`,
    `DontImportFromWisa`, `ModifySmartschoolStaffEmail`, `SetCopyCode`,
    `UpdateWisaName`, `NoActionNeeded`.
  - Dispatch in [StaffMemberActionParser.cs](legacy-wpf/AccountManager/Action/StaffAccount/StaffMemberActionParser.cs).

Every action exposes `Header`, `Description`, `CanBeApplied`,
`CanBeAppliedToAll`, `CanShowDetails`, an `Indicator` (busy spinner), and a
`Prop<bool> ApplyToAll` toggle. Actions that can show diff details override
`GetDetails(linkedRecord) -> FlowDocument` so the
[ShowActionDetails.xaml](legacy-wpf/AccountManager/Views/Dialogs/ShowActionDetails.xaml)
dialog can render a side-by-side comparison.

### 6.5 Dialogs ([Views/Dialogs/](legacy-wpf/AccountManager/Views/Dialogs/))

Modal MaterialDesign dialogs used for rule editing and confirmation:

- `ImportRuleSelectDialog` - pick a rule type to add.
- `SS_DiscardGroupEditor`, `SS_DiscardSubGroupEditor` - configure Smartschool
  rules.
- `WI_DontImportClass`, `WI_DontImportUser`, `WI_MarkAsVirtual`,
  `WI_ReplaceInstitute` - configure WISA rules.
- `ShowActionDetails` - render the FlowDocument returned by an action.
- `IRuleEditor` - shared editor interface implemented by each rule dialog.

### 6.6 Password export ([Exporters/](legacy-wpf/AccountManager/Exporters/))

- `PasswordManager` - lazy singleton holding two `Manager<T>` stores backed by
  `Passwords.json` and `CoPasswords.json`.
- `Passwords.AccountPassword`, `Passwords.CoAccountPassword` - typed entries
  derived from `AbstractPassword`.
- `Passwords.Manager<T>` - in-memory list with JSON persistence.
- PDF generation uses PDFsharp / MigraDoc (referenced in the `.csproj`); the
  rendered sheets are produced from the `Views/Passwords/*Passwords.xaml`
  pages.

### 6.7 Utilities ([legacy-wpf/AccountManager/Utils/](legacy-wpf/AccountManager/Utils/))

- `ConfigValue<T>` - observable value with two callback hooks (one for state
  observers, one for connection-state invalidation), a name (JSON key), and
  Load/Save helpers - the building block every `*State` is composed of.
- `JsonConverter` - shared Newtonsoft converter setup.
- `CompareStrings`, `StringExtensions` - normalisation helpers used when
  comparing names from different systems (whitespace, accents, case).
- `Set<T>`, `TreeAccount`, `TreeGroup` - tree views and set ops over the
  combined account/group hierarchy.
- `FlowTableCreator` - builds `FlowDocument` tables for action-detail dialogs.
- `SortKeepingDataGrid` - DataGrid that preserves sort order across refreshes.
- `TaskUtils` - async helpers.
- `IErrorHandler` - shared error contract.

## 7. Configuration and persistence

- **`%APPDATA%\AccountManager\config.json`** - holds connection settings, the
  "WorkDate" pair (real + virtual), grade/year labels, and the JSON-serialized
  list of import rules (one per system).
- **`%APPDATA%\AccountManager\*.json`** - cached snapshots of the WISA,
  Smartschool, and Azure trees so the app can render before a fresh sync
  finishes (`LoadLocalContent` paths in each `*State`).
- **MSAL token cache** - serialized to a DPAPI-protected file by
  `TokenCacheHelper.EnableSerialization` so Azure logins persist across runs.
- **Passwords.json / CoPasswords.json** - kept in the same folder for the
  password manager.

## 8. Typical workflow

1. Operator launches the app; `MainWindow` boots state, connects each backend,
   and shows the Dashboard once `Linked.*.ReLink()` finishes.
2. Operator clicks **Sync ...** in each Dashboard tile. The corresponding
   `*State` calls `Connect()` and the manager (`StudentManager`,
   `GroupManager`, ...) refreshes data.
3. Linker recomputes; per-account/group action lists are rebuilt by the
   `*ActionParser`s. Dashboard counters update via the observer pattern.
4. Operator opens **Accounts** -> Leerlingen / Personeel, expands a row, and
   sees the suggested actions with diff details. Single actions or
   `ApplyToAll`-checked actions can be applied; an action calls back into
   `AccountApi.{Smartschool,Wisa,Azure}` to mutate the appropriate backend.
5. Operator generates passwords (**Passwords**) for new accounts; PDFs are
   produced via PDFsharp/MigraDoc.
6. Import rules and connection settings are adjusted in **Settings**; the
   application JSON is rewritten on close (`saveLocalContent` /
   `SaveConfiguration` in [ApplicationState.cs:104-109](legacy-wpf/AccountManager/State/ApplicationState.cs#L104-L109)).
7. The right-hand **Log** panel records every connector message and error,
   filterable by origin and severity.

## 9. Extensibility points

These describe how the **legacy** application was extended, and are kept as
reference for reading that code. `legacy-wpf/` is read-only: new connectors,
actions and import rules belong in the Dart packages under `packages/` (see §2).

- **Adding a sync target** - implement an `AbstractState` for the new system,
  expose `Account`/`Group` types implementing `IAccount`/`IGroup`, write a
  connector under `legacy-wpf/AccountApi/<System>/`, and register it in
  `State.App` + `LinkedState`.
- **Adding an action** - create a class deriving from the appropriate
  `AccountAction` / `GroupAction`, implement `Evaluate(LinkedAccount)` and
  `Apply(...)`, then add it to the corresponding `*ActionParser`.
- **Adding an import rule** - extend the `Rule` enum, implement an `IRule`
  under `legacy-wpf/AccountApi/Rules/`, register it in the `*State.AddImportRule(...)`
  switch, and add a dialog under `Views/Dialogs/`.
