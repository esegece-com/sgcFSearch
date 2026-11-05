{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Journal;

{$I sgcVer.inc}
{ NTFS change journal (USN) catch-up without administrator rights.

  The journal is queried with FSCTL_QUERY_USN_JOURNAL and read with
  FSCTL_READ_UNPRIVILEGED_USN_JOURNAL (READ_USN_JOURNAL_DATA_V1, record major
  versions 2 and 3; the 128-bit references of V3 are truncated to their low
  64 bits, which is what the index stores as folder FileId). The handle is
  the volume root directory ('C:\', FILE_FLAG_BACKUP_SEMANTICS) with the
  smallest access that works, then the volume device ('\\.\C:'); the method
  that worked is cached (AccessMethod).

  Typical use: Snapshot a root before its initial crawl (and again while the
  watcher still runs, before saving the index on exit), CatchUp after loading
  the index. CatchUp re-lists the folders touched since the stored NextUsn
  (TsgcFSearchFolderRefresher, same flow as the watcher) and falls back to a
  full rescan of the root (CrawlRoot, a diff) when the journal is missing,
  was recreated (other JournalId) or wrapped (stored NextUsn < FirstUsn), or
  when too many touched folders are unknown to the index. Records are a
  replay: re-listing a folder twice is harmless. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections,
  System.SyncObjs,
  // sgc
  sgcFSearch_Types, sgcFSearch_Index, sgcFSearch_Watcher;

type
  /// How the journal handle was opened (last success, process wide).
  TsgcFSearchJournalAccess = (fsjaNone, fsjaRootDir, fsjaRootDirRead,
    fsjaVolume, fsjaVolumeRead);

  TsgcFSearchCatchUpMode = (fscmJournal, fscmRescan, fscmFailed);

  TsgcFSearchCatchUpResult = record
    Mode: TsgcFSearchCatchUpMode;
    Records: Integer; // journal records read (fscmJournal)
    UnknownRefs: Integer; // touched folder refs not in the index
    NextUsn: Int64; // NextUsn stored in the root afterwards
    Stats: TsgcFSearchRefreshStats; // re-list totals (fscmJournal)
  end;

  /// One journal record (V2 or V3, references truncated to 64 bits).
  TsgcFSearchUsnRecord = record
    Usn: Int64;
    FileRef: UInt64;
    ParentRef: UInt64;
    Reason: Cardinal; // USN_REASON_*
    Attributes: Cardinal; // FILE_ATTRIBUTE_*
    MajorVersion: Word;
    Name: string; // only with WithNames
  end;

  TsgcFSearchUsnRecords = TArray<TsgcFSearchUsnRecord>;

  TsgcFSearchJournal = class
  private
    class var FAccess: Integer;
    class var FLastError: Cardinal;
  public
    /// Handle kind that last worked (fsjaNone before the first success).
    class function AccessMethod: TsgcFSearchJournalAccess;
    /// Win32 error of the last failed open / query / read.
    class function LastError: Cardinal;
    /// Journal state of the volume holding RootPath. True only when the
    /// journal can be queried AND read by this process.
    class function Query(const RootPath: string; out JournalId: UInt64;
      out NextUsn, FirstUsn: Int64): Boolean;
    /// Reads the records from StartUsn up to the journal end at call time
    /// (diagnostics and tests). False if the journal cannot be read.
    class function ReadRecords(const RootPath: string; JournalId: UInt64;
      StartUsn: Int64; out Records: TsgcFSearchUsnRecords; out NextUsn: Int64;
      WithNames: Boolean = False): Boolean;
    /// Stores the current journal id / NextUsn in root RootNo (zeros when the
    /// journal is unavailable). Call without holding the index lock.
    class function Snapshot(const aIndex: TsgcFSearchIndex;
      RootNo: Integer): Boolean;
    /// Brings root RootNo up to date from the stored journal position, or
    /// rescans it. Synchronous; call without holding the index lock.
    class function CatchUp(const aIndex: TsgcFSearchIndex; RootNo: Integer;
      const Skip: TArray<string>): TsgcFSearchCatchUpResult; overload;
    class function CatchUp(const Refresher: TsgcFSearchFolderRefresher;
      RootNo: Integer): TsgcFSearchCatchUpResult; overload;
  end;

implementation

uses
  // sgc
  sgcFSearch_Log;

const
  CS_FSCTL_QUERY_USN_JOURNAL = $000900F4;
  CS_FSCTL_READ_UNPRIVILEGED_USN_JOURNAL = $000903AB;
  CS_READ_BUFFER_SIZE = 64 * 1024;

  CS_USN_REASON_DATA_OVERWRITE = $00000001;
  CS_USN_REASON_DATA_EXTEND = $00000002;
  CS_USN_REASON_DATA_TRUNCATION = $00000004;
  CS_USN_REASON_FILE_CREATE = $00000100;
  CS_USN_REASON_FILE_DELETE = $00000200;
  CS_USN_REASON_RENAME_OLD_NAME = $00001000;
  CS_USN_REASON_RENAME_NEW_NAME = $00002000;
  CS_USN_REASON_BASIC_INFO_CHANGE = $00008000;
  CS_USN_REASON_HARD_LINK_CHANGE = $00010000;
  CS_USN_REASON_COMPRESSION_CHANGE = $00020000;
  CS_USN_REASON_ENCRYPTION_CHANGE = $00040000;
  CS_USN_REASON_REPARSE_POINT_CHANGE = $00100000;
  CS_REASON_MASK = CS_USN_REASON_DATA_OVERWRITE or CS_USN_REASON_DATA_EXTEND or
    CS_USN_REASON_DATA_TRUNCATION or CS_USN_REASON_FILE_CREATE or
    CS_USN_REASON_FILE_DELETE or CS_USN_REASON_RENAME_OLD_NAME or
    CS_USN_REASON_RENAME_NEW_NAME or CS_USN_REASON_BASIC_INFO_CHANGE or
    CS_USN_REASON_HARD_LINK_CHANGE or CS_USN_REASON_COMPRESSION_CHANGE or
    CS_USN_REASON_ENCRYPTION_CHANGE or CS_USN_REASON_REPARSE_POINT_CHANGE;

  // drive roots: rescan when more than CS_UNKNOWN_MIN touched folder refs are
  // unknown AND they outnumber the resolved ones CS_UNKNOWN_RATIO times
  // (folders created since the snapshot are not counted)
  CS_UNKNOWN_MIN = 4096;
  CS_UNKNOWN_RATIO = 4;

type
  /// USN_JOURNAL_DATA_V2 (80 bytes; V0 = first 56, V1 = first 60).
  TsgcFSearchUsnJournalData = record
    UsnJournalID: UInt64;
    FirstUsn: Int64;
    NextUsn: Int64;
    LowestValidUsn: Int64;
    MaxUsn: Int64;
    MaximumSize: UInt64;
    AllocationDelta: UInt64;
    MinSupportedMajorVersion: Word;
    MaxSupportedMajorVersion: Word;
    Flags: Cardinal;
    RangeTrackChunkSize: UInt64;
    RangeTrackFileSizeThreshold: Int64;
  end;

  /// READ_USN_JOURNAL_DATA_V1 (48 bytes with alignment).
  TsgcFSearchReadUsnData = record
    StartUsn: Int64;
    ReasonMask: Cardinal;
    ReturnOnlyOnClose: Cardinal;
    Timeout: UInt64;
    BytesToWaitFor: UInt64;
    UsnJournalID: UInt64;
    MinMajorVersion: Word;
    MaxMajorVersion: Word;
  end;

  TsgcFSearchUsnRecordProc = reference to procedure
    (const Rec: TsgcFSearchUsnRecord);

function sgcDeviceIoControl(hDevice: THandle; dwIoControlCode: DWORD;
  lpInBuffer: Pointer; nInBufferSize: DWORD; lpOutBuffer: Pointer;
  nOutBufferSize: DWORD; lpBytesReturned: PDWORD; lpOverlapped: POverlapped)
  : BOOL; stdcall; external kernel32 name 'DeviceIoControl';
function sgcGetVolumePathNameW(lpszFileName, lpszVolumePathName: PWideChar;
  cchBufferLength: DWORD): BOOL; stdcall;
  external kernel32 name 'GetVolumePathNameW';
function sgcGetVolumeNameForVolumeMountPointW(lpszVolumeMountPoint,
  lpszVolumeName: PWideChar; cchBufferLength: DWORD): BOOL; stdcall;
  external kernel32 name 'GetVolumeNameForVolumeMountPointW';

/// Volume mount path of Path ('C:\'), '' on failure.
function DoVolumePath(const Path: string): string;
var
  vBuf: array [0 .. 4 * MAX_PATH] of Char;
begin
  Result := '';
  if sgcGetVolumePathNameW(PChar(Path), @vBuf[0], Length(vBuf)) then
    Result := PChar(@vBuf[0]);
end;

/// Volume device path: '\\.\C:' for a drive letter, else the volume GUID
/// path without its trailing backslash.
function DoVolumeDevice(const VolumePath: string): string;
var
  vBuf: array [0 .. 4 * MAX_PATH] of Char;
begin
  Result := '';
  if (Length(VolumePath) = 3) and (VolumePath[2] = ':') then
    Result := '\\.\' + Copy(VolumePath, 1, 2)
  else if sgcGetVolumeNameForVolumeMountPointW(PChar(VolumePath), @vBuf[0],
    Length(vBuf)) then
  begin
    Result := PChar(@vBuf[0]);
    if (Result <> '') and (Result[Length(Result)] = '\') then
      SetLength(Result, Length(Result) - 1);
  end;
end;

function DoQueryJournal(Handle: THandle;
  out Data: TsgcFSearchUsnJournalData): Boolean;
var
  vBytes: DWORD;
begin
  FillChar(Data, SizeOf(Data), 0);
  vBytes := 0;
  Result := sgcDeviceIoControl(Handle, CS_FSCTL_QUERY_USN_JOURNAL, nil, 0,
    @Data, SizeOf(Data), @vBytes, nil) and (vBytes >= 56);
  if not Result then
    TsgcFSearchJournal.FLastError := GetLastError;
end;

/// Reads the records from StartUsn up to StopUsn (at least one call), calls
/// Proc for each. NextUsn = USN to continue from.
function DoReadJournal(Handle: THandle; JournalId: UInt64;
  StartUsn, StopUsn: Int64; WithNames: Boolean;
  const Proc: TsgcFSearchUsnRecordProc; out NextUsn: Int64): Boolean;
var
  vIn: TsgcFSearchReadUsnData;
  vBuf: TBytes;
  vBytes, vLen: DWORD;
  vP, vEnd: PByte;
  vRec: TsgcFSearchUsnRecord;
  vNameLen, vNameOfs: Word;
  vNext: Int64;
begin
  Result := False;
  NextUsn := StartUsn;
  SetLength(vBuf, CS_READ_BUFFER_SIZE);
  FillChar(vIn, SizeOf(vIn), 0);
  vIn.StartUsn := StartUsn;
  vIn.ReasonMask := CS_REASON_MASK;
  vIn.UsnJournalID := JournalId;
  vIn.MinMajorVersion := 2;
  vIn.MaxMajorVersion := 3;
  while True do
  begin
    vBytes := 0;
    if not sgcDeviceIoControl(Handle, CS_FSCTL_READ_UNPRIVILEGED_USN_JOURNAL,
      @vIn, SizeOf(vIn), @vBuf[0], Length(vBuf), @vBytes, nil) then
    begin
      TsgcFSearchJournal.FLastError := GetLastError;
      Exit;
    end;
    if vBytes < SizeOf(Int64) then
      Break;
    vNext := PInt64(@vBuf[0])^;
    if Assigned(Proc) then
    begin
      vP := @vBuf[SizeOf(Int64)];
      vEnd := @vBuf[0];
      Inc(vEnd, vBytes);
      while vP + 8 <= vEnd do
      begin
        vLen := PCardinal(vP)^;
        if (vLen < 8) or (vP + vLen > vEnd) then
          Break;
        vRec.MajorVersion := PWord(vP + 4)^;
        case vRec.MajorVersion of
          2:
            begin
              vRec.FileRef := PUInt64(vP + 8)^;
              vRec.ParentRef := PUInt64(vP + 16)^;
              vRec.Usn := PInt64(vP + 24)^;
              vRec.Reason := PCardinal(vP + 40)^;
              vRec.Attributes := PCardinal(vP + 52)^;
              vNameLen := PWord(vP + 56)^;
              vNameOfs := PWord(vP + 58)^;
            end;
          3:
            begin
              // FILE_ID_128: low 64 bits first
              vRec.FileRef := PUInt64(vP + 8)^;
              vRec.ParentRef := PUInt64(vP + 24)^;
              vRec.Usn := PInt64(vP + 40)^;
              vRec.Reason := PCardinal(vP + 56)^;
              vRec.Attributes := PCardinal(vP + 68)^;
              vNameLen := PWord(vP + 72)^;
              vNameOfs := PWord(vP + 74)^;
            end;
        else
          begin
            Inc(vP, vLen);
            Continue;
          end;
        end;
        if WithNames and (vNameLen > 0) and (vNameOfs + vNameLen <= vLen) then
          SetString(vRec.Name, PChar(vP + vNameOfs), vNameLen div SizeOf(Char))
        else
          vRec.Name := '';
        Proc(vRec);
        Inc(vP, vLen);
      end;
    end;
    NextUsn := vNext;
    if (vBytes <= SizeOf(Int64)) or (vNext >= StopUsn) or (vNext <= vIn.StartUsn)
    then
      Break;
    vIn.StartUsn := vNext;
  end;
  Result := True;
end;

function DoProbeRead(Handle: THandle;
  const Data: TsgcFSearchUsnJournalData): Boolean;
var
  vNext: Int64;
begin
  Result := DoReadJournal(Handle, Data.UsnJournalID, Data.NextUsn, Data.NextUsn,
    False, nil, vNext);
end;

/// Opens a handle on which the journal can be queried and read, trying the
/// cached method first. Handle must be closed by the caller.
function DoOpenJournal(const RootPath: string; out Handle: THandle;
  out Data: TsgcFSearchUsnJournalData): Boolean;
var
  vVol, vDev, vName: string;
  vOrder: array [0 .. 4] of Integer;
  i, k: Integer;
  vAccess, vFlags: DWORD;
begin
  Result := False;
  Handle := INVALID_HANDLE_VALUE;
  FillChar(Data, SizeOf(Data), 0);
  vVol := DoVolumePath(RootPath);
  if vVol = '' then
  begin
    TsgcFSearchJournal.FLastError := GetLastError;
    Exit;
  end;
  vDev := DoVolumeDevice(vVol);
  vOrder[0] := TsgcFSearchJournal.FAccess;
  for i := 1 to 4 do
    vOrder[i] := i;
  for i := 0 to 4 do
  begin
    k := vOrder[i];
    if (k < 1) or (k > 4) or ((i > 0) and (k = vOrder[0])) then
      Continue;
    case k of
      1, 2:
        begin
          vName := vVol;
          vFlags := FILE_FLAG_BACKUP_SEMANTICS;
        end;
    else
      begin
        vName := vDev;
        vFlags := 0;
      end;
    end;
    if vName = '' then
      Continue;
    if (k = 1) or (k = 3) then
      vAccess := 0
    else
      vAccess := GENERIC_READ;
    Handle := CreateFile(PChar(vName), vAccess, FILE_SHARE_READ or
      FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING, vFlags, 0);
    if Handle = INVALID_HANDLE_VALUE then
    begin
      TsgcFSearchJournal.FLastError := GetLastError;
      Continue;
    end;
    if DoQueryJournal(Handle, Data) and DoProbeRead(Handle, Data) then
    begin
      TsgcFSearchJournal.FAccess := k;
      Exit(True);
    end;
    CloseHandle(Handle);
    Handle := INVALID_HANDLE_VALUE;
  end;
end;

procedure DoRescan(const Refresher: TsgcFSearchFolderRefresher; RootNo: Integer;
  HaveJournal: Boolean; const Data: TsgcFSearchUsnJournalData;
  var Res: TsgcFSearchCatchUpResult);
var
  vIndex: TsgcFSearchIndex;
begin
  vIndex := Refresher.SearchIndex;
  // Data was queried before the rescan: everything after Data.NextUsn is
  // either seen by the rescan or replayed by the next catch-up
  if Refresher.Rescan(RootNo) then
  begin
    Res.Mode := fscmRescan;
    vIndex.BeginWrite;
    try
      if HaveJournal then
      begin
        vIndex.SetRootJournal(RootNo, Data.UsnJournalID, Data.NextUsn);
        Res.NextUsn := Data.NextUsn;
      end
      else
        vIndex.SetRootJournal(RootNo, 0, 0);
    finally
      vIndex.EndWrite;
    end;
  end
  else
    Res.Mode := fscmFailed;
end;

{ TsgcFSearchJournal }

class function TsgcFSearchJournal.AccessMethod: TsgcFSearchJournalAccess;
begin
  case FAccess of
    1:
      Result := fsjaRootDir;
    2:
      Result := fsjaRootDirRead;
    3:
      Result := fsjaVolume;
    4:
      Result := fsjaVolumeRead;
  else
    Result := fsjaNone;
  end;
end;

class function TsgcFSearchJournal.LastError: Cardinal;
begin
  Result := FLastError;
end;

class function TsgcFSearchJournal.Query(const RootPath: string;
  out JournalId: UInt64; out NextUsn, FirstUsn: Int64): Boolean;
var
  vHandle: THandle;
  vData: TsgcFSearchUsnJournalData;
begin
  JournalId := 0;
  NextUsn := 0;
  FirstUsn := 0;
  Result := DoOpenJournal(RootPath, vHandle, vData);
  if Result then
  begin
    CloseHandle(vHandle);
    JournalId := vData.UsnJournalID;
    NextUsn := vData.NextUsn;
    FirstUsn := vData.FirstUsn;
  end;
end;

class function TsgcFSearchJournal.ReadRecords(const RootPath: string;
  JournalId: UInt64; StartUsn: Int64; out Records: TsgcFSearchUsnRecords;
  out NextUsn: Int64; WithNames: Boolean): Boolean;
var
  vHandle: THandle;
  vData: TsgcFSearchUsnJournalData;
  vList: TList<TsgcFSearchUsnRecord>;
begin
  Records := nil;
  NextUsn := StartUsn;
  Result := DoOpenJournal(RootPath, vHandle, vData);
  if not Result then
    Exit;
  vList := TList<TsgcFSearchUsnRecord>.Create;
  try
    Result := DoReadJournal(vHandle, JournalId, StartUsn, vData.NextUsn,
      WithNames, procedure(const Rec: TsgcFSearchUsnRecord)
      begin
        vList.Add(Rec);
      end, NextUsn);
    Records := vList.ToArray;
  finally
    vList.Free;
    CloseHandle(vHandle);
  end;
end;

class function TsgcFSearchJournal.Snapshot(const aIndex: TsgcFSearchIndex;
RootNo: Integer): Boolean;
var
  vPath: string;
  vId: UInt64;
  vNext, vFirst: Int64;
begin
  Result := False;
  aIndex.BeginRead;
  try
    if (RootNo < 0) or (RootNo >= aIndex.RootCount) then
      Exit;
    vPath := aIndex.Root(RootNo).Path;
  finally
    aIndex.EndRead;
  end;
  Result := Query(vPath, vId, vNext, vFirst);
  aIndex.BeginWrite;
  try
    if Result then
      aIndex.SetRootJournal(RootNo, vId, vNext)
    else
      aIndex.SetRootJournal(RootNo, 0, 0);
  finally
    aIndex.EndWrite;
  end;
end;

class function TsgcFSearchJournal.CatchUp(const aIndex: TsgcFSearchIndex;
RootNo: Integer; const Skip: TArray<string>): TsgcFSearchCatchUpResult;
var
  vRefresher: TsgcFSearchFolderRefresher;
begin
  vRefresher := TsgcFSearchFolderRefresher.Create(aIndex, Skip);
  try
    Result := CatchUp(vRefresher, RootNo);
  finally
    vRefresher.Free;
  end;
end;

class function TsgcFSearchJournal.CatchUp(const Refresher
  : TsgcFSearchFolderRefresher; RootNo: Integer): TsgcFSearchCatchUpResult;
var
  vIndex: TsgcFSearchIndex;
  vRoot: TsgcFSearchRoot;
  vHandle: THandle;
  vData: TsgcFSearchUsnJournalData;
  vRefs: TDictionary<UInt64, Byte>; // folder ref -> 0 new side, 1 old side
  vCreated: TDictionary<UInt64, Boolean>; // folders created since NextUsn
  vPair: TPair<UInt64, Byte>;
  vNewPaths, vOldPaths: TList<string>;
  vCount, vUnknown, vResolved, vIdx: Integer;
  vNext: Int64;
  vVol: string;
  vIsSubFolder, vOk: Boolean;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Mode := fscmFailed;
  vIndex := Refresher.SearchIndex;
  vIndex.BeginRead;
  try
    if (RootNo < 0) or (RootNo >= vIndex.RootCount) then
      Exit;
    vRoot := vIndex.Root(RootNo);
  finally
    vIndex.EndRead;
  end;
  if not DoOpenJournal(vRoot.Path, vHandle, vData) then
  begin
    sgcFSearchLog(Format('Journal: unavailable for %s (error %d), rescanning',
      [vRoot.Path, FLastError]));
    DoRescan(Refresher, RootNo, False, vData, Result);
    Exit;
  end;
  try
    if (vRoot.JournalId = 0) or (vRoot.JournalId <> vData.UsnJournalID) or
      (vRoot.NextUsn < vData.FirstUsn) or (vRoot.NextUsn > vData.NextUsn) then
    begin
      sgcFSearchLog(Format('Journal: %s has no usable position, rescanning',
        [vRoot.Path]));
      DoRescan(Refresher, RootNo, True, vData, Result);
      Exit;
    end;
    vCount := 0;
    vRefs := TDictionary<UInt64, Byte>.Create;
    vCreated := TDictionary<UInt64, Boolean>.Create;
    vNewPaths := TList<string>.Create;
    vOldPaths := TList<string>.Create;
    try
      vOk := DoReadJournal(vHandle, vData.UsnJournalID, vRoot.NextUsn,
        vData.NextUsn, False, procedure(const Rec: TsgcFSearchUsnRecord)
        var
          vSide, vOld: Byte;
        begin
          Inc(vCount);
          if (Rec.Reason and (CS_USN_REASON_FILE_DELETE or
            CS_USN_REASON_RENAME_OLD_NAME)) <> 0 then
            vSide := 1
          else
            vSide := 0;
          if not vRefs.TryGetValue(Rec.ParentRef, vOld) or (vSide < vOld) then
            vRefs.AddOrSetValue(Rec.ParentRef, vSide);
          if (Rec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          begin
            if not vRefs.TryGetValue(Rec.FileRef, vOld) or (vSide < vOld) then
              vRefs.AddOrSetValue(Rec.FileRef, vSide);
            if (Rec.Reason and CS_USN_REASON_FILE_CREATE) <> 0 then
              vCreated.AddOrSetValue(Rec.FileRef, True);
          end;
        end, vNext);
      if not vOk then
      begin
        // wrapped or deleted while reading
        sgcFSearchLog(Format('Journal: read failed for %s (error %d), ' +
          'rescanning', [vRoot.Path, FLastError]));
        if DoQueryJournal(vHandle, vData) then
          DoRescan(Refresher, RootNo, True, vData, Result)
        else
          DoRescan(Refresher, RootNo, False, vData, Result);
        Exit;
      end;
      Result.Records := vCount;
      vUnknown := 0;
      vResolved := 0;
      vIndex.BeginRead;
      try
        for vPair in vRefs do
        begin
          vIdx := vIndex.FindFolderByFileId(RootNo, vPair.Key);
          if vIdx >= 0 then
          begin
            Inc(vResolved);
            if vPair.Value = 0 then
              vNewPaths.Add(vIndex.FullPath(vIdx))
            else
              vOldPaths.Add(vIndex.FullPath(vIdx));
          end
          else if not vCreated.ContainsKey(vPair.Key) then
            Inc(vUnknown);
        end;
      finally
        vIndex.EndRead;
      end;
      Result.UnknownRefs := vUnknown;
      // the journal covers the whole volume: when the root is a subfolder,
      // refs outside it are expected
      vVol := DoVolumePath(vRoot.Path);
      vIsSubFolder := not SameText(ExcludeTrailingPathDelimiter(vVol),
        ExcludeTrailingPathDelimiter(vRoot.Path));
      if not vIsSubFolder and (vUnknown > CS_UNKNOWN_MIN) and
        (vUnknown > CS_UNKNOWN_RATIO * vResolved) then
      begin
        sgcFSearchLog(Format('Journal: %d unknown folders on %s, rescanning',
          [vUnknown, vRoot.Path]));
        DoRescan(Refresher, RootNo, True, vData, Result);
        Exit;
      end;
      vNewPaths.AddRange(vOldPaths);
      Result.Stats := Refresher.RefreshFolders(vNewPaths.ToArray);
      vIndex.BeginWrite;
      try
        vIndex.SetRootNextUsn(RootNo, vNext);
      finally
        vIndex.EndWrite;
      end;
      Result.NextUsn := vNext;
      Result.Mode := fscmJournal;
    finally
      vOldPaths.Free;
      vNewPaths.Free;
      vCreated.Free;
      vRefs.Free;
    end;
  finally
    CloseHandle(vHandle);
  end;
end;

end.
