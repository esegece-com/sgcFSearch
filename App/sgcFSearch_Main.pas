{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Main;

{$I sgcVer.inc}
// Hidden main form of sgcFSearch.exe: owns the engine, the pipe server, the
// search bar, the tray icon and the global hotkey.
// Startup: engine, then pipe server; ERROR_ACCESS_DENIED = another instance
// owns the index: send it a show request (unless --background) and exit.
// --restarted retries the pipe for up to 10 s (previous instance closing).
// Engine and pipe events arrive on background threads and reach the main
// thread through PostMessage to a utility window (never Synchronize).

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.SysUtils,
  System.Classes, System.SyncObjs, System.JSON, Vcl.Controls, Vcl.Forms,
  Vcl.Menus, Vcl.ExtCtrls,
  // sgc
  sgcFSearch_Config, sgcFSearch_Log, sgcFSearch_Engine, sgcFSearch_Pipe,
  sgcFSearch_Hotkey, sgcFSearch_FormBar, sgcFSearch_FormFolders;

const
  WM_SGCFS_SHOW = WM_APP + 1;
  WM_SGCFS_STOP = WM_APP + 2;
  WM_SGCFS_CHANGED = WM_APP + 3;
  WM_SGCFS_STATE = WM_APP + 4;
  SGCFS_RESTARTED_ARG = '--restarted';
  SGCFS_HOTKEY_ID = 1;
  SGCFS_HISTORY_FILE = 'history.json';
  SGCFS_RESTART_WAIT_MS = 10000;
  SGCFS_TRAY_TIMER_MS = 2000;

type
  TsgcFSearchMainForm = class(TForm)
  private
    FEngine: TsgcFSearchEngine;
    FServer: TsgcFSearchPipeServer;
    FBar: TsgcFSearchBarForm;
    FTray: TTrayIcon;
    FMenu: TPopupMenu;
    FMenuCounts: TMenuItem;
    FMenuSearch: TMenuItem;
    FMenuLogin: TMenuItem;
    FTimer: TTimer;
    FWnd: HWND;
    FLock: TCriticalSection;
    FShowText: string;
    FChangedPosted: Integer;
    FHotkeyText: string;
    FHotkeyRegistered: Boolean;
    FBackground: Boolean;
    FRestarted: Boolean;
    FStarted: Boolean;
    FShutdown: Boolean;
    FFoldersOpen: Boolean;
    FFormat: TFormatSettings;
    procedure WndProcMsg(var Message: TMessage);
    function DoCreateServer: TsgcFSearchPipeServer;
    function DoHandleRequest(const Line: string): string;
    procedure DoEngineChanged(Sender: TObject; Generation: Int64);
    procedure DoEngineState(Sender: TObject; State: TsgcFSearchEngineState);
    procedure DoRegisterHotkey;
    procedure DoUnregisterHotkey;
    procedure DoCreateTray;
    function DoAddMenuItem(const Caption: string; Handler: TNotifyEvent)
      : TMenuItem;
    function DoNumber(Value: Int64): string;
    function DoStatusText(out Busy: Boolean): string;
    procedure DoUpdateTray;
    procedure DoTrayClick(Sender: TObject);
    procedure DoMenuPopup(Sender: TObject);
    procedure DoMenuSearch(Sender: TObject);
    procedure DoMenuFolders(Sender: TObject);
    procedure DoMenuLogin(Sender: TObject);
    procedure DoMenuLog(Sender: TObject);
    procedure DoMenuQuit(Sender: TObject);
    procedure DoTimer(Sender: TObject);
    procedure DoShowBar(const Text: string);
    procedure DoToggleBar;
    procedure DoShutdown;
    procedure DoQuit;
    procedure DoRestart;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// False when another instance owns the index (the app must exit).
    function Startup: Boolean;
  end;

var
  sgcFSearchMainForm: TsgcFSearchMainForm;

implementation

{$R *.dfm}

function DoIsTrue(Value: TJSONValue): Boolean;
begin
  Result := (Value is TJSONBool) and TJSONBool(Value).AsBoolean;
end;

constructor TsgcFSearchMainForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FFormat := TFormatSettings.Invariant;
  FWnd := AllocateHWnd(WndProcMsg);
end;

destructor TsgcFSearchMainForm.Destroy;
begin
  DoShutdown;
  FreeAndNil(FBar);
  FreeAndNil(FServer);
  FreeAndNil(FEngine);
  if FWnd <> 0 then
    DeallocateHWnd(FWnd);
  FWnd := 0;
  FreeAndNil(FLock);
  inherited Destroy;
end;

function TsgcFSearchMainForm.DoCreateServer: TsgcFSearchPipeServer;
begin
  Result := TsgcFSearchPipeServer.Create(function(const Line: string): string
    begin
      Result := DoHandleRequest(Line);
    end);
end;

function TsgcFSearchMainForm.Startup: Boolean;
var
  i: Integer;
  vOk: Boolean;
  vStart: UInt64;
  vResponse: string;
begin
  Result := False;
  for i := 1 to ParamCount do
    if SameText(ParamStr(i), SGCFS_BACKGROUND_ARG) then
      FBackground := True
    else if SameText(ParamStr(i), SGCFS_RESTARTED_ARG) then
      FRestarted := True;

  FEngine := TsgcFSearchEngine.Create;
  FServer := DoCreateServer;
  vOk := FServer.Start;
  if (not vOk) and FRestarted then
  begin
    vStart := GetTickCount64;
    while (not vOk) and (FServer.LastError = ERROR_ACCESS_DENIED) and
      (GetTickCount64 - vStart < SGCFS_RESTART_WAIT_MS) do
    begin
      Sleep(250);
      FreeAndNil(FServer);
      FServer := DoCreateServer;
      vOk := FServer.Start;
    end;
  end;
  if (not vOk) and (FServer.LastError = ERROR_ACCESS_DENIED) then
  begin
    FreeAndNil(FServer);
    FreeAndNil(FEngine);
    if not FBackground then
    begin
      // let the running instance bring its bar to the foreground
      AllowSetForegroundWindow(DWORD(-1));
      sgcFSearchPipeRequest('{"show":true}', 3000, vResponse);
    end;
    Exit;
  end;
  if not vOk then
    sgcFSearchLog('app: pipe server not started, error ' +
      IntToStr(FServer.LastError));

  FStarted := True;
  FBar := TsgcFSearchBarForm.Create(Self);
  FBar.Engine := FEngine;
  FBar.HistoryFileName := IncludeTrailingPathDelimiter(FEngine.DataDir) +
    SGCFS_HISTORY_FILE;
  FEngine.OnChanged := DoEngineChanged;
  FEngine.OnStateChanged := DoEngineState;

  DoRegisterHotkey;
  DoCreateTray;
  sgcFSearchLog('app: started, pid ' + IntToStr(GetCurrentProcessId) + ', pipe '
    + FServer.PipeName);
  FEngine.Start;
  DoUpdateTray;
  if not FBackground then
    DoShowBar('');
  Result := True;
end;

function TsgcFSearchMainForm.DoHandleRequest(const Line: string): string;
var
  vValue, vId, vText: TJSONValue;
  vObject: TJSONObject;
  vOp: Integer;
  vIdText, vQuery: string;
begin
  vOp := 0;
  vIdText := '';
  vQuery := '';
  vValue := nil;
  try
    try
      vValue := TJSONObject.ParseJSONValue(Line);
    except
      vValue := nil;
    end;
    if vValue is TJSONObject then
    begin
      vObject := TJSONObject(vValue);
      if DoIsTrue(vObject.GetValue('show')) then
        vOp := 1
      else if DoIsTrue(vObject.GetValue('stop')) then
        vOp := 2;
      if vOp <> 0 then
      begin
        vId := vObject.GetValue('id');
        if vId <> nil then
          vIdText := vId.ToJSON;
        vText := vObject.GetValue('q');
        if vText is TJSONString then
          vQuery := TJSONString(vText).Value;
      end;
    end;
  finally
    vValue.Free;
  end;

  if vOp = 0 then
  begin
    Result := FEngine.HandleRequest(Line);
    Exit;
  end;
  if vOp = 1 then
  begin
    FLock.Enter;
    try
      FShowText := vQuery;
    finally
      FLock.Leave;
    end;
    PostMessage(FWnd, WM_SGCFS_SHOW, 0, 0);
  end
  else
    PostMessage(FWnd, WM_SGCFS_STOP, 0, 0);
  if vIdText <> '' then
    Result := '{"id":' + vIdText + ',"ok":true}'
  else
    Result := '{"ok":true}';
end;

procedure TsgcFSearchMainForm.DoEngineChanged(Sender: TObject;
Generation: Int64);
begin
  // background thread: at most one pending message
  if AtomicExchange(FChangedPosted, 1) = 0 then
    PostMessage(FWnd, WM_SGCFS_CHANGED, 0, 0);
end;

procedure TsgcFSearchMainForm.DoEngineState(Sender: TObject;
State: TsgcFSearchEngineState);
begin
  PostMessage(FWnd, WM_SGCFS_STATE, WPARAM(Ord(State)), 0);
end;

procedure TsgcFSearchMainForm.WndProcMsg(var Message: TMessage);
var
  vText: string;
begin
  try
    case Message.Msg of
      WM_SGCFS_SHOW:
        begin
          FLock.Enter;
          try
            vText := FShowText;
            FShowText := '';
          finally
            FLock.Leave;
          end;
          DoShowBar(vText);
        end;
      WM_SGCFS_STOP:
        DoQuit;
      WM_SGCFS_CHANGED, WM_SGCFS_STATE:
        begin
          if Message.Msg = WM_SGCFS_CHANGED then
            AtomicExchange(FChangedPosted, 0);
          if not FShutdown then
          begin
            FBar.NotifyIndexChanged;
            DoUpdateTray;
          end;
        end;
      WM_HOTKEY:
        if Message.WPARAM = SGCFS_HOTKEY_ID then
          DoToggleBar;
      WM_QUERYENDSESSION:
        begin
          if (FEngine <> nil) and not FShutdown then
            FEngine.Checkpoint(True);
          Message.Result := 1;
        end;
      WM_ENDSESSION:
        begin
          if Message.WPARAM <> 0 then
            DoShutdown;
          Message.Result := 0;
        end;
    else
      Message.Result := DefWindowProc(FWnd, Message.Msg, Message.WPARAM,
        Message.LParam);
    end;
  except
    on E: Exception do
      sgcFSearchLog('app: message ' + IntToStr(Message.Msg) + ' failed: ' +
        E.Message);
  end;
end;

procedure TsgcFSearchMainForm.DoRegisterHotkey;
var
  vList: TArray<string>;
  vText: string;
  vModifiers, vKey: Cardinal;
begin
  vList := [Trim(FEngine.Config.Hotkey), SGCFS_HOTKEY_FALLBACK_1,
    SGCFS_HOTKEY_FALLBACK_2];
  for vText in vList do
  begin
    if not sgcFSearchParseHotkey(vText, vModifiers, vKey) then
    begin
      sgcFSearchLog('app: invalid hotkey "' + vText + '"');
      Continue;
    end;
    if RegisterHotKey(FWnd, SGCFS_HOTKEY_ID, vModifiers or SGCFS_MOD_NOREPEAT,
      vKey) then
    begin
      FHotkeyRegistered := True;
      FHotkeyText := sgcFSearchHotkeyText(vModifiers, vKey);
      sgcFSearchLog('app: hotkey ' + FHotkeyText + ' active');
      Exit;
    end;
    sgcFSearchLog('app: hotkey ' + vText + ' not available, error ' +
      IntToStr(GetLastError));
  end;
  sgcFSearchLog('app: no global hotkey available');
end;

procedure TsgcFSearchMainForm.DoUnregisterHotkey;
begin
  if FHotkeyRegistered then
    UnregisterHotKey(FWnd, SGCFS_HOTKEY_ID);
  FHotkeyRegistered := False;
end;

function TsgcFSearchMainForm.DoAddMenuItem(const Caption: string;
Handler: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := Caption;
  Result.OnClick := Handler;
  FMenu.Items.Add(Result);
end;

procedure TsgcFSearchMainForm.DoCreateTray;
var
  vSearch: string;
begin
  FMenu := TPopupMenu.Create(Self);
  FMenu.OnPopup := DoMenuPopup;
  FMenuCounts := DoAddMenuItem('sgcFSearch', nil);
  FMenuCounts.Enabled := False;
  vSearch := 'Search';
  if FHotkeyText <> '' then
    vSearch := vSearch + #9 + FHotkeyText;
  FMenuSearch := DoAddMenuItem(vSearch, DoMenuSearch);
  FMenuSearch.Default := True;
  DoAddMenuItem('Folders...', DoMenuFolders);
  FMenuLogin := DoAddMenuItem('Start at login', DoMenuLogin);
  // a portable copy writes nothing outside its own folder
  FMenuLogin.Enabled := not sgcFSearchIsPortable;
  DoAddMenuItem('Open log', DoMenuLog);
  DoAddMenuItem('-', nil);
  DoAddMenuItem('Quit', DoMenuQuit);

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := SGCFS_TRAY_TIMER_MS;
  FTimer.OnTimer := DoTimer;

  FTray := TTrayIcon.Create(Self);
  FTray.Icon.Assign(Application.Icon);
  FTray.Hint := 'sgcFSearch';
  FTray.PopupMenu := FMenu;
  FTray.OnClick := DoTrayClick;
  FTray.Visible := True;
end;

function TsgcFSearchMainForm.DoNumber(Value: Int64): string;
begin
  Result := FormatFloat('#,##0', Value, FFormat);
end;

function TsgcFSearchMainForm.DoStatusText(out Busy: Boolean): string;
var
  vStatus: TsgcFSearchEngineStatus;
begin
  vStatus := FEngine.Status;
  case vStatus.State of
    fsesStarting, fsesLoading:
      Result := 'Loading index';
    fsesCrawling:
      Result := 'Indexing ' + DoNumber(vStatus.Crawled) + ' entries';
    fsesCatchUp:
      Result := 'Updating, ' + DoNumber(vStatus.Files) + ' files, ' +
        DoNumber(vStatus.Folders) + ' folders';
    fsesReady:
      Result := 'Ready, ' + DoNumber(vStatus.Files) + ' files, ' +
        DoNumber(vStatus.Folders) + ' folders';
    fsesStopping:
      Result := 'Stopping';
  else
    Result := 'Stopped';
  end;
  if vStatus.ContentPending > 0 then
    Result := Result + ', ' + DoNumber(vStatus.ContentPending) +
      ' files being read';
  Busy := (vStatus.State in [fsesStarting, fsesLoading, fsesCrawling,
    fsesCatchUp]) or ((vStatus.State = fsesReady) and
    (vStatus.ContentPending > 0));
end;

procedure TsgcFSearchMainForm.DoUpdateTray;
var
  vBusy: Boolean;
  vText: string;
begin
  if (FTray = nil) or (FEngine = nil) then
    Exit;
  vText := DoStatusText(vBusy);
  FTray.Hint := 'sgcFSearch: ' + vText;
  FMenuCounts.Caption := vText;
  FTimer.Enabled := vBusy and not FShutdown;
end;

procedure TsgcFSearchMainForm.DoTimer(Sender: TObject);
begin
  if FShutdown then
  begin
    FTimer.Enabled := False;
    Exit;
  end;
  // the first crawl fires no change events: let the bar see the growing index
  if FEngine.State = fsesCrawling then
    FBar.NotifyIndexChanged;
  DoUpdateTray;
end;

procedure TsgcFSearchMainForm.DoTrayClick(Sender: TObject);
begin
  // a pinned bar that has the focus closes, as it does with the hotkey
  if (not FShutdown) and (FBar <> nil) and FBar.PinnedAndActive then
    FBar.HideBar
  else
    DoShowBar('');
end;

procedure TsgcFSearchMainForm.DoMenuPopup(Sender: TObject);
begin
  DoUpdateTray;
  FMenuLogin.Checked := FMenuLogin.Enabled and
    (sgcFSearchGetStartAtLogin <> '');
end;

procedure TsgcFSearchMainForm.DoMenuSearch(Sender: TObject);
begin
  DoShowBar('');
end;

procedure TsgcFSearchMainForm.DoMenuFolders(Sender: TObject);
var
  vSaved: Boolean;
begin
  if FFoldersOpen or FShutdown then
    Exit;
  FFoldersOpen := True;
  try
    if FBar.Visible then
      FBar.HideBar;
    vSaved := TsgcFSearchFoldersForm.Execute;
  finally
    FFoldersOpen := False;
  end;
  if vSaved then
    DoRestart;
end;

procedure TsgcFSearchMainForm.DoMenuLogin(Sender: TObject);
var
  vEnable: Boolean;
begin
  vEnable := sgcFSearchGetStartAtLogin = '';
  if not sgcFSearchSetStartAtLogin(vEnable, ParamStr(0)) then
    sgcFSearchLog('app: start at login change failed');
  FMenuLogin.Checked := sgcFSearchGetStartAtLogin <> '';
end;

procedure TsgcFSearchMainForm.DoMenuLog(Sender: TObject);
var
  vFile: string;
begin
  vFile := sgcFSearchLogFileName;
  if FileExists(vFile) then
    ShellExecute(0, 'open', PChar(vFile), nil, nil, SW_SHOWNORMAL);
end;

procedure TsgcFSearchMainForm.DoMenuQuit(Sender: TObject);
begin
  DoQuit;
end;

procedure TsgcFSearchMainForm.DoShowBar(const Text: string);
begin
  if FShutdown or (FBar = nil) then
    Exit;
  FBar.ShowBar(Text);
end;

procedure TsgcFSearchMainForm.DoToggleBar;
begin
  if FShutdown or (FBar = nil) then
    Exit;
  if FBar.Visible and (GetForegroundWindow = FBar.Handle) then
    FBar.HideBar
  else
    FBar.ShowBar('');
end;

procedure TsgcFSearchMainForm.DoShutdown;
begin
  if FShutdown then
    Exit;
  FShutdown := True;
  if FTimer <> nil then
    FTimer.Enabled := False;
  DoUnregisterHotkey;
  if (FBar <> nil) and FBar.Visible then
    FBar.HideBar;
  if FServer <> nil then
    FServer.Stop;
  if FEngine <> nil then
    FEngine.Stop;
  if FTray <> nil then
    FTray.Visible := False;
  if FStarted then
    sgcFSearchLog('app: stopped');
end;

procedure TsgcFSearchMainForm.DoQuit;
begin
  DoShutdown;
  Application.Terminate;
end;

procedure TsgcFSearchMainForm.DoRestart;
var
  vStartup: TStartupInfo;
  vProcess: TProcessInformation;
  vCommand: string;
begin
  sgcFSearchLog('app: settings changed, restarting');
  DoShutdown;
  vCommand := '"' + ParamStr(0) + '" ' + SGCFS_BACKGROUND_ARG + ' ' +
    SGCFS_RESTARTED_ARG;
  UniqueString(vCommand);
  FillChar(vStartup, SizeOf(vStartup), 0);
  vStartup.cb := SizeOf(vStartup);
  if CreateProcess(nil, PChar(vCommand), nil, nil, False, 0, nil, nil, vStartup,
    vProcess) then
  begin
    CloseHandle(vProcess.hThread);
    CloseHandle(vProcess.hProcess);
  end
  else
    sgcFSearchLog('app: restart failed, error ' + IntToStr(GetLastError));
  Application.Terminate;
end;

end.
