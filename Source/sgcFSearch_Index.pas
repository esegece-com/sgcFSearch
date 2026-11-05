{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Index;

{$I sgcVer.inc}
{ In-memory name index.

  Locking contract: the index has one writer at a time and many readers.
  - Readers wrap every access in BeginRead / EndRead (do not nest).
  - The writer wraps every mutation in BeginWrite / EndWrite.
  - All methods below assume the caller already holds the right lock,
  EXCEPT SaveToFile (takes the read lock itself) and LoadFromFile (takes
  the write lock itself): call those two without holding the lock.
  - Entry indexes, name ids and pointers (EntryPtr, Entries, NamePtr) are only
  valid while the lock is held. Generation changes on every mutation, so a
  reader caching indexes across locks must compare it first (tombstoned slots
  are reused by later inserts). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  // sgc
  sgcFSearch_Types;

const
  SGCFS_INDEX_VERSION = 1;

type
  /// One index entry, 34 bytes packed. Live entries have no
  /// SGCFS_FLAG_DELETED; child lists only link live entries.
  TsgcFSearchEntry = packed record
    ParentIdx: Int32; // parent entry, -1 for a root (or a tombstone)
    FirstChild: Int32; // first child entry, -1 none
    NextSibling: Int32; // next entry of the parent's child list, -1 end
    NameId: Int32; // distinct-name table id (NamePtr / NameLen)
    MTime: Int64; // last write time, FILETIME UTC
    Flags: Word; // SGCFS_FLAG_*
    case Integer of
      0:
        (Size: Int64); // files: size in bytes
      1:
        (FileId: UInt64); // folders (SGCFS_FLAG_DIR): file reference number,
    // folders have no size so the field is shared (0 = unknown)
  end;

  PsgcFSearchEntry = ^TsgcFSearchEntry;

  /// One indexed root (drive root or any folder).
  TsgcFSearchRoot = record
    Path: string; // normalized: 'C:\' or 'C:\Temp\x' (no trailing \)
    EntryIdx: Int32; // root entry (ParentIdx = -1, name = Path)
    VolumeSerial: Cardinal;
    JournalId: UInt64; // USN journal id (live-update agent)
    NextUsn: Int64; // next USN to read (live-update agent)
  end;

  /// Result of TsgcFSearchIndex.ApplyFolderListing.
  TsgcFSearchApplyResult = record
    Added: Integer; // items inserted
    Removed: Integer; // entries tombstoned, descendants included
    Updated: Integer; // items with changed size / mtime / attributes,
    // renamed or moved folders, folders with a new FileId
    NewFolders: TArray<Integer>; // entries the caller must crawl: new
    // folders (not reparse points) and folders whose FileId changed
  end;

  /// Open addressing map UInt64 -> Int32 (folder FileId -> entry). Internal
  /// helper of TsgcFSearchIndex.
  TsgcFSearchFileIdMap = record
  private
    FKeys: TArray<UInt64>;
    FVals: TArray<Int32>; // -1 = empty slot
    FCount: Integer;
    FMask: Integer;
    function DoSlot(Key: UInt64): Integer; inline;
    procedure DoGrow;
  public
    procedure Clear;
    procedure Put(Key: UInt64; Value: Int32);
    function Get(Key: UInt64): Int32; // -1 if missing
    procedure Remove(Key: UInt64; Value: Int32); // only if Key -> Value
    property Count: Integer read FCount;
  end;

  TsgcFSearchIndex = class
  private
    FLock: TLightweightMREW;
    FGeneration: Int64;
    // entries
    FEntries: TArray<TsgcFSearchEntry>;
    FEntryCount: Integer;
    FFreeHead: Int32;
    FFileCount: Integer;
    FFolderCount: Integer;
    // distinct-name table
    FPool: TArray<Char>;
    FPoolLen: Integer;
    FNameOfs: TArray<Int32>;
    FNameLen: TArray<Word>;
    FNameHash: TArray<Cardinal>;
    FNameCount: Integer;
    FNameSlots: TArray<Int32>;
    FNameMask: Integer;
    // roots
    FRoots: TArray<TsgcFSearchRoot>;
    FRootMaps: TArray<TsgcFSearchFileIdMap>;
    // writer scratch buffers
    FScratchChildren: TArray<Int32>;
    FScratchMatched: TArray<Boolean>;
    FScratchSlots: TArray<Int32>;
    FScratchList: TArray<Int32>;
    FScratchDone: TArray<Boolean>;
    function GetEntries: PsgcFSearchEntry;
    function GetRootCount: Integer;
    function DoAllocEntry: Integer;
    function DoInternName(P: PChar; Len: Integer): Integer;
    procedure DoRehashNames(NewSize: Integer);
    function DoDeleteSubtree(Idx, RootNo: Integer): Integer;
    procedure DoUnlink(Idx: Integer);
    procedure DoLink(ParentIdx, Idx: Integer);
    function DoRootNoOfRootEntry(RootEntry: Integer): Integer;
    procedure DoSetFolderFileId(Idx, RootNo: Integer; FileId: UInt64);
    procedure DoUpdateFromItem(Idx, RootNo: Integer;
      const Item: TsgcFSearchListingItem; var Changed: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    // ---- locking (see the contract at the top of the unit)
    procedure BeginRead; inline;
    procedure EndRead; inline;
    procedure BeginWrite; inline;
    procedure EndWrite; inline;
    /// Incremented on every mutation (atomic read, no lock needed).
    property Generation: Int64 read FGeneration;

    /// Removes everything (roots included). Write lock.
    procedure Clear;

    // ---- distinct-name table (ids 0 .. NameCount - 1; may contain names no
    // live entry uses any more, they are dropped by SaveToFile)
    property NameCount: Integer read FNameCount;
    function NamePtr(Id: Integer): PChar; inline;
    function NameLen(Id: Integer): Integer; inline;
    /// Exact-case lookup, -1 if the name is not in the table.
    function FindName(P: PChar; Len: Integer): Integer;

    // ---- entries (slots 0 .. EntryCount - 1, tombstones included: skip
    // entries with SGCFS_FLAG_DELETED when scanning)
    property EntryCount: Integer read FEntryCount;
    /// Pointer to entry 0 (nil when empty), for scanners: Entries[I].
    property Entries: PsgcFSearchEntry read GetEntries;
    function EntryPtr(Idx: Integer): PsgcFSearchEntry; inline;
    function IsLive(Idx: Integer): Boolean; inline;
    /// Entry name ('' for a tombstone). A root's name is its path.
    function NameOf(Idx: Integer): string;
    /// Full path, 'C:\Windows\notepad.exe' ('' for a tombstone).
    function FullPath(Idx: Integer): string;
    /// Entry of a full path (case-insensitive, exact case preferred),
    /// -1 if not indexed.
    function FindPath(const Path: string): Integer;
    /// Folder entry with that FileId inside root number Root, -1 if none.
    function FindFolderByFileId(Root: Integer; FileId: UInt64): Integer;
    /// Root number (0 .. RootCount - 1) an entry belongs to, -1 if invalid.
    function RootOfEntry(Idx: Integer): Integer;
    /// Live files / folders (roots and tombstones excluded).
    property FileCount: Integer read FFileCount;
    property FolderCount: Integer read FFolderCount;

    // ---- roots
    property RootCount: Integer read GetRootCount;
    function Root(RootNo: Integer): TsgcFSearchRoot;
    /// Root number of a root path (case-insensitive), -1 if none.
    function FindRoot(const Path: string): Integer;
    /// Adds a root (or returns the existing one with the same path, updating
    /// serial / FileId / MTime). Returns the root number.
    function AddRoot(const Path: string; VolumeSerial: Cardinal;
      RootFileId: UInt64 = 0; MTime: Int64 = 0): Integer;
    procedure SetRootVolumeSerial(RootNo: Integer; VolumeSerial: Cardinal);
    procedure SetRootJournal(RootNo: Integer; JournalId: UInt64;
      NextUsn: Int64);
    procedure SetRootNextUsn(RootNo: Integer; NextUsn: Int64);

    // ---- mutation (write lock)
    /// Inserts one item under ParentIdx (no duplicate check, used to fill a
    /// folder that has no children yet). Returns the new entry, -1 if
    /// ParentIdx is not a live folder.
    function AddChild(ParentIdx: Integer;
      const Item: TsgcFSearchListingItem): Integer;
    /// Diffs a fresh listing of FolderIdx into the index: new items are
    /// inserted, missing ones tombstoned with their whole subtree, changed
    /// ones updated, renamed / moved folders (same FileId) relinked in place
    /// keeping their subtree. Clears SGCFS_FLAG_DENIED on FolderIdx. Skip
    /// folders are not known here: the caller filters NewFolders.
    function ApplyFolderListing(FolderIdx: Integer;
      const Items: TsgcFSearchListingItems): TsgcFSearchApplyResult;
    /// Sets or clears one flag (SGCFS_FLAG_DENIED, SGCFS_FLAG_SKIPPED ...).
    procedure SetEntryFlag(Idx: Integer; Flag: Word; Value: Boolean);

    // ---- persistence (no lock held by the caller)
    /// Writes a compacted snapshot (no tombstones, renumbered entries in
    /// pre-order, unreferenced names dropped) to FileName + '.tmp', then
    /// replaces FileName. Holds the read lock only while taking the
    /// snapshot. Raises on I/O errors.
    procedure SaveToFile(const FileName: string);
    /// Loads a file written by SaveToFile, replacing the index. Returns False
    /// (index unchanged) when the file is missing, truncated or invalid.
    function LoadFromFile(const FileName: string): Boolean;
  end;

implementation

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

const
  CS_MAGIC: array [0 .. 7] of AnsiChar = 'SGCFSIDX';
  CS_END_MAGIC: array [0 .. 7] of AnsiChar = 'SGCFSEND';
  CS_MAX_DEPTH = 32768;
  CS_MAX_NAME = 65535;

type
  TsgcFSearchIndexHeader = packed record
    Magic: array [0 .. 7] of AnsiChar;
    Version: Cardinal;
    EntrySize: Cardinal;
    RootCount: Int32;
    EntryCount: Int32;
    NameCount: Int32;
    PoolChars: Int32;
    FileCount: Int32;
    FolderCount: Int32;
  end;

function DoHashName(P: PChar; Len: Integer): Cardinal; inline;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 0 to Len - 1 do
    Result := (Result xor Ord(P[i])) * 16777619;
end;

function DoSameOrdinal(P1: PChar; L1: Integer; P2: PChar; L2: Integer)
  : Boolean; inline;
begin
  Result := CompareStringOrdinal(P1, L1, P2, L2, 1) = CSTR_EQUAL;
end;

function DoNormalizePath(const Path: string): string;
begin
  Result := StringReplace(Path, '/', '\', [rfReplaceAll]);
  if Result.StartsWith('\\?\') then
    Delete(Result, 1, 4);
  if (Length(Result) = 2) and (Result[2] = ':') then
    Result := Result + '\';
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    SetLength(Result, Length(Result) - 1);
end;

{ TsgcFSearchFileIdMap }

function TsgcFSearchFileIdMap.DoSlot(Key: UInt64): Integer;
begin
  Result := Integer((Key * UInt64($9E3779B97F4A7C15)) shr 32) and FMask;
end;

procedure TsgcFSearchFileIdMap.DoGrow;
var
  vKeys: TArray<UInt64>;
  vVals: TArray<Int32>;
  i, s, vSize: Integer;
begin
  vKeys := FKeys;
  vVals := FVals;
  vSize := Length(FVals) * 2;
  if vSize < 64 then
    vSize := 64;
  SetLength(FKeys, 0);
  SetLength(FVals, 0);
  SetLength(FKeys, vSize);
  SetLength(FVals, vSize);
  FillChar(FVals[0], vSize * SizeOf(Int32), $FF);
  FMask := vSize - 1;
  for i := 0 to Length(vVals) - 1 do
    if vVals[i] >= 0 then
    begin
      s := DoSlot(vKeys[i]);
      while FVals[s] >= 0 do
        s := (s + 1) and FMask;
      FKeys[s] := vKeys[i];
      FVals[s] := vVals[i];
    end;
end;

procedure TsgcFSearchFileIdMap.Clear;
begin
  FKeys := nil;
  FVals := nil;
  FCount := 0;
  FMask := 0;
end;

procedure TsgcFSearchFileIdMap.Put(Key: UInt64; Value: Int32);
var
  s: Integer;
begin
  if (FVals = nil) or ((FCount + 1) * 2 > Length(FVals)) then
    DoGrow;
  s := DoSlot(Key);
  while FVals[s] >= 0 do
  begin
    if FKeys[s] = Key then
    begin
      FVals[s] := Value;
      Exit;
    end;
    s := (s + 1) and FMask;
  end;
  FKeys[s] := Key;
  FVals[s] := Value;
  Inc(FCount);
end;

function TsgcFSearchFileIdMap.Get(Key: UInt64): Int32;
var
  s: Integer;
begin
  Result := -1;
  if FVals = nil then
    Exit;
  s := DoSlot(Key);
  while FVals[s] >= 0 do
  begin
    if FKeys[s] = Key then
      Exit(FVals[s]);
    s := (s + 1) and FMask;
  end;
end;

procedure TsgcFSearchFileIdMap.Remove(Key: UInt64; Value: Int32);
var
  s, j, k: Integer;
  vInRange: Boolean;
begin
  if FVals = nil then
    Exit;
  s := DoSlot(Key);
  while True do
  begin
    if FVals[s] < 0 then
      Exit;
    if FKeys[s] = Key then
      Break;
    s := (s + 1) and FMask;
  end;
  if FVals[s] <> Value then
    Exit;
  FVals[s] := -1;
  Dec(FCount);
  // backward shift deletion
  j := s;
  while True do
  begin
    j := (j + 1) and FMask;
    if FVals[j] < 0 then
      Break;
    k := DoSlot(FKeys[j]);
    if s <= j then
      vInRange := (k > s) and (k <= j)
    else
      vInRange := (k > s) or (k <= j);
    if not vInRange then
    begin
      FKeys[s] := FKeys[j];
      FVals[s] := FVals[j];
      FVals[j] := -1;
      s := j;
    end;
  end;
end;

{ TsgcFSearchIndex }

constructor TsgcFSearchIndex.Create;
begin
  inherited Create;
  FFreeHead := -1;
  DoRehashNames(1024);
end;

destructor TsgcFSearchIndex.Destroy;
begin
  inherited;
end;

procedure TsgcFSearchIndex.BeginRead;
begin
  FLock.BeginRead;
end;

procedure TsgcFSearchIndex.EndRead;
begin
  FLock.EndRead;
end;

procedure TsgcFSearchIndex.BeginWrite;
begin
  FLock.BeginWrite;
end;

procedure TsgcFSearchIndex.EndWrite;
begin
  FLock.EndWrite;
end;

procedure TsgcFSearchIndex.Clear;
begin
  FEntries := nil;
  FEntryCount := 0;
  FFreeHead := -1;
  FFileCount := 0;
  FFolderCount := 0;
  FPool := nil;
  FPoolLen := 0;
  FNameOfs := nil;
  FNameLen := nil;
  FNameHash := nil;
  FNameCount := 0;
  DoRehashNames(1024);
  FRoots := nil;
  FRootMaps := nil;
  Inc(FGeneration);
end;

function TsgcFSearchIndex.GetEntries: PsgcFSearchEntry;
begin
  if FEntryCount = 0 then
    Result := nil
  else
    Result := @FEntries[0];
end;

function TsgcFSearchIndex.GetRootCount: Integer;
begin
  Result := Length(FRoots);
end;

function TsgcFSearchIndex.EntryPtr(Idx: Integer): PsgcFSearchEntry;
begin
  Result := @FEntries[Idx];
end;

function TsgcFSearchIndex.IsLive(Idx: Integer): Boolean;
begin
  Result := (Idx >= 0) and (Idx < FEntryCount) and
    ((FEntries[Idx].Flags and SGCFS_FLAG_DELETED) = 0);
end;

function TsgcFSearchIndex.NamePtr(Id: Integer): PChar;
begin
  Result := @FPool[FNameOfs[Id]];
end;

function TsgcFSearchIndex.NameLen(Id: Integer): Integer;
begin
  Result := FNameLen[Id];
end;

procedure TsgcFSearchIndex.DoRehashNames(NewSize: Integer);
var
  i, s: Integer;
begin
  SetLength(FNameSlots, 0);
  SetLength(FNameSlots, NewSize);
  FillChar(FNameSlots[0], NewSize * SizeOf(Int32), $FF);
  FNameMask := NewSize - 1;
  for i := 0 to FNameCount - 1 do
  begin
    s := Integer(FNameHash[i] and Cardinal(FNameMask));
    while FNameSlots[s] >= 0 do
      s := (s + 1) and FNameMask;
    FNameSlots[s] := i;
  end;
end;

function TsgcFSearchIndex.FindName(P: PChar; Len: Integer): Integer;
var
  h: Cardinal;
  s, vId: Integer;
begin
  if Len > CS_MAX_NAME then
    Len := CS_MAX_NAME;
  h := DoHashName(P, Len);
  s := Integer(h and Cardinal(FNameMask));
  while True do
  begin
    vId := FNameSlots[s];
    if vId < 0 then
      Exit(-1);
    if (FNameHash[vId] = h) and (FNameLen[vId] = Len) and
      CompareMem(@FPool[FNameOfs[vId]], P, Len * SizeOf(Char)) then
      Exit(vId);
    s := (s + 1) and FNameMask;
  end;
end;

function TsgcFSearchIndex.DoInternName(P: PChar; Len: Integer): Integer;
var
  h: Cardinal;
  s, vId, vCap: Integer;
begin
  if Len > CS_MAX_NAME then
    Len := CS_MAX_NAME;
  h := DoHashName(P, Len);
  s := Integer(h and Cardinal(FNameMask));
  while True do
  begin
    vId := FNameSlots[s];
    if vId < 0 then
      Break;
    if (FNameHash[vId] = h) and (FNameLen[vId] = Len) and
      CompareMem(@FPool[FNameOfs[vId]], P, Len * SizeOf(Char)) then
      Exit(vId);
    s := (s + 1) and FNameMask;
  end;
  // append to the pool
  if FPoolLen + Len > Length(FPool) then
  begin
    vCap := Length(FPool) * 2;
    if vCap < FPoolLen + Len + 65536 then
      vCap := FPoolLen + Len + 65536;
    SetLength(FPool, vCap);
  end;
  if Len > 0 then
    Move(P^, FPool[FPoolLen], Len * SizeOf(Char));
  if FNameCount = Length(FNameOfs) then
  begin
    vCap := Length(FNameOfs) * 2;
    if vCap < 1024 then
      vCap := 1024;
    SetLength(FNameOfs, vCap);
    SetLength(FNameLen, vCap);
    SetLength(FNameHash, vCap);
  end;
  Result := FNameCount;
  FNameOfs[Result] := FPoolLen;
  FNameLen[Result] := Len;
  FNameHash[Result] := h;
  Inc(FPoolLen, Len);
  Inc(FNameCount);
  FNameSlots[s] := Result;
  if FNameCount * 2 > Length(FNameSlots) then
    DoRehashNames(Length(FNameSlots) * 2);
end;

function TsgcFSearchIndex.DoAllocEntry: Integer;
var
  vCap: Integer;
  vE: PsgcFSearchEntry;
begin
  if FFreeHead >= 0 then
  begin
    Result := FFreeHead;
    FFreeHead := FEntries[Result].NextSibling;
  end
  else
  begin
    if FEntryCount = Length(FEntries) then
    begin
      vCap := Length(FEntries) * 2;
      if vCap < 1024 then
        vCap := 1024;
      SetLength(FEntries, vCap);
    end;
    Result := FEntryCount;
    Inc(FEntryCount);
  end;
  vE := @FEntries[Result];
  FillChar(vE^, SizeOf(TsgcFSearchEntry), 0);
  vE.ParentIdx := -1;
  vE.FirstChild := -1;
  vE.NextSibling := -1;
end;

function TsgcFSearchIndex.NameOf(Idx: Integer): string;
var
  vId: Integer;
begin
  if not IsLive(Idx) then
    Exit('');
  vId := FEntries[Idx].NameId;
  SetString(Result, NamePtr(vId), FNameLen[vId]);
end;

function TsgcFSearchIndex.FullPath(Idx: Integer): string;
var
  i, vLen, vPos, vNL, vDepth: Integer;
  vE: PsgcFSearchEntry;
  vRootSep: Boolean;
  vP: PChar;
begin
  if not IsLive(Idx) then
    Exit('');
  // pass 1: total length
  vLen := 0;
  vDepth := 0;
  i := Idx;
  while True do
  begin
    vE := @FEntries[i];
    vNL := FNameLen[vE.NameId];
    if vE.ParentIdx < 0 then
    begin
      Inc(vLen, vNL);
      vP := NamePtr(vE.NameId);
      vRootSep := (vNL > 0) and (vP[vNL - 1] = '\');
      Break;
    end;
    Inc(vLen, vNL + 1);
    Inc(vDepth);
    if vDepth > CS_MAX_DEPTH then
      Exit('');
    i := vE.ParentIdx;
  end;
  if vRootSep and (Idx <> i) then
    Dec(vLen);
  SetLength(Result, vLen);
  // pass 2: fill from the end
  vPos := vLen; // 1-based index of the last char to write
  i := Idx;
  while True do
  begin
    vE := @FEntries[i];
    vNL := FNameLen[vE.NameId];
    if vNL > 0 then
      Move(NamePtr(vE.NameId)^, Result[vPos - vNL + 1], vNL * SizeOf(Char));
    Dec(vPos, vNL);
    if vE.ParentIdx < 0 then
      Break;
    if not(vRootSep and ((FEntries[vE.ParentIdx].Flags and SGCFS_FLAG_ROOT) <>
      0) and (FEntries[vE.ParentIdx].ParentIdx < 0)) then
    begin
      Result[vPos] := '\';
      Dec(vPos);
    end;
    i := vE.ParentIdx;
  end;
end;

function TsgcFSearchIndex.FindPath(const Path: string): Integer;
var
  vPath, vRP: string;
  r, vBest, vBestLen, vL, vLen, vPos, vStart, vCLen, c, vCand, vNL: Integer;
  vCP, vNP: PChar;
  vE: PsgcFSearchEntry;
begin
  Result := -1;
  vPath := DoNormalizePath(Path);
  vLen := Length(vPath);
  if vLen = 0 then
    Exit;
  vBest := -1;
  vBestLen := 0;
  for r := 0 to Length(FRoots) - 1 do
  begin
    vRP := FRoots[r].Path;
    vL := Length(vRP);
    if (vL = 0) or (vL > vLen) or (vL <= vBestLen) then
      Continue;
    if not DoSameOrdinal(PChar(vRP), vL, PChar(vPath), vL) then
      Continue;
    if (vL = vLen) or (vRP[vL] = '\') or (vPath[vL + 1] = '\') then
    begin
      vBest := r;
      vBestLen := vL;
    end;
  end;
  if vBest < 0 then
    Exit;
  Result := FRoots[vBest].EntryIdx;
  vPos := vBestLen + 1;
  while vPos <= vLen do
  begin
    while (vPos <= vLen) and (vPath[vPos] = '\') do
      Inc(vPos);
    if vPos > vLen then
      Break;
    vStart := vPos;
    while (vPos <= vLen) and (vPath[vPos] <> '\') do
      Inc(vPos);
    vCLen := vPos - vStart;
    vCP := @vPath[vStart];
    vCand := -1;
    c := FEntries[Result].FirstChild;
    while c >= 0 do
    begin
      vE := @FEntries[c];
      vNL := FNameLen[vE.NameId];
      if vNL = vCLen then
      begin
        vNP := NamePtr(vE.NameId);
        if CompareMem(vNP, vCP, vCLen * SizeOf(Char)) then
        begin
          vCand := c;
          Break;
        end;
        if (vCand < 0) and DoSameOrdinal(vNP, vNL, vCP, vCLen) then
          vCand := c;
      end;
      c := vE.NextSibling;
    end;
    if vCand < 0 then
      Exit(-1);
    Result := vCand;
  end;
end;

function TsgcFSearchIndex.FindFolderByFileId(Root: Integer;
  FileId: UInt64): Integer;
begin
  Result := -1;
  if (Root < 0) or (Root >= Length(FRootMaps)) or (FileId = 0) then
    Exit;
  Result := FRootMaps[Root].Get(FileId);
  if (Result >= 0) and not IsLive(Result) then
    Result := -1;
end;

function TsgcFSearchIndex.DoRootNoOfRootEntry(RootEntry: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to Length(FRoots) - 1 do
    if FRoots[i].EntryIdx = RootEntry then
      Exit(i);
  Result := -1;
end;

function TsgcFSearchIndex.RootOfEntry(Idx: Integer): Integer;
var
  vDepth: Integer;
begin
  Result := -1;
  if not IsLive(Idx) then
    Exit;
  vDepth := 0;
  while FEntries[Idx].ParentIdx >= 0 do
  begin
    Idx := FEntries[Idx].ParentIdx;
    Inc(vDepth);
    if vDepth > CS_MAX_DEPTH then
      Exit;
  end;
  Result := DoRootNoOfRootEntry(Idx);
end;

function TsgcFSearchIndex.Root(RootNo: Integer): TsgcFSearchRoot;
begin
  Result := FRoots[RootNo];
end;

function TsgcFSearchIndex.FindRoot(const Path: string): Integer;
var
  vPath: string;
  i: Integer;
begin
  vPath := DoNormalizePath(Path);
  for i := 0 to Length(FRoots) - 1 do
    if (Length(FRoots[i].Path) = Length(vPath)) and
      DoSameOrdinal(PChar(FRoots[i].Path), Length(vPath), PChar(vPath),
      Length(vPath)) then
      Exit(i);
  Result := -1;
end;

procedure TsgcFSearchIndex.DoSetFolderFileId(Idx, RootNo: Integer;
  FileId: UInt64);
var
  vE: PsgcFSearchEntry;
begin
  vE := @FEntries[Idx];
  if vE.FileId = FileId then
  begin
    if (FileId <> 0) and (RootNo >= 0) then
      FRootMaps[RootNo].Put(FileId, Idx);
    Exit;
  end;
  if (vE.FileId <> 0) and (RootNo >= 0) then
    FRootMaps[RootNo].Remove(vE.FileId, Idx);
  vE.FileId := FileId;
  if (FileId <> 0) and (RootNo >= 0) then
    FRootMaps[RootNo].Put(FileId, Idx);
end;

function TsgcFSearchIndex.AddRoot(const Path: string; VolumeSerial: Cardinal;
  RootFileId: UInt64; MTime: Int64): Integer;
var
  vPath: string;
  vIdx: Integer;
  vE: PsgcFSearchEntry;
begin
  vPath := DoNormalizePath(Path);
  Result := FindRoot(vPath);
  if Result >= 0 then
  begin
    FRoots[Result].VolumeSerial := VolumeSerial;
    vIdx := FRoots[Result].EntryIdx;
    if RootFileId <> 0 then
      DoSetFolderFileId(vIdx, Result, RootFileId);
    if MTime <> 0 then
      FEntries[vIdx].MTime := MTime;
    Inc(FGeneration);
    Exit;
  end;
  vIdx := DoAllocEntry;
  vE := @FEntries[vIdx];
  vE.NameId := DoInternName(PChar(vPath), Length(vPath));
  vE := @FEntries[vIdx];
  vE.Flags := SGCFS_FLAG_DIR or SGCFS_FLAG_ROOT;
  vE.MTime := MTime;
  vE.FileId := 0;
  Result := Length(FRoots);
  SetLength(FRoots, Result + 1);
  SetLength(FRootMaps, Result + 1);
  FRoots[Result].Path := vPath;
  FRoots[Result].EntryIdx := vIdx;
  FRoots[Result].VolumeSerial := VolumeSerial;
  FRoots[Result].JournalId := 0;
  FRoots[Result].NextUsn := 0;
  FRootMaps[Result].Clear;
  if RootFileId <> 0 then
    DoSetFolderFileId(vIdx, Result, RootFileId);
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.SetRootVolumeSerial(RootNo: Integer;
  VolumeSerial: Cardinal);
begin
  FRoots[RootNo].VolumeSerial := VolumeSerial;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.SetRootJournal(RootNo: Integer; JournalId: UInt64;
  NextUsn: Int64);
begin
  FRoots[RootNo].JournalId := JournalId;
  FRoots[RootNo].NextUsn := NextUsn;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.SetRootNextUsn(RootNo: Integer; NextUsn: Int64);
begin
  FRoots[RootNo].NextUsn := NextUsn;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.SetEntryFlag(Idx: Integer; Flag: Word;
  Value: Boolean);
begin
  if not IsLive(Idx) then
    Exit;
  if Value then
    FEntries[Idx].Flags := FEntries[Idx].Flags or Flag
  else
    FEntries[Idx].Flags := FEntries[Idx].Flags and not Flag;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.DoLink(ParentIdx, Idx: Integer);
begin
  FEntries[Idx].ParentIdx := ParentIdx;
  FEntries[Idx].NextSibling := FEntries[ParentIdx].FirstChild;
  FEntries[ParentIdx].FirstChild := Idx;
end;

procedure TsgcFSearchIndex.DoUnlink(Idx: Integer);
var
  vParent, c, vPrev: Integer;
begin
  vParent := FEntries[Idx].ParentIdx;
  if vParent < 0 then
    Exit;
  vPrev := -1;
  c := FEntries[vParent].FirstChild;
  while (c >= 0) and (c <> Idx) do
  begin
    vPrev := c;
    c := FEntries[c].NextSibling;
  end;
  if c <> Idx then
    Exit;
  if vPrev < 0 then
    FEntries[vParent].FirstChild := FEntries[Idx].NextSibling
  else
    FEntries[vPrev].NextSibling := FEntries[Idx].NextSibling;
  FEntries[Idx].NextSibling := -1;
end;

function TsgcFSearchIndex.DoDeleteSubtree(Idx, RootNo: Integer): Integer;
var
  vHead, vCount, i, c: Integer;
  vE: PsgcFSearchEntry;
begin
  // collect the subtree breadth first (does not unlink Idx from its parent)
  if Length(FScratchList) < 64 then
    SetLength(FScratchList, 64);
  FScratchList[0] := Idx;
  vCount := 1;
  vHead := 0;
  while vHead < vCount do
  begin
    c := FEntries[FScratchList[vHead]].FirstChild;
    Inc(vHead);
    while c >= 0 do
    begin
      if vCount = Length(FScratchList) then
        SetLength(FScratchList, vCount * 2);
      FScratchList[vCount] := c;
      Inc(vCount);
      c := FEntries[c].NextSibling;
    end;
  end;
  for i := 0 to vCount - 1 do
  begin
    vE := @FEntries[FScratchList[i]];
    if (vE.Flags and SGCFS_FLAG_DIR) <> 0 then
    begin
      if (vE.FileId <> 0) and (RootNo >= 0) then
        FRootMaps[RootNo].Remove(vE.FileId, FScratchList[i]);
      if (vE.Flags and SGCFS_FLAG_ROOT) = 0 then
        Dec(FFolderCount);
    end
    else
      Dec(FFileCount);
    vE.Flags := SGCFS_FLAG_DELETED;
    vE.ParentIdx := -1;
    vE.FirstChild := -1;
    vE.Size := 0;
    vE.NextSibling := FFreeHead;
    FFreeHead := FScratchList[i];
  end;
  Result := vCount;
  Inc(FGeneration);
end;

function TsgcFSearchIndex.AddChild(ParentIdx: Integer;
  const Item: TsgcFSearchListingItem): Integer;
var
  vNameId, vRootNo: Integer;
  vFlags: Word;
  vE: PsgcFSearchEntry;
begin
  Result := -1;
  if not IsLive(ParentIdx) or
    ((FEntries[ParentIdx].Flags and SGCFS_FLAG_DIR) = 0) then
    Exit;
  vNameId := DoInternName(PChar(Item.Name), Length(Item.Name));
  vFlags := sgcFSearchAttributesToFlags(Item.Attributes, Item.ReparseTag);
  Result := DoAllocEntry;
  vE := @FEntries[Result];
  vE.NameId := vNameId;
  vE.Flags := vFlags;
  vE.MTime := Item.MTime;
  DoLink(ParentIdx, Result);
  if (vFlags and SGCFS_FLAG_DIR) <> 0 then
  begin
    Inc(FFolderCount);
    if Item.FileId <> 0 then
    begin
      vRootNo := RootOfEntry(ParentIdx);
      DoSetFolderFileId(Result, vRootNo, Item.FileId);
    end;
  end
  else
  begin
    vE.Size := Item.Size;
    Inc(FFileCount);
  end;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.DoUpdateFromItem(Idx, RootNo: Integer;
  const Item: TsgcFSearchListingItem; var Changed: Boolean);
var
  vE: PsgcFSearchEntry;
  vAttr: Word;
begin
  vE := @FEntries[Idx];
  vAttr := sgcFSearchAttributesToFlags(Item.Attributes, Item.ReparseTag);
  if (vE.Flags and SGCFS_FLAGS_ATTR) <> vAttr then
  begin
    vE.Flags := (vE.Flags and not SGCFS_FLAGS_ATTR) or vAttr;
    Changed := True;
  end;
  if vE.MTime <> Item.MTime then
  begin
    vE.MTime := Item.MTime;
    Changed := True;
  end;
  if (vAttr and SGCFS_FLAG_DIR) = 0 then
  begin
    if vE.Size <> Item.Size then
    begin
      vE.Size := Item.Size;
      Changed := True;
    end;
  end
  else if (Item.FileId <> 0) and (vE.FileId <> Item.FileId) then
  begin
    DoSetFolderFileId(Idx, RootNo, Item.FileId);
    Changed := True;
  end;
end;

function TsgcFSearchIndex.ApplyFolderListing(FolderIdx: Integer;
  const Items: TsgcFSearchListingItems): TsgcFSearchApplyResult;
var
  vRootNo, n, i, P, c, s, vSize, vMask, vNameId, vNewCount, vHead, vUp,
    vDepth: Integer;
  vE: PsgcFSearchEntry;
  vNewAttr: Word;
  vChanged, vFileIdChanged, vOk: Boolean;
  vMoved, vNew: TArray<Integer>;
  vMovedCount: Integer;

  procedure DoAddNewFolder(Idx: Integer);
  begin
    if vNewCount = Length(vNew) then
      SetLength(vNew, vNewCount * 2 + 16);
    vNew[vNewCount] := Idx;
    Inc(vNewCount);
  end;

begin
  Result.Added := 0;
  Result.Removed := 0;
  Result.Updated := 0;
  Result.NewFolders := nil;
  vNewCount := 0;
  vMovedCount := 0;
  if not IsLive(FolderIdx) or
    ((FEntries[FolderIdx].Flags and SGCFS_FLAG_DIR) = 0) then
    Exit;
  vRootNo := RootOfEntry(FolderIdx);

  // current children
  n := 0;
  c := FEntries[FolderIdx].FirstChild;
  while c >= 0 do
  begin
    if n = Length(FScratchChildren) then
      SetLength(FScratchChildren, n * 2 + 64);
    FScratchChildren[n] := c;
    Inc(n);
    c := FEntries[c].NextSibling;
  end;
  if Length(FScratchMatched) < n then
    SetLength(FScratchMatched, n + 64);
  if n > 0 then
    FillChar(FScratchMatched[0], n * SizeOf(Boolean), 0);
  if Length(FScratchDone) < Length(Items) then
    SetLength(FScratchDone, Length(Items) + 64);
  if Length(Items) > 0 then
    FillChar(FScratchDone[0], Length(Items) * SizeOf(Boolean), 0);

  // NameId -> child position (open addressing)
  vSize := 16;
  while vSize < n * 2 do
    vSize := vSize * 2;
  vMask := vSize - 1;
  if Length(FScratchSlots) < vSize then
    SetLength(FScratchSlots, vSize);
  FillChar(FScratchSlots[0], vSize * SizeOf(Int32), $FF);
  for P := 0 to n - 1 do
  begin
    s := Integer((Cardinal(FEntries[FScratchChildren[P]].NameId) * 2654435761)
      and Cardinal(vMask));
    while FScratchSlots[s] >= 0 do
      s := (s + 1) and vMask;
    FScratchSlots[s] := P;
  end;

  // pass 1: match by exact name
  for i := 0 to Length(Items) - 1 do
  begin
    vNameId := FindName(PChar(Items[i].Name), Length(Items[i].Name));
    if vNameId < 0 then
      Continue;
    s := Integer((Cardinal(vNameId) * 2654435761) and Cardinal(vMask));
    P := -1;
    while FScratchSlots[s] >= 0 do
    begin
      if FEntries[FScratchChildren[FScratchSlots[s]]].NameId = vNameId then
      begin
        P := FScratchSlots[s];
        Break;
      end;
      s := (s + 1) and vMask;
    end;
    if (P < 0) or FScratchMatched[P] then
      Continue;
    c := FScratchChildren[P];
    vE := @FEntries[c];
    vNewAttr := sgcFSearchAttributesToFlags(Items[i].Attributes,
      Items[i].ReparseTag);
    // file <-> folder, or folder <-> reparse point: replace, not update
    if ((vE.Flags xor vNewAttr) and (SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE)) <> 0
    then
      Continue;
    FScratchMatched[P] := True;
    FScratchDone[i] := True;
    vChanged := False;
    vFileIdChanged := ((vNewAttr and SGCFS_FLAG_DIR) <> 0) and
      (Items[i].FileId <> 0) and (vE.FileId <> Items[i].FileId);
    DoUpdateFromItem(c, vRootNo, Items[i], vChanged);
    if vChanged then
      Inc(Result.Updated);
    if vFileIdChanged and ((vNewAttr and SGCFS_FLAG_REPARSE) = 0) then
      DoAddNewFolder(c);
  end;

  // pass 2: unmatched folders found by FileId: renamed here or moved here
  for i := 0 to Length(Items) - 1 do
  begin
    if FScratchDone[i] or (Items[i].FileId = 0) or
      ((Items[i].Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0) then
      Continue;
    c := FindFolderByFileId(vRootNo, Items[i].FileId);
    if (c < 0) or (c = FolderIdx) or
      ((FEntries[c].Flags and SGCFS_FLAG_ROOT) <> 0) then
      Continue;
    vNewAttr := sgcFSearchAttributesToFlags(Items[i].Attributes,
      Items[i].ReparseTag);
    if ((FEntries[c].Flags xor vNewAttr) and
      (SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE)) <> 0 then
      Continue;
    if FEntries[c].ParentIdx = FolderIdx then
    begin
      // renamed inside this folder
      P := -1;
      for s := 0 to n - 1 do
        if FScratchChildren[s] = c then
        begin
          P := s;
          Break;
        end;
      if (P < 0) or FScratchMatched[P] then
        Continue;
      FScratchMatched[P] := True;
    end
    else
    begin
      // moved from another folder: FolderIdx must not be inside c
      vOk := True;
      vUp := FolderIdx;
      vDepth := 0;
      while vUp >= 0 do
      begin
        if vUp = c then
        begin
          vOk := False;
          Break;
        end;
        vUp := FEntries[vUp].ParentIdx;
        Inc(vDepth);
        if vDepth > CS_MAX_DEPTH then
          Break;
      end;
      if not vOk then
        Continue;
      // unlink now, so a tombstoned old parent does not take it along
      DoUnlink(c);
      if vMovedCount = Length(vMoved) then
        SetLength(vMoved, vMovedCount * 2 + 8);
      vMoved[vMovedCount] := c;
      Inc(vMovedCount);
    end;
    FScratchDone[i] := True;
    FEntries[c].NameId := DoInternName(PChar(Items[i].Name),
      Length(Items[i].Name));
    vChanged := True;
    DoUpdateFromItem(c, vRootNo, Items[i], vChanged);
    Inc(Result.Updated);
  end;

  // pass 3: tombstone children missing from the listing, rebuild the list
  for P := 0 to n - 1 do
    if not FScratchMatched[P] then
      Inc(Result.Removed, DoDeleteSubtree(FScratchChildren[P], vRootNo));
  vHead := -1;
  for P := n - 1 downto 0 do
    if FScratchMatched[P] then
    begin
      FEntries[FScratchChildren[P]].NextSibling := vHead;
      vHead := FScratchChildren[P];
    end;
  FEntries[FolderIdx].FirstChild := vHead;
  for i := 0 to vMovedCount - 1 do
    DoLink(FolderIdx, vMoved[i]);

  // pass 4: insert new items
  for i := 0 to Length(Items) - 1 do
  begin
    if FScratchDone[i] then
      Continue;
    c := AddChild(FolderIdx, Items[i]);
    if c < 0 then
      Continue;
    Inc(Result.Added);
    if (FEntries[c].Flags and (SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE)) = SGCFS_FLAG_DIR
    then
      DoAddNewFolder(c);
  end;

  FEntries[FolderIdx].Flags := FEntries[FolderIdx].Flags and
    not SGCFS_FLAG_DENIED;
  SetLength(vNew, vNewCount);
  Result.NewFolders := vNew;
  Inc(FGeneration);
end;

procedure TsgcFSearchIndex.SaveToFile(const FileName: string);
var
  vNewIdx, vOrder, vNameMap: TArray<Int32>;
  vEntries: TArray<TsgcFSearchEntry>;
  vNameLens: TArray<Word>;
  vPool: TArray<Char>;
  vRoots: TArray<TsgcFSearchRoot>;
  vCount, vNames, vPoolLen, vTop, vSegStart, i, j, c, vOld, vId, vNL, vFiles,
    vFolders: Integer;
  vStack: TArray<Int32>;
  vE: PsgcFSearchEntry;
  vH: TsgcFSearchIndexHeader;
  vStream: TStream;
  vTmp: string;
  vLen: Int32;
  vTmpI: Int32;
begin
  // ---- snapshot + compaction under the read lock
  BeginRead;
  try
    SetLength(vNewIdx, FEntryCount);
    if FEntryCount > 0 then
      FillChar(vNewIdx[0], FEntryCount * SizeOf(Int32), $FF);
    SetLength(vOrder, FEntryCount);
    SetLength(vStack, 1024);
    vCount := 0;
    vFiles := 0;
    vFolders := 0;
    vRoots := Copy(FRoots);
    for i := 0 to Length(vRoots) - 1 do
    begin
      vStack[0] := vRoots[i].EntryIdx;
      vTop := 1;
      while vTop > 0 do
      begin
        Dec(vTop);
        vOld := vStack[vTop];
        if (vOld < 0) or (vOld >= FEntryCount) or (vNewIdx[vOld] >= 0) or
          ((FEntries[vOld].Flags and SGCFS_FLAG_DELETED) <> 0) then
          Continue;
        vNewIdx[vOld] := vCount;
        vOrder[vCount] := vOld;
        Inc(vCount);
        // push children reversed so the first child is visited first
        vSegStart := vTop;
        c := FEntries[vOld].FirstChild;
        while c >= 0 do
        begin
          if vTop = Length(vStack) then
            SetLength(vStack, vTop * 2);
          vStack[vTop] := c;
          Inc(vTop);
          c := FEntries[c].NextSibling;
        end;
        j := vTop - 1;
        while vSegStart < j do
        begin
          c := vStack[vSegStart];
          vStack[vSegStart] := vStack[j];
          vStack[j] := c;
          Inc(vSegStart);
          Dec(j);
        end;
      end;
      vRoots[i].EntryIdx := vNewIdx[vRoots[i].EntryIdx];
    end;
    vStack := nil;
    // copy entries renumbered, remap names
    SetLength(vEntries, vCount);
    SetLength(vNameMap, FNameCount);
    if FNameCount > 0 then
      FillChar(vNameMap[0], FNameCount * SizeOf(Int32), $FF);
    SetLength(vNameLens, 1024);
    SetLength(vPool, 65536);
    vNames := 0;
    vPoolLen := 0;
    for i := 0 to vCount - 1 do
    begin
      vEntries[i] := FEntries[vOrder[i]];
      vE := @vEntries[i];
      if vE.ParentIdx >= 0 then
        vE.ParentIdx := vNewIdx[vE.ParentIdx];
      if vE.FirstChild >= 0 then
        vE.FirstChild := vNewIdx[vE.FirstChild];
      if vE.NextSibling >= 0 then
        vE.NextSibling := vNewIdx[vE.NextSibling];
      if (vE.Flags and SGCFS_FLAG_ROOT) <> 0 then
        vE.NextSibling := -1;
      vId := vE.NameId;
      if vNameMap[vId] < 0 then
      begin
        vNL := FNameLen[vId];
        if vNames = Length(vNameLens) then
          SetLength(vNameLens, vNames * 2);
        if vPoolLen + vNL > Length(vPool) then
          SetLength(vPool, (vPoolLen + vNL) * 2);
        if vNL > 0 then
          Move(FPool[FNameOfs[vId]], vPool[vPoolLen], vNL * SizeOf(Char));
        vNameLens[vNames] := vNL;
        Inc(vPoolLen, vNL);
        vNameMap[vId] := vNames;
        Inc(vNames);
      end;
      vE.NameId := vNameMap[vId];
      if (vE.Flags and SGCFS_FLAG_ROOT) = 0 then
      begin
        if (vE.Flags and SGCFS_FLAG_DIR) <> 0 then
          Inc(vFolders)
        else
          Inc(vFiles);
      end;
    end;
  finally
    EndRead;
  end;
  vNewIdx := nil;
  vOrder := nil;
  vNameMap := nil;

  // ---- write the file
  vTmp := FileName + '.tmp';
  FillChar(vH, SizeOf(vH), 0);
  Move(CS_MAGIC[0], vH.Magic[0], SizeOf(vH.Magic));
  vH.Version := SGCFS_INDEX_VERSION;
  vH.EntrySize := SizeOf(TsgcFSearchEntry);
  vH.RootCount := Length(vRoots);
  vH.EntryCount := vCount;
  vH.NameCount := vNames;
  vH.PoolChars := vPoolLen;
  vH.FileCount := vFiles;
  vH.FolderCount := vFolders;
  vStream := TBufferedFileStream.Create(vTmp, fmCreate, 1024 * 1024);
  try
    vStream.WriteBuffer(vH, SizeOf(vH));
    for i := 0 to Length(vRoots) - 1 do
    begin
      vLen := Length(vRoots[i].Path);
      vStream.WriteBuffer(vLen, SizeOf(vLen));
      if vLen > 0 then
        vStream.WriteBuffer(vRoots[i].Path[1], vLen * SizeOf(Char));
      vTmpI := vRoots[i].EntryIdx;
      vStream.WriteBuffer(vTmpI, SizeOf(vTmpI));
      vStream.WriteBuffer(vRoots[i].VolumeSerial, SizeOf(Cardinal));
      vStream.WriteBuffer(vRoots[i].JournalId, SizeOf(UInt64));
      vStream.WriteBuffer(vRoots[i].NextUsn, SizeOf(Int64));
    end;
    if vCount > 0 then
      vStream.WriteBuffer(vEntries[0], vCount * SizeOf(TsgcFSearchEntry));
    if vNames > 0 then
      vStream.WriteBuffer(vNameLens[0], vNames * SizeOf(Word));
    if vPoolLen > 0 then
      vStream.WriteBuffer(vPool[0], vPoolLen * SizeOf(Char));
    vStream.WriteBuffer(CS_END_MAGIC[0], SizeOf(CS_END_MAGIC));
  finally
    vStream.Free;
  end;
  if not MoveFileEx(PChar(vTmp), PChar(FileName), MOVEFILE_REPLACE_EXISTING or
    MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function TsgcFSearchIndex.LoadFromFile(const FileName: string): Boolean;
var
  vStream: TStream;
  vH: TsgcFSearchIndexHeader;
  vRoots: TArray<TsgcFSearchRoot>;
  vMaps: TArray<TsgcFSearchFileIdMap>;
  vEntries: TArray<TsgcFSearchEntry>;
  vNameLens: TArray<Word>;
  vPool: TArray<Char>;
  vOfs: TArray<Int32>;
  vHash: TArray<Cardinal>;
  vRootNo: TArray<Int32>;
  vEnd: array [0 .. 7] of AnsiChar;
  vSize, vNeed: Int64;
  vLen, i, r, vSum, vFiles, vFolders, vSlots: Integer;
  vE: PsgcFSearchEntry;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  try
    vStream := TBufferedFileStream.Create(FileName, fmOpenRead or
      fmShareDenyWrite, 1024 * 1024);
    try
      vSize := vStream.Size;
      if vSize < SizeOf(vH) + SizeOf(vEnd) then
        Exit;
      vStream.ReadBuffer(vH, SizeOf(vH));
      if not CompareMem(@vH.Magic[0], @CS_MAGIC[0], SizeOf(vH.Magic)) or
        (vH.Version <> SGCFS_INDEX_VERSION) or
        (vH.EntrySize <> SizeOf(TsgcFSearchEntry)) or (vH.RootCount < 0) or
        (vH.EntryCount < vH.RootCount) or (vH.NameCount < 0) or
        (vH.PoolChars < 0) then
        Exit;
      vNeed := SizeOf(vH) + Int64(vH.EntryCount) * SizeOf(TsgcFSearchEntry) +
        Int64(vH.NameCount) * SizeOf(Word) + Int64(vH.PoolChars) * SizeOf(Char)
        + SizeOf(vEnd) + Int64(vH.RootCount) * 28;
      if vNeed > vSize then
        Exit;
      // roots
      SetLength(vRoots, vH.RootCount);
      for i := 0 to vH.RootCount - 1 do
      begin
        vStream.ReadBuffer(vLen, SizeOf(vLen));
        if (vLen < 0) or (vLen > 32767) then
          Exit;
        SetLength(vRoots[i].Path, vLen);
        if vLen > 0 then
          vStream.ReadBuffer(vRoots[i].Path[1], vLen * SizeOf(Char));
        vStream.ReadBuffer(vRoots[i].EntryIdx, SizeOf(Int32));
        vStream.ReadBuffer(vRoots[i].VolumeSerial, SizeOf(Cardinal));
        vStream.ReadBuffer(vRoots[i].JournalId, SizeOf(UInt64));
        vStream.ReadBuffer(vRoots[i].NextUsn, SizeOf(Int64));
        if (vRoots[i].EntryIdx < 0) or (vRoots[i].EntryIdx >= vH.EntryCount)
        then
          Exit;
      end;
      // blocks
      SetLength(vEntries, vH.EntryCount);
      if vH.EntryCount > 0 then
        vStream.ReadBuffer(vEntries[0],
          vH.EntryCount * SizeOf(TsgcFSearchEntry));
      SetLength(vNameLens, vH.NameCount);
      if vH.NameCount > 0 then
        vStream.ReadBuffer(vNameLens[0], vH.NameCount * SizeOf(Word));
      SetLength(vPool, vH.PoolChars);
      if vH.PoolChars > 0 then
        vStream.ReadBuffer(vPool[0], vH.PoolChars * SizeOf(Char));
      vStream.ReadBuffer(vEnd, SizeOf(vEnd));
      if not CompareMem(@vEnd[0], @CS_END_MAGIC[0], SizeOf(vEnd)) then
        Exit;
    finally
      vStream.Free;
    end;
  except
    Exit(False);
  end;

  // ---- validate + rebuild derived tables (outside the lock)
  SetLength(vOfs, vH.NameCount);
  SetLength(vHash, vH.NameCount);
  vSum := 0;
  for i := 0 to vH.NameCount - 1 do
  begin
    vOfs[i] := vSum;
    Inc(vSum, vNameLens[i]);
    if vSum > vH.PoolChars then
      Exit;
    vHash[i] := DoHashName(@vPool[vOfs[i]], vNameLens[i]);
  end;
  if vSum <> vH.PoolChars then
    Exit;
  SetLength(vRootNo, vH.EntryCount);
  if vH.EntryCount > 0 then
    FillChar(vRootNo[0], vH.EntryCount * SizeOf(Int32), $FF);
  for r := 0 to vH.RootCount - 1 do
    vRootNo[vRoots[r].EntryIdx] := r;
  SetLength(vMaps, vH.RootCount);
  for r := 0 to vH.RootCount - 1 do
    vMaps[r].Clear;
  vFiles := 0;
  vFolders := 0;
  for i := 0 to vH.EntryCount - 1 do
  begin
    vE := @vEntries[i];
    if (vE.NameId < 0) or (vE.NameId >= vH.NameCount) or (vE.ParentIdx >= i) or
      (vE.FirstChild < -1) or (vE.FirstChild >= vH.EntryCount) or
      (vE.NextSibling < -1) or (vE.NextSibling >= vH.EntryCount) or
      ((vE.Flags and SGCFS_FLAG_DELETED) <> 0) then
      Exit;
    if vE.ParentIdx < 0 then
    begin
      if (vRootNo[i] < 0) or ((vE.Flags and SGCFS_FLAG_ROOT) = 0) then
        Exit;
    end
    else
      vRootNo[i] := vRootNo[vE.ParentIdx];
    if (vE.Flags and SGCFS_FLAG_DIR) <> 0 then
    begin
      if (vE.FileId <> 0) and (vRootNo[i] >= 0) then
        vMaps[vRootNo[i]].Put(vE.FileId, i);
      if (vE.Flags and SGCFS_FLAG_ROOT) = 0 then
        Inc(vFolders);
    end
    else
      Inc(vFiles);
  end;

  // ---- swap in
  BeginWrite;
  try
    FEntries := vEntries;
    FEntryCount := vH.EntryCount;
    FFreeHead := -1;
    FFileCount := vFiles;
    FFolderCount := vFolders;
    FPool := vPool;
    FPoolLen := vH.PoolChars;
    FNameOfs := vOfs;
    FNameLen := vNameLens;
    FNameHash := vHash;
    FNameCount := vH.NameCount;
    vSlots := 1024;
    while vSlots < FNameCount * 2 do
      vSlots := vSlots * 2;
    DoRehashNames(vSlots);
    FRoots := vRoots;
    FRootMaps := vMaps;
    Inc(FGeneration);
  finally
    EndWrite;
  end;
  Result := True;
end;

end.
