{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_NtApi;

{$I sgcVer.inc}

interface

uses
  Winapi.Windows, System.SysUtils,
  // sgc
  sgcFSearch_Types;

// Declarations missing from Delphi 13 Winapi.Windows (checked: it has no
// GetFileInformationByHandleEx, FILE_INFO_BY_HANDLE_CLASS, FILE_ID_*_DIR_INFO,
// NtOpenFile, UNICODE_STRING, OBJECT_ATTRIBUTES or IO_STATUS_BLOCK).

const
  // FILE_INFO_BY_HANDLE_CLASS values (minwinbase.h)
  FileIdBothDirectoryInfo = 10;
  FileIdBothDirectoryRestartInfo = 11;
  FileFullDirectoryInfo = 14;
  FileIdExtdDirectoryInfo = 19;
  FileIdExtdDirectoryRestartInfo = 20;

  // NtOpenFile access, share and open options
  FILE_LIST_DIRECTORY = $0001;
  FILE_READ_ATTRIBUTES_ACCESS = $0080; // FILE_READ_ATTRIBUTES access right
  FILE_DIRECTORY_FILE = $00000001;
  FILE_SYNCHRONOUS_IO_NONALERT = $00000020;
  FILE_OPEN_FOR_BACKUP_INTENT = $00004000;
  OBJ_CASE_INSENSITIVE = $00000040;

  // NTSTATUS values
  STATUS_SUCCESS = NTSTATUS(0);
  STATUS_ACCESS_DENIED = NTSTATUS($C0000022);
  STATUS_OBJECT_NAME_INVALID = NTSTATUS($C0000033);
  STATUS_OBJECT_NAME_NOT_FOUND = NTSTATUS($C0000034);
  STATUS_OBJECT_PATH_NOT_FOUND = NTSTATUS($C000003A);
  STATUS_SHARING_VIOLATION = NTSTATUS($C0000043);
  STATUS_DELETE_PENDING = NTSTATUS($C0000056);
  STATUS_NOT_A_DIRECTORY = NTSTATUS($C0000103);

  /// Listing buffer size used by sgcFSearchListDirectory.
  SGCFS_LIST_BUFFER_SIZE = 64 * 1024;

type
  /// UNICODE_STRING (x64: 16 bytes)
  TsgcFSearchUnicodeString = record
    Length: Word; // bytes, without terminator
    MaximumLength: Word; // bytes
    Buffer: PWideChar;
  end;

  PsgcFSearchUnicodeString = ^TsgcFSearchUnicodeString;

  /// OBJECT_ATTRIBUTES (x64: 48 bytes)
  TsgcFSearchObjectAttributes = record
    Length: Cardinal;
    RootDirectory: THandle; // open folder handle for relative opens, or 0
    ObjectName: PsgcFSearchUnicodeString;
    Attributes: Cardinal; // OBJ_*
    SecurityDescriptor: Pointer;
    SecurityQualityOfService: Pointer;
  end;

  PsgcFSearchObjectAttributes = ^TsgcFSearchObjectAttributes;

  /// IO_STATUS_BLOCK (x64: 16 bytes; Status in the low 32 bits)
  TsgcFSearchIoStatusBlock = record
    Status: NativeInt;
    Information: NativeUInt;
  end;

  PsgcFSearchIoStatusBlock = ^TsgcFSearchIoStatusBlock;

  /// FILE_ID_BOTH_DIR_INFO (FileName at offset 104)
  TsgcFSearchFileIdBothDirInfo = record
    NextEntryOffset: Cardinal;
    FileIndex: Cardinal;
    CreationTime: Int64;
    LastAccessTime: Int64;
    LastWriteTime: Int64;
    ChangeTime: Int64;
    EndOfFile: Int64;
    AllocationSize: Int64;
    FileAttributes: Cardinal;
    FileNameLength: Cardinal; // bytes
    EaSize: Cardinal; // reparse tag when FILE_ATTRIBUTE_REPARSE_POINT
    ShortNameLength: ShortInt;
    ShortName: array [0 .. 11] of WideChar;
    FileId: Int64;
    FileName: array [0 .. 0] of WideChar;
  end;

  PsgcFSearchFileIdBothDirInfo = ^TsgcFSearchFileIdBothDirInfo;

  /// FILE_ID_EXTD_DIR_INFO (FileName at offset 88; FileId is FILE_ID_128,
  /// the low 8 bytes are the NTFS file reference number)
  TsgcFSearchFileIdExtdDirInfo = record
    NextEntryOffset: Cardinal;
    FileIndex: Cardinal;
    CreationTime: Int64;
    LastAccessTime: Int64;
    LastWriteTime: Int64;
    ChangeTime: Int64;
    EndOfFile: Int64;
    AllocationSize: Int64;
    FileAttributes: Cardinal;
    FileNameLength: Cardinal; // bytes
    EaSize: Cardinal;
    ReparsePointTag: Cardinal;
    FileId: array [0 .. 15] of Byte;
    FileName: array [0 .. 0] of WideChar;
  end;

  PsgcFSearchFileIdExtdDirInfo = ^TsgcFSearchFileIdExtdDirInfo;

function NtOpenFile(out FileHandle: THandle; DesiredAccess: ACCESS_MASK;
  ObjectAttributes: PsgcFSearchObjectAttributes;
  IoStatusBlock: PsgcFSearchIoStatusBlock; ShareAccess: Cardinal;
  OpenOptions: Cardinal): NTSTATUS; stdcall;
function RtlNtStatusToDosError(Status: NTSTATUS): Cardinal; stdcall;
function GetFileInformationByHandleEx(hFile: THandle;
  FileInformationClass: Integer; lpFileInformation: Pointer;
  dwBufferSize: DWORD): BOOL; stdcall;

/// Converts a Win32 path (C:\x, \\?\C:\x) to an NT path (\??\C:\x). A drive
/// root keeps its trailing backslash (\??\C:\ is the root folder, \??\C:
/// would be the volume).
function sgcFSearchToNtPath(const Path: string): string;

/// Opens a folder for listing with NtOpenFile. Parent = 0 opens Name as a
/// full path (Win32 or NT form); Parent <> 0 opens Name relative to that open
/// folder handle. ReadAttributes adds FILE_READ_ATTRIBUTES (for
/// GetFileInformationByHandle on the handle). Returns the NTSTATUS.
function sgcFSearchOpenFolder(Parent: THandle; const Name: string;
  out Handle: THandle; ReadAttributes: Boolean = False): NTSTATUS;

/// Maps an NTSTATUS from sgcFSearchOpenFolder to a list status.
function sgcFSearchNtStatusToListStatus(Status: NTSTATUS)
  : TsgcFSearchListStatus;

/// Lists one open folder handle in bulk (GetFileInformationByHandleEx,
/// FileIdExtdDirectoryInfo with FileIdBothDirectoryInfo fallback for file
/// systems without it) into Items, skipping "." and "..". Buffer is an
/// optional caller-owned buffer of SGCFS_LIST_BUFFER_SIZE bytes (worker
/// threads reuse one; nil allocates a temporary one). Returns ERROR_SUCCESS
/// or the Win32 error code.
function sgcFSearchListDirectory(Handle: THandle;
  out Items: TsgcFSearchListingItems; Buffer: Pointer = nil): Cardinal;

implementation

const
  CS_NTDLL = 'ntdll.dll';

function NtOpenFile; external CS_NTDLL name 'NtOpenFile';
function RtlNtStatusToDosError; external CS_NTDLL name 'RtlNtStatusToDosError';
function GetFileInformationByHandleEx;
  external kernel32 name 'GetFileInformationByHandleEx';

function sgcFSearchToNtPath(const Path: string): string;
begin
  Result := Path;
  if Result.StartsWith('\??\') then
    Exit;
  if Result.StartsWith('\\?\') then
    Result := '\??\' + Copy(Result, 5, MaxInt)
  else if Result.StartsWith('\\') then
    Result := '\??\UNC\' + Copy(Result, 3, MaxInt)
  else
    Result := '\??\' + Result;
  // drive root: keep exactly one trailing backslash
  if (Length(Result) = 6) and (Result[6] = ':') then
    Result := Result + '\';
end;

function sgcFSearchOpenFolder(Parent: THandle; const Name: string;
  out Handle: THandle; ReadAttributes: Boolean): NTSTATUS;
var
  vPath: string;
  vUS: TsgcFSearchUnicodeString;
  vOA: TsgcFSearchObjectAttributes;
  vIOSB: TsgcFSearchIoStatusBlock;
  vAccess: ACCESS_MASK;
begin
  Handle := INVALID_HANDLE_VALUE;
  if Parent = 0 then
    vPath := sgcFSearchToNtPath(Name)
  else
    vPath := Name;
  if (vPath = '') or (Length(vPath) > 32000) then
    Exit(STATUS_OBJECT_NAME_INVALID);
  vUS.Length := Length(vPath) * SizeOf(WideChar);
  vUS.MaximumLength := vUS.Length;
  vUS.Buffer := PWideChar(vPath);
  FillChar(vOA, SizeOf(vOA), 0);
  vOA.Length := SizeOf(vOA);
  vOA.RootDirectory := Parent;
  vOA.ObjectName := @vUS;
  vOA.Attributes := OBJ_CASE_INSENSITIVE;
  vAccess := FILE_LIST_DIRECTORY or SYNCHRONIZE;
  if ReadAttributes then
    vAccess := vAccess or FILE_READ_ATTRIBUTES_ACCESS;
  FillChar(vIOSB, SizeOf(vIOSB), 0);
  Result := NtOpenFile(Handle, vAccess, @vOA, @vIOSB, FILE_SHARE_READ or
    FILE_SHARE_WRITE or FILE_SHARE_DELETE, FILE_DIRECTORY_FILE or
    FILE_SYNCHRONOUS_IO_NONALERT or FILE_OPEN_FOR_BACKUP_INTENT);
  if Result <> STATUS_SUCCESS then
    Handle := INVALID_HANDLE_VALUE;
end;

function sgcFSearchNtStatusToListStatus(Status: NTSTATUS)
  : TsgcFSearchListStatus;
begin
  if Status = STATUS_SUCCESS then
    Result := fslsOK
  else if (Status = STATUS_OBJECT_NAME_NOT_FOUND) or
    (Status = STATUS_OBJECT_PATH_NOT_FOUND) or (Status = STATUS_DELETE_PENDING)
  then
    Result := fslsNotFound
  else if (Status = STATUS_ACCESS_DENIED) or (Status = STATUS_SHARING_VIOLATION)
  then
    Result := fslsAccessDenied
  else if Status = STATUS_NOT_A_DIRECTORY then
    Result := fslsNotADirectory
  else
    Result := fslsError;
end;

function DoIsDotName(P: PWideChar; Len: Integer): Boolean; inline;
begin
  Result := ((Len = 1) and (P[0] = '.')) or
    ((Len = 2) and (P[0] = '.') and (P[1] = '.'));
end;

function sgcFSearchListDirectory(Handle: THandle;
  out Items: TsgcFSearchListingItems; Buffer: Pointer): Cardinal;
var
  vOwnBuffer: Pointer;
  vClass, vCount, vLen: Integer;
  vOfs: Cardinal;
  vP: PByte;
  vExtd: PsgcFSearchFileIdExtdDirInfo;
  vBoth: PsgcFSearchFileIdBothDirInfo;
  vItem: PsgcFSearchListingItem;
begin
  Items := nil;
  vCount := 0;
  vOwnBuffer := nil;
  if Buffer = nil then
  begin
    GetMem(vOwnBuffer, SGCFS_LIST_BUFFER_SIZE);
    Buffer := vOwnBuffer;
  end;
  try
    vClass := FileIdExtdDirectoryInfo;
    SetLength(Items, 64);
    while True do
    begin
      if not GetFileInformationByHandleEx(Handle, vClass, Buffer,
        SGCFS_LIST_BUFFER_SIZE) then
      begin
        Result := GetLastError;
        if Result = ERROR_NO_MORE_FILES then
          Result := ERROR_SUCCESS
        else if (vCount = 0) and (vClass = FileIdExtdDirectoryInfo) and
          ((Result = ERROR_INVALID_PARAMETER) or (Result = ERROR_NOT_SUPPORTED)
          or (Result = ERROR_INVALID_LEVEL)) then
        begin
          // file system without FileIdExtdDirectoryInfo (FAT, some
          // network redirectors): retry with FileIdBothDirectoryInfo
          vClass := FileIdBothDirectoryInfo;
          Continue;
        end;
        Break;
      end;
      vP := Buffer;
      repeat
        if vCount = Length(Items) then
          SetLength(Items, vCount * 2);
        vItem := @Items[vCount];
        if vClass = FileIdExtdDirectoryInfo then
        begin
          vExtd := PsgcFSearchFileIdExtdDirInfo(vP);
          vLen := vExtd.FileNameLength div SizeOf(WideChar);
          vOfs := vExtd.NextEntryOffset;
          if DoIsDotName(@vExtd.FileName[0], vLen) then
          begin
            Inc(vP, vOfs);
            Continue;
          end;
          SetString(vItem.Name, PWideChar(@vExtd.FileName[0]), vLen);
          vItem.Attributes := vExtd.FileAttributes;
          vItem.ReparseTag := vExtd.ReparsePointTag;
          vItem.Size := vExtd.EndOfFile;
          vItem.MTime := vExtd.LastWriteTime;
          vItem.FileId := PUInt64(@vExtd.FileId[0])^;
        end
        else
        begin
          vBoth := PsgcFSearchFileIdBothDirInfo(vP);
          vLen := vBoth.FileNameLength div SizeOf(WideChar);
          vOfs := vBoth.NextEntryOffset;
          if DoIsDotName(@vBoth.FileName[0], vLen) then
          begin
            Inc(vP, vOfs);
            Continue;
          end;
          SetString(vItem.Name, PWideChar(@vBoth.FileName[0]), vLen);
          vItem.Attributes := vBoth.FileAttributes;
          if (vBoth.FileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
            vItem.ReparseTag := vBoth.EaSize
          else
            vItem.ReparseTag := 0;
          vItem.Size := vBoth.EndOfFile;
          vItem.MTime := vBoth.LastWriteTime;
          vItem.FileId := UInt64(vBoth.FileId);
        end;
        if (vItem.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          vItem.Size := 0;
        Inc(vCount);
        Inc(vP, vOfs);
      until vOfs = 0;
    end;
  finally
    if vOwnBuffer <> nil then
      FreeMem(vOwnBuffer);
  end;
  SetLength(Items, vCount);
end;

end.
