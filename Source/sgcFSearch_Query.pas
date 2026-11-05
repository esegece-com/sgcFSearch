{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Query;

{$I sgcVer.inc}
{ Query parser (no index access). Syntax:
  - words, AND semantics, matched against the name (case-insensitive).
  Modifiers: 'exact (whole name), ^prefix, suffix$, ^both$ (= exact),
  !exclude (combinable: !^tmp). Double quotes group spaces: "my file".
  - path tokens: a word with \ or / is split, the last component matches the
  name, the earlier ones ancestor folder names in order (substring):
  src\main, node_modules\ (anything below a node_modules folder).
  - filters (key:value, unknown keys stay literal words):
  ext:pas,dfm            extension list, no dot, files only
  type:images,code       documents images videos audio code archives apps
  fonts folders
  kind:dir|folder|file
  in:<path>              scope, descendants only, repeatable (OR), ~ = home
  path:<text>            substring of the full path, repeatable (AND)
  size:>10mb size:<1k size:1mb..5mb size:>=2g size:10k size:empty
  units b k kb kib m mb g gb t tb (1024 based), files only; size:empty
  also matches folders without children
  mtime:today|yesterday|week|month|year  (week = last 7 days incl. today,
  month = last 30 days, year = last 365 days, local time)
  mtime:<7d (newer than) mtime:>30d (older than), units h d w y
  mtime:>2026-01-01 (after that day) >= < <= = and 2026-10-01..2026-10-31
  re:<regex>             on the name, case-insensitive
  limit:N
  sort:name|size|date|rank  name ascending, size and date descending;
  suffix -asc / -desc forces the direction (sort:size-asc), a leading -
  reverses the default (sort:-date = oldest first)
  grep:<text> regex:<pattern> sym:<name>  content filters, parsed only.
  Parsing never raises: invalid values are ignored and listed in Warnings. }

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math,
  System.RegularExpressions,
  // sgc
  sgcFSearch_Types, sgcFSearch_Match, sgcFSearch_Config;

const
  SGCFS_DEFAULT_LIMIT = 100;

type
  TsgcFSearchSortKind = (fssRank, fssName, fssSize, fssDate);
  TsgcFSearchKindFilter = (fskAny, fskFile, fskDir);

  TsgcFSearchTerm = record
    Text: string; // name part as typed (modifiers and quotes removed)
    Folded: string; // folded name part, '' = any name (path token "src\")
    Kind: TsgcFSearchMatchKind;
    Exclude: Boolean;
    Dirs: TArray<string>; // folded ancestor components, outermost first
  end;

  TsgcFSearchQuery = record
    Text: string;
    Terms: TArray<TsgcFSearchTerm>;
    Exts: TArray<string>; // ext: folded, no dot
    TypeNames: TArray<string>; // type: categories, lower case
    TypeExts: TArray<string>; // union of the categories' extensions
    TypeDirs: Boolean; // type:folders
    Kind: TsgcFSearchKindFilter;
    InPaths: TArray<string>; // in: expanded, no trailing \ (except X:\)
    PathTexts: TArray<string>; // path: folded, / -> \
    HasSize: Boolean;
    SizeMin, SizeMax: Int64; // inclusive
    SizeEmpty: Boolean; // size:empty (also empty folders)
    HasMTime: Boolean;
    MTimeMin, MTimeMax: Int64; // FILETIME UTC, Min <= MTime < Max
    NameRegex: string; // re:
    Limit: Integer; // limit:, 0 = not given
    Sort: TsgcFSearchSortKind;
    SortDesc: Boolean;
    Grep: string; // grep:
    ContentRegex: string; // regex:
    Sym: string; // sym:
    Warnings: TArray<string>;
    /// At least one positive (non exclude) term.
    function HasNameTerms: Boolean;
    /// grep:, regex: or sym: given.
    function HasContentFilters: Boolean;
    function HasType: Boolean;
  end;

function sgcFSearchParseQuery(const Text: string): TsgcFSearchQuery; overload;
/// Now = local time used for mtime: relative values.
function sgcFSearchParseQuery(const Text: string; const Now: TDateTime)
  : TsgcFSearchQuery; overload;
/// Comma list of the extensions of a type: category ('' unknown, and for
/// folders, which matches directories).
function sgcFSearchTypeExtensions(const Category: string): string;
/// '10mb', '1.5k', '500' -> bytes.
function sgcFSearchParseSize(const S: string; out Value: Int64): Boolean;

// GUI filter chips, on the query TEXT (tokens are re-joined with one space)
function sgcFSearchQueryGetFilter(const Text, Key: string): string;
/// Replaces the first Key: filter (others of that key are removed) or
/// appends it; quotes the value when needed. Value '' removes the filter.
function sgcFSearchQuerySetFilter(const Text, Key, Value: string): string;
function sgcFSearchQueryRemoveFilter(const Text, Key: string): string;

implementation

type
  TsgcFSearchQueryToken = record
    Start, Len: Integer; // span in the text, 1-based
    Value: string; // quotes removed
    Quoted: TArray<Boolean>; // per char of Value (0-based)
    Colon: Integer; // 1-based position of the first unquoted ':', 0 none
  end;

const
  CS_KEYS: array [0 .. 12] of string = ('ext', 'type', 'kind', 'in', 'path',
    'size', 'mtime', 're', 'limit', 'sort', 'grep', 'regex', 'sym');

  CS_TYPE_DOCUMENTS = 'txt,md,pdf,doc,docx,odt,rtf,xls,xlsx,ods,csv,ppt,pptx,' +
    'odp,epub,tex,pages,numbers,key,xps';
  CS_TYPE_IMAGES = 'jpg,jpeg,png,gif,bmp,tif,tiff,webp,heic,heif,svg,ico,' +
    'psd,raw,cr2,nef,arw,dng,avif';
  CS_TYPE_VIDEOS = 'mp4,mkv,avi,mov,wmv,flv,webm,m4v,mpg,mpeg,3gp,mts,m2ts,vob';
  CS_TYPE_AUDIO = 'mp3,wav,flac,aac,ogg,m4a,wma,opus,aiff,aif,mid,midi,ape';
  CS_TYPE_CODE = 'pas,dpr,dpk,dfm,fmx,inc,c,h,cpp,hpp,cc,cxx,cs,java,js,mjs,' +
    'ts,tsx,jsx,py,rb,go,rs,php,swift,kt,kts,scala,sh,bat,cmd,ps1,psm1,lua,' +
    'pl,sql,html,htm,css,scss,less,json,xml,yaml,yml,toml,ini,vb,m,mm,dart,r';
  CS_TYPE_ARCHIVES = 'zip,rar,7z,tar,gz,tgz,bz2,xz,zst,cab,iso,lz,lzma,jar';
  CS_TYPE_APPS = 'exe,msi,msix,appx,appxbundle,com,scr,lnk';
  CS_TYPE_FONTS = 'ttf,otf,woff,woff2,fon,fnt,eot';

procedure DoWarn(var Q: TsgcFSearchQuery; const Msg: string);
begin
  Q.Warnings := Q.Warnings + [Msg];
end;

function DoTokenize(const Text: string): TArray<TsgcFSearchQueryToken>;
var
  i, n, vCount: Integer;
  vInQ: Boolean;
  c: Char;
  vTok: TsgcFSearchQueryToken;
begin
  Result := nil;
  i := 1;
  n := Length(Text);
  while i <= n do
  begin
    while (i <= n) and (Text[i] <= ' ') do
      Inc(i);
    if i > n then
      Break;
    vTok := Default (TsgcFSearchQueryToken);
    vTok.Start := i;
    vInQ := False;
    vCount := 0;
    SetLength(vTok.Value, n - i + 1);
    SetLength(vTok.Quoted, n - i + 1);
    while i <= n do
    begin
      c := Text[i];
      if c = '"' then
      begin
        vInQ := not vInQ;
        Inc(i);
        Continue;
      end;
      if (not vInQ) and (c <= ' ') then
        Break;
      Inc(vCount);
      vTok.Value[vCount] := c;
      vTok.Quoted[vCount - 1] := vInQ;
      if (c = ':') and (not vInQ) and (vTok.Colon = 0) then
        vTok.Colon := vCount;
      Inc(i);
    end;
    SetLength(vTok.Value, vCount);
    SetLength(vTok.Quoted, vCount);
    vTok.Len := i - vTok.Start;
    Result := Result + [vTok];
  end;
end;

function DoTokenKey(const T: TsgcFSearchQueryToken): string;
begin
  if T.Colon > 1 then
    Result := LowerCase(Copy(T.Value, 1, T.Colon - 1))
  else
    Result := '';
end;

function DoIsKey(const Key: string): Boolean;
var
  i: Integer;
begin
  for i := Low(CS_KEYS) to High(CS_KEYS) do
    if CS_KEYS[i] = Key then
      Exit(True);
  Result := False;
end;

function DoNormPath(const Path: string): string;
begin
  Result := StringReplace(Trim(Path), '/', '\', [rfReplaceAll]);
  while (Length(Result) > 1) and (Result[Length(Result)] = '\') and
    not((Length(Result) = 3) and (Result[2] = ':')) do
    SetLength(Result, Length(Result) - 1);
  if (Length(Result) = 2) and (Result[2] = ':') then
    Result := Result + '\';
end;

procedure DoTerm(var Q: TsgcFSearchQuery; const T: TsgcFSearchQueryToken);
var
  i, j, k: Integer;
  vPre, vSuf: Boolean;
  vTerm: TsgcFSearchTerm;
  vBody: string;
  vParts: TArray<string>;
begin
  vTerm := Default (TsgcFSearchTerm);
  vTerm.Kind := fsmkContains;
  vPre := False;
  vSuf := False;
  i := 1;
  j := Length(T.Value);
  while (i <= j) and not T.Quoted[i - 1] and
    CharInSet(T.Value[i], ['!', '^', '''']) do
  begin
    case T.Value[i] of
      '!':
        vTerm.Exclude := True;
      '^':
        vPre := True;
    else
      vTerm.Kind := fsmkExact;
    end;
    Inc(i);
  end;
  if (j >= i) and not T.Quoted[j - 1] and (T.Value[j] = '$') then
  begin
    vSuf := True;
    Dec(j);
  end;
  if vTerm.Kind <> fsmkExact then
  begin
    if vPre and vSuf then
      vTerm.Kind := fsmkExact
    else if vPre then
      vTerm.Kind := fsmkPrefix
    else if vSuf then
      vTerm.Kind := fsmkSuffix;
  end;
  vBody := Copy(T.Value, i, j - i + 1);
  if vBody = '' then
    Exit;
  if (Pos('\', vBody) > 0) or (Pos('/', vBody) > 0) then
  begin
    vParts := StringReplace(vBody, '/', '\', [rfReplaceAll]).Split(['\']);
    if Length(vParts) = 0 then
      Exit;
    vTerm.Text := vParts[High(vParts)];
    for k := 0 to High(vParts) - 1 do
      if vParts[k] <> '' then
        vTerm.Dirs := vTerm.Dirs + [sgcFSearchFold(vParts[k])];
    if (vTerm.Text = '') and (Length(vTerm.Dirs) = 0) then
      Exit;
  end
  else
    vTerm.Text := vBody;
  vTerm.Folded := sgcFSearchFold(vTerm.Text);
  Q.Terms := Q.Terms + [vTerm];
end;

function sgcFSearchTypeExtensions(const Category: string): string;
var
  c: string;
begin
  c := LowerCase(Trim(Category));
  if (c = 'documents') or (c = 'document') or (c = 'docs') then
    Result := CS_TYPE_DOCUMENTS
  else if (c = 'images') or (c = 'image') or (c = 'pictures') then
    Result := CS_TYPE_IMAGES
  else if (c = 'videos') or (c = 'video') then
    Result := CS_TYPE_VIDEOS
  else if (c = 'audio') or (c = 'music') then
    Result := CS_TYPE_AUDIO
  else if (c = 'code') or (c = 'source') then
    Result := CS_TYPE_CODE
  else if (c = 'archives') or (c = 'archive') then
    Result := CS_TYPE_ARCHIVES
  else if (c = 'apps') or (c = 'app') or (c = 'executables') then
    Result := CS_TYPE_APPS
  else if (c = 'fonts') or (c = 'font') then
    Result := CS_TYPE_FONTS
  else
    Result := '';
end;

function sgcFSearchParseSize(const S: string; out Value: Int64): Boolean;
var
  v, vNum, vUnit: string;
  i: Integer;
  vMul, vF: Double;
begin
  Result := False;
  Value := 0;
  v := LowerCase(Trim(S));
  i := 1;
  while (i <= Length(v)) and CharInSet(v[i], ['0' .. '9', '.']) do
    Inc(i);
  vNum := Copy(v, 1, i - 1);
  vUnit := Trim(Copy(v, i, MaxInt));
  if vNum = '' then
    Exit;
  if (vUnit = '') or (vUnit = 'b') then
    vMul := 1
  else if (vUnit = 'k') or (vUnit = 'kb') or (vUnit = 'kib') then
    vMul := 1024.0
  else if (vUnit = 'm') or (vUnit = 'mb') or (vUnit = 'mib') then
    vMul := 1024.0 * 1024
  else if (vUnit = 'g') or (vUnit = 'gb') or (vUnit = 'gib') then
    vMul := 1024.0 * 1024 * 1024
  else if (vUnit = 't') or (vUnit = 'tb') or (vUnit = 'tib') then
    vMul := 1024.0 * 1024 * 1024 * 1024
  else
    Exit;
  if not TryStrToFloat(vNum, vF, TFormatSettings.Invariant) then
    Exit;
  vF := vF * vMul;
  if (vF < 0) or (vF > 9.0E18) then
    Exit;
  Value := Round(vF);
  Result := True;
end;

procedure DoSize(var Q: TsgcFSearchQuery; const Val: string);
var
  v, a, b: string;
  p: Integer;
  vLo, vHi, n: Int64;
  vOk: Boolean;
begin
  v := LowerCase(Trim(Val));
  vLo := 0;
  vHi := High(Int64);
  vOk := True;
  if v = 'empty' then
  begin
    Q.SizeEmpty := True;
    vHi := 0;
  end
  else
  begin
    p := Pos('..', v);
    if p > 0 then
    begin
      a := Copy(v, 1, p - 1);
      b := Copy(v, p + 2, MaxInt);
      if a <> '' then
        vOk := sgcFSearchParseSize(a, vLo);
      if vOk and (b <> '') then
        vOk := sgcFSearchParseSize(b, vHi);
      vOk := vOk and ((a <> '') or (b <> ''));
    end
    else if Copy(v, 1, 2) = '>=' then
      vOk := sgcFSearchParseSize(Copy(v, 3, MaxInt), vLo)
    else if Copy(v, 1, 2) = '<=' then
      vOk := sgcFSearchParseSize(Copy(v, 3, MaxInt), vHi)
    else if Copy(v, 1, 1) = '>' then
    begin
      vOk := sgcFSearchParseSize(Copy(v, 2, MaxInt), n);
      vLo := n + 1;
    end
    else if Copy(v, 1, 1) = '<' then
    begin
      vOk := sgcFSearchParseSize(Copy(v, 2, MaxInt), n);
      vHi := n - 1;
    end
    else
    begin
      if Copy(v, 1, 1) = '=' then
        Delete(v, 1, 1);
      vOk := sgcFSearchParseSize(v, n);
      vLo := n;
      vHi := n;
    end;
  end;
  if not vOk then
  begin
    DoWarn(Q, 'invalid size: ' + Val);
    Exit;
  end;
  if not Q.HasSize then
  begin
    Q.SizeMin := 0;
    Q.SizeMax := High(Int64);
  end;
  Q.HasSize := True;
  Q.SizeMin := Max(Q.SizeMin, vLo);
  Q.SizeMax := Min(Q.SizeMax, vHi);
end;

function DoParseDate(const S: string; out D: TDateTime): Boolean;
var
  vParts: TArray<string>;
  y, m, dd: Integer;
begin
  Result := False;
  vParts := S.Split(['-']);
  if Length(vParts) <> 3 then
    Exit;
  if (Length(vParts[0]) <> 4) or not TryStrToInt(vParts[0], y) or
    not TryStrToInt(vParts[1], m) or not TryStrToInt(vParts[2], dd) then
    Exit;
  Result := TryEncodeDate(y, m, dd, D);
end;

function DoParseAge(const S: string; out Days: Double): Boolean;
var
  v, vNum: string;
  i: Integer;
  vF: Double;
begin
  Result := False;
  v := LowerCase(Trim(S));
  i := 1;
  while (i <= Length(v)) and CharInSet(v[i], ['0' .. '9', '.']) do
    Inc(i);
  vNum := Copy(v, 1, i - 1);
  if (vNum = '') or not TryStrToFloat(vNum, vF, TFormatSettings.Invariant) then
    Exit;
  v := Copy(v, i, MaxInt);
  if (v = '') or (v = 'd') then
    Days := vF
  else if v = 'h' then
    Days := vF / 24
  else if v = 'w' then
    Days := vF * 7
  else if v = 'y' then
    Days := vF * 365
  else
    Exit;
  Result := True;
end;

procedure DoMTime(var Q: TsgcFSearchQuery; const Val: string;
  const Now: TDateTime);
var
  v, vOp, a, b: string;
  vMid, d1, d2: TDateTime;
  vDays: Double;
  vLo, vHi: Int64;
  p: Integer;
  vOk: Boolean;
begin
  v := LowerCase(Trim(Val));
  vMid := DateOf(Now);
  vLo := Low(Int64);
  vHi := High(Int64);
  vOk := True;
  if v = 'today' then
    vLo := sgcFSearchLocalDateTimeToFileTime(vMid)
  else if v = 'yesterday' then
  begin
    vLo := sgcFSearchLocalDateTimeToFileTime(vMid - 1);
    vHi := sgcFSearchLocalDateTimeToFileTime(vMid);
  end
  else if v = 'week' then
    vLo := sgcFSearchLocalDateTimeToFileTime(vMid - 6)
  else if v = 'month' then
    vLo := sgcFSearchLocalDateTimeToFileTime(vMid - 29)
  else if v = 'year' then
    vLo := sgcFSearchLocalDateTimeToFileTime(vMid - 364)
  else
  begin
    p := Pos('..', v);
    if p > 0 then
    begin
      a := Copy(v, 1, p - 1);
      b := Copy(v, p + 2, MaxInt);
      vOk := DoParseDate(a, d1) and DoParseDate(b, d2);
      if vOk then
      begin
        vLo := sgcFSearchLocalDateTimeToFileTime(d1);
        vHi := sgcFSearchLocalDateTimeToFileTime(d2 + 1);
      end;
    end
    else
    begin
      vOp := '';
      if (Copy(v, 1, 2) = '>=') or (Copy(v, 1, 2) = '<=') then
        vOp := Copy(v, 1, 2)
      else if CharInSet(Copy(v + ' ', 1, 1)[1], ['<', '>', '=']) then
        vOp := Copy(v, 1, 1);
      a := Copy(v, Length(vOp) + 1, MaxInt);
      if DoParseDate(a, d1) then
      begin
        if vOp = '>' then
          vLo := sgcFSearchLocalDateTimeToFileTime(d1 + 1)
        else if vOp = '>=' then
          vLo := sgcFSearchLocalDateTimeToFileTime(d1)
        else if vOp = '<' then
          vHi := sgcFSearchLocalDateTimeToFileTime(d1)
        else if vOp = '<=' then
          vHi := sgcFSearchLocalDateTimeToFileTime(d1 + 1)
        else
        begin
          vLo := sgcFSearchLocalDateTimeToFileTime(d1);
          vHi := sgcFSearchLocalDateTimeToFileTime(d1 + 1);
        end;
      end
      else if DoParseAge(a, vDays) then
      begin
        // age: < newer than, > older than, bare = newer than
        if (vOp = '>') or (vOp = '>=') then
          vHi := sgcFSearchLocalDateTimeToFileTime(Now - vDays)
        else
          vLo := sgcFSearchLocalDateTimeToFileTime(Now - vDays);
      end
      else
        vOk := False;
    end;
  end;
  if not vOk then
  begin
    DoWarn(Q, 'invalid mtime: ' + Val);
    Exit;
  end;
  if not Q.HasMTime then
  begin
    Q.MTimeMin := Low(Int64);
    Q.MTimeMax := High(Int64);
  end;
  Q.HasMTime := True;
  Q.MTimeMin := Max(Q.MTimeMin, vLo);
  Q.MTimeMax := Min(Q.MTimeMax, vHi);
end;

procedure DoSort(var Q: TsgcFSearchQuery; const Val: string);
var
  v: string;
  vRev: Boolean;
  vDir: Integer;
begin
  v := LowerCase(Trim(Val));
  vRev := (v <> '') and (v[1] = '-');
  if vRev then
    Delete(v, 1, 1);
  vDir := 0;
  if v.EndsWith('-asc') then
  begin
    vDir := 1;
    SetLength(v, Length(v) - 4);
  end
  else if v.EndsWith('-desc') then
  begin
    vDir := 2;
    SetLength(v, Length(v) - 5);
  end;
  if v = 'name' then
  begin
    Q.Sort := fssName;
    Q.SortDesc := False;
  end
  else if v = 'size' then
  begin
    Q.Sort := fssSize;
    Q.SortDesc := True;
  end
  else if (v = 'date') or (v = 'mtime') then
  begin
    Q.Sort := fssDate;
    Q.SortDesc := True;
  end
  else if (v = 'rank') or (v = 'score') then
  begin
    Q.Sort := fssRank;
    Q.SortDesc := False;
    Exit;
  end
  else
  begin
    DoWarn(Q, 'invalid sort: ' + Val);
    Exit;
  end;
  if vDir = 1 then
    Q.SortDesc := False
  else if vDir = 2 then
    Q.SortDesc := True;
  if vRev then
    Q.SortDesc := not Q.SortDesc;
end;

procedure DoFilter(var Q: TsgcFSearchQuery; const Key, Val: string;
  const Now: TDateTime);
var
  S, c: string;
  vList: TArray<string>;
  n: Integer;
begin
  if Trim(Val) = '' then
  begin
    DoWarn(Q, 'empty value: ' + Key + ':');
    Exit;
  end;
  if Key = 'ext' then
  begin
    n := Length(Q.Exts);
    for S in Val.Split([',']) do
    begin
      c := Trim(S);
      while (c <> '') and (c[1] = '.') do
        Delete(c, 1, 1);
      if c <> '' then
        Q.Exts := Q.Exts + [sgcFSearchFold(c)];
    end;
    if Length(Q.Exts) = n then
      DoWarn(Q, 'invalid ext: ' + Val);
  end
  else if Key = 'type' then
  begin
    for S in Val.Split([',']) do
    begin
      c := LowerCase(Trim(S));
      if c = '' then
        Continue;
      if (c = 'folders') or (c = 'folder') or (c = 'dirs') or (c = 'dir') then
        Q.TypeDirs := True
      else
      begin
        vList := sgcFSearchTypeExtensions(c).Split([',']);
        if Length(vList) = 0 then
        begin
          DoWarn(Q, 'unknown type: ' + c);
          Continue;
        end;
        Q.TypeExts := Q.TypeExts + vList;
      end;
      Q.TypeNames := Q.TypeNames + [c];
    end;
  end
  else if Key = 'kind' then
  begin
    c := LowerCase(Trim(Val));
    if (c = 'dir') or (c = 'dirs') or (c = 'folder') or (c = 'folders') then
      Q.Kind := fskDir
    else if (c = 'file') or (c = 'files') then
      Q.Kind := fskFile
    else
      DoWarn(Q, 'invalid kind: ' + Val);
  end
  else if Key = 'in' then
    Q.InPaths := Q.InPaths + [DoNormPath(sgcFSearchExpandUserPath(Trim(Val)))]
  else if Key = 'path' then
    Q.PathTexts := Q.PathTexts +
      [sgcFSearchFold(StringReplace(Val, '/', '\', [rfReplaceAll]))]
  else if Key = 'size' then
    DoSize(Q, Val)
  else if Key = 'mtime' then
    DoMTime(Q, Val, Now)
  else if Key = 're' then
  begin
    try
      TRegEx.Create(Val, [roIgnoreCase]).IsMatch('');
      Q.NameRegex := Val;
    except
      DoWarn(Q, 'invalid regex: ' + Val);
    end;
  end
  else if Key = 'limit' then
  begin
    n := StrToIntDef(Trim(Val), 0);
    if n > 0 then
      Q.Limit := n
    else
      DoWarn(Q, 'invalid limit: ' + Val);
  end
  else if Key = 'sort' then
    DoSort(Q, Val)
  else if Key = 'grep' then
    Q.Grep := Val
  else if Key = 'regex' then
    Q.ContentRegex := Val
  else if Key = 'sym' then
    Q.Sym := Val;
end;

function sgcFSearchParseQuery(const Text: string; const Now: TDateTime)
  : TsgcFSearchQuery;
var
  vTokens: TArray<TsgcFSearchQueryToken>;
  i: Integer;
  vKey: string;
begin
  Result := Default (TsgcFSearchQuery);
  Result.Text := Text;
  Result.SizeMin := 0;
  Result.SizeMax := High(Int64);
  Result.MTimeMin := Low(Int64);
  Result.MTimeMax := High(Int64);
  Result.Sort := fssRank;
  Result.Kind := fskAny;
  try
    vTokens := DoTokenize(Text);
    for i := 0 to High(vTokens) do
    begin
      vKey := DoTokenKey(vTokens[i]);
      if (vKey <> '') and DoIsKey(vKey) then
        DoFilter(Result, vKey, Copy(vTokens[i].Value, vTokens[i].Colon + 1,
          MaxInt), Now)
      else
        DoTerm(Result, vTokens[i]);
    end;
  except
    on E: Exception do
      DoWarn(Result, 'parse error: ' + E.Message);
  end;
end;

function sgcFSearchParseQuery(const Text: string): TsgcFSearchQuery;
begin
  Result := sgcFSearchParseQuery(Text, System.SysUtils.Now);
end;

{ TsgcFSearchQuery }

function TsgcFSearchQuery.HasNameTerms: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Terms) do
    if not Terms[i].Exclude then
      Exit(True);
  Result := False;
end;

function TsgcFSearchQuery.HasContentFilters: Boolean;
begin
  Result := (Grep <> '') or (ContentRegex <> '') or (Sym <> '');
end;

function TsgcFSearchQuery.HasType: Boolean;
begin
  Result := TypeDirs or (Length(TypeExts) > 0);
end;

{ chips }

function sgcFSearchQueryGetFilter(const Text, Key: string): string;
var
  vTokens: TArray<TsgcFSearchQueryToken>;
  i: Integer;
  vKey: string;
begin
  Result := '';
  vKey := LowerCase(Key);
  vTokens := DoTokenize(Text);
  for i := 0 to High(vTokens) do
    if DoTokenKey(vTokens[i]) = vKey then
      Exit(Copy(vTokens[i].Value, vTokens[i].Colon + 1, MaxInt));
end;

function DoQuote(const Value: string): string;
var
  i: Integer;
  vNeed: Boolean;
begin
  Result := StringReplace(Value, '"', '', [rfReplaceAll]);
  vNeed := False;
  for i := 1 to Length(Result) do
    if Result[i] <= ' ' then
      vNeed := True;
  if vNeed then
    Result := '"' + Result + '"';
end;

function sgcFSearchQuerySetFilter(const Text, Key, Value: string): string;
var
  vTokens: TArray<TsgcFSearchQueryToken>;
  vParts: TArray<string>;
  i: Integer;
  vKey: string;
  vDone: Boolean;
begin
  vKey := LowerCase(Key);
  vTokens := DoTokenize(Text);
  vParts := nil;
  vDone := False;
  for i := 0 to High(vTokens) do
  begin
    if DoTokenKey(vTokens[i]) = vKey then
    begin
      if (not vDone) and (Value <> '') then
        vParts := vParts + [vKey + ':' + DoQuote(Value)];
      vDone := True;
    end
    else
      vParts := vParts + [Copy(Text, vTokens[i].Start, vTokens[i].Len)];
  end;
  if (not vDone) and (Value <> '') then
    vParts := vParts + [vKey + ':' + DoQuote(Value)];
  Result := string.Join(' ', vParts);
end;

function sgcFSearchQueryRemoveFilter(const Text, Key: string): string;
begin
  Result := sgcFSearchQuerySetFilter(Text, Key, '');
end;

end.
