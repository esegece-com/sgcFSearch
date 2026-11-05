{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Usage;

{$I sgcVer.inc}
{ Frecency: paths the user opened or copied, a count weighted score with an
  exponential decay (14 day half-life). Thread-safe. Persisted to
  DataDir\usage.json (written to a temp file, then MoveFileEx). Capped at
  SGCFS_USAGE_MAX paths, the lowest scores are dropped. Path keys are case
  insensitive. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults, System.JSON,
  System.IOUtils, System.Math,
  // sgc
  sgcFSearch_Types, sgcFSearch_Match, sgcFSearch_Config;

const
  SGCFS_USAGE_FILE = 'usage.json';
  SGCFS_USAGE_MAX = 4000;
  SGCFS_USAGE_HALF_LIFE_DAYS = 14;
  SGCFS_USAGE_WEIGHT_OPEN = 1.0;
  SGCFS_USAGE_WEIGHT_COPY = 0.7;

type
  TsgcFSearchUsageKind = (fsukOpen, fsukCopy);

  TsgcFSearchUsageItem = record
    Path: string;
    Boost: Single;
  end;

  TsgcFSearchUsage = class
  private type
    TEntry = record
      Path: string;
      Score: Double; // decayed score as of Stamp
      Stamp: Int64; // FILETIME UTC
    end;

  var
    FLock: TCriticalSection;
    FItems: TDictionary<string, TEntry>;
    FFileName: string;
    FVersion: Int64;
    class function DoDecay(const E: TEntry; Now: Int64): Double; static;
    procedure DoPrune(Now: Int64);
    function DoToJSON: string;
    function GetVersion: Int64;
  public
    /// FileName '' = sgcFSearchDataDir\usage.json. Loads the file.
    constructor Create(const FileName: string = '');
    destructor Destroy; override;
    /// Records one use (open or copy) now, then saves the file. ("Record"
    /// is a reserved word.)
    procedure RecordUse(const Path: string;
      Kind: TsgcFSearchUsageKind); overload;
    /// Time = FILETIME UTC of the use; Save = False skips the file write.
    procedure RecordUse(const Path: string; Kind: TsgcFSearchUsageKind;
      Time: Int64; Save: Boolean); overload;
    /// Decayed score now, 0 when unknown.
    function Boost(const Path: string): Single;
    /// All paths with their current boost.
    function Snapshot: TArray<TsgcFSearchUsageItem>;
    function Count: Integer;
    procedure Clear;
    /// Replaces the content with the file (False when missing / invalid).
    function Load: Boolean;
    /// Writes the file, False on error (never raises).
    function Save: Boolean;
    property FileName: string read FFileName;
    /// Incremented on every change (RecordUse, Clear, Load).
    property Version: Int64 read GetVersion;
  end;

implementation

const
  CS_FT_PER_DAY = Int64(864000000000); // 100 ns units per day

  { TsgcFSearchUsage }

constructor TsgcFSearchUsage.Create(const FileName: string = '');
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TDictionary<string, TEntry>.Create;
  if FileName <> '' then
    FFileName := FileName
  else
    FFileName := IncludeTrailingPathDelimiter(sgcFSearchDataDir) +
      SGCFS_USAGE_FILE;
  Load;
end;

destructor TsgcFSearchUsage.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

function TsgcFSearchUsage.GetVersion: Int64;
begin
  Result := TInterlocked.Read(FVersion);
end;

class function TsgcFSearchUsage.DoDecay(const E: TEntry; Now: Int64): Double;
var
  vDays: Double;
begin
  vDays := (Now - E.Stamp) / CS_FT_PER_DAY;
  if vDays <= 0 then
    Result := E.Score
  else
    Result := E.Score * Power(0.5, vDays / SGCFS_USAGE_HALF_LIFE_DAYS);
end;

procedure TsgcFSearchUsage.DoPrune(Now: Int64);
var
  vKeys: TArray<string>;
  vScores, vSorted: TArray<Double>;
  vPair: TPair<string, TEntry>;
  i, n, vDrop: Integer;
  vCut: Double;
begin
  if FItems.Count <= SGCFS_USAGE_MAX then
    Exit;
  n := FItems.Count;
  SetLength(vKeys, n);
  SetLength(vScores, n);
  i := 0;
  for vPair in FItems do
  begin
    vKeys[i] := vPair.Key;
    vScores[i] := DoDecay(vPair.Value, Now);
    Inc(i);
  end;
  // drop the lowest down to 90 % so pruning does not run on every record
  vDrop := n - (SGCFS_USAGE_MAX * 9 div 10);
  vSorted := Copy(vScores);
  TArray.Sort<Double>(vSorted);
  vCut := vSorted[vDrop - 1];
  for i := 0 to n - 1 do
    if (vDrop > 0) and (vScores[i] <= vCut) then
    begin
      FItems.Remove(vKeys[i]);
      Dec(vDrop);
    end;
end;

procedure TsgcFSearchUsage.RecordUse(const Path: string;
  Kind: TsgcFSearchUsageKind; Time: Int64; Save: Boolean);
var
  vKey: string;
  vE: TEntry;
  vW: Double;
begin
  if Path = '' then
    Exit;
  vKey := sgcFSearchFold(Path);
  if Kind = fsukCopy then
    vW := SGCFS_USAGE_WEIGHT_COPY
  else
    vW := SGCFS_USAGE_WEIGHT_OPEN;
  FLock.Enter;
  try
    if FItems.TryGetValue(vKey, vE) then
    begin
      if Time >= vE.Stamp then
      begin
        vE.Score := DoDecay(vE, Time) + vW;
        vE.Stamp := Time;
      end
      else // an older use: add it decayed to the current stamp
        vE.Score := vE.Score + vW * Power(0.5, (vE.Stamp - Time) / CS_FT_PER_DAY
          / SGCFS_USAGE_HALF_LIFE_DAYS);
      vE.Path := Path;
    end
    else
    begin
      vE.Path := Path;
      vE.Score := vW;
      vE.Stamp := Time;
    end;
    FItems.AddOrSetValue(vKey, vE);
    DoPrune(Time);
    TInterlocked.Increment(FVersion);
  finally
    FLock.Leave;
  end;
  if Save then
    Self.Save;
end;

procedure TsgcFSearchUsage.RecordUse(const Path: string;
  Kind: TsgcFSearchUsageKind);
begin
  RecordUse(Path, Kind, sgcFSearchNowFileTime, True);
end;

function TsgcFSearchUsage.Boost(const Path: string): Single;
var
  vE: TEntry;
begin
  Result := 0;
  FLock.Enter;
  try
    if FItems.TryGetValue(sgcFSearchFold(Path), vE) then
      Result := DoDecay(vE, sgcFSearchNowFileTime);
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchUsage.Snapshot: TArray<TsgcFSearchUsageItem>;
var
  vNow: Int64;
  vE: TEntry;
  n: Integer;
begin
  vNow := sgcFSearchNowFileTime;
  FLock.Enter;
  try
    SetLength(Result, FItems.Count);
    n := 0;
    for vE in FItems.Values do
    begin
      Result[n].Path := vE.Path;
      Result[n].Boost := DoDecay(vE, vNow);
      Inc(n);
    end;
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchUsage.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FItems.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TsgcFSearchUsage.Clear;
begin
  FLock.Enter;
  try
    FItems.Clear;
    TInterlocked.Increment(FVersion);
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchUsage.DoToJSON: string;
var
  vRoot, vObj: TJSONObject;
  vArr: TJSONArray;
  vE: TEntry;
begin
  vRoot := TJSONObject.Create;
  try
    vRoot.AddPair('version', TJSONNumber.Create(1));
    vArr := TJSONArray.Create;
    vRoot.AddPair('items', vArr);
    for vE in FItems.Values do
    begin
      vObj := TJSONObject.Create;
      vObj.AddPair('path', vE.Path);
      vObj.AddPair('score', TJSONNumber.Create(vE.Score));
      vObj.AddPair('stamp', TJSONNumber.Create(vE.Stamp));
      vArr.AddElement(vObj);
    end;
    Result := vRoot.ToJSON;
  finally
    vRoot.Free;
  end;
end;

function TsgcFSearchUsage.Save: Boolean;
var
  vTmp: string;
  vBytes: TBytes;
begin
  try
    FLock.Enter;
    try
      vBytes := TEncoding.UTF8.GetBytes(DoToJSON);
      vTmp := FFileName + '.tmp';
      ForceDirectories(ExtractFileDir(FFileName));
      TFile.WriteAllBytes(vTmp, vBytes);
      Result := MoveFileEx(PChar(vTmp), PChar(FFileName),
        MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH);
    finally
      FLock.Leave;
    end;
  except
    Result := False;
  end;
end;

function TsgcFSearchUsage.Load: Boolean;
var
  vValue, vItems: TJSONValue;
  vItem: TJSONValue;
  vE: TEntry;
  vNew: TDictionary<string, TEntry>;
  vPath: string;
begin
  Result := False;
  if not FileExists(FFileName) then
    Exit;
  vNew := TDictionary<string, TEntry>.Create;
  try
    try
      vValue := TJSONObject.ParseJSONValue(TFile.ReadAllText(FFileName,
        TEncoding.UTF8));
      if vValue = nil then
        Exit;
      try
        if not(vValue is TJSONObject) then
          Exit;
        vItems := TJSONObject(vValue).GetValue('items');
        if not(vItems is TJSONArray) then
          Exit;
        for vItem in TJSONArray(vItems) do
        begin
          if not(vItem is TJSONObject) then
            Continue;
          vPath := TJSONObject(vItem).GetValue<string>('path', '');
          if vPath = '' then
            Continue;
          vE.Path := vPath;
          vE.Score := TJSONObject(vItem).GetValue<Double>('score', 0);
          vE.Stamp := TJSONObject(vItem).GetValue<Int64>('stamp', 0);
          if vE.Score > 0 then
            vNew.AddOrSetValue(sgcFSearchFold(vPath), vE);
        end;
      finally
        vValue.Free;
      end;
      FLock.Enter;
      try
        FItems.Clear;
        for vPath in vNew.Keys do
          FItems.Add(vPath, vNew[vPath]);
        DoPrune(sgcFSearchNowFileTime);
        TInterlocked.Increment(FVersion);
      finally
        FLock.Leave;
      end;
      Result := True;
    except
      Result := False;
    end;
  finally
    vNew.Free;
  end;
end;

end.
