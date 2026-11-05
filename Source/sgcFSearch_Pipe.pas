{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Pipe;

{$I sgcVer.inc}
// Named pipe transport of the sgcFSearch protocol (one JSON object per line).
// - Name: \\.\pipe\sgcFSearch-<current user SID>. The env SGCFSEARCH_PIPE
// overrides the full name (a bare name gets the \\.\pipe\ prefix).
// - Server: multi-instance pipe, overlapped ConnectNamedPipe in an accept
// thread, one worker thread per connection, DACL D:P(A;;GA;;;<SID>), local
// clients only. The first instance is created with
// FILE_FLAG_FIRST_PIPE_INSTANCE, so Start returns False (LastError =
// ERROR_ACCESS_DENIED) when another server already owns the name: that is
// how a second process detects it is not the first one.
// - Framing: UTF-8, LF terminated (CR LF accepted), blank lines ignored, a
// line longer than SGCFS_PIPE_MAX_LINE gets an error and the connection is
// closed. The handler runs on the worker threads (it must be thread-safe).
// A handler exception becomes an ok:false response with the message, an
// empty result the "unknown request" error (id echoed); the connection stays.
// - Shared registry names (HKCU), used by "sgcfs install / uninstall" and by
// the GUI "Start at login" option: SGCFS_REG_ENV_KEY + SGCFS_REG_ENV_PATH
// (user PATH, REG_EXPAND_SZ) and SGCFS_REG_RUN_KEY + SGCFS_REG_RUN_VALUE
// (data = sgcFSearchRunCommand(<dir>\sgcFSearch.exe)).

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections;

const
  SGCFS_PIPE_ENV = 'SGCFSEARCH_PIPE';
  SGCFS_PIPE_PREFIX = '\\.\pipe\';
  SGCFS_PIPE_BASE_NAME = 'sgcFSearch-';
  SGCFS_PIPE_MAX_LINE = 16 * 1024 * 1024;
  SGCFS_APP_EXE = 'sgcFSearch.exe';
  SGCFS_BACKGROUND_ARG = '--background';
  // HKCU\Environment, value Path (REG_EXPAND_SZ): sgcfs install adds its folder
  SGCFS_REG_ENV_KEY = 'Environment';
  SGCFS_REG_ENV_PATH = 'Path';
  // HKCU\...\Run, value sgcFSearch = "<dir>\sgcFSearch.exe" --background
  SGCFS_REG_RUN_KEY = 'Software\Microsoft\Windows\CurrentVersion\Run';
  SGCFS_REG_RUN_VALUE = 'sgcFSearch';

type
  TsgcFSearchRequestHandler = reference to function(const Line: string): string;

  TsgcFSearchPipeServer = class
  private
    FAcceptThread: TThread;
    FActive: Boolean;
    FHandler: TsgcFSearchRequestHandler;
    FLastError: Cardinal;
    FLock: TCriticalSection;
    FPipeName: string;
    FSecAttr: TSecurityAttributes;
    FSecDesc: Pointer;
    FStopEvent: THandle;
    FWorkers: TList<TThread>;
    function GetClientCount: Integer;
  protected
    function CreateInstance(First: Boolean): THandle;
    procedure AddConnection(Pipe: THandle);
  public
    constructor Create(const Handler: TsgcFSearchRequestHandler);
    destructor Destroy; override;
    // False when the pipe name is owned by another server (LastError =
    // ERROR_ACCESS_DENIED) or cannot be created. The name is read from
    // sgcFSearchPipeName at each Start.
    function Start: Boolean;
    // cancels pending I/O, closes every connection, joins the threads; a
    // handler that is running is waited for
    procedure Stop;
    // handler call with the protocol defaults (used by the workers)
    function ProcessLine(const Line: string): string;
    property Active: Boolean read FActive;
    property ClientCount: Integer read GetClientCount;
    property LastError: Cardinal read FLastError;
    property PipeName: string read FPipeName;
  end;

  TsgcFSearchPipeClient = class
  private
    FBuf: TBytes;
    FLastError: Cardinal;
    FLen: Integer;
    FPipe: THandle;
    FStart: Integer;
    function GetConnected: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // retries while the pipe is busy or not created yet, until TimeoutMs
    function Connect(TimeoutMs: Integer): Boolean;
    // sends Line + LF (as is when Line already ends with LF)
    function WriteLine(const Line: string): Boolean;
    // next response line without its CR LF; '' on error (see LastError)
    function ReadLine: string;
    // WriteLine + ReadLine; '' on error
    function Request(const Line: string): string;
    procedure Close;
    property Connected: Boolean read GetConnected;
    property Handle: THandle read FPipe;
    property LastError: Cardinal read FLastError;
  end;

  // string SID of the process user ('' on failure)
function sgcFSearchCurrentUserSid: string;
// \\.\pipe\sgcFSearch-<SID>, or the SGCFSEARCH_PIPE override
function sgcFSearchPipeName: string;
// connect + one request + close; False when the server cannot be reached
function sgcFSearchPipeRequest(const Line: string; TimeoutMs: Integer;
  out Response: string): Boolean;
// True when a server owns the pipe name (busy instances included)
function sgcFSearchIsServerRunning: Boolean;
// starts "<ExePath>" --background detached when no server runs, then waits
// until it answers a status request; False on a missing exe or timeout
function sgcFSearchStartDaemon(const ExePath: string;
  TimeoutMs: Integer): Boolean;
// {"id":<id of Line, when any>,"ok":false,"error":"<Error>"}
function sgcFSearchErrorResponse(const Line, Error: string): string;
// PATH list merge (';' separated; compare ignores case, quotes, trailing \
// and expands %VARS%). Add appends Dir, False when already present.
function sgcFSearchPathListAdd(const PathList, Dir: string;
  out NewList: string): Boolean;
// removes every entry equal to Dir, False when none
function sgcFSearchPathListRemove(const PathList, Dir: string;
  out NewList: string): Boolean;
// "<AppExe>" --background (the Run value data)
function sgcFSearchRunCommand(const AppExe: string): string;
// writes or deletes HKCU Run\sgcFSearch
function sgcFSearchSetStartAtLogin(Enable: Boolean;
  const AppExe: string): Boolean;
// HKCU Run\sgcFSearch data, '' when not set
function sgcFSearchGetStartAtLogin: string;

implementation

uses
  System.Math, System.JSON, System.Win.Registry,
  // sgc
  sgcFSearch_Log;

const
  CS_PIPE_BUFFER = 64 * 1024;
  CS_READ_CHUNK = 64 * 1024;
  CS_FIRST_PIPE_INSTANCE = $00080000;
  CS_PIPE_REJECT_REMOTE_CLIENTS = $00000008;
  CS_SECURITY_SQOS_PRESENT = $00100000;
  CS_SECURITY_IDENTIFICATION = $00010000;
  CS_SDDL_REVISION_1 = 1;
  CS_STATUS_REQUEST = '{"status":true}';

function ApiConvertSidToStringSid(Sid: Pointer; var StringSid: PWideChar): BOOL;
  stdcall; external advapi32 name 'ConvertSidToStringSidW';
function ApiConvertStringSDToSD(StringSD: PWideChar; Revision: DWORD;
  var SD: Pointer; SDSize: Pointer): BOOL; stdcall;
  external advapi32 name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';
function ApiCancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL;
  stdcall; external kernel32 name 'CancelIoEx';

type
  TsgcFSearchPipeWorker = class(TThread)
  private
    FBuf: TBytes;
    FEvent: THandle;
    FLen: Integer;
    FOv: TOverlapped;
    FPipe: THandle;
    FScan: Integer;
    FServer: TsgcFSearchPipeServer;
    FServing: Boolean;
    FStart: Integer;
    function Stopping: Boolean;
    function WaitIo(out Count: DWORD): Boolean;
    function ReadMore: Boolean;
    function WriteText(const Text: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Server: TsgcFSearchPipeServer; Pipe: THandle);
    destructor Destroy; override;
  end;

  TsgcFSearchPipeAcceptor = class(TThread)
  private
    FEvent: THandle;
    FPipe: THandle;
    FServer: TsgcFSearchPipeServer;
  protected
    procedure Execute; override;
  public
    constructor Create(Server: TsgcFSearchPipeServer; Pipe: THandle);
    destructor Destroy; override;
  end;

function FindLF(const Buf: TBytes; From, Count: Integer): Integer;
var
  i: Integer;
begin
  for i := From to Count - 1 do
    if Buf[i] = 10 then
      Exit(i);
  Result := -1;
end;

{ TsgcFSearchPipeWorker }

constructor TsgcFSearchPipeWorker.Create(Server: TsgcFSearchPipeServer;
  Pipe: THandle);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := Server;
  FPipe := Pipe;
  FEvent := CreateEvent(nil, True, False, nil);
  FServing := True;
  SetLength(FBuf, CS_READ_CHUNK);
end;

destructor TsgcFSearchPipeWorker.Destroy;
begin
  inherited;
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  if FEvent <> 0 then
    CloseHandle(FEvent);
end;

function TsgcFSearchPipeWorker.Stopping: Boolean;
begin
  Result := WaitForSingleObject(FServer.FStopEvent, 0) = WAIT_OBJECT_0;
end;

function TsgcFSearchPipeWorker.WaitIo(out Count: DWORD): Boolean;
var
  vHandles: array [0 .. 1] of THandle;
begin
  Count := 0;
  vHandles[0] := FEvent;
  vHandles[1] := FServer.FStopEvent;
  if WaitForMultipleObjects(2, PWOHandleArray(@vHandles[0]), False, INFINITE) = WAIT_OBJECT_0
  then
    Result := GetOverlappedResult(FPipe, FOv, Count, False)
  else
  begin
    // stop requested: cancel and wait until the I/O really ended
    ApiCancelIoEx(FPipe, @FOv);
    GetOverlappedResult(FPipe, FOv, Count, True);
    Result := False;
  end;
end;

function TsgcFSearchPipeWorker.ReadMore: Boolean;
var
  vDummy, vCount: DWORD;
begin
  if FStart > 0 then
  begin
    if FLen > FStart then
      Move(FBuf[FStart], FBuf[0], FLen - FStart);
    Dec(FLen, FStart);
    Dec(FScan, FStart);
    FStart := 0;
  end;
  if Length(FBuf) - FLen < CS_READ_CHUNK then
    SetLength(FBuf, Max(Length(FBuf) * 2, FLen + CS_READ_CHUNK));
  FillChar(FOv, SizeOf(FOv), 0);
  FOv.hEvent := FEvent;
  vDummy := 0;
  vCount := 0;
  if ReadFile(FPipe, FBuf[FLen], DWORD(Length(FBuf) - FLen), vDummy, @FOv) then
    Result := GetOverlappedResult(FPipe, FOv, vCount, False)
  else if GetLastError = ERROR_IO_PENDING then
    Result := WaitIo(vCount)
  else
    Result := False;
  if Result then
    Inc(FLen, Integer(vCount));
end;

function TsgcFSearchPipeWorker.WriteText(const Text: string): Boolean;
var
  vBytes: TBytes;
  vPos: Integer;
  vDummy, vCount: DWORD;
  vOk: Boolean;
begin
  vBytes := TEncoding.UTF8.GetBytes(Text + #10);
  vPos := 0;
  while vPos < Length(vBytes) do
  begin
    FillChar(FOv, SizeOf(FOv), 0);
    FOv.hEvent := FEvent;
    vDummy := 0;
    vCount := 0;
    if WriteFile(FPipe, vBytes[vPos], DWORD(Length(vBytes) - vPos), vDummy, @FOv)
    then
      vOk := GetOverlappedResult(FPipe, FOv, vCount, False)
    else if GetLastError = ERROR_IO_PENDING then
      vOk := WaitIo(vCount)
    else
      vOk := False;
    if not vOk or (vCount = 0) then
      Exit(False);
    Inc(vPos, Integer(vCount));
  end;
  Result := True;
end;

procedure TsgcFSearchPipeWorker.Execute;
var
  p, vEnd: Integer;
  vLine: string;
begin
  try
    try
      if FEvent = 0 then
        Exit;
      FStart := 0;
      FLen := 0;
      FScan := 0;
      while not Stopping do
      begin
        p := FindLF(FBuf, FScan, FLen);
        if p < 0 then
        begin
          FScan := FLen;
          if FLen - FStart > SGCFS_PIPE_MAX_LINE then
          begin
            WriteText(sgcFSearchErrorResponse('', 'request line too long'));
            Break;
          end;
          if not ReadMore then
            Break;
          Continue;
        end;
        vEnd := p;
        if (vEnd > FStart) and (FBuf[vEnd - 1] = 13) then
          Dec(vEnd);
        if vEnd > FStart then
          vLine := TEncoding.UTF8.GetString(FBuf, FStart, vEnd - FStart)
        else
          vLine := '';
        FStart := p + 1;
        FScan := FStart;
        if Trim(vLine) = '' then
          Continue;
        if not WriteText(FServer.ProcessLine(vLine)) then
          Break;
      end;
    except
      on E: Exception do
        sgcFSearchLog('pipe: connection error: ' + E.Message);
    end;
  finally
    // closing (not disconnecting) lets the client still read what was sent
    if FPipe <> INVALID_HANDLE_VALUE then
      CloseHandle(FPipe);
    FPipe := INVALID_HANDLE_VALUE;
    FServing := False;
  end;
end;

{ TsgcFSearchPipeAcceptor }

constructor TsgcFSearchPipeAcceptor.Create(Server: TsgcFSearchPipeServer;
  Pipe: THandle);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := Server;
  FPipe := Pipe;
  FEvent := CreateEvent(nil, True, False, nil);
end;

destructor TsgcFSearchPipeAcceptor.Destroy;
begin
  inherited;
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  if FEvent <> 0 then
    CloseHandle(FEvent);
end;

procedure TsgcFSearchPipeAcceptor.Execute;
var
  vOv: TOverlapped;
  vHandles: array [0 .. 1] of THandle;
  vCount, vErr: DWORD;
  vConnected: Boolean;
begin
  try
    if FEvent = 0 then
      Exit;
    while WaitForSingleObject(FServer.FStopEvent, 0) <> WAIT_OBJECT_0 do
    begin
      if FPipe = INVALID_HANDLE_VALUE then
      begin
        FPipe := FServer.CreateInstance(False);
        if FPipe = INVALID_HANDLE_VALUE then
        begin
          // out of resources: back off, retry
          if WaitForSingleObject(FServer.FStopEvent, 250) = WAIT_OBJECT_0 then
            Break;
          Continue;
        end;
      end;
      FillChar(vOv, SizeOf(vOv), 0);
      vOv.hEvent := FEvent;
      vConnected := ConnectNamedPipe(FPipe, @vOv);
      if not vConnected then
      begin
        vErr := GetLastError;
        if vErr = ERROR_PIPE_CONNECTED then
          vConnected := True
        else if vErr = ERROR_IO_PENDING then
        begin
          vHandles[0] := FEvent;
          vHandles[1] := FServer.FStopEvent;
          if WaitForMultipleObjects(2, PWOHandleArray(@vHandles[0]), False,
            INFINITE) = WAIT_OBJECT_0 then
            vConnected := GetOverlappedResult(FPipe, vOv, vCount, False)
          else
          begin
            ApiCancelIoEx(FPipe, @vOv);
            GetOverlappedResult(FPipe, vOv, vCount, True);
            Break;
          end;
        end
        else if vErr = ERROR_NO_DATA then
        begin
          // the client connected and left already: reuse the instance
          DisconnectNamedPipe(FPipe);
          Continue;
        end;
      end;
      if vConnected then
        FServer.AddConnection(FPipe)
      else
        CloseHandle(FPipe);
      FPipe := INVALID_HANDLE_VALUE;
    end;
  except
    on E: Exception do
      sgcFSearchLog('pipe: accept error: ' + E.Message);
  end;
end;

{ TsgcFSearchPipeServer }

constructor TsgcFSearchPipeServer.Create(const Handler
  : TsgcFSearchRequestHandler);
begin
  inherited Create;
  FHandler := Handler;
  FLock := TCriticalSection.Create;
  FWorkers := TList<TThread>.Create;
  FStopEvent := CreateEvent(nil, True, False, nil);
end;

destructor TsgcFSearchPipeServer.Destroy;
begin
  Stop;
  FWorkers.Free;
  FLock.Free;
  if FStopEvent <> 0 then
    CloseHandle(FStopEvent);
  if FSecDesc <> nil then
    LocalFree(HLOCAL(FSecDesc));
  inherited;
end;

function TsgcFSearchPipeServer.CreateInstance(First: Boolean): THandle;
var
  vOpenMode: DWORD;
begin
  vOpenMode := PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED;
  if First then
    vOpenMode := vOpenMode or CS_FIRST_PIPE_INSTANCE;
  Result := CreateNamedPipe(PChar(FPipeName), vOpenMode, PIPE_TYPE_BYTE or
    PIPE_READMODE_BYTE or PIPE_WAIT or CS_PIPE_REJECT_REMOTE_CLIENTS,
    PIPE_UNLIMITED_INSTANCES, CS_PIPE_BUFFER, CS_PIPE_BUFFER, 0, @FSecAttr);
end;

procedure TsgcFSearchPipeServer.AddConnection(Pipe: THandle);
var
  i: Integer;
  vWorker: TsgcFSearchPipeWorker;
begin
  // reap the finished workers (few clients, a linear pass is fine)
  FLock.Enter;
  try
    for i := FWorkers.Count - 1 downto 0 do
      if FWorkers[i].Finished then
      begin
        FWorkers[i].Free;
        FWorkers.Delete(i);
      end;
  finally
    FLock.Leave;
  end;
  try
    vWorker := TsgcFSearchPipeWorker.Create(Self, Pipe);
  except
    on E: Exception do
    begin
      CloseHandle(Pipe);
      sgcFSearchLog('pipe: cannot start a connection thread: ' + E.Message);
      Exit;
    end;
  end;
  FLock.Enter;
  try
    FWorkers.Add(vWorker);
  finally
    FLock.Leave;
  end;
  vWorker.Start;
end;

function TsgcFSearchPipeServer.GetClientCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to FWorkers.Count - 1 do
      if TsgcFSearchPipeWorker(FWorkers[i]).FServing then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchPipeServer.Start: Boolean;
var
  vSid: string;
  vPipe: THandle;
begin
  if FActive then
    Exit(True);
  FLastError := 0;
  FPipeName := sgcFSearchPipeName;
  if FSecDesc = nil then
  begin
    vSid := sgcFSearchCurrentUserSid;
    if (vSid = '') or not ApiConvertStringSDToSD
      (PChar('D:P(A;;GA;;;' + vSid + ')'), CS_SDDL_REVISION_1, FSecDesc, nil)
    then
    begin
      FLastError := GetLastError;
      FSecDesc := nil;
      Exit(False);
    end;
  end;
  FSecAttr.nLength := SizeOf(FSecAttr);
  FSecAttr.lpSecurityDescriptor := FSecDesc;
  FSecAttr.bInheritHandle := False;
  vPipe := CreateInstance(True);
  if vPipe = INVALID_HANDLE_VALUE then
  begin
    FLastError := GetLastError;
    Exit(False);
  end;
  ResetEvent(FStopEvent);
  try
    FAcceptThread := TsgcFSearchPipeAcceptor.Create(Self, vPipe);
  except
    CloseHandle(vPipe);
    raise;
  end;
  FActive := True;
  FAcceptThread.Start;
  Result := True;
end;

procedure TsgcFSearchPipeServer.Stop;
var
  vList: TArray<TThread>;
  i: Integer;
begin
  if FAcceptThread = nil then
  begin
    FActive := False;
    Exit;
  end;
  SetEvent(FStopEvent);
  FAcceptThread.WaitFor;
  FreeAndNil(FAcceptThread);
  FLock.Enter;
  try
    vList := FWorkers.ToArray;
    FWorkers.Clear;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(vList) do
    vList[i].Free; // Terminate + WaitFor
  ResetEvent(FStopEvent);
  FActive := False;
end;

function TsgcFSearchPipeServer.ProcessLine(const Line: string): string;
begin
  Result := '';
  try
    if Assigned(FHandler) then
      Result := FHandler(Line);
  except
    on E: Exception do
    begin
      sgcFSearchLog('pipe: request failed: ' + E.ClassName + ': ' + E.Message);
      Exit(sgcFSearchErrorResponse(Line, E.Message));
    end;
  end;
  // a response is exactly one line
  while (Result <> '') and CharInSet(Result[Length(Result)], [#10, #13]) do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then
    Result := sgcFSearchErrorResponse(Line, 'unknown request');
end;

{ TsgcFSearchPipeClient }

constructor TsgcFSearchPipeClient.Create;
begin
  inherited Create;
  FPipe := INVALID_HANDLE_VALUE;
end;

destructor TsgcFSearchPipeClient.Destroy;
begin
  Close;
  inherited;
end;

function TsgcFSearchPipeClient.GetConnected: Boolean;
begin
  Result := FPipe <> INVALID_HANDLE_VALUE;
end;

procedure TsgcFSearchPipeClient.Close;
begin
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  FPipe := INVALID_HANDLE_VALUE;
  FStart := 0;
  FLen := 0;
end;

function TsgcFSearchPipeClient.Connect(TimeoutMs: Integer): Boolean;
var
  vName: string;
  vDeadline: UInt64;
  vRemain: Int64;
begin
  Close;
  vName := sgcFSearchPipeName;
  vDeadline := GetTickCount64 + UInt64(Max(TimeoutMs, 0));
  repeat
    FPipe := CreateFile(PChar(vName), GENERIC_READ or GENERIC_WRITE, 0, nil,
      OPEN_EXISTING, CS_SECURITY_SQOS_PRESENT or CS_SECURITY_IDENTIFICATION, 0);
    if FPipe <> INVALID_HANDLE_VALUE then
    begin
      FLastError := 0;
      Exit(True);
    end;
    FLastError := GetLastError;
    vRemain := Int64(vDeadline) - Int64(GetTickCount64);
    if vRemain <= 0 then
      Exit(False);
    if FLastError = ERROR_PIPE_BUSY then
      WaitNamedPipe(PChar(vName), DWORD(Min(vRemain, 1000)))
    else if FLastError = ERROR_FILE_NOT_FOUND then
      Sleep(DWORD(Min(vRemain, 50)))
    else
      Exit(False);
  until False;
end;

function TsgcFSearchPipeClient.WriteLine(const Line: string): Boolean;
var
  vBytes: TBytes;
  vPos: Integer;
  vDone: DWORD;
begin
  if FPipe = INVALID_HANDLE_VALUE then
  begin
    FLastError := ERROR_INVALID_HANDLE;
    Exit(False);
  end;
  if (Line <> '') and (Line[Length(Line)] = #10) then
    vBytes := TEncoding.UTF8.GetBytes(Line)
  else
    vBytes := TEncoding.UTF8.GetBytes(Line + #10);
  vPos := 0;
  while vPos < Length(vBytes) do
  begin
    vDone := 0;
    if not WriteFile(FPipe, vBytes[vPos], DWORD(Length(vBytes) - vPos),
      vDone, nil) then
    begin
      FLastError := GetLastError;
      Exit(False);
    end;
    Inc(vPos, Integer(vDone));
  end;
  Result := True;
end;

function TsgcFSearchPipeClient.ReadLine: string;
var
  p, vEnd, vScan: Integer;
  vRead: DWORD;
begin
  Result := '';
  if FPipe = INVALID_HANDLE_VALUE then
  begin
    FLastError := ERROR_INVALID_HANDLE;
    Exit;
  end;
  vScan := FStart;
  repeat
    p := FindLF(FBuf, vScan, FLen);
    if p >= 0 then
    begin
      vEnd := p;
      if (vEnd > FStart) and (FBuf[vEnd - 1] = 13) then
        Dec(vEnd);
      if vEnd > FStart then
        Result := TEncoding.UTF8.GetString(FBuf, FStart, vEnd - FStart);
      FStart := p + 1;
      Exit;
    end;
    vScan := FLen;
    if FStart > 0 then
    begin
      if FLen > FStart then
        Move(FBuf[FStart], FBuf[0], FLen - FStart);
      Dec(FLen, FStart);
      Dec(vScan, FStart);
      FStart := 0;
    end;
    if Length(FBuf) - FLen < CS_READ_CHUNK then
      SetLength(FBuf, Max(Length(FBuf) * 2, FLen + CS_READ_CHUNK));
    vRead := 0;
    if not ReadFile(FPipe, FBuf[FLen], DWORD(Length(FBuf) - FLen), vRead, nil)
    then
    begin
      FLastError := GetLastError;
      Exit;
    end;
    Inc(FLen, Integer(vRead));
  until False;
end;

function TsgcFSearchPipeClient.Request(const Line: string): string;
begin
  if WriteLine(Line) then
    Result := ReadLine
  else
    Result := '';
end;

{ functions }

function sgcFSearchCurrentUserSid: string;
var
  vToken: THandle;
  vSize: DWORD;
  vBuf: TBytes;
  vStr: PWideChar;
begin
  Result := '';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, vToken) then
    Exit;
  try
    vSize := 0;
    GetTokenInformation(vToken, TokenUser, nil, 0, vSize);
    if vSize = 0 then
      Exit;
    SetLength(vBuf, vSize);
    if not GetTokenInformation(vToken, TokenUser, @vBuf[0], vSize, vSize) then
      Exit;
    vStr := nil;
    if ApiConvertSidToStringSid(PTokenUser(@vBuf[0])^.User.Sid, vStr) then
    begin
      Result := vStr;
      LocalFree(HLOCAL(vStr));
    end;
  finally
    CloseHandle(vToken);
  end;
end;

function sgcFSearchPipeName: string;
begin
  Result := Trim(GetEnvironmentVariable(SGCFS_PIPE_ENV));
  if Result = '' then
    Result := SGCFS_PIPE_PREFIX + SGCFS_PIPE_BASE_NAME +
      sgcFSearchCurrentUserSid
  else if Copy(Result, 1, 2) <> '\\' then
    Result := SGCFS_PIPE_PREFIX + Result;
end;

function sgcFSearchPipeRequest(const Line: string; TimeoutMs: Integer;
  out Response: string): Boolean;
var
  vClient: TsgcFSearchPipeClient;
begin
  Response := '';
  vClient := TsgcFSearchPipeClient.Create;
  try
    Result := vClient.Connect(TimeoutMs);
    if Result then
    begin
      Response := vClient.Request(Line);
      Result := Response <> '';
    end;
  finally
    vClient.Free;
  end;
end;

function sgcFSearchIsServerRunning: Boolean;
var
  vName: string;
begin
  vName := sgcFSearchPipeName;
  // never 0: that means "the server default timeout"
  Result := WaitNamedPipe(PChar(vName), 1);
  if not Result then
    Result := GetLastError = ERROR_SEM_TIMEOUT; // exists, all instances busy
end;

function ResponseIsOk(const Response: string): Boolean;
var
  vValue: TJSONValue;
begin
  Result := False;
  vValue := TJSONObject.ParseJSONValue(Response);
  try
    if vValue is TJSONObject then
      Result := TJSONObject(vValue).GetValue('ok') is TJSONTrue;
  finally
    vValue.Free;
  end;
end;

function sgcFSearchStartDaemon(const ExePath: string;
  TimeoutMs: Integer): Boolean;
var
  vSI: TStartupInfo;
  vPI: TProcessInformation;
  vCmd, vDir, vResp: string;
  vDeadline: UInt64;
  vFlags: DWORD;
begin
  if sgcFSearchIsServerRunning then
    Exit(True);
  if (ExePath = '') or not FileExists(ExePath) then
  begin
    SetLastError(ERROR_FILE_NOT_FOUND);
    Exit(False);
  end;
  vCmd := sgcFSearchRunCommand(ExePath);
  UniqueString(vCmd);
  vDir := ExtractFileDir(ExePath);
  FillChar(vSI, SizeOf(vSI), 0);
  vSI.cb := SizeOf(vSI);
  FillChar(vPI, SizeOf(vPI), 0);
  // no handle inheritance: a redirected stdout of the caller must not stay
  // open in the daemon
  vFlags := CREATE_NEW_PROCESS_GROUP or DETACHED_PROCESS;
  if not CreateProcess(nil, PChar(vCmd), nil, nil, False,
    vFlags or CREATE_BREAKAWAY_FROM_JOB, nil, PChar(vDir), vSI, vPI) then
    if not CreateProcess(nil, PChar(vCmd), nil, nil, False, vFlags, nil,
      PChar(vDir), vSI, vPI) then
      Exit(False);
  CloseHandle(vPI.hThread);
  try
    vDeadline := GetTickCount64 + UInt64(Max(TimeoutMs, 0));
    repeat
      if sgcFSearchPipeRequest(CS_STATUS_REQUEST, 250, vResp) and
        ResponseIsOk(vResp) then
        Exit(True);
      // exited without a server: it failed (when another instance won the
      // race, the pipe exists and the polling goes on)
      if (WaitForSingleObject(vPI.hProcess, 0) = WAIT_OBJECT_0) and not sgcFSearchIsServerRunning
      then
        Exit(False);
      if GetTickCount64 >= vDeadline then
        Exit(False);
      Sleep(100);
    until False;
  finally
    CloseHandle(vPI.hProcess);
  end;
end;

function sgcFSearchErrorResponse(const Line, Error: string): string;
var
  vValue, vId: TJSONValue;
  vIdText: string;
  vError: TJSONString;
begin
  vIdText := '';
  if Line <> '' then
  begin
    vValue := nil;
    try
      try
        vValue := TJSONObject.ParseJSONValue(Line);
        if vValue is TJSONObject then
        begin
          vId := TJSONObject(vValue).GetValue('id');
          if vId <> nil then
            vIdText := vId.ToJSON;
        end;
      except
        vIdText := '';
      end;
    finally
      vValue.Free;
    end;
  end;
  vError := TJSONString.Create(Error);
  try
    if vIdText <> '' then
      Result := '{"id":' + vIdText + ',"ok":false,"error":' +
        vError.ToJSON + '}'
    else
      Result := '{"ok":false,"error":' + vError.ToJSON + '}';
  finally
    vError.Free;
  end;
end;

function ExpandEnv(const S: string): string;
var
  vLen: DWORD;
begin
  vLen := ExpandEnvironmentStrings(PChar(S), nil, 0);
  if vLen = 0 then
    Exit(S);
  SetLength(Result, vLen);
  vLen := ExpandEnvironmentStrings(PChar(S), PChar(Result), vLen);
  if vLen = 0 then
    Exit(S);
  SetLength(Result, vLen - 1);
end;

function TrimDir(const S: string): string;
begin
  Result := Trim(S);
  while (Length(Result) > 3) and CharInSet(Result[Length(Result)],
    ['\', '/']) do
    SetLength(Result, Length(Result) - 1);
end;

// comparison key of a PATH entry
function PathKey(const S: string): string;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and (Result[1] = '"') and
    (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
  if Pos('%', Result) > 0 then
    Result := ExpandEnv(Result);
  Result := AnsiUpperCase(TrimDir(Result));
end;

function sgcFSearchPathListAdd(const PathList, Dir: string;
  out NewList: string): Boolean;
var
  vDir, vKey: string;
  vParts: TArray<string>;
  i: Integer;
begin
  NewList := PathList;
  vDir := TrimDir(Dir);
  vKey := PathKey(vDir);
  if vKey = '' then
    Exit(False);
  vParts := PathList.Split([';']);
  for i := 0 to High(vParts) do
    if (Trim(vParts[i]) <> '') and (PathKey(vParts[i]) = vKey) then
      Exit(False);
  while (NewList <> '') and (NewList[Length(NewList)] = ';') do
    SetLength(NewList, Length(NewList) - 1);
  if Trim(NewList) = '' then
    NewList := vDir
  else
    NewList := NewList + ';' + vDir;
  Result := True;
end;

function sgcFSearchPathListRemove(const PathList, Dir: string;
  out NewList: string): Boolean;
var
  vKey, vOut: string;
  vParts: TArray<string>;
  i: Integer;
begin
  NewList := PathList;
  Result := False;
  vKey := PathKey(Dir);
  if vKey = '' then
    Exit;
  vParts := PathList.Split([';']);
  vOut := '';
  for i := 0 to High(vParts) do
  begin
    if Trim(vParts[i]) = '' then
      Continue;
    if PathKey(vParts[i]) = vKey then
      Result := True
    else if vOut = '' then
      vOut := vParts[i]
    else
      vOut := vOut + ';' + vParts[i];
  end;
  if Result then
    NewList := vOut;
end;

function sgcFSearchRunCommand(const AppExe: string): string;
begin
  Result := '"' + AppExe + '" ' + SGCFS_BACKGROUND_ARG;
end;

function sgcFSearchSetStartAtLogin(Enable: Boolean;
  const AppExe: string): Boolean;
var
  vReg: TRegistry;
begin
  vReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      vReg.RootKey := HKEY_CURRENT_USER;
      if vReg.OpenKey(SGCFS_REG_RUN_KEY, Enable) then
      begin
        if Enable then
          vReg.WriteString(SGCFS_REG_RUN_VALUE, sgcFSearchRunCommand(AppExe))
        else if vReg.ValueExists(SGCFS_REG_RUN_VALUE) then
          vReg.DeleteValue(SGCFS_REG_RUN_VALUE);
        Result := True;
      end
      else
        Result := not Enable;
    except
      Result := False;
    end;
  finally
    vReg.Free;
  end;
end;

function sgcFSearchGetStartAtLogin: string;
var
  vReg: TRegistry;
begin
  Result := '';
  vReg := TRegistry.Create(KEY_READ);
  try
    try
      vReg.RootKey := HKEY_CURRENT_USER;
      if vReg.OpenKeyReadOnly(SGCFS_REG_RUN_KEY) and
        vReg.ValueExists(SGCFS_REG_RUN_VALUE) then
        Result := vReg.ReadString(SGCFS_REG_RUN_VALUE);
    except
      Result := '';
    end;
  finally
    vReg.Free;
  end;
end;

end.
