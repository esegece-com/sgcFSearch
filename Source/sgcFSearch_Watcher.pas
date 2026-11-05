{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Watcher;

{$I sgcVer.inc}
{ Live updates of an index from file system notifications.

  TsgcFSearchWatcher runs one thread per index root (drive root or any
  folder) with an overlapped ReadDirectoryChangesW on the whole subtree.
  Every notification marks the folder that must be re-listed: the parent of
  the changed item (for a rename the old and the new parent). Pending folders
  are flushed after CS_QUIET_MS without notifications, or at most
  CS_MAX_DELAY_MS after the first one.

  TsgcFSearchFolderRefresher does the flush (also used by the USN journal
  catch-up): each folder is resolved with FindPath under the read lock (a
  missing folder walks up to the nearest indexed ancestor), listed with
  TsgcFSearchCrawler.ListFolderByPath with no lock held, diffed into the
  index under the write lock (ApplyFolderListing), then the new folders are
  crawled with CrawlSubtree (it takes the lock itself). A folder that is gone
  re-lists its parent. Folders of the skip list are never re-listed.

  A notification buffer overflow schedules a USN journal catch-up of the root
  (TsgcFSearchJournal.CatchUp, from the NextUsn stored in the index root),
  which falls back to a full rescan (CrawlRoot, a diff) when the journal
  cannot be used. Reading goes on meanwhile and overflows are coalesced: at
  most one catch-up per root every CS_CATCHUP_INTERVAL_MS, the first one at
  once. Folders of IgnorePaths (the app's own data folder) are not watched.

  The watcher never logs per change: the log file usually lives inside an
  indexed folder, so logging a change would produce another change. Only
  start / stop / overflow / errors are logged. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults,
  // sgc
  sgcFSearch_Types, sgcFSearch_Index, sgcFSearch_Crawler;

type
  /// Called from a watcher thread (not the main thread) after a flush that
  /// changed the index. Generation = index generation after the flush.
  TsgcFSearchChangedEvent = procedure(Sender: TObject; Generation: Int64)
    of object;
  /// Called from a watcher thread (not the main thread) after a flush.
  /// Removed = False: files added or changed, plus folders created or renamed
  /// / moved into place (their content is new). Removed = True: paths that
  /// no longer exist (files or folders: drop the path and everything below
  /// it). Not called for overflow catch-ups (OnChanged is).
  TsgcFSearchFilesChangedEvent = procedure(Sender: TObject;
    const Paths: TArray<string>; Removed: Boolean) of object;

  /// Totals of one TsgcFSearchFolderRefresher.RefreshFolders call.
  TsgcFSearchRefreshStats = record
    Folders: Integer; // folders listed and applied
    Added: Integer; // ApplyFolderListing totals
    Removed: Integer;
    Updated: Integer;
    Subtrees: Integer; // new folders crawled with CrawlSubtree
    Errors: Integer; // folders that could not be listed
  end;

  /// Re-lists folders into an index (shared by the watcher and the journal
  /// catch-up). One instance per thread; call without holding the index
  /// lock.
  TsgcFSearchFolderRefresher = class
  private
    FIndex: TsgcFSearchIndex;
    FSkip: TArray<string>;
    FSkipNorm: TArray<string>;
    FCrawler: TsgcFSearchCrawler;
    FDone: TDictionary<string, Boolean>;
    FCancelled: Boolean;
    function DoResolve(var Path: string): Boolean;
    procedure DoRefreshOne(const Path: string; const Queue: TList<string>;
      var Stats: TsgcFSearchRefreshStats);
  public
    constructor Create(const aIndex: TsgcFSearchIndex;
      const Skip: TArray<string>);
    destructor Destroy; override;
    /// True if Path is a skip folder or lies below one.
    function IsSkipped(const Path: string): Boolean;
    /// Re-lists the folders (full paths, duplicates allowed, processed in
    /// order). Missing folders walk up to the nearest indexed ancestor, gone
    /// folders re-list their parent, new folders are crawled.
    function RefreshFolders(const Paths: TArray<string>)
      : TsgcFSearchRefreshStats;
    /// Full rescan of a root (CrawlRoot, diffs against the index).
    function Rescan(RootNo: Integer): Boolean;
    /// Stops a running RefreshFolders / Rescan as soon as possible
    /// (thread-safe, final: create a new refresher afterwards).
    procedure Cancel;
    property SearchIndex: TsgcFSearchIndex read FIndex;
    property Skip: TArray<string> read FSkip;
  end;

  /// Keeps an index up to date while active. Create it after the initial
  /// crawl (or index load + journal catch-up), Start watches every root of
  /// the index at that moment.
  TsgcFSearchWatcher = class
  private
    FIndex: TsgcFSearchIndex;
    FSkip: TArray<string>;
    FStopEvent: TEvent;
    FThreads: TObjectList<TThread>;
    FActive: Boolean;
    FWatchedCount: Integer;
    FUseJournal: Boolean;
    FOnChanged: TsgcFSearchChangedEvent;
    FOnFilesChanged: TsgcFSearchFilesChangedEvent;
    FBufferSize: Integer;
    FIgnore: TArray<string>;
    FIgnoreNorm: TArray<string>;
    FCatchUps: Integer;
  public
    constructor Create(const aIndex: TsgcFSearchIndex;
      const Skip: TArray<string>);
    destructor Destroy; override;
    /// Starts one thread per index root; returns once every thread has
    /// armed its first ReadDirectoryChangesW (changes made after Start
    /// returns are seen). Call without holding the index lock.
    procedure Start;
    /// Stops and joins the threads (pending notifications are dropped),
    /// cancelling a running flush / catch-up. A thread still running after
    /// TimeoutMs (stuck in a file system call) is abandoned, never freed.
    procedure Stop(TimeoutMs: Cardinal = 5000);
    property Active: Boolean read FActive;
    /// Roots actually watched by the last Start.
    property WatchedCount: Integer read FWatchedCount;
    /// Overflow handling: True (default) = USN journal catch-up with rescan
    /// fallback, False = rescan.
    property UseJournal: Boolean read FUseJournal write FUseJournal;
    /// Size of each ReadDirectoryChangesW buffer in bytes (the kernel keeps
    /// one of the same size per root between two reads), set before Start.
    property BufferSize: Integer read FBufferSize write FBufferSize;
    /// Folders whose notifications are ignored (the app's own data folder:
    /// index saves and the log would feed changes back), set before Start.
    property IgnorePaths: TArray<string> read FIgnore write FIgnore;
    /// Overflow catch-ups run since Create.
    property CatchUps: Integer read FCatchUps;
    /// Watcher-thread events, set them before Start.
    property OnChanged: TsgcFSearchChangedEvent read FOnChanged
      write FOnChanged;
    property OnFilesChanged: TsgcFSearchFilesChangedEvent read FOnFilesChanged
      write FOnFilesChanged;
  end;

implementation

uses
  // sgc
  sgcFSearch_Log, sgcFSearch_Journal;

const
  // whole volume watches: 64 KB overflowed within a second on a busy C:\
  CS_BUFFER_SIZE = 2 * 1024 * 1024;
  CS_FILE_LIST_DIRECTORY = $0001;
  CS_NOTIFY_FILTER = FILE_NOTIFY_CHANGE_FILE_NAME or
    FILE_NOTIFY_CHANGE_DIR_NAME or FILE_NOTIFY_CHANGE_SIZE or
    FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_ATTRIBUTES;
  CS_ACTION_ADDED = 1;
  CS_ACTION_REMOVED = 2;
  CS_ACTION_MODIFIED = 3;
  CS_ACTION_RENAMED_OLD = 4;
  CS_ACTION_RENAMED_NEW = 5;
  CS_ERROR_NOTIFY_ENUM_DIR = 1022;
  CS_QUIET_MS = 100;
  CS_MAX_DELAY_MS = 500;
  CS_START_TIMEOUT_MS = 5000;
  CS_SUBTREE_THREADS = 2;
  CS_RESCAN_THREADS = 4;
  CS_CATCHUP_INTERVAL_MS = 5000;
  CS_STOP_POLL_MS = 20;
  CS_IO_CANCEL_WAIT_MS = 2000;

type
  TsgcFSearchNotifyInfo = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD; // bytes
    FileName: array [0 .. 0] of WideChar;
  end;

  PsgcFSearchNotifyInfo = ^TsgcFSearchNotifyInfo;

  TsgcFSearchWatchThread = class(TThread)
  private
    FOwner: TsgcFSearchWatcher;
    FRootNo: Integer;
    FRootPath: string;
    FRefresher: TsgcFSearchFolderRefresher;
    FReady: TEvent;
    FWatching: Boolean;
    FDir: THandle;
    FIoEvent: THandle;
    FOverlapped: TOverlapped;
    FArmed: Boolean;
    FBuffers: array [0 .. 1] of TBytes;
    FCurrent: Integer;
    FPending: TDictionary<string, Byte>; // folder -> 0 new side, 1 old side
    FPendingFiles: TDictionary<string, Byte>; // item path -> last action
    FFirstTick: UInt64;
    FLastTick: UInt64;
    FBufferSize: Integer;
    FCatchUpDue: UInt64; // 0 = no catch-up scheduled
    FLastCatchUp: UInt64;
    function DoArm: Boolean;
    // Path is an IgnorePaths folder or lies below one (the folder itself is
    // reported as modified in its parent when its content changes)
    function DoIsIgnored(const Path: string): Boolean;
    procedure DoScheduleCatchUp;
    procedure DoParse(Buffer: PByte; Bytes: Cardinal);
    procedure DoFlush;
    procedure DoReportFiles;
    procedure DoOverflow;
  protected
    procedure Execute; override;
  public
    constructor Create(const aOwner: TsgcFSearchWatcher; RootNo: Integer;
      const RootPath: string);
    destructor Destroy; override;
  end;

function sgcReadDirectoryChangesW(hDirectory: THandle; lpBuffer: Pointer;
  nBufferLength: DWORD; bWatchSubtree: BOOL; dwNotifyFilter: DWORD;
  lpBytesReturned: PDWORD; lpOverlapped: POverlapped;
  lpCompletionRoutine: Pointer): BOOL; stdcall;
  external kernel32 name 'ReadDirectoryChangesW';
function sgcGetOverlappedResult(hFile: THandle; lpOverlapped: POverlapped;
  var lpNumberOfBytesTransferred: DWORD; bWait: BOOL): BOOL; stdcall;
  external kernel32 name 'GetOverlappedResult';
function sgcCancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL;
  stdcall; external kernel32 name 'CancelIoEx';

function DoNormalizePath(const Path: string): string;
begin
  Result := StringReplace(Path, '/', '\', [rfReplaceAll]);
  if Result.StartsWith('\\?\') then
    Delete(Result, 1, 4);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    SetLength(Result, Length(Result) - 1);
end;

function DoJoinPath(const Path, Name: string): string;
begin
  if (Path <> '') and (Path[Length(Path)] = '\') then
    Result := Path + Name
  else
    Result := Path + '\' + Name;
end;

/// Parent folder ('C:\a' -> 'C:\', 'C:\a\b' -> 'C:\a'), Path itself at the
/// top ('C:\'), '' when there is none.
function DoParentPath(const Path: string): string;
var
  i: Integer;
begin
  i := Length(Path);
  while (i > 0) and (Path[i] <> '\') do
    Dec(i);
  if i <= 0 then
    Exit('');
  if (i = 3) and (Path[2] = ':') then
  begin
    if Length(Path) = 3 then
      Result := Path
    else
      Result := Copy(Path, 1, 3);
    Exit;
  end;
  Result := Copy(Path, 1, i - 1);
  if (Length(Result) < 3) or (Result[Length(Result)] = '\') then
    Result := '';
end;

function DoLongPath(const Path: string): string;
var
  vBuf: array [0 .. 4 * MAX_PATH] of Char;
  vLen: DWORD;
begin
  vLen := GetLongPathName(PChar(Path), @vBuf[0], Length(vBuf));
  if (vLen > 0) and (vLen < DWORD(Length(vBuf))) then
    SetString(Result, PChar(@vBuf[0]), vLen)
  else
    Result := Path;
end;

{ TsgcFSearchFolderRefresher }

constructor TsgcFSearchFolderRefresher.Create(const aIndex: TsgcFSearchIndex;
  const Skip: TArray<string>);
var
  i, n: Integer;
begin
  inherited Create;
  FIndex := aIndex;
  FSkip := Copy(Skip);
  SetLength(FSkipNorm, Length(Skip));
  n := 0;
  for i := 0 to Length(Skip) - 1 do
    if Skip[i] <> '' then
    begin
      FSkipNorm[n] := DoNormalizePath(Skip[i]);
      Inc(n);
    end;
  SetLength(FSkipNorm, n);
  FCrawler := TsgcFSearchCrawler.Create;
  FCrawler.ThreadCount := CS_SUBTREE_THREADS;
  FDone := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
end;

destructor TsgcFSearchFolderRefresher.Destroy;
begin
  FDone.Free;
  FCrawler.Free;
  inherited;
end;

function TsgcFSearchFolderRefresher.IsSkipped(const Path: string): Boolean;
var
  i, vLen: Integer;
begin
  Result := False;
  for i := 0 to Length(FSkipNorm) - 1 do
  begin
    vLen := Length(FSkipNorm[i]);
    if (Length(Path) >= vLen) and
      (CompareStringOrdinal(PChar(Path), vLen, PChar(FSkipNorm[i]), vLen, 1)
      = CSTR_EQUAL) and ((Length(Path) = vLen) or (Path[vLen + 1] = '\') or
      (FSkipNorm[i][vLen] = '\')) then
      Exit(True);
  end;
end;

procedure TsgcFSearchFolderRefresher.Cancel;
begin
  FCancelled := True;
  FCrawler.Cancel;
end;

function TsgcFSearchFolderRefresher.DoResolve(var Path: string): Boolean;
var
  vIdx: Integer;
  vUp: string;
begin
  Result := False;
  FIndex.BeginRead;
  try
    vIdx := FIndex.FindPath(Path);
    while True do
    begin
      // a live folder that is not a reparse point: re-list it; a file or a
      // reparse point at that path: re-list its parent
      if (vIdx >= 0) and
        ((FIndex.EntryPtr(vIdx).Flags and (SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE)
        ) = SGCFS_FLAG_DIR) then
        Exit(True);
      vUp := DoParentPath(Path);
      if (vUp = '') or (vUp = Path) then
        Exit;
      Path := vUp;
      vIdx := FIndex.FindPath(Path);
    end;
  finally
    FIndex.EndRead;
  end;
end;

procedure TsgcFSearchFolderRefresher.DoRefreshOne(const Path: string;
  const Queue: TList<string>; var Stats: TsgcFSearchRefreshStats);
var
  vPath, vOrig, vUp: string;
  vItems: TsgcFSearchListingItems;
  vRes: TsgcFSearchApplyResult;
  vNew: TArray<string>;
  vSub: string;
  vIdx, i, n: Integer;
begin
  vPath := DoNormalizePath(Path);
  if (vPath = '') or FDone.ContainsKey(vPath) or IsSkipped(vPath) then
    Exit;
  FDone.Add(vPath, True);
  vOrig := vPath;
  if Pos('~', vPath) > 0 then
    vPath := DoLongPath(vPath);
  if not DoResolve(vPath) then
    Exit;
  if not SameText(vPath, vOrig) then
  begin
    if FDone.ContainsKey(vPath) then
      Exit;
    FDone.Add(vPath, True);
  end;
  case TsgcFSearchCrawler.ListFolderByPath(vPath, vItems) of
    fslsOK:
      begin
        n := 0;
        FIndex.BeginWrite;
        try
          vIdx := FIndex.FindPath(vPath);
          if (vIdx < 0) or
            ((FIndex.EntryPtr(vIdx).Flags and (SGCFS_FLAG_DIR or
            SGCFS_FLAG_REPARSE)) <> SGCFS_FLAG_DIR) then
            Exit;
          vRes := FIndex.ApplyFolderListing(vIdx, vItems);
          Inc(Stats.Folders);
          Inc(Stats.Added, vRes.Added);
          Inc(Stats.Removed, vRes.Removed);
          Inc(Stats.Updated, vRes.Updated);
          SetLength(vNew, Length(vRes.NewFolders));
          for i := 0 to Length(vRes.NewFolders) - 1 do
          begin
            vSub := FIndex.FullPath(vRes.NewFolders[i]);
            if IsSkipped(vSub) then
              FIndex.SetEntryFlag(vRes.NewFolders[i], SGCFS_FLAG_SKIPPED, True)
            else
            begin
              vNew[n] := vSub;
              Inc(n);
            end;
          end;
        finally
          FIndex.EndWrite;
        end;
        // CrawlSubtree takes the index lock itself
        for i := 0 to n - 1 do
        begin
          if FCancelled then
            Exit;
          FDone.AddOrSetValue(vNew[i], True);
          FIndex.BeginRead;
          try
            vIdx := FIndex.FindPath(vNew[i]);
          finally
            FIndex.EndRead;
          end;
          if (vIdx >= 0) and FCrawler.CrawlSubtree(FIndex, vIdx, FSkip) then
            Inc(Stats.Subtrees);
        end;
      end;
    fslsNotFound, fslsNotADirectory:
      begin
        vUp := DoParentPath(vPath);
        if (vUp <> '') and (vUp <> vPath) then
          Queue.Add(vUp);
      end;
    fslsAccessDenied:
      begin
        Inc(Stats.Errors);
        FIndex.BeginWrite;
        try
          vIdx := FIndex.FindPath(vPath);
          if vIdx >= 0 then
            FIndex.SetEntryFlag(vIdx, SGCFS_FLAG_DENIED, True);
        finally
          FIndex.EndWrite;
        end;
      end;
  else
    Inc(Stats.Errors);
  end;
end;

function TsgcFSearchFolderRefresher.RefreshFolders(const Paths: TArray<string>)
  : TsgcFSearchRefreshStats;
var
  vQueue: TList<string>;
  i: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  FDone.Clear;
  vQueue := TList<string>.Create;
  try
    vQueue.AddRange(Paths);
    i := 0;
    while (i < vQueue.Count) and not FCancelled do
    begin
      DoRefreshOne(vQueue[i], vQueue, Result);
      Inc(i);
    end;
  finally
    vQueue.Free;
    FDone.Clear;
  end;
end;

function TsgcFSearchFolderRefresher.Rescan(RootNo: Integer): Boolean;
var
  vPath: string;
begin
  Result := False;
  FIndex.BeginRead;
  try
    if (RootNo < 0) or (RootNo >= FIndex.RootCount) then
      Exit;
    vPath := FIndex.Root(RootNo).Path;
  finally
    FIndex.EndRead;
  end;
  if not FCancelled then
    Result := FCrawler.CrawlRoot(FIndex, vPath, FSkip, CS_RESCAN_THREADS) >= 0;
end;

{ TsgcFSearchWatchThread }

constructor TsgcFSearchWatchThread.Create(const aOwner: TsgcFSearchWatcher;
  RootNo: Integer; const RootPath: string);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FOwner := aOwner;
  FRootNo := RootNo;
  FRootPath := RootPath;
  FDir := INVALID_HANDLE_VALUE;
  FRefresher := TsgcFSearchFolderRefresher.Create(aOwner.FIndex, aOwner.FSkip);
  FReady := TEvent.Create(nil, True, False, '');
  FBufferSize := aOwner.FBufferSize;
  if FBufferSize < 4096 then
    FBufferSize := 4096;
  SetLength(FBuffers[0], FBufferSize);
  SetLength(FBuffers[1], FBufferSize);
  FPending := TDictionary<string, Byte>.Create(TIStringComparer.Ordinal);
  FPendingFiles := TDictionary<string, Byte>.Create(TIStringComparer.Ordinal);
end;

destructor TsgcFSearchWatchThread.Destroy;
begin
  inherited; // terminates and waits for Execute
  FPendingFiles.Free;
  FPending.Free;
  FReady.Free;
  FRefresher.Free;
end;

function TsgcFSearchWatchThread.DoArm: Boolean;
begin
  FillChar(FOverlapped, SizeOf(FOverlapped), 0);
  ResetEvent(FIoEvent);
  FOverlapped.hEvent := FIoEvent;
  Result := sgcReadDirectoryChangesW(FDir, @FBuffers[FCurrent][0], FBufferSize,
    True, CS_NOTIFY_FILTER, nil, @FOverlapped, nil);
  FArmed := Result;
  if not Result then
    sgcFSearchLog
      (Format('Watcher: ReadDirectoryChangesW failed on %s (error %d)',
      [FRootPath, GetLastError]));
end;

function TsgcFSearchWatchThread.DoIsIgnored(const Path: string): Boolean;
var
  i, vLen: Integer;
  vIgnore: string;
begin
  Result := False;
  for i := 0 to Length(FOwner.FIgnoreNorm) - 1 do
  begin
    vIgnore := FOwner.FIgnoreNorm[i];
    vLen := Length(vIgnore);
    if (vLen > 0) and (Length(Path) >= vLen) and
      (CompareStringOrdinal(PChar(Path), vLen, PChar(vIgnore), vLen, 1)
      = CSTR_EQUAL) and ((Length(Path) = vLen) or (Path[vLen + 1] = '\') or
      (vIgnore[vLen] = '\')) then
      Exit(True);
  end;
end;

procedure TsgcFSearchWatchThread.DoScheduleCatchUp;
var
  vNow: UInt64;
begin
  // one catch-up covers every overflow until it runs
  if FCatchUpDue <> 0 then
    Exit;
  vNow := GetTickCount64;
  if (FLastCatchUp <> 0) and (vNow < FLastCatchUp + CS_CATCHUP_INTERVAL_MS) then
    FCatchUpDue := FLastCatchUp + CS_CATCHUP_INTERVAL_MS
  else
    FCatchUpDue := vNow;
end;

procedure TsgcFSearchWatchThread.DoParse(Buffer: PByte; Bytes: Cardinal);
var
  vInfo: PsgcFSearchNotifyInfo;
  vOfs: Cardinal;
  vRel, vFull, vDir: string;
  vSide, vOld: Byte;
  vWantFiles: Boolean;
  vNow: UInt64;
begin
  vNow := GetTickCount64;
  if FPending.Count = 0 then
    FFirstTick := vNow;
  FLastTick := vNow;
  vWantFiles := Assigned(FOwner.FOnFilesChanged);
  vOfs := 0;
  while vOfs + 12 <= Bytes do
  begin
    vInfo := PsgcFSearchNotifyInfo(Buffer + vOfs);
    SetString(vRel, PChar(@vInfo.FileName[0]),
      vInfo.FileNameLength div SizeOf(Char));
    vFull := DoJoinPath(FRootPath, vRel);
    vDir := DoParentPath(vFull);
    if (vDir <> '') and not FRefresher.IsSkipped(vDir) and not DoIsIgnored(vFull)
    then
    begin
      if (vInfo.Action = CS_ACTION_REMOVED) or
        (vInfo.Action = CS_ACTION_RENAMED_OLD) then
        vSide := 1
      else
        vSide := 0;
      // new side first: a folder moved between folders is relinked (subtree
      // kept) when its new parent is listed before its old parent
      if FPending.TryGetValue(vDir, vOld) then
      begin
        if vSide < vOld then
          FPending[vDir] := vSide;
      end
      else
        FPending.Add(vDir, vSide);
      // a later MODIFIED must not hide that the item was added / renamed
      if vWantFiles and ((vInfo.Action <> CS_ACTION_MODIFIED) or
        not FPendingFiles.ContainsKey(vFull)) then
        FPendingFiles.AddOrSetValue(vFull, Byte(vInfo.Action));
    end;
    if vInfo.NextEntryOffset = 0 then
      Break;
    Inc(vOfs, vInfo.NextEntryOffset);
  end;
end;

procedure TsgcFSearchWatchThread.DoReportFiles;
var
  vPair: TPair<string, Byte>;
  vChanged, vRemoved: TArray<string>;
  nc, nr, vIdx: Integer;
  vIndex: TsgcFSearchIndex;
  vEvent: TsgcFSearchFilesChangedEvent;
begin
  vEvent := FOwner.FOnFilesChanged;
  if (FPendingFiles.Count = 0) or not Assigned(vEvent) then
  begin
    FPendingFiles.Clear;
    Exit;
  end;
  vIndex := FOwner.FIndex;
  SetLength(vChanged, FPendingFiles.Count);
  SetLength(vRemoved, FPendingFiles.Count);
  nc := 0;
  nr := 0;
  vIndex.BeginRead;
  try
    for vPair in FPendingFiles do
    begin
      vIdx := vIndex.FindPath(vPair.Key);
      if vIdx < 0 then
      begin
        vRemoved[nr] := vPair.Key;
        Inc(nr);
      end
      else if ((vIndex.EntryPtr(vIdx).Flags and SGCFS_FLAG_DIR) = 0) or
        (vPair.Value = CS_ACTION_ADDED) or (vPair.Value = CS_ACTION_RENAMED_NEW)
      then
      begin
        vChanged[nc] := vPair.Key;
        Inc(nc);
      end;
    end;
  finally
    vIndex.EndRead;
  end;
  FPendingFiles.Clear;
  SetLength(vChanged, nc);
  SetLength(vRemoved, nr);
  if nc > 0 then
    vEvent(FOwner, vChanged, False);
  if nr > 0 then
    vEvent(FOwner, vRemoved, True);
end;

procedure TsgcFSearchWatchThread.DoFlush;
var
  vPaths: TArray<string>;
  vPair: TPair<string, Byte>;
  vStats: TsgcFSearchRefreshStats;
  vSide: Byte;
  n: Integer;
  vEvent: TsgcFSearchChangedEvent;
begin
  try
    SetLength(vPaths, FPending.Count);
    n := 0;
    for vSide := 0 to 1 do
      for vPair in FPending do
        if vPair.Value = vSide then
        begin
          vPaths[n] := vPair.Key;
          Inc(n);
        end;
    FPending.Clear;
    vStats := FRefresher.RefreshFolders(vPaths);
    DoReportFiles;
    vEvent := FOwner.FOnChanged;
    if Assigned(vEvent) and
      ((vStats.Added + vStats.Removed + vStats.Updated + vStats.Subtrees) > 0)
    then
      vEvent(FOwner, FOwner.FIndex.Generation);
  except
    on E: Exception do
    begin
      FPending.Clear;
      FPendingFiles.Clear;
      sgcFSearchLog(Format('Watcher: flush error on %s, %s: %s',
        [FRootPath, E.ClassName, E.Message]));
    end;
  end;
end;

procedure TsgcFSearchWatchThread.DoOverflow;
var
  vRes: TsgcFSearchCatchUpResult;
  vEvent: TsgcFSearchChangedEvent;
begin
  FPending.Clear;
  FPendingFiles.Clear;
  AtomicIncrement(FOwner.FCatchUps);
  try
    if FOwner.FUseJournal then
    begin
      vRes := TsgcFSearchJournal.CatchUp(FRefresher, FRootNo);
      case vRes.Mode of
        fscmJournal:
          sgcFSearchLog(Format('Watcher: overflow on %s, journal catch-up, ' +
            '%d records, %d folders', [FRootPath, vRes.Records,
            vRes.Stats.Folders]));
        fscmRescan:
          sgcFSearchLog(Format('Watcher: overflow on %s, rescanned',
            [FRootPath]));
      else
        sgcFSearchLog(Format('Watcher: overflow on %s, catch-up failed',
          [FRootPath]));
      end;
    end
    else
    begin
      FRefresher.Rescan(FRootNo);
      sgcFSearchLog(Format('Watcher: overflow on %s, rescanned', [FRootPath]));
    end;
    vEvent := FOwner.FOnChanged;
    if Assigned(vEvent) then
      vEvent(FOwner, FOwner.FIndex.Generation);
  except
    on E: Exception do
      sgcFSearchLog(Format('Watcher: overflow error on %s, %s: %s',
        [FRootPath, E.ClassName, E.Message]));
  end;
end;

procedure TsgcFSearchWatchThread.Execute;
var
  vHandles: array [0 .. 1] of THandle;
  vWait, vTimeout, vBytes, vError: DWORD;
  vNow, vDue: UInt64;
  vFilled: Integer;
  vOk: Boolean;
begin
  NameThreadForDebugging('sgcFSearchWatcher');
  FDir := CreateFile(PChar(FRootPath), CS_FILE_LIST_DIRECTORY,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
  if FDir = INVALID_HANDLE_VALUE then
  begin
    sgcFSearchLog(Format('Watcher: cannot open %s (error %d)',
      [FRootPath, GetLastError]));
    FReady.SetEvent;
    Exit;
  end;
  FIoEvent := CreateEvent(nil, True, False, nil);
  try
    FCurrent := 0;
    FWatching := (FIoEvent <> 0) and DoArm;
    FReady.SetEvent;
    vHandles[0] := FOwner.FStopEvent.Handle;
    vHandles[1] := FIoEvent;
    while FWatching and not Terminated do
    begin
      vTimeout := INFINITE;
      if (FPending.Count > 0) or (FCatchUpDue <> 0) then
      begin
        vNow := GetTickCount64;
        vDue := High(UInt64);
        if FPending.Count > 0 then
        begin
          vDue := FLastTick + CS_QUIET_MS;
          if FFirstTick + CS_MAX_DELAY_MS < vDue then
            vDue := FFirstTick + CS_MAX_DELAY_MS;
        end;
        if (FCatchUpDue <> 0) and (FCatchUpDue < vDue) then
          vDue := FCatchUpDue;
        if vDue <= vNow then
          vTimeout := 0
        else
          vTimeout := DWORD(vDue - vNow);
      end;
      vWait := WaitForMultipleObjects(2, @vHandles, False, vTimeout);
      if vWait = WAIT_OBJECT_0 then
        Break;
      if vWait = WAIT_OBJECT_0 + 1 then
      begin
        vBytes := 0;
        vOk := sgcGetOverlappedResult(FDir, @FOverlapped, vBytes, False);
        if vOk then
          vError := 0
        else
          vError := GetLastError;
        FArmed := False;
        if vOk and (vBytes > 0) then
        begin
          // re-arm on the other buffer first, then parse the filled one
          vFilled := FCurrent;
          FCurrent := 1 - FCurrent;
          FWatching := DoArm;
          DoParse(@FBuffers[vFilled][0], vBytes);
        end
        else if (vOk and (vBytes = 0)) or (vError = CS_ERROR_NOTIFY_ENUM_DIR)
        then
        begin
          // keep reading: the catch-up runs from the loop, rate limited
          FWatching := DoArm;
          DoScheduleCatchUp;
        end
        else if vError = ERROR_OPERATION_ABORTED then
          Break
        else
        begin
          sgcFSearchLog(Format('Watcher: %s stopped (error %d)',
            [FRootPath, vError]));
          FWatching := False;
        end;
      end
      else if vWait <> WAIT_TIMEOUT then
      begin
        sgcFSearchLog(Format('Watcher: wait failed on %s (error %d)',
          [FRootPath, GetLastError]));
        Break;
      end;
      if FOwner.FStopEvent.WaitFor(0) = wrSignaled then
        Break;
      vNow := GetTickCount64;
      if (FCatchUpDue <> 0) and (vNow >= FCatchUpDue) then
      begin
        FCatchUpDue := 0;
        DoOverflow;
        FLastCatchUp := GetTickCount64;
      end
      else if (FPending.Count > 0) and ((vNow >= FLastTick + CS_QUIET_MS) or
        (vNow >= FFirstTick + CS_MAX_DELAY_MS)) then
        DoFlush;
    end;
  finally
    if FArmed then
    begin
      sgcCancelIoEx(FDir, @FOverlapped);
      // bounded: Stop must never hang on a read that does not complete
      if WaitForSingleObject(FIoEvent, CS_IO_CANCEL_WAIT_MS) = WAIT_OBJECT_0
      then
        sgcGetOverlappedResult(FDir, @FOverlapped, vBytes, False);
      FArmed := False;
    end;
    if FIoEvent <> 0 then
      CloseHandle(FIoEvent);
    CloseHandle(FDir);
    FDir := INVALID_HANDLE_VALUE;
    FReady.SetEvent;
  end;
end;

{ TsgcFSearchWatcher }

constructor TsgcFSearchWatcher.Create(const aIndex: TsgcFSearchIndex;
  const Skip: TArray<string>);
begin
  inherited Create;
  FIndex := aIndex;
  FSkip := Copy(Skip);
  FUseJournal := True;
  FBufferSize := CS_BUFFER_SIZE;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FThreads := TObjectList<TThread>.Create(True);
end;

destructor TsgcFSearchWatcher.Destroy;
begin
  Stop;
  FThreads.Free;
  FStopEvent.Free;
  inherited;
end;

procedure TsgcFSearchWatcher.Start;
var
  vRoots: TArray<string>;
  vThread: TsgcFSearchWatchThread;
  i: Integer;
begin
  if FActive then
    Exit;
  FStopEvent.ResetEvent;
  SetLength(FIgnoreNorm, Length(FIgnore));
  for i := 0 to Length(FIgnore) - 1 do
    FIgnoreNorm[i] := DoNormalizePath(FIgnore[i]);
  FIndex.BeginRead;
  try
    SetLength(vRoots, FIndex.RootCount);
    for i := 0 to Length(vRoots) - 1 do
      vRoots[i] := FIndex.Root(i).Path;
  finally
    FIndex.EndRead;
  end;
  FWatchedCount := 0;
  for i := 0 to Length(vRoots) - 1 do
    FThreads.Add(TsgcFSearchWatchThread.Create(Self, i, vRoots[i]));
  for i := 0 to FThreads.Count - 1 do
  begin
    vThread := TsgcFSearchWatchThread(FThreads[i]);
    vThread.FReady.WaitFor(CS_START_TIMEOUT_MS);
    if vThread.FWatching then
      Inc(FWatchedCount);
  end;
  FActive := True;
  sgcFSearchLog(Format('Watcher started, %d of %d roots watched',
    [FWatchedCount, Length(vRoots)]));
end;

procedure TsgcFSearchWatcher.Stop(TimeoutMs: Cardinal);
var
  vThread: TsgcFSearchWatchThread;
  vStart: UInt64;
  i: Integer;
begin
  if not FActive then
    Exit;
  FStopEvent.SetEvent;
  for i := 0 to FThreads.Count - 1 do
  begin
    TsgcFSearchWatchThread(FThreads[i]).FRefresher.Cancel;
    FThreads[i].Terminate;
  end;
  // CrawlRoot / CrawlSubtree clear the crawler's cancel flag when they start:
  // a single Cancel is lost when a catch-up starts its next crawl right after
  // it, so cancel again until the thread is gone, within TimeoutMs
  vStart := GetTickCount64;
  for i := 0 to FThreads.Count - 1 do
  begin
    vThread := TsgcFSearchWatchThread(FThreads[i]);
    while WaitForSingleObject(vThread.Handle, CS_STOP_POLL_MS) <>
      WAIT_OBJECT_0 do
    begin
      if GetTickCount64 - vStart >= TimeoutMs then
        Break;
      vThread.FRefresher.Cancel;
    end;
  end;
  for i := FThreads.Count - 1 downto 0 do
    if WaitForSingleObject(FThreads[i].Handle, 0) <> WAIT_OBJECT_0 then
    begin
      sgcFSearchLog(Format('Watcher: %s did not stop within %d ms, abandoned',
        [TsgcFSearchWatchThread(FThreads[i]).FRootPath, TimeoutMs]));
      FThreads.Extract(FThreads[i]);
    end;
  FThreads.Clear;
  FActive := False;
  FWatchedCount := 0;
  sgcFSearchLog('Watcher stopped');
end;

end.
