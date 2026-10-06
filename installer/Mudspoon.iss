#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #error StageDir is required, build with installer\build.ps1
#endif
#ifndef AssetsDir
  #error AssetsDir is required, build with installer\build.ps1
#endif

[Setup]
AppId={{8F4C2D1A-6B3E-4C7A-9D52-3E1B7A0C94F6}
AppName=Hammerspoon for Windows
AppVersion={#AppVersion}
AppVerName=Hammerspoon for Windows {#AppVersion}
AppPublisher=mudbourn
DefaultDirName={localappdata}\Mudspoon
DefaultGroupName=Hammerspoon for Windows
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
WizardImageFile={#AssetsDir}\wizard.bmp,{#AssetsDir}\wizard@2x.bmp
WizardSmallImageFile={#AssetsDir}\wizard_small.bmp,{#AssetsDir}\wizard_small@2x.bmp
SetupIconFile={#AssetsDir}\mudspoon.ico
UninstallDisplayIcon={app}\app\mudspoon.ico
UninstallDisplayName=Hammerspoon for Windows
OutputDir=Output
OutputBaseFilename=Mudspoon-Setup
Compression=lzma2/ultra
SolidCompression=yes
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel2=This installs Hammerspoon for Windows %1 with the mudscript config, for bug testing.%n%nIt must run at the physical console of the PC. Remote Desktop (RDP) intercepts input and breaks the keyboard and mouse hooks.%n%nTo report a bug, open the Start menu and choose Send Hammerspoon bug report. It saves a zip of the logs on your Desktop and opens Explorer on it. Send that zip back along with what you were doing.

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "autostart"; Description: "Start Hammerspoon when I sign in"; Flags: unchecked

[Files]
Source: "{#StageDir}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\.hammerspoon\*"; DestDir: "{app}\.hammerspoon"; Excludes: "data\*,\ms_macros.lua"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\.hammerspoon\ms_macros.lua"; DestDir: "{app}\.hammerspoon"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#StageDir}\.hammerspoon\data\*"; DestDir: "{app}\.hammerspoon\data"; Excludes: ".ms_trusted_hash,.ms_build_num,.ms_build_base,registry_index.json"; Flags: onlyifdoesntexist uninsneveruninstall recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "{#StageDir}\.hammerspoon\data\.ms_trusted_hash"; DestDir: "{app}\.hammerspoon\data"; Flags: ignoreversion uninsneveruninstall
Source: "{#StageDir}\.hammerspoon\data\.ms_build_num"; DestDir: "{app}\.hammerspoon\data"; Flags: ignoreversion uninsneveruninstall
Source: "{#StageDir}\.hammerspoon\data\.ms_build_base"; DestDir: "{app}\.hammerspoon\data"; Flags: ignoreversion uninsneveruninstall
Source: "{#StageDir}\.hammerspoon\data\registry_index.json"; DestDir: "{app}\.hammerspoon\data"; Flags: ignoreversion uninsneveruninstall
Source: "{#StageDir}\.local\*"; DestDir: "{app}\.local"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "wv2.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\Hammerspoon for Windows"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\app\Mudspoon.vbs"""; WorkingDir: "{app}\app"; IconFilename: "{app}\app\mudspoon.ico"
Name: "{autoprograms}\Send Hammerspoon bug report"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\app\tray.ps1"" -BugReport"; WorkingDir: "{app}\app"; IconFilename: "{app}\app\mudspoon.ico"
Name: "{autodesktop}\Hammerspoon for Windows"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\app\Mudspoon.vbs"""; WorkingDir: "{app}\app"; IconFilename: "{app}\app\mudspoon.ico"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Mudspoon"; ValueData: """{sys}\wscript.exe"" ""{app}\app\Mudspoon.vbs"""; Tasks: autostart

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\wv2.ps1"""; StatusMsg: "Checking the WebView2 runtime..."; Flags: runhidden; Check: NeedWebView2
Filename: "{sys}\wscript.exe"; Parameters: """{app}\app\Mudspoon.vbs"""; WorkingDir: "{app}\app"; Description: "Launch Hammerspoon"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\app"

[Code]
const
  Wv2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function Wv2Present(Root: Integer; Key: string): Boolean;
var
  Version: string;
begin
  Result := RegQueryStringValue(Root, Key, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function NeedWebView2: Boolean;
begin
  Result :=
    not Wv2Present(HKLM32, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + Wv2Guid) and
    not Wv2Present(HKLM64, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + Wv2Guid) and
    not Wv2Present(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + Wv2Guid);
end;

procedure StopRunningApp;
var
  Script: string;
  ResultCode: Integer;
begin
  Script := ExpandConstant('{app}\app\stop.ps1');
  if FileExists(Script) then
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '" -Root "' + ExpandConstant('{app}\app') + '" -Tray',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InstalledUninstaller: string;
var
  Key: string;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F4C2D1A-6B3E-4C7A-9D52-3E1B7A0C94F6}_is1';

  if not RegQueryStringValue(HKCU, Key, 'UninstallString', Result) then
    if not RegQueryStringValue(HKLM, Key, 'UninstallString', Result) then
      Result := '';
end;

function InitializeSetup: Boolean;
var
  Uninstaller: string;
  Choice: Integer;
  ResultCode: Integer;
begin
  Result := True;

  Uninstaller := InstalledUninstaller;

  if (Uninstaller = '') or WizardSilent then
    exit;

  Choice := TaskDialogMsgBox(
    'Hammerspoon for Windows is already installed.',
    'Repair reinstalls the app files and keeps your settings and macros. Uninstall removes the app.',
    mbConfirmation,
    MB_YESNOCANCEL,
    ['Repair', 'Uninstall'],
    0);

  if Choice = IDNO then
  begin
    Exec(RemoveQuotes(Uninstaller), '', '', SW_SHOWNORMAL, ewNoWait, ResultCode);

    Result := False;
  end
  else if Choice = IDCANCEL then
    Result := False;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    StopRunningApp;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    StopRunningApp;
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Mudspoon');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if (not UninstallSilent) and
       (MsgBox('Also delete your Hammerspoon settings, macros and logs?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES) then
    begin
      DelTree(ExpandConstant('{app}\.hammerspoon'), True, True, True);
      DelTree(ExpandConstant('{app}\.local'), True, True, True);
    end;
  end;
end;
