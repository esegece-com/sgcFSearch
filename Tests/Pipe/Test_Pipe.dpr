{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Pipe;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON,
  System.SyncObjs, System.Diagnostics, System.IOUtils,
  // sgc
  sgcFSearch_Log in '..\..\Source\sgcFSearch_Log.pas',
  sgcFSearch_Pipe in '..\..\Source\sgcFSearch_Pipe.pas';

const
  CS_SE_KERNEL_OBJECT = 6;
  CS_DACL_SECURITY_INFORMATION = 4;
  CS_ACL_SIZE_INFORMATION = 2;
  CS_SE_DACL_PROTECTED = $1000;
  CS_BIG = 5 * 1024 * 1024;

  CS_STATUS = '"ok":true,"state":"ready","files":5080000,"folders":610000,' +
    '"crawled":5690000,"content_pending":42,"content_indexed":36000,' +
    '"pid":1234,"version":"1.0.0","roots":["C:\\","D:\\"],' +
    '"log":"C:\\Users\\test\\daemon.log"}';
  CS_RESULTS = '"ok":true,"total":3,"ms":0.8,"content":false,"results":[' +
    '{"path":"C:\\Docs\\report.pdf","name":"report.pdf","dir":false,' +
    '"size":12345,"mtime":"2026-11-03T10:15:00Z","score":512.0,"match":[0,6]},'
    + '{"path":"C:\\Docs\\Reports","name":"Reports","dir":true,' +
    '"mtime":"2026-11-02T08:00:00Z","score":400.0},' +
    '{"path":"C:\\Docs\\caf\u00e9.txt","name":"caf\u00e9.txt","dir":false,' +
    '"size":5,"mtime":"2026-11-01T00:00:00Z","score":100.0}]}';
  CS_CONTENT = '"ok":true,"total":1,"ms":1.5,"content":true,"results":[' +
    '{"path":"C:\\Src\\main.pas","name":"main.pas","dir":false,"size":100,' +
    '"mtime":"2026-11-03T10:15:00Z","line":12,"text":"// TODO fix",' +
    '"tmatch":[3,4]}]}';
  CS_EMPTY = '"ok":true,"total":0,"ms":0.1,"content":false,"results":[]}';

type
  TAclSizeInfo = record
    AceCount, AclBytesInUse, AclBytesFree: DWORD;
  end;

function ApiGetSecurityInfo(Handle: THandle; ObjectType, SecurityInfo: DWORD;
  ppsidOwner, ppsidGroup, ppDacl, ppSacl: PPointer; var ppSD: Pointer): DWORD;
  stdcall; external advapi32 name 'GetSecurityInfo';
function ApiGetAclInformation(pAcl: Pointer; pInfo: Pointer; InfoLen: DWORD;
  InfoClass: DWORD): BOOL; stdcall; external advapi32 name 'GetAclInformation';
function ApiGetAce(pAcl: Pointer; Index: DWORD; var pAce: Pointer): BOOL;
  stdcall; external advapi32 name 'GetAce';
function ApiConvertSidToStringSid(Sid: Pointer; var StringSid: PWideChar): BOOL;
  stdcall; external advapi32 name 'ConvertSidToStringSidW';
function ApiGetSDControl(pSD: Pointer; var Control: Word; var Revision: DWORD)
  : BOOL; stdcall; external advapi32 name 'GetSecurityDescriptorControl';

var
  GChecks, GFails: Integer;
  GBase, GCli, GPipeEnv: string;
  GConcErrors: Integer;
  GLastQ: string; // "q" of the last request the fake server received
  GLastQLock: TCriticalSection;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(GChecks);
  if not Cond then
  begin
    Inc(GFails);
    Writeln('[FAIL] ', Msg);
  end;
end;

procedure Info(const Msg: string);
begin
  Writeln('[INFO] ', Msg);
end;

{ fake request handler }

function FakeHandler(const Line: string): string;
var
  vValue, vId: TJSONValue;
  vObj: TJSONObject;
  vIdText, vQ: string;
begin
  Result := '';
  vValue := TJSONObject.ParseJSONValue(Line);
  try
    if not(vValue is TJSONObject) then
      Exit;
    vObj := TJSONObject(vValue);
    if vObj.GetValue('q') <> nil then
    begin
      GLastQLock.Enter;
      try
        GLastQ := vObj.GetValue('q').Value;
      finally
        GLastQLock.Leave;
      end;
    end;
    vIdText := '';
    vId := vObj.GetValue('id');
    if vId <> nil then
      vIdText := '"id":' + vId.ToJSON + ',';
    if vObj.GetValue('echo') <> nil then
      Result := '{' + vIdText + '"ok":true,"echo":' + vObj.GetValue('echo')
        .ToJSON + '}'
    else if vObj.GetValue('sleep') <> nil then
    begin
      Sleep(TJSONNumber(vObj.GetValue('sleep')).AsInt);
      Result := '{' + vIdText + '"ok":true}';
    end
    else if vObj.GetValue('big') <> nil then
      Result := '{' + vIdText + '"ok":true,"data":"' +
        StringOfChar('x', TJSONNumber(vObj.GetValue('big')).AsInt) + '"}'
    else if vObj.GetValue('raise') <> nil then
      raise Exception.Create('fake handler failure')
    else if vObj.GetValue('status') <> nil then
      Result := '{' + vIdText + CS_STATUS
    else if vObj.GetValue('show') <> nil then
      Result := '{' + vIdText + '"ok":true}'
    else if vObj.GetValue('q') <> nil then
    begin
      vQ := vObj.GetValue('q').Value;
      if vQ = 'nothing' then
        Result := '{' + vIdText + CS_EMPTY
      else if Pos('grep:', vQ) > 0 then
        Result := '{' + vIdText + CS_CONTENT
      else
        Result := '{' + vIdText + CS_RESULTS;
    end;
    // "empty" and anything else: '' -> unknown request
  finally
    vValue.Free;
  end;
end;

{ helpers }

function NewServer: TsgcFSearchPipeServer;
begin
  Result := TsgcFSearchPipeServer.Create(FakeHandler);
end;

function WaitClientCount(Server: TsgcFSearchPipeServer;
  Count, TimeoutMs: Integer): Boolean;
var
  vSW: TStopwatch;
begin
  vSW := TStopwatch.StartNew;
  repeat
    if Server.ClientCount = Count then
      Exit(True);
    Sleep(10);
  until vSW.ElapsedMilliseconds > TimeoutMs;
  Result := Server.ClientCount = Count;
end;

function RawWrite(Client: TsgcFSearchPipeClient; const S: string): Boolean;
var
  vBytes: TBytes;
  vDone: DWORD;
begin
  vBytes := TEncoding.UTF8.GetBytes(S);
  Result := WriteFile(Client.Handle, vBytes[0], Length(vBytes), vDone, nil) and
    (Integer(vDone) = Length(vBytes));
end;

function ReadFileText(const FileName: string): string;
begin
  if FileExists(FileName) then
    Result := TEncoding.UTF8.GetString(TFile.ReadAllBytes(FileName))
  else
    Result := '';
end;

// runs the CLI copy with stdin/stdout/stderr redirected to files
function RunCli(const Args, StdinText: string;
  out OutText, ErrText: string): Integer;
var
  vSA: TSecurityAttributes;
  vSI: TStartupInfo;
  vPI: TProcessInformation;
  hIn, hOut, hErr: THandle;
  vCmd, vIn, vOut, vErr: string;
  vCode: DWORD;
begin
  Result := -1;
  OutText := '';
  ErrText := '';
  vIn := TPath.Combine(GBase, 'cli_in.txt');
  vOut := TPath.Combine(GBase, 'cli_out.txt');
  vErr := TPath.Combine(GBase, 'cli_err.txt');
  TFile.WriteAllBytes(vIn, TEncoding.UTF8.GetBytes(StdinText));
  vSA.nLength := SizeOf(vSA);
  vSA.lpSecurityDescriptor := nil;
  vSA.bInheritHandle := True;
  hIn := CreateFile(PChar(vIn), GENERIC_READ, FILE_SHARE_READ, @vSA,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  hOut := CreateFile(PChar(vOut), GENERIC_WRITE, FILE_SHARE_READ, @vSA,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  hErr := CreateFile(PChar(vErr), GENERIC_WRITE, FILE_SHARE_READ, @vSA,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  try
    FillChar(vSI, SizeOf(vSI), 0);
    vSI.cb := SizeOf(vSI);
    vSI.dwFlags := STARTF_USESTDHANDLES;
    vSI.hStdInput := hIn;
    vSI.hStdOutput := hOut;
    vSI.hStdError := hErr;
    vCmd := '"' + GCli + '" ' + Args;
    UniqueString(vCmd);
    if not CreateProcess(nil, PChar(vCmd), nil, nil, True, CREATE_NO_WINDOW,
      nil, PChar(GBase), vSI, vPI) then
      Exit;
  finally
    CloseHandle(hIn);
    CloseHandle(hOut);
    CloseHandle(hErr);
  end;
  try
    if WaitForSingleObject(vPI.hProcess, 30000) <> WAIT_OBJECT_0 then
    begin
      TerminateProcess(vPI.hProcess, 99);
      WaitForSingleObject(vPI.hProcess, 5000);
      Exit;
    end;
    GetExitCodeProcess(vPI.hProcess, vCode);
    Result := Integer(vCode);
  finally
    CloseHandle(vPI.hThread);
    CloseHandle(vPI.hProcess);
  end;
  OutText := ReadFileText(vOut);
  ErrText := ReadFileText(vErr);
end;

// runs the CLI and returns the "q" text the fake server received
function CliQ(const Args: string): string;
var
  vOut, vErr: string;
begin
  GLastQLock.Enter;
  try
    GLastQ := '';
  finally
    GLastQLock.Leave;
  end;
  RunCli(Args, '', vOut, vErr);
  GLastQLock.Enter;
  try
    Result := GLastQ;
  finally
    GLastQLock.Leave;
  end;
end;

{ tests }

procedure TestPure;
var
  vNew: string;
begin
  Check(sgcFSearchPathListAdd('C:\A;C:\B', 'C:\Tools', vNew) and
    (vNew = 'C:\A;C:\B;C:\Tools'), 'path add: ' + vNew);
  Check(sgcFSearchPathListAdd('', 'C:\Tools\', vNew) and (vNew = 'C:\Tools'),
    'path add to empty: ' + vNew);
  Check(sgcFSearchPathListAdd('C:\A;;', 'C:\Tools', vNew) and
    (vNew = 'C:\A;C:\Tools'), 'path add trailing ;: ' + vNew);
  Check(not sgcFSearchPathListAdd('C:\A;c:\tools\;C:\B', 'C:\Tools', vNew) and
    (vNew = 'C:\A;c:\tools\;C:\B'), 'path add duplicate (case, \)');
  Check(not sgcFSearchPathListAdd('"C:\Tools"', 'C:\Tools', vNew),
    'path add duplicate (quoted)');
  SetEnvironmentVariable('SGCFS_TEST_DIR', 'C:\Tools');
  Check(not sgcFSearchPathListAdd('C:\A;%SGCFS_TEST_DIR%', 'C:\Tools', vNew),
    'path add duplicate (%VAR%)');
  Check(sgcFSearchPathListRemove('C:\A;C:\Tools;C:\B;c:\tools\', 'C:\Tools',
    vNew) and (vNew = 'C:\A;C:\B'), 'path remove: ' + vNew);
  Check(not sgcFSearchPathListRemove('C:\A;C:\B', 'C:\Tools', vNew) and
    (vNew = 'C:\A;C:\B'), 'path remove absent');
  Check(sgcFSearchPathListRemove('%SGCFS_TEST_DIR%', 'C:\Tools', vNew) and
    (vNew = ''), 'path remove %VAR%');
  Check(sgcFSearchRunCommand('C:\x y\sgcFSearch.exe')
    = '"C:\x y\sgcFSearch.exe" --background', 'run command');
  Check(SGCFS_REG_RUN_KEY = 'Software\Microsoft\Windows\CurrentVersion\Run',
    'run key');
  Check(sgcFSearchErrorResponse('{"id":"a","x":1}', 'boom')
    = '{"id":"a","ok":false,"error":"boom"}', 'error response with id');
  Check(sgcFSearchErrorResponse('not json', 'x "q"')
    = '{"ok":false,"error":"x \"q\""}', 'error response, no id: ' +
    sgcFSearchErrorResponse('not json', 'x "q"'));
  // pipe name
  SetEnvironmentVariable(SGCFS_PIPE_ENV, nil);
  Check(Copy(sgcFSearchCurrentUserSid, 1, 4) = 'S-1-', 'user SID');
  Check(sgcFSearchPipeName = '\\.\pipe\sgcFSearch-' + sgcFSearchCurrentUserSid,
    'default pipe name ' + sgcFSearchPipeName);
  SetEnvironmentVariable(SGCFS_PIPE_ENV, 'abc');
  Check(sgcFSearchPipeName = '\\.\pipe\abc', 'bare override');
  SetEnvironmentVariable(SGCFS_PIPE_ENV, PChar(GPipeEnv));
  Check(sgcFSearchPipeName = '\\.\pipe\' + GPipeEnv, 'test pipe name');
end;

procedure TestNoServer;
var
  vC: TsgcFSearchPipeClient;
  vSW: TStopwatch;
  vResp: string;
begin
  Check(not sgcFSearchIsServerRunning, 'no server: not running');
  vC := TsgcFSearchPipeClient.Create;
  try
    vSW := TStopwatch.StartNew;
    Check(not vC.Connect(300), 'no server: connect fails');
    Check((vSW.ElapsedMilliseconds >= 250) and (vSW.ElapsedMilliseconds < 2000),
      Format('connect timeout %d ms', [vSW.ElapsedMilliseconds]));
    Check(vC.LastError = ERROR_FILE_NOT_FOUND, 'connect LastError ' +
      IntToStr(vC.LastError));
    vSW := TStopwatch.StartNew;
    Check(not vC.Connect(0), 'connect(0) fails');
    Check(vSW.ElapsedMilliseconds < 200, 'connect(0) immediate');
    Check(vC.Request('{"echo":1}') = '', 'request when not connected');
  finally
    vC.Free;
  end;
  Check(not sgcFSearchPipeRequest('{"status":true}', 100, vResp) and
    (vResp = ''), 'one-shot request without server');
  vSW := TStopwatch.StartNew;
  Check(not sgcFSearchStartDaemon(TPath.Combine(GBase, 'missing.exe'), 15000),
    'start daemon: missing exe');
  Check(vSW.ElapsedMilliseconds < 1000, 'start daemon fails fast');
end;

function MakeClientProc(Index: Integer): TProc;
begin
  Result := procedure
    var
      vC: TsgcFSearchPipeClient;
      k: Integer;
      vExp: string;
    begin
      vC := TsgcFSearchPipeClient.Create;
      try
        if not vC.Connect(5000) then
        begin
          TInterlocked.Add(GConcErrors, 100);
          Exit;
        end;
        for k := 1 to 100 do
        begin
          vExp := Format('t%d-%d', [Index, k]);
          if vC.Request(Format('{"id":%d,"echo":"%s"}', [k, vExp])) <>
            Format('{"id":%d,"ok":true,"echo":"%s"}', [k, vExp]) then
            TInterlocked.Increment(GConcErrors);
        end;
      finally
        vC.Free;
      end;
    end;
end;

procedure TestServer;
var
  vS, vS2: TsgcFSearchPipeServer;
  vC: TsgcFSearchPipeClient;
  vClients: array [0 .. 2] of TsgcFSearchPipeClient;
  vThreads: array [0 .. 7] of TThread;
  vBusy: TThread;
  vResp, vBig, vExp: string;
  vSW: TStopwatch;
  i, vOkCount: Integer;
  vSD, vDacl, vAce: Pointer;
  vAclInfo: TAclSizeInfo;
  vSidStr: PWideChar;
  vControl: Word;
  vRev: DWORD;
begin
  vS := NewServer;
  try
    Check(vS.Start, 'server start, error ' + IntToStr(vS.LastError));
    Check(vS.Active, 'server active');
    Check(vS.PipeName = '\\.\pipe\' + GPipeEnv, 'server pipe name');
    Check(sgcFSearchIsServerRunning, 'server running');
    Check(vS.ProcessLine('{"id":"x","empty":true}')
      = '{"id":"x","ok":false,"error":"unknown request"}', 'ProcessLine empty');

    // second server: first-instance flag
    vS2 := NewServer;
    try
      Check(not vS2.Start, 'second server must fail');
      Check(vS2.LastError = ERROR_ACCESS_DENIED, 'second server LastError ' +
        IntToStr(vS2.LastError));
      Check(not vS2.Active, 'second server not active');
    finally
      vS2.Free;
    end;

    vC := TsgcFSearchPipeClient.Create;
    try
      Check(vC.Connect(2000), 'client connect');
      Check(vC.Connected, 'client connected');
      Check(vC.Request('{"echo":"hello"}') = '{"ok":true,"echo":"hello"}',
        'round trip');
      Check(vC.Request('{"id":42,"echo":"x"}')
        = '{"id":42,"ok":true,"echo":"x"}', 'id echo number');
      Check(vC.Request('{"id":"abc","echo":"x"}')
        = '{"id":"abc","ok":true,"echo":"x"}', 'id echo string');
      Check(vC.Request('{"id":7,"empty":true}')
        = '{"id":7,"ok":false,"error":"unknown request"}', 'empty -> unknown');
      Check(vC.Request('{"foo":1}') = '{"ok":false,"error":"unknown request"}',
        'unknown op');
      Check(vC.Request('not json') = '{"ok":false,"error":"unknown request"}',
        'invalid json');
      vResp := vC.Request('{"id":5,"raise":true}');
      Check(vResp = '{"id":5,"ok":false,"error":"fake handler failure"}',
        'handler exception: ' + vResp);
      Check(vC.Request('{"echo":"after"}') = '{"ok":true,"echo":"after"}',
        'connection survives the exception');
      Check(vC.Request('{"echo":"crlf"}'#13#10) = '{"ok":true,"echo":"crlf"}',
        'CRLF request');
      Check(vC.Request('{"echo":"caf'#$00E9' '#$4E2D'"}')
        = '{"ok":true,"echo":"caf\u00E9 \u4E2D"}',
        'unicode echo: ' + vC.Request('{"echo":"caf'#$00E9' '#$4E2D'"}'));
      // partial writes, pipelined lines, blank lines
      Check(RawWrite(vC, '{"echo":'), 'raw write 1');
      Sleep(50);
      Check(RawWrite(vC, '"p1"}'#10#10#13#10'{"echo":"p2"}'#10), 'raw write 2');
      Check(vC.ReadLine = '{"ok":true,"echo":"p1"}', 'partial line p1');
      Check(vC.ReadLine = '{"ok":true,"echo":"p2"}', 'pipelined p2');
      // many sequential requests
      vOkCount := 0;
      vSW := TStopwatch.StartNew;
      for i := 1 to 1000 do
        if vC.Request(Format('{"id":%d,"echo":"s"}', [i]))
          = Format('{"id":%d,"ok":true,"echo":"s"}', [i]) then
          Inc(vOkCount);
      vSW.Stop;
      Check(vOkCount = 1000, Format('sequential %d/1000', [vOkCount]));
      Info(Format('1000 sequential requests: %d ms (%.1f us per round trip)',
        [vSW.ElapsedMilliseconds, vSW.Elapsed.TotalMilliseconds]));
      // big request (server partial reads) and big response
      vBig := StringOfChar('y', 1024 * 1024);
      vResp := vC.Request('{"echo":"' + vBig + '"}');
      Check(vResp = '{"ok":true,"echo":"' + vBig + '"}', '1 MB request');
      vSW := TStopwatch.StartNew;
      vResp := vC.Request(Format('{"big":%d}', [CS_BIG]));
      vSW.Stop;
      Check(Length(vResp) = CS_BIG + Length('{"ok":true,"data":""}'),
        '5 MB response length ' + IntToStr(Length(vResp)));
      Check(Copy(vResp, 1, 19) = '{"ok":true,"data":"', '5 MB response head');
      Info(Format('5 MB response: %d ms', [vSW.ElapsedMilliseconds]));
      Check(vC.Request('{"echo":"tail"}') = '{"ok":true,"echo":"tail"}',
        'request after the big response');

      // DACL: one ACE, current user, protected
      vSD := nil;
      vDacl := nil;
      Check(ApiGetSecurityInfo(vC.Handle, CS_SE_KERNEL_OBJECT,
        CS_DACL_SECURITY_INFORMATION, nil, nil, @vDacl, nil, vSD) = 0,
        'GetSecurityInfo');
      if vSD <> nil then
      begin
        FillChar(vAclInfo, SizeOf(vAclInfo), 0);
        Check((vDacl <> nil) and ApiGetAclInformation(vDacl, @vAclInfo,
          SizeOf(vAclInfo), CS_ACL_SIZE_INFORMATION), 'GetAclInformation');
        Check(vAclInfo.AceCount = 1, 'DACL ace count ' +
          IntToStr(vAclInfo.AceCount));
        vAce := nil;
        if (vDacl <> nil) and ApiGetAce(vDacl, 0, vAce) then
        begin
          Check(PByte(vAce)^ = 0, 'ace type allow');
          vSidStr := nil;
          Check(ApiConvertSidToStringSid(PByte(vAce) + 8, vSidStr) and
            (string(vSidStr) = sgcFSearchCurrentUserSid), 'ace SID = user');
          if vSidStr <> nil then
            LocalFree(HLOCAL(vSidStr));
        end
        else
          Check(False, 'GetAce');
        vControl := 0;
        Check(ApiGetSDControl(vSD, vControl, vRev) and
          (vControl and CS_SE_DACL_PROTECTED <> 0), 'DACL protected');
        LocalFree(HLOCAL(vSD));
      end;
      Check(WaitClientCount(vS, 1, 1000), 'client count 1');
    finally
      vC.Free;
    end;
    Check(WaitClientCount(vS, 0, 1000), 'client count 0 after close');

    // 8 concurrent clients x 100 requests
    GConcErrors := 0;
    vSW := TStopwatch.StartNew;
    for i := 0 to High(vThreads) do
    begin
      vThreads[i] := TThread.CreateAnonymousThread(MakeClientProc(i));
      vThreads[i].FreeOnTerminate := False;
      vThreads[i].Start;
    end;
    for i := 0 to High(vThreads) do
    begin
      vThreads[i].WaitFor;
      vThreads[i].Free;
    end;
    vSW.Stop;
    Check(GConcErrors = 0, Format('concurrent errors %d', [GConcErrors]));
    Info(Format('8 clients x 100 requests: %d ms', [vSW.ElapsedMilliseconds]));
    Check(WaitClientCount(vS, 0, 1000), 'client count 0 after concurrency');

    // Stop with connected clients (one inside the handler)
    for i := 0 to High(vClients) do
    begin
      vClients[i] := TsgcFSearchPipeClient.Create;
      Check(vClients[i].Connect(2000), 'stop test connect ' + IntToStr(i));
    end;
    Check(WaitClientCount(vS, 3, 2000), 'client count 3');
    vBusy := TThread.CreateAnonymousThread(procedure
      begin
        vClients[2].Request('{"sleep":300}');
      end);
    vBusy.FreeOnTerminate := False;
    vBusy.Start;
    Sleep(50);
    vSW := TStopwatch.StartNew;
    vS.Stop;
    vSW.Stop;
    Check(vSW.ElapsedMilliseconds < 2000, Format('stop took %d ms',
      [vSW.ElapsedMilliseconds]));
    Info(Format('Stop with 3 clients (one busy 300 ms): %d ms',
      [vSW.ElapsedMilliseconds]));
    Check(not vS.Active, 'inactive after stop');
    Check(vS.ClientCount = 0, 'no clients after stop');
    vBusy.WaitFor;
    vBusy.Free;
    Check(vClients[0].Request('{"echo":"x"}') = '', 'client cut by stop');
    for i := 0 to High(vClients) do
      vClients[i].Free;
    Check(not sgcFSearchIsServerRunning, 'not running after stop');

    // restart works (first instance again)
    Check(vS.Start, 'restart, error ' + IntToStr(vS.LastError));
    Check(sgcFSearchPipeRequest('{"echo":"again"}', 2000, vResp) and
      (vResp = '{"ok":true,"echo":"again"}'), 'one-shot request after restart');

    // CLI integration (the CLI copy has no sgcFSearch.exe next to it)
    if not FileExists(GCli) then
      Check(False, 'CLI copy missing ' + GCli)
    else
    begin
      Check(RunCli('status', '', vResp, vBig) = 0, 'cli status exit: ' + vBig);
      Check((Pos('ready', vResp) > 0) and (Pos('5,080,000', vResp) > 0) and
        (Pos('C:\, D:\', vResp) > 0) and (Pos('C:\Users\test\daemon.log', vResp)
        > 0), 'cli status text: ' + vResp);
      vExp := 'C:\Docs\report.pdf'#13#10'C:\Docs\Reports\'#13#10 +
        'C:\Docs\caf'#$00E9'.txt'#13#10;
      Check(RunCli('report ext:pdf', '', vResp, vBig) = 0, 'cli query exit');
      Check(vResp = vExp, 'cli query stdout: ' + vResp);
      Check(Pos('3 results (0.8 ms)', vBig) > 0, 'cli query stderr: ' + vBig);
      Check(RunCli('nothing', '', vResp, vBig) = 1, 'cli no results exit 1');
      Check(vResp = '', 'cli no results stdout empty');
      Check(RunCli('--json -n 5 report', '', vResp, vBig) = 0, 'cli json exit');
      Check((Copy(vResp, 1, 11) = '{"ok":true,') and
        (Pos('"results":[', vResp) > 0), 'cli json stdout: ' + vResp);
      Check(RunCli('-l report', '', vResp, vBig) = 0, 'cli long exit');
      Check((Pos('12345', vResp) > 0) and (Pos('<DIR>', vResp) > 0) and
        (Pos('2026-11-0', vResp) > 0) and (Pos('C:\Docs\report.pdf', vResp) >
        0), 'cli long stdout: ' + vResp);
      Check(RunCli('grep:TODO', '', vResp, vBig) = 0, 'cli content exit');
      Check(vResp = 'C:\Src\main.pas:12: // TODO fix'#13#10,
        'cli content: ' + vResp);
      Check(RunCli('stdio', '{"id":1,"echo":"a"}'#10#10'{"id":2,"echo":"b"}',
        vResp, vBig) = 0, 'cli stdio exit: ' + vBig);
      Check(vResp = '{"id":1,"ok":true,"echo":"a"}'#10 +
        '{"id":2,"ok":true,"echo":"b"}'#10, 'cli stdio stdout: ' + vResp);
      Check(RunCli('show hello', '', vResp, vBig) = 0, 'cli show exit');
      // query text: one argument is used as typed, with several an argument
      // holding a space stays one phrase
      vExp := CliQ('"notepad ext:exe"');
      Check(vExp = 'notepad ext:exe', 'cli one argument raw: ' + vExp);
      vExp := CliQ('-n 5 --json "notepad ext:exe"');
      Check(vExp = 'notepad ext:exe',
        'cli one argument after options: ' + vExp);
      vExp := CliQ('"annual report" in:~\Documents');
      Check(vExp = '"annual report" in:~\Documents',
        'cli phrase kept: ' + vExp);
      vExp := CliQ('report ext:pdf');
      Check(vExp = 'report ext:pdf', 'cli plain words: ' + vExp);
      vExp := CliQ('-- "-n x"');
      Check(vExp = '-n x', 'cli -- one argument raw: ' + vExp);
      vExp := CliQ('-- status "a b"');
      Check(vExp = 'status "a b"', 'cli -- phrase kept: ' + vExp);
      vExp := CliQ('show "notepad ext:exe"');
      Check(vExp = 'notepad ext:exe', 'cli show one argument raw: ' + vExp);
      vExp := CliQ('show "annual report" ext:pdf');
      Check(vExp = '"annual report" ext:pdf', 'cli show phrase kept: ' + vExp);
      Check((RunCli('help', '', vResp, vBig) = 0) and
        (Pos('Query syntax', vResp) > 0), 'cli help');
    end;
  finally
    vS.Free;
  end;
  Check(not sgcFSearchIsServerRunning, 'not running after free');
  // CLI without a server: never starts anything, exit 2
  if FileExists(GCli) then
  begin
    Check(RunCli('stop', '', vResp, vBig) = 2, 'cli stop without server');
    Check(Pos('not running', vBig) > 0, 'cli stop message: ' + vBig);
    Check(RunCli('status', '', vResp, vBig) = 2, 'cli status without server');
    Check(RunCli('report', '', vResp, vBig) = 2, 'cli query without server');
    Check((Pos('sgcFSearch.exe', vBig) > 0) and (Pos('not found', vBig) > 0),
      'cli missing exe message: ' + vBig);
    Check(not sgcFSearchIsServerRunning, 'cli started nothing');
  end;
end;

var
  vSrcCli: string;

begin
  GLastQLock := TCriticalSection.Create;
  try
    GBase := TPath.Combine(GetEnvironmentVariable('TEMP'),
      'sgcFSearchTests\pipe');
    if TDirectory.Exists(GBase) then
      TDirectory.Delete(GBase, True);
    TDirectory.CreateDirectory(GBase);
    SetEnvironmentVariable('SGCFSEARCH_HOME',
      PChar(TPath.Combine(GBase, 'home')));
    GPipeEnv := Format('sgcFSearchTest-%d-%d',
      [GetCurrentProcessId, GetTickCount]);
    SetEnvironmentVariable(SGCFS_PIPE_ENV, PChar(GPipeEnv));
    vSrcCli := ExtractFilePath(ParamStr(0)) + 'sgcfs.exe';
    GCli := TPath.Combine(GBase, 'sgcfs.exe');
    if FileExists(vSrcCli) then
      TFile.Copy(vSrcCli, GCli, True);
    try
      TestPure;
      TestNoServer;
      TestServer;
    finally
      try
        TDirectory.Delete(GBase, True);
      except
        Writeln('[WARN] cannot remove ', GBase);
      end;
    end;
  except
    on E: Exception do
    begin
      Inc(GFails);
      Writeln('[FAIL] exception ', E.ClassName, ': ', E.Message);
    end;
  end;
  GLastQLock.Free;
  if GFails = 0 then
  begin
    Writeln(Format('[PASS] %d checks', [GChecks]));
    ExitCode := 0;
  end
  else
  begin
    Writeln(Format('[FAILED] %d of %d checks', [GFails, GChecks]));
    ExitCode := 1;
  end;

end.
