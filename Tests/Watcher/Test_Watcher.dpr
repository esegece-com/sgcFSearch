{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Watcher;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.SyncObjs, System.Generics.Collections,
  // sgc
  sgcFSearch_Types in '..\..\Source\sgcFSearch_Types.pas',
  sgcFSearch_NtApi in '..\..\Source\sgcFSearch_NtApi.pas',
  sgcFSearch_Index in '..\..\Source\sgcFSearch_Index.pas',
  sgcFSearch_Crawler in '..\..\Source\sgcFSearch_Crawler.pas',
  sgcFSearch_Config in '..\..\Source\sgcFSearch_Config.pas',
  sgcFSearch_Log in '..\..\Source\sgcFSearch_Log.pas',
  sgcFSearch_Watcher in '..\..\Source\sgcFSearch_Watcher.pas',
  sgcFSearch_Journal in '..\..\Source\sgcFSearch_Journal.pas';

const
  CS_DIRS = 10;
  CS_TOP_FILES = 10;
  CS_SUBS = 3;
  CS_SUB_FILES = 10;
  // 10 * 10 + 10 * 3 * 10 = 400 (SkipMe content is not indexed)
  CS_FILES = CS_DIRS * CS_TOP_FILES + CS_DIRS * CS_SUBS * CS_SUB_FILES;
  CS_TIMEOUT_MS = 3000;

type
  TTestEvents = class
  public
    Changed: Integer;
    Lock: TCriticalSection;
    ChangedPaths: TStringList;
    RemovedPaths: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure DoChanged(Sender: TObject; Generation: Int64);
    procedure DoFiles(Sender: TObject; const Paths: TArray<string>;
      Removed: Boolean);
    function Has(const Path: string; Removed: Boolean): Boolean;
  end;

var
  GChecks, GFails: Integer;
  GBase, GTree, GHome: string;
  GIndex: TsgcFSearchIndex;
  GSkip: TArray<string>;
  GLatencies: TList<Int64>;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(GChecks);
  if not Cond then
  begin
    Inc(GFails);
    Writeln('[FAIL] ', Msg);
  end;
end;

{ TTestEvents }

constructor TTestEvents.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  ChangedPaths := TStringList.Create;
  RemovedPaths := TStringList.Create;
end;

destructor TTestEvents.Destroy;
begin
  RemovedPaths.Free;
  ChangedPaths.Free;
  Lock.Free;
  inherited;
end;

procedure TTestEvents.DoChanged(Sender: TObject; Generation: Int64);
begin
  AtomicIncrement(Changed);
end;

procedure TTestEvents.DoFiles(Sender: TObject; const Paths: TArray<string>;
  Removed: Boolean);
var
  i: Integer;
begin
  Lock.Enter;
  try
    for i := 0 to Length(Paths) - 1 do
      if Removed then
        RemovedPaths.Add(Paths[i])
      else
        ChangedPaths.Add(Paths[i]);
  finally
    Lock.Leave;
  end;
end;

function TTestEvents.Has(const Path: string; Removed: Boolean): Boolean;
begin
  Lock.Enter;
  try
    if Removed then
      Result := RemovedPaths.IndexOf(Path) >= 0
    else
      Result := ChangedPaths.IndexOf(Path) >= 0;
  finally
    Lock.Leave;
  end;
end;

function TreeP(const Rel: string): string;
begin
  Result := GTree + '\' + Rel;
end;

procedure WriteBytes(const FileName: string; Count: Integer);
var
  vBytes: TBytes;
begin
  SetLength(vBytes, Count);
  if Count > 0 then
    FillChar(vBytes[0], Count, Ord('x'));
  TFile.WriteAllBytes(FileName, vBytes);
end;

procedure AppendBytes(const FileName: string; Count: Integer);
var
  vFS: TFileStream;
  vBytes: TBytes;
begin
  SetLength(vBytes, Count);
  FillChar(vBytes[0], Count, Ord('y'));
  vFS := TFileStream.Create(FileName, fmOpenReadWrite);
  try
    vFS.Seek(0, soEnd);
    vFS.WriteBuffer(vBytes[0], Count);
  finally
    vFS.Free;
  end;
end;

function EntryIdx(const Path: string): Integer;
begin
  GIndex.BeginRead;
  try
    Result := GIndex.FindPath(Path);
  finally
    GIndex.EndRead;
  end;
end;

function Indexed(const Path: string): Boolean;
begin
  Result := EntryIdx(Path) >= 0;
end;

function EntrySize(const Path: string): Int64;
var
  vIdx: Integer;
begin
  Result := -1;
  GIndex.BeginRead;
  try
    vIdx := GIndex.FindPath(Path);
    if vIdx >= 0 then
      Result := GIndex.EntryPtr(vIdx).Size;
  finally
    GIndex.EndRead;
  end;
end;

function EntryFlags(const Path: string): Word;
var
  vIdx: Integer;
begin
  Result := 0;
  GIndex.BeginRead;
  try
    vIdx := GIndex.FindPath(Path);
    if vIdx >= 0 then
      Result := GIndex.EntryPtr(vIdx).Flags;
  finally
    GIndex.EndRead;
  end;
end;

function EntryFileId(const Path: string): UInt64;
var
  vIdx: Integer;
begin
  Result := 0;
  GIndex.BeginRead;
  try
    vIdx := GIndex.FindPath(Path);
    if vIdx >= 0 then
      Result := GIndex.EntryPtr(vIdx).FileId;
  finally
    GIndex.EndRead;
  end;
end;

function IndexFileCount: Integer;
begin
  GIndex.BeginRead;
  try
    Result := GIndex.FileCount;
  finally
    GIndex.EndRead;
  end;
end;

function FileRefOf(const Path: string): UInt64;
var
  vHandle: THandle;
  vInfo: TByHandleFileInformation;
begin
  Result := 0;
  vHandle := CreateFile(PChar(Path), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or
    FILE_SHARE_DELETE, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if vHandle = INVALID_HANDLE_VALUE then
    Exit;
  try
    if GetFileInformationByHandle(vHandle, vInfo) then
      Result := (UInt64(vInfo.nFileIndexHigh) shl 32) or vInfo.nFileIndexLow;
  finally
    CloseHandle(vHandle);
  end;
end;

/// Polls Cond until True (3 s timeout), records and prints the latency.
procedure WaitUntil(const Name: string; const Cond: TFunc<Boolean>);
var
  vSW: TStopwatch;
  vOk: Boolean;
begin
  vSW := TStopwatch.StartNew;
  repeat
    vOk := Cond();
    if vOk then
      Break;
    Sleep(5);
  until vSW.ElapsedMilliseconds > CS_TIMEOUT_MS;
  if not vOk then
    vOk := Cond();
  if vOk then
  begin
    GLatencies.Add(vSW.ElapsedMilliseconds);
    Writeln(Format('  %-26s %5d ms', [Name, vSW.ElapsedMilliseconds]));
  end;
  Check(vOk, Name + ': not reflected in the index within 3 s');
end;

procedure BuildTree;
var
  d, s, f: Integer;
  vDir, vSub: string;
begin
  for d := 0 to CS_DIRS - 1 do
  begin
    vDir := TreeP('Dir_' + IntToStr(d));
    ForceDirectories(vDir);
    for f := 0 to CS_TOP_FILES - 1 do
      WriteBytes(vDir + '\File_' + IntToStr(f) + '.txt', 10 + f);
    for s := 0 to CS_SUBS - 1 do
    begin
      vSub := vDir + '\Sub_' + Char(Ord('A') + s);
      ForceDirectories(vSub);
      for f := 0 to CS_SUB_FILES - 1 do
        WriteBytes(vSub + '\File_' + IntToStr(f) + '.txt', 20 + f);
    end;
  end;
  ForceDirectories(TreeP('SkipMe'));
  WriteBytes(TreeP('SkipMe\Hidden_Away.txt'), 5);
end;

procedure TestLiveChanges(const aWatcher: TsgcFSearchWatcher;
  const aEvents: TTestEvents);
var
  vIdx: Integer;
  vSorted: TArray<Int64>;
begin
  Writeln('Live changes (latency until the index reflects the change):');
  // create file
  WriteBytes(TreeP('Dir_0\New_File.txt'), 100);
  WaitUntil('create file', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_0\New_File.txt'));
    end);

  // create folder with files (subtree crawled)
  ForceDirectories(TreeP('Dir_1\New_Folder\Inner'));
  WriteBytes(TreeP('Dir_1\New_Folder\A.txt'), 1);
  WriteBytes(TreeP('Dir_1\New_Folder\B.txt'), 2);
  WriteBytes(TreeP('Dir_1\New_Folder\Inner\C.txt'), 3);
  WaitUntil('create folder + files', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_1\New_Folder\A.txt')) and
        Indexed(TreeP('Dir_1\New_Folder\B.txt')) and
        Indexed(TreeP('Dir_1\New_Folder\Inner\C.txt'));
    end);

  // rename file
  Check(RenameFile(TreeP('Dir_0\New_File.txt'), TreeP('Dir_0\Renamed_File.txt')
    ), 'rename file failed');
  WaitUntil('rename file', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_0\Renamed_File.txt')) and
        not Indexed(TreeP('Dir_0\New_File.txt'));
    end);

  // rename folder, subtree kept (same entries)
  vIdx := EntryIdx(TreeP('Dir_2\Sub_A'));
  Check(vIdx >= 0, 'Dir_2\Sub_A indexed');
  Check(RenameFile(TreeP('Dir_2'), TreeP('Dir_2_Renamed')),
    'rename folder failed');
  WaitUntil('rename folder', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_2_Renamed\Sub_A\File_3.txt')) and
        not Indexed(TreeP('Dir_2'));
    end);
  Check(EntryIdx(TreeP('Dir_2_Renamed\Sub_A')) = vIdx,
    'rename folder: subtree entries kept');

  // move file between folders
  Check(MoveFile(PChar(TreeP('Dir_3\File_0.txt')),
    PChar(TreeP('Dir_4\Moved_File.txt'))), 'move file failed');
  WaitUntil('move file', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_4\Moved_File.txt')) and
        not Indexed(TreeP('Dir_3\File_0.txt'));
    end);

  // move folder between folders, subtree kept
  vIdx := EntryIdx(TreeP('Dir_9\Sub_B'));
  Check(MoveFile(PChar(TreeP('Dir_9\Sub_B')), PChar(TreeP('Dir_1\Sub_B_Moved'))
    ), 'move folder failed');
  WaitUntil('move folder', function: Boolean
    begin
      Result := Indexed(TreeP('Dir_1\Sub_B_Moved\File_7.txt')) and
        not Indexed(TreeP('Dir_9\Sub_B'));
    end);
  Check(EntryIdx(TreeP('Dir_1\Sub_B_Moved')) = vIdx,
    'move folder: subtree entries kept');

  // modify size
  AppendBytes(TreeP('Dir_5\File_1.txt'), 1000);
  WaitUntil('modify size', function: Boolean
    begin
      Result := EntrySize(TreeP('Dir_5\File_1.txt')) = 1011;
    end);

  // delete file
  Check(DeleteFile(TreeP('Dir_6\File_2.txt')), 'delete file failed');
  WaitUntil('delete file', function: Boolean
    begin
      Result := not Indexed(TreeP('Dir_6\File_2.txt'));
    end);

  // delete folder tree
  TDirectory.Delete(TreeP('Dir_7'), True);
  WaitUntil('delete folder tree', function: Boolean
    begin
      Result := not Indexed(TreeP('Dir_7'));
    end);
  // 400 + 1 + 3 - 1 - 40
  Check(IndexFileCount = CS_FILES + 1 + 3 - 1 - (CS_TOP_FILES + CS_SUBS *
    CS_SUB_FILES), Format('file count after changes: %d', [IndexFileCount]));

  // attribute change
  Check(SetFileAttributes(PChar(TreeP('Dir_8\File_3.txt')),
    FILE_ATTRIBUTE_HIDDEN), 'set attributes failed');
  WaitUntil('attribute change', function: Boolean
    begin
      Result := (EntryFlags(TreeP('Dir_8\File_3.txt')) and
        SGCFS_FLAG_HIDDEN) <> 0;
    end);

  // skip folder: never re-listed
  WriteBytes(TreeP('SkipMe\Ignored.txt'), 7);
  Sleep(700);
  Check(not Indexed(TreeP('SkipMe\Ignored.txt')), 'skip folder re-listed');
  Check((EntryFlags(TreeP('SkipMe')) and SGCFS_FLAG_SKIPPED) <> 0,
    'SkipMe flagged skipped');

  // events (fired after the index is updated, give them a moment)
  Sleep(300);
  Check(aEvents.Changed > 0, 'OnChanged fired');
  Check(aEvents.Has(TreeP('Dir_0\New_File.txt'), False),
    'OnFilesChanged reported the created file');
  Check(aEvents.Has(TreeP('Dir_6\File_2.txt'), True),
    'OnFilesChanged reported the deleted file');
  Check(aEvents.Has(TreeP('Dir_1\New_Folder'), False),
    'OnFilesChanged reported the created folder');
  Check(not aEvents.Has(TreeP('SkipMe\Ignored.txt'), False),
    'OnFilesChanged reported a skipped file');

  vSorted := GLatencies.ToArray;
  TArray.Sort<Int64>(vSorted);
  if Length(vSorted) > 0 then
    Writeln(Format('Latency: %d changes, median %d ms, max %d ms',
      [Length(vSorted), vSorted[Length(vSorted) div 2],
      vSorted[Length(vSorted) - 1]]));
end;

procedure TestJournal(const aWatcher: TsgcFSearchWatcher; RootNo: Integer);
var
  vId, vRootId, vDirFileId, vFileRef, vDirRef: UInt64;
  vNext, vFirst, vSnapNext, vEnd: Int64;
  vRecs: TsgcFSearchUsnRecords;
  vRes: TsgcFSearchCatchUpResult;
  vFound, i, vDirIdx: Integer;
  vNames: Boolean;
const
  CS_ACCESS: array [TsgcFSearchJournalAccess] of string = ('none',
    'root directory, no access rights', 'root directory, GENERIC_READ',
    'volume device, no access rights', 'volume device, GENERIC_READ');
begin
  aWatcher.Stop;
  if not TsgcFSearchJournal.Query(GTree, vId, vNext, vFirst) then
  begin
    Writeln(Format('Journal: NOT available unelevated (error %d), journal ' +
      'checks skipped', [TsgcFSearchJournal.LastError]));
    Exit;
  end;
  Writeln(Format('Journal: available unelevated via %s, id $%x, next %d, ' +
    'first %d', [CS_ACCESS[TsgcFSearchJournal.AccessMethod], vId, vNext,
    vFirst]));
  Check(vNext >= vFirst, 'journal NextUsn >= FirstUsn');
  Check(TsgcFSearchJournal.Snapshot(GIndex, RootNo), 'journal snapshot');
  GIndex.BeginRead;
  try
    vRootId := GIndex.Root(RootNo).JournalId;
    vSnapNext := GIndex.Root(RootNo).NextUsn;
  finally
    GIndex.EndRead;
  end;
  Check((vRootId = vId) and (vSnapNext >= vNext), 'snapshot stored in root');

  // changes while nothing watches
  WriteBytes(TreeP('Dir_0\Journal_New.txt'), 33);
  ForceDirectories(TreeP('Dir_3\J_Folder\J_Inner'));
  WriteBytes(TreeP('Dir_3\J_Folder\J1.txt'), 1);
  WriteBytes(TreeP('Dir_3\J_Folder\J_Inner\J2.txt'), 2);
  Check(DeleteFile(TreeP('Dir_5\File_2.txt')), 'journal: delete failed');
  Check(RenameFile(TreeP('Dir_6\File_3.txt'), TreeP('Dir_6\J_Renamed.txt')),
    'journal: rename failed');
  Check(RenameFile(TreeP('Dir_8\Sub_C'), TreeP('Dir_8\Sub_C_J')),
    'journal: folder rename failed');
  SetFileAttributes(PChar(TreeP('Dir_8\File_4.txt')), FILE_ATTRIBUTE_HIDDEN);
  Check(not Indexed(TreeP('Dir_0\Journal_New.txt')),
    'journal: index unchanged while stopped');

  // FileId mapping: index folder FileId = ParentFileReferenceNumber
  Check(TsgcFSearchJournal.ReadRecords(GTree, vId, vSnapNext, vRecs, vEnd,
    True), 'journal: read records');
  vFileRef := FileRefOf(TreeP('Dir_0\Journal_New.txt'));
  vFound := -1;
  vNames := False;
  for i := 0 to Length(vRecs) - 1 do
  begin
    if vRecs[i].Name <> '' then
      vNames := True;
    if (vFound < 0) and ((vRecs[i].FileRef = vFileRef) or
      SameText(vRecs[i].Name, 'Journal_New.txt')) then
      vFound := i;
  end;
  vDirIdx := EntryIdx(TreeP('Dir_0'));
  vDirFileId := EntryFileId(TreeP('Dir_0'));
  vDirRef := FileRefOf(TreeP('Dir_0'));
  Writeln(Format('Journal: %d records since snapshot, names %s',
    [Length(vRecs), BoolToStr(vNames, True)]));
  Check(vFound >= 0, 'journal: record of the created file found');
  if vFound >= 0 then
  begin
    Writeln(Format('FileId mapping: record V%d, file ref $%x (file info $%x), '
      + 'parent ref $%x, index FileId of Dir_0 $%x, file info of Dir_0 $%x',
      [vRecs[vFound].MajorVersion, vRecs[vFound].FileRef, vFileRef,
      vRecs[vFound].ParentRef, vDirFileId, vDirRef]));
    Check(vRecs[vFound].ParentRef = vDirFileId,
      'FileId mapping: parent ref = index folder FileId');
    Check(vDirFileId = vDirRef, 'FileId mapping: index FileId = file info');
    GIndex.BeginRead;
    try
      Check(GIndex.FindFolderByFileId(RootNo, vRecs[vFound].ParentRef)
        = vDirIdx, 'FileId mapping: FindFolderByFileId resolves the parent');
    finally
      GIndex.EndRead;
    end;
  end;

  // catch-up
  vRes := TsgcFSearchJournal.CatchUp(GIndex, RootNo, GSkip);
  Writeln(Format('Journal catch-up: %d records, %d folders, %d unknown refs',
    [vRes.Records, vRes.Stats.Folders, vRes.UnknownRefs]));
  Check(vRes.Mode = fscmJournal, 'journal: catch-up used the journal');
  Check(Indexed(TreeP('Dir_0\Journal_New.txt')), 'journal: created file');
  Check(Indexed(TreeP('Dir_3\J_Folder\J_Inner\J2.txt')) and
    Indexed(TreeP('Dir_3\J_Folder\J1.txt')), 'journal: created folder');
  Check(not Indexed(TreeP('Dir_5\File_2.txt')), 'journal: deleted file');
  Check(Indexed(TreeP('Dir_6\J_Renamed.txt')) and
    not Indexed(TreeP('Dir_6\File_3.txt')), 'journal: renamed file');
  Check(Indexed(TreeP('Dir_8\Sub_C_J\File_5.txt')) and
    not Indexed(TreeP('Dir_8\Sub_C')), 'journal: renamed folder');
  Check((EntryFlags(TreeP('Dir_8\File_4.txt')) and SGCFS_FLAG_HIDDEN) <> 0,
    'journal: attribute change');
  GIndex.BeginRead;
  try
    Check(GIndex.Root(RootNo).NextUsn > vSnapNext, 'journal: NextUsn advanced');
  finally
    GIndex.EndRead;
  end;

  // recreated journal (other id) -> rescan
  WriteBytes(TreeP('Dir_0\Rescan_Id.txt'), 4);
  GIndex.BeginWrite;
  try
    GIndex.SetRootJournal(RootNo, vId xor 1, vSnapNext);
  finally
    GIndex.EndWrite;
  end;
  vRes := TsgcFSearchJournal.CatchUp(GIndex, RootNo, GSkip);
  Check(vRes.Mode = fscmRescan, 'journal: other id rescans');
  Check(Indexed(TreeP('Dir_0\Rescan_Id.txt')), 'journal: rescan after new id');
  GIndex.BeginRead;
  try
    Check(GIndex.Root(RootNo).JournalId = vId,
      'journal: id stored after rescan');
  finally
    GIndex.EndRead;
  end;
end;

procedure TestFallbacks(RootNo: Integer);
var
  vRes: TsgcFSearchCatchUpResult;
  vRefresher: TsgcFSearchFolderRefresher;
  vStats: TsgcFSearchRefreshStats;
begin
  // overflow path without a journal position -> rescan
  WriteBytes(TreeP('Dir_0\Rescan_1.txt'), 1);
  GIndex.BeginWrite;
  try
    GIndex.SetRootJournal(RootNo, 0, 0);
  finally
    GIndex.EndWrite;
  end;
  vRes := TsgcFSearchJournal.CatchUp(GIndex, RootNo, GSkip);
  Check(vRes.Mode = fscmRescan, 'no journal position rescans');
  Check(Indexed(TreeP('Dir_0\Rescan_1.txt')), 'rescan fallback found file');

  vRefresher := TsgcFSearchFolderRefresher.Create(GIndex, GSkip);
  try
    // direct rescan
    WriteBytes(TreeP('Dir_0\Rescan_2.txt'), 2);
    Check(vRefresher.Rescan(RootNo), 'refresher rescan');
    Check(Indexed(TreeP('Dir_0\Rescan_2.txt')), 'refresher rescan found file');
    // missing folder walks up to the nearest indexed ancestor
    WriteBytes(TreeP('Dir_1\Walk_Up.txt'), 3);
    vStats := vRefresher.RefreshFolders([TreeP('Dir_1\Missing\Deeper')]);
    Check(Indexed(TreeP('Dir_1\Walk_Up.txt')) and (vStats.Folders = 1),
      'refresh walks up to the indexed ancestor');
    // gone folder re-lists its parent
    TDirectory.Delete(TreeP('Dir_4'), True);
    vStats := vRefresher.RefreshFolders([TreeP('Dir_4\Sub_A')]);
    Check(not Indexed(TreeP('Dir_4')), 'gone folder re-lists its parent');
    // skip folders are never re-listed
    vStats := vRefresher.RefreshFolders([TreeP('SkipMe')]);
    Check((vStats.Folders = 0) and not Indexed(TreeP('SkipMe\Ignored.txt')),
      'skip folder not re-listed');
  finally
    vRefresher.Free;
  end;
end;

type
  TStormEvents = class
  public
    Changed: Integer;
    BlockMs: Integer;
    Gate: TEvent; // assigned: DoChanged waits on it (a stuck watcher thread)
    procedure DoChanged(Sender: TObject; Generation: Int64);
  end;

procedure TStormEvents.DoChanged(Sender: TObject; Generation: Int64);
begin
  AtomicIncrement(Changed);
  if Gate <> nil then
    Gate.WaitFor(20000)
  else if BlockMs > 0 then
    Sleep(BlockMs);
end;

procedure TestStorm;
const
  CS_BURSTS = 6;
  CS_BURST = 400;
var
  vWatcher: TsgcFSearchWatcher;
  vEvents: TStormEvents;
  vGate: TEvent;
  vSW: TStopwatch;
  b, i, vCatchUps: Integer;
  vOk: Boolean;
begin
  ForceDirectories(TreeP('Ignored'));
  ForceDirectories(TreeP('Storm'));
  vGate := TEvent.Create(nil, True, False, '');
  vEvents := TStormEvents.Create;
  vWatcher := TsgcFSearchWatcher.Create(GIndex, GSkip);
  try
    // the app's own data folder: notifications are ignored
    vWatcher.IgnorePaths := [TreeP('Ignored')];
    vWatcher.OnChanged := vEvents.DoChanged;
    vWatcher.Start;
    for i := 0 to 19 do
      WriteBytes(TreeP(Format('Ignored\ig_%d.txt', [i])), 10);
    Sleep(1000);
    Check(vEvents.Changed = 0, Format('ignored folder: %d flushes',
      [vEvents.Changed]));
    Check(not Indexed(TreeP('Ignored\ig_0.txt')), 'ignored folder: not listed');
    vWatcher.Stop;
    FreeAndNil(vWatcher);

    // overflow storm: 4 KB buffers and a handler that keeps the watcher
    // thread busy 1 s, bursts land while it is busy and overflow
    vEvents.Changed := 0;
    vEvents.BlockMs := 1000;
    vWatcher := TsgcFSearchWatcher.Create(GIndex, GSkip);
    vWatcher.BufferSize := 4096;
    vWatcher.OnChanged := vEvents.DoChanged;
    vWatcher.Start;
    vSW := TStopwatch.StartNew;
    for b := 0 to CS_BURSTS - 1 do
    begin
      for i := 0 to CS_BURST - 1 do
        WriteBytes(TreeP(Format('Storm\st_%d_%d.txt', [b, i])), 1);
      Sleep(400);
    end;
    vCatchUps := vWatcher.CatchUps;
    Writeln(Format('  storm: %d catch-ups in %d ms',
      [vCatchUps, vSW.ElapsedMilliseconds]));
    Check(vCatchUps >= 1, 'storm: overflow caught up');
    Check(vCatchUps <= 2, Format('storm: %d catch-ups, not coalesced',
      [vCatchUps]));
    vEvents.BlockMs := 0;
    vSW := TStopwatch.StartNew;
    repeat
      vOk := True;
      for b := 0 to CS_BURSTS - 1 do
        if not Indexed(TreeP(Format('Storm\st_%d_%d.txt', [b, CS_BURST - 1])))
        then
          vOk := False;
      if vOk then
        Break;
      Sleep(50);
    until vSW.ElapsedMilliseconds > 15000;
    Check(vOk and Indexed(TreeP('Storm\st_0_0.txt')),
      'storm: every file indexed after the coalesced catch-up');
    Writeln(Format('  storm: indexed %d ms after the last burst',
      [vSW.ElapsedMilliseconds]));

    // a stop while the watcher thread is stuck returns within its timeout
    vEvents.Changed := 0;
    vEvents.Gate := vGate;
    WriteBytes(TreeP('Storm\gate.txt'), 3);
    vSW := TStopwatch.StartNew;
    while (vEvents.Changed = 0) and (vSW.ElapsedMilliseconds < 5000) do
      Sleep(10);
    Check(vEvents.Changed > 0, 'stuck thread: handler entered');
    vSW := TStopwatch.StartNew;
    vWatcher.Stop(500);
    Writeln(Format('  stop with a stuck thread: %d ms',
      [vSW.ElapsedMilliseconds]));
    Check(vSW.ElapsedMilliseconds < 1500,
      Format('stuck thread: stop took %d ms', [vSW.ElapsedMilliseconds]));
    Check(not vWatcher.Active, 'stuck thread: watcher inactive');
    vGate.SetEvent;
    Sleep(500); // the abandoned thread ends before its owner is freed
  finally
    vGate.SetEvent;
    vWatcher.Free;
    vEvents.Free;
    vGate.Free;
  end;
end;

procedure RunTests;
var
  vCrawler: TsgcFSearchCrawler;
  vWatcher: TsgcFSearchWatcher;
  vEvents: TTestEvents;
  vRootNo: Integer;
begin
  GBase := TPath.Combine(TPath.GetTempPath, 'sgcFSearchTests\watcher');
  GTree := GBase + '\tree';
  GHome := GBase + '\home';
  if TDirectory.Exists(GBase) then
    TDirectory.Delete(GBase, True);
  ForceDirectories(GHome);
  SetEnvironmentVariable('SGCFSEARCH_HOME', PChar(GHome));
  BuildTree;
  GSkip := [TreeP('SkipMe')];
  GLatencies := TList<Int64>.Create;
  GIndex := TsgcFSearchIndex.Create;
  vEvents := TTestEvents.Create;
  vCrawler := TsgcFSearchCrawler.Create;
  vWatcher := nil;
  try
    vRootNo := vCrawler.CrawlRoot(GIndex, GTree, GSkip);
    Check(vRootNo >= 0, 'crawl root');
    Check(IndexFileCount = CS_FILES, Format('initial file count %d',
      [IndexFileCount]));
    vWatcher := TsgcFSearchWatcher.Create(GIndex, GSkip);
    vWatcher.OnChanged := vEvents.DoChanged;
    vWatcher.OnFilesChanged := vEvents.DoFiles;
    vWatcher.Start;
    Check(vWatcher.Active and (vWatcher.WatchedCount = 1), 'watcher started');
    TestLiveChanges(vWatcher, vEvents);
    TestJournal(vWatcher, vRootNo);
    TestFallbacks(vRootNo);
    TestStorm;
    // clean restart / stop
    vWatcher.Start;
    Check(vWatcher.WatchedCount = 1, 'watcher restarted');
    WriteBytes(TreeP('Dir_0\After_Restart.txt'), 9);
    WaitUntil('create file after restart', function: Boolean
      begin
        Result := Indexed(TreeP('Dir_0\After_Restart.txt'));
      end);
    vWatcher.Stop;
    Check(not vWatcher.Active, 'watcher stopped');
  finally
    vWatcher.Free;
    vCrawler.Free;
    vEvents.Free;
    GIndex.Free;
    GLatencies.Free;
  end;
  TDirectory.Delete(GBase, True);
end;

begin
  try
    RunTests;
  except
    on E: Exception do
    begin
      Inc(GFails);
      Writeln('[FAIL] exception ', E.ClassName, ': ', E.Message);
    end;
  end;
  if GFails = 0 then
  begin
    Writeln('[PASS] ', GChecks, ' checks');
    ExitCode := 0;
  end
  else
  begin
    Writeln('[FAIL] ', GFails, ' of ', GChecks, ' checks failed');
    ExitCode := 1;
  end;

end.
