{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Config;

{$I sgcVer.inc}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils,
  System.Generics.Collections,
  // sgc
  sgcFSearch_Types;

const
  SGCFS_CONFIG_FILE = 'config.json';
  SGCFS_INDEX_FILE = 'names.idx';
  SGCFS_LOG_FILE = 'daemon.log';
  SGCFS_SAVED_FILTERS_FILE = 'saved_filters.json';
  SGCFS_HOME_ENV = 'SGCFSEARCH_HOME'; // overrides the data folder (tests)
  SGCFS_PORTABLE_MARKER = 'sgcFSearch.portable'; // next to the exe: portable

type
  /// One entry of the Saved chip of the search bar.
  TsgcFSearchSavedFilter = record
    Name: string;
    Query: string;
  end;

  /// User settings, stored as DataDir\config.json:
  /// {"roots":["~"],"skip":[],"hotkey":"Alt+Shift+Space","drives":[],
  /// "content_max_size_mb":16,"content_case":"insensitive"}
  TsgcFSearchConfig = class
  private
    FRoots: TArray<string>;
    FSkip: TArray<string>;
    FHotkey: string;
    FDrives: TArray<string>;
    FContentMaxSizeMB: Integer;
    FContentCase: TsgcFSearchGrepCase;
  public
    constructor Create;
    /// Restores the defaults.
    procedure SetDefaults;
    /// Loads a JSON file; keys not present keep their current value, except
    /// content_case, where a missing key means insensitive. Returns False
    /// (settings unchanged) if the file is missing or not valid JSON.
    function LoadFromFile(const FileName: string): Boolean;
    /// Writes the JSON file (UTF-8, no BOM, temp file + replace).
    procedure SaveToFile(const FileName: string);
    /// Roots / Skip with '~' expanded (ExpandUserPath).
    function ExpandedRoots: TArray<string>;
    function ExpandedSkip: TArray<string>;
    /// Content-index roots, default ['~'] (may contain '~').
    property Roots: TArray<string> read FRoots write FRoots;
    /// Folders never opened by the crawler (may contain '~').
    property Skip: TArray<string> read FSkip write FSkip;
    /// Global hotkey of the search bar, default 'Alt+Shift+Space'.
    property Hotkey: string read FHotkey write FHotkey;
    /// Drives to index ('C:\' ...); empty = all fixed drives.
    property Drives: TArray<string> read FDrives write FDrives;
    /// Content indexing size cap per file, default 16 MB.
    property ContentMaxSizeMB: Integer read FContentMaxSizeMB
      write FContentMaxSizeMB;
    /// Content search case: insensitive (default), smart (a capital letter
    /// in the search text makes it case sensitive) or sensitive. The engine
    /// reads it at start, a hand edit takes effect at the next start.
    property ContentCase: TsgcFSearchGrepCase read FContentCase
      write FContentCase;
  end;

  /// Data folder of the running exe, see sgcFSearchDataDirFor. Created when
  /// missing. No trailing backslash.
function sgcFSearchDataDir: string;
/// Data folder for an exe folder, in this order: %SGCFSEARCH_HOME%, the
/// portable folder of ExeDir, %LOCALAPPDATA%\sgcFSearch. Creates nothing.
/// No trailing backslash.
function sgcFSearchDataDirFor(const ExeDir: string): string;
/// Folder of the running exe.
function sgcFSearchExeDir: string;
/// ExeDir\data\<computer name> when the file sgcFSearch.portable is in ExeDir
/// (any content, a folder with that name does not count), else ''. Creates
/// nothing.
function sgcFSearchPortableDataDir(const ExeDir: string): string;
/// True when the file sgcFSearch.portable is next to the running exe.
function sgcFSearchIsPortable: Boolean;
/// Name with the characters a folder name cannot hold replaced by '_', the
/// trailing dots and spaces removed and reserved device names prefixed.
function sgcFSearchSafeFolderName(const Name: string): string;
/// '~' or '~\x' -> %USERPROFILE% or %USERPROFILE%\x; other paths unchanged.
function sgcFSearchExpandUserPath(const Path: string): string;
/// DataDir\config.json, DataDir\names.idx, DataDir\daemon.log
function sgcFSearchConfigFileName: string;
function sgcFSearchIndexFileName: string;
function sgcFSearchLogFileName: string;
/// DataDir\saved_filters.json
function sgcFSearchSavedFiltersFileName: string;
/// Reads [{"name":"...","query":"..."}]. A missing or invalid file gives an
/// empty list, entries without a name or a query are skipped.
function sgcFSearchLoadSavedFilters(const FileName: string)
  : TArray<TsgcFSearchSavedFilter>;
/// Writes the list (UTF-8, no BOM, temp file + replace).
procedure sgcFSearchSaveSavedFilters(const FileName: string;
  const Filters: TArray<TsgcFSearchSavedFilter>);

implementation

uses
  System.StrUtils,
  // sgc
  sgcFSearch_Log;

const
  CS_DEFAULT_HOTKEY = 'Alt+Shift+Space';
  CS_DEFAULT_CONTENT_MAX_MB = 16;
  CS_CONTENT_CASE: array [TsgcFSearchGrepCase] of string = ('insensitive',
    'smart', 'sensitive');

function DoGetEnv(const Name: string): string;
begin
  Result := GetEnvironmentVariable(Name);
end;

function sgcFSearchExeDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

function sgcFSearchSafeFolderName(const Name: string): string;
var
  i: Integer;
  vUpper: string;
begin
  Result := Name;
  for i := 1 to Length(Result) do
    if (Result[i] < ' ') or CharInSet(Result[i], ['<', '>', ':', '"', '/', '\',
      '|', '?', '*']) then
      Result[i] := '_';
  while (Result <> '') and CharInSet(Result[Length(Result)], ['.', ' ']) do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then
    Exit('unknown');
  vUpper := UpperCase(Result);
  if (IndexStr(vUpper, ['CON', 'PRN', 'AUX', 'NUL']) >= 0) or
    ((Length(vUpper) = 4) and (IndexStr(Copy(vUpper, 1, 3), ['COM', 'LPT']) >=
    0) and CharInSet(vUpper[4], ['0' .. '9'])) then
    Result := '_' + Result;
end;

function DoComputerName: string;
var
  vBuf: array [0 .. MAX_COMPUTERNAME_LENGTH] of Char;
  vSize: DWORD;
begin
  vSize := Length(vBuf);
  if GetComputerName(vBuf, vSize) then
    SetString(Result, vBuf, vSize)
  else
    Result := '';
  Result := sgcFSearchSafeFolderName(Result);
end;

function sgcFSearchPortableDataDir(const ExeDir: string): string;
var
  vDir: string;
begin
  Result := '';
  vDir := IncludeTrailingPathDelimiter(ExeDir);
  // FileExists is False for a folder with that name
  if FileExists(vDir + SGCFS_PORTABLE_MARKER) then
    Result := vDir + 'data\' + DoComputerName;
end;

function sgcFSearchIsPortable: Boolean;
begin
  Result := sgcFSearchPortableDataDir(sgcFSearchExeDir) <> '';
end;

function sgcFSearchDataDirFor(const ExeDir: string): string;
begin
  Result := DoGetEnv(SGCFS_HOME_ENV);
  if Result = '' then
    Result := sgcFSearchPortableDataDir(ExeDir);
  if Result = '' then
  begin
    Result := DoGetEnv('LOCALAPPDATA');
    if Result = '' then
      Result := TPath.GetHomePath;
    Result := IncludeTrailingPathDelimiter(Result) + 'sgcFSearch';
  end;
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function sgcFSearchDataDir: string;
begin
  Result := sgcFSearchDataDirFor(sgcFSearchExeDir);
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function sgcFSearchExpandUserPath(const Path: string): string;
var
  vHome: string;
begin
  Result := Path;
  if (Result = '') or (Result[1] <> '~') then
    Exit;
  if (Length(Result) > 1) and (Result[2] <> '\') and (Result[2] <> '/') then
    Exit;
  vHome := ExcludeTrailingPathDelimiter(DoGetEnv('USERPROFILE'));
  if vHome = '' then
    Exit;
  Result := vHome + Copy(Result, 2, MaxInt);
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
end;

function sgcFSearchConfigFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(sgcFSearchDataDir) + SGCFS_CONFIG_FILE;
end;

function sgcFSearchIndexFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(sgcFSearchDataDir) + SGCFS_INDEX_FILE;
end;

function sgcFSearchLogFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(sgcFSearchDataDir) + SGCFS_LOG_FILE;
end;

function sgcFSearchSavedFiltersFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(sgcFSearchDataDir) +
    SGCFS_SAVED_FILTERS_FILE;
end;

function DoReadStrings(aObj: TJSONObject; const Key: string;
  var Value: TArray<string>): Boolean;
var
  vVal: TJSONValue;
  vArr: TJSONArray;
  i: Integer;
begin
  Result := False;
  vVal := aObj.GetValue(Key);
  if not(vVal is TJSONArray) then
    Exit;
  vArr := TJSONArray(vVal);
  SetLength(Value, 0);
  for i := 0 to vArr.Count - 1 do
    if vArr.Items[i] is TJSONString then
      Value := Value + [TJSONString(vArr.Items[i]).Value];
  Result := True;
end;

function DoStringsToJSON(const Value: TArray<string>): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to Length(Value) - 1 do
    Result.Add(Value[i]);
end;

function DoReadContentCase(const Text: string;
  var Value: TsgcFSearchGrepCase): Boolean;
var
  i: TsgcFSearchGrepCase;
begin
  Result := False;
  for i := Low(TsgcFSearchGrepCase) to High(TsgcFSearchGrepCase) do
    if SameText(Text, CS_CONTENT_CASE[i]) then
    begin
      Value := i;
      Exit(True);
    end;
end;

{ TsgcFSearchConfig }

constructor TsgcFSearchConfig.Create;
begin
  inherited Create;
  SetDefaults;
end;

procedure TsgcFSearchConfig.SetDefaults;
begin
  FRoots := ['~'];
  FSkip := nil;
  FHotkey := CS_DEFAULT_HOTKEY;
  FDrives := nil;
  FContentMaxSizeMB := CS_DEFAULT_CONTENT_MAX_MB;
  FContentCase := fsgcInsensitive;
end;

function TsgcFSearchConfig.ExpandedRoots: TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Length(FRoots));
  for i := 0 to Length(FRoots) - 1 do
    Result[i] := sgcFSearchExpandUserPath(FRoots[i]);
end;

function TsgcFSearchConfig.ExpandedSkip: TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Length(FSkip));
  for i := 0 to Length(FSkip) - 1 do
    Result[i] := sgcFSearchExpandUserPath(FSkip[i]);
end;

function TsgcFSearchConfig.LoadFromFile(const FileName: string): Boolean;
var
  vBytes: TBytes;
  vText: string;
  vJSON: TJSONValue;
  vObj: TJSONObject;
  vVal: TJSONValue;
  vOfs: Integer;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  try
    vBytes := TFile.ReadAllBytes(FileName);
  except
    Exit;
  end;
  vOfs := 0;
  if (Length(vBytes) >= 3) and (vBytes[0] = $EF) and (vBytes[1] = $BB) and
    (vBytes[2] = $BF) then
    vOfs := 3;
  vText := TEncoding.UTF8.GetString(vBytes, vOfs, Length(vBytes) - vOfs);
  vJSON := TJSONObject.ParseJSONValue(vText);
  if vJSON = nil then
    Exit;
  try
    if not(vJSON is TJSONObject) then
      Exit;
    vObj := TJSONObject(vJSON);
    DoReadStrings(vObj, 'roots', FRoots);
    DoReadStrings(vObj, 'skip', FSkip);
    DoReadStrings(vObj, 'drives', FDrives);
    vVal := vObj.GetValue('hotkey');
    if vVal is TJSONString then
      FHotkey := TJSONString(vVal).Value;
    vVal := vObj.GetValue('content_max_size_mb');
    if vVal is TJSONNumber then
      FContentMaxSizeMB := TJSONNumber(vVal).AsInt;
    // a missing or unknown value means insensitive, never the previous one
    FContentCase := fsgcInsensitive;
    vVal := vObj.GetValue('content_case');
    if (vVal <> nil) and not DoReadContentCase(vVal.Value, FContentCase) then
      sgcFSearchLog('config: unknown content_case value: ' + vVal.ToJSON);
    Result := True;
  finally
    vJSON.Free;
  end;
end;

procedure TsgcFSearchConfig.SaveToFile(const FileName: string);
var
  vObj: TJSONObject;
  vTmp: string;
begin
  vObj := TJSONObject.Create;
  try
    vObj.AddPair('roots', DoStringsToJSON(FRoots));
    vObj.AddPair('skip', DoStringsToJSON(FSkip));
    vObj.AddPair('hotkey', FHotkey);
    vObj.AddPair('drives', DoStringsToJSON(FDrives));
    vObj.AddPair('content_max_size_mb', TJSONNumber.Create(FContentMaxSizeMB));
    vObj.AddPair('content_case', CS_CONTENT_CASE[FContentCase]);
    vTmp := FileName + '.tmp';
    TFile.WriteAllBytes(vTmp, TEncoding.UTF8.GetBytes(vObj.Format(2)));
  finally
    vObj.Free;
  end;
  if not MoveFileEx(PChar(vTmp), PChar(FileName), MOVEFILE_REPLACE_EXISTING or
    MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function sgcFSearchLoadSavedFilters(const FileName: string)
  : TArray<TsgcFSearchSavedFilter>;
var
  vBytes: TBytes;
  vOfs, i: Integer;
  vJSON: TJSONValue;
  vArr: TJSONArray;
  vItem: TsgcFSearchSavedFilter;

  function ReadText(aObj: TJSONObject; const aKey: string): string;
  var
    vVal: TJSONValue;
  begin
    vVal := aObj.GetValue(aKey);
    if vVal is TJSONString then
      Result := TJSONString(vVal).Value
    else
      Result := '';
  end;

begin
  Result := nil;
  if not FileExists(FileName) then
    Exit;
  try
    vBytes := TFile.ReadAllBytes(FileName);
    vOfs := 0;
    if (Length(vBytes) >= 3) and (vBytes[0] = $EF) and (vBytes[1] = $BB) and
      (vBytes[2] = $BF) then
      vOfs := 3;
    vJSON := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(vBytes, vOfs,
      Length(vBytes) - vOfs));
  except
    Exit;
  end;
  if vJSON = nil then
    Exit;
  try
    if not(vJSON is TJSONArray) then
      Exit;
    vArr := TJSONArray(vJSON);
    for i := 0 to vArr.Count - 1 do
      if vArr.Items[i] is TJSONObject then
      begin
        vItem.Name := ReadText(TJSONObject(vArr.Items[i]), 'name');
        vItem.Query := ReadText(TJSONObject(vArr.Items[i]), 'query');
        if (Trim(vItem.Name) <> '') and (Trim(vItem.Query) <> '') then
          Result := Result + [vItem];
      end;
  finally
    vJSON.Free;
  end;
end;

procedure sgcFSearchSaveSavedFilters(const FileName: string;
  const Filters: TArray<TsgcFSearchSavedFilter>);
var
  vArr: TJSONArray;
  vObj: TJSONObject;
  vTmp: string;
  i: Integer;
begin
  vTmp := FileName + '.tmp';
  vArr := TJSONArray.Create;
  try
    for i := 0 to High(Filters) do
    begin
      vObj := TJSONObject.Create;
      vArr.AddElement(vObj);
      vObj.AddPair('name', Filters[i].Name);
      vObj.AddPair('query', Filters[i].Query);
    end;
    TFile.WriteAllBytes(vTmp, TEncoding.UTF8.GetBytes(vArr.Format(2)));
  finally
    vArr.Free;
  end;
  if not MoveFileEx(PChar(vTmp), PChar(FileName), MOVEFILE_REPLACE_EXISTING or
    MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

end.
