{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Trigram;

{$I sgcVer.inc}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
{ Trigram content index + background content indexer.

  TsgcFSearchContentIndex
  - Documents: docid -> path, size, mtime, flags. Docids only grow: an update
  tombstones the old docid and appends a new one, so every posting list
  stays sorted with plain appends. Tombstones are filtered out by the
  queries and dropped by Compact (SaveToFile compacts first).
  - Trigrams: 3 case-folded UTF-16 code units packed in a UInt64, one posting
  list per trigram (varint delta encoded docids), open addressing hash.
  - Thread-safe: every public method takes the TLightweightMREW itself (not
  reentrant, never call it back from inside). Docids are only stable until
  the next Compact / LoadFromFile: use CandidateDocs to get paths in the
  same lock.

  TsgcFSearchContentIndexer
  - Background thread (THREAD_MODE_BACKGROUND_BEGIN, COM MTA). Candidate
  files come from the name index: root subtrees walked through the child
  lists in short read-lock batches, files read with no lock held. Excluded
  folder names (node_modules, .git ...), skip folders and SGCFS_FLAG_OFFLINE
  / REPARSE / DENIED / SKIPPED entries are never read.
  - After LoadFromFile only files whose size / mtime changed are read again,
  files that vanished are removed.
  - NotifyChanged / NotifyRemoved queue paths (files or folders). Saving is
  the owner's job (ContentIndex.SaveToFile). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  // sgc
  sgcFSearch_Types, sgcFSearch_Index;

const
  SGCFS_CONTENT_FILE = 'content.idx';
  SGCFS_CONTENT_VERSION = 1;
  SGCFS_DOC_DELETED = $01; // tombstone
  SGCFS_DOC_EMPTY = $02; // no text (binary data / no extractor)
  SGCFS_EXCLUDED_FOLDERS = 'node_modules,.git,.svn,.hg,.bzr,obj,.vs,.idea,' +
    '__pycache__,.gradle,bower_components,$Recycle.Bin,AppData,.nuget,.npm,' +
    '.yarn,.cache,.tox,.venv,venv,.mypy_cache,.pytest_cache,__history,' +
    '__recovery,.terraform,System Volume Information,.next,.nuxt,.angular,' +
    '.parcel-cache,.dart_tool,.pub-cache,.m2,.cargo,.rustup';

type
  TsgcFSearchDocId = Int32;
  TsgcFSearchDocIds = TArray<TsgcFSearchDocId>;

  TsgcFSearchContentDoc = record
    DocId: TsgcFSearchDocId;
    Path: string;
    Size: Int64;
    MTime: Int64; // FILETIME UTC
  end;

  TsgcFSearchContentDocs = TArray<TsgcFSearchContentDoc>;

  /// One posting list (internal).
  TsgcFSearchPosting = record
    Key: UInt64;
    Data: TBytes; // varint deltas, first delta from -1
    DataLen: Int32;
    Count: Int32;
    LastDoc: Int32;
  end;

  TsgcFSearchContentIndex = class
  private
    FLock: TLightweightMREW;
    FGeneration: Int64;
    FPaths: TArray<string>;
    FSizes: TArray<Int64>;
    FMTimes: TArray<Int64>;
    FFlags: TArray<Byte>;
    FDocCount: Integer;
    FLiveCount: Integer;
    FDeadCount: Integer;
    FPathMap: TDictionary<string, Integer>;
    FPostings: TArray<TsgcFSearchPosting>;
    FPostingCount: Integer;
    FSlots: TArray<Int32>;
    FSlotKeys: TArray<UInt64>;
    FSlotMask: Integer;
    function DoFind(Key: UInt64): Integer;
    function DoFindOrAdd(Key: UInt64): Integer;
    procedure DoRehash(NewSize: Integer);
    procedure DoDeleteDoc(DocId: Integer);
    function DoCandidates(const Literals: TArray<string>): TsgcFSearchDocIds;
    procedure DoCompact;
    procedure DoClear;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    /// Indexes (or re-indexes) a document. Text = '' records the file with
    /// no content (never a candidate) so it is not read again.
    procedure AddOrUpdate(const Path: string; Size, MTime: Int64;
      const Text: string);
    /// Tombstones a document. False if Path is not indexed.
    function Remove(const Path: string): Boolean;
    /// Tombstones every document below Folder. Returns the count.
    function RemoveFolder(const Folder: string): Integer;
    /// Live documents holding every trigram of every literal (literals
    /// shorter than 3 chars add no constraint; none at all = every live
    /// document with text). Sorted docids.
    function Candidates(const Literals: TArray<string>): TsgcFSearchDocIds;
    /// Same as Candidates, resolved to path / size / mtime in the same lock.
    function CandidateDocs(const Literals: TArray<string>)
      : TsgcFSearchContentDocs;
    /// Path of a live document, '' otherwise.
    function DocPath(DocId: TsgcFSearchDocId): string;
    function FindDoc(const Path: string;
      out Doc: TsgcFSearchContentDoc): Boolean;
    function LivePaths: TArray<string>;
    /// Drops tombstones, renumbers docids (write lock).
    procedure Compact;
    /// Compacts, then writes FileName + '.tmp' under the read lock and
    /// replaces FileName (MoveFileEx). Raises on I/O errors.
    procedure SaveToFile(const FileName: string);
    /// Replaces the index with a file written by SaveToFile. False (index
    /// unchanged) if missing or invalid.
    function LoadFromFile(const FileName: string): Boolean;

    /// Live documents (documents with no text included).
    property DocCount: Integer read FLiveCount;
    property TrigramCount: Integer read FPostingCount;
    property Generation: Int64 read FGeneration;
  end;

  TsgcFSearchContentIndexer = class(TThread)
  private
    FNameIndex: TsgcFSearchIndex;
    FContentIndex: TsgcFSearchContentIndex;
    FRoots: TArray<string>;
    FRootsNorm: TArray<string>;
    FSkip: TArray<string>;
    FMaxBytes: Int64;
    FQueueLock: TCriticalSection;
    FQueue: TQueue<string>;
    FQueued: TDictionary<string, Boolean>;
    FEvent: TEvent;
    FPending: Integer;
    FIndexed: Int64;
    FScanDone: Boolean;
    function DoRootLen(const Path: string): Integer;
    function DoIsSkipped(const Folder: string): Boolean;
    function DoIsCandidateName(const Name: string): Boolean;
    procedure DoEnqueue(const Path: string; Removed: Boolean);
    function DoDequeue(out Path: string; out Removed: Boolean): Boolean;
    function DoWalk(const Folder: string;
      Seen: TDictionary<string, Boolean>): Boolean;
    procedure DoInitialScan;
    procedure DoProcess(const Path: string; Removed: Boolean);
  protected
    procedure Execute; override;
  public
    /// Created suspended: call Start. Roots / Skip are full folder paths.
    constructor Create(NameIndex: TsgcFSearchIndex;
      ContentIndex: TsgcFSearchContentIndex; const Roots, Skip: TArray<string>;
      MaxSizeMB: Integer);
    destructor Destroy; override;
    /// Terminates the thread and waits for it, at most TimeoutMs: False when
    /// it is still running then (do not free it).
    function Stop(TimeoutMs: Cardinal = INFINITE): Boolean;
    /// Queues a created / modified file (or folder: its indexed subtree).
    /// Paths outside the roots or in excluded folders are ignored.
    procedure NotifyChanged(const Path: string);
    /// Queues a deleted file or folder.
    procedure NotifyRemoved(const Path: string);
    /// Under a root, not in an excluded / skip folder, not a binary kind.
    function IsIndexablePath(const Path: string): Boolean;
    /// Waits until the initial scan is done and the queue is empty.
    function WaitIdle(TimeoutMs: Cardinal): Boolean;
    /// Files still to read (queue + the one being read).
    property Pending: Integer read FPending;
    /// Files whose text was indexed since Start.
    property Indexed: Int64 read FIndexed;
    property ScanDone: Boolean read FScanDone;
  end;

  /// Case folding (CharLowerBuffW table, 1:1 per UTF-16 code unit).
function sgcFSearchFoldChar(C: Char): Char;
function sgcFSearchFoldText(const S: string): string;
/// True for folder names never content-indexed (case-insensitive).
function sgcFSearchIsExcludedFolder(const Name: string): Boolean;

implementation

uses
  Winapi.ActiveX, System.Generics.Defaults,
  // sgc
  sgcFSearch_Extract;

const
  CS_MAGIC: array [0 .. 7] of AnsiChar = 'SGCFSCI1';
  CS_MAGIC_END: array [0 .. 7] of AnsiChar = 'SGCFSEND';
  CS_MIN_SLOTS = 4096;
  CS_WALK_BATCH = 4096;
  SGCFS_THREAD_MODE_BACKGROUND_BEGIN = $00010000;
  SGCFS_THREAD_MODE_BACKGROUND_END = $00020000;

var
  GFold: array [Char] of Char;
  GExcluded: TDictionary<string, Boolean>;

function sgcFSearchFoldChar(C: Char): Char;
begin
  Result := GFold[C];
end;

function sgcFSearchFoldText(const S: string): string;
var
  i: Integer;
  P: PChar;
begin
  SetLength(Result, Length(S));
  P := PChar(Result);
  for i := 1 to Length(S) do
  begin
    P^ := GFold[S[i]];
    Inc(P);
  end;
end;

function sgcFSearchIsExcludedFolder(const Name: string): Boolean;
begin
  Result := GExcluded.ContainsKey(Name);
end;

function DoHash(Key: UInt64): Cardinal; inline;
begin
  Result := Cardinal((Key * UInt64($9E3779B97F4A7C15)) shr 32);
end;

// Distinct trigram keys of a text (no lock needed).
function DoCollectKeys(const Text: string): TArray<UInt64>;
var
  vSet, vNew: TArray<UInt64>;
  vMask, vCount, n, i, j, h: Integer;
  vKey: UInt64;
  vHasZero: Boolean;
  P: PChar;
  c0, c1, c2: UInt64;
begin
  Result := nil;
  n := Length(Text);
  if n < 3 then
    Exit;
  SetLength(vSet, CS_MIN_SLOTS);
  vMask := CS_MIN_SLOTS - 1;
  vCount := 0;
  vHasZero := False;
  P := PChar(Text);
  c0 := Ord(GFold[P[0]]);
  c1 := Ord(GFold[P[1]]);
  for i := 2 to n - 1 do
  begin
    c2 := Ord(GFold[P[i]]);
    vKey := (c0 shl 32) or (c1 shl 16) or c2;
    c0 := c1;
    c1 := c2;
    if vKey = 0 then
    begin
      vHasZero := True;
      Continue;
    end;
    h := DoHash(vKey) and vMask;
    while (vSet[h] <> 0) and (vSet[h] <> vKey) do
      h := (h + 1) and vMask;
    if vSet[h] = 0 then
    begin
      vSet[h] := vKey;
      Inc(vCount);
      if vCount * 2 > Length(vSet) then
      begin
        SetLength(vNew, Length(vSet) * 2);
        vMask := Length(vNew) - 1;
        for j := 0 to High(vSet) do
          if vSet[j] <> 0 then
          begin
            h := DoHash(vSet[j]) and vMask;
            while vNew[h] <> 0 do
              h := (h + 1) and vMask;
            vNew[h] := vSet[j];
          end;
        vSet := vNew;
        vNew := nil;
      end;
    end;
  end;
  SetLength(Result, vCount + Ord(vHasZero));
  j := 0;
  for i := 0 to High(vSet) do
    if vSet[i] <> 0 then
    begin
      Result[j] := vSet[i];
      Inc(j);
    end;
  if vHasZero then
    Result[j] := 0;
end;

procedure DoAppend(var Posting: TsgcFSearchPosting; DocId: Integer);
var
  v: Cardinal;
  vCap: Integer;
begin
  if Posting.LastDoc = DocId then
    Exit;
  v := Cardinal(DocId - Posting.LastDoc);
  // room for one more varint (up to 5 bytes). Compact and LoadFromFile trim
  // Data to DataLen, so a short list can be full at 1 .. 7 bytes: growing
  // it to 8 bytes only overran the block, corrupted the heap and hung the
  // memory manager inside AddOrUpdate, with the write lock held.
  if Posting.DataLen + 5 > Length(Posting.Data) then
  begin
    vCap := Length(Posting.Data) * 2;
    if vCap < Posting.DataLen + 5 then
      vCap := Posting.DataLen + 5;
    if vCap < 8 then
      vCap := 8;
    SetLength(Posting.Data, vCap);
  end;
  while v >= $80 do
  begin
    Posting.Data[Posting.DataLen] := Byte(v or $80);
    Inc(Posting.DataLen);
    v := v shr 7;
  end;
  Posting.Data[Posting.DataLen] := Byte(v);
  Inc(Posting.DataLen);
  Posting.LastDoc := DocId;
  Inc(Posting.Count);
end;

function DoReadVarint(const Data: TBytes; var Pos: Integer; DataLen: Integer)
  : Cardinal;
var
  b: Byte;
  vShift: Integer;
begin
  Result := 0;
  vShift := 0;
  repeat
    if Pos >= DataLen then
      Exit(0);
    b := Data[Pos];
    Inc(Pos);
    Result := Result or (Cardinal(b and $7F) shl vShift);
    Inc(vShift, 7);
  until (b < $80) or (vShift > 28);
end;

function DoDecode(const Posting: TsgcFSearchPosting): TsgcFSearchDocIds;
var
  vPos, vId, n: Integer;
begin
  SetLength(Result, Posting.Count);
  vPos := 0;
  vId := -1;
  n := 0;
  while (vPos < Posting.DataLen) and (n < Posting.Count) do
  begin
    Inc(vId, Integer(DoReadVarint(Posting.Data, vPos, Posting.DataLen)));
    Result[n] := vId;
    Inc(n);
  end;
  SetLength(Result, n);
end;

// In place intersection of sorted A[0 .. Count - 1] with a posting list.
function DoIntersect(var A: TsgcFSearchDocIds; Count: Integer;
  const Posting: TsgcFSearchPosting): Integer;
var
  i, vPos, vId: Integer;
begin
  Result := 0;
  i := 0;
  vPos := 0;
  vId := -1;
  while (i < Count) and (vPos < Posting.DataLen) do
  begin
    Inc(vId, Integer(DoReadVarint(Posting.Data, vPos, Posting.DataLen)));
    while (i < Count) and (A[i] < vId) do
      Inc(i);
    if (i < Count) and (A[i] = vId) then
    begin
      A[Result] := vId;
      Inc(Result);
      Inc(i);
    end;
  end;
end;

// Re-encodes a posting with a docid map (-1 = dropped), in place (the
// output never overtakes the input: mapped deltas are never larger).
procedure DoRemap(var Posting: TsgcFSearchPosting; const Map: TArray<Int32>);
var
  vIn, vOut, vOld, vNew, vLast, vCount, vMapped: Integer;
  v: Cardinal;
begin
  vIn := 0;
  vOut := 0;
  vOld := -1;
  vLast := -1;
  vCount := 0;
  while vIn < Posting.DataLen do
  begin
    Inc(vOld, Integer(DoReadVarint(Posting.Data, vIn, Posting.DataLen)));
    if (vOld < 0) or (vOld >= Length(Map)) then
      Break;
    vMapped := Map[vOld];
    if vMapped < 0 then
      Continue;
    vNew := vMapped;
    v := Cardinal(vNew - vLast);
    while v >= $80 do
    begin
      Posting.Data[vOut] := Byte(v or $80);
      Inc(vOut);
      v := v shr 7;
    end;
    Posting.Data[vOut] := Byte(v);
    Inc(vOut);
    vLast := vNew;
    Inc(vCount);
  end;
  Posting.DataLen := vOut;
  Posting.Count := vCount;
  Posting.LastDoc := vLast;
end;

{ TsgcFSearchContentIndex }

constructor TsgcFSearchContentIndex.Create;
begin
  inherited Create;
  FPathMap := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  DoClear;
end;

destructor TsgcFSearchContentIndex.Destroy;
begin
  FPathMap.Free;
  inherited;
end;

procedure TsgcFSearchContentIndex.DoClear;
begin
  FPaths := nil;
  FSizes := nil;
  FMTimes := nil;
  FFlags := nil;
  FDocCount := 0;
  FLiveCount := 0;
  FDeadCount := 0;
  FPathMap.Clear;
  FPostings := nil;
  FPostingCount := 0;
  DoRehash(CS_MIN_SLOTS);
  Inc(FGeneration);
end;

procedure TsgcFSearchContentIndex.Clear;
begin
  FLock.BeginWrite;
  try
    DoClear;
  finally
    FLock.EndWrite;
  end;
end;

procedure TsgcFSearchContentIndex.DoRehash(NewSize: Integer);
var
  i, h: Integer;
begin
  SetLength(FSlots, NewSize);
  SetLength(FSlotKeys, NewSize);
  FSlotMask := NewSize - 1;
  for i := 0 to NewSize - 1 do
    FSlots[i] := -1;
  for i := 0 to FPostingCount - 1 do
  begin
    h := DoHash(FPostings[i].Key) and FSlotMask;
    while FSlots[h] >= 0 do
      h := (h + 1) and FSlotMask;
    FSlots[h] := i;
    FSlotKeys[h] := FPostings[i].Key;
  end;
end;

function TsgcFSearchContentIndex.DoFind(Key: UInt64): Integer;
var
  h: Integer;
begin
  h := DoHash(Key) and FSlotMask;
  while FSlots[h] >= 0 do
  begin
    if FSlotKeys[h] = Key then
      Exit(FSlots[h]);
    h := (h + 1) and FSlotMask;
  end;
  Result := -1;
end;

function TsgcFSearchContentIndex.DoFindOrAdd(Key: UInt64): Integer;
var
  h: Integer;
begin
  if (FPostingCount + 1) * 2 > Length(FSlots) then
    DoRehash(Length(FSlots) * 2);
  h := DoHash(Key) and FSlotMask;
  while FSlots[h] >= 0 do
  begin
    if FSlotKeys[h] = Key then
      Exit(FSlots[h]);
    h := (h + 1) and FSlotMask;
  end;
  if FPostingCount = Length(FPostings) then
  begin
    if FPostingCount < 1024 then
      SetLength(FPostings, 1024)
    else
      SetLength(FPostings, FPostingCount * 2);
  end;
  Result := FPostingCount;
  Inc(FPostingCount);
  FPostings[Result].Key := Key;
  FPostings[Result].Data := nil;
  FPostings[Result].DataLen := 0;
  FPostings[Result].Count := 0;
  FPostings[Result].LastDoc := -1;
  FSlots[h] := Result;
  FSlotKeys[h] := Key;
end;

procedure TsgcFSearchContentIndex.DoDeleteDoc(DocId: Integer);
begin
  if (FFlags[DocId] and SGCFS_DOC_DELETED) <> 0 then
    Exit;
  FFlags[DocId] := FFlags[DocId] or SGCFS_DOC_DELETED;
  FPaths[DocId] := '';
  Dec(FLiveCount);
  Inc(FDeadCount);
end;

procedure TsgcFSearchContentIndex.AddOrUpdate(const Path: string;
  Size, MTime: Int64; const Text: string);
var
  vKeys: TArray<UInt64>;
  vOld, vId, vCap, i, j: Integer;
begin
  vKeys := DoCollectKeys(Text); // outside the lock
  FLock.BeginWrite;
  try
    if FPathMap.TryGetValue(Path, vOld) then
      DoDeleteDoc(vOld);
    if FDocCount = Length(FPaths) then
    begin
      vCap := FDocCount * 2;
      if vCap < 1024 then
        vCap := 1024;
      SetLength(FPaths, vCap);
      SetLength(FSizes, vCap);
      SetLength(FMTimes, vCap);
      SetLength(FFlags, vCap);
    end;
    vId := FDocCount;
    Inc(FDocCount);
    FPaths[vId] := Path;
    FSizes[vId] := Size;
    FMTimes[vId] := MTime;
    if Text = '' then
      FFlags[vId] := SGCFS_DOC_EMPTY
    else
      FFlags[vId] := 0;
    FPathMap.AddOrSetValue(Path, vId);
    Inc(FLiveCount);
    for i := 0 to High(vKeys) do
    begin
      j := DoFindOrAdd(vKeys[i]);
      DoAppend(FPostings[j], vId);
    end;
    Inc(FGeneration);
  finally
    FLock.EndWrite;
  end;
end;

function TsgcFSearchContentIndex.Remove(const Path: string): Boolean;
var
  vId: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FPathMap.TryGetValue(Path, vId);
    if Result then
    begin
      FPathMap.Remove(Path);
      DoDeleteDoc(vId);
      Inc(FGeneration);
    end;
  finally
    FLock.EndWrite;
  end;
end;

function TsgcFSearchContentIndex.RemoveFolder(const Folder: string): Integer;
var
  vPrefix: string;
  i: Integer;
begin
  Result := 0;
  vPrefix := IncludeTrailingPathDelimiter(Folder);
  FLock.BeginWrite;
  try
    for i := 0 to FDocCount - 1 do
      if ((FFlags[i] and SGCFS_DOC_DELETED) = 0) and
        (Length(FPaths[i]) > Length(vPrefix)) and
        (StrLIComp(PChar(FPaths[i]), PChar(vPrefix), Length(vPrefix)) = 0) then
      begin
        FPathMap.Remove(FPaths[i]);
        DoDeleteDoc(i);
        Inc(Result);
      end;
    if Result > 0 then
      Inc(FGeneration);
  finally
    FLock.EndWrite;
  end;
end;

function TsgcFSearchContentIndex.DoCandidates(const Literals: TArray<string>)
  : TsgcFSearchDocIds;
var
  vList: TArray<Integer>;
  vFolded: string;
  vKey: UInt64;
  vAny, vDup: Boolean;
  i, j, k, n, P, vCount: Integer;
begin
  Result := nil;
  vAny := False;
  n := 0;
  for i := 0 to High(Literals) do
  begin
    if Length(Literals[i]) < 3 then
      Continue;
    vAny := True;
    vFolded := sgcFSearchFoldText(Literals[i]);
    for j := 3 to Length(vFolded) do
    begin
      vKey := (UInt64(Ord(vFolded[j - 2])) shl 32) or
        (UInt64(Ord(vFolded[j - 1])) shl 16) or UInt64(Ord(vFolded[j]));
      P := DoFind(vKey);
      if P < 0 then
        Exit; // a trigram no document has
      vDup := False;
      for k := 0 to n - 1 do
        if vList[k] = P then
        begin
          vDup := True;
          Break;
        end;
      if not vDup then
      begin
        if n = Length(vList) then
          SetLength(vList, n * 2 + 8);
        vList[n] := P;
        Inc(n);
      end;
    end;
  end;
  if not vAny then
  begin
    SetLength(Result, FLiveCount);
    vCount := 0;
    for i := 0 to FDocCount - 1 do
      if (FFlags[i] and (SGCFS_DOC_DELETED or SGCFS_DOC_EMPTY)) = 0 then
      begin
        Result[vCount] := i;
        Inc(vCount);
      end;
    SetLength(Result, vCount);
    Exit;
  end;
  // shortest posting list first
  for i := 1 to n - 1 do
  begin
    P := vList[i];
    j := i - 1;
    while (j >= 0) and (FPostings[vList[j]].Count > FPostings[P].Count) do
    begin
      vList[j + 1] := vList[j];
      Dec(j);
    end;
    vList[j + 1] := P;
  end;
  Result := DoDecode(FPostings[vList[0]]);
  vCount := Length(Result);
  for i := 1 to n - 1 do
  begin
    if vCount = 0 then
      Break;
    vCount := DoIntersect(Result, vCount, FPostings[vList[i]]);
  end;
  n := 0;
  for i := 0 to vCount - 1 do
    if (Result[i] >= 0) and (Result[i] < FDocCount) and
      ((FFlags[Result[i]] and (SGCFS_DOC_DELETED or SGCFS_DOC_EMPTY)) = 0) then
    begin
      Result[n] := Result[i];
      Inc(n);
    end;
  SetLength(Result, n);
end;

function TsgcFSearchContentIndex.Candidates(const Literals: TArray<string>)
  : TsgcFSearchDocIds;
begin
  FLock.BeginRead;
  try
    Result := DoCandidates(Literals);
  finally
    FLock.EndRead;
  end;
end;

function TsgcFSearchContentIndex.CandidateDocs(const Literals: TArray<string>)
  : TsgcFSearchContentDocs;
var
  vIds: TsgcFSearchDocIds;
  i: Integer;
begin
  FLock.BeginRead;
  try
    vIds := DoCandidates(Literals);
    SetLength(Result, Length(vIds));
    for i := 0 to High(vIds) do
    begin
      Result[i].DocId := vIds[i];
      Result[i].Path := FPaths[vIds[i]];
      Result[i].Size := FSizes[vIds[i]];
      Result[i].MTime := FMTimes[vIds[i]];
    end;
  finally
    FLock.EndRead;
  end;
end;

function TsgcFSearchContentIndex.DocPath(DocId: TsgcFSearchDocId): string;
begin
  Result := '';
  FLock.BeginRead;
  try
    if (DocId >= 0) and (DocId < FDocCount) and
      ((FFlags[DocId] and SGCFS_DOC_DELETED) = 0) then
      Result := FPaths[DocId];
  finally
    FLock.EndRead;
  end;
end;

function TsgcFSearchContentIndex.FindDoc(const Path: string;
  out Doc: TsgcFSearchContentDoc): Boolean;
var
  vId: Integer;
begin
  FLock.BeginRead;
  try
    Result := FPathMap.TryGetValue(Path, vId);
    if Result then
    begin
      Doc.DocId := vId;
      Doc.Path := FPaths[vId];
      Doc.Size := FSizes[vId];
      Doc.MTime := FMTimes[vId];
    end
    else
    begin
      Doc.DocId := -1;
      Doc.Path := '';
      Doc.Size := 0;
      Doc.MTime := 0;
    end;
  finally
    FLock.EndRead;
  end;
end;

function TsgcFSearchContentIndex.LivePaths: TArray<string>;
var
  i, n: Integer;
begin
  FLock.BeginRead;
  try
    SetLength(Result, FLiveCount);
    n := 0;
    for i := 0 to FDocCount - 1 do
      if (FFlags[i] and SGCFS_DOC_DELETED) = 0 then
      begin
        Result[n] := FPaths[i];
        Inc(n);
      end;
    SetLength(Result, n);
  finally
    FLock.EndRead;
  end;
end;

procedure TsgcFSearchContentIndex.DoCompact;
var
  vMap: TArray<Int32>;
  i, n: Integer;
begin
  if FDeadCount = 0 then
    Exit;
  SetLength(vMap, FDocCount);
  n := 0;
  for i := 0 to FDocCount - 1 do
    if (FFlags[i] and SGCFS_DOC_DELETED) = 0 then
    begin
      vMap[i] := n;
      FPaths[n] := FPaths[i];
      FSizes[n] := FSizes[i];
      FMTimes[n] := FMTimes[i];
      FFlags[n] := FFlags[i];
      Inc(n);
    end
    else
      vMap[i] := -1;
  for i := n to FDocCount - 1 do
    FPaths[i] := '';
  FDocCount := n;
  FDeadCount := 0;
  FPathMap.Clear;
  for i := 0 to FDocCount - 1 do
    FPathMap.AddOrSetValue(FPaths[i], i);
  n := 0;
  for i := 0 to FPostingCount - 1 do
  begin
    DoRemap(FPostings[i], vMap);
    if FPostings[i].Count = 0 then
      Continue;
    SetLength(FPostings[i].Data, FPostings[i].DataLen);
    if n <> i then
      FPostings[n] := FPostings[i];
    Inc(n);
  end;
  for i := n to FPostingCount - 1 do
    FPostings[i].Data := nil;
  FPostingCount := n;
  DoRehash(Length(FSlots));
  Inc(FGeneration);
end;

procedure TsgcFSearchContentIndex.Compact;
begin
  FLock.BeginWrite;
  try
    DoCompact;
  finally
    FLock.EndWrite;
  end;
end;

procedure TsgcFSearchContentIndex.SaveToFile(const FileName: string);
var
  vStream: TStream;
  vMap: TArray<Int32>;
  vTmp: TsgcFSearchPosting;
  vTemp: string;
  i, n, vLen: Integer;
  vDirty: Boolean;
begin
  Compact;
  vTemp := FileName + '.tmp';
  FLock.BeginRead;
  try
    vStream := TBufferedFileStream.Create(vTemp, fmCreate, 1024 * 1024);
    try
      // a writer may have tombstoned documents since Compact: remap again
      SetLength(vMap, FDocCount);
      n := 0;
      for i := 0 to FDocCount - 1 do
        if (FFlags[i] and SGCFS_DOC_DELETED) = 0 then
        begin
          vMap[i] := n;
          Inc(n);
        end
        else
          vMap[i] := -1;
      vDirty := n <> FDocCount;
      vStream.WriteBuffer(CS_MAGIC, SizeOf(CS_MAGIC));
      i := SGCFS_CONTENT_VERSION;
      vStream.WriteBuffer(i, SizeOf(i));
      vStream.WriteBuffer(n, SizeOf(n));
      vStream.WriteBuffer(FPostingCount, SizeOf(FPostingCount));
      for i := 0 to FDocCount - 1 do
        if vMap[i] >= 0 then
        begin
          vStream.WriteBuffer(FFlags[i], SizeOf(Byte));
          vStream.WriteBuffer(FSizes[i], SizeOf(Int64));
          vStream.WriteBuffer(FMTimes[i], SizeOf(Int64));
          vLen := Length(FPaths[i]);
          vStream.WriteBuffer(vLen, SizeOf(vLen));
          if vLen > 0 then
            vStream.WriteBuffer(PChar(FPaths[i])^, vLen * SizeOf(Char));
        end;
      for i := 0 to FPostingCount - 1 do
      begin
        vTmp := FPostings[i];
        if vDirty then
        begin
          vTmp.Data := Copy(FPostings[i].Data, 0, FPostings[i].DataLen);
          DoRemap(vTmp, vMap);
        end;
        vStream.WriteBuffer(vTmp.Key, SizeOf(UInt64));
        vStream.WriteBuffer(vTmp.Count, SizeOf(Int32));
        vStream.WriteBuffer(vTmp.DataLen, SizeOf(Int32));
        if vTmp.DataLen > 0 then
          vStream.WriteBuffer(vTmp.Data[0], vTmp.DataLen);
      end;
      vStream.WriteBuffer(CS_MAGIC_END, SizeOf(CS_MAGIC_END));
    finally
      vStream.Free;
    end;
  finally
    FLock.EndRead;
  end;
  if not MoveFileEx(PChar(vTemp), PChar(FileName), MOVEFILE_REPLACE_EXISTING or
    MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function TsgcFSearchContentIndex.LoadFromFile(const FileName: string): Boolean;
var
  vBytes: TBytes;
  vStream: TFileStream;
  vPos, vDocs, vPosts, vVersion, vLen, i, vSize: Integer;
  vPaths: TArray<string>;
  vSizes, vMTimes: TArray<Int64>;
  vFlags: TArray<Byte>;
  vPostings: TArray<TsgcFSearchPosting>;
  vMap: TDictionary<string, Integer>;
  vIds: TsgcFSearchDocIds;
  vMagic: array [0 .. 7] of AnsiChar;

  function Take(var Dest; Count: Integer): Boolean;
  begin
    Result := (Count >= 0) and (vPos + Count <= vSize);
    if Result and (Count > 0) then
    begin
      Move(vBytes[vPos], Dest, Count);
      Inc(vPos, Count);
    end;
  end;

begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  try
    vStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      if vStream.Size > MaxInt then
        Exit;
      vSize := vStream.Size;
      SetLength(vBytes, vSize);
      if vSize > 0 then
        vStream.ReadBuffer(vBytes[0], vSize);
    finally
      vStream.Free;
    end;
  except
    Exit;
  end;
  vPos := 0;
  if not Take(vMagic, SizeOf(vMagic)) or not CompareMem(@vMagic, @CS_MAGIC,
    SizeOf(vMagic)) then
    Exit;
  if not Take(vVersion, 4) or (vVersion <> SGCFS_CONTENT_VERSION) then
    Exit;
  if not Take(vDocs, 4) or not Take(vPosts, 4) or (vDocs < 0) or (vPosts < 0)
  then
    Exit;
  if (vDocs > vSize) or (vPosts > vSize) then
    Exit;
  vMap := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  try
    SetLength(vPaths, vDocs);
    SetLength(vSizes, vDocs);
    SetLength(vMTimes, vDocs);
    SetLength(vFlags, vDocs);
    for i := 0 to vDocs - 1 do
    begin
      if not Take(vFlags[i], 1) or not Take(vSizes[i], 8) or
        not Take(vMTimes[i], 8) or not Take(vLen, 4) then
        Exit;
      if (vLen < 0) or (vLen > 32767) or (vPos + vLen * 2 > vSize) then
        Exit;
      vFlags[i] := vFlags[i] and SGCFS_DOC_EMPTY;
      SetString(vPaths[i], PChar(@vBytes[vPos]), vLen);
      Inc(vPos, vLen * 2);
      vMap.AddOrSetValue(vPaths[i], i);
    end;
    SetLength(vPostings, vPosts);
    for i := 0 to vPosts - 1 do
    begin
      if not Take(vPostings[i].Key, 8) or not Take(vPostings[i].Count, 4) or
        not Take(vPostings[i].DataLen, 4) then
        Exit;
      if (vPostings[i].DataLen < 0) or (vPostings[i].Count < 0) or
        (vPos + vPostings[i].DataLen > vSize) then
        Exit;
      vPostings[i].Data := Copy(vBytes, vPos, vPostings[i].DataLen);
      Inc(vPos, vPostings[i].DataLen);
      vIds := DoDecode(vPostings[i]);
      if Length(vIds) <> vPostings[i].Count then
        Exit;
      if Length(vIds) > 0 then
      begin
        if (vIds[0] < 0) or (vIds[High(vIds)] >= vDocs) then
          Exit;
        vPostings[i].LastDoc := vIds[High(vIds)];
      end
      else
        vPostings[i].LastDoc := -1;
    end;
    if not Take(vMagic, SizeOf(vMagic)) or
      not CompareMem(@vMagic, @CS_MAGIC_END, SizeOf(vMagic)) then
      Exit;
    FLock.BeginWrite;
    try
      FPaths := vPaths;
      FSizes := vSizes;
      FMTimes := vMTimes;
      FFlags := vFlags;
      FDocCount := vDocs;
      FLiveCount := vDocs;
      FDeadCount := 0;
      FPathMap.Clear;
      for i := 0 to vDocs - 1 do
        FPathMap.AddOrSetValue(vPaths[i], i);
      FPostings := vPostings;
      FPostingCount := vPosts;
      vSize := CS_MIN_SLOTS;
      while vSize < vPosts * 2 + 2 do
        vSize := vSize * 2;
      DoRehash(vSize);
      Inc(FGeneration);
    finally
      FLock.EndWrite;
    end;
    Result := True;
  finally
    vMap.Free;
  end;
end;

{ TsgcFSearchContentIndexer }

constructor TsgcFSearchContentIndexer.Create(NameIndex: TsgcFSearchIndex;
  ContentIndex: TsgcFSearchContentIndex; const Roots, Skip: TArray<string>;
  MaxSizeMB: Integer);
var
  i: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FNameIndex := NameIndex;
  FContentIndex := ContentIndex;
  FRoots := Copy(Roots);
  SetLength(FRootsNorm, Length(FRoots));
  for i := 0 to High(FRoots) do
    FRootsNorm[i] := ExcludeTrailingPathDelimiter(FRoots[i]);
  SetLength(FSkip, Length(Skip));
  for i := 0 to High(Skip) do
    FSkip[i] := ExcludeTrailingPathDelimiter(Skip[i]);
  FMaxBytes := Int64(MaxSizeMB) * 1024 * 1024;
  FQueueLock := TCriticalSection.Create;
  FQueue := TQueue<string>.Create;
  FQueued := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  FEvent := TEvent.Create(nil, False, False, '');
end;

destructor TsgcFSearchContentIndexer.Destroy;
begin
  Stop;
  inherited;
  FEvent.Free;
  FQueued.Free;
  FQueue.Free;
  FQueueLock.Free;
end;

function TsgcFSearchContentIndexer.Stop(TimeoutMs: Cardinal): Boolean;
begin
  Terminate;
  FEvent.SetEvent;
  Result := True;
  if Started and not Finished then
  begin
    if TimeoutMs = INFINITE then
      WaitFor
    else
      Result := WaitForSingleObject(Handle, TimeoutMs) = WAIT_OBJECT_0;
  end;
end;

function TsgcFSearchContentIndexer.DoRootLen(const Path: string): Integer;
var
  i, n: Integer;
begin
  for i := 0 to High(FRootsNorm) do
  begin
    n := Length(FRootsNorm[i]);
    if (Length(Path) > n + 1) and (Path[n + 1] = '\') and
      (StrLIComp(PChar(Path), PChar(FRootsNorm[i]), n) = 0) then
      Exit(n);
  end;
  Result := -1;
end;

function TsgcFSearchContentIndexer.DoIsSkipped(const Folder: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FSkip) do
    if SameText(Folder, FSkip[i]) then
      Exit(True);
  Result := False;
end;

function TsgcFSearchContentIndexer.DoIsCandidateName
  (const Name: string): Boolean;
begin
  case sgcFSearchFileKind(Name) of
    fsfkBinary:
      Result := False;
    fsfkIFilter:
      Result := sgcFSearchIFilterAvailable(sgcFSearchFileExt(Name));
  else
    Result := True;
  end;
end;

function TsgcFSearchContentIndexer.IsIndexablePath(const Path: string): Boolean;
var
  i, vStart: Integer;
begin
  vStart := DoRootLen(Path);
  if vStart < 0 then
    Exit(False);
  Inc(vStart, 2); // first char after the root's '\'
  for i := vStart to Length(Path) do
    if Path[i] = '\' then
    begin
      if sgcFSearchIsExcludedFolder(Copy(Path, vStart, i - vStart)) or
        DoIsSkipped(Copy(Path, 1, i - 1)) then
        Exit(False);
      vStart := i + 1;
    end;
  Result := DoIsCandidateName(Path);
end;

procedure TsgcFSearchContentIndexer.DoEnqueue(const Path: string;
  Removed: Boolean);
begin
  FQueueLock.Enter;
  try
    if not FQueued.ContainsKey(Path) then
    begin
      FQueue.Enqueue(Path);
      TInterlocked.Increment(FPending);
    end;
    FQueued.AddOrSetValue(Path, Removed);
  finally
    FQueueLock.Leave;
  end;
  FEvent.SetEvent;
end;

function TsgcFSearchContentIndexer.DoDequeue(out Path: string;
  out Removed: Boolean): Boolean;
begin
  FQueueLock.Enter;
  try
    Result := FQueue.Count > 0;
    if Result then
    begin
      Path := FQueue.Dequeue;
      if not FQueued.TryGetValue(Path, Removed) then
        Removed := False;
      FQueued.Remove(Path);
    end;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TsgcFSearchContentIndexer.NotifyChanged(const Path: string);
begin
  if DoRootLen(Path) >= 0 then
    DoEnqueue(Path, False);
end;

procedure TsgcFSearchContentIndexer.NotifyRemoved(const Path: string);
begin
  if DoRootLen(Path) >= 0 then
    DoEnqueue(Path, True);
end;

function TsgcFSearchContentIndexer.WaitIdle(TimeoutMs: Cardinal): Boolean;
var
  vStart: UInt64;
begin
  vStart := GetTickCount64;
  repeat
    if FScanDone and (FPending = 0) then
      Exit(True);
    if Finished then
      Exit(False);
    Sleep(5);
  until GetTickCount64 - vStart >= TimeoutMs;
  Result := False;
end;

type
  TsgcFSearchWalkItem = record
    Idx: Integer;
    Path: string;
  end;

  TsgcFSearchWalkFile = record
    Path: string;
    Size: Int64;
    MTime: Int64;
  end;

function DoJoin(const Folder, Name: string): string;
begin
  if (Folder <> '') and (Folder[Length(Folder)] = '\') then
    Result := Folder + Name
  else
    Result := Folder + '\' + Name;
end;

function TsgcFSearchContentIndexer.DoWalk(const Folder: string;
  Seen: TDictionary<string, Boolean>): Boolean;
const
  CS_SKIP_FLAGS = SGCFS_FLAG_DELETED or SGCFS_FLAG_REPARSE or
    SGCFS_FLAG_OFFLINE or SGCFS_FLAG_DENIED or SGCFS_FLAG_SKIPPED;
var
  vStack: TList<TsgcFSearchWalkItem>;
  vFiles: TList<TsgcFSearchWalkFile>;
  vItem, vSub: TsgcFSearchWalkItem;
  vFile: TsgcFSearchWalkFile;
  vEntry: PsgcFSearchEntry;
  vDoc: TsgcFSearchContentDoc;
  vGen: Int64;
  vResolve: Boolean;
  vBudget, vChild: Integer;
  vName: string;
begin
  Result := False;
  vStack := TList<TsgcFSearchWalkItem>.Create;
  vFiles := TList<TsgcFSearchWalkFile>.Create;
  try
    FNameIndex.BeginRead;
    try
      vItem.Idx := FNameIndex.FindPath(Folder);
      if (vItem.Idx < 0) or
        ((FNameIndex.EntryPtr(vItem.Idx).Flags and SGCFS_FLAG_DIR) = 0) then
        Exit;
      vItem.Path := Folder;
      vStack.Add(vItem);
      vGen := FNameIndex.Generation;
    finally
      FNameIndex.EndRead;
    end;
    while (vStack.Count > 0) and not Terminated do
    begin
      vFiles.Clear;
      FNameIndex.BeginRead;
      try
        vResolve := FNameIndex.Generation <> vGen;
        vBudget := CS_WALK_BATCH;
        while (vStack.Count > 0) and (vBudget > 0) do
        begin
          vItem := vStack.Last;
          vStack.Delete(vStack.Count - 1);
          if vResolve then
            vItem.Idx := FNameIndex.FindPath(vItem.Path);
          if (vItem.Idx < 0) or not FNameIndex.IsLive(vItem.Idx) then
            Continue;
          vEntry := FNameIndex.EntryPtr(vItem.Idx);
          if (vEntry.Flags and SGCFS_FLAG_DIR) = 0 then
            Continue;
          vChild := vEntry.FirstChild;
          while vChild >= 0 do
          begin
            vEntry := FNameIndex.EntryPtr(vChild);
            Dec(vBudget);
            if (vEntry.Flags and CS_SKIP_FLAGS) = 0 then
            begin
              vName := FNameIndex.NameOf(vChild);
              if (vEntry.Flags and SGCFS_FLAG_DIR) <> 0 then
              begin
                if not sgcFSearchIsExcludedFolder(vName) then
                begin
                  vFile.Path := DoJoin(vItem.Path, vName);
                  if not DoIsSkipped(vFile.Path) then
                  begin
                    vSub.Idx := vChild;
                    vSub.Path := vFile.Path;
                    vStack.Add(vSub);
                  end;
                end;
              end
              else if ((FMaxBytes <= 0) or (vEntry.Size <= FMaxBytes)) and
                DoIsCandidateName(vName) then
              begin
                vFile.Path := DoJoin(vItem.Path, vName);
                vFile.Size := vEntry.Size;
                vFile.MTime := vEntry.MTime;
                vFiles.Add(vFile);
              end;
            end;
            vChild := vEntry.NextSibling;
          end;
        end;
        vGen := FNameIndex.Generation;
      finally
        FNameIndex.EndRead;
      end;
      // no name index lock held from here
      for vFile in vFiles do
      begin
        if Seen <> nil then
          Seen.AddOrSetValue(vFile.Path, True);
        if not(FContentIndex.FindDoc(vFile.Path, vDoc) and
          (vDoc.Size = vFile.Size) and (vDoc.MTime = vFile.MTime)) then
          DoEnqueue(vFile.Path, False);
      end;
    end;
    Result := not Terminated;
  finally
    vFiles.Free;
    vStack.Free;
  end;
end;

procedure TsgcFSearchContentIndexer.DoInitialScan;
var
  vSeen: TDictionary<string, Boolean>;
  vAll: Boolean;
  vPath: string;
  i: Integer;
begin
  vSeen := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  try
    vAll := True;
    for i := 0 to High(FRoots) do
      if not Terminated and not DoWalk(FRoots[i], vSeen) then
        vAll := False;
    // vanished files: only when every root was walked completely
    if vAll and not Terminated then
      for vPath in FContentIndex.LivePaths do
        if not vSeen.ContainsKey(vPath) then
          FContentIndex.Remove(vPath);
  finally
    vSeen.Free;
  end;
end;

procedure TsgcFSearchContentIndexer.DoProcess(const Path: string;
  Removed: Boolean);
var
  vAttributes: Cardinal;
  vSize, vMTime: Int64;
  vDoc: TsgcFSearchContentDoc;
  vText: string;
begin
  if Removed then
  begin
    if not FContentIndex.Remove(Path) then
      FContentIndex.RemoveFolder(Path);
    Exit;
  end;
  if not sgcFSearchGetFileInfo(Path, vAttributes, vSize, vMTime) then
  begin
    if not FContentIndex.Remove(Path) then
      FContentIndex.RemoveFolder(Path);
    Exit;
  end;
  if (vAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
  begin
    if IsIndexablePath(DoJoin(Path, 'x')) then
      DoWalk(Path, nil);
    Exit;
  end;
  if not IsIndexablePath(Path) then
    Exit;
  if FContentIndex.FindDoc(Path, vDoc) and (vDoc.Size = vSize) and
    (vDoc.MTime = vMTime) then
    Exit;
  case sgcFSearchExtractText(Path, FMaxBytes, vText) of
    fserOK:
      begin
        FContentIndex.AddOrUpdate(Path, vSize, vMTime, vText);
        TInterlocked.Increment(FIndexed);
      end;
    fserBinary, fserUnsupported:
      FContentIndex.AddOrUpdate(Path, vSize, vMTime, '');
    fserTooBig, fserOffline:
      FContentIndex.Remove(Path);
  end; // fserError: locked / vanished, retried on the next change
end;

procedure TsgcFSearchContentIndexer.Execute;
var
  vInit: HRESULT;
  vPath: string;
  vRemoved: Boolean;
begin
  NameThreadForDebugging('sgcFSearch content indexer');
  vInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  SetThreadPriority(GetCurrentThread, SGCFS_THREAD_MODE_BACKGROUND_BEGIN);
  try
    try
      DoInitialScan;
    except
      // keep the thread alive: queued changes still get indexed
    end;
    FScanDone := True;
    while not Terminated do
    begin
      if DoDequeue(vPath, vRemoved) then
      begin
        try
          DoProcess(vPath, vRemoved);
        except
          // one bad file must not stop the indexer
        end;
        TInterlocked.Decrement(FPending);
      end
      else
        FEvent.WaitFor(1000);
    end;
  finally
    SetThreadPriority(GetCurrentThread, SGCFS_THREAD_MODE_BACKGROUND_END);
    if Succeeded(vInit) then
      CoUninitialize;
  end;
end;

procedure DoInitUnit;
var
  C: Char;
  vName: string;
begin
  for C := Low(Char) to High(Char) do
    GFold[C] := C;
  CharLowerBuffW(@GFold[#1], 65535);
  GExcluded := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  for vName in string(SGCFS_EXCLUDED_FOLDERS).Split([',']) do
    GExcluded.AddOrSetValue(vName, True);
end;

initialization

DoInitUnit;

finalization

GExcluded.Free;

end.
