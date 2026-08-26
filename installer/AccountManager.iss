; Arcadia Account Manager — Windows installer (#371).
;
; Per-user by design, and that is the load-bearing decision rather than a
; preference: a machine-wide install under Program Files needs UAC elevation on
; every single update, which would make the in-app auto-update a UAC prompt an
; operator has to notice and approve. Installing into the user's own
; %LOCALAPPDATA% means the running app can replace its own files with no
; elevation at all, so `/SILENT` really is silent.
;
; Build it from a finished `flutter build windows --release` tree:
;
;   flutter build windows --release          (in account_manager/)
;   ISCC /DAppVersion=1.2.3 installer\AccountManager.iss
;
; AppVersion defaults to 0.0.0 so a bare `ISCC installer\AccountManager.iss`
; compiles for a syntax check without arguments. The release workflow always
; passes the real version, taken from the tag after checking it against
; account_manager/pubspec.yaml — which stays the single source of truth.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Arcadia Account Manager"
#define AppPublisher "Arcadia"
#define AppExeName "account_manager.exe"

; Where `flutter build windows --release` leaves the payload, relative to this
; script. Overridable with /DSourceDir= so CI can point at an artifact it
; unpacked somewhere else.
#ifndef SourceDir
  #define SourceDir "..\account_manager\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change this GUID. It is the identity Windows matches an existing
; install by, so a new one would stack a second copy beside the first instead
; of upgrading it — which is exactly the failure the auto-update would then
; repeat at every release.
AppId={{B76992CD-B38B-4FF6-88B6-564B2B9590FE}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL=https://github.com/yvanvds/AccountManager/issues
AppUpdatesURL=https://github.com/yvanvds/AccountManager/releases

; --- per-user install ---------------------------------------------------------
; `lowest` means the installer never asks for elevation; combined with a
; {localappdata} target it also means an unprivileged operator can install and
; update without an administrator ever being involved.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={localappdata}\Programs\AccountManager
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UsePreviousAppDir=yes

; 64-bit only: the app is built for x64 and there is no 32-bit runner.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; --- upgrade behaviour --------------------------------------------------------
; Let the restart manager close a running copy rather than failing on a locked
; .exe. RestartApplications is off on purpose: the auto-update path relaunches
; the app itself via /RELAUNCH=1 below, and letting the restart manager *also*
; bring it back is how an operator ends up with two windows.
CloseApplications=yes
RestartApplications=no

; Nothing under %APPDATA%\AccountManager\ is listed in [Files] or [UninstallDelete]
; anywhere in this script, so an upgrade cannot touch the DPAPI token cache or
; the connection.json bootstrap (#370). The only code that removes it is the
; explicit, opt-in prompt in CurUninstallStepChanged below.

OutputDir=..\build\installer
OutputBaseFilename=AccountManager-Setup-v{#AppVersion}
SetupIconFile=..\account_manager\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "nl"; MessagesFile: "compiler:Languages\Dutch.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter release tree: the .exe, flutter_windows.dll, the data\
; folder (app.so, icudtl.dat, flutter_assets) and any plugin DLLs a future
; dependency adds. Recursive and wildcarded on purpose — a hand-listed set is
; how a plugin DLL goes missing from exactly one release.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; Two mutually exclusive relaunches, and the Check guards are what keeps them
; exclusive.
;
; The first is the ordinary "run it now?" checkbox of an interactive install.
; `skipifsilent` means it never fires under /SILENT — which is precisely why the
; second one has to exist: the auto-update runs this installer silently, so
; without it the app would update and simply never come back.
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent; Check: not WantsRelaunch
Filename: "{app}\{#AppExeName}"; Flags: nowait; Check: WantsRelaunch

[Code]
{ True when the installer was started by the app's own updater, which passes
  /RELAUNCH=1 (see silentInstallArguments in update_bootstrap.dart). }
function WantsRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

{ The operator's own data — the DPAPI-encrypted token cache and the
  connection.json bootstrap — outlives an uninstall unless it is explicitly
  given up.

  Asked rather than assumed in both directions: silently deleting a token cache
  and a backend configuration on what might be a reinstall is destructive, and
  silently leaving it behind on a real removal is untidy. A silent uninstall
  keeps the data, because there is nobody there to ask. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DataDir := ExpandConstant('{userappdata}\AccountManager');
  if not DirExists(DataDir) then
    Exit;
  if UninstallSilent then
    Exit;
  if MsgBox('Ook de lokale gegevens van Arcadia Account Manager verwijderen?'#13#10#13#10
            + DataDir + #13#10#13#10
            + 'Dit bevat de bewaarde aanmelding en de verbindingsinstellingen van '
            + 'deze machine. Kies Nee als je de app opnieuw gaat installeren.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(DataDir, True, True, True);
end;
