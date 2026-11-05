{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_FormBar;

{$I sgcVer.inc}
{ Search bar form (borderless, topmost tool window) shown by the app shell.

  - Engine is set by the shell after create, the form never frees it; free
  the form before the engine.
  - Search as you type runs on one background worker thread (latest query
  wins: every query gets a sequence number, a result whose number is not the
  current one is dropped). Results reach the main thread by TThread.Queue.
  - Results: virtual owner-drawn TListBox (lbVirtualOwnerDraw, LBS_NODATA:
  the control stores no strings, rows are painted from the result array).
  - NotifyIndexChanged (main thread) re-runs the visible query, throttled to
  one run per 250 ms, ignored while hidden. No timer runs while hidden. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, Winapi.CommCtrl,
  System.SysUtils, System.Classes, System.Types, System.Math,
  System.SyncObjs, System.JSON, System.IOUtils, System.Generics.Collections,
  System.Win.Registry, System.Win.ComObj,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.Menus, Vcl.Dialogs, Vcl.Clipbrd,
  // sgc
  sgcFSearch_Types, sgcFSearch_Config, sgcFSearch_Query, sgcFSearch_Usage,
  sgcFSearch_Engine;

const
  WM_SGCFS_BAR_DEACTIVATE = WM_APP + 101;

type
  TsgcFSearchBarChip = (fsbcType, fsbcModified, fsbcSize, fsbcFolder, fsbcSort);

  TsgcFSearchBarPalette = record
    Back: TColor;
    Box: TColor;
    Border: TColor;
    Text: TColor;
    Dim: TColor;
    Accent: TColor;
    Select: TColor;
    Chip: TColor;
    ChipBorder: TColor;
    ChipActive: TColor;
    ChipActiveText: TColor;
    Error: TColor;
  end;

  TsgcFSearchBarForm = class(TForm)
  private
    FEngine: TsgcFSearchEngine;
    FWorker: TThread;
    FSeq: Int64;
    FBusy: Boolean;
    FShown: Boolean;
    FDestroying: Boolean;
    FDialogOpen: Boolean;
    FMenuOpen: Boolean;
    FInternal: Boolean;
    FInHistory: Boolean;
    FSuppressChar: Boolean;
    FDark: Boolean;
    FPal: TsgcFSearchBarPalette;
    FRows: TArray<TsgcFSearchEngineRow>;
    FTotal: Integer;
    FElapsed: Double;
    FError: string;
    FWarning: string;
    FFallback: Boolean;
    FKeepPath: string;
    FEngineText: string;
    FBoxRect: TRect;
    FChipRects: array [TsgcFSearchBarChip] of TRect;
    FChipKind: TsgcFSearchBarChip;
    FChipValues: TArray<string>;
    FChipMenu: TPopupMenu;
    FRowMenu: TPopupMenu;
    FIcons: TDictionary<string, Integer>;
    FImlSmall: HIMAGELIST;
    FImlLarge: HIMAGELIST;
    FHistory: TStringList;
    FHistoryLoaded: Boolean;
    FHistoryPos: Integer;
    FHistoryFileName: string;
    FLinkRect: TRect;
    FLinkHot: Boolean;
    procedure SetEngine(const Value: TsgcFSearchEngine);
    procedure SetHistoryFileName(const Value: string);
    procedure WMActivate(var Message: TWMActivate); message WM_ACTIVATE;
    procedure WMBarDeactivate(var Message: TMessage);
      message WM_SGCFS_BAR_DEACTIVATE;
    procedure CMDialogKey(var Message: TCMDialogKey); message CM_DIALOGKEY;
    procedure DoDeliver(Seq: Int64; const Rows: TsgcFSearchEngineRows;
      const Error, Warning: string; Fallback: Boolean);
    procedure DoStartSearch(Keep: Boolean);
    procedure DoClearRows;
    procedure DoLayout;
    procedure DoPlace(aMonitor: Vcl.Forms.TMonitor);
    procedure DoApplyTheme(Handles: Boolean);
    procedure DoApplyListTheme;
    procedure DoForceForeground;
    procedure DoDpiChanged(Sender: TObject; OldDPI, NewDPI: Integer);
    procedure DoUpdateEngineText;
    function DoSelRow(out Row: TsgcFSearchEngineRow): Boolean;
    procedure DoMoveSel(Delta: Integer);
    procedure DoOpenSelected;
    procedure DoRevealSelected;
    procedure DoCopyFile;
    procedure DoCopyPath;
    procedure DoRowMenuClick(Sender: TObject);
    procedure DoChipItemClick(Sender: TObject);
    procedure DoChipPopup(Kind: TsgcFSearchBarChip);
    function DoChipValue(Kind: TsgcFSearchBarChip): string;
    function DoHistoryActive: Boolean;
    procedure DoHistoryStep(Dir: Integer);
    procedure DoEnsureHistory;
    procedure DoSaveHistory;
    function DoImageList(out Size: Integer): HIMAGELIST;
    function DoIconIndex(const Row: TsgcFSearchEngineRow): Integer;
    function DoDrawSpans(C: TCanvas; const R: TRect; const S: string;
      HPos, HLen: Integer; Normal, Hl: TColor): Integer;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    /// Folder picker (TFileOpenDialog, fdoPickFolders); '' = cancelled.
    function DoPickFolder(const Initial: string): string; virtual;
    /// Writes Value into the query text for a chip ('' removes the filter).
    procedure DoApplyChip(Kind: TsgcFSearchBarChip; const Value: string);
    function DoChipCaption(Kind: TsgcFSearchBarChip;
      out Active: Boolean): string;
    /// Tab key: folder picker when the token at the caret is in: / path:.
    procedure DoTabKey;
    procedure DoAddHistory(const Text: string);
    function DoStatusText(out IsError: Boolean): string;
    property History: TStringList read FHistory;
    /// True while a search for the current text is pending.
    property Searching: Boolean read FBusy;
  public
    procedure ShowBar(const InitialText: string = '');
    procedure HideBar;
    /// Main thread only (TThread.Queue from Engine.OnChanged).
    procedure NotifyIndexChanged;
    property Engine: TsgcFSearchEngine read FEngine write SetEngine;
    property HistoryFileName: string read FHistoryFileName
      write SetHistoryFileName;
  published
    edtSearch: TEdit;
    pbChips: TPaintBox;
    lstResults: TListBox;
    pbStatus: TPaintBox;
    tmrRefresh: TTimer;
    tmrStatus: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormPaint(Sender: TObject);
    procedure edtSearchChange(Sender: TObject);
    procedure edtSearchKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure edtSearchKeyPress(Sender: TObject; var Key: Char);
    procedure pbChipsPaint(Sender: TObject);
    procedure pbChipsMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbStatusPaint(Sender: TObject);
    procedure pbStatusMouseLeave(Sender: TObject);
    procedure pbStatusMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure pbStatusMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure lstResultsData(Control: TWinControl; Index: Integer;
      var Data: string);
    procedure lstResultsDrawItem(Control: TWinControl; Index: Integer;
      aRect: TRect; State: TOwnerDrawState);
    procedure lstResultsDblClick(Sender: TObject);
    procedure lstResultsMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure tmrRefreshTimer(Sender: TObject);
    procedure tmrStatusTimer(Sender: TObject);
  end;

var
  sgcFSearchBarForm: TsgcFSearchBarForm;

implementation

{$R *.dfm}

const
  CS_BAR_WIDTH = 760;
  CS_BAR_ROWS = 9;
  CS_ROW_HEIGHT = 46;
  CS_BAR_LIMIT = 300;
  CS_HISTORY_MAX = 50;
  CS_ICON_CACHE_MAX = 4000;
  CS_FONT = 'Segoe UI';
  CS_LINK_CAPTION = 'made by esegece.com';
  CS_LINK_URL = 'https://www.esegece.com';
  CS_CLOSE_MARK = #$00D7;
  CS_PICK = '|pick';
  CS_REMOVE = '|remove';
  CS_DROPEFFECT_COPY = 1;
  CS_DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  CS_DWMWA_WINDOW_CORNER_PREFERENCE = 33;
  CS_DWMWCP_ROUND = 2;
  CS_THEME_KEY = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';

  CS_CHIP_KEYS: array [TsgcFSearchBarChip] of string = ('type', 'mtime', 'size',
    'in', 'sort');
  CS_CHIP_NAMES: array [TsgcFSearchBarChip] of string = ('Type', 'Modified',
    'Size', 'In folder...', 'Sort');

  CS_PAL_LIGHT: TsgcFSearchBarPalette = (Back: $00F9F9F9; Box: $00FFFFFF;
    Border: $00D0D0D0; Text: $001A1A1A; Dim: $00606060; Accent: $00B85F00;
    Select: $00FAECE0; Chip: $00F3F3F3; ChipBorder: $00D6D6D6;
    ChipActive: $00B85F00; ChipActiveText: $00FFFFFF; Error: $001C2BC4);
  CS_PAL_DARK: TsgcFSearchBarPalette = (Back: $00202020; Box: $002D2D2D;
    Border: $00404040; Text: $00F0F0F0; Dim: $00A0A0A0; Accent: $00FFCD60;
    Select: $00543E2D; Chip: $00303030; ChipBorder: $00474747;
    ChipActive: $00FFCD60; ChipActiveText: $00000000; Error: $00A499FF);

type
  TsgcFSearchBarDropFiles = record
    pFiles: DWORD;
    pt: TPoint;
    fNC: BOOL;
    fWide: BOOL;
  end;

  PsgcFSearchBarDropFiles = ^TsgcFSearchBarDropFiles;

  TsgcFSearchBarDeliver = procedure(Seq: Int64;
    const Rows: TsgcFSearchEngineRows; const Error, Warning: string;
    Fallback: Boolean) of object;

  TsgcFSearchBarWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FOnDeliver: TsgcFSearchBarDeliver;
    FHasJob: Boolean;
    FJobSeq: Int64;
    FJobText: string;
    FJobEngine: TsgcFSearchEngine;
    procedure DoQueue(Seq: Int64; const Rows: TsgcFSearchEngineRows;
      const Error, Warning: string; Fallback: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(const aOnDeliver: TsgcFSearchBarDeliver);
    destructor Destroy; override;
    procedure Post(Seq: Int64; const Text: string; Engine: TsgcFSearchEngine);
  end;

function sgcDwmSetWindowAttribute(hwnd: hwnd; dwAttribute: DWORD;
  pvAttribute: Pointer; cbAttribute: DWORD): HRESULT; stdcall;
  external 'dwmapi.dll' name 'DwmSetWindowAttribute';
function sgcSetWindowTheme(hwnd: hwnd; pszSubAppName, pszSubIdList: PWideChar)
  : HRESULT; stdcall; external 'uxtheme.dll' name 'SetWindowTheme';
function sgcILCreateFromPath(pszPath: PWideChar): Pointer; stdcall;
  external 'shell32.dll' name 'ILCreateFromPathW';
procedure sgcILFree(pidl: Pointer); stdcall;
  external 'shell32.dll' name 'ILFree';
function sgcSHOpenFolderAndSelectItems(pidlFolder: Pointer; cidl: UINT;
  apidl: Pointer; dwFlags: DWORD): HRESULT; stdcall;
  external 'shell32.dll' name 'SHOpenFolderAndSelectItems';

var
  GInv: TFormatSettings;

function sgcBarSystemDark: Boolean;
var
  vReg: TRegistry;
begin
  Result := False;
  try
    vReg := TRegistry.Create(KEY_READ);
    try
      vReg.RootKey := HKEY_CURRENT_USER;
      if vReg.OpenKeyReadOnly(CS_THEME_KEY) then
      begin
        if vReg.ValueExists('AppsUseLightTheme') then
          Result := vReg.ReadInteger('AppsUseLightTheme') = 0;
        vReg.CloseKey;
      end;
    finally
      vReg.Free;
    end;
  except
    Result := False;
  end;
end;

function sgcBarCountText(N: Int64): string;
begin
  if N >= 1000000 then
    Result := FormatFloat('0.0', N / 1000000, GInv) + 'M'
  else
    Result := FormatFloat('#,##0', N, GInv);
end;

function sgcBarSizeText(Size: Int64): string;
begin
  if Size < 0 then
    Result := ''
  else if Size < 1024 then
    Result := IntToStr(Size) + ' B'
  else if Size < 1024 * 1024 then
    Result := FormatFloat('0.0', Size / 1024, GInv) + ' KB'
  else if Size < Int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', Size / 1048576, GInv) + ' MB'
  else
    Result := FormatFloat('0.0', Size / 1073741824, GInv) + ' GB';
end;

procedure sgcBarChipOptions(Kind: TsgcFSearchBarChip;
  out Captions, Values: TArray<string>);
begin
  case Kind of
    fsbcType:
      begin
        Captions := ['Documents', 'Images', 'Videos', 'Audio', 'Code',
          'Archives', 'Apps', 'Fonts', 'Folders'];
        Values := ['documents', 'images', 'videos', 'audio', 'code', 'archives',
          'apps', 'fonts', 'folders'];
      end;
    fsbcModified:
      begin
        Captions := ['Today', 'Yesterday', 'Past week', 'Past month',
          'Past year'];
        Values := ['today', 'yesterday', 'week', 'month', 'year'];
      end;
    fsbcSize:
      begin
        Captions := ['Empty', 'Under 1 MB', '1-100 MB', 'Over 100 MB',
          'Over 1 GB'];
        Values := ['empty', '<1mb', '1mb..100mb', '>100mb', '>1gb'];
      end;
    fsbcSort:
      begin
        Captions := ['Relevance', 'Name', 'Size', 'Date'];
        Values := ['', 'name', 'size', 'date'];
      end;
  else
    begin
      Captions := nil;
      Values := nil;
    end;
  end;
end;

function sgcBarOptionCaption(Kind: TsgcFSearchBarChip;
  const Value: string): string;
var
  vCaps, vVals: TArray<string>;
  i: Integer;
begin
  Result := Value;
  sgcBarChipOptions(Kind, vCaps, vVals);
  for i := 0 to High(vVals) do
    if (vVals[i] <> '') and SameText(vVals[i], Value) then
      Exit(vCaps[i]);
end;

{ TsgcFSearchBarWorker }

constructor TsgcFSearchBarWorker.Create(const aOnDeliver
  : TsgcFSearchBarDeliver);
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FOnDeliver := aOnDeliver;
  inherited Create(False);
end;

destructor TsgcFSearchBarWorker.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  if not Finished then
    WaitFor;
  TThread.RemoveQueuedEvents(Self);
  inherited Destroy;
  FWake.Free;
  FLock.Free;
end;

procedure TsgcFSearchBarWorker.Post(Seq: Int64; const Text: string;
  Engine: TsgcFSearchEngine);
begin
  FLock.Enter;
  try
    FJobSeq := Seq;
    FJobText := Text;
    FJobEngine := Engine;
    FHasJob := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TsgcFSearchBarWorker.DoQueue(Seq: Int64;
  const Rows: TsgcFSearchEngineRows; const Error, Warning: string;
  Fallback: Boolean);
var
  vSeq: Int64;
  vRows: TsgcFSearchEngineRows;
  vError, vWarning: string;
  vFallback: Boolean;
  vDeliver: TsgcFSearchBarDeliver;
begin
  // locals of this call are captured: one copy per queued delivery
  vSeq := Seq;
  vRows := Rows;
  vError := Error;
  vWarning := Warning;
  vFallback := Fallback;
  vDeliver := FOnDeliver;
  Queue(procedure
    begin
      vDeliver(vSeq, vRows, vError, vWarning, vFallback);
    end);
end;

procedure TsgcFSearchBarWorker.Execute;
var
  vHas, vStale, vFallback: Boolean;
  vSeq: Int64;
  vText, vError, vWarning: string;
  vEngine: TsgcFSearchEngine;
  vRows: TsgcFSearchEngineRows;
  vQuery: TsgcFSearchQuery;
begin
  while not Terminated do
  begin
    FWake.WaitFor(INFINITE);
    if Terminated then
      Break;
    FLock.Enter;
    try
      vHas := FHasJob;
      vSeq := FJobSeq;
      vText := FJobText;
      vEngine := FJobEngine;
      FHasJob := False;
    finally
      FLock.Leave;
    end;
    if (not vHas) or (vEngine = nil) then
      Continue;
    vRows := Default (TsgcFSearchEngineRows);
    vError := '';
    vWarning := '';
    vFallback := False;
    try
      vQuery := sgcFSearchParseQuery(vText);
      if Length(vQuery.Warnings) > 0 then
        vWarning := vQuery.Warnings[0];
      vEngine.Search(vText, CS_BAR_LIMIT, vRows);
      vFallback := vRows.IsContentResult and not vQuery.HasContentFilters;
    except
      on E: Exception do
      begin
        vRows := Default (TsgcFSearchEngineRows);
        vError := E.Message;
      end;
    end;
    FLock.Enter;
    try
      vStale := FHasJob;
    finally
      FLock.Leave;
    end;
    if vStale or Terminated then
      Continue;
    DoQueue(vSeq, vRows, vError, vWarning, vFallback);
  end;
end;

{ TsgcFSearchBarForm }

procedure TsgcFSearchBarForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW or WS_EX_TOPMOST;
  Params.WindowClass.style := Params.WindowClass.style or CS_DROPSHADOW;
end;

procedure TsgcFSearchBarForm.CreateWnd;
var
  vPref: Integer;
begin
  inherited;
  vPref := CS_DWMWCP_ROUND;
  try
    sgcDwmSetWindowAttribute(Handle, CS_DWMWA_WINDOW_CORNER_PREFERENCE, @vPref,
      SizeOf(vPref));
  except
    // dwmapi not available
  end;
end;

procedure TsgcFSearchBarForm.FormCreate(Sender: TObject);

  procedure AddRowItem(const aCaption: string; aTag: Integer;
  aShortCut: TShortCut);
  var
    vItem: TMenuItem;
  begin
    vItem := TMenuItem.Create(FRowMenu);
    vItem.Caption := aCaption;
    vItem.Tag := aTag;
    vItem.ShortCut := aShortCut;
    vItem.OnClick := DoRowMenuClick;
    FRowMenu.Items.Add(vItem);
  end;

begin
  FHistory := TStringList.Create;
  FHistory.CaseSensitive := False;
  FHistoryPos := -1;
  FIcons := TDictionary<string, Integer>.Create;
  FHistoryFileName := IncludeTrailingPathDelimiter(sgcFSearchDataDir) +
    'history.json';
  FChipMenu := TPopupMenu.Create(Self);
  FRowMenu := TPopupMenu.Create(Self);
  AddRowItem('Open', 1, Vcl.Menus.ShortCut(VK_RETURN, []));
  AddRowItem('Show in folder', 2, Vcl.Menus.ShortCut(VK_RETURN, [ssCtrl]));
  AddRowItem('Copy file', 3, Vcl.Menus.ShortCut(Ord('C'), [ssCtrl]));
  AddRowItem('Copy path', 4, Vcl.Menus.ShortCut(Ord('C'), [ssCtrl, ssShift]));
  OnAfterMonitorDpiChanged := DoDpiChanged;
  DoApplyTheme(False);
  DoLayout;
end;

procedure TsgcFSearchBarForm.FormDestroy(Sender: TObject);
begin
  FDestroying := True;
  tmrRefresh.Enabled := False;
  tmrStatus.Enabled := False;
  FreeAndNil(FWorker);
  FreeAndNil(FIcons);
  FreeAndNil(FHistory);
end;

procedure TsgcFSearchBarForm.SetEngine(const Value: TsgcFSearchEngine);
begin
  if FEngine = Value then
    Exit;
  FEngine := Value;
  if Trim(edtSearch.Text) <> '' then
    DoStartSearch(False);
end;

procedure TsgcFSearchBarForm.SetHistoryFileName(const Value: string);
begin
  if FHistoryFileName = Value then
    Exit;
  FHistoryFileName := Value;
  FHistoryLoaded := False;
  FHistoryPos := -1;
  if FHistory <> nil then
    FHistory.Clear;
end;

{ window }

procedure TsgcFSearchBarForm.WMActivate(var Message: TWMActivate);
begin
  inherited;
  if (Message.Active = WA_INACTIVE) and FShown and not FDialogOpen and
    not FMenuOpen and HandleAllocated then
    PostMessage(Handle, WM_SGCFS_BAR_DEACTIVATE, 0, 0);
end;

procedure TsgcFSearchBarForm.WMBarDeactivate(var Message: TMessage);
var
  vFg: hwnd;
begin
  if (not FShown) or FDialogOpen or FMenuOpen then
    Exit;
  vFg := GetForegroundWindow;
  if (vFg = Handle) or ((vFg <> 0) and (GetWindow(vFg, GW_OWNER) = Handle)) then
    Exit;
  HideBar;
end;

procedure TsgcFSearchBarForm.CMDialogKey(var Message: TCMDialogKey);
begin
  case Message.CharCode of
    VK_TAB:
      begin
        DoTabKey;
        Message.Result := 1;
      end;
    VK_ESCAPE:
      begin
        HideBar;
        Message.Result := 1;
      end;
  else
    inherited;
  end;
end;

procedure TsgcFSearchBarForm.DoApplyTheme(Handles: Boolean);
var
  vDark: BOOL;
begin
  FDark := sgcBarSystemDark;
  if FDark then
    FPal := CS_PAL_DARK
  else
    FPal := CS_PAL_LIGHT;
  Color := FPal.Back;
  edtSearch.Color := FPal.Box;
  edtSearch.Font.Color := FPal.Text;
  lstResults.Color := FPal.Back;
  if Handles and HandleAllocated then
  begin
    vDark := FDark;
    try
      sgcDwmSetWindowAttribute(Handle, CS_DWMWA_USE_IMMERSIVE_DARK_MODE, @vDark,
        SizeOf(vDark));
    except
      // dwmapi not available
    end;
  end;
  Invalidate;
end;

procedure TsgcFSearchBarForm.DoApplyListTheme;
begin
  if not lstResults.HandleAllocated then
    Exit;
  try
    if FDark then
      sgcSetWindowTheme(lstResults.Handle, 'DarkMode_Explorer', nil)
    else
      sgcSetWindowTheme(lstResults.Handle, 'Explorer', nil);
  except
    // uxtheme not available
  end;
end;

procedure TsgcFSearchBarForm.DoLayout;
var
  vM, vW, vY, vBoxH, vEH, vIH, vRows: Integer;
begin
  vW := ClientWidth;
  vM := ScaleValue(10);
  vBoxH := ScaleValue(46);
  FBoxRect := System.Types.Rect(vM, vM, vW - vM, vM + vBoxH);
  vEH := edtSearch.Height;
  edtSearch.SetBounds(FBoxRect.Left + ScaleValue(42),
    FBoxRect.Top + (vBoxH - vEH) div 2, FBoxRect.Width - ScaleValue(54), vEH);
  vY := FBoxRect.Bottom + ScaleValue(8);
  pbChips.SetBounds(vM, vY, vW - 2 * vM, ScaleValue(28));
  vY := pbChips.Top + pbChips.Height + ScaleValue(8);
  vIH := ScaleValue(CS_ROW_HEIGHT);
  if lstResults.ItemHeight <> vIH then
  begin
    lstResults.ItemHeight := vIH;
    if FShown then
      DoApplyListTheme;
  end;
  vRows := Min(Length(FRows), CS_BAR_ROWS);
  if vRows > 0 then
  begin
    lstResults.SetBounds(vM, vY, vW - 2 * vM, vRows * vIH);
    lstResults.Visible := True;
    vY := lstResults.Top + lstResults.Height + ScaleValue(4);
  end
  else
    lstResults.Visible := False;
  pbStatus.SetBounds(vM + ScaleValue(6), vY, vW - 2 * vM - ScaleValue(12),
    ScaleValue(20));
  ClientHeight := pbStatus.Top + pbStatus.Height + ScaleValue(6);
end;

procedure TsgcFSearchBarForm.DoPlace(aMonitor: Vcl.Forms.TMonitor);
var
  vWA: TRect;
  vW: Integer;
begin
  if aMonitor <> nil then
  begin
    vWA := aMonitor.WorkareaRect;
    if (aMonitor.PixelsPerInch > 0) and (aMonitor.PixelsPerInch <> CurrentPPI)
    then
      ScaleForPPI(aMonitor.PixelsPerInch);
  end
  else
    vWA := Screen.WorkareaRect;
  vW := Min(ScaleValue(CS_BAR_WIDTH), vWA.Width - ScaleValue(32));
  SetBounds(vWA.Left + (vWA.Width - vW) div 2,
    vWA.Top + Round(vWA.Height * 0.22), vW, Height);
  DoLayout;
end;

procedure TsgcFSearchBarForm.DoDpiChanged(Sender: TObject;
OldDPI, NewDPI: Integer);
begin
  if FShown then
  begin
    DoPlace(Monitor);
    DoApplyListTheme;
  end
  else
    DoLayout;
  Invalidate;
end;

procedure TsgcFSearchBarForm.DoForceForeground;
var
  vFg: hwnd;
  vFgThread, vMyThread: DWORD;
begin
  SetForegroundWindow(Handle);
  if GetForegroundWindow = Handle then
    Exit;
  vFg := GetForegroundWindow;
  vFgThread := GetWindowThreadProcessId(vFg, nil);
  vMyThread := GetCurrentThreadId;
  if (vFgThread <> 0) and (vFgThread <> vMyThread) and
    AttachThreadInput(vMyThread, vFgThread, True) then
    try
      BringWindowToTop(Handle);
      SetForegroundWindow(Handle);
      Winapi.Windows.SetFocus(edtSearch.Handle);
    finally
      AttachThreadInput(vMyThread, vFgThread, False);
    end;
end;

procedure TsgcFSearchBarForm.ShowBar(const InitialText: string);
var
  vPt: TPoint;
begin
  DoApplyTheme(True);
  if InitialText <> '' then
  begin
    FInternal := True;
    try
      edtSearch.Text := InitialText;
    finally
      FInternal := False;
    end;
  end;
  FHistoryPos := -1;
  FShown := True;
  pbChips.Invalidate;
  DoUpdateEngineText;
  DoStartSearch(False);
  if not GetCursorPos(vPt) then
    vPt := Point(0, 0);
  DoPlace(Screen.MonitorFromPoint(vPt, mdNearest));
  if not Visible then
    Visible := True;
  SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or
    SWP_SHOWWINDOW);
  DoApplyListTheme;
  DoForceForeground;
  if edtSearch.CanFocus then
    edtSearch.SetFocus;
  edtSearch.SelectAll;
  tmrStatus.Enabled := (FEngine <> nil) and (FEngine.State <> fsesReady);
end;

procedure TsgcFSearchBarForm.HideBar;
begin
  tmrRefresh.Enabled := False;
  tmrStatus.Enabled := False;
  if Trim(edtSearch.Text) <> '' then
    DoAddHistory(edtSearch.Text);
  Inc(FSeq); // drop results still in flight
  FBusy := False;
  FShown := False;
  if Visible then
    Hide;
end;

procedure TsgcFSearchBarForm.NotifyIndexChanged;
begin
  if (not FShown) or (Trim(edtSearch.Text) = '') then
    Exit;
  if not tmrRefresh.Enabled then
    tmrRefresh.Enabled := True;
end;

procedure TsgcFSearchBarForm.tmrRefreshTimer(Sender: TObject);
begin
  tmrRefresh.Enabled := False;
  if FShown then
    DoStartSearch(True);
end;

procedure TsgcFSearchBarForm.tmrStatusTimer(Sender: TObject);
begin
  if (not FShown) or (FEngine = nil) then
  begin
    tmrStatus.Enabled := False;
    Exit;
  end;
  DoUpdateEngineText;
  pbStatus.Invalidate;
  if FEngine.State = fsesReady then
    tmrStatus.Enabled := False;
  // the partial index grew (or is complete now): refresh the results
  if Trim(edtSearch.Text) <> '' then
    DoStartSearch(True);
end;

{ search }

procedure TsgcFSearchBarForm.DoClearRows;
begin
  FRows := nil;
  FTotal := 0;
  FElapsed := 0;
  FError := '';
  FWarning := '';
  FFallback := False;
  lstResults.Count := 0;
  DoLayout;
  pbStatus.Invalidate;
end;

procedure TsgcFSearchBarForm.DoStartSearch(Keep: Boolean);
var
  vText: string;
  vRow: TsgcFSearchEngineRow;
begin
  Inc(FSeq);
  vText := Trim(edtSearch.Text);
  FKeepPath := '';
  if Keep and DoSelRow(vRow) then
    FKeepPath := vRow.Path;
  if (vText = '') or (FEngine = nil) then
  begin
    FBusy := False;
    DoClearRows;
    Exit;
  end;
  if FWorker = nil then
    FWorker := TsgcFSearchBarWorker.Create(DoDeliver);
  FBusy := True;
  TsgcFSearchBarWorker(FWorker).Post(FSeq, vText, FEngine);
end;

procedure TsgcFSearchBarForm.DoDeliver(Seq: Int64;
const Rows: TsgcFSearchEngineRows; const Error, Warning: string;
Fallback: Boolean);
var
  i, vSel: Integer;
begin
  if FDestroying or (Seq <> FSeq) then
    Exit;
  FBusy := False;
  FRows := Rows.Items;
  FTotal := Rows.Total;
  FElapsed := Rows.ElapsedMs;
  FError := Error;
  FWarning := Warning;
  FFallback := Fallback;
  vSel := 0;
  if FKeepPath <> '' then
    for i := 0 to High(FRows) do
      if SameText(FRows[i].Path, FKeepPath) then
      begin
        vSel := i;
        Break;
      end;
  lstResults.Count := Length(FRows);
  if Length(FRows) > 0 then
    lstResults.ItemIndex := vSel;
  DoLayout;
  lstResults.Invalidate;
  pbStatus.Invalidate;
end;

procedure TsgcFSearchBarForm.DoUpdateEngineText;
var
  vSt: TsgcFSearchEngineStatus;
begin
  FEngineText := '';
  if FEngine = nil then
    Exit;
  vSt := FEngine.Status;
  case vSt.State of
    fsesStarting:
      FEngineText := 'Starting...';
    fsesLoading:
      FEngineText := 'Loading index...';
    fsesCrawling:
      FEngineText := 'Indexing... ' + sgcBarCountText
        (Max(Int64(vSt.Files) + vSt.Folders, vSt.Crawled)) + ' files';
    fsesCatchUp:
      FEngineText := 'Updating index...';
    fsesStopping, fsesStopped:
      FEngineText := 'Index stopped';
  end;
end;

function TsgcFSearchBarForm.DoStatusText(out IsError: Boolean): string;
var
  vS: string;

  procedure Add(const S: string);
  begin
    if S = '' then
      Exit;
    if vS <> '' then
      vS := vS + '     ';
    vS := vS + S;
  end;

begin
  vS := '';
  IsError := FError <> '';
  if IsError then
    Add(FError)
  else if (Trim(edtSearch.Text) <> '') and not FBusy then
  begin
    if FFallback then
      Add('No file name matches, showing matches inside files');
    if FTotal = 1 then
      Add('1 result  ' + FormatFloat('0.0', FElapsed, GInv) + ' ms')
    else
      Add(sgcBarCountText(FTotal) + ' results  ' + FormatFloat('0.0', FElapsed,
        GInv) + ' ms');
    Add(FWarning);
  end;
  Add(FEngineText);
  Result := vS;
end;

{ selection + actions }

function TsgcFSearchBarForm.DoSelRow(out Row: TsgcFSearchEngineRow): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(FRows) = 0 then
    Exit;
  i := lstResults.ItemIndex;
  if (i < 0) or (i > High(FRows)) then
    Exit;
  Row := FRows[i];
  Result := True;
end;

procedure TsgcFSearchBarForm.DoMoveSel(Delta: Integer);
var
  i: Integer;
begin
  if Length(FRows) = 0 then
    Exit;
  i := lstResults.ItemIndex;
  if i < 0 then
    i := 0
  else
    i := EnsureRange(i + Delta, 0, High(FRows));
  lstResults.ItemIndex := i;
end;

procedure TsgcFSearchBarForm.DoOpenSelected;
var
  vRow: TsgcFSearchEngineRow;
begin
  if not DoSelRow(vRow) then
    Exit;
  ShellExecute(0, 'open', PChar(vRow.Path), nil, PChar(ExtractFileDir(vRow.Path)
    ), SW_SHOWNORMAL);
  if FEngine <> nil then
    FEngine.RecordUse(vRow.Path, fsukOpen);
  HideBar; // saves the history
end;

procedure TsgcFSearchBarForm.DoRevealSelected;
var
  vRow: TsgcFSearchEngineRow;
  vPidl: Pointer;
begin
  if not DoSelRow(vRow) then
    Exit;
  vPidl := sgcILCreateFromPath(PChar(vRow.Path));
  if vPidl <> nil then
    try
      sgcSHOpenFolderAndSelectItems(vPidl, 0, nil, 0);
    finally
      sgcILFree(vPidl);
    end
  else
    ShellExecute(0, 'open', 'explorer.exe',
      PChar('/select,"' + vRow.Path + '"'), nil, SW_SHOWNORMAL);
  if FEngine <> nil then
    FEngine.RecordUse(vRow.Path, fsukOpen);
  HideBar;
end;

procedure TsgcFSearchBarForm.DoCopyFile;
var
  vRow: TsgcFSearchEngineRow;
  vDrop, vEffect: HGLOBAL;
  vP: PByte;
begin
  if not DoSelRow(vRow) then
    Exit;
  vDrop := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT,
    SizeOf(TsgcFSearchBarDropFiles) + (Length(vRow.Path) + 2) * SizeOf(Char));
  vEffect := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, SizeOf(DWORD));
  try
    if (vDrop = 0) or (vEffect = 0) then
      Exit;
    vP := GlobalLock(vDrop);
    PsgcFSearchBarDropFiles(vP)^.pFiles := SizeOf(TsgcFSearchBarDropFiles);
    PsgcFSearchBarDropFiles(vP)^.fWide := True;
    Move(PChar(vRow.Path)^, (vP + SizeOf(TsgcFSearchBarDropFiles))^,
      Length(vRow.Path) * SizeOf(Char));
    GlobalUnlock(vDrop);
    PDWORD(GlobalLock(vEffect))^ := CS_DROPEFFECT_COPY;
    GlobalUnlock(vEffect);
    try
      Clipboard.Open;
      try
        Clipboard.SetAsHandle(CF_HDROP, vDrop);
        vDrop := 0;
        Clipboard.SetAsHandle
          (RegisterClipboardFormat('Preferred DropEffect'), vEffect);
        vEffect := 0;
      finally
        Clipboard.Close;
      end;
    except
      // clipboard busy
      Exit;
    end;
  finally
    if vDrop <> 0 then
      GlobalFree(vDrop);
    if vEffect <> 0 then
      GlobalFree(vEffect);
  end;
  if FEngine <> nil then
    FEngine.RecordUse(vRow.Path, fsukCopy);
  DoAddHistory(edtSearch.Text);
end;

procedure TsgcFSearchBarForm.DoCopyPath;
var
  vRow: TsgcFSearchEngineRow;
begin
  if not DoSelRow(vRow) then
    Exit;
  try
    Clipboard.AsText := vRow.Path;
  except
    // clipboard busy
    Exit;
  end;
  DoAddHistory(edtSearch.Text);
end;

procedure TsgcFSearchBarForm.DoRowMenuClick(Sender: TObject);
begin
  case TMenuItem(Sender).Tag of
    1:
      DoOpenSelected;
    2:
      DoRevealSelected;
    3:
      DoCopyFile;
    4:
      DoCopyPath;
  end;
end;

{ keys }

procedure TsgcFSearchBarForm.edtSearchChange(Sender: TObject);
begin
  if FInternal then
    Exit;
  if not FInHistory then
    FHistoryPos := -1;
  pbChips.Invalidate;
  DoStartSearch(False);
end;

procedure TsgcFSearchBarForm.edtSearchKeyDown(Sender: TObject; var Key: Word;
Shift: TShiftState);
begin
  case Key of
    VK_UP:
      begin
        Key := 0;
        if DoHistoryActive then
          DoHistoryStep(1)
        else
          DoMoveSel(-1);
      end;
    VK_DOWN:
      begin
        Key := 0;
        if (FHistoryPos >= 0) and DoHistoryActive then
          DoHistoryStep(-1)
        else
          DoMoveSel(1);
      end;
    VK_PRIOR:
      begin
        Key := 0;
        DoMoveSel(-CS_BAR_ROWS);
      end;
    VK_NEXT:
      begin
        Key := 0;
        DoMoveSel(CS_BAR_ROWS);
      end;
    VK_RETURN:
      begin
        Key := 0;
        FSuppressChar := True;
        if ssCtrl in Shift then
          DoRevealSelected
        else
          DoOpenSelected;
      end;
    VK_ESCAPE:
      begin
        Key := 0;
        HideBar;
      end;
    Ord('C'):
      if (ssCtrl in Shift) and not(ssAlt in Shift) then
      begin
        if ssShift in Shift then
        begin
          Key := 0;
          FSuppressChar := True;
          DoCopyPath;
        end
        else if edtSearch.SelLength = 0 then
        begin
          Key := 0;
          FSuppressChar := True;
          DoCopyFile;
        end;
      end;
  end;
end;

procedure TsgcFSearchBarForm.edtSearchKeyPress(Sender: TObject; var Key: Char);
begin
  if FSuppressChar then
  begin
    FSuppressChar := False;
    Key := #0;
  end
  else if (Key = #13) or (Key = #10) or (Key = #27) or (Key = #9) then
    Key := #0;
end;

procedure TsgcFSearchBarForm.DoTabKey;
var
  vS, vTok, vPath: string;
  vStart, vEnd: Integer;
begin
  vS := edtSearch.Text;
  vStart := edtSearch.SelStart;
  vEnd := vStart;
  while (vStart > 0) and (vS[vStart] <> ' ') do
    Dec(vStart);
  while (vEnd < Length(vS)) and (vS[vEnd + 1] <> ' ') do
    Inc(vEnd);
  vTok := Copy(vS, vStart + 1, vEnd - vStart);
  if not(SameText(vTok, 'in:') or SameText(vTok, 'path:')) then
    Exit;
  vPath := DoPickFolder('');
  if vPath = '' then
    Exit;
  if Pos(' ', vPath) > 0 then
    vPath := '"' + vPath + '"';
  edtSearch.SelStart := vEnd;
  edtSearch.SelLength := 0;
  edtSearch.SelText := vPath;
end;

function TsgcFSearchBarForm.DoPickFolder(const Initial: string): string;
var
  vDlg: TFileOpenDialog;
begin
  Result := '';
  vDlg := TFileOpenDialog.Create(nil);
  try
    vDlg.Options := [fdoPickFolders, fdoForceFileSystem, fdoPathMustExist];
    vDlg.Title := 'Choose a folder';
    if (Initial <> '') and DirectoryExists(Initial) then
      vDlg.DefaultFolder := Initial;
    FDialogOpen := True;
    try
      if vDlg.Execute(Handle) then
        Result := vDlg.FileName;
    finally
      FDialogOpen := False;
    end;
  finally
    vDlg.Free;
  end;
  if FShown then
  begin
    DoForceForeground;
    if edtSearch.CanFocus then
      edtSearch.SetFocus;
  end;
end;

{ history }

procedure TsgcFSearchBarForm.DoEnsureHistory;
var
  vV: TJSONValue;
  i: Integer;
  vS: string;
begin
  if FHistoryLoaded then
    Exit;
  FHistoryLoaded := True;
  FHistory.Clear;
  if (FHistoryFileName = '') or not FileExists(FHistoryFileName) then
    Exit;
  try
    vV := TJSONObject.ParseJSONValue(TFile.ReadAllText(FHistoryFileName,
      TEncoding.UTF8));
    try
      if vV is TJSONArray then
        for i := 0 to TJSONArray(vV).Count - 1 do
          if TJSONArray(vV).Items[i] is TJSONString then
          begin
            vS := Trim(TJSONArray(vV).Items[i].Value);
            if (vS <> '') and (FHistory.IndexOf(vS) < 0) and
              (FHistory.Count < CS_HISTORY_MAX) then
              FHistory.Add(vS);
          end;
    finally
      vV.Free;
    end;
  except
    FHistory.Clear;
  end;
end;

procedure TsgcFSearchBarForm.DoSaveHistory;
var
  vA: TJSONArray;
  vS: string;
  i: Integer;
begin
  if FHistoryFileName = '' then
    Exit;
  vA := TJSONArray.Create;
  try
    for i := 0 to FHistory.Count - 1 do
      vA.Add(FHistory[i]);
    vS := vA.ToJSON;
  finally
    vA.Free;
  end;
  try
    ForceDirectories(ExtractFileDir(FHistoryFileName));
    TFile.WriteAllBytes(FHistoryFileName, TEncoding.UTF8.GetBytes(vS));
  except
    // history is a convenience, never fail on it
  end;
end;

procedure TsgcFSearchBarForm.DoAddHistory(const Text: string);
var
  vS: string;
  i: Integer;
begin
  vS := Trim(Text);
  if vS = '' then
    Exit;
  DoEnsureHistory;
  i := FHistory.IndexOf(vS);
  if i = 0 then
    Exit;
  if i > 0 then
    FHistory.Delete(i);
  FHistory.Insert(0, vS);
  while FHistory.Count > CS_HISTORY_MAX do
    FHistory.Delete(FHistory.Count - 1);
  FHistoryPos := -1;
  DoSaveHistory;
end;

function TsgcFSearchBarForm.DoHistoryActive: Boolean;
begin
  DoEnsureHistory;
  Result := (edtSearch.Text = '') or
    ((FHistoryPos >= 0) and (FHistoryPos < FHistory.Count) and
    (edtSearch.Text = FHistory[FHistoryPos]));
end;

procedure TsgcFSearchBarForm.DoHistoryStep(Dir: Integer);
var
  vNew: Integer;
begin
  DoEnsureHistory;
  if edtSearch.Text = '' then
    FHistoryPos := -1;
  vNew := FHistoryPos + Dir;
  if vNew >= FHistory.Count then
    Exit;
  FInHistory := True;
  try
    if vNew < 0 then
    begin
      FHistoryPos := -1;
      edtSearch.Text := '';
    end
    else
    begin
      FHistoryPos := vNew;
      edtSearch.Text := FHistory[vNew];
    end;
  finally
    FInHistory := False;
  end;
  edtSearch.SelStart := Length(edtSearch.Text);
end;

{ chips }

function TsgcFSearchBarForm.DoChipValue(Kind: TsgcFSearchBarChip): string;
begin
  Result := StringReplace(sgcFSearchQueryGetFilter(edtSearch.Text,
    CS_CHIP_KEYS[Kind]), '"', '', [rfReplaceAll]);
end;

function TsgcFSearchBarForm.DoChipCaption(Kind: TsgcFSearchBarChip;
out Active: Boolean): string;
var
  vV, vS, vName: string;
  vParts: TArray<string>;
  i: Integer;
begin
  vV := DoChipValue(Kind);
  Active := vV <> '';
  if not Active then
    Exit(CS_CHIP_NAMES[Kind]);
  case Kind of
    fsbcType:
      begin
        vParts := vV.Split([',']);
        vS := '';
        for i := 0 to High(vParts) do
          if vParts[i] <> '' then
          begin
            if vS <> '' then
              vS := vS + ', ';
            vS := vS + sgcBarOptionCaption(Kind, vParts[i]);
          end;
      end;
    fsbcFolder:
      begin
        vName := ExtractFileName(ExcludeTrailingPathDelimiter(vV));
        if vName = '' then
          vName := vV;
        if Length(vName) > 28 then
          vName := Copy(vName, 1, 25) + '...';
        vS := 'In ' + vName;
      end;
    fsbcSort:
      vS := 'Sort: ' + sgcBarOptionCaption(Kind, vV);
  else
    vS := sgcBarOptionCaption(Kind, vV);
  end;
  Result := vS + ' ' + CS_CLOSE_MARK;
end;

procedure TsgcFSearchBarForm.DoApplyChip(Kind: TsgcFSearchBarChip;
const Value: string);
var
  vT: string;
begin
  if Value = '' then
    vT := sgcFSearchQueryRemoveFilter(edtSearch.Text, CS_CHIP_KEYS[Kind])
  else
    vT := sgcFSearchQuerySetFilter(edtSearch.Text, CS_CHIP_KEYS[Kind], Value);
  if vT <> edtSearch.Text then
    edtSearch.Text := vT; // OnChange: chips repaint + search
  edtSearch.SelStart := Length(vT);
end;

procedure TsgcFSearchBarForm.DoChipPopup(Kind: TsgcFSearchBarChip);
var
  vCur: string;
  vCaps, vVals, vCurList: TArray<string>;
  i: Integer;
  vPt: TPoint;

  procedure AddItem(const aCaption, aValue: string; aChecked: Boolean);
  var
    vItem: TMenuItem;
  begin
    vItem := TMenuItem.Create(FChipMenu);
    vItem.Caption := aCaption;
    if aCaption <> '-' then
    begin
      FChipValues := FChipValues + [aValue];
      vItem.Tag := High(FChipValues);
      vItem.RadioItem := aValue <> CS_REMOVE;
      vItem.Checked := aChecked;
      vItem.OnClick := DoChipItemClick;
    end;
    FChipMenu.Items.Add(vItem);
  end;

  function InList(const aValue: string): Boolean;
  var
    j: Integer;
  begin
    for j := 0 to High(vCurList) do
      if SameText(vCurList[j], aValue) then
        Exit(True);
    Result := False;
  end;

begin
  FChipKind := Kind;
  FChipMenu.Items.Clear;
  FChipValues := nil;
  vCur := DoChipValue(Kind);
  if Kind = fsbcType then
    vCurList := vCur.Split([','])
  else
    vCurList := [vCur];
  if Kind = fsbcFolder then
    AddItem('Choose folder...', CS_PICK, False)
  else
  begin
    sgcBarChipOptions(Kind, vCaps, vVals);
    for i := 0 to High(vVals) do
      AddItem(vCaps[i], vVals[i], InList(vVals[i]));
  end;
  if vCur <> '' then
  begin
    AddItem('-', '', False);
    AddItem('Remove filter', CS_REMOVE, False);
  end;
  vPt := pbChips.ClientToScreen(Point(FChipRects[Kind].Left,
    FChipRects[Kind].Bottom + ScaleValue(2)));
  FMenuOpen := True;
  try
    FChipMenu.Popup(vPt.X, vPt.Y);
  finally
    FMenuOpen := False;
  end;
end;

procedure TsgcFSearchBarForm.DoChipItemClick(Sender: TObject);
var
  i: Integer;
  vV, vPath: string;
begin
  i := TMenuItem(Sender).Tag;
  if (i < 0) or (i > High(FChipValues)) then
    Exit;
  vV := FChipValues[i];
  if vV = CS_PICK then
  begin
    vPath := DoPickFolder(DoChipValue(fsbcFolder));
    if vPath <> '' then
      DoApplyChip(fsbcFolder, vPath);
  end
  else if vV = CS_REMOVE then
    DoApplyChip(FChipKind, '')
  else
    DoApplyChip(FChipKind, vV);
end;

procedure TsgcFSearchBarForm.pbChipsPaint(Sender: TObject);
var
  C: TCanvas;
  k: TsgcFSearchBarChip;
  vX, vW, vH: Integer;
  vCap: string;
  vActive: Boolean;
  vR: TRect;
begin
  C := pbChips.Canvas;
  C.Brush.style := bsSolid;
  C.Brush.Color := FPal.Back;
  C.FillRect(pbChips.ClientRect);
  C.Font.Name := CS_FONT;
  C.Font.Height := -ScaleValue(12);
  C.Font.style := [];
  C.Pen.Width := 1;
  vH := pbChips.Height;
  vX := 0;
  for k := Low(TsgcFSearchBarChip) to High(TsgcFSearchBarChip) do
  begin
    vCap := DoChipCaption(k, vActive);
    vW := C.TextWidth(vCap) + ScaleValue(24);
    vR := System.Types.Rect(vX, 0, vX + vW, vH);
    FChipRects[k] := vR;
    C.Brush.style := bsSolid;
    if vActive then
    begin
      C.Brush.Color := FPal.ChipActive;
      C.Pen.Color := FPal.ChipActive;
      C.Font.Color := FPal.ChipActiveText;
    end
    else
    begin
      C.Brush.Color := FPal.Chip;
      C.Pen.Color := FPal.ChipBorder;
      C.Font.Color := FPal.Text;
    end;
    C.RoundRect(vR.Left, vR.Top, vR.Right, vR.Bottom, vH, vH);
    C.Brush.style := bsClear;
    DrawText(C.Handle, PChar(vCap), Length(vCap), vR, DT_SINGLELINE or
      DT_CENTER or DT_VCENTER or DT_NOPREFIX);
    vX := vX + vW + ScaleValue(6);
  end;
  C.Brush.style := bsSolid;
end;

procedure TsgcFSearchBarForm.pbChipsMouseUp(Sender: TObject;
Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  k: TsgcFSearchBarChip;
  vActive: Boolean;
begin
  if Button <> mbLeft then
    Exit;
  for k := Low(TsgcFSearchBarChip) to High(TsgcFSearchBarChip) do
    if PtInRect(FChipRects[k], Point(X, Y)) then
    begin
      DoChipCaption(k, vActive);
      if vActive and (X >= FChipRects[k].Right - ScaleValue(22)) then
        DoApplyChip(k, '')
      else
        DoChipPopup(k);
      Exit;
    end;
end;

{ painting }

procedure TsgcFSearchBarForm.FormPaint(Sender: TObject);
var
  C: TCanvas;
  vR, vCx, vCy, vRr, vD: Integer;
begin
  C := Canvas;
  C.Brush.style := bsSolid;
  C.Brush.Color := FPal.Back;
  C.FillRect(ClientRect);
  C.Pen.Width := 1;
  C.Pen.Color := FPal.Border;
  C.Brush.Color := FPal.Box;
  vR := ScaleValue(14);
  C.RoundRect(FBoxRect.Left, FBoxRect.Top, FBoxRect.Right,
    FBoxRect.Bottom, vR, vR);
  // magnifier glyph
  vCx := FBoxRect.Left + ScaleValue(21);
  vCy := (FBoxRect.Top + FBoxRect.Bottom) div 2 - ScaleValue(2);
  vRr := ScaleValue(7);
  vD := Round(vRr * 0.7071);
  C.Pen.Color := FPal.Dim;
  C.Pen.Width := Max(1, ScaleValue(2));
  C.Brush.style := bsClear;
  C.Ellipse(vCx - vRr, vCy - vRr, vCx + vRr, vCy + vRr);
  C.MoveTo(vCx + vD, vCy + vD);
  C.LineTo(vCx + vD + ScaleValue(5), vCy + vD + ScaleValue(5));
  C.Pen.Width := 1;
  C.Brush.style := bsSolid;
end;

procedure TsgcFSearchBarForm.pbStatusPaint(Sender: TObject);
var
  C: TCanvas;
  vS: string;
  vErr: Boolean;
  vR: TRect;
  vW: Integer;
begin
  C := pbStatus.Canvas;
  C.Brush.style := bsSolid;
  C.Brush.Color := FPal.Back;
  C.FillRect(pbStatus.ClientRect);
  C.Font.Name := CS_FONT;
  C.Font.Height := -ScaleValue(11);
  C.Brush.style := bsClear;
  vR := pbStatus.ClientRect;
  // link, right aligned; the status text is clipped before it
  if FLinkHot then
    C.Font.style := [fsUnderline]
  else
    C.Font.style := [];
  C.Font.Color := FPal.Accent;
  vW := C.TextWidth(CS_LINK_CAPTION);
  FLinkRect := System.Types.Rect(vR.Right - vW, vR.Top, vR.Right, vR.Bottom);
  DrawText(C.Handle, PChar(CS_LINK_CAPTION), Length(CS_LINK_CAPTION), FLinkRect,
    DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX);
  vR.Right := FLinkRect.Left - ScaleValue(16);
  vS := DoStatusText(vErr);
  if (vS <> '') and (vR.Right > vR.Left) then
  begin
    C.Font.style := [];
    if vErr then
      C.Font.Color := FPal.Error
    else
      C.Font.Color := FPal.Dim;
    DrawText(C.Handle, PChar(vS), Length(vS), vR, DT_SINGLELINE or DT_VCENTER or
      DT_END_ELLIPSIS or DT_NOPREFIX);
  end;
  C.Brush.style := bsSolid;
end;

procedure TsgcFSearchBarForm.pbStatusMouseMove(Sender: TObject;
Shift: TShiftState; X, Y: Integer);
var
  vHot: Boolean;
begin
  vHot := PtInRect(FLinkRect, Point(X, Y));
  if vHot = FLinkHot then
    Exit;
  FLinkHot := vHot;
  if vHot then
    pbStatus.Cursor := crHandPoint
  else
    pbStatus.Cursor := crDefault;
  pbStatus.Invalidate;
end;

procedure TsgcFSearchBarForm.pbStatusMouseLeave(Sender: TObject);
begin
  if not FLinkHot then
    Exit;
  FLinkHot := False;
  pbStatus.Cursor := crDefault;
  pbStatus.Invalidate;
end;

procedure TsgcFSearchBarForm.pbStatusMouseUp(Sender: TObject;
Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button <> mbLeft) or not PtInRect(FLinkRect, Point(X, Y)) then
    Exit;
  ShellExecute(0, 'open', PChar(CS_LINK_URL), nil, nil, SW_SHOWNORMAL);
  HideBar;
end;

function TsgcFSearchBarForm.DoImageList(out Size: Integer): HIMAGELIST;
var
  vInfo: TSHFileInfo;
  vCx, vCy: Integer;
begin
  FillChar(vInfo, SizeOf(vInfo), 0);
  if ScaleValue(16) > 20 then
  begin
    if FImlLarge = 0 then
      FImlLarge := HIMAGELIST(SHGetFileInfo('file.txt', FILE_ATTRIBUTE_NORMAL,
        vInfo, SizeOf(vInfo), SHGFI_USEFILEATTRIBUTES or SHGFI_SYSICONINDEX));
    Result := FImlLarge;
  end
  else
  begin
    if FImlSmall = 0 then
      FImlSmall := HIMAGELIST(SHGetFileInfo('file.txt', FILE_ATTRIBUTE_NORMAL,
        vInfo, SizeOf(vInfo), SHGFI_USEFILEATTRIBUTES or SHGFI_SYSICONINDEX or
        SHGFI_SMALLICON));
    Result := FImlSmall;
  end;
  Size := 16;
  if (Result <> 0) and ImageList_GetIconSize(Result, vCx, vCy) then
    Size := vCx;
end;

function TsgcFSearchBarForm.DoIconIndex(const Row
  : TsgcFSearchEngineRow): Integer;
var
  vExt, vKey: string;
  vInfo: TSHFileInfo;
  vPerPath: Boolean;
  vFlags: UINT;
begin
  vPerPath := False;
  vExt := '';
  if Row.IsDir then
    vKey := '<dir>'
  else
  begin
    vExt := LowerCase(ExtractFileExt(Row.Name));
    vPerPath := (vExt = '.exe') or (vExt = '.lnk') or (vExt = '.ico') or
      (vExt = '.url');
    if vPerPath then
      vKey := LowerCase(Row.Path)
    else
      vKey := '*' + vExt;
  end;
  if FIcons.TryGetValue(vKey, Result) then
    Exit;
  Result := -1;
  vFlags := SHGFI_SYSICONINDEX or SHGFI_SMALLICON;
  FillChar(vInfo, SizeOf(vInfo), 0);
  if vPerPath and (SHGetFileInfo(PChar(Row.Path), 0, vInfo, SizeOf(vInfo),
    vFlags) <> 0) then
    Result := vInfo.iIcon
  else if Row.IsDir then
  begin
    if SHGetFileInfo('folder', FILE_ATTRIBUTE_DIRECTORY, vInfo, SizeOf(vInfo),
      vFlags or SHGFI_USEFILEATTRIBUTES) <> 0 then
      Result := vInfo.iIcon;
  end
  else if SHGetFileInfo(PChar('file' + vExt), FILE_ATTRIBUTE_NORMAL, vInfo,
    SizeOf(vInfo), vFlags or SHGFI_USEFILEATTRIBUTES) <> 0 then
    Result := vInfo.iIcon;
  if FIcons.Count >= CS_ICON_CACHE_MAX then
    FIcons.Clear;
  FIcons.AddOrSetValue(vKey, Result);
end;

function TsgcFSearchBarForm.DoDrawSpans(C: TCanvas; const R: TRect;
const S: string; HPos, HLen: Integer; Normal, Hl: TColor): Integer;
var
  vParts: array [0 .. 2] of string;
  vX, vW, i: Integer;
  vR: TRect;
begin
  if (HPos < 0) or (HLen <= 0) or (HPos >= Length(S)) then
  begin
    vParts[0] := S;
    vParts[1] := '';
    vParts[2] := '';
  end
  else
  begin
    HLen := Min(HLen, Length(S) - HPos);
    vParts[0] := Copy(S, 1, HPos);
    vParts[1] := Copy(S, HPos + 1, HLen);
    vParts[2] := Copy(S, HPos + HLen + 1, MaxInt);
  end;
  vX := R.Left;
  for i := 0 to 2 do
  begin
    if (vParts[i] = '') or (vX >= R.Right) then
      Continue;
    if i = 1 then
    begin
      C.Font.style := [fsBold];
      C.Font.Color := Hl;
    end
    else
    begin
      C.Font.style := [];
      C.Font.Color := Normal;
    end;
    vW := C.TextWidth(vParts[i]);
    vR := System.Types.Rect(vX, R.Top, Min(R.Right, vX + vW), R.Bottom);
    DrawText(C.Handle, PChar(vParts[i]), Length(vParts[i]), vR, DT_SINGLELINE or
      DT_VCENTER or DT_NOPREFIX or DT_END_ELLIPSIS);
    Inc(vX, vW);
  end;
  C.Font.style := [];
  Result := Min(vX, R.Right);
end;

procedure TsgcFSearchBarForm.lstResultsData(Control: TWinControl;
Index: Integer; var Data: string);
begin
  if (Index >= 0) and (Index < Length(FRows)) then
    Data := FRows[Index].Name
  else
    Data := '';
end;

procedure TsgcFSearchBarForm.lstResultsDrawItem(Control: TWinControl;
Index: Integer; aRect: TRect; State: TOwnerDrawState);
var
  C: TCanvas;
  vRow: TsgcFSearchEngineRow;
  vPad, vX, vIconSz, vIdx, vEnd, vW, vN, vPos, vLen, vCut: Integer;
  vR1, vR2, vRr: TRect;
  vS, vPre: string;
  vIml: HIMAGELIST;
begin
  C := lstResults.Canvas;
  C.Brush.style := bsSolid;
  if (Index < 0) or (Index >= Length(FRows)) then
  begin
    C.Brush.Color := FPal.Back;
    C.FillRect(aRect);
    Exit;
  end;
  vRow := FRows[Index];
  if odSelected in State then
    C.Brush.Color := FPal.Select
  else
    C.Brush.Color := FPal.Back;
  C.FillRect(aRect);
  if odSelected in State then
  begin
    C.Brush.Color := FPal.Accent;
    C.FillRect(System.Types.Rect(aRect.Left, aRect.Top + ScaleValue(10),
      aRect.Left + ScaleValue(3), aRect.Bottom - ScaleValue(10)));
  end;
  vPad := ScaleValue(10);
  vIml := DoImageList(vIconSz);
  vIdx := DoIconIndex(vRow);
  vX := aRect.Left + vPad + ScaleValue(4);
  if (vIml <> 0) and (vIdx >= 0) then
    ImageList_Draw(vIml, vIdx, C.Handle, vX,
      aRect.Top + (aRect.Height - vIconSz) div 2, ILD_TRANSPARENT);
  vX := vX + vIconSz + ScaleValue(10);
  vR1 := System.Types.Rect(vX, aRect.Top + ScaleValue(4), aRect.Right - vPad,
    aRect.Top + ScaleValue(24));
  vR2 := System.Types.Rect(vX, aRect.Top + ScaleValue(24), aRect.Right - vPad,
    aRect.Bottom - ScaleValue(4));
  C.Brush.style := bsClear;
  C.Font.Name := CS_FONT;
  // line 1: name with the matched span
  C.Font.Height := -ScaleValue(14);
  vEnd := DoDrawSpans(C, vR1, vRow.Name, vRow.MatchPos, vRow.MatchLen,
    FPal.Text, FPal.Accent);
  C.Font.Height := -ScaleValue(12);
  C.Font.style := [];
  C.Font.Color := FPal.Dim;
  vS := ExtractFileDir(vRow.Path);
  if vRow.IsContent then
  begin
    // folder after the name, line 2 = the matching line
    vRr := vR1;
    vRr.Left := vEnd + ScaleValue(12);
    if vRr.Left < vRr.Right then
      DrawText(C.Handle, PChar(vS), Length(vS), vRr, DT_SINGLELINE or
        DT_VCENTER or DT_NOPREFIX or DT_PATH_ELLIPSIS);
    vS := StringReplace(vRow.LineText, #9, ' ', [rfReplaceAll]);
    vS := StringReplace(vS, #13, ' ', [rfReplaceAll]);
    vS := StringReplace(vS, #10, ' ', [rfReplaceAll]);
    vN := 0;
    while (vN < Length(vS)) and (vS[vN + 1] = ' ') do
      Inc(vN);
    vPos := vRow.TextMatchPos;
    vLen := vRow.TextMatchLen;
    if vPos >= 0 then
      vPos := Max(0, vPos - vN);
    vS := Copy(vS, vN + 1, MaxInt);
    if vPos > 60 then
    begin
      vCut := vPos - 20;
      vS := '...' + Copy(vS, vCut + 1, MaxInt);
      vPos := vPos - vCut + 3;
    end;
    vS := Copy(vS, 1, 400);
    vPre := Format('line %d: ', [vRow.LineNo]);
    if vPos >= 0 then
      vPos := vPos + Length(vPre);
    DoDrawSpans(C, vR2, vPre + vS, vPos, vLen, FPal.Dim, FPal.Accent);
  end
  else
  begin
    // line 2: parent folder, right aligned size + modified date
    vPre := sgcBarSizeText(vRow.Size);
    if vRow.MTime > 0 then
    begin
      if vPre <> '' then
        vPre := vPre + '     ';
      vPre := vPre + FormatDateTime('ddddd t',
        sgcFSearchFileTimeToLocalDateTime(vRow.MTime));
    end;
    vW := 0;
    if vPre <> '' then
    begin
      vW := C.TextWidth(vPre);
      vRr := vR2;
      DrawText(C.Handle, PChar(vPre), Length(vPre), vRr, DT_SINGLELINE or
        DT_RIGHT or DT_VCENTER or DT_NOPREFIX);
    end;
    vRr := vR2;
    vRr.Right := vRr.Right - vW - ScaleValue(16);
    if vRr.Right > vRr.Left then
      DrawText(C.Handle, PChar(vS), Length(vS), vRr, DT_SINGLELINE or
        DT_VCENTER or DT_NOPREFIX or DT_PATH_ELLIPSIS);
  end;
  C.Brush.style := bsSolid;
  // the list draws an XOR focus rect after this handler: cancel it
  if odFocused in State then
    C.DrawFocusRect(aRect);
end;

procedure TsgcFSearchBarForm.lstResultsDblClick(Sender: TObject);
begin
  DoOpenSelected;
end;

procedure TsgcFSearchBarForm.lstResultsMouseUp(Sender: TObject;
Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
  vPt: TPoint;
begin
  if Button = mbRight then
  begin
    i := lstResults.ItemAtPos(Point(X, Y), True);
    if i >= 0 then
    begin
      lstResults.ItemIndex := i;
      vPt := lstResults.ClientToScreen(Point(X, Y));
      FMenuOpen := True;
      try
        FRowMenu.Popup(vPt.X, vPt.Y);
      finally
        FMenuOpen := False;
      end;
    end;
  end;
  if FShown and edtSearch.CanFocus then
    edtSearch.SetFocus;
end;

initialization

GInv := TFormatSettings.Invariant;

end.
