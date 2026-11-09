{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Core;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.DateUtils, System.SyncObjs,
  // sgc
  sgcFSearch_Types in '..\..\Source\sgcFSearch_Types.pas',
  sgcFSearch_NtApi in '..\..\Source\sgcFSearch_NtApi.pas',
  sgcFSearch_Index in '..\..\Source\sgcFSearch_Index.pas',
  sgcFSearch_Crawler in '..\..\Source\sgcFSearch_Crawler.pas',
  sgcFSearch_Config in '..\..\Source\sgcFSearch_Config.pas',
  sgcFSearch_Log in '..\..\Source\sgcFSearch_Log.pas';

const
  CS_TOP_DIRS = 10;
  CS_TOP_FILES = 10;
  CS_SUBS = 5;
  CS_SUB_FILES = 38;
  // 10 * 10 + 10 * 5 * 38 = 2000, + 3 unicode files + Dir_5\Unique_Gone_42.txt
  CS_FILES = CS_TOP_DIRS * CS_TOP_FILES + CS_TOP_DIRS * CS_SUBS *
    CS_SUB_FILES + 4;
  // 10 + 50 subs + unicode folder + SkipMe + Link junction
  CS_FOLDERS = CS_TOP_DIRS + CS_TOP_DIRS * CS_SUBS + 3;

var
  GChecks, GFails: Integer;
  GBase, GTree, GHome: string;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(GChecks);
  if not Cond then
  begin
    Inc(GFails);
    Writeln('[FAIL] ', Msg);
  end;
end;

function SubName(i: Integer): string;
begin
  Result := 'Sub_' + Char(Ord('A') + i);
end;

function TopFileName(i: Integer): string;
begin
  if Odd(i) then
    Result := Format('ReadMe_%d.MD', [i])
  else
    Result := Format('File_%d.txt', [i]);
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

procedure AppendText(const FileName, S: string);
var
  vFS: TFileStream;
  vB: TBytes;
begin
  vB := TEncoding.ASCII.GetBytes(S);
  vFS := TFileStream.Create(FileName, fmOpenReadWrite);
  try
    vFS.Seek(0, soEnd);
    vFS.WriteBuffer(vB[0], Length(vB));
  finally
    vFS.Free;
  end;
end;

function RunCmd(const Cmd: string): Boolean;
var
  vSI: TStartupInfo;
  vPI: TProcessInformation;
  vCmd: string;
  vCode: DWORD;
begin
  vCmd := 'cmd.exe /c ' + Cmd + ' >nul 2>&1';
  UniqueString(vCmd);
  FillChar(vSI, SizeOf(vSI), 0);
  vSI.cb := SizeOf(vSI);
  Result := CreateProcess(nil, PChar(vCmd), nil, nil, False, CREATE_NO_WINDOW,
    nil, nil, vSI, vPI);
  if Result then
  begin
    WaitForSingleObject(vPI.hProcess, 30000);
    GetExitCodeProcess(vPI.hProcess, vCode);
    Result := vCode = 0;
    CloseHandle(vPI.hThread);
    CloseHandle(vPI.hProcess);
  end;
end;

function UnicodeDir: string;
begin
  Result := #$00DC + 'nicode';
end;

function UnicodeFile(i: Integer): string;
begin
  case i of
    0:
      Result := 'Caf' + #$00E9 + '.txt';
    1:
      Result := #$65E5 + #$672C + '.txt';
  else
    Result := 'smile_' + #$D83D + #$DE00 + '.txt';
  end;
end;

procedure RemoveTree;
begin
  if DirectoryExists(GTree + '\Link') then
    RemoveDirectory(PChar(GTree + '\Link')); // the junction, not its target
  if DirectoryExists(GBase) then
    TDirectory.Delete(GBase, True);
end;

procedure BuildTree;
var
  d, S, f: Integer;
  vDir, vSub: string;
begin
  RemoveTree;
  ForceDirectories(GTree);
  ForceDirectories(GHome);
  for d := 0 to CS_TOP_DIRS - 1 do
  begin
    vDir := GTree + '\Dir_' + IntToStr(d);
    ForceDirectories(vDir);
    for f := 0 to CS_TOP_FILES - 1 do
      WriteBytes(vDir + '\' + TopFileName(f), f * 7 + d);
    for S := 0 to CS_SUBS - 1 do
    begin
      vSub := vDir + '\' + SubName(S);
      ForceDirectories(vSub);
      for f := 0 to CS_SUB_FILES - 1 do
        WriteBytes(vSub + '\' + Format('doc_%.2d.Dat', [f]), f mod 13);
    end;
  end;
  WriteBytes(GTree + '\Dir_5\Unique_Gone_42.txt', 42);
  ForceDirectories(GTree + '\' + UnicodeDir);
  for f := 0 to 2 do
    WriteBytes(GTree + '\' + UnicodeDir + '\' + UnicodeFile(f), 100 + f);
  ForceDirectories(GTree + '\SkipMe');
  for f := 0 to 4 do
    WriteBytes(GTree + '\SkipMe\skipped_' + IntToStr(f) + '.txt', 5);
  RunCmd('mklink /J "' + GTree + '\Link" "' + GTree + '\Dir_0"');
end;

function ChildCount(aIndex: TsgcFSearchIndex; Idx: Integer): Integer;
var
  c: Integer;
begin
  Result := 0;
  c := aIndex.EntryPtr(Idx).FirstChild;
  while c >= 0 do
  begin
    Inc(Result);
    c := aIndex.EntryPtr(c).NextSibling;
  end;
end;

function ParentsOk(aIndex: TsgcFSearchIndex; Idx: Integer): Boolean;
var
  c: Integer;
begin
  Result := True;
  c := aIndex.EntryPtr(Idx).FirstChild;
  while c >= 0 do
  begin
    if (aIndex.EntryPtr(c).ParentIdx <> Idx) or not aIndex.IsLive(c) then
      Exit(False);
    c := aIndex.EntryPtr(c).NextSibling;
  end;
end;

function LiveScanCount(aIndex: TsgcFSearchIndex;
  const Forbidden: string): Integer;
var
  i: Integer;
  vE: PsgcFSearchEntry;
begin
  Result := 0;
  vE := aIndex.Entries;
  for i := 0 to aIndex.EntryCount - 1 do
    if (vE[i].Flags and SGCFS_FLAG_DELETED) = 0 then
    begin
      Inc(Result);
      if (Forbidden <> '') and (Pos(Forbidden, aIndex.FullPath(i)) > 0) then
        Check(False, 'live entry under removed folder: ' + aIndex.FullPath(i));
    end;
end;

function DiskFileId(const Path: string): UInt64;
var
  vH: THandle;
  vInfo: TByHandleFileInformation;
begin
  Result := 0;
  vH := CreateFile(PChar(Path), FILE_READ_ATTRIBUTES, FILE_SHARE_READ or
    FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS, 0);
  if vH = INVALID_HANDLE_VALUE then
    Exit;
  if GetFileInformationByHandle(vH, vInfo) then
    Result := (UInt64(vInfo.nFileIndexHigh) shl 32) or vInfo.nFileIndexLow;
  CloseHandle(vH);
end;

procedure TestTypes;
var
  vDT: TDateTime;
  vFT: Int64;
begin
  vDT := EncodeDate(2026, 11, 3) + EncodeTime(12, 34, 56, 0);
  vFT := sgcFSearchDateTimeUTCToFileTime(vDT);
  Check(Abs(sgcFSearchFileTimeToDateTimeUTC(vFT) - vDT) < 1 / 86400000,
    'FILETIME UTC round trip');
  Check(sgcFSearchDateTimeUTCToFileTime(EncodeDate(1601, 1, 1)) = 0,
    'FILETIME epoch');
  Check(Abs(sgcFSearchFileTimeToLocalDateTime(sgcFSearchLocalDateTimeToFileTime
    (vDT)) - vDT) < 1 / 86400, 'FILETIME local round trip');
  Check(Abs(sgcFSearchFileTimeToDateTimeUTC(sgcFSearchNowFileTime) -
    TTimeZone.Local.ToUniversalTime(Now)) < 1 / 1440, 'NowFileTime');
  Check(sgcFSearchAttributesToFlags(FILE_ATTRIBUTE_DIRECTORY or
    FILE_ATTRIBUTE_REPARSE_POINT, $A0000003) = SGCFS_FLAG_DIR or
    SGCFS_FLAG_REPARSE, 'junction flags');
  Check(sgcFSearchAttributesToFlags(FILE_ATTRIBUTE_DIRECTORY or
    FILE_ATTRIBUTE_REPARSE_POINT or SGCFS_ATTR_RECALL_ON_DATA_ACCESS, $9000301A)
    = SGCFS_FLAG_DIR or SGCFS_FLAG_OFFLINE, 'cloud placeholder flags');
  Check(SizeOf(TsgcFSearchEntry) = 34, 'entry record size');
  Check(SizeOf(TsgcFSearchObjectAttributes) = 48, 'OBJECT_ATTRIBUTES size');
  Check(NativeInt(@PsgcFSearchFileIdBothDirInfo(nil).FileName) = 104,
    'FILE_ID_BOTH_DIR_INFO.FileName offset');
  Check(NativeInt(@PsgcFSearchFileIdExtdDirInfo(nil).FileName) = 88,
    'FILE_ID_EXTD_DIR_INFO.FileName offset');
end;

procedure TestCrawlAndIndex;
var
  vIndex, vLoaded: TsgcFSearchIndex;
  vCrawler: TsgcFSearchCrawler;
  vRoot, vIdx, vIdx2, vDir5, vSubC, vNewSub, vMoved, i: Integer;
  vSkip: TArray<string>;
  vPath, vIdxFile: string;
  vItems: TsgcFSearchListingItems;
  vRes: TsgcFSearchApplyResult;
  vE, vE2: PsgcFSearchEntry;
  vOldEntryCount, vOldNameCount, vLive: Integer;
  vAttr: TWin32FileAttributeData;
  vSerial: Cardinal;
  vFS: string;
begin
  vSkip := [GTree + '\SkipMe'];
  vIndex := TsgcFSearchIndex.Create;
  vCrawler := TsgcFSearchCrawler.Create;
  try
    // ---- static helpers
    Check(Length(TsgcFSearchCrawler.EnumFixedDrives) > 0, 'EnumFixedDrives');
    Check(TsgcFSearchCrawler.GetVolumeInfo(GTree, vSerial, vFS) and (vFS <> ''),
      'GetVolumeInfo');
    Check(TsgcFSearchCrawler.ListFolderByPath(GTree + '\NoSuchFolder', vItems)
      = fslsNotFound, 'ListFolderByPath missing = NotFound');
    Check(TsgcFSearchCrawler.ListFolderByPath(GTree + '\Dir_1\File_0.txt',
      vItems) = fslsNotADirectory, 'ListFolderByPath file = NotADirectory');
    Check((TsgcFSearchCrawler.ListFolderByPath(GTree + '\Dir_1', vItems)
      = fslsOK) and (Length(vItems) = CS_TOP_FILES + CS_SUBS),
      'ListFolderByPath Dir_1');
    Check(DirectoryExists(GTree + '\Link'), 'junction created (mklink /J)');

    // ---- crawl
    vRoot := vCrawler.CrawlRoot(vIndex, GTree, vSkip, 2);
    Check(vRoot = 0, 'CrawlRoot returns root 0');
    Check(vCrawler.Errors = 0, 'crawl errors = 0, got ' +
      IntToStr(vCrawler.Errors));
    vIndex.BeginRead;
    try
      Check(vIndex.FileCount = CS_FILES, Format('FileCount %d = %d',
        [vIndex.FileCount, CS_FILES]));
      Check(vIndex.FolderCount = CS_FOLDERS, Format('FolderCount %d = %d',
        [vIndex.FolderCount, CS_FOLDERS]));
      Check(vIndex.RootCount = 1, 'RootCount 1');
      Check(SameText(vIndex.Root(0).Path, GTree), 'root path');
      Check(vIndex.Root(0).VolumeSerial = vSerial, 'root volume serial');
      Check(vCrawler.Entries = CS_FILES + CS_FOLDERS, 'crawler Entries');

      // FindPath / FullPath round trips
      vPath := GTree + '\Dir_3\Sub_D\doc_07.Dat';
      vIdx := vIndex.FindPath(vPath);
      Check(vIdx >= 0, 'FindPath file');
      Check(vIndex.FullPath(vIdx) = vPath, 'FullPath file round trip');
      Check(vIndex.FindPath(UpperCase(vPath)) = vIdx,
        'FindPath case-insensitive');
      Check(vIndex.FindPath(GTree + '\Dir_3\Sub_D\') = vIndex.EntryPtr(vIdx)
        .ParentIdx, 'FindPath folder with trailing backslash');
      Check(vIndex.EntryPtr(vIdx).Size = 7 mod 13, 'file size');
      Check(vIndex.NameOf(vIdx) = 'doc_07.Dat', 'NameOf');
      vPath := GTree + '\' + UnicodeDir + '\' + UnicodeFile(2);
      vIdx := vIndex.FindPath(vPath);
      Check((vIdx >= 0) and (vIndex.FullPath(vIdx) = vPath),
        'unicode path round trip');
      Check(vIndex.FindPath(GTree + '\' + 'U' + 'nicode') < 0,
        'no false match');
      Check(vIndex.FindPath(GTree + '\Dir_3\Missing.txt') = -1,
        'FindPath missing');
      vIdx := vIndex.FindPath(GTree);
      Check(vIdx = vIndex.Root(0).EntryIdx, 'FindPath root');
      Check(vIndex.FullPath(vIdx) = GTree, 'FullPath root');
      vPath := GTree + '\Dir_2\File_4.txt';
      vIdx := vIndex.FindPath(vPath);
      Check(GetFileAttributesEx(PChar(vPath), GetFileExInfoStandard, @vAttr) and
        (vIndex.EntryPtr(vIdx).MTime = Int64(vAttr.ftLastWriteTime)),
        'file mtime');

      // junction and skip folder
      vIdx := vIndex.FindPath(GTree + '\Link');
      Check(vIdx >= 0, 'junction recorded');
      if vIdx >= 0 then
        Check(((vIndex.EntryPtr(vIdx).Flags and (SGCFS_FLAG_DIR or
          SGCFS_FLAG_REPARSE)) = SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE) and
          (vIndex.EntryPtr(vIdx).FirstChild = -1), 'junction not entered');
      vIdx := vIndex.FindPath(GTree + '\SkipMe');
      Check(vIdx >= 0, 'skip folder recorded');
      if vIdx >= 0 then
        Check(((vIndex.EntryPtr(vIdx).Flags and SGCFS_FLAG_SKIPPED) <> 0) and
          (vIndex.EntryPtr(vIdx).FirstChild = -1), 'skip folder not entered');

      // child lists
      vIdx := vIndex.FindPath(GTree + '\Dir_3');
      Check(ChildCount(vIndex, vIdx) = CS_TOP_FILES + CS_SUBS,
        'Dir_3 child count');
      Check(ParentsOk(vIndex, vIdx), 'Dir_3 children parent links');
      Check(ChildCount(vIndex, vIndex.Root(0).EntryIdx) = CS_TOP_DIRS + 3,
        'root child count');

      // FileId map
      vE := vIndex.EntryPtr(vIdx);
      Check(vE.FileId <> 0, 'folder FileId stored');
      Check(vE.FileId = DiskFileId(GTree + '\Dir_3'),
        'folder FileId = GetFileInformationByHandle');
      Check(vIndex.FindFolderByFileId(0, vE.FileId) = vIdx,
        'FindFolderByFileId');
      Check(vIndex.FindFolderByFileId(0, DiskFileId(GTree)) = vIndex.Root(0)
        .EntryIdx, 'FindFolderByFileId root');
      Check(vIndex.FindFolderByFileId(1, vE.FileId) = -1,
        'FindFolderByFileId bad root');
      Check(LiveScanCount(vIndex, '') = vIndex.FileCount + vIndex.FolderCount +
        1, 'live scan count after crawl');
    finally
      vIndex.EndRead;
    end;

    // ---- rescan keeps everything
    Check(vCrawler.CrawlRoot(vIndex, GTree + '\', vSkip, 2) = 0,
      'rescan same root');
    vIndex.BeginRead;
    try
      Check((vIndex.FileCount = CS_FILES) and (vIndex.FolderCount = CS_FOLDERS),
        'rescan counts unchanged');
      Check(vIndex.EntryCount = CS_FILES + CS_FOLDERS + 1,
        'rescan adds no slots');
    finally
      vIndex.EndRead;
    end;

    // ---- ApplyFolderListing: add / remove / rename / modify
    WriteBytes(GTree + '\Dir_5\NewFile.txt', 11);
    TDirectory.Delete(GTree + '\Dir_5\Sub_B', True);
    DeleteFile(GTree + '\Dir_5\Unique_Gone_42.txt');
    Check(RenameFile(GTree + '\Dir_5\Sub_C', GTree + '\Dir_5\Sub_C_Renamed'),
      'rename on disk');
    AppendText(GTree + '\Dir_5\File_0.txt', 'more data');
    ForceDirectories(GTree + '\Dir_5\NewSub');
    WriteBytes(GTree + '\Dir_5\NewSub\a.txt', 1);
    WriteBytes(GTree + '\Dir_5\NewSub\b.txt', 2);
    Check(TsgcFSearchCrawler.ListFolderByPath(GTree + '\Dir_5', vItems)
      = fslsOK, 'list Dir_5');
    vIndex.BeginWrite;
    try
      vDir5 := vIndex.FindPath(GTree + '\Dir_5');
      vSubC := vIndex.FindPath(GTree + '\Dir_5\Sub_C');
      vOldNameCount := vIndex.NameCount;
      vRes := vIndex.ApplyFolderListing(vDir5, vItems);
      Check(vRes.Added = 2, 'apply Added = 2, got ' + IntToStr(vRes.Added));
      Check(vRes.Removed = CS_SUB_FILES + 2, 'apply Removed = 40, got ' +
        IntToStr(vRes.Removed));
      Check(vRes.Updated = 2, 'apply Updated = 2, got ' +
        IntToStr(vRes.Updated));
      Check(Length(vRes.NewFolders) = 1, 'one new folder');
      if Length(vRes.NewFolders) = 1 then
        Check(vIndex.FullPath(vRes.NewFolders[0]) = GTree + '\Dir_5\NewSub',
          'new folder path');
      vIdx := vIndex.FindPath(GTree + '\Dir_5\Sub_C_Renamed');
      Check((vIdx = vSubC) and (vSubC >= 0), 'rename keeps the entry');
      Check(ChildCount(vIndex, vIdx) = CS_SUB_FILES, 'rename keeps subtree');
      Check(vIndex.FindPath(GTree + '\Dir_5\Sub_C') = -1, 'old name gone');
      Check(vIndex.FindPath(GTree + '\Dir_5\Sub_B\doc_01.Dat') = -1,
        'removed subtree gone');
      Check(vIndex.EntryPtr(vIndex.FindPath(GTree + '\Dir_5\File_0.txt'))
        .Size = 5 + 9, 'modified size');
      Check(vIndex.FileCount = CS_FILES + 1 - CS_SUB_FILES - 1,
        'FileCount after apply');
      Check(vIndex.FolderCount = CS_FOLDERS, 'FolderCount after apply');
      Check(ParentsOk(vIndex, vDir5), 'Dir_5 links after apply');
      Check(ChildCount(vIndex, vDir5) = CS_TOP_FILES + CS_SUBS + 1,
        'Dir_5 child count after apply');
      Check(LiveScanCount(vIndex, '\Dir_5\Sub_B') = vIndex.FileCount +
        vIndex.FolderCount + 1, 'recursive tombstone: live scan count');
      vNewSub := vIndex.FindPath(GTree + '\Dir_5\NewSub');
      Check(vIndex.NameCount >= vOldNameCount, 'names kept in memory');
    finally
      vIndex.EndWrite;
    end;
    Check(vCrawler.CrawlSubtree(vIndex, vNewSub, vSkip), 'CrawlSubtree');
    vIndex.BeginRead;
    try
      Check(ChildCount(vIndex, vNewSub) = 2, 'CrawlSubtree children');
      Check(vIndex.FileCount = CS_FILES - CS_SUB_FILES + 2,
        'FileCount after CrawlSubtree');
    finally
      vIndex.EndRead;
    end;

    // ---- move a folder between parents (same FileId)
    Check(RenameFile(GTree + '\Dir_6\Sub_A', GTree + '\Dir_7\Sub_A_Moved'),
      'move on disk');
    vIndex.BeginWrite;
    try
      vMoved := vIndex.FindPath(GTree + '\Dir_6\Sub_A');
      TsgcFSearchCrawler.ListFolderByPath(GTree + '\Dir_7', vItems);
      vRes := vIndex.ApplyFolderListing
        (vIndex.FindPath(GTree + '\Dir_7'), vItems);
      Check((vRes.Added = 0) and (vRes.Removed = 0) and (vRes.Updated = 1),
        Format('move apply target %d/%d/%d', [vRes.Added, vRes.Removed,
        vRes.Updated]));
      Check(vIndex.FindPath(GTree + '\Dir_7\Sub_A_Moved') = vMoved,
        'moved folder keeps its entry');
      Check(ChildCount(vIndex, vMoved) = CS_SUB_FILES, 'moved subtree kept');
      TsgcFSearchCrawler.ListFolderByPath(GTree + '\Dir_6', vItems);
      vRes := vIndex.ApplyFolderListing
        (vIndex.FindPath(GTree + '\Dir_6'), vItems);
      Check((vRes.Added = 0) and (vRes.Removed = 0),
        'move apply source removes nothing');
      Check(vIndex.FindPath(GTree + '\Dir_6\Sub_A') = -1,
        'moved: old path gone');
      Check(vIndex.FileCount = CS_FILES - CS_SUB_FILES + 2,
        'FileCount after move');
      vIndex.SetRootJournal(0, $1122334455667788, 987654321);
      vOldEntryCount := vIndex.EntryCount;
      vOldNameCount := vIndex.NameCount;
      vLive := LiveScanCount(vIndex, '');
    finally
      vIndex.EndWrite;
    end;

    // ---- save -> load round trip (compaction)
    vIdxFile := sgcFSearchIndexFileName;
    vIndex.SaveToFile(vIdxFile);
    Check(FileExists(vIdxFile) and not FileExists(vIdxFile + '.tmp'),
      'SaveToFile wrote the file');
    vLoaded := TsgcFSearchIndex.Create;
    try
      Check(vLoaded.LoadFromFile(vIdxFile), 'LoadFromFile');
      vLoaded.BeginRead;
      vIndex.BeginRead;
      try
        Check(vOldEntryCount > vLive, 'source had tombstones');
        Check(vLoaded.EntryCount = vLive, 'compacted entry count');
        Check(vLoaded.NameCount < vOldNameCount, 'unreferenced names dropped');
        Check((vLoaded.FileCount = vIndex.FileCount) and
          (vLoaded.FolderCount = vIndex.FolderCount), 'loaded counters');
        Check((vLoaded.RootCount = 1) and (vLoaded.Root(0).Path = GTree) and
          (vLoaded.Root(0).JournalId = $1122334455667788) and
          (vLoaded.Root(0).NextUsn = 987654321) and
          (vLoaded.Root(0).VolumeSerial = vSerial), 'loaded root record');
        vLive := 0;
        for i := 0 to vIndex.EntryCount - 1 do
        begin
          if not vIndex.IsLive(i) then
            Continue;
          vIdx2 := vLoaded.FindPath(vIndex.FullPath(i));
          if vIdx2 < 0 then
          begin
            Inc(vLive);
            Continue;
          end;
          vE := vIndex.EntryPtr(i);
          vE2 := vLoaded.EntryPtr(vIdx2);
          if (vE.Flags <> vE2.Flags) or (vE.MTime <> vE2.MTime) or
            (vE.Size <> vE2.Size) or
            (vLoaded.FullPath(vIdx2) <> vIndex.FullPath(i)) then
            Inc(vLive);
        end;
        Check(vLive = 0, 'loaded entries equal the source (' + IntToStr(vLive) +
          ' differ)');
        vIdx := vLoaded.FindPath(GTree + '\Dir_3');
        Check((vIdx >= 0) and (vLoaded.FindFolderByFileId(0,
          vLoaded.EntryPtr(vIdx).FileId) = vIdx),
          'FindFolderByFileId after load');
        vIdx := vLoaded.FindPath(GTree + '\Dir_7');
        Check((vIdx >= 0) and ParentsOk(vLoaded, vIdx) and
          (ChildCount(vLoaded, vIdx) = CS_TOP_FILES + CS_SUBS + 1),
          'child lists after load');
        Check(LiveScanCount(vLoaded, '') = vLoaded.FileCount +
          vLoaded.FolderCount + 1, 'loaded live scan count');
      finally
        vIndex.EndRead;
        vLoaded.EndRead;
      end;
      // a loaded index is mutable: add one child
      vLoaded.BeginWrite;
      try
        vItems := nil;
        SetLength(vItems, 1);
        vItems[0].Name := 'Extra.bin';
        vItems[0].Size := 3;
        vIdx := vLoaded.AddChild(vLoaded.FindPath(GTree + '\Dir_1'), vItems[0]);
        Check(vLoaded.FullPath(vIdx) = GTree + '\Dir_1\Extra.bin',
          'AddChild after load');
      finally
        vLoaded.EndWrite;
      end;
    finally
      vLoaded.Free;
    end;
    vLoaded := TsgcFSearchIndex.Create;
    try
      Check(not vLoaded.LoadFromFile(vIdxFile + '.missing'),
        'LoadFromFile missing = False');
    finally
      vLoaded.Free;
    end;
    TFile.WriteAllText(vIdxFile + '.bad', 'garbage');
    vLoaded := TsgcFSearchIndex.Create;
    try
      Check(not vLoaded.LoadFromFile(vIdxFile + '.bad') and
        (vLoaded.EntryCount = 0), 'LoadFromFile invalid = False');
    finally
      vLoaded.Free;
    end;
  finally
    vCrawler.Free;
    vIndex.Free;
  end;
end;

procedure TestConfig;
var
  vCfg, vCfg2: TsgcFSearchConfig;
begin
  Check(SameText(sgcFSearchDataDir, ExcludeTrailingPathDelimiter(GHome)),
    'DataDir honours SGCFSEARCH_HOME');
  Check(sgcFSearchExpandUserPath('~\Docs') = ExcludeTrailingPathDelimiter
    (GetEnvironmentVariable('USERPROFILE')) + '\Docs', 'ExpandUserPath ~\x');
  Check(sgcFSearchExpandUserPath('C:\x') = 'C:\x', 'ExpandUserPath plain');
  Check(sgcFSearchExpandUserPath('~abc') = '~abc', 'ExpandUserPath ~name');
  vCfg := TsgcFSearchConfig.Create;
  vCfg2 := TsgcFSearchConfig.Create;
  try
    Check((Length(vCfg.Roots) = 1) and (vCfg.Roots[0] = '~') and
      (vCfg.Hotkey = 'Alt+Shift+Space') and (vCfg.ContentMaxSizeMB = 16) and
      (Length(vCfg.Drives) = 0) and (Length(vCfg.Skip) = 0), 'config defaults');
    Check(not vCfg2.LoadFromFile(sgcFSearchConfigFileName + '.none'),
      'config missing file');
    vCfg.Roots := ['~', 'D:\Work'];
    vCfg.Skip := ['C:\Windows', '~\AppData', 'C:\' + UnicodeDir];
    vCfg.Hotkey := 'Ctrl+Alt+F';
    vCfg.Drives := ['C:\', 'D:\'];
    vCfg.ContentMaxSizeMB := 32;
    vCfg.SaveToFile(sgcFSearchConfigFileName);
    Check(vCfg2.LoadFromFile(sgcFSearchConfigFileName), 'config load');
    Check((Length(vCfg2.Roots) = 2) and (vCfg2.Roots[1] = 'D:\Work') and
      (Length(vCfg2.Skip) = 3) and (vCfg2.Skip[2] = 'C:\' + UnicodeDir) and
      (vCfg2.Hotkey = 'Ctrl+Alt+F') and (Length(vCfg2.Drives) = 2) and
      (vCfg2.Drives[1] = 'D:\') and (vCfg2.ContentMaxSizeMB = 32),
      'config JSON round trip');
    Check(vCfg2.ExpandedSkip[1] = sgcFSearchExpandUserPath('~\AppData'),
      'ExpandedSkip');
  finally
    vCfg2.Free;
    vCfg.Free;
  end;
  sgcFSearchLog('Test_Core log line');
  Check(FileExists(sgcFSearchLogFileName), 'log file written');
end;

procedure TestConfigContentCase;
const
  CS_OLD = '{"roots":["~"],"skip":[],"hotkey":"Ctrl+Alt+F","drives":[],' +
    '"content_max_size_mb":32}';
  CS_TEXT: array [0 .. 2] of string = ('insensitive', 'smart', 'sensitive');
  CS_MODE: array [0 .. 2] of TsgcFSearchGrepCase = (fsgcInsensitive, fsgcSmart,
    fsgcSensitive);
var
  vCfg, vDlg: TsgcFSearchConfig;
  vFile, vLog: string;
  i: Integer;

  function LoadedCase: TsgcFSearchGrepCase;
  var
    vC: TsgcFSearchConfig;
  begin
    vC := TsgcFSearchConfig.Create;
    try
      Check(vC.LoadFromFile(vFile), 'content_case file loads');
      Result := vC.ContentCase;
    finally
      vC.Free;
    end;
  end;

begin
  vFile := sgcFSearchConfigFileName + '.case';
  vCfg := TsgcFSearchConfig.Create;
  try
    Check(vCfg.ContentCase = fsgcInsensitive, 'content_case default');
    // a saved value round-trips
    for i := 0 to High(CS_MODE) do
    begin
      vCfg.ContentCase := CS_MODE[i];
      vCfg.SaveToFile(vFile);
      Check(LoadedCase = CS_MODE[i], 'content_case round trip ' + CS_TEXT[i]);
    end;
    vCfg.SetDefaults;
    Check(vCfg.ContentCase = fsgcInsensitive, 'content_case SetDefaults');
    // config.json written by an older version, no content_case key
    TFile.WriteAllText(vFile, CS_OLD, TEncoding.ANSI);
    Check(LoadedCase = fsgcInsensitive, 'content_case older config');
    vCfg.ContentCase := fsgcSensitive;
    Check(vCfg.LoadFromFile(vFile) and (vCfg.ContentCase = fsgcInsensitive) and
      (vCfg.Hotkey = 'Ctrl+Alt+F') and (vCfg.ContentMaxSizeMB = 32),
      'content_case older config, reused instance');
    // load then save, as the Folders dialog does, keeps the value
    for i := 0 to High(CS_MODE) do
    begin
      TFile.WriteAllText(vFile, '{"roots":["~"],"content_case":"' + CS_TEXT[i] +
        '"}', TEncoding.ANSI);
      vDlg := TsgcFSearchConfig.Create;
      try
        Check(vDlg.LoadFromFile(vFile), 'content_case dialog load');
        vDlg.Roots := ['~', 'D:\Work'];
        vDlg.SaveToFile(vFile);
      finally
        vDlg.Free;
      end;
      Check((LoadedCase = CS_MODE[i]) and
        (Pos('"content_case"', TFile.ReadAllText(vFile, TEncoding.UTF8)) > 0),
        'content_case load then save ' + CS_TEXT[i]);
    end;
    // value matching ignores case
    TFile.WriteAllText(vFile, '{"content_case":"SENSITIVE"}', TEncoding.ANSI);
    Check(LoadedCase = fsgcSensitive, 'content_case value ignores case');
    TFile.WriteAllText(vFile, '{"content_case":"Smart"}', TEncoding.ANSI);
    Check(LoadedCase = fsgcSmart, 'content_case value ignores case 2');
    // an unknown value means insensitive and is logged once
    TFile.WriteAllText(vFile, '{"content_case":"bogus_zz"}', TEncoding.ANSI);
    Check(LoadedCase = fsgcInsensitive, 'content_case unknown value');
    vLog := TFile.ReadAllText(sgcFSearchLogFileName, TEncoding.UTF8);
    Check(Length(vLog.Split(['bogus_zz'])) = 2,
      'content_case unknown value logged once');
  finally
    vCfg.Free;
  end;
end;

procedure TestScale;
const
  CS_DIRS = 1000;
  CS_PER_DIR = 1000;
var
  vIndex, vLoaded: TsgcFSearchIndex;
  vItem: TsgcFSearchListingItem;
  vRoot, vDir, d, i, vSlots: Integer;
  vT: Cardinal;
  vRes: TsgcFSearchApplyResult;
  vFile: string;
begin
  vIndex := TsgcFSearchIndex.Create;
  vLoaded := TsgcFSearchIndex.Create;
  try
    vFile := sgcFSearchIndexFileName + '.scale';
    vT := GetTickCount;
    vIndex.BeginWrite;
    try
      vRoot := vIndex.AddRoot('X:\Synthetic', 1);
      for d := 0 to CS_DIRS - 1 do
      begin
        vItem.Name := 'Folder_' + IntToStr(d);
        vItem.Attributes := FILE_ATTRIBUTE_DIRECTORY;
        vItem.ReparseTag := 0;
        vItem.FileId := UInt64(1000000 + d);
        vItem.Size := 0;
        vItem.MTime := d;
        vDir := vIndex.AddChild(vIndex.Root(vRoot).EntryIdx, vItem);
        vItem.Attributes := FILE_ATTRIBUTE_ARCHIVE;
        vItem.FileId := 0;
        for i := 0 to CS_PER_DIR - 1 do
        begin
          vItem.Name := 'file_' + IntToStr((d * 7 + i) mod 5000) + '.dat';
          vItem.Size := i;
          vIndex.AddChild(vDir, vItem);
        end;
      end;
      Check(vIndex.FileCount = CS_DIRS * CS_PER_DIR, 'scale FileCount');
      Check(vIndex.NameCount = 5000 + CS_DIRS + 1, 'scale distinct names');
    finally
      vIndex.EndWrite;
    end;
    Writeln(Format('scale: insert %d entries %d ms', [vIndex.EntryCount,
      GetTickCount - vT]));
    vT := GetTickCount;
    vIndex.SaveToFile(vFile);
    Writeln(Format('scale: save %d ms', [GetTickCount - vT]));
    vT := GetTickCount;
    Check(vLoaded.LoadFromFile(vFile), 'scale load');
    Writeln(Format('scale: load %d ms', [GetTickCount - vT]));
    vLoaded.BeginRead;
    try
      Check((vLoaded.FileCount = CS_DIRS * CS_PER_DIR) and
        (vLoaded.FolderCount = CS_DIRS), 'scale loaded counters');
      Check(vLoaded.FindPath('x:\synthetic\FOLDER_999\file_' +
        IntToStr((999 * 7 + 5) mod 5000) + '.dat') >= 0, 'scale FindPath');
      Check(vLoaded.FindFolderByFileId(0, 1000000 + 500)
        = vLoaded.FindPath('X:\Synthetic\Folder_500'),
        'scale FindFolderByFileId');
    finally
      vLoaded.EndRead;
    end;
    // tombstone everything, then refill: slots are reused
    vT := GetTickCount;
    vIndex.BeginWrite;
    try
      vSlots := vIndex.EntryCount;
      vRes := vIndex.ApplyFolderListing(vIndex.Root(vRoot).EntryIdx, nil);
      Check(vRes.Removed = CS_DIRS * (CS_PER_DIR + 1), 'scale mass tombstone');
      Check((vIndex.FileCount = 0) and (vIndex.FolderCount = 0),
        'scale counters after tombstone');
      vItem.Name := 'again.txt';
      for i := 0 to 999 do
        vIndex.AddChild(vIndex.Root(vRoot).EntryIdx, vItem);
      Check(vIndex.EntryCount = vSlots, 'scale tombstoned slots reused');
      Check(vIndex.FindFolderByFileId(0, 1000000 + 500) = -1,
        'scale FileId map cleaned');
    finally
      vIndex.EndWrite;
    end;
    Writeln(Format('scale: tombstone + refill %d ms', [GetTickCount - vT]));
    DeleteFile(vFile);
  finally
    vLoaded.Free;
    vIndex.Free;
  end;
end;

begin
  try
    GBase := IncludeTrailingPathDelimiter(TPath.GetTempPath) +
      'sgcFSearchTests\core';
    GTree := GBase + '\tree';
    GHome := GBase + '\home';
    BuildTree;
    SetEnvironmentVariable(SGCFS_HOME_ENV, PChar(GHome));
    TestTypes;
    TestCrawlAndIndex;
    TestConfig;
    TestConfigContentCase;
    TestScale;
  except
    on E: Exception do
    begin
      Inc(GFails);
      Writeln('[FAIL] exception ', E.ClassName, ': ', E.Message);
    end;
  end;
  try
    RemoveTree;
  except
    on E: Exception do
      Writeln('cleanup: ', E.Message);
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
