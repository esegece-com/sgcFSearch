{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Match;

{$I sgcVer.inc}
{ Name matching primitives: case folding of UTF-16 code units, folded
  substring / prefix / suffix / equals search on PChar + Len (no string
  allocation), wildcard patterns, word boundaries, fuzzy matching (one typo)
  and quality tiers.

  "Folded" text is text mapped through sgcFSearchFoldMap. Needles are always
  passed folded. Functions named *Fold take a raw (unfolded) hay and fold it
  on the fly, the others expect a folded hay. }

interface

uses
  Winapi.Windows, System.SysUtils;

const
  // quality tiers, higher is better, 0 = no match
  SGCFS_QUALITY_NONE = 0;
  SGCFS_QUALITY_FUZZY = 1;
  SGCFS_QUALITY_SUBSTR = 2;
  SGCFS_QUALITY_WORD = 3;
  SGCFS_QUALITY_PREFIX = 4;
  SGCFS_QUALITY_EXACT = 5;
  // fuzzy matching applies to needles of this length range
  SGCFS_FUZZY_MIN_LEN = 5;
  SGCFS_FUZZY_MAX_LEN = 63;

type
  /// fsmkWildcard: the needle is a pattern on the whole name, * matches any
  /// run of characters (also none), ? exactly one character.
  TsgcFSearchMatchKind = (fsmkContains, fsmkExact, fsmkPrefix, fsmkSuffix,
    fsmkWildcard);

  /// Approximate substring matcher, optimal string alignment distance 1
  /// (one insertion, deletion, substitution or adjacent transposition),
  /// bit-parallel (Shift-And with one error). Needle and hay folded.
  TsgcFSearchFuzzy = record
  private
    FLen: Integer;
    FMask: UInt64; // prefilter: bit (Ord(c) and 63) of every needle char
    FPeq: array [0 .. 255] of UInt64;
    FWideChars: array [0 .. SGCFS_FUZZY_MAX_LEN - 1] of Char;
    FWideMasks: array [0 .. SGCFS_FUZZY_MAX_LEN - 1] of UInt64;
    FWideCount: Integer;
    function DoPeq(C: Char): UInt64; inline;
  public
    /// Prepares the matcher; Len outside SGCFS_FUZZY_MIN_LEN ..
    /// SGCFS_FUZZY_MAX_LEN disables it (Match returns False).
    procedure Init(Needle: PChar; Len: Integer);
    /// True when a substring of Hay is within distance 1 of the needle.
    function Match(Hay: PChar; HayLen: Integer;
      out MatchPos, MatchLen: Integer): Boolean;
    property Len: Integer read FLen;
  end;

  PsgcFSearchFuzzy = ^TsgcFSearchFuzzy;

var
  /// Fold table for every UTF-16 code unit (lower case, surrogates
  /// unchanged). Built once at unit initialization, read-only afterwards.
  sgcFSearchFoldMap: array [Word] of Char;

function sgcFSearchFoldChar(C: Char): Char; inline;
procedure sgcFSearchFoldBuffer(Src, Dst: PChar; Len: Integer);
function sgcFSearchFold(const S: string): string;

/// Folded hay: first position >= From of Needle, -1 if none.
function sgcFSearchPos(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer; From: Integer = 0): Integer;
/// Raw hay (folded on the fly).
function sgcFSearchPosFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer; From: Integer = 0): Integer;
function sgcFSearchStartsWithFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;
function sgcFSearchEndsWithFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;
function sgcFSearchSameFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;

/// Word start at Pos of a raw name: start of name, after a non letter /
/// digit char ('.', '_', '-', space ...), a letter / digit change, or a
/// camelCase lower -> upper step.
function sgcFSearchIsWordStart(Name: PChar; NameLen, Pos: Integer): Boolean;

/// Quality tier of one name against one folded needle. Folded is the folded
/// name (required), Raw the raw name (nil: word starts are detected on the
/// folded text, no camelCase). Fuzzy (may be nil) is only tried for
/// fsmkContains when there is no exact substring. An empty needle matches
/// with SGCFS_QUALITY_SUBSTR and MatchPos -1. fsmkWildcard: exact without
/// any *, prefix when the pattern does not start with *, substring
/// otherwise; the highlight is the first literal run of the pattern (0 / 0
/// for a pattern of wildcards only).
function sgcFSearchMatchQuality(Folded, Raw: PChar; NameLen: Integer;
  Needle: PChar; NeedleLen: Integer; Kind: TsgcFSearchMatchKind;
  Fuzzy: PsgcFSearchFuzzy; out MatchPos, MatchLen: Integer): Integer;
/// Same on a raw name only (folds it into a temporary buffer).
function sgcFSearchMatchQualityRaw(Raw: PChar; NameLen: Integer; Needle: PChar;
  NeedleLen: Integer; Kind: TsgcFSearchMatchKind; Fuzzy: PsgcFSearchFuzzy;
  out MatchPos, MatchLen: Integer): Integer;

implementation

procedure DoBuildFoldMap;
var
  i: Integer;
begin
  for i := 0 to High(Word) do
    sgcFSearchFoldMap[i] := Char(i);
  // fold the two ranges separately so no surrogate pair is formed
  CharLowerBuffW(@sgcFSearchFoldMap[0], $D800);
  CharLowerBuffW(@sgcFSearchFoldMap[$E000], $10000 - $E000);
end;

function sgcFSearchFoldChar(C: Char): Char;
begin
  Result := sgcFSearchFoldMap[Ord(C)];
end;

procedure sgcFSearchFoldBuffer(Src, Dst: PChar; Len: Integer);
var
  i: Integer;
begin
  for i := 0 to Len - 1 do
    Dst[i] := sgcFSearchFoldMap[Ord(Src[i])];
end;

function sgcFSearchFold(const S: string): string;
begin
  SetLength(Result, Length(S));
  if S <> '' then
    sgcFSearchFoldBuffer(PChar(S), PChar(Result), Length(S));
end;

function sgcFSearchPos(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer; From: Integer = 0): Integer;
var
  i, j, vLast: Integer;
  c0: Char;
begin
  if From < 0 then
    From := 0;
  if NeedleLen <= 0 then
  begin
    if From <= HayLen then
      Exit(From);
    Exit(-1);
  end;
  vLast := HayLen - NeedleLen;
  c0 := Needle[0];
  i := From;
  while i <= vLast do
  begin
    if Hay[i] = c0 then
    begin
      j := 1;
      while (j < NeedleLen) and (Hay[i + j] = Needle[j]) do
        Inc(j);
      if j = NeedleLen then
        Exit(i);
    end;
    Inc(i);
  end;
  Result := -1;
end;

function sgcFSearchPosFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer; From: Integer = 0): Integer;
var
  i, j, vLast: Integer;
  c0: Char;
begin
  if From < 0 then
    From := 0;
  if NeedleLen <= 0 then
  begin
    if From <= HayLen then
      Exit(From);
    Exit(-1);
  end;
  vLast := HayLen - NeedleLen;
  c0 := Needle[0];
  i := From;
  while i <= vLast do
  begin
    if sgcFSearchFoldMap[Ord(Hay[i])] = c0 then
    begin
      j := 1;
      while (j < NeedleLen) and
        (sgcFSearchFoldMap[Ord(Hay[i + j])] = Needle[j]) do
        Inc(j);
      if j = NeedleLen then
        Exit(i);
    end;
    Inc(i);
  end;
  Result := -1;
end;

function DoSameFoldAt(Hay: PChar; Needle: PChar; NeedleLen: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to NeedleLen - 1 do
    if sgcFSearchFoldMap[Ord(Hay[i])] <> Needle[i] then
      Exit(False);
  Result := True;
end;

function sgcFSearchStartsWithFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;
begin
  Result := (HayLen >= NeedleLen) and DoSameFoldAt(Hay, Needle, NeedleLen);
end;

function sgcFSearchEndsWithFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;
begin
  Result := (HayLen >= NeedleLen) and DoSameFoldAt(Hay + HayLen - NeedleLen,
    Needle, NeedleLen);
end;

function sgcFSearchSameFold(Hay: PChar; HayLen: Integer; Needle: PChar;
  NeedleLen: Integer): Boolean;
begin
  Result := (HayLen = NeedleLen) and DoSameFoldAt(Hay, Needle, NeedleLen);
end;

function DoIsDigit(C: Char): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

function DoIsAlnum(C: Char): Boolean; inline;
begin
  case C of
    '0' .. '9', 'a' .. 'z', 'A' .. 'Z':
      Result := True;
  else
    // non-ASCII letters: anything above Latin-1 punctuation
    Result := C >= #$00C0;
  end;
end;

function sgcFSearchIsWordStart(Name: PChar; NameLen, Pos: Integer): Boolean;
var
  p, C: Char;
begin
  if Pos <= 0 then
    Exit(True);
  if Pos >= NameLen then
    Exit(False);
  p := Name[Pos - 1];
  C := Name[Pos];
  if not DoIsAlnum(p) then
    Exit(True);
  if not DoIsAlnum(C) then
    Exit(False);
  if DoIsDigit(p) <> DoIsDigit(C) then
    Exit(True);
  // camelCase: p is lower case (folds to itself, has an upper case form is
  // not needed), c is upper case (folds to something else)
  Result := (sgcFSearchFoldMap[Ord(C)] <> C) and (sgcFSearchFoldMap[Ord(p)] = p)
    and not DoIsDigit(p);
end;

function DoSameAt(A, B: PChar; Len: Integer): Boolean; inline;
var
  i: Integer;
begin
  for i := 0 to Len - 1 do
    if A[i] <> B[i] then
      Exit(False);
  Result := True;
end;

// Folded name against a folded wildcard pattern, whole name. Iterative,
// one backtrack point (the last * seen), no recursion.
function DoWildQuality(Hay: PChar; HayLen: Integer; Pattern: PChar;
  PatLen: Integer; out MatchPos, MatchLen: Integer): Integer;
var
  p, S, vStarP, vStarS, vLit, vLitLen, vHl: Integer;
  C: Char;
begin
  Result := SGCFS_QUALITY_NONE;
  MatchPos := -1;
  MatchLen := 0;
  // first literal run of the pattern, the highlight
  vLit := 0;
  while (vLit < PatLen) and ((Pattern[vLit] = '*') or (Pattern[vLit] = '?')) do
    Inc(vLit);
  vLitLen := 0;
  while (vLit + vLitLen < PatLen) and (Pattern[vLit + vLitLen] <> '*') and
    (Pattern[vLit + vLitLen] <> '?') do
    Inc(vLitLen);
  vHl := 0;
  p := 0;
  S := 0;
  vStarP := -1;
  vStarS := 0;
  while S < HayLen do
  begin
    if p < PatLen then
    begin
      C := Pattern[p];
      if C = '*' then
      begin
        vStarP := p;
        vStarS := S;
        Inc(p);
        Continue;
      end;
      if (C = '?') or (C = Hay[S]) then
      begin
        // the last time the first literal is consumed is on the match path
        if p = vLit then
          vHl := S;
        Inc(p);
        Inc(S);
        Continue;
      end;
    end;
    if vStarP < 0 then
      Exit;
    // let the last * take one more char and retry the rest
    p := vStarP + 1;
    Inc(vStarS);
    S := vStarS;
  end;
  while (p < PatLen) and (Pattern[p] = '*') do
    Inc(p);
  if p < PatLen then
    Exit;
  if vLitLen > 0 then
  begin
    MatchPos := vHl;
    MatchLen := vLitLen;
  end
  else
    MatchPos := 0;
  if Pattern[0] = '*' then
    Exit(SGCFS_QUALITY_SUBSTR);
  for p := 1 to PatLen - 1 do
    if Pattern[p] = '*' then
      Exit(SGCFS_QUALITY_PREFIX);
  Result := SGCFS_QUALITY_EXACT;
end;

function sgcFSearchMatchQuality(Folded, Raw: PChar; NameLen: Integer;
  Needle: PChar; NeedleLen: Integer; Kind: TsgcFSearchMatchKind;
  Fuzzy: PsgcFSearchFuzzy; out MatchPos, MatchLen: Integer): Integer;
var
  p, q: Integer;
  B: PChar;
begin
  Result := SGCFS_QUALITY_NONE;
  MatchPos := -1;
  MatchLen := 0;
  if NeedleLen <= 0 then
    Exit(SGCFS_QUALITY_SUBSTR);
  if NameLen < NeedleLen then
  begin
    // a pattern can be longer than the names it matches (* matches none)
    if Kind = fsmkWildcard then
      Exit(DoWildQuality(Folded, NameLen, Needle, NeedleLen, MatchPos,
        MatchLen));
    if (Kind = fsmkContains) and (Fuzzy <> nil) and
      Fuzzy.Match(Folded, NameLen, MatchPos, MatchLen) then
      Result := SGCFS_QUALITY_FUZZY;
    Exit;
  end;
  B := Raw;
  if B = nil then
    B := Folded;
  case Kind of
    fsmkExact:
      if (NameLen = NeedleLen) and DoSameAt(Folded, Needle, NeedleLen) then
      begin
        MatchPos := 0;
        MatchLen := NeedleLen;
        Result := SGCFS_QUALITY_EXACT;
      end;
    fsmkPrefix:
      if DoSameAt(Folded, Needle, NeedleLen) then
      begin
        MatchPos := 0;
        MatchLen := NeedleLen;
        if NameLen = NeedleLen then
          Result := SGCFS_QUALITY_EXACT
        else
          Result := SGCFS_QUALITY_PREFIX;
      end;
    fsmkSuffix:
      begin
        p := NameLen - NeedleLen;
        if DoSameAt(Folded + p, Needle, NeedleLen) then
        begin
          MatchPos := p;
          MatchLen := NeedleLen;
          if p = 0 then
            Result := SGCFS_QUALITY_EXACT
          else if sgcFSearchIsWordStart(B, NameLen, p) then
            Result := SGCFS_QUALITY_WORD
          else
            Result := SGCFS_QUALITY_SUBSTR;
        end;
      end;
    fsmkWildcard:
      Result := DoWildQuality(Folded, NameLen, Needle, NeedleLen, MatchPos,
        MatchLen);
  else
    begin
      p := sgcFSearchPos(Folded, NameLen, Needle, NeedleLen, 0);
      if p < 0 then
      begin
        if (Fuzzy <> nil) and Fuzzy.Match(Folded, NameLen, MatchPos, MatchLen)
        then
          Result := SGCFS_QUALITY_FUZZY;
        Exit;
      end;
      MatchLen := NeedleLen;
      MatchPos := p;
      if p = 0 then
      begin
        if NameLen = NeedleLen then
          Result := SGCFS_QUALITY_EXACT
        else
          Result := SGCFS_QUALITY_PREFIX;
        Exit;
      end;
      Result := SGCFS_QUALITY_SUBSTR;
      q := p;
      while q >= 0 do
      begin
        if sgcFSearchIsWordStart(B, NameLen, q) then
        begin
          MatchPos := q;
          Result := SGCFS_QUALITY_WORD;
          Break;
        end;
        q := sgcFSearchPos(Folded, NameLen, Needle, NeedleLen, q + 1);
      end;
    end;
  end;
end;

function sgcFSearchMatchQualityRaw(Raw: PChar; NameLen: Integer; Needle: PChar;
  NeedleLen: Integer; Kind: TsgcFSearchMatchKind; Fuzzy: PsgcFSearchFuzzy;
  out MatchPos, MatchLen: Integer): Integer;
var
  vBuf: array [0 .. 511] of Char;
  vTmp: string;
  F: PChar;
begin
  if NameLen <= Length(vBuf) then
    F := @vBuf[0]
  else
  begin
    SetLength(vTmp, NameLen);
    F := PChar(vTmp);
  end;
  sgcFSearchFoldBuffer(Raw, F, NameLen);
  Result := sgcFSearchMatchQuality(F, Raw, NameLen, Needle, NeedleLen, Kind,
    Fuzzy, MatchPos, MatchLen);
end;

{ TsgcFSearchFuzzy }

procedure TsgcFSearchFuzzy.Init(Needle: PChar; Len: Integer);
var
  i, k: Integer;
  C: Char;
begin
  FillChar(FPeq, SizeOf(FPeq), 0);
  FWideCount := 0;
  FMask := 0;
  FLen := 0;
  if (Len < SGCFS_FUZZY_MIN_LEN) or (Len > SGCFS_FUZZY_MAX_LEN) then
    Exit;
  FLen := Len;
  for i := 0 to Len - 1 do
  begin
    C := Needle[i];
    FMask := FMask or (UInt64(1) shl (Ord(C) and 63));
    if Ord(C) < 256 then
      FPeq[Ord(C)] := FPeq[Ord(C)] or (UInt64(1) shl i)
    else
    begin
      k := 0;
      while (k < FWideCount) and (FWideChars[k] <> C) do
        Inc(k);
      if k = FWideCount then
      begin
        FWideChars[k] := C;
        FWideMasks[k] := 0;
        Inc(FWideCount);
      end;
      FWideMasks[k] := FWideMasks[k] or (UInt64(1) shl i);
    end;
  end;
end;

function TsgcFSearchFuzzy.DoPeq(C: Char): UInt64;
var
  k: Integer;
begin
  if Ord(C) < 256 then
    Exit(FPeq[Ord(C)]);
  for k := 0 to FWideCount - 1 do
    if FWideChars[k] = C then
      Exit(FWideMasks[k]);
  Result := 0;
end;

function TsgcFSearchFuzzy.Match(Hay: PChar; HayLen: Integer;
  out MatchPos, MatchLen: Integer): Boolean;
var
  i: Integer;
  vSeen, vHit, R0, R0p, R1, Bc, Bp, vNew0: UInt64;
begin
  Result := False;
  MatchPos := -1;
  MatchLen := 0;
  if (FLen = 0) or (HayLen < FLen - 1) then
    Exit;
  // prefilter: with one edit at most one needle char can be missing
  vSeen := 0;
  for i := 0 to HayLen - 1 do
    vSeen := vSeen or (UInt64(1) shl (Ord(Hay[i]) and 63));
  vSeen := FMask and not vSeen;
  if (vSeen and (vSeen - 1)) <> 0 then
    Exit;
  vHit := UInt64(1) shl (FLen - 1);
  R0 := 0; // exact state after the previous char
  R0p := 0; // exact state two chars back
  R1 := 1; // one error state (bit 0: first needle char deleted)
  Bp := 0;
  for i := 0 to HayLen - 1 do
  begin
    Bc := DoPeq(Hay[i]);
    vNew0 := ((R0 shl 1) or 1) and Bc;
    R1 := (((R1 shl 1) or 1) and Bc) // match
      or (R0 shl 1) or 1 // substitution
      or R0 // insertion (extra hay char)
      or (vNew0 shl 1) // deletion (needle char skipped)
      or (((R0p shl 2) or 2) and (Bc shl 1) and Bp); // transposition
    R0p := R0;
    R0 := vNew0;
    Bp := Bc;
    if (R1 and vHit) <> 0 then
    begin
      MatchPos := i - FLen + 1;
      if MatchPos < 0 then
        MatchPos := 0;
      MatchLen := i - MatchPos + 1;
      Exit(True);
    end;
  end;
end;

initialization

DoBuildFoldMap;

end.
