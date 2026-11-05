{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Extract;

{$I sgcVer.inc}
{ Text extraction for the content index and the content search.

  - Plain text: by extension (constant table) or, for unknown extensions, by
  a sniff of the first 4 KB (no NUL byte unless a UTF-16 BOM). Encodings:
  UTF-8 / UTF-16 LE / UTF-16 BE BOMs, valid UTF-8 without BOM, UTF-16
  without BOM (known text extensions only), else ANSI 1252.
  - OOXML (docx, xlsx, pptx) and OpenDocument (odt, ods, odp) through
  System.Zip and a linear XML scanner (no DOM, no Office needed).
  - pdf and legacy Office / rtf through the registered IFilter (query.dll
  LoadIFilter), with a time budget checked between chunks. Not registered:
  fserUnsupported.
  COM: IFilter extraction needs COM on the calling thread. Threads that
  extract many files should call CoInitializeEx(nil, COINIT_MULTITHREADED)
  once; sgcFSearchExtractText initialises (and releases) COM itself when the
  thread has not, which works but is slow when repeated.
  - Online-only cloud files (FILE_ATTRIBUTE_OFFLINE, RECALL_ON_OPEN,
  RECALL_ON_DATA_ACCESS) are never opened: opening them downloads them.
  All functions are thread-safe. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  // sgc
  sgcFSearch_Types;

type
  TsgcFSearchExtractResult = (fserOK, // Text holds the content
    fserTooBig, // larger than MaxBytes
    fserBinary, // binary extension or binary data
    fserOffline, // online-only cloud file, not opened
    fserUnsupported, // no extractor (no IFilter registered, folder ...)
    fserError); // missing, locked or corrupt file

  TsgcFSearchFileKind = (fsfkUnknown, // no / unknown extension: sniff
    fsfkText, fsfkBinary, fsfkWord, fsfkExcel, fsfkPowerPoint, fsfkOpenDocument,
    fsfkIFilter);

const
  SGCFS_SNIFF_BYTES = 4096;
  SGCFS_IFILTER_TIMEOUT_MS = 10000;
  SGCFS_ZIP_PART_MAX = 256 * 1024 * 1024;

  /// Kind of a file by its extension (case-insensitive).
function sgcFSearchFileKind(const FileName: string): TsgcFSearchFileKind;
/// Lower case extension without the dot ('' if none).
function sgcFSearchFileExt(const FileName: string): string;
/// True for online-only cloud files (offline, recall on open / data access).
function sgcFSearchIsOfflineAttributes(Attributes: Cardinal): Boolean;
/// Attributes, size and last write time (FILETIME UTC) without opening the
/// file. False if it does not exist.
function sgcFSearchGetFileInfo(const FileName: string; out Attributes: Cardinal;
  out Size, MTime: Int64): Boolean;
/// True if the first 4 KB hold a NUL byte and no UTF-16 BOM.
function sgcFSearchIsBinaryData(const Buffer: TBytes; Count: Integer): Boolean;
/// Decodes text bytes: BOMs, valid UTF-8, optional UTF-16 without BOM
/// heuristic, else ANSI 1252.
function sgcFSearchDecodeText(const Buffer: TBytes; Count: Integer;
  AllowUTF16NoBom: Boolean = False): string;
/// True if an IFilter is registered for the extension ('pdf' or '.pdf').
function sgcFSearchIFilterAvailable(const Ext: string): Boolean;
/// Extracts the text of a file. MaxBytes <= 0 means no size limit.
function sgcFSearchExtractText(const FileName: string; MaxBytes: Int64;
  out Text: string): TsgcFSearchExtractResult;

implementation

uses
  Winapi.ActiveX, System.Zip, System.Win.Registry, System.Generics.Collections,
  System.Generics.Defaults, System.SyncObjs, System.StrUtils;

const
  CS_TEXT_EXT = 'txt,text,md,markdown,rst,log,csv,tsv,ini,cfg,conf,config,' +
    'json,jsonc,xml,xsd,xsl,xslt,html,htm,xhtml,css,scss,sass,less,js,mjs,' +
    'cjs,ts,tsx,jsx,vue,svelte,pas,dpr,dpk,dfm,fmx,inc,lpr,lpi,pp,c,h,cc,' +
    'cpp,cxx,hpp,hh,hxx,cs,vb,fs,fsx,java,kt,kts,scala,groovy,gradle,go,rs,' +
    'swift,m,mm,py,pyw,rb,php,pl,pm,lua,r,sql,sh,bash,zsh,ps1,psm1,psd1,bat,' +
    'cmd,yaml,yml,toml,properties,env,gitignore,editorconfig,dockerfile,' +
    'makefile,cmake,mak,mk,tex,bib,srt,vtt,sln,csproj,vbproj,vcxproj,dproj,' +
    'groupproj,props,targets,resx,rc,def,asm,s,nim,zig,dart,ex,exs,erl,hrl,' +
    'hs,elm,clj,cljs,edn,ml,mli,tf,hcl,proto,graphql,gql,svg,iss,nsi,reg,' +
    'diff,patch,manifest,plist,cshtml,razor,aspx,ascx,jsp,erb,twig,hbs,' +
    'mustache,cfm,awk,vbs,wsf,au3,ahk';
  CS_BINARY_EXT = 'exe,dll,sys,ocx,bpl,dcu,dcp,obj,o,lib,a,so,dylib,pdb,ilk,' +
    'exp,res,rsm,tds,zip,7z,rar,gz,tgz,bz2,xz,zst,cab,msi,msp,msix,appx,iso,' +
    'img,vhd,vhdx,vmdk,jpg,jpeg,png,gif,bmp,ico,cur,tif,tiff,webp,heic,avif,' +
    'psd,raw,cr2,nef,mp3,mp4,m4a,m4v,wav,flac,ogg,opus,avi,mov,mkv,wmv,webm,' +
    'ttf,otf,woff,woff2,eot,class,jar,war,pyc,pyo,db,sqlite,mdb,accdb,ldf,' +
    'mdf,bin,pak,lnk,chm,dmp,etl,evtx,pst,ost,nupkg,apk,ipa,deb,rpm,blend,' +
    'fbx,glb,unitypackage,swf,dat,idx,pch,ipch,suo,ncb,sdf,vsix';
  CS_WORD_EXT = 'docx,docm,dotx,dotm';
  CS_EXCEL_EXT = 'xlsx,xlsm,xltx,xltm';
  CS_POWERPOINT_EXT = 'pptx,pptm,potx,ppsx';
  CS_ODF_EXT = 'odt,ods,odp,ott,ots,otp';
  CS_IFILTER_EXT = 'pdf,doc,xls,ppt,rtf';

  CS_IID_IFILTER = '{89BCB740-6119-101A-BCB7-00DD010655AF}';

  // IFilter (filter.h / filterr.h)
  IFILTER_INIT_CANON_PARAGRAPHS = 1;
  IFILTER_INIT_HARD_LINE_BREAKS = 2;
  IFILTER_INIT_CANON_HYPHENS = 4;
  IFILTER_INIT_CANON_SPACES = 8;
  CHUNK_TEXT = 1;
  CHUNK_NO_BREAK = 0;
  CHUNK_EOW = 1;
  FILTER_E_END_OF_CHUNKS = HRESULT($80041700);
  FILTER_E_NO_MORE_TEXT = HRESULT($80041701);
  FILTER_E_EMBEDDING_UNAVAILABLE = HRESULT($80041707);
  FILTER_E_LINK_UNAVAILABLE = HRESULT($80041708);
  FILTER_S_LAST_TEXT = HRESULT($00041709);

type
  TsgcFSearchPropSpec = record
    ulKind: ULONG;
    case Integer of
      0:
        (propid: ULONG);
      1:
        (lpwstr: PWideChar);
  end;

  TsgcFSearchFullPropSpec = record
    guidPropSet: TGUID;
    psProperty: TsgcFSearchPropSpec;
  end;

  TsgcFSearchStatChunk = record
    idChunk: ULONG;
    breakType: Integer;
    flags: Integer;
    locale: LCID;
    attribute: TsgcFSearchFullPropSpec;
    idChunkSource: ULONG;
    cwcStartSource: ULONG;
    cwcLenSource: ULONG;
  end;

  IsgcFSearchFilter = interface(IUnknown)
    [CS_IID_IFILTER]
    function Init(grfFlags: ULONG; cAttributes: ULONG; aAttributes: Pointer;
      out pFlags: ULONG): HRESULT; stdcall;
    function GetChunk(out pStat: TsgcFSearchStatChunk): HRESULT; stdcall;
    function GetText(var pcwcBuffer: ULONG; awcBuffer: PWideChar)
      : HRESULT; stdcall;
    function GetValue(out ppPropValue: Pointer): HRESULT; stdcall;
    function BindRegion(origPos: Pointer; const riid: TGUID; out ppunk)
      : HRESULT; stdcall;
  end;

  TsgcFSearchLoadIFilter = function(pwcsPath: PWideChar; pUnkOuter: Pointer;
    out ppIUnk: IUnknown): HRESULT; stdcall;

var
  GKinds: TDictionary<string, TsgcFSearchFileKind>;
  GLock: TCriticalSection;
  GFilterCache: TDictionary<string, string>;
  GQueryLib: HMODULE;
  GQueryTried: Boolean;
  GLoadIFilter: TsgcFSearchLoadIFilter;

procedure DoAddKinds(const List: string; Kind: TsgcFSearchFileKind);
var
  vExt: string;
begin
  for vExt in List.Split([',']) do
    GKinds.AddOrSetValue(vExt, Kind);
end;

function DoLongPath(const Path: string): string;
begin
  if (Length(Path) >= MAX_PATH - 12) and (Copy(Path, 1, 2) <> '\\') then
    Result := '\\?\' + Path
  else
    Result := Path;
end;

function sgcFSearchFileExt(const FileName: string): string;
var
  i: Integer;
begin
  Result := '';
  i := Length(FileName);
  while (i > 0) and (FileName[i] <> '.') and (FileName[i] <> '\') and
    (FileName[i] <> '/') do
    Dec(i);
  if (i > 0) and (FileName[i] = '.') then
    Result := LowerCase(Copy(FileName, i + 1, MaxInt));
end;

function sgcFSearchFileKind(const FileName: string): TsgcFSearchFileKind;
var
  vExt: string;
begin
  vExt := sgcFSearchFileExt(FileName);
  if (vExt = '') or not GKinds.TryGetValue(vExt, Result) then
    Result := fsfkUnknown;
end;

function sgcFSearchIsOfflineAttributes(Attributes: Cardinal): Boolean;
begin
  Result := (Attributes and (FILE_ATTRIBUTE_OFFLINE or
    SGCFS_ATTR_RECALL_ON_OPEN or SGCFS_ATTR_RECALL_ON_DATA_ACCESS)) <> 0;
end;

function sgcFSearchGetFileInfo(const FileName: string; out Attributes: Cardinal;
  out Size, MTime: Int64): Boolean;
var
  vData: TWin32FileAttributeData;
begin
  Result := GetFileAttributesEx(PChar(DoLongPath(FileName)),
    GetFileExInfoStandard, @vData);
  if Result then
  begin
    Attributes := vData.dwFileAttributes;
    Size := (Int64(vData.nFileSizeHigh) shl 32) or vData.nFileSizeLow;
    MTime := (Int64(vData.ftLastWriteTime.dwHighDateTime) shl 32) or
      vData.ftLastWriteTime.dwLowDateTime;
  end
  else
  begin
    Attributes := 0;
    Size := 0;
    MTime := 0;
  end;
end;

// 0 = no, 1 = UTF-16 LE, 2 = UTF-16 BE (no BOM, ASCII-heavy text)
function DoUTF16NoBom(const Buffer: TBytes; Count: Integer): Integer;
var
  i, vPairs, vZeroEven, vZeroOdd: Integer;
begin
  Result := 0;
  if Count > SGCFS_SNIFF_BYTES then
    Count := SGCFS_SNIFF_BYTES;
  vPairs := Count div 2;
  if vPairs < 2 then
    Exit;
  vZeroEven := 0;
  vZeroOdd := 0;
  for i := 0 to vPairs - 1 do
  begin
    if Buffer[2 * i] = 0 then
      Inc(vZeroEven);
    if Buffer[2 * i + 1] = 0 then
      Inc(vZeroOdd);
  end;
  if (vZeroOdd * 10 >= vPairs * 7) and (vZeroEven * 20 <= vPairs) then
    Result := 1
  else if (vZeroEven * 10 >= vPairs * 7) and (vZeroOdd * 20 <= vPairs) then
    Result := 2;
end;

function DoIsBinary(const Buffer: TBytes; Count: Integer;
  AllowUTF16NoBom: Boolean): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  if (Count >= 2) and (((Buffer[0] = $FF) and (Buffer[1] = $FE)) or
    ((Buffer[0] = $FE) and (Buffer[1] = $FF))) then
    Exit;
  n := Count;
  if n > SGCFS_SNIFF_BYTES then
    n := SGCFS_SNIFF_BYTES;
  for i := 0 to n - 1 do
    if Buffer[i] = 0 then
    begin
      Result := not(AllowUTF16NoBom and (DoUTF16NoBom(Buffer, Count) <> 0));
      Exit;
    end;
end;

function sgcFSearchIsBinaryData(const Buffer: TBytes; Count: Integer): Boolean;
begin
  Result := DoIsBinary(Buffer, Count, False);
end;

function DoMultiByte(CodePage, flags: Cardinal; P: PByte; Len: Integer;
  out S: string): Boolean;
var
  n: Integer;
begin
  S := '';
  if Len <= 0 then
    Exit(True);
  n := MultiByteToWideChar(CodePage, flags, PAnsiChar(P), Len, nil, 0);
  Result := n > 0;
  if Result then
  begin
    SetLength(S, n);
    MultiByteToWideChar(CodePage, flags, PAnsiChar(P), Len, PChar(S), n);
  end;
end;

function DoUTF16(P: PByte; ByteLen: Integer; BigEndian: Boolean): string;
var
  i: Integer;
  vP: PWord;
begin
  SetLength(Result, ByteLen div 2);
  if ByteLen div 2 = 0 then
    Exit;
  Move(P^, PChar(Result)^, (ByteLen div 2) * SizeOf(Char));
  if BigEndian then
  begin
    vP := PWord(PChar(Result));
    for i := 0 to ByteLen div 2 - 1 do
    begin
      vP^ := Swap(vP^);
      Inc(vP);
    end;
  end;
end;

function sgcFSearchDecodeText(const Buffer: TBytes; Count: Integer;
  AllowUTF16NoBom: Boolean = False): string;
begin
  Result := '';
  if Count <= 0 then
    Exit;
  if (Count >= 3) and (Buffer[0] = $EF) and (Buffer[1] = $BB) and
    (Buffer[2] = $BF) then
    DoMultiByte(CP_UTF8, 0, @Buffer[3], Count - 3, Result)
  else if (Count >= 2) and (Buffer[0] = $FF) and (Buffer[1] = $FE) then
    Result := DoUTF16(@Buffer[2], Count - 2, False)
  else if (Count >= 2) and (Buffer[0] = $FE) and (Buffer[1] = $FF) then
    Result := DoUTF16(@Buffer[2], Count - 2, True)
  else
  begin
    if AllowUTF16NoBom then
      case DoUTF16NoBom(Buffer, Count) of
        1:
          Exit(DoUTF16(@Buffer[0], Count, False));
        2:
          Exit(DoUTF16(@Buffer[0], Count, True));
      end;
    if not DoMultiByte(CP_UTF8, MB_ERR_INVALID_CHARS, @Buffer[0], Count, Result)
    then
      DoMultiByte(1252, 0, @Buffer[0], Count, Result);
  end;
end;

// ---------------------------------------------------------------- plain text

function DoReadBlock(Handle: THandle; var Buffer: TBytes;
  Offset, Count: Integer): Integer;
var
  vGot: DWORD;
begin
  Result := 0;
  while Result < Count do
  begin
    if not ReadFile(Handle, Buffer[Offset + Result], Count - Result, vGot, nil)
    then
      Exit(-1);
    if vGot = 0 then
      Break;
    Inc(Result, vGot);
  end;
end;

function DoExtractPlain(const FileName: string; Kind: TsgcFSearchFileKind;
  MaxBytes: Int64; out Text: string): TsgcFSearchExtractResult;
var
  vHandle: THandle;
  vSize: Int64;
  vBuffer: TBytes;
  vCount, vRead, vFirst: Integer;
begin
  Result := fserError;
  Text := '';
  vHandle := CreateFile(PChar(DoLongPath(FileName)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
  if vHandle = INVALID_HANDLE_VALUE then
    Exit;
  try
    if not GetFileSizeEx(vHandle, vSize) then
      Exit;
    if ((MaxBytes > 0) and (vSize > MaxBytes)) or (vSize > MaxInt - 16) then
      Exit(fserTooBig);
    SetLength(vBuffer, vSize);
    vFirst := vSize;
    if vFirst > SGCFS_SNIFF_BYTES then
      vFirst := SGCFS_SNIFF_BYTES;
    vCount := DoReadBlock(vHandle, vBuffer, 0, vFirst);
    if vCount < 0 then
      Exit;
    if DoIsBinary(vBuffer, vCount, Kind = fsfkText) then
      Exit(fserBinary);
    if vCount = vFirst then
    begin
      vRead := DoReadBlock(vHandle, vBuffer, vCount, vSize - vCount);
      if vRead < 0 then
        Exit;
      Inc(vCount, vRead);
    end;
    Text := sgcFSearchDecodeText(vBuffer, vCount, Kind = fsfkText);
    Result := fserOK;
  finally
    CloseHandle(vHandle);
  end;
end;

// ---------------------------------------------------------------- XML

function DoXmlToText(const Xml: TBytes; ODF: Boolean): string;
var
  S, vName, vEnt: string;
  n, i, j, k, o, vCap, vCode: Integer;
  vClosing, vSelf: Boolean;
  c, q: Char;

  procedure Emit(ch: Char);
  begin
    Inc(o);
    Result[o] := ch;
  end;

  procedure EmitSep(ch: Char);
  begin
    if o = 0 then
      Exit;
    if Result[o] = #10 then
      Exit;
    if Result[o] = #9 then
    begin
      Result[o] := ch;
      Exit;
    end;
    Emit(ch);
  end;

  procedure EmitCode(Code: Integer);
  begin
    if (Code <= 0) or (Code > $10FFFF) then
      Exit;
    if Code < $10000 then
      Emit(Char(Code))
    else
    begin
      Dec(Code, $10000);
      Emit(Char($D800 + (Code shr 10)));
      Emit(Char($DC00 + (Code and $3FF)));
    end;
  end;

  function IsCapture(const Name: string): Boolean;
  begin
    if ODF then
      Result := (Name = 'p') or (Name = 'h')
    else
      Result := Name = 't';
  end;

begin
  S := TEncoding.UTF8.GetString(Xml);
  n := Length(S);
  SetLength(Result, n);
  o := 0;
  vCap := 0;
  i := 1;
  while i <= n do
  begin
    c := S[i];
    if c = '<' then
    begin
      if (i + 3 <= n) and (S[i + 1] = '!') and (S[i + 2] = '-') and
        (S[i + 3] = '-') then
      begin
        j := PosEx('-->', S, i + 4);
        if j = 0 then
          Break;
        i := j + 3;
        Continue;
      end;
      if (i + 8 <= n) and (S[i + 1] = '!') and (S[i + 2] = '[') and
        (Copy(S, i, 9) = '<![CDATA[') then
      begin
        j := PosEx(']]>', S, i + 9);
        if j = 0 then
          j := n + 1;
        if vCap > 0 then
          for k := i + 9 to j - 1 do
            Emit(S[k]);
        i := j + 3;
        Continue;
      end;
      j := i + 1;
      vClosing := (j <= n) and (S[j] = '/');
      if vClosing then
        Inc(j);
      if (j <= n) and ((S[j] = '?') or (S[j] = '!')) then
      begin
        j := PosEx('>', S, j);
        if j = 0 then
          Break;
        i := j + 1;
        Continue;
      end;
      k := j;
      while (j <= n) and (S[j] <> ' ') and (S[j] <> '/') and (S[j] <> '>') and
        (S[j] <> #9) and (S[j] <> #10) and (S[j] <> #13) do
        Inc(j);
      // local name (after the namespace prefix)
      i := j - 1;
      while (i >= k) and (S[i] <> ':') do
        Dec(i);
      vName := Copy(S, i + 1, j - i - 1);
      q := #0;
      while j <= n do
      begin
        if q <> #0 then
        begin
          if S[j] = q then
            q := #0;
        end
        else if (S[j] = '"') or (S[j] = '''') then
          q := S[j]
        else if S[j] = '>' then
          Break;
        Inc(j);
      end;
      vSelf := (j <= n) and (S[j - 1] = '/');
      if IsCapture(vName) then
      begin
        if vClosing then
        begin
          if vCap > 0 then
            Dec(vCap);
        end
        else if not vSelf then
          Inc(vCap);
      end;
      if not vClosing then
      begin
        if vName = 'tab' then
          EmitSep(#9)
        else if (vName = 'br') or (vName = 'cr') or (vName = 'line-break') then
          EmitSep(#10)
        else if ODF and (vName = 's') then
          Emit(' ');
      end;
      if vClosing or vSelf then
      begin
        if (vName = 'p') or (vName = 'h') or (vName = 'tr') or (vName = 'row')
          or (vName = 'table-row') or (vName = 'si') then
          EmitSep(#10)
        else if (vName = 'tc') or (vName = 'c') or (vName = 'table-cell') then
          EmitSep(#9);
      end;
      i := j + 1;
    end
    else if (c = '&') and (vCap > 0) then
    begin
      j := i + 1;
      while (j <= n) and (j - i <= 10) and (S[j] <> ';') do
        Inc(j);
      if (j <= n) and (S[j] = ';') then
      begin
        vEnt := Copy(S, i + 1, j - i - 1);
        if vEnt = 'lt' then
          Emit('<')
        else if vEnt = 'gt' then
          Emit('>')
        else if vEnt = 'amp' then
          Emit('&')
        else if vEnt = 'quot' then
          Emit('"')
        else if vEnt = 'apos' then
          Emit('''')
        else if (Length(vEnt) > 1) and (vEnt[1] = '#') then
        begin
          if (vEnt[2] = 'x') or (vEnt[2] = 'X') then
            vCode := StrToIntDef('$' + Copy(vEnt, 3, MaxInt), 0)
          else
            vCode := StrToIntDef(Copy(vEnt, 2, MaxInt), 0);
          EmitCode(vCode);
        end
        else
        begin
          Emit('&');
          Inc(i);
          Continue;
        end;
        i := j + 1;
      end
      else
      begin
        Emit('&');
        Inc(i);
      end;
    end
    else
    begin
      if vCap > 0 then
        Emit(c);
      Inc(i);
    end;
  end;
  SetLength(Result, o);
end;

// ---------------------------------------------------------------- zip

function DoIsTextPart(Kind: TsgcFSearchFileKind; const Name: string): Boolean;
begin
  case Kind of
    fsfkWord:
      Result := (Name = 'word/document.xml') or
        ((StartsStr('word/header', Name) or StartsStr('word/footer', Name)) and
        EndsStr('.xml', Name));
    fsfkExcel:
      Result := (Name = 'xl/sharedstrings.xml') or
        (StartsStr('xl/worksheets/sheet', Name) and EndsStr('.xml', Name));
    fsfkPowerPoint:
      Result := StartsStr('ppt/slides/slide', Name) and EndsStr('.xml', Name);
    fsfkOpenDocument:
      Result := Name = 'content.xml';
  else
    Result := False;
  end;
end;

function DoExtractZip(const FileName: string; Kind: TsgcFSearchFileKind;
  out Text: string): TsgcFSearchExtractResult;
var
  vStream: TStream;
  vZip: TZipFile;
  vSB: TStringBuilder;
  vBytes: TBytes;
  i: Integer;
begin
  Result := fserError;
  Text := '';
  try
    vStream := TFileStream.Create(DoLongPath(FileName), fmOpenRead or
      fmShareDenyNone);
  except
    Exit;
  end;
  try
    vZip := TZipFile.Create;
    try
      try
        vZip.Open(vStream, zmRead);
      except
        Exit(fserUnsupported);
      end;
      vSB := TStringBuilder.Create;
      try
        for i := 0 to vZip.FileCount - 1 do
        begin
          if not DoIsTextPart(Kind, LowerCase(vZip.FileNames[i])) then
            Continue;
          if vZip.FileInfo[i].UncompressedSize > SGCFS_ZIP_PART_MAX then
            Continue;
          vZip.Read(i, vBytes);
          vSB.Append(DoXmlToText(vBytes, Kind = fsfkOpenDocument));
          vSB.Append(#10);
        end;
        Text := vSB.ToString;
        Result := fserOK;
      finally
        vSB.Free;
      end;
    finally
      vZip.Free;
    end;
  finally
    vStream.Free;
  end;
end;

// ---------------------------------------------------------------- IFilter

function DoRegDefault(const Key: string; out Value: string): Boolean;
var
  vReg: TRegistry;
begin
  Value := '';
  vReg := TRegistry.Create(KEY_READ);
  try
    vReg.RootKey := HKEY_CLASSES_ROOT;
    if vReg.OpenKeyReadOnly(Key) then
    begin
      if vReg.ValueExists('') then
        Value := vReg.ReadString('');
      vReg.CloseKey;
    end;
  finally
    vReg.Free;
  end;
  Result := Value <> '';
end;

// CLSID of the IFilter registered for an extension, '' if none.
function DoFindFilter(const Ext: string): string;
var
  vHandler, vProgId, vClsid: string;
begin
  Result := '';
  if not DoRegDefault('.' + Ext + '\PersistentHandler', vHandler) then
    if DoRegDefault('.' + Ext, vProgId) and DoRegDefault(vProgId + '\CLSID',
      vClsid) then
      DoRegDefault('CLSID\' + vClsid + '\PersistentHandler', vHandler);
  if vHandler <> '' then
    DoRegDefault('CLSID\' + vHandler + '\PersistentAddinsRegistered\' +
      CS_IID_IFILTER, Result);
end;

function DoFilterClsid(const Ext: string): string;
var
  vExt: string;
begin
  vExt := LowerCase(Ext);
  if (vExt <> '') and (vExt[1] = '.') then
    Delete(vExt, 1, 1);
  if vExt = '' then
    Exit('');
  GLock.Enter;
  try
    if GFilterCache.TryGetValue(vExt, Result) then
      Exit;
  finally
    GLock.Leave;
  end;
  try
    Result := DoFindFilter(vExt);
  except
    Result := '';
  end;
  GLock.Enter;
  try
    GFilterCache.AddOrSetValue(vExt, Result);
  finally
    GLock.Leave;
  end;
end;

function sgcFSearchIFilterAvailable(const Ext: string): Boolean;
begin
  Result := DoFilterClsid(Ext) <> '';
end;

function DoLoadQuery: Boolean;
begin
  GLock.Enter;
  try
    if not GQueryTried then
    begin
      GQueryTried := True;
      GQueryLib := SafeLoadLibrary('query.dll');
      if GQueryLib <> 0 then
        @GLoadIFilter := GetProcAddress(GQueryLib, 'LoadIFilter');
    end;
    Result := Assigned(GLoadIFilter);
  finally
    GLock.Leave;
  end;
end;

// Filter of a file: LoadIFilter (IPersistFile), else the registered CLSID
// loaded through IPersistStream / IPersistFile (the Windows PDF filter only
// implements IPersistStream). Stream must live as long as Filter.
function DoOpenFilter(const FileName: string; out Filter: IsgcFSearchFilter;
  out Stream: IStream): Boolean;
var
  vUnk: IUnknown;
  vClsid: string;
  vPersistStream: IPersistStream;
  vPersistFile: IPersistFile;
  vHR: HRESULT;
begin
  Filter := nil;
  Stream := nil;
  if DoLoadQuery and Succeeded(GLoadIFilter(PChar(DoLongPath(FileName)), nil,
    vUnk)) and (vUnk <> nil) and Supports(vUnk, IsgcFSearchFilter, Filter) then
    Exit(True);
  Filter := nil;
  vClsid := DoFilterClsid(sgcFSearchFileExt(FileName));
  if (vClsid = '') or Failed(CoCreateInstance(StringToGUID(vClsid), nil,
    CLSCTX_INPROC_SERVER, IsgcFSearchFilter, Filter)) then
  begin
    Filter := nil;
    Exit(False);
  end;
  vHR := E_NOINTERFACE;
  if Supports(Filter, IPersistStream, vPersistStream) then
  begin
    Stream := TStreamAdapter.Create(TFileStream.Create(DoLongPath(FileName),
      fmOpenRead or fmShareDenyNone), soOwned);
    vHR := vPersistStream.Load(Stream);
  end
  else if Supports(Filter, IPersistFile, vPersistFile) then
    vHR := vPersistFile.Load(PChar(DoLongPath(FileName)),
      STGM_READ or STGM_SHARE_DENY_NONE);
  Result := Succeeded(vHR);
  if not Result then
  begin
    Filter := nil;
    Stream := nil;
  end;
end;

function DoExtractIFilter(const FileName: string; MaxBytes: Int64;
  out Text: string): TsgcFSearchExtractResult;
var
  vInit, vHR: HRESULT;
  vFilter: IsgcFSearchFilter;
  vStream: IStream;
  vFlags, vLen: ULONG;
  vStat: TsgcFSearchStatChunk;
  vBuffer: array [0 .. 4095] of WideChar;
  vSB: TStringBuilder;
  vStart: UInt64;
  vMaxChars: Int64;
  vChunk: string;
begin
  Result := fserError;
  Text := '';
  vMaxChars := MaxBytes;
  if vMaxChars <= 0 then
    vMaxChars := 64 * 1024 * 1024;
  vInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    if not DoOpenFilter(FileName, vFilter, vStream) then
      Exit;
    vFlags := 0;
    if Failed(vFilter.Init(IFILTER_INIT_CANON_PARAGRAPHS or
      IFILTER_INIT_HARD_LINE_BREAKS or IFILTER_INIT_CANON_HYPHENS or
      IFILTER_INIT_CANON_SPACES, 0, nil, vFlags)) then
      Exit;
    vSB := TStringBuilder.Create;
    try
      vStart := GetTickCount64;
      while (vSB.Length < vMaxChars) and
        (GetTickCount64 - vStart < SGCFS_IFILTER_TIMEOUT_MS) do
      begin
        FillChar(vStat, SizeOf(vStat), 0);
        vHR := vFilter.GetChunk(vStat);
        if (vHR = FILTER_E_EMBEDDING_UNAVAILABLE) or
          (vHR = FILTER_E_LINK_UNAVAILABLE) then
          Continue;
        if Failed(vHR) then
          Break; // FILTER_E_END_OF_CHUNKS or a filter error
        if (vStat.flags and CHUNK_TEXT) = 0 then
          Continue;
        if vSB.Length > 0 then
          case vStat.breakType of
            CHUNK_NO_BREAK:
              ;
            CHUNK_EOW:
              vSB.Append(' ');
          else
            vSB.Append(#10);
          end;
        repeat
          vLen := Length(vBuffer) - 1;
          vHR := vFilter.GetText(vLen, @vBuffer[0]);
          if Succeeded(vHR) and (vLen > 0) then
          begin
            if vLen > ULONG(Length(vBuffer)) then
              vLen := Length(vBuffer);
            SetString(vChunk, PChar(@vBuffer[0]), vLen);
            vSB.Append(vChunk);
          end;
        until Failed(vHR) or (vHR = FILTER_S_LAST_TEXT) or
          (vSB.Length >= vMaxChars);
      end;
      Text := vSB.ToString;
      Result := fserOK;
    finally
      vSB.Free;
    end;
  finally
    vFilter := nil;
    vStream := nil;
    if (vInit = S_OK) or (vInit = S_FALSE) then
      CoUninitialize;
  end;
end;

// ---------------------------------------------------------------- entry

function sgcFSearchExtractText(const FileName: string; MaxBytes: Int64;
  out Text: string): TsgcFSearchExtractResult;
var
  vAttributes: Cardinal;
  vSize, vMTime: Int64;
  vKind: TsgcFSearchFileKind;
begin
  Text := '';
  try
    if not sgcFSearchGetFileInfo(FileName, vAttributes, vSize, vMTime) then
      Exit(fserError);
    if (vAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      Exit(fserUnsupported);
    if sgcFSearchIsOfflineAttributes(vAttributes) then
      Exit(fserOffline);
    if (MaxBytes > 0) and (vSize > MaxBytes) then
      Exit(fserTooBig);
    vKind := sgcFSearchFileKind(FileName);
    case vKind of
      fsfkBinary:
        Result := fserBinary;
      fsfkWord, fsfkExcel, fsfkPowerPoint, fsfkOpenDocument:
        Result := DoExtractZip(FileName, vKind, Text);
      fsfkIFilter:
        if sgcFSearchIFilterAvailable(sgcFSearchFileExt(FileName)) then
          Result := DoExtractIFilter(FileName, MaxBytes, Text)
        else
          Result := fserUnsupported;
    else
      Result := DoExtractPlain(FileName, vKind, MaxBytes, Text);
    end;
  except
    Text := '';
    Result := fserError;
  end;
end;

initialization

GLock := TCriticalSection.Create;
GFilterCache := TDictionary<string, string>.Create;
GKinds := TDictionary<string, TsgcFSearchFileKind>.Create;
DoAddKinds(CS_TEXT_EXT, fsfkText);
DoAddKinds(CS_BINARY_EXT, fsfkBinary);
DoAddKinds(CS_WORD_EXT, fsfkWord);
DoAddKinds(CS_EXCEL_EXT, fsfkExcel);
DoAddKinds(CS_POWERPOINT_EXT, fsfkPowerPoint);
DoAddKinds(CS_ODF_EXT, fsfkOpenDocument);
DoAddKinds(CS_IFILTER_EXT, fsfkIFilter);

finalization

GKinds.Free;
GFilterCache.Free;
GLock.Free;
if GQueryLib <> 0 then
  FreeLibrary(GQueryLib);

end.
