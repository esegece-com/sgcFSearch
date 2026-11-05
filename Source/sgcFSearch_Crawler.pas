{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Crawler;

{$I sgcVer.inc}
{$WARN SYMBOL_PLATFORM OFF} // TThreadPriority, Win64 only project
{ Folder crawler: worker threads open + list folders (I/O), the calling thread
  is the single writer that applies listings into the index (in batches under
  BeginWrite / EndWrite) and queues the subfolders. CrawlRoot / CrawlSubtree
  are synchronous: call them from a background thread, without holding the
  index lock. Folders are opened with NtOpenFile relative to the parent
  handle (kept open, ref-counted, until all its subfolders are opened), with
  a fallback to the full NT path. Work is taken LIFO (depth first) so few
  parent handles stay open. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  // sgc
  sgcFSearch_Types, sgcFSearch_NtApi, sgcFSearch_Index;

type
  TsgcFSearchCrawler = class
  private
    FCancelled: Boolean;
    FFoldersDone: Int64;
    FEntries: Int64;
    FErrors: Int64;
    FThreadCount: Integer;
    FPriority: TThreadPriority;
    FStartListed: Boolean;
    function DoRun(const aIndex: TsgcFSearchIndex; StartIdx: Integer;
      const StartPath: string; const Skip: TArray<string>;
      ThreadCount: Integer): Boolean;
  public
    constructor Create;

    /// Fixed drives as 'C:\', 'D:\' ... (GetLogicalDrives + DRIVE_FIXED).
    class function EnumFixedDrives: TArray<string>;
    /// Volume serial and file system name ('NTFS', 'ReFS', 'FAT32' ...) of
    /// the volume holding Path.
    class function GetVolumeInfo(const Path: string; out Serial: Cardinal;
      out FileSystem: string): Boolean;
    /// Opens and bulk lists one folder by full path (used by the live-update
    /// agent to re-list folders). fslsNotFound = folder gone,
    /// fslsAccessDenied = exists but cannot be listed.
    class function ListFolderByPath(const Path: string;
      out Items: TsgcFSearchListingItems): TsgcFSearchListStatus;

    /// Crawls a drive root or any folder into aIndex: adds (or reuses) the
    /// root and lists every folder below it. Folders already indexed are
    /// diffed with ApplyFolderListing, so a second call is a full rescan.
    /// Skip = full folder paths (case-insensitive) recorded with
    /// SGCFS_FLAG_SKIPPED and never opened. ThreadCount <= 0 uses the
    /// ThreadCount property. Returns the root number, -1 if RootPath cannot
    /// be opened. Synchronous.
    function CrawlRoot(const aIndex: TsgcFSearchIndex; const RootPath: string;
      const Skip: TArray<string>; ThreadCount: Integer = 0): Integer;
    /// Crawls one indexed folder and everything below it (for the
    /// NewFolders of ApplyFolderListing). False if FolderIdx is not a live
    /// folder or cannot be opened. Synchronous.
    function CrawlSubtree(const aIndex: TsgcFSearchIndex; FolderIdx: Integer;
      const Skip: TArray<string>): Boolean;

    /// Stops the running crawl as soon as possible (thread-safe).
    procedure Cancel;
    property Cancelled: Boolean read FCancelled;
    /// Progress of the current / last crawl, readable from any thread.
    property FoldersDone: Int64 read FFoldersDone;
    property Entries: Int64 read FEntries;
    property Errors: Int64 read FErrors;
    /// Worker threads (default 4).
    property ThreadCount: Integer read FThreadCount write FThreadCount;
    /// Priority of every worker thread the crawler creates (default
    /// tpLower, so a whole-drive crawl does not compete with the user's apps).
    property Priority: TThreadPriority read FPriority write FPriority;
  end;

implementation

uses
  System.SyncObjs, System.Generics.Collections, System.Generics.Defaults;

const
  CS_BATCH = 256; // results applied per write lock

type
  /// Open parent folder handle shared by the work items of its subfolders.
  TsgcFSearchCrawlHandle = class
  public
    Handle: THandle;
    RefCount: Integer;
    procedure Release;
  end;

  TsgcFSearchCrawlWork = record
    FolderIdx: Integer;
    NameId: Integer; // expected entry name / FileId when the result arrives
    FileId: UInt64;
    Path: string; // full Win32 path
    Name: string; // name relative to Parent
    Parent: TsgcFSearchCrawlHandle; // nil: open by full path
  end;

  TsgcFSearchCrawlResult = record
    FolderIdx: Integer;
    NameId: Integer;
    FileId: UInt64;
    Path: string;
    Status: TsgcFSearchListStatus;
    Items: TsgcFSearchListingItems;
    Handle: THandle;
  end;

  TsgcFSearchCrawlJob = class
  private
    FOwner: TsgcFSearchCrawler;
    FIndex: TsgcFSearchIndex;
    FSkip: TDictionary<string, Boolean>;
    FLock: TCriticalSection;
    FWork: TList<TsgcFSearchCrawlWork>;
    FResults: TList<TsgcFSearchCrawlResult>;
    FWorkSem: THandle;
    FResultEvent: TEvent;
    FStop: Boolean;
    FPending: Integer;
    FStartIdx: Integer;
    procedure DoPush(const aWork: TsgcFSearchCrawlWork);
    procedure DoProcess(var aResult: TsgcFSearchCrawlResult);
  public
    constructor Create(aOwner: TsgcFSearchCrawler; aIndex: TsgcFSearchIndex;
      const Skip: TArray<string>);
    destructor Destroy; override;
    procedure WorkerLoop;
    procedure Run(StartIdx: Integer; const StartPath: string;
      ThreadCount: Integer);
  end;

  TsgcFSearchCrawlWorker = class(TThread)
  private
    FJob: TsgcFSearchCrawlJob;
  protected
    procedure Execute; override;
  public
    constructor Create(aJob: TsgcFSearchCrawlJob);
  end;

function DoNormalizeSkip(const Path: string): string;
begin
  Result := StringReplace(Path, '/', '\', [rfReplaceAll]);
  if Result.StartsWith('\\?\') then
    Delete(Result, 1, 4);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    SetLength(Result, Length(Result) - 1);
end;

function DoJoinPath(const Path, Name: string): string; inline;
begin
  if (Path <> '') and (Path[Length(Path)] = '\') then
    Result := Path + Name
  else
    Result := Path + '\' + Name;
end;

{ TsgcFSearchCrawlHandle }

procedure TsgcFSearchCrawlHandle.Release;
begin
  if AtomicDecrement(RefCount) = 0 then
  begin
    CloseHandle(Handle);
    Free;
  end;
end;

{ TsgcFSearchCrawlWorker }

constructor TsgcFSearchCrawlWorker.Create(aJob: TsgcFSearchCrawlJob);
begin
  FJob := aJob;
  inherited Create(False);
  // the thread starts in AfterConstruction, so this runs before Execute
  Priority := aJob.FOwner.FPriority;
end;

procedure TsgcFSearchCrawlWorker.Execute;
begin
  FJob.WorkerLoop;
end;

{ TsgcFSearchCrawlJob }

constructor TsgcFSearchCrawlJob.Create(aOwner: TsgcFSearchCrawler;
  aIndex: TsgcFSearchIndex; const Skip: TArray<string>);
var
  i: Integer;
begin
  inherited Create;
  FOwner := aOwner;
  FIndex := aIndex;
  FSkip := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  for i := 0 to Length(Skip) - 1 do
    if Skip[i] <> '' then
      FSkip.AddOrSetValue(DoNormalizeSkip(Skip[i]), True);
  FLock := TCriticalSection.Create;
  FWork := TList<TsgcFSearchCrawlWork>.Create;
  FResults := TList<TsgcFSearchCrawlResult>.Create;
  FWorkSem := CreateSemaphore(nil, 0, MaxInt, nil);
  FResultEvent := TEvent.Create(nil, False, False, '');
end;

destructor TsgcFSearchCrawlJob.Destroy;
begin
  FResultEvent.Free;
  CloseHandle(FWorkSem);
  FResults.Free;
  FWork.Free;
  FLock.Free;
  FSkip.Free;
  inherited;
end;

procedure TsgcFSearchCrawlJob.DoPush(const aWork: TsgcFSearchCrawlWork);
begin
  FLock.Enter;
  try
    FWork.Add(aWork);
  finally
    FLock.Leave;
  end;
  Inc(FPending);
  ReleaseSemaphore(FWorkSem, 1, nil);
end;

procedure TsgcFSearchCrawlJob.WorkerLoop;
var
  vBuffer: Pointer;
  vWork: TsgcFSearchCrawlWork;
  vResult: TsgcFSearchCrawlResult;
  vStatus: NTSTATUS;
  vHandle: THandle;
  vErr: Cardinal;
  vHave: Boolean;
begin
  GetMem(vBuffer, SGCFS_LIST_BUFFER_SIZE);
  try
    while True do
    begin
      WaitForSingleObject(FWorkSem, INFINITE);
      if FStop then
        Break;
      vHave := False;
      FLock.Enter;
      try
        if FWork.Count > 0 then
        begin
          vWork := FWork.Last;
          FWork.Delete(FWork.Count - 1);
          vHave := True;
        end;
      finally
        FLock.Leave;
      end;
      if not vHave then
        Continue;
      vResult.FolderIdx := vWork.FolderIdx;
      vResult.NameId := vWork.NameId;
      vResult.FileId := vWork.FileId;
      vResult.Path := vWork.Path;
      vResult.Items := nil;
      vResult.Handle := INVALID_HANDLE_VALUE;
      if FOwner.FCancelled then
        vResult.Status := fslsError
      else
      begin
        vHandle := INVALID_HANDLE_VALUE;
        if vWork.Parent <> nil then
          vStatus := sgcFSearchOpenFolder(vWork.Parent.Handle,
            vWork.Name, vHandle)
        else
          vStatus := STATUS_OBJECT_NAME_INVALID;
        if (vStatus <> STATUS_SUCCESS) and (vStatus <> STATUS_ACCESS_DENIED) and
          (vStatus <> STATUS_OBJECT_NAME_NOT_FOUND) then
          vStatus := sgcFSearchOpenFolder(0, vWork.Path, vHandle);
        vResult.Status := sgcFSearchNtStatusToListStatus(vStatus);
        if vResult.Status = fslsOK then
        begin
          vErr := sgcFSearchListDirectory(vHandle, vResult.Items, vBuffer);
          if vErr = ERROR_SUCCESS then
            vResult.Handle := vHandle
          else
          begin
            CloseHandle(vHandle);
            vResult.Items := nil;
            if vErr = ERROR_ACCESS_DENIED then
              vResult.Status := fslsAccessDenied
            else
              vResult.Status := fslsError;
          end;
        end;
      end;
      if vWork.Parent <> nil then
        vWork.Parent.Release;
      vWork.Path := '';
      vWork.Name := '';
      FLock.Enter;
      try
        FResults.Add(vResult);
      finally
        FLock.Leave;
      end;
      vResult.Items := nil;
      vResult.Path := '';
      FResultEvent.SetEvent;
    end;
  finally
    FreeMem(vBuffer);
  end;
end;

procedure TsgcFSearchCrawlJob.DoProcess(var aResult: TsgcFSearchCrawlResult);
var
  vE: PsgcFSearchEntry;
  i, c, vCount: Integer;
  vChildren: TArray<TsgcFSearchCrawlWork>;
  vHolder: TsgcFSearchCrawlHandle;
  vPath: string;
begin
  Dec(FPending);
  Inc(FOwner.FFoldersDone);
  // the folder may have been removed / its slot reused by another writer
  // between our write locks
  if not FIndex.IsLive(aResult.FolderIdx) or
    (FIndex.EntryPtr(aResult.FolderIdx).NameId <> aResult.NameId) or
    ((FIndex.EntryPtr(aResult.FolderIdx).Flags and SGCFS_FLAG_DIR) = 0) or
    ((aResult.FileId <> 0) and (FIndex.EntryPtr(aResult.FolderIdx).FileId <>
    aResult.FileId)) then
  begin
    if aResult.Handle <> INVALID_HANDLE_VALUE then
      CloseHandle(aResult.Handle);
    Exit;
  end;
  case aResult.Status of
    fslsOK:
      ;
    fslsAccessDenied:
      begin
        FIndex.SetEntryFlag(aResult.FolderIdx, SGCFS_FLAG_DENIED, True);
        Inc(FOwner.FErrors);
        Exit;
      end;
  else
    begin
      if not FOwner.FCancelled then
        Inc(FOwner.FErrors);
      Exit;
    end;
  end;

  if aResult.FolderIdx = FStartIdx then
    FOwner.FStartListed := True;
  // apply the listing
  if FIndex.EntryPtr(aResult.FolderIdx).FirstChild < 0 then
  begin
    for i := 0 to Length(aResult.Items) - 1 do
      FIndex.AddChild(aResult.FolderIdx, aResult.Items[i]);
    FIndex.SetEntryFlag(aResult.FolderIdx, SGCFS_FLAG_DENIED, False);
  end
  else
    FIndex.ApplyFolderListing(aResult.FolderIdx, aResult.Items);
  Inc(FOwner.FEntries, Length(aResult.Items));
  aResult.Items := nil;

  // queue the subfolders
  vCount := 0;
  if not FOwner.FCancelled then
  begin
    c := FIndex.EntryPtr(aResult.FolderIdx).FirstChild;
    while c >= 0 do
    begin
      vE := FIndex.EntryPtr(c);
      if (vE.Flags and (SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE)) = SGCFS_FLAG_DIR
      then
      begin
        vPath := DoJoinPath(aResult.Path, FIndex.NameOf(c));
        if FSkip.ContainsKey(vPath) then
        begin
          if (vE.Flags and SGCFS_FLAG_SKIPPED) = 0 then
            FIndex.SetEntryFlag(c, SGCFS_FLAG_SKIPPED, True);
        end
        else
        begin
          if (vE.Flags and SGCFS_FLAG_SKIPPED) <> 0 then
            FIndex.SetEntryFlag(c, SGCFS_FLAG_SKIPPED, False);
          if vCount = Length(vChildren) then
            SetLength(vChildren, vCount * 2 + 16);
          vChildren[vCount].FolderIdx := c;
          vChildren[vCount].NameId := vE.NameId;
          vChildren[vCount].FileId := vE.FileId;
          vChildren[vCount].Path := vPath;
          vChildren[vCount].Name := FIndex.NameOf(c);
          vChildren[vCount].Parent := nil;
          Inc(vCount);
        end;
      end;
      c := FIndex.EntryPtr(c).NextSibling;
    end;
  end;
  if vCount = 0 then
  begin
    CloseHandle(aResult.Handle);
    Exit;
  end;
  vHolder := TsgcFSearchCrawlHandle.Create;
  vHolder.Handle := aResult.Handle;
  vHolder.RefCount := vCount;
  // push in reverse so the first child is taken first (LIFO)
  for i := vCount - 1 downto 0 do
  begin
    vChildren[i].Parent := vHolder;
    DoPush(vChildren[i]);
  end;
end;

procedure TsgcFSearchCrawlJob.Run(StartIdx: Integer; const StartPath: string;
  ThreadCount: Integer);
var
  vThreads: TArray<TThread>;
  vBatch, vTmp: TList<TsgcFSearchCrawlResult>;
  vWork: TsgcFSearchCrawlWork;
  vRes: TsgcFSearchCrawlResult;
  i, vPos, vEnd: Integer;
begin
  if ThreadCount < 1 then
    ThreadCount := 1;
  FStartIdx := StartIdx;
  FIndex.BeginRead;
  try
    vWork.FolderIdx := StartIdx;
    vWork.NameId := FIndex.EntryPtr(StartIdx).NameId;
    vWork.FileId := FIndex.EntryPtr(StartIdx).FileId;
  finally
    FIndex.EndRead;
  end;
  vWork.Path := StartPath;
  vWork.Name := '';
  vWork.Parent := nil;
  DoPush(vWork);
  SetLength(vThreads, ThreadCount);
  for i := 0 to ThreadCount - 1 do
    vThreads[i] := TsgcFSearchCrawlWorker.Create(Self);
  vBatch := TList<TsgcFSearchCrawlResult>.Create;
  try
    while FPending > 0 do
    begin
      FResultEvent.WaitFor(100);
      FLock.Enter;
      try
        vTmp := FResults;
        FResults := vBatch;
        vBatch := vTmp;
      finally
        FLock.Leave;
      end;
      vPos := 0;
      while vPos < vBatch.Count do
      begin
        vEnd := vPos + CS_BATCH;
        if vEnd > vBatch.Count then
          vEnd := vBatch.Count;
        FIndex.BeginWrite;
        try
          for i := vPos to vEnd - 1 do
          begin
            vRes := vBatch[i];
            DoProcess(vRes);
          end;
        finally
          FIndex.EndWrite;
        end;
        vPos := vEnd;
      end;
      vRes.Items := nil;
      vRes.Path := '';
      vBatch.Clear;
    end;
  finally
    FStop := True;
    ReleaseSemaphore(FWorkSem, ThreadCount, nil);
    for i := 0 to Length(vThreads) - 1 do
    begin
      vThreads[i].WaitFor;
      vThreads[i].Free;
    end;
    vBatch.Free;
  end;
end;

{ TsgcFSearchCrawler }

constructor TsgcFSearchCrawler.Create;
begin
  inherited Create;
  FThreadCount := 4;
  FPriority := tpLower;
end;

procedure TsgcFSearchCrawler.Cancel;
begin
  FCancelled := True;
end;

class function TsgcFSearchCrawler.EnumFixedDrives: TArray<string>;
var
  vMask: DWORD;
  i: Integer;
  vRoot: string;
begin
  Result := nil;
  vMask := GetLogicalDrives;
  for i := 0 to 25 do
    if (vMask and (DWORD(1) shl i)) <> 0 then
    begin
      vRoot := Char(Ord('A') + i) + ':\';
      if GetDriveType(PChar(vRoot)) = DRIVE_FIXED then
        Result := Result + [vRoot];
    end;
end;

class function TsgcFSearchCrawler.GetVolumeInfo(const Path: string;
  out Serial: Cardinal; out FileSystem: string): Boolean;
var
  vVolume: array [0 .. MAX_PATH] of Char;
  vFS: array [0 .. MAX_PATH] of Char;
  vMaxComp, vFlags: DWORD;
begin
  Serial := 0;
  FileSystem := '';
  Result := GetVolumePathName(PChar(Path), vVolume, Length(vVolume)) and
    GetVolumeInformation(vVolume, nil, 0, @Serial, vMaxComp, vFlags, vFS,
    Length(vFS));
  if Result then
    FileSystem := vFS;
end;

class function TsgcFSearchCrawler.ListFolderByPath(const Path: string;
  out Items: TsgcFSearchListingItems): TsgcFSearchListStatus;
var
  vHandle: THandle;
  vErr: Cardinal;
begin
  Items := nil;
  Result := sgcFSearchNtStatusToListStatus(sgcFSearchOpenFolder(0, Path,
    vHandle));
  if Result <> fslsOK then
    Exit;
  try
    vErr := sgcFSearchListDirectory(vHandle, Items);
  finally
    CloseHandle(vHandle);
  end;
  if vErr <> ERROR_SUCCESS then
  begin
    Items := nil;
    if vErr = ERROR_ACCESS_DENIED then
      Result := fslsAccessDenied
    else
      Result := fslsError;
  end;
end;

function TsgcFSearchCrawler.DoRun(const aIndex: TsgcFSearchIndex;
  StartIdx: Integer; const StartPath: string; const Skip: TArray<string>;
  ThreadCount: Integer): Boolean;
var
  vJob: TsgcFSearchCrawlJob;
begin
  FStartListed := False;
  vJob := TsgcFSearchCrawlJob.Create(Self, aIndex, Skip);
  try
    vJob.Run(StartIdx, StartPath, ThreadCount);
  finally
    vJob.Free;
  end;
  Result := FStartListed and not FCancelled;
end;

function TsgcFSearchCrawler.CrawlRoot(const aIndex: TsgcFSearchIndex;
  const RootPath: string; const Skip: TArray<string>;
  ThreadCount: Integer): Integer;
var
  vHandle: THandle;
  vInfo: TByHandleFileInformation;
  vFileId: UInt64;
  vMTime: Int64;
  vSerial: Cardinal;
  vRootIdx: Integer;
  vPath: string;
begin
  Result := -1;
  FCancelled := False;
  FFoldersDone := 0;
  FEntries := 0;
  FErrors := 0;
  if ThreadCount <= 0 then
    ThreadCount := FThreadCount;
  if sgcFSearchOpenFolder(0, RootPath, vHandle, True) <> STATUS_SUCCESS then
    Exit;
  try
    FillChar(vInfo, SizeOf(vInfo), 0);
    if GetFileInformationByHandle(vHandle, vInfo) then
    begin
      vFileId := (UInt64(vInfo.nFileIndexHigh) shl 32) or vInfo.nFileIndexLow;
      vMTime := Int64(vInfo.ftLastWriteTime);
      vSerial := vInfo.dwVolumeSerialNumber;
    end
    else
    begin
      vFileId := 0;
      vMTime := 0;
      vSerial := 0;
    end;
  finally
    CloseHandle(vHandle);
  end;
  aIndex.BeginWrite;
  try
    Result := aIndex.AddRoot(RootPath, vSerial, vFileId, vMTime);
    vRootIdx := aIndex.Root(Result).EntryIdx;
    vPath := aIndex.Root(Result).Path;
  finally
    aIndex.EndWrite;
  end;
  DoRun(aIndex, vRootIdx, vPath, Skip, ThreadCount);
end;

function TsgcFSearchCrawler.CrawlSubtree(const aIndex: TsgcFSearchIndex;
  FolderIdx: Integer; const Skip: TArray<string>): Boolean;
var
  vPath: string;
begin
  Result := False;
  FCancelled := False;
  FFoldersDone := 0;
  FEntries := 0;
  FErrors := 0;
  aIndex.BeginRead;
  try
    if not aIndex.IsLive(FolderIdx) or
      ((aIndex.EntryPtr(FolderIdx).Flags and (SGCFS_FLAG_DIR or
      SGCFS_FLAG_REPARSE)) <> SGCFS_FLAG_DIR) then
      Exit;
    vPath := aIndex.FullPath(FolderIdx);
  finally
    aIndex.EndRead;
  end;
  Result := DoRun(aIndex, FolderIdx, vPath, Skip, FThreadCount);
end;

end.
