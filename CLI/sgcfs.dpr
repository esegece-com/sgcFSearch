{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program sgcfs;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}
{ sgcfs: command line client of the sgcFSearch daemon (usage in CS_HELP).
  stdout carries only results, summaries and messages go to stderr.
  Exit code: 0 results / done, 1 no results, 2 error or daemon unavailable. }

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.JSON, System.DateUtils, System.Math, System.Diagnostics,
  System.Generics.Collections, System.Win.Registry,
  // sgc
  sgcFSearch_Pipe in '..\Source\sgcFSearch_Pipe.pas';

const
  CS_CONNECT_TIMEOUT = 5000;
  CS_DAEMON_TIMEOUT = 15000;
  CS_STOP_WAIT = 5000;
  CS_OUT_FLUSH = 32 * 1024;
  CS_LABEL = '%-17s%s';
  CS_CREDIT = 'made by esegece.com, https://www.esegece.com';

  CS_HELP = 'sgcfs - command line client of sgcFSearch' + sLineBreak +
    sLineBreak + 'Usage:' + sLineBreak +
    '  sgcfs <words...> [-n <limit>] [-l|--long] [--json]   search' + sLineBreak
    + '  sgcfs -- <words...>      search words that look like commands' +
    sLineBreak +
    '  sgcfs stdio              JSON lines bridge: stdin -> sgcFSearch -> stdout'
    + sLineBreak +
    '  sgcfs status             daemon state, index counters, roots, log file' +
    sLineBreak + '  sgcfs stop               stop the daemon' + sLineBreak +
    '  sgcfs show [text]        open the search bar (optional initial text)' +
    sLineBreak +
    '  sgcfs install [--login]  add this folder to the user PATH; --login also'
    + sLineBreak + '                           starts sgcFSearch at login' +
    sLineBreak +
    '  sgcfs uninstall          remove the login entry and the PATH entry' +
    sLineBreak +
    '  sgcfs bench [n]          time a fixed query set n times (default 20)' +
    sLineBreak + '  sgcfs help               this text' + sLineBreak +
    sLineBreak + 'Options:' + sLineBreak +
    '  -n <limit>   maximum results (default 100)' + sLineBreak +
    '  -l, --long   size, modified time (local) and path' + sLineBreak +
    '  --json       print the raw JSON response line' + sLineBreak + sLineBreak
    + 'Output: one path per line, folders end with \, content hits as' +
    sLineBreak +
    '  path:line: text. The "N results (x ms)" summary goes to stderr.' +
    sLineBreak + sLineBreak + 'Query syntax (all words must match the name):' +
    sLineBreak + '  word          fuzzy, case-insensitive name match' +
    sLineBreak + '  ''exact        whole name' + sLineBreak +
    '  ^prefix       name starts with' + sLineBreak +
    '  suffix$       name ends with' + sLineBreak +
    '  !word         exclude (combinable: !^tmp)' + sLineBreak +
    '  "a b"         group words with spaces' + sLineBreak +
    '  *.pas, a?c    wildcards: * any run, ? one char, on the whole name' +
    sLineBreak +
    '  src\main      path tokens: earlier parts match ancestor folders' +
    sLineBreak + '  ext:pas,dfm   extensions (files only)' + sLineBreak +
    '  type:code     documents images videos audio code archives apps fonts folders'
    + sLineBreak + '  kind:file     file | dir' + sLineBreak +
    '  in:<path>     below a folder (~ = home), repeatable' + sLineBreak +
    '  path:<text>   full path contains text' + sLineBreak +
    '  size:>10mb    < <= > >= a..b, units k m g t, size:empty' + sLineBreak +
    '  mtime:<7d     today yesterday week month year, <7d >30d, 2026-01-01..2026-02-01'
    + sLineBreak + '  re:<regex>    regular expression on the name' + sLineBreak
    + '  grep:<text>   file content contains text' + sLineBreak +
    '  regex:<re>    file content matches a regular expression' + sLineBreak +
    '  sym:<name>    symbol definitions in source files' + sLineBreak +
    '  limit:N       maximum results' + sLineBreak +
    '  sort:name|size|date|rank  (-asc / -desc suffix, leading - reverses)' +
    sLineBreak + sLineBreak +
    'Exit code: 0 results, 1 no results, 2 error or daemon unavailable.' +
    sLineBreak + sLineBreak + CS_CREDIT;

  CS_BENCH_NAME: array [0 .. 4] of string = ('one word', 'typo', 'two words',
    'filtered', 'content grep');
  CS_BENCH_REQ: array [0 .. 4] of string = ('{"q":"config","limit":100}',
    '{"q":"confgi","limit":100}', '{"q":"system config","limit":100}',
    '{"q":"config ext:json,xml","limit":100}',
    '{"grep":"TODO","mode":"literal","q":"ext:pas,txt,md","limit":100}');

var
  GOut, GErr, GIn: THandle;
  GOutConsole, GErrConsole, GInConsole: Boolean;
  GOldCP: UINT;
  GOutBuf: TStringBuilder;
  GFS: TFormatSettings;

  { console output }

procedure WriteHandle(H: THandle; IsConsole: Boolean; const S: string);
var
  vDone: DWORD;
  vBytes: TBytes;
  vPos, vChunk: Integer;
begin
  if (S = '') or (H = 0) or (H = INVALID_HANDLE_VALUE) then
    Exit;
  if IsConsole then
  begin
    vPos := 1;
    while vPos <= Length(S) do
    begin
      vChunk := Min(Length(S) - vPos + 1, 8192);
      // never split a surrogate pair
      if (vChunk > 1) and (vPos + vChunk - 1 < Length(S)) and
        (Ord(S[vPos + vChunk - 1]) >= $D800) and
        (Ord(S[vPos + vChunk - 1]) <= $DBFF) then
        Dec(vChunk);
      vDone := 0;
      if not WriteConsoleW(H, @S[vPos], DWORD(vChunk), vDone, nil) or (vDone = 0)
      then
        Break;
      Inc(vPos, Integer(vDone));
    end;
  end
  else
  begin
    vBytes := TEncoding.UTF8.GetBytes(S);
    vPos := 0;
    while vPos < Length(vBytes) do
    begin
      vDone := 0;
      if not WriteFile(H, vBytes[vPos], DWORD(Length(vBytes) - vPos), vDone,
        nil) or (vDone = 0) then
        Break;
      Inc(vPos, Integer(vDone));
    end;
  end;
end;

procedure FlushOut;
begin
  if GOutBuf.Length > 0 then
  begin
    WriteHandle(GOut, GOutConsole, GOutBuf.ToString);
    GOutBuf.Clear;
  end;
end;

procedure OutLn(const S: string);
begin
  GOutBuf.Append(S).Append(sLineBreak);
  if GOutBuf.Length >= CS_OUT_FLUSH then
    FlushOut;
end;

procedure ErrLn(const S: string);
begin
  FlushOut;
  WriteHandle(GErr, GErrConsole, S + sLineBreak);
end;

procedure InitConsole;
var
  vMode: DWORD;
begin
  GOut := GetStdHandle(STD_OUTPUT_HANDLE);
  GErr := GetStdHandle(STD_ERROR_HANDLE);
  GIn := GetStdHandle(STD_INPUT_HANDLE);
  GOutConsole := GetConsoleMode(GOut, vMode);
  GErrConsole := GetConsoleMode(GErr, vMode);
  GInConsole := GetConsoleMode(GIn, vMode);
  GOldCP := GetConsoleOutputCP;
  if GOldCP <> 0 then
    SetConsoleOutputCP(CP_UTF8);
end;

{ JSON helpers }

function ParseObject(const S: string): TJSONObject;
var
  vValue: TJSONValue;
begin
  vValue := TJSONObject.ParseJSONValue(S);
  if vValue is TJSONObject then
    Result := TJSONObject(vValue)
  else
  begin
    vValue.Free;
    Result := nil;
  end;
end;

function JValue(Obj: TJSONObject; const Name: string): TJSONValue;
begin
  if Obj = nil then
    Result := nil
  else
    Result := Obj.GetValue(Name);
end;

function JStr(Obj: TJSONObject; const Name: string;
  const Default: string = ''): string;
var
  vValue: TJSONValue;
begin
  vValue := JValue(Obj, Name);
  if vValue is TJSONString then // TJSONNumber included (its text)
    Result := TJSONString(vValue).Value
  else if (vValue = nil) or (vValue is TJSONNull) then
    Result := Default
  else
    Result := vValue.ToJSON;
end;

function JInt64(Obj: TJSONObject; const Name: string; Default: Int64): Int64;
var
  vValue: TJSONValue;
begin
  vValue := JValue(Obj, Name);
  if vValue is TJSONNumber then
    Result := StrToInt64Def(TJSONNumber(vValue).Value,
      Trunc(TJSONNumber(vValue).AsDouble))
  else
    Result := Default;
end;

function JFloat(Obj: TJSONObject; const Name: string): Double;
var
  vValue: TJSONValue;
begin
  vValue := JValue(Obj, Name);
  if vValue is TJSONNumber then
    Result := TJSONNumber(vValue).AsDouble
  else
    Result := 0;
end;

function JBool(Obj: TJSONObject; const Name: string): Boolean;
begin
  Result := JValue(Obj, Name) is TJSONTrue;
end;

// nil (after printing the error) when the response is invalid or not ok
function ParseResponse(const Resp: string): TJSONObject;
begin
  Result := ParseObject(Resp);
  if Result = nil then
    ErrLn('sgcfs: invalid response from sgcFSearch')
  else if not JBool(Result, 'ok') then
  begin
    ErrLn('sgcfs: ' + JStr(Result, 'error', 'request failed'));
    FreeAndNil(Result);
  end;
end;

function FormatMs(Ms: Double): string;
begin
  Result := FormatFloat('0.0#', Ms, GFS);
end;

function FormatCount(Value: Int64): string;
begin
  Result := FormatFloat('#,##0', Value, GFS);
end;

{ daemon }

function EnsureDaemon: Boolean;
var
  vExe: string;
begin
  if sgcFSearchIsServerRunning then
    Exit(True);
  vExe := ExtractFilePath(ParamStr(0)) + SGCFS_APP_EXE;
  if not FileExists(vExe) then
  begin
    ErrLn('sgcfs: sgcFSearch is not running and ' + vExe +
      ' was not found, cannot start it');
    Exit(False);
  end;
  ErrLn('sgcfs: starting sgcFSearch...');
  Result := sgcFSearchStartDaemon(vExe, CS_DAEMON_TIMEOUT);
  if not Result then
    ErrLn(Format('sgcfs: sgcFSearch did not answer within %d s',
      [CS_DAEMON_TIMEOUT div 1000]));
end;

function SendRequest(const Line: string; out Resp: string): Boolean;
begin
  Result := sgcFSearchPipeRequest(Line, CS_CONNECT_TIMEOUT, Resp);
  if not Result then
    ErrLn('sgcfs: cannot reach sgcFSearch (' +
      SysErrorMessage(GetLastError) + ')');
end;

{ query }

function MTimeText(const ISO: string): string;
begin
  Result := '';
  if ISO = '' then
    Exit;
  try
    Result := FormatDateTime('yyyy-mm-dd hh:nn', ISO8601ToDate(ISO, False));
  except
    Result := ISO;
  end;
end;

function FormatResult(Item: TJSONObject; Long: Boolean): string;
var
  vPath, vSize: string;
  vDir: Boolean;
begin
  vPath := JStr(Item, 'path');
  vDir := JBool(Item, 'dir');
  if vDir and (vPath <> '') and (vPath[Length(vPath)] <> '\') then
    vPath := vPath + '\';
  if JValue(Item, 'line') <> nil then
    vPath := vPath + ':' + JStr(Item, 'line') + ': ' + JStr(Item, 'text');
  if Long then
  begin
    if JValue(Item, 'size') <> nil then
      vSize := JStr(Item, 'size')
    else if vDir then
      vSize := '<DIR>'
    else
      vSize := '';
    Result := Format('%14s  %-16s  %s',
      [vSize, MTimeText(JStr(Item, 'mtime')), vPath]);
  end
  else
    Result := vPath;
end;

{ query text from the word arguments: a single argument is the query text as
  typed (the shell delivered one quoted string), with several, an argument
  holding a space is quoted so it stays one phrase }
function JoinQueryArgs(const Args: TArray<string>): string;
var
  i: Integer;
  vArg: string;
begin
  if Length(Args) = 1 then
    Exit(Args[0]);
  Result := '';
  for i := 0 to High(Args) do
  begin
    vArg := Args[i];
    if Pos(' ', vArg) > 0 then
      vArg := '"' + vArg + '"';
    if Result = '' then
      Result := vArg
    else
      Result := Result + ' ' + vArg;
  end;
end;

function CmdQuery(First: Integer): Integer;
var
  i, vLimit, vCount: Integer;
  vArg, vQuery, vResp: string;
  vLong, vJson, vWords: Boolean;
  vReq, vObj, vItem: TJSONObject;
  vResults: TJSONArray;
  vTotal: Int64;
  vWordArgs: TArray<string>;
begin
  vLimit := 0;
  vLong := False;
  vJson := False;
  vWords := False;
  i := First;
  while i <= ParamCount do
  begin
    vArg := ParamStr(i);
    Inc(i);
    if not vWords then
    begin
      if vArg = '--' then
      begin
        vWords := True;
        Continue;
      end
      else if vArg = '-n' then
      begin
        if i <= ParamCount then
          vLimit := StrToIntDef(ParamStr(i), 0);
        Inc(i);
        if vLimit <= 0 then
        begin
          ErrLn('sgcfs: -n needs a positive number');
          Exit(2);
        end;
        Continue;
      end
      else if (vArg = '-l') or (vArg = '--long') then
      begin
        vLong := True;
        Continue;
      end
      else if vArg = '--json' then
      begin
        vJson := True;
        Continue;
      end;
    end;
    vWordArgs := vWordArgs + [vArg];
  end;
  vQuery := JoinQueryArgs(vWordArgs);
  if Trim(vQuery) = '' then
  begin
    ErrLn('sgcfs: empty query (sgcfs help for the usage)');
    Exit(2);
  end;
  vReq := TJSONObject.Create;
  try
    vReq.AddPair('q', vQuery);
    if vLimit > 0 then
      vReq.AddPair('limit', TJSONNumber.Create(vLimit));
    vQuery := vReq.ToJSON;
  finally
    vReq.Free;
  end;
  if not EnsureDaemon then
    Exit(2);
  if not SendRequest(vQuery, vResp) then
    Exit(2);
  if vJson then
    OutLn(vResp);
  vObj := ParseResponse(vResp);
  if vObj = nil then
    Exit(2);
  try
    vCount := 0;
    if JValue(vObj, 'results') is TJSONArray then
    begin
      vResults := TJSONArray(JValue(vObj, 'results'));
      vCount := vResults.Count;
      if not vJson then
        for i := 0 to vResults.Count - 1 do
          if vResults.Items[i] is TJSONObject then
          begin
            vItem := TJSONObject(vResults.Items[i]);
            OutLn(FormatResult(vItem, vLong));
          end;
    end;
    vTotal := JInt64(vObj, 'total', vCount);
    if vTotal = 1 then
      ErrLn(Format('1 result (%s ms)', [FormatMs(JFloat(vObj, 'ms'))]))
    else if vTotal > vCount then
      ErrLn(Format('%d results, %d shown (%s ms)', [vTotal, vCount,
        FormatMs(JFloat(vObj, 'ms'))]))
    else
      ErrLn(Format('%d results (%s ms)',
        [vTotal, FormatMs(JFloat(vObj, 'ms'))]));
    if vCount > 0 then
      Result := 0
    else
      Result := 1;
  finally
    vObj.Free;
  end;
end;

{ stdio }

function ReadStdin(var Buf: TBytes; var Len: Integer): Boolean;
var
  vRead: DWORD;
  vChars: array [0 .. 4095] of WideChar;
  vText: string;
  vBytes: TBytes;
begin
  if GInConsole then
  begin
    vRead := 0;
    if not ReadConsoleW(GIn, @vChars[0], Length(vChars), vRead, nil) or
      (vRead = 0) or (vChars[0] = #26) then // Ctrl+Z = end of input
      Exit(False);
    SetString(vText, PWideChar(@vChars[0]), vRead);
    vBytes := TEncoding.UTF8.GetBytes(vText);
    if Length(Buf) < Len + Length(vBytes) then
      SetLength(Buf, Max(Length(Buf) * 2, Len + Length(vBytes)));
    if Length(vBytes) > 0 then
      Move(vBytes[0], Buf[Len], Length(vBytes));
    Inc(Len, Length(vBytes));
    Result := True;
  end
  else
  begin
    if Length(Buf) - Len < 65536 then
      SetLength(Buf, Max(Length(Buf) * 2, Len + 65536));
    vRead := 0;
    Result := ReadFile(GIn, Buf[Len], DWORD(Length(Buf) - Len), vRead, nil) and
      (vRead > 0);
    if Result then
      Inc(Len, Integer(vRead));
  end;
end;

function CmdStdio: Integer;
var
  vClient: TsgcFSearchPipeClient;
  vBuf: TBytes;
  vLen, vStart, p, vEnd: Integer;
  vEof: Boolean;
  vLine, vResp: string;
begin
  if not EnsureDaemon then
    Exit(2);
  vClient := TsgcFSearchPipeClient.Create;
  try
    if not vClient.Connect(CS_CONNECT_TIMEOUT) then
    begin
      ErrLn('sgcfs: cannot connect to sgcFSearch (' +
        SysErrorMessage(vClient.LastError) + ')');
      Exit(2);
    end;
    SetLength(vBuf, 65536);
    vLen := 0;
    vStart := 0;
    vEof := False;
    repeat
      // next line: [vStart, p)
      p := vStart;
      while (p < vLen) and (vBuf[p] <> 10) do
        Inc(p);
      if p >= vLen then
      begin
        if not vEof then
        begin
          if vStart > 0 then
          begin
            if vLen > vStart then
              Move(vBuf[vStart], vBuf[0], vLen - vStart);
            Dec(vLen, vStart);
            vStart := 0;
          end;
          if not ReadStdin(vBuf, vLen) then
            vEof := True;
          Continue;
        end;
        if vStart >= vLen then
          Break; // input consumed
        p := vLen; // last line without \n
      end;
      vEnd := p;
      if (vEnd > vStart) and (vBuf[vEnd - 1] = 13) then
        Dec(vEnd);
      if vEnd > vStart then
        vLine := TEncoding.UTF8.GetString(vBuf, vStart, vEnd - vStart)
      else
        vLine := '';
      vStart := p + 1;
      if Trim(vLine) = '' then
        Continue;
      vResp := vClient.Request(vLine);
      if vResp = '' then
      begin
        ErrLn('sgcfs: connection to sgcFSearch lost (' +
          SysErrorMessage(vClient.LastError) + ')');
        Exit(2);
      end;
      WriteHandle(GOut, GOutConsole, vResp + #10);
    until False;
    Result := 0;
  finally
    vClient.Free;
  end;
end;

{ status, stop, show }

function CmdStatus: Integer;
var
  vResp, vRoots: string;
  vObj: TJSONObject;
  vArr: TJSONArray;
  i: Integer;
begin
  if not sgcFSearchIsServerRunning then
  begin
    ErrLn('sgcfs: sgcFSearch is not running');
    Exit(2);
  end;
  if not SendRequest('{"status":true}', vResp) then
    Exit(2);
  vObj := ParseResponse(vResp);
  if vObj = nil then
    Exit(2);
  try
    OutLn(Format(CS_LABEL, ['state', JStr(vObj, 'state')]));
    if JValue(vObj, 'version') <> nil then
      OutLn(Format(CS_LABEL, ['version', JStr(vObj, 'version')]));
    if JValue(vObj, 'pid') <> nil then
      OutLn(Format(CS_LABEL, ['pid', JStr(vObj, 'pid')]));
    OutLn(Format(CS_LABEL, ['files', FormatCount(JInt64(vObj, 'files', 0))]));
    OutLn(Format(CS_LABEL, ['folders', FormatCount(JInt64(vObj,
      'folders', 0))]));
    if JValue(vObj, 'crawled') <> nil then
      OutLn(Format(CS_LABEL, ['crawled', FormatCount(JInt64(vObj,
        'crawled', 0))]));
    OutLn(Format(CS_LABEL, ['content pending',
      FormatCount(JInt64(vObj, 'content_pending', 0))]));
    OutLn(Format(CS_LABEL, ['content indexed',
      FormatCount(JInt64(vObj, 'content_indexed', 0))]));
    vRoots := '';
    if JValue(vObj, 'roots') is TJSONArray then
    begin
      vArr := TJSONArray(JValue(vObj, 'roots'));
      for i := 0 to vArr.Count - 1 do
      begin
        if vRoots <> '' then
          vRoots := vRoots + ', ';
        vRoots := vRoots + vArr.Items[i].Value;
      end;
    end;
    OutLn(Format(CS_LABEL, ['roots', vRoots]));
    OutLn(Format(CS_LABEL, ['log', JStr(vObj, 'log')]));
    Result := 0;
  finally
    vObj.Free;
  end;
end;

function CmdStop: Integer;
var
  vResp: string;
  vObj: TJSONObject;
  vDeadline: UInt64;
begin
  if not sgcFSearchIsServerRunning then
  begin
    ErrLn('sgcfs: sgcFSearch is not running');
    Exit(2);
  end;
  if not SendRequest('{"stop":true}', vResp) then
    Exit(2);
  vObj := ParseResponse(vResp);
  if vObj = nil then
    Exit(2);
  vObj.Free;
  vDeadline := GetTickCount64 + CS_STOP_WAIT;
  while sgcFSearchIsServerRunning and (GetTickCount64 < vDeadline) do
    Sleep(100);
  if sgcFSearchIsServerRunning then
    OutLn('sgcFSearch is stopping (saving the index)')
  else
    OutLn('sgcFSearch stopped');
  Result := 0;
end;

function CmdShow: Integer;
var
  i: Integer;
  vText, vResp: string;
  vReq, vObj: TJSONObject;
  vWordArgs: TArray<string>;
begin
  for i := 2 to ParamCount do
    vWordArgs := vWordArgs + [ParamStr(i)];
  vText := JoinQueryArgs(vWordArgs);
  vReq := TJSONObject.Create;
  try
    vReq.AddPair('show', TJSONTrue.Create);
    if vText <> '' then
      vReq.AddPair('q', vText);
    vText := vReq.ToJSON;
  finally
    vReq.Free;
  end;
  if not EnsureDaemon then
    Exit(2);
  if not SendRequest(vText, vResp) then
    Exit(2);
  vObj := ParseResponse(vResp);
  if vObj = nil then
    Exit(2);
  vObj.Free;
  Result := 0;
end;

{ install, uninstall }

procedure BroadcastEnvironment;
var
  vResult: DWORD_PTR;
begin
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
    LPARAM(PChar('Environment')), SMTO_ABORTIFHUNG, 5000, @vResult);
end;

// adds (Add) or removes the folder from HKCU\Environment\Path; True changed
function UpdateUserPath(const Dir: string; Add: Boolean): Boolean;
var
  vReg: TRegistry;
  vPath, vNew: string;
begin
  Result := False;
  vReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    vReg.RootKey := HKEY_CURRENT_USER;
    if not vReg.OpenKey(SGCFS_REG_ENV_KEY, Add) then
      Exit;
    if vReg.ValueExists(SGCFS_REG_ENV_PATH) then
      vPath := vReg.ReadString(SGCFS_REG_ENV_PATH)
    else
      vPath := '';
    if Add then
      Result := sgcFSearchPathListAdd(vPath, Dir, vNew)
    else
      Result := sgcFSearchPathListRemove(vPath, Dir, vNew);
    if Result then
      vReg.WriteExpandString(SGCFS_REG_ENV_PATH, vNew);
  finally
    vReg.Free;
  end;
end;

function CmdInstall: Integer;
var
  vDir, vApp: string;
  vLogin: Boolean;
begin
  vLogin := (ParamCount >= 2) and SameText(ParamStr(2), '--login');
  vDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  if UpdateUserPath(vDir, True) then
  begin
    BroadcastEnvironment;
    OutLn('added ' + vDir +
      ' to the user PATH (open a new terminal to use it)');
  end
  else
    OutLn(vDir + ' is already in the user PATH');
  Result := 0;
  if vLogin then
  begin
    vApp := IncludeTrailingPathDelimiter(vDir) + SGCFS_APP_EXE;
    if not FileExists(vApp) then
      ErrLn('sgcfs: warning, ' + vApp + ' does not exist');
    if sgcFSearchSetStartAtLogin(True, vApp) then
      OutLn('sgcFSearch will start at login')
    else
    begin
      ErrLn('sgcfs: cannot write the login entry');
      Result := 2;
    end;
  end;
end;

function CmdUninstall: Integer;
var
  vDir: string;
begin
  Result := 0;
  if sgcFSearchSetStartAtLogin(False, '') then
    OutLn('login entry removed')
  else
  begin
    ErrLn('sgcfs: cannot remove the login entry');
    Result := 2;
  end;
  vDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  if UpdateUserPath(vDir, False) then
  begin
    BroadcastEnvironment;
    OutLn('removed ' + vDir + ' from the user PATH');
  end
  else
    OutLn(vDir + ' was not in the user PATH');
end;

{ bench }

function MedianOf(const Values: TArray<Double>): Double;
var
  vCopy: TArray<Double>;
  n: Integer;
begin
  vCopy := Copy(Values);
  n := Length(vCopy);
  if n = 0 then
    Exit(0);
  TArray.Sort<Double>(vCopy);
  if Odd(n) then
    Result := vCopy[n div 2]
  else
    Result := (vCopy[n div 2 - 1] + vCopy[n div 2]) / 2;
end;

function CmdBench: Integer;
var
  vRuns, q, r: Integer;
  vClient: TsgcFSearchPipeClient;
  vServer, vRtt: TArray<Double>;
  vSW: TStopwatch;
  vResp: string;
  vObj: TJSONObject;
  vTotal: Int64;
begin
  vRuns := 20;
  if ParamCount >= 2 then
    vRuns := StrToIntDef(ParamStr(2), 0);
  if vRuns <= 0 then
  begin
    ErrLn('sgcfs: bench needs a positive run count');
    Exit(2);
  end;
  if not EnsureDaemon then
    Exit(2);
  vClient := TsgcFSearchPipeClient.Create;
  try
    if not vClient.Connect(CS_CONNECT_TIMEOUT) then
    begin
      ErrLn('sgcfs: cannot connect to sgcFSearch (' +
        SysErrorMessage(vClient.LastError) + ')');
      Exit(2);
    end;
    OutLn(Format('%-14s %10s %12s %10s', ['query', 'server ms', 'round trip',
      'results']));
    for q := 0 to High(CS_BENCH_REQ) do
    begin
      SetLength(vServer, vRuns);
      SetLength(vRtt, vRuns);
      vTotal := 0;
      for r := 0 to vRuns - 1 do
      begin
        vSW := TStopwatch.StartNew;
        vResp := vClient.Request(CS_BENCH_REQ[q]);
        vSW.Stop;
        if vResp = '' then
        begin
          ErrLn('sgcfs: connection to sgcFSearch lost');
          Exit(2);
        end;
        vRtt[r] := vSW.Elapsed.TotalMilliseconds;
        vObj := ParseResponse(vResp);
        if vObj = nil then
          Exit(2);
        try
          vServer[r] := JFloat(vObj, 'ms');
          vTotal := JInt64(vObj, 'total', 0);
        finally
          vObj.Free;
        end;
      end;
      OutLn(Format('%-14s %10s %12s %10d', [CS_BENCH_NAME[q],
        FormatFloat('0.00', MedianOf(vServer), GFS), FormatFloat('0.00',
        MedianOf(vRtt), GFS), vTotal]));
      FlushOut;
    end;
    OutLn(Format('median of %d runs per query, one connection', [vRuns]));
    Result := 0;
  finally
    vClient.Free;
  end;
end;

{ main }

function Main: Integer;
var
  vCmd: string;
begin
  if ParamCount = 0 then
  begin
    OutLn(CS_HELP);
    Exit(0);
  end;
  vCmd := LowerCase(ParamStr(1));
  if (vCmd = 'help') or (vCmd = '-h') or (vCmd = '--help') or (vCmd = '/?') then
  begin
    OutLn(CS_HELP);
    Result := 0;
  end
  else if vCmd = 'stdio' then
    Result := CmdStdio
  else if vCmd = 'status' then
    Result := CmdStatus
  else if vCmd = 'stop' then
    Result := CmdStop
  else if vCmd = 'show' then
    Result := CmdShow
  else if vCmd = 'install' then
    Result := CmdInstall
  else if vCmd = 'uninstall' then
    Result := CmdUninstall
  else if vCmd = 'bench' then
    Result := CmdBench
  else
    Result := CmdQuery(1);
end;

begin
  GFS := TFormatSettings.Invariant;
  GOutBuf := TStringBuilder.Create;
  try
    InitConsole;
    try
      ExitCode := Main;
    except
      on E: Exception do
      begin
        ErrLn('sgcfs: ' + E.Message);
        ExitCode := 2;
      end;
    end;
    FlushOut;
  finally
    if GOldCP <> 0 then
      SetConsoleOutputCP(GOldCP);
    GOutBuf.Free;
  end;

end.
