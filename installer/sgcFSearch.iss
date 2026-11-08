; sgcFSearch per-user installer (Inno Setup 7)
; Build the Release exes first:
;   build\_msb.bat App\sgcFSearch.dproj Win64 Release
;   build\_msb.bat CLI\sgcfs.dproj Win64 Release
; then: "C:\Program Files\Inno Setup 7\ISCC.exe" installer\sgcFSearch.iss

#define AppName "sgcFSearch"
#define AppVersion "1.0.2"
#define AppPublisher "eSeGeCe"
#define AppURL "https://www.esegece.com"
#define AppExe "sgcFSearch.exe"
#define CliExe "sgcfs.exe"
#ifndef BinDir
  #define BinDir "..\bin\Win64\Release"
#endif

[Setup]
AppId={{3221FF96-DA54-4325-8B18-37AAFCDE10E7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppCopyright=Copyright (C) 2026 {#AppPublisher}
VersionInfoVersion={#AppVersion}.0
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=Output
OutputBaseFilename={#AppName}_setup
SetupIconFile=..\assets\sgcFSearch.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
CloseApplications=yes
RestartApplications=no
SignTool=sgcSignCode

[Tasks]
Name: "startatlogin"; Description: "Start {#AppName} at login"; GroupDescription: "Additional options:"
Name: "addtopath"; Description: "Add sgcfs to the user PATH"; GroupDescription: "Additional options:"

[Files]
Source: "{#BinDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\{#CliExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; Comment: "Search the files of every drive"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExe}"" --background"; Flags: uninsdeletevalue; Tasks: startatlogin

[Run]
Filename: "{app}\{#AppExe}"; Parameters: "--background"; Description: "Start {#AppName} now"; Flags: postinstall nowait

[UninstallRun]
Filename: "{app}\{#CliExe}"; Parameters: "stop"; RunOnceId: "StopDaemon"; Flags: waituntilterminated runhidden

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  EnvKey = 'Environment';

function SamePath(A, B: string): Boolean;
begin
  A := RemoveBackslashUnlessRoot(RemoveQuotes(Trim(A)));
  B := RemoveBackslashUnlessRoot(RemoveQuotes(Trim(B)));
  Result := CompareText(ExpandConstant(A), ExpandConstant(B)) = 0;
end;

{ rebuilds the user PATH: Dir appended (Add) or every copy of it removed }
procedure UpdateUserPath(const Dir: string; Add: Boolean);
var
  OldPath, NewPath, Rest, Item: string;
  P: Integer;
  Found: Boolean;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', OldPath) then
    OldPath := '';
  NewPath := '';
  Found := False;
  Rest := OldPath;
  while Rest <> '' do
  begin
    P := Pos(';', Rest);
    if P > 0 then
    begin
      Item := Copy(Rest, 1, P - 1);
      Delete(Rest, 1, P);
    end
    else
    begin
      Item := Rest;
      Rest := '';
    end;
    if Trim(Item) = '' then
      Continue;
    if SamePath(Item, Dir) then
    begin
      Found := True;
      if not Add then
        Continue;
    end;
    if NewPath <> '' then
      NewPath := NewPath + ';';
    NewPath := NewPath + Item;
  end;
  if Add and not Found then
  begin
    if NewPath <> '' then
      NewPath := NewPath + ';';
    NewPath := NewPath + Dir;
  end;
  if NewPath <> OldPath then
    RegWriteExpandStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', NewPath);
end;

{ closes a running instance before the files are replaced }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Cli, Exe: string;
  Code, I: Integer;
begin
  Result := '';
  Cli := ExpandConstant('{app}\{#CliExe}');
  Exe := ExpandConstant('{app}\{#AppExe}');
  if FileExists(Cli) then
  begin
    Exec(Cli, 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
    { the daemon saves its index after the reply: wait until the exe is free }
    for I := 1 to 30 do
    begin
      if not FileExists(Exe) then
        Break;
      if SaveStringToFile(Exe, '', True) then
        Break;
      Sleep(500);
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    UpdateUserPath(ExpandConstant('{app}'), WizardIsTaskSelected('addtopath'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    UpdateUserPath(ExpandConstant('{app}'), False);
    { the app menu may have written the Run value itself }
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, '{#AppName}');
  end;
end;
