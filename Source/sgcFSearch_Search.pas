{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Search;

{$I sgcVer.inc}
{ Name search over a TsgcFSearchIndex.

  Search takes the index read lock itself (call it without holding the
  lock). It runs in two parallel passes:
  1. every distinct name is scored once per term into a per-name byte
  (quality tier, exact-case bit, ext / type bits; name regex applied) and,
  for path tokens, a per-name bit mask of the matching folder components;
  2. every entry combines its name byte with the cheap filters (kind, ext,
  type, size, mtime), path tokens via the ancestor names, in: scope via a
  memoised per-query state array, path: via FullPath last. Matches go to a
  top-K heap per chunk, the heaps are merged at the end.

  Caches kept by the searcher (guarded by an internal lock, rebuilt while the
  read lock is held):
  - folded copy of the name pool: 2 bytes per name char + 4 bytes per name
  (same size as the index pool plus the offsets), appended incrementally
  when NameCount grows, rebuilt when the table was replaced;
  - usage boosts resolved to entry indexes (re-resolved when Usage changes,
  when the Generation changes at most every 2 s, and every 60 s);
  - folder totals for sort:size, 8 bytes per entry, per Generation.

  Ranking (sort:rank): Score = 100 * tier - 2 * min(depth, 40) + usage
  bonus (10 * ln(1 + boost), max 60) + 1 for an exact-case match of the
  first term; ties: shorter name, then lower entry index. sort:name /
  size / date use that field first and the score as tie-break. sort:dir
  orders by the parent folder path, then by the name: two folders are compared
  by walking their ancestor chains, nothing is built or kept for it. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Math, System.Threading, System.Generics.Collections,
  System.Generics.Defaults, System.RegularExpressions,
  // sgc
  sgcFSearch_Types, sgcFSearch_Index, sgcFSearch_Match, sgcFSearch_Query,
  sgcFSearch_Usage;

type
  TsgcFSearchResult = record
    EntryIdx: Integer;
    NameId: Integer; // valid for the Generation of the results
    Score: Single;
    IsDir: Boolean;
    Depth: Word; // number of ancestors, used by sort:dir
    Size: Int64; // files: bytes; folders: total of the descendant files
    // with sort:size, -1 otherwise
    MTime: Int64; // FILETIME UTC
    MatchPos: Integer; // highlight in the name, 0-based, -1 = none
    MatchLen: Integer;
  end;

  TsgcFSearchResults = record
    Items: TArray<TsgcFSearchResult>;
    Total: Integer; // all matches (not limited)
    ElapsedMs: Double;
    Generation: Int64; // index Generation the results belong to
  end;

  TsgcFSearchSearcher = class
  private
    FIndex: TsgcFSearchIndex;
    FUsage: TsgcFSearchUsage;
    FCacheLock: TCriticalSection;
    FFold: TArray<Char>;
    FFoldOfs: TArray<Int32>;
    FFoldCount: Integer;
    FFoldChars: Integer;
    FBoostIdx: TArray<Int32>;
    FBoostVal: TArray<Single>;
    FBoostGen: Int64;
    FBoostVer: Int64;
    FBoostTick: UInt64;
    FTotals: TArray<Int64>;
    FTotalsGen: Int64;
    FTotalsCount: Integer;
    procedure DoSyncFold;
    procedure DoSyncBoosts;
    procedure DoSyncTotals;
    function GetFoldedMemory: Int64;
  public
    /// Usage may be nil (no frecency boost).
    constructor Create(Index: TsgcFSearchIndex; Usage: TsgcFSearchUsage = nil);
    destructor Destroy; override;
    /// Takes the index read lock itself. Limit <= 0 = SGCFS_DEFAULT_LIMIT,
    /// a limit: filter overrides it.
    procedure Search(const Query: TsgcFSearchQuery; Limit: Integer;
      out Results: TsgcFSearchResults); overload;
    procedure Search(const Text: string; Limit: Integer;
      out Results: TsgcFSearchResults); overload;
    /// Caller holds the read lock. Applies every filter of Query plus its
    /// exclude terms (not the positive name terms) to one entry, for
    /// content search hits. Roots and tombstones never match.
    function MatchesFilters(EntryIdx: Integer;
      const Query: TsgcFSearchQuery): Boolean;
    property Index: TsgcFSearchIndex read FIndex;
    property Usage: TsgcFSearchUsage read FUsage;
    /// Bytes held by the folded name cache.
    property FoldedMemory: Int64 read GetFoldedMemory;
  end;

implementation

const
  CS_BOOST_MAX = 60;
  CS_MAX_WALK = 4096;
  CS_BIT_EXACT_CASE = 8;
  CS_BIT_EXT = 16;
  CS_BIT_TYPE = 32;
  CS_MAX_AUX_BITS = 32;

type
  TsgcFSearchRunTerm = record
    Needle: string; // folded
    Raw: string; // as typed
    NeedleP: PChar;
    NeedleLen: Integer;
    Kind: TsgcFSearchMatchKind;
    Exclude: Boolean;
    Fuzzy: PsgcFSearchFuzzy; // nil = no fuzzy
    HasDirs: Boolean;
    NameBit: Integer; // exclude with dirs: aux bit of the name part
    CompBits: TArray<Integer>; // aux bits of the components, outermost first
  end;

  PsgcFSearchRunTerm = ^TsgcFSearchRunTerm;

  TsgcFSearchRunHeap = record
    Items: TArray<TsgcFSearchResult>;
    Count: Integer;
  end;

  /// State of one search (internal).
  TsgcFSearchRun = class
  public
    Index: TsgcFSearchIndex;
    Q: TsgcFSearchQuery;
    K: Integer;
    Entries: PsgcFSearchEntry;
    EntryCount: Integer;
    NameCount: Integer;
    Fold: TArray<Char>;
    FoldBase: PChar;
    FoldOfs: TArray<Int32>;
    BoostIdx: TArray<Int32>;
    BoostVal: TArray<Single>;
    Totals: TArray<Int64>;
    HasTotals: Boolean;
    Terms: TArray<TsgcFSearchRunTerm>;
    DirTerms: TArray<Integer>;
    CompP: TArray<PChar>;
    CompLen: TArray<Integer>;
    CompBit: TArray<Integer>;
    Comps: TArray<string>;
    HasPositive: Boolean;
    HasType: Boolean;
    FirstTerm: Integer;
    NameQ: TArray<Byte>;
    Aux: TArray<Cardinal>;
    Scope: TArray<Byte>;
    HasScope: Boolean;
    NameChunks: Integer;
    EntryChunks: Integer;
    Heaps: TArray<TsgcFSearchRunHeap>;
    Counts: TArray<Integer>;
    destructor Destroy; override;
    procedure PrepareTerms;
    function PrepareScope: Boolean;
    procedure NameChunk(Chunk: Integer);
    procedure EntryChunk(Chunk: Integer);
    function Better(const A, B: TsgcFSearchResult): Boolean;
    procedure HeapPush(var H: TsgcFSearchRunHeap; const R: TsgcFSearchResult);
    function InScope(Folder: Integer; var Stack: TArray<Int32>): Boolean;
    function DirsMatch(Idx: Integer; const T: TsgcFSearchRunTerm): Boolean;
    function Depth(Idx: Integer): Integer;
    function BoostOf(Idx: Integer): Single;
    function CmpName(A, B: Integer): Integer;
    function CmpFolders(A, DA, B, DB: Integer): Integer;
    procedure Execute(var Results: TsgcFSearchResults);
  end;

function DoChunkCount(Count: Integer): Integer;
begin
  Result := Min(TThread.ProcessorCount * 4, Count div 8192 + 1);
  if Result < 1 then
    Result := 1;
end;

procedure DoRange(Chunk, Chunks, Count: Integer; out AFrom, ATo: Integer);
begin
  AFrom := Int64(Count) * Chunk div Chunks;
  ATo := Int64(Count) * (Chunk + 1) div Chunks;
end;

procedure DoParallel(Count: Integer; const Proc: TProc<Integer>);
var
  i: Integer;
begin
  if Count <= 1 then
  begin
    for i := 0 to Count - 1 do
      Proc(i);
    Exit;
  end;
  TParallel.For(0, Count - 1, Proc);
end;

/// Folded name: is its extension (after the last '.') in List?
function DoExtIn(F: PChar; Len: Integer; const List: TArray<string>): Boolean;
var
  p, vEL, i: Integer;
begin
  p := Len - 1;
  while (p >= 0) and (F[p] <> '.') do
    Dec(p);
  if p < 0 then
    Exit(False);
  vEL := Len - p - 1;
  for i := 0 to High(List) do
    if (Length(List[i]) = vEL) and (vEL > 0) and
      CompareMem(PChar(List[i]), F + p + 1, vEL * SizeOf(Char)) then
      Exit(True);
  Result := False;
end;

function DoRootUnder(const RootPath, Scope: string): Boolean;
var
  vS: string;
begin
  vS := IncludeTrailingPathDelimiter(Scope);
  Result := (Length(RootPath) >= Length(vS)) and
    SameText(Copy(RootPath, 1, Length(vS)), vS);
end;

{ TsgcFSearchRun }

destructor TsgcFSearchRun.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Terms) do
    if Terms[i].Fuzzy <> nil then
      Dispose(Terms[i].Fuzzy);
  inherited;
end;

procedure TsgcFSearchRun.PrepareTerms;
var
  i, j, vBits, vNeed: Integer;
  vT: TsgcFSearchRunTerm;
begin
  vBits := 0;
  FirstTerm := -1;
  for i := 0 to High(Q.Terms) do
  begin
    vT := Default (TsgcFSearchRunTerm);
    vT.Needle := Q.Terms[i].Folded;
    vT.Raw := Q.Terms[i].Text;
    vT.Kind := Q.Terms[i].Kind;
    vT.Exclude := Q.Terms[i].Exclude;
    vT.NameBit := -1;
    vT.HasDirs := Length(Q.Terms[i].Dirs) > 0;
    if vT.HasDirs then
    begin
      vNeed := Length(Q.Terms[i].Dirs) + Ord(vT.Exclude);
      if vBits + vNeed > CS_MAX_AUX_BITS then
        Continue; // too many path components in one query: term ignored
      for j := 0 to High(Q.Terms[i].Dirs) do
      begin
        Comps := Comps + [Q.Terms[i].Dirs[j]];
        CompBit := CompBit + [vBits];
        vT.CompBits := vT.CompBits + [vBits];
        Inc(vBits);
      end;
      if vT.Exclude then
      begin
        vT.NameBit := vBits;
        Inc(vBits);
      end;
      DirTerms := DirTerms + [Length(Terms)];
    end;
    if (not vT.Exclude) and (vT.Kind = fsmkContains) and
      (Length(vT.Needle) >= SGCFS_FUZZY_MIN_LEN) and
      (Length(vT.Needle) <= SGCFS_FUZZY_MAX_LEN) then
    begin
      New(vT.Fuzzy);
      vT.Fuzzy.Init(PChar(vT.Needle), Length(vT.Needle));
    end;
    if not vT.Exclude then
    begin
      HasPositive := True;
      if (FirstTerm < 0) and (vT.Needle <> '') then
        FirstTerm := Length(Terms);
    end;
    Terms := Terms + [vT];
  end;
  for i := 0 to High(Terms) do
  begin
    Terms[i].NeedleP := PChar(Terms[i].Needle);
    Terms[i].NeedleLen := Length(Terms[i].Needle);
  end;
  SetLength(CompP, Length(Comps));
  SetLength(CompLen, Length(Comps));
  for i := 0 to High(Comps) do
  begin
    CompP[i] := PChar(Comps[i]);
    CompLen[i] := Length(Comps[i]);
  end;
  HasType := Q.HasType;
end;

function TsgcFSearchRun.PrepareScope: Boolean;
var
  i, R, vIdx: Integer;
begin
  Result := False;
  HasScope := True;
  SetLength(Scope, EntryCount);
  for i := 0 to High(Q.InPaths) do
  begin
    vIdx := Index.FindPath(Q.InPaths[i]);
    if vIdx >= 0 then
    begin
      Scope[vIdx] := 1;
      Result := True;
    end
    else
      // a scope above the indexed roots: the roots below it are in scope
      for R := 0 to Index.RootCount - 1 do
        if DoRootUnder(Index.Root(R).Path, Q.InPaths[i]) then
        begin
          Scope[Index.Root(R).EntryIdx] := 1;
          Result := True;
        end;
  end;
end;

procedure TsgcFSearchRun.NameChunk(Chunk: Integer);
var
  vFrom, vTo, id, T, c, vTier, vMin, vPos, vLen, vNL, vOfs: Integer;
  F, R: PChar;
  vAux: Cardinal;
  vOk, vEC, vFirst, vHasRe, vHasAux: Boolean;
  vQ: Byte;
  vT: PsgcFSearchRunTerm;
  vRe: TRegEx;
  vS: string;
begin
  DoRange(Chunk, NameChunks, NameCount, vFrom, vTo);
  vHasRe := Q.NameRegex <> '';
  if vHasRe then
    vRe := TRegEx.Create(Q.NameRegex, [roIgnoreCase]);
  vHasAux := Length(Aux) > 0;
  for id := vFrom to vTo - 1 do
  begin
    vOfs := FoldOfs[id];
    vNL := FoldOfs[id + 1] - vOfs;
    F := FoldBase + vOfs;
    R := Index.NamePtr(id);
    vAux := 0;
    for c := 0 to High(CompP) do
      if sgcFSearchPos(F, vNL, CompP[c], CompLen[c]) >= 0 then
        vAux := vAux or (Cardinal(1) shl CompBit[c]);
    vOk := True;
    vMin := SGCFS_QUALITY_EXACT + 1;
    vEC := False;
    vFirst := True;
    for T := 0 to High(Terms) do
    begin
      vT := @Terms[T];
      if vT.Exclude then
        vTier := sgcFSearchMatchQuality(F, R, vNL, vT.NeedleP, vT.NeedleLen,
          vT.Kind, nil, vPos, vLen)
      else
        vTier := sgcFSearchMatchQuality(F, R, vNL, vT.NeedleP, vT.NeedleLen,
          vT.Kind, vT.Fuzzy, vPos, vLen);
      if vT.Exclude then
      begin
        if vTier > 0 then
        begin
          if vT.HasDirs then
            vAux := vAux or (Cardinal(1) shl vT.NameBit)
          else
          begin
            vOk := False;
            Break;
          end;
        end;
      end
      else
      begin
        if vTier = 0 then
        begin
          vOk := False;
          Break;
        end;
        if vTier < vMin then
          vMin := vTier;
        if vFirst and (vT.NeedleLen > 0) then
        begin
          vFirst := False;
          vEC := (vTier > SGCFS_QUALITY_FUZZY) and (vPos >= 0) and
            (vT.Kind <> fsmkWildcard) and (Length(vT.Raw) = vT.NeedleLen) and
            CompareMem(R + vPos, PChar(vT.Raw), vT.NeedleLen * SizeOf(Char));
        end;
      end;
    end;
    if vHasAux then
      Aux[id] := vAux;
    if not vOk then
      Continue;
    if vMin > SGCFS_QUALITY_EXACT then
      vMin := SGCFS_QUALITY_SUBSTR; // filters only
    vQ := Byte(vMin);
    if vEC then
      vQ := vQ or CS_BIT_EXACT_CASE;
    if (Length(Q.Exts) > 0) and DoExtIn(F, vNL, Q.Exts) then
      vQ := vQ or CS_BIT_EXT;
    if (Length(Q.TypeExts) > 0) and DoExtIn(F, vNL, Q.TypeExts) then
      vQ := vQ or CS_BIT_TYPE;
    if vHasRe then
    begin
      SetString(vS, R, vNL);
      if not vRe.IsMatch(vS) then
        Continue;
    end;
    NameQ[id] := vQ;
  end;
end;

function TsgcFSearchRun.InScope(Folder: Integer;
  var Stack: TArray<Int32>): Boolean;
var
  n, K, p: Integer;
  s: Byte;
begin
  if Folder < 0 then
    Exit(False);
  n := 0;
  p := Folder;
  while True do
  begin
    if p < 0 then
    begin
      s := 2;
      Break;
    end;
    s := Scope[p];
    if s <> 0 then
      Break;
    if n >= Length(Stack) then
    begin
      s := 2;
      Break;
    end;
    Stack[n] := p;
    Inc(n);
    p := Entries[p].ParentIdx;
  end;
  // benign race: concurrent chunks store the same value
  for K := 0 to n - 1 do
    Scope[Stack[K]] := s;
  Result := s = 1;
end;

function TsgcFSearchRun.DirsMatch(Idx: Integer;
  const T: TsgcFSearchRunTerm): Boolean;
var
  j, p, n: Integer;
begin
  j := High(T.CompBits);
  p := Entries[Idx].ParentIdx;
  n := 0;
  while (j >= 0) and (p >= 0) and (n < CS_MAX_WALK) do
  begin
    if (Aux[Entries[p].NameId] and (Cardinal(1) shl T.CompBits[j])) <> 0 then
      Dec(j);
    p := Entries[p].ParentIdx;
    Inc(n);
  end;
  Result := j < 0;
end;

function TsgcFSearchRun.Depth(Idx: Integer): Integer;
var
  p: Integer;
begin
  Result := 0;
  p := Entries[Idx].ParentIdx;
  while (p >= 0) and (Result < CS_MAX_WALK) do
  begin
    Inc(Result);
    p := Entries[p].ParentIdx;
  end;
end;

function TsgcFSearchRun.BoostOf(Idx: Integer): Single;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := High(BoostIdx);
  while lo <= hi do
  begin
    mid := (lo + hi) shr 1;
    if BoostIdx[mid] = Idx then
      Exit(Min(CS_BOOST_MAX, 10 * Ln(1 + BoostVal[mid])))
    else if BoostIdx[mid] < Idx then
      lo := mid + 1
    else
      hi := mid - 1;
  end;
  Result := 0;
end;

function TsgcFSearchRun.CmpName(A, B: Integer): Integer;
var
  pa, pb: PChar;
  la, lb, i: Integer;
begin
  pa := FoldBase + FoldOfs[A];
  pb := FoldBase + FoldOfs[B];
  la := FoldOfs[A + 1] - FoldOfs[A];
  lb := FoldOfs[B + 1] - FoldOfs[B];
  for i := 0 to Min(la, lb) - 1 do
    if pa[i] <> pb[i] then
      Exit(Ord(pa[i]) - Ord(pb[i]));
  Result := la - lb;
end;

/// Order of two different folders (entry indexes, -1 = none) by path,
/// component by component with the folding of CmpName. DA and DB are the
/// lengths of their ancestor chains. A folder goes before the folders inside
/// it; siblings with the same folded name stay apart by entry index.
function TsgcFSearchRun.CmpFolders(A, DA, B, DB: Integer): Integer;
var
  i, pa, pb: Integer;
begin
  for i := 1 to DA - DB do
    A := Entries[A].ParentIdx;
  for i := 1 to DB - DA do
    B := Entries[B].ParentIdx;
  if A = B then
    Exit(DA - DB);
  while (A >= 0) and (B >= 0) do
  begin
    pa := Entries[A].ParentIdx;
    pb := Entries[B].ParentIdx;
    if pa = pb then
    begin
      Result := CmpName(Entries[A].NameId, Entries[B].NameId);
      if Result = 0 then
        Result := A - B;
      Exit;
    end;
    A := pa;
    B := pb;
  end;
  Result := DA - DB;
end;

function TsgcFSearchRun.Better(const A, B: TsgcFSearchResult): Boolean;
var
  c, la, lb, vPA, vPB: Integer;
begin
  case Q.Sort of
    fssName:
      begin
        c := CmpName(A.NameId, B.NameId);
        if c <> 0 then
          Exit((c < 0) <> Q.SortDesc);
      end;
    fssSize:
      if A.Size <> B.Size then
        Exit((A.Size > B.Size) = Q.SortDesc);
    fssDate:
      if A.MTime <> B.MTime then
        Exit((A.MTime > B.MTime) = Q.SortDesc);
    fssDir:
      begin
        vPA := Entries[A.EntryIdx].ParentIdx;
        vPB := Entries[B.EntryIdx].ParentIdx;
        if vPA = vPB then
          c := CmpName(A.NameId, B.NameId)
        else
          c := CmpFolders(vPA, A.Depth, vPB, B.Depth);
        if c <> 0 then
          Exit((c < 0) <> Q.SortDesc);
      end;
  end;
  if A.Score <> B.Score then
    Exit(A.Score > B.Score);
  la := FoldOfs[A.NameId + 1] - FoldOfs[A.NameId];
  lb := FoldOfs[B.NameId + 1] - FoldOfs[B.NameId];
  if la <> lb then
    Exit(la < lb);
  Result := A.EntryIdx < B.EntryIdx;
end;

procedure TsgcFSearchRun.HeapPush(var H: TsgcFSearchRunHeap;
  const R: TsgcFSearchResult);
var
  i, p, c: Integer;
begin
  // the root (Items[0]) is the worst kept result
  if H.Count < K then
  begin
    if H.Count = Length(H.Items) then
      SetLength(H.Items, Min(K, Max(64, H.Count * 2)));
    i := H.Count;
    Inc(H.Count);
    while i > 0 do
    begin
      p := (i - 1) shr 1;
      if not Better(H.Items[p], R) then
        Break;
      H.Items[i] := H.Items[p];
      i := p;
    end;
    H.Items[i] := R;
  end
  else
  begin
    if not Better(R, H.Items[0]) then
      Exit;
    i := 0;
    while True do
    begin
      c := 2 * i + 1;
      if c >= H.Count then
        Break;
      if (c + 1 < H.Count) and Better(H.Items[c], H.Items[c + 1]) then
        Inc(c);
      if not Better(R, H.Items[c]) then
        Break;
      H.Items[i] := H.Items[c];
      i := c;
    end;
    H.Items[i] := R;
  end;
end;

procedure TsgcFSearchRun.EntryChunk(Chunk: Integer);
var
  vFrom, vTo, i, j, vCount: Integer;
  vE: PsgcFSearchEntry;
  vQ: Byte;
  vIsDir, vOk: Boolean;
  vR: TsgcFSearchResult;
  vStack: TArray<Int32>;
  vUB: Single;
  vPath: string;
  vT: PsgcFSearchRunTerm;
begin
  DoRange(Chunk, EntryChunks, EntryCount, vFrom, vTo);
  vCount := 0;
  if HasScope then
    SetLength(vStack, CS_MAX_WALK);
  for i := vFrom to vTo - 1 do
  begin
    vE := @Entries[i];
    if (vE.Flags and SGCFS_FLAG_DELETED) <> 0 then
      Continue;
    vQ := NameQ[vE.NameId];
    if vQ = 0 then
      Continue;
    if ((vE.Flags and SGCFS_FLAG_ROOT) <> 0) and not HasPositive then
      Continue;
    vIsDir := (vE.Flags and SGCFS_FLAG_DIR) <> 0;
    case Q.Kind of
      fskFile:
        if vIsDir then
          Continue;
      fskDir:
        if not vIsDir then
          Continue;
    end;
    if (Length(Q.Exts) > 0) and (vIsDir or ((vQ and CS_BIT_EXT) = 0)) then
      Continue;
    if HasType then
    begin
      if vIsDir then
      begin
        if not Q.TypeDirs then
          Continue;
      end
      else if (vQ and CS_BIT_TYPE) = 0 then
        Continue;
    end;
    if Q.HasSize then
    begin
      if vIsDir then
      begin
        if not(Q.SizeEmpty and (vE.FirstChild < 0)) then
          Continue;
      end
      else if (vE.Size < Q.SizeMin) or (vE.Size > Q.SizeMax) then
        Continue;
    end;
    if Q.HasMTime and ((vE.MTime < Q.MTimeMin) or (vE.MTime >= Q.MTimeMax)) then
      Continue;
    vOk := True;
    for j := 0 to High(DirTerms) do
    begin
      vT := @Terms[DirTerms[j]];
      if vT.Exclude then
      begin
        if ((Aux[vE.NameId] and (Cardinal(1) shl vT.NameBit)) <> 0) and
          DirsMatch(i, vT^) then
        begin
          vOk := False;
          Break;
        end;
      end
      else if not DirsMatch(i, vT^) then
      begin
        vOk := False;
        Break;
      end;
    end;
    if not vOk then
      Continue;
    if HasScope and not InScope(vE.ParentIdx, vStack) then
      Continue;
    if Length(Q.PathTexts) > 0 then
    begin
      vPath := sgcFSearchFold(Index.FullPath(i));
      for j := 0 to High(Q.PathTexts) do
        if Pos(Q.PathTexts[j], vPath) = 0 then
        begin
          vOk := False;
          Break;
        end;
      if not vOk then
        Continue;
    end;
    Inc(vCount);
    // cheap reject before computing depth and boost
    if (Q.Sort = fssRank) and (Heaps[Chunk].Count >= K) then
    begin
      vUB := 100 * (vQ and 7) + CS_BOOST_MAX + 1;
      if vUB < Heaps[Chunk].Items[0].Score then
        Continue;
    end;
    vR.EntryIdx := i;
    vR.NameId := vE.NameId;
    vR.IsDir := vIsDir;
    vR.MTime := vE.MTime;
    if not vIsDir then
      vR.Size := vE.Size
    else if HasTotals then
      vR.Size := Totals[i]
    else
      vR.Size := -1;
    vR.Depth := Depth(i);
    vR.Score := 100 * (vQ and 7) - 2 * Min(vR.Depth, 40) + BoostOf(i) +
      Ord((vQ and CS_BIT_EXACT_CASE) <> 0);
    vR.MatchPos := -1;
    vR.MatchLen := 0;
    HeapPush(Heaps[Chunk], vR);
  end;
  Counts[Chunk] := vCount;
end;

procedure TsgcFSearchRun.Execute(var Results: TsgcFSearchResults);
var
  i, n, vPos, vLen: Integer;
  vAll: TArray<TsgcFSearchResult>;
  vT: PsgcFSearchRunTerm;
  vId: Integer;
  vRun: TsgcFSearchRun;
begin
  EntryCount := Index.EntryCount;
  Entries := Index.Entries;
  if Length(Fold) > 0 then
    FoldBase := @Fold[0]
  else
    FoldBase := nil;
  PrepareTerms;
  if (EntryCount = 0) or (NameCount = 0) then
    Exit;
  if (Length(Q.InPaths) > 0) and not PrepareScope then
    Exit;
  SetLength(NameQ, NameCount);
  if Length(Comps) > 0 then
    SetLength(Aux, NameCount);
  NameChunks := DoChunkCount(NameCount);
  DoParallel(NameChunks, procedure(c: Integer)
    begin
      NameChunk(c);
    end);
  EntryChunks := DoChunkCount(EntryCount);
  SetLength(Heaps, EntryChunks);
  SetLength(Counts, EntryChunks);
  DoParallel(EntryChunks, procedure(c: Integer)
    begin
      EntryChunk(c);
    end);
  // merge
  n := 0;
  for i := 0 to EntryChunks - 1 do
  begin
    Inc(Results.Total, Counts[i]);
    Inc(n, Heaps[i].Count);
  end;
  SetLength(vAll, n);
  n := 0;
  for i := 0 to EntryChunks - 1 do
    if Heaps[i].Count > 0 then
    begin
      Move(Heaps[i].Items[0], vAll[n], Heaps[i].Count *
        SizeOf(TsgcFSearchResult));
      Inc(n, Heaps[i].Count);
    end;
  vRun := Self;
  TArray.Sort<TsgcFSearchResult>(vAll, TComparer<TsgcFSearchResult>.Construct(
    function(const L, R: TsgcFSearchResult): Integer
    begin
      if vRun.Better(L, R) then
        Result := -1
      else if vRun.Better(R, L) then
        Result := 1
      else
        Result := 0;
    end));
  if Length(vAll) > K then
    SetLength(vAll, K);
  // highlight of the first positive term
  if FirstTerm >= 0 then
  begin
    vT := @Terms[FirstTerm];
    for i := 0 to High(vAll) do
    begin
      vId := vAll[i].NameId;
      sgcFSearchMatchQuality(FoldBase + FoldOfs[vId], Index.NamePtr(vId),
        FoldOfs[vId + 1] - FoldOfs[vId], vT.NeedleP, vT.NeedleLen, vT.Kind,
        vT.Fuzzy, vPos, vLen);
      vAll[i].MatchPos := vPos;
      vAll[i].MatchLen := vLen;
    end;
  end;
  Results.Items := vAll;
end;

{ TsgcFSearchSearcher }

constructor TsgcFSearchSearcher.Create(Index: TsgcFSearchIndex;
Usage: TsgcFSearchUsage = nil);
begin
  inherited Create;
  FIndex := Index;
  FUsage := Usage;
  FCacheLock := TCriticalSection.Create;
  FBoostGen := -1;
  FBoostVer := -1;
  FTotalsGen := -1;
end;

destructor TsgcFSearchSearcher.Destroy;
begin
  FCacheLock.Free;
  inherited;
end;

function TsgcFSearchSearcher.GetFoldedMemory: Int64;
begin
  FCacheLock.Enter;
  try
    Result := Int64(Length(FFold)) * SizeOf(Char) + Int64(Length(FFoldOfs)) *
      SizeOf(Int32);
  finally
    FCacheLock.Leave;
  end;
end;

procedure TsgcFSearchSearcher.DoSyncFold;
var
  n, i, K, id, vLen, vNeed, vFrom, vCount, vChunks: Integer;
  vReset: Boolean;
  p: PChar;
begin
  n := FIndex.NameCount;
  vReset := n < FFoldCount;
  // the table only grows; a replaced table (Clear, LoadFromFile) is
  // detected by sampling names already folded
  if (not vReset) and (FFoldCount > 0) then
    for K := 0 to 15 do
    begin
      id := Int64(FFoldCount - 1) * K div 15;
      vLen := FFoldOfs[id + 1] - FFoldOfs[id];
      if vLen <> FIndex.NameLen(id) then
      begin
        vReset := True;
        Break;
      end;
      p := FIndex.NamePtr(id);
      for i := 0 to vLen - 1 do
        if sgcFSearchFoldMap[Ord(p[i])] <> FFold[FFoldOfs[id] + i] then
        begin
          vReset := True;
          Break;
        end;
      if vReset then
        Break;
    end;
  if vReset then
  begin
    // new arrays: a running search keeps its own reference to the old ones
    FFold := nil;
    FFoldOfs := nil;
    FFoldCount := 0;
    FFoldChars := 0;
  end;
  if (n = FFoldCount) and (Length(FFoldOfs) > 0) then
    Exit;
  SetLength(FFoldOfs, n + 1);
  if FFoldCount = 0 then
    FFoldOfs[0] := 0;
  vNeed := FFoldChars;
  for id := FFoldCount to n - 1 do
  begin
    Inc(vNeed, FIndex.NameLen(id));
    FFoldOfs[id + 1] := vNeed;
  end;
  // headroom: appends write past what older searches read, never inside it
  if vNeed + 1 > Length(FFold) then
    SetLength(FFold, vNeed + vNeed div 4 + 4096);
  vFrom := FFoldCount;
  vCount := n - vFrom;
  vChunks := DoChunkCount(vCount);
  DoParallel(vChunks, procedure(c: Integer)
    var
      A, B, j: Integer;
    begin
      DoRange(c, vChunks, vCount, A, B);
      for j := vFrom + A to vFrom + B - 1 do
        sgcFSearchFoldBuffer(FIndex.NamePtr(j), @FFold[FFoldOfs[j]],
          FFoldOfs[j + 1] - FFoldOfs[j]);
    end);
  FFoldCount := n;
  FFoldChars := vNeed;
end;

procedure TsgcFSearchSearcher.DoSyncBoosts;
var
  vVer, vGen: Int64;
  vTick: UInt64;
  vItems: TArray<TsgcFSearchUsageItem>;
  vKeys: TArray<Int64>;
  vVal: TArray<Single>;
  i, n, vIdx: Integer;
begin
  if FUsage = nil then
    Exit;
  vVer := FUsage.Version;
  vGen := FIndex.Generation;
  vTick := GetTickCount64;
  if (FBoostTick <> 0) and (vVer = FBoostVer) and (vTick - FBoostTick < 60000)
    and ((vGen = FBoostGen) or (vTick - FBoostTick < 2000)) then
    Exit;
  vItems := FUsage.Snapshot;
  SetLength(vKeys, Length(vItems));
  SetLength(vVal, Length(vItems));
  n := 0;
  for i := 0 to High(vItems) do
  begin
    if vItems[i].Boost < 0.001 then
      Continue;
    vIdx := FIndex.FindPath(vItems[i].Path);
    if vIdx < 0 then
      Continue;
    vKeys[n] := (Int64(vIdx) shl 32) or n;
    vVal[n] := vItems[i].Boost;
    Inc(n);
  end;
  SetLength(vKeys, n);
  TArray.Sort<Int64>(vKeys);
  // new arrays: a running search keeps its own reference to the old ones
  FBoostIdx := nil;
  FBoostVal := nil;
  SetLength(FBoostIdx, n);
  SetLength(FBoostVal, n);
  for i := 0 to n - 1 do
  begin
    FBoostIdx[i] := Int32(vKeys[i] shr 32);
    FBoostVal[i] := vVal[vKeys[i] and $FFFFFFFF];
  end;
  FBoostVer := vVer;
  FBoostGen := vGen;
  FBoostTick := vTick;
end;

procedure TsgcFSearchSearcher.DoSyncTotals;
var
  vGen: Int64;
  n, i, K, p, d, vMax, j: Integer;
  E: PsgcFSearchEntry;
  vDepth, vStack, vStart, vPos, vOrder: TArray<Int32>;
  vTot: TArray<Int64>;
begin
  vGen := FIndex.Generation;
  n := FIndex.EntryCount;
  if (FTotalsGen = vGen) and (FTotalsCount = n) then
    Exit;
  E := FIndex.Entries;
  SetLength(vTot, n);
  if n > 0 then
  begin
    // depth of every live entry, iterative with memoisation (entries are
    // not in parent-before-child order)
    SetLength(vDepth, n);
    FillChar(vDepth[0], n * SizeOf(Int32), $FF);
    SetLength(vStack, CS_MAX_WALK);
    vMax := 0;
    for i := 0 to n - 1 do
    begin
      if ((E[i].Flags and SGCFS_FLAG_DELETED) <> 0) or (vDepth[i] >= 0) then
        Continue;
      K := 0;
      p := i;
      while (p >= 0) and (vDepth[p] < 0) and (K < CS_MAX_WALK) do
      begin
        vStack[K] := p;
        Inc(K);
        p := E[p].ParentIdx;
      end;
      if (p >= 0) and (vDepth[p] >= 0) then
        d := vDepth[p]
      else
        d := -1;
      while K > 0 do
      begin
        Dec(K);
        Inc(d);
        vDepth[vStack[K]] := d;
      end;
      if d > vMax then
        vMax := d;
    end;
    // bucket the entries by depth, then add children to parents deepest
    // level first: every folder total is final before its parent reads it
    SetLength(vStart, vMax + 2);
    for i := 0 to n - 1 do
      if vDepth[i] >= 0 then
        Inc(vStart[vDepth[i] + 1]);
    for d := 1 to vMax + 1 do
      Inc(vStart[d], vStart[d - 1]);
    vPos := Copy(vStart);
    SetLength(vOrder, vStart[vMax + 1]);
    for i := 0 to n - 1 do
    begin
      d := vDepth[i];
      if d >= 0 then
      begin
        vOrder[vPos[d]] := i;
        Inc(vPos[d]);
      end;
    end;
    for d := vMax downto 1 do
      for j := vStart[d] to vStart[d + 1] - 1 do
      begin
        i := vOrder[j];
        p := E[i].ParentIdx;
        if p < 0 then
          Continue;
        if (E[i].Flags and SGCFS_FLAG_DIR) <> 0 then
          Inc(vTot[p], vTot[i])
        else
          Inc(vTot[p], E[i].Size);
      end;
  end;
  FTotals := vTot;
  FTotalsGen := vGen;
  FTotalsCount := n;
end;

procedure TsgcFSearchSearcher.Search(const Query: TsgcFSearchQuery;
Limit: Integer; out Results: TsgcFSearchResults);
var
  vRun: TsgcFSearchRun;
  vT0, vT1, vFreq: Int64;
begin
  Results := Default (TsgcFSearchResults);
  QueryPerformanceFrequency(vFreq);
  QueryPerformanceCounter(vT0);
  vRun := TsgcFSearchRun.Create;
  try
    vRun.Index := FIndex;
    vRun.Q := Query;
    if Query.Limit > 0 then
      vRun.K := Query.Limit
    else if Limit > 0 then
      vRun.K := Limit
    else
      vRun.K := SGCFS_DEFAULT_LIMIT;
    FIndex.BeginRead;
    try
      Results.Generation := FIndex.Generation;
      FCacheLock.Enter;
      try
        DoSyncFold;
        vRun.Fold := FFold;
        vRun.FoldOfs := FFoldOfs;
        vRun.NameCount := FFoldCount;
        DoSyncBoosts;
        vRun.BoostIdx := FBoostIdx;
        vRun.BoostVal := FBoostVal;
        if Query.Sort = fssSize then
        begin
          DoSyncTotals;
          vRun.Totals := FTotals;
          vRun.HasTotals := True;
        end;
      finally
        FCacheLock.Leave;
      end;
      vRun.Execute(Results);
    finally
      FIndex.EndRead;
    end;
  finally
    vRun.Free;
  end;
  QueryPerformanceCounter(vT1);
  Results.ElapsedMs := (vT1 - vT0) * 1000.0 / vFreq;
end;

procedure TsgcFSearchSearcher.Search(const Text: string; Limit: Integer;
out Results: TsgcFSearchResults);
begin
  Search(sgcFSearchParseQuery(Text), Limit, Results);
end;

function TsgcFSearchSearcher.MatchesFilters(EntryIdx: Integer;
const Query: TsgcFSearchQuery): Boolean;
var
  vE: PsgcFSearchEntry;
  vIsDir, vFound: Boolean;
  R: PChar;
  vNL, i, j, p, n, vPos, vLen, vIdx, vRootNo: Integer;
  vRaw, vF, vPath: string;
begin
  Result := False;
  if not FIndex.IsLive(EntryIdx) then
    Exit;
  vE := FIndex.EntryPtr(EntryIdx);
  if (vE.Flags and SGCFS_FLAG_ROOT) <> 0 then
    Exit;
  vIsDir := (vE.Flags and SGCFS_FLAG_DIR) <> 0;
  case Query.Kind of
    fskFile:
      if vIsDir then
        Exit;
    fskDir:
      if not vIsDir then
        Exit;
  end;
  R := FIndex.NamePtr(vE.NameId);
  vNL := FIndex.NameLen(vE.NameId);
  SetString(vRaw, R, vNL);
  vF := sgcFSearchFold(vRaw);
  if (Length(Query.Exts) > 0) and
    (vIsDir or not DoExtIn(PChar(vF), vNL, Query.Exts)) then
    Exit;
  if Query.HasType then
  begin
    if vIsDir then
    begin
      if not Query.TypeDirs then
        Exit;
    end
    else if not DoExtIn(PChar(vF), vNL, Query.TypeExts) then
      Exit;
  end;
  if Query.HasSize then
  begin
    if vIsDir then
    begin
      if not(Query.SizeEmpty and (vE.FirstChild < 0)) then
        Exit;
    end
    else if (vE.Size < Query.SizeMin) or (vE.Size > Query.SizeMax) then
      Exit;
  end;
  if Query.HasMTime and ((vE.MTime < Query.MTimeMin) or
    (vE.MTime >= Query.MTimeMax)) then
    Exit;
  if (Query.NameRegex <> '') and not TRegEx.IsMatch(vRaw, Query.NameRegex,
    [roIgnoreCase]) then
    Exit;
  // exclude terms
  for i := 0 to High(Query.Terms) do
  begin
    if not Query.Terms[i].Exclude then
      Continue;
    if sgcFSearchMatchQuality(PChar(vF), R, vNL, PChar(Query.Terms[i].Folded),
      Length(Query.Terms[i].Folded), Query.Terms[i].Kind, nil, vPos, vLen) = 0
    then
      Continue;
    if Length(Query.Terms[i].Dirs) = 0 then
      Exit;
    j := High(Query.Terms[i].Dirs);
    p := vE.ParentIdx;
    n := 0;
    while (j >= 0) and (p >= 0) and (n < CS_MAX_WALK) do
    begin
      vIdx := FIndex.EntryPtr(p).NameId;
      if sgcFSearchPosFold(FIndex.NamePtr(vIdx), FIndex.NameLen(vIdx),
        PChar(Query.Terms[i].Dirs[j]), Length(Query.Terms[i].Dirs[j])) >= 0 then
        Dec(j);
      p := FIndex.EntryPtr(p).ParentIdx;
      Inc(n);
    end;
    if j < 0 then
      Exit;
  end;
  // in: scope (descendants only)
  if Length(Query.InPaths) > 0 then
  begin
    vFound := False;
    vRootNo := FIndex.RootOfEntry(EntryIdx);
    for i := 0 to High(Query.InPaths) do
    begin
      vIdx := FIndex.FindPath(Query.InPaths[i]);
      if vIdx >= 0 then
      begin
        p := vE.ParentIdx;
        n := 0;
        while (p >= 0) and (n < CS_MAX_WALK) do
        begin
          if p = vIdx then
          begin
            vFound := True;
            Break;
          end;
          p := FIndex.EntryPtr(p).ParentIdx;
          Inc(n);
        end;
      end
      else if (vRootNo >= 0) and DoRootUnder(FIndex.Root(vRootNo).Path,
        Query.InPaths[i]) then
        vFound := True;
      if vFound then
        Break;
    end;
    if not vFound then
      Exit;
  end;
  if Length(Query.PathTexts) > 0 then
  begin
    vPath := sgcFSearchFold(FIndex.FullPath(EntryIdx));
    for i := 0 to High(Query.PathTexts) do
      if Pos(Query.PathTexts[i], vPath) = 0 then
        Exit;
  end;
  Result := True;
end;

end.
