{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Log;

{$I sgcVer.inc}

interface

uses
  Winapi.Windows, System.SysUtils, System.SyncObjs,
  // sgc
  sgcFSearch_Config;

const
  SGCFS_LOG_MAX_SIZE = 2 * 1024 * 1024; // rotate at 2 MB, keep one .old

  /// Thread-safe: appends 'yyyy-mm-dd hh:nn:ss.zzz [tid] Msg' (UTF-8) to
  /// DataDir\daemon.log; at 2 MB the file is renamed to daemon.log.old
  /// (replacing the previous one). Never raises.
procedure sgcFSearchLog(const Msg: string);

implementation

var
  GLogLock: TCriticalSection;

procedure sgcFSearchLog(const Msg: string);
var
  vFile, vOld: string;
  vLine: UTF8String;
  vHandle: THandle;
  vSize: Int64;
  vWritten: DWORD;
begin
  try
    vLine := UTF8String(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) +
      Format(' [%d] ', [GetCurrentThreadId]) + Msg + sLineBreak);
    vFile := sgcFSearchLogFileName;
    GLogLock.Enter;
    try
      vHandle := CreateFile(PChar(vFile), FILE_APPEND_DATA, FILE_SHARE_READ or
        FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, 0);
      if vHandle = INVALID_HANDLE_VALUE then
        Exit;
      try
        if not GetFileSizeEx(vHandle, vSize) then
          vSize := 0;
        if vSize >= SGCFS_LOG_MAX_SIZE then
        begin
          CloseHandle(vHandle);
          vHandle := INVALID_HANDLE_VALUE;
          vOld := vFile + '.old';
          MoveFileEx(PChar(vFile), PChar(vOld), MOVEFILE_REPLACE_EXISTING);
          vHandle := CreateFile(PChar(vFile), FILE_APPEND_DATA,
            FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
          if vHandle = INVALID_HANDLE_VALUE then
            Exit;
        end;
        if Length(vLine) > 0 then
          WriteFile(vHandle, vLine[1], Length(vLine), vWritten, nil);
      finally
        if vHandle <> INVALID_HANDLE_VALUE then
          CloseHandle(vHandle);
      end;
    finally
      GLogLock.Leave;
    end;
  except
    // logging never raises
  end;
end;

initialization

GLogLock := TCriticalSection.Create;

finalization

FreeAndNil(GLogLock);

end.
