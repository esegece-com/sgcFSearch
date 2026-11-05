{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Types;

{$I sgcVer.inc}

interface

uses
  Winapi.Windows, System.SysUtils;

const
  // Entry flags (TsgcFSearchEntry.Flags, Word).
  SGCFS_FLAG_DIR = $0001; // folder
  SGCFS_FLAG_REPARSE = $0002; // name surrogate reparse point (junction,
  // symlink, mount point): recorded, never entered
  SGCFS_FLAG_HIDDEN = $0004; // FILE_ATTRIBUTE_HIDDEN
  SGCFS_FLAG_SYSTEM = $0008; // FILE_ATTRIBUTE_SYSTEM
  SGCFS_FLAG_READONLY = $0010; // FILE_ATTRIBUTE_READONLY
  SGCFS_FLAG_DELETED = $0020; // tombstone: slot is dead, skip it
  SGCFS_FLAG_OFFLINE = $0040; // offline / cloud placeholder (OFFLINE,
  // RECALL_ON_OPEN, RECALL_ON_DATA_ACCESS): content not local
  SGCFS_FLAG_ROOT = $0080; // root entry (ParentIdx = -1), name = root path
  SGCFS_FLAG_DENIED = $0100; // folder could not be opened (access denied)
  SGCFS_FLAG_SKIPPED = $0200; // folder in the skip list, never opened

  // Flags derived from the file attributes (compared by the listing diff).
  SGCFS_FLAGS_ATTR = SGCFS_FLAG_DIR or SGCFS_FLAG_REPARSE or
    SGCFS_FLAG_HIDDEN or SGCFS_FLAG_SYSTEM or SGCFS_FLAG_READONLY or
    SGCFS_FLAG_OFFLINE;

  // Attribute bits not always declared by Winapi.Windows.
  SGCFS_ATTR_RECALL_ON_OPEN = $00040000;
  SGCFS_ATTR_RECALL_ON_DATA_ACCESS = $00400000;
  // Reparse tag bit of name surrogates (junction, symlink, mount point).
  SGCFS_REPARSE_NAME_SURROGATE = $20000000;

type
  /// One item of a bulk folder listing (see sgcFSearchListDirectory).
  TsgcFSearchListingItem = record
    Name: string; // file name only, exact case
    Attributes: Cardinal; // FILE_ATTRIBUTE_*
    ReparseTag: Cardinal; // IO_REPARSE_TAG_* when FILE_ATTRIBUTE_REPARSE_POINT
    Size: Int64; // EndOfFile in bytes (0 for folders)
    MTime: Int64; // LastWriteTime, FILETIME UTC (100 ns since 1601)
    FileId: UInt64; // 64 bit file reference number (with sequence)
  end;

  PsgcFSearchListingItem = ^TsgcFSearchListingItem;
  TsgcFSearchListingItems = TArray<TsgcFSearchListingItem>;

  /// Result of opening + listing one folder.
  TsgcFSearchListStatus = (fslsOK, // listed
    fslsNotFound, // folder (or a parent) does not exist any more
    fslsAccessDenied, // exists but cannot be opened / listed
    fslsNotADirectory, // the path is a file
    fslsError); // any other failure (or cancelled)

  /// Maps file attributes + reparse tag to SGCFS_FLAG_* bits. Only name
  /// surrogate reparse points get SGCFS_FLAG_REPARSE; cloud placeholders and
  /// other reparse tags are plain files / folders (SGCFS_FLAG_OFFLINE if not
  /// local).
function sgcFSearchAttributesToFlags(Attributes, ReparseTag: Cardinal): Word;
/// True for junctions, symlinks and mount points.
function sgcFSearchIsNameSurrogate(ReparseTag: Cardinal): Boolean; inline;

/// FILETIME UTC (Int64) <-> TDateTime in UTC.
function sgcFSearchFileTimeToDateTimeUTC(FileTime: Int64): TDateTime;
function sgcFSearchDateTimeUTCToFileTime(const DateTime: TDateTime): Int64;
/// FILETIME UTC (Int64) <-> TDateTime in local time (DST of that date).
function sgcFSearchFileTimeToLocalDateTime(FileTime: Int64): TDateTime;
function sgcFSearchLocalDateTimeToFileTime(const DateTime: TDateTime): Int64;
/// Current time as FILETIME UTC.
function sgcFSearchNowFileTime: Int64;

implementation

const
  CS_FILETIME_PER_DAY = 864000000000; // 100 ns ticks per day
  CS_FILETIME_EPOCH = -109205.0; // EncodeDate(1601, 1, 1)

function sgcFSearchIsNameSurrogate(ReparseTag: Cardinal): Boolean;
begin
  Result := (ReparseTag and SGCFS_REPARSE_NAME_SURROGATE) <> 0;
end;

function sgcFSearchAttributesToFlags(Attributes, ReparseTag: Cardinal): Word;
begin
  Result := 0;
  if (Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    Result := Result or SGCFS_FLAG_DIR;
  if ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) and
    sgcFSearchIsNameSurrogate(ReparseTag) then
    Result := Result or SGCFS_FLAG_REPARSE;
  if (Attributes and FILE_ATTRIBUTE_HIDDEN) <> 0 then
    Result := Result or SGCFS_FLAG_HIDDEN;
  if (Attributes and FILE_ATTRIBUTE_SYSTEM) <> 0 then
    Result := Result or SGCFS_FLAG_SYSTEM;
  if (Attributes and FILE_ATTRIBUTE_READONLY) <> 0 then
    Result := Result or SGCFS_FLAG_READONLY;
  if (Attributes and (FILE_ATTRIBUTE_OFFLINE or SGCFS_ATTR_RECALL_ON_OPEN or
    SGCFS_ATTR_RECALL_ON_DATA_ACCESS)) <> 0 then
    Result := Result or SGCFS_FLAG_OFFLINE;
end;

function sgcFSearchFileTimeToDateTimeUTC(FileTime: Int64): TDateTime;
begin
  Result := CS_FILETIME_EPOCH + FileTime / CS_FILETIME_PER_DAY;
end;

function sgcFSearchDateTimeUTCToFileTime(const DateTime: TDateTime): Int64;
begin
  Result := Round((DateTime - CS_FILETIME_EPOCH) * CS_FILETIME_PER_DAY);
end;

function sgcFSearchFileTimeToLocalDateTime(FileTime: Int64): TDateTime;
var
  vUTC, vLocal: TSystemTime;
begin
  if FileTimeToSystemTime(TFileTime(FileTime), vUTC) and
    SystemTimeToTzSpecificLocalTime(nil, vUTC, vLocal) then
    Result := SystemTimeToDateTime(vLocal)
  else
    Result := sgcFSearchFileTimeToDateTimeUTC(FileTime);
end;

function sgcFSearchLocalDateTimeToFileTime(const DateTime: TDateTime): Int64;
var
  vUTC, vLocal: TSystemTime;
  vFT: TFileTime;
begin
  DateTimeToSystemTime(DateTime, vLocal);
  if TzSpecificLocalTimeToSystemTime(nil, vLocal, vUTC) and
    SystemTimeToFileTime(vUTC, vFT) then
    Result := Int64(vFT)
  else
    Result := sgcFSearchDateTimeUTCToFileTime(DateTime);
end;

function sgcFSearchNowFileTime: Int64;
var
  vFT: TFileTime;
begin
  GetSystemTimeAsFileTime(vFT);
  Result := Int64(vFT);
end;

end.
