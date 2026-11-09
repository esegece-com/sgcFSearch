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
  SGCFS_HOME_ENV = 'SGCFSEARCH_HOME'; // overrides the data folder (tests)

type
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

  /// Data folder: %SGCFSEARCH_HOME% if set, else %LOCALAPPDATA%\sgcFSearch.
  /// Created when missing. No trailing backslash.
function sgcFSearchDataDir: string;
/// '~' or '~\x' -> %USERPROFILE% or %USERPROFILE%\x; other paths unchanged.
function sgcFSearchExpandUserPath(const Path: string): string;
/// DataDir\config.json, DataDir\names.idx, DataDir\daemon.log
function sgcFSearchConfigFileName: string;
function sgcFSearchIndexFileName: string;
function sgcFSearchLogFileName: string;

implementation

uses
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

function sgcFSearchDataDir: string;
begin
  Result := DoGetEnv(SGCFS_HOME_ENV);
  if Result = '' then
  begin
    Result := DoGetEnv('LOCALAPPDATA');
    if Result = '' then
      Result := TPath.GetHomePath;
    Result := IncludeTrailingPathDelimiter(Result) + 'sgcFSearch';
  end;
  Result := ExcludeTrailingPathDelimiter(Result);
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

end.
