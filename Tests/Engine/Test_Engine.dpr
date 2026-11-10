{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Engine;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.JSON, System.SyncObjs, System.Diagnostics, System.StrUtils,
  System.Generics.Collections,
  // sgc
  sgcFSearch_Types in '..\..\Source\sgcFSearch_Types.pas',
  sgcFSearch_NtApi in '..\..\Source\sgcFSearch_NtApi.pas',
  sgcFSearch_Index in '..\..\Source\sgcFSearch_Index.pas',
  sgcFSearch_Crawler in '..\..\Source\sgcFSearch_Crawler.pas',
  sgcFSearch_Config in '..\..\Source\sgcFSearch_Config.pas',
  sgcFSearch_Log in '..\..\Source\sgcFSearch_Log.pas',
  sgcFSearch_Watcher in '..\..\Source\sgcFSearch_Watcher.pas',
  sgcFSearch_Journal in '..\..\Source\sgcFSearch_Journal.pas',
  sgcFSearch_Match in '..\..\Source\sgcFSearch_Match.pas',
  sgcFSearch_Query in '..\..\Source\sgcFSearch_Query.pas',
  sgcFSearch_Usage in '..\..\Source\sgcFSearch_Usage.pas',
  sgcFSearch_Search in '..\..\Source\sgcFSearch_Search.pas',
  sgcFSearch_Extract in '..\..\Source\sgcFSearch_Extract.pas',
  sgcFSearch_Trigram in '..\..\Source\sgcFSearch_Trigram.pas',
  sgcFSearch_Grep in '..\..\Source\sgcFSearch_Grep.pas',
  sgcFSearch_Engine in '..\..\Source\sgcFSearch_Engine.pas';

const
  CS_FILES = 309;
  CS_FOLDERS = 13;
  CS_PAS = 'unit Widget;'#13#10'interface'#13#10'type'#13#10 +
    '  TWidgetFrobber = class'#13#10'  end;'#13#10 +
    'procedure FrobnicateAll;'#13#10'implementation'#13#10 +
    'procedure FrobnicateAll;'#13#10'begin'#13#10'end;'#13#10'end.'#13#10;

type
  TRecorder = class
  public
    Lock: TCriticalSection;
    States: TStringList;
    Changes: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure OnState(Sender: TObject; State: TsgcFSearchEngineState);
    procedure OnChanged(Sender: TObject; Generation: Int64);
    function Text: string;
  end;

var
  GChecks, GFails: Integer;
  GBase, GTree, GHome: string;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(GChecks);
  if not Cond then
  begin
    Inc(GFails);
    Writeln('[FAIL] ', Msg);
  end;
end;

function P(const Name: string): string;
begin
  Result := GTree + '\' + Name;
end;

procedure WriteText(const FileName, S: string);
begin
  ForceDirectories(ExtractFileDir(FileName));
  TFile.WriteAllText(FileName, S, TEncoding.ANSI);
end;

constructor TRecorder.Create;
begin
  inherited;
  Lock := TCriticalSection.Create;
  States := TStringList.Create;
end;

destructor TRecorder.Destroy;
begin
  States.Free;
  Lock.Free;
  inherited;
end;

procedure TRecorder.OnState(Sender: TObject; State: TsgcFSearchEngineState);
begin
  Lock.Enter;
  try
    States.Add(sgcFSearchEngineStateText(State));
  finally
    Lock.Leave;
  end;
end;

procedure TRecorder.OnChanged(Sender: TObject; Generation: Int64);
begin
  TInterlocked.Increment(Changes);
end;

function TRecorder.Text: string;
begin
  Lock.Enter;
  try
    Result := States.CommaText;
  finally
    Lock.Leave;
  end;
end;

function WaitUntil(const Cond: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
var
  vSw: TStopwatch;
begin
  vSw := TStopwatch.StartNew;
  repeat
    if Cond() then
      Exit(True);
    Sleep(10);
  until vSw.ElapsedMilliseconds > TimeoutMs;
  Result := Cond();
end;

procedure BuildTree;
var
  i, j: Integer;
begin
  for i := 0 to 9 do
    for j := 0 to 29 do
      WriteText(P(Format('dir%.2d\file_%.2d_%.3d.dat', [i, i, j])),
        'data ' + IntToStr(i * 100 + j));
  WriteText(P('docs\alpha_notes.txt'), 'first line'#13#10 +
    'the quick zebracorn jumps'#13#10'last line'#13#10);
  WriteText(P('docs\beta_notes.txt'), 'nothing here'#13#10 +
    'zebracorn again'#13#10);
  WriteText(P('docs\unique.txt'), 'the word quasarvortex appears only here');
  WriteText(P('src\Widget.pas'), CS_PAS);
  WriteText(P('src\other.txt'), 'FrobnicateAll mentioned in a txt file');
  WriteText(P('sizes\size_small.bin'), '0123456789');
  WriteText(P('sizes\size_big.bin'), StringOfChar('x', 50000));
  WriteText(P('sizes\rank_test_a.dat'), 'a');
  WriteText(P('sizes\rank_test_b.dat'), 'b');
end;

procedure WriteConfig(const Home, Tree: string; const ContentCase: string = '');
var
  vO: TJSONObject;
begin
  ForceDirectories(Home);
  vO := TJSONObject.Create;
  try
    vO.AddPair('roots', TJSONArray.Create.Add(Tree));
    vO.AddPair('drives', TJSONArray.Create.Add(Tree));
    vO.AddPair('skip', TJSONArray.Create);
    if ContentCase <> '' then
      vO.AddPair('content_case', ContentCase);
    TFile.WriteAllText(Home + '\config.json', vO.ToJSON, TEncoding.ANSI);
  finally
    vO.Free;
  end;
end;

function Rows(E: TsgcFSearchEngine; const Q: string; Limit: Integer = 100)
  : TsgcFSearchEngineRows;
begin
  E.Search(Q, Limit, Result);
end;

function AllEndWith(const R: TsgcFSearchEngineRows; const Ext: string): Boolean;
var
  i: Integer;
begin
  Result := Length(R.Items) > 0;
  for i := 0 to High(R.Items) do
    if not EndsText(Ext, R.Items[i].Path) then
      Result := False;
end;

function NameCount(const R: TsgcFSearchEngineRows; const Name: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(R.Items) do
    if SameText(R.Items[i].Name, Name) then
      Inc(Result);
end;

function JObj(const S: string): TJSONObject;
var
  vV: TJSONValue;
begin
  vV := TJSONObject.ParseJSONValue(S);
  if vV is TJSONObject then
    Result := TJSONObject(vV)
  else
  begin
    vV.Free;
    Result := nil;
  end;
end;

function JOk(const S: string): Boolean;
var
  vO: TJSONObject;
begin
  Result := False;
  vO := JObj(S);
  if vO <> nil then
    try
      Result := vO.GetValue<Boolean>('ok');
    finally
      vO.Free;
    end;
end;

procedure TestFirstRun(out E: TsgcFSearchEngine; Rec: TRecorder);
var
  vSw: TStopwatch;
  vStartMs, vReadyMs: Int64;
  vEngine: TsgcFSearchEngine;
  vSt: TsgcFSearchEngineStatus;
  R: TsgcFSearchEngineRows;
begin
  E := TsgcFSearchEngine.Create(GHome);
  vEngine := E;
  E.OnStateChanged := Rec.OnState;
  E.OnChanged := Rec.OnChanged;
  vSw := TStopwatch.StartNew;
  E.Start;
  vStartMs := vSw.ElapsedMilliseconds;
  Check(WaitUntil(function: Boolean
    begin
      Result := vEngine.State = fsesReady;
    end, 30000), 'first run reaches ready, state ' + E.StateText);
  vReadyMs := vSw.ElapsedMilliseconds;
  Writeln(Format('first run: Start returned in %d ms, ready in %d ms, ' +
    'states %s', [vStartMs, vReadyMs, Rec.Text]));
  Check(Pos('crawling', Rec.Text) > 0, 'first run crawls: ' + Rec.Text);
  Check(Pos('loading', Rec.Text) = 0, 'first run does not load');
  vSt := E.Status;
  Check(vSt.Files = CS_FILES, Format('files %d', [vSt.Files]));
  Check(vSt.Folders = CS_FOLDERS, Format('folders %d', [vSt.Folders]));
  Check(vSt.Crawled > 0, 'crawled > 0');
  Check((Length(vSt.Roots) = 1) and SameText(vSt.Roots[0], GTree), 'roots');
  Check(FileExists(GHome + '\names.idx'), 'names.idx saved after the crawl');
  // name search
  R := Rows(E, 'alpha_notes');
  Check((R.Total = 1) and (Length(R.Items) = 1), 'name search total');
  if Length(R.Items) = 1 then
  begin
    Check(R.Items[0].Name = 'alpha_notes.txt', 'name');
    Check(SameText(R.Items[0].Path, P('docs\alpha_notes.txt')), 'path');
    Check((R.Items[0].MatchPos = 0) and (R.Items[0].MatchLen = 11),
      'name highlight');
    Check(not R.IsContentResult and not R.Items[0].IsContent, 'not content');
    Check(R.Items[0].MTime > 0, 'mtime');
  end;
  // filters
  R := Rows(E, 'notes ext:txt');
  Check((R.Total = 2) and AllEndWith(R, '.txt'), 'ext filter');
  R := Rows(E, 'file_ in:"' + P('dir03') + '"');
  Check(R.Total = 30, Format('in: filter %d', [R.Total]));
  R := Rows(E, 'size_ ext:bin sort:size');
  Check((Length(R.Items) = 2) and (R.Items[0].Name = 'size_big.bin') and
    (R.Items[0].Size = 50000), 'sort:size');
  R := Rows(E, 'file_0 limit:7');
  Check((Length(R.Items) = 7) and (R.Total > 7), 'limit:');
  // total is the true match count when the limit is below it
  R := Rows(E, 'ext:dat in:"' + P('dir03') + '"', 5);
  Check((Length(R.Items) = 5) and (R.Total = 30), Format('filter-only total %d',
    [R.Total]));
  R := Rows(E, 'kind:dir in:"' + GTree + '"', 3);
  Check((Length(R.Items) = 3) and (R.Total = CS_FOLDERS),
    Format('kind in total %d', [R.Total]));
  R := Rows(E, 'kind:file sort:size in:"' + P('dir03') + '"', 4);
  Check((Length(R.Items) = 4) and (R.Total = 30), Format('sort:size total %d',
    [R.Total]));
end;

procedure TestContent(E: TsgcFSearchEngine);
var
  vEngine: TsgcFSearchEngine;
  R: TsgcFSearchEngineRows;
  vSw: TStopwatch;
  i: Integer;
  vOk: Boolean;
begin
  vEngine := E;
  vSw := TStopwatch.StartNew;
  Check(WaitUntil(function: Boolean
    var
      vS: TsgcFSearchEngineStatus;
    begin
      vS := vEngine.Status;
      Result := (vS.ContentPending = 0) and (vS.ContentIndexed >= 5);
    end, 30000), 'content indexer idle');
  Writeln(Format('content indexed: %d docs, idle after %d ms',
    [E.Status.ContentIndexed, vSw.ElapsedMilliseconds]));
  R := Rows(E, 'grep:zebracorn');
  Check(R.IsContentResult and (Length(R.Items) = 2), 'grep: 2 hits');
  vOk := Length(R.Items) > 0;
  for i := 0 to High(R.Items) do
    if not R.Items[i].IsContent or (R.Items[i].LineNo < 1) or
      (Copy(R.Items[i].LineText, R.Items[i].TextMatchPos + 1,
      R.Items[i].TextMatchLen) <> 'zebracorn') then
      vOk := False;
  Check(vOk, 'grep: line, text, tmatch');
  R := Rows(E, 'regex:Frob[a-z]+All ext:pas');
  Check(R.IsContentResult and (Length(R.Items) >= 1) and AllEndWith(R,
    'Widget.pas'), 'regex: with ext:pas');
  R := Rows(E, 'regex:Frob[a-z]+All');
  Check(Length(R.Items) >= 3, Format('regex: without filter %d',
    [Length(R.Items)]));
  R := Rows(E, 'grep:FrobnicateAll ext:txt');
  Check((Length(R.Items) = 1) and AllEndWith(R, 'other.txt'),
    'ext: filter on content hits');
  R := Rows(E, 'alpha grep:zebracorn');
  Check((Length(R.Items) = 1) and AllEndWith(R, 'alpha_notes.txt'),
    'name term on content hits');
  R := Rows(E, 'alpha*.txt grep:zebracorn');
  Check((Length(R.Items) = 1) and AllEndWith(R, 'alpha_notes.txt'),
    'wildcard name term on content hits');
  R := Rows(E, 'sym:FrobnicateAll');
  Check(R.IsContentResult and (Length(R.Items) >= 1) and AllEndWith(R,
    'Widget.pas'), 'sym:');
  R := Rows(E, 'quasarvortex');
  Check(R.IsContentResult and (Length(R.Items) = 1) and AllEndWith(R,
    'unique.txt'), 'content fallback');
  R := Rows(E, 'quasarvortex ext:pas');
  Check(Length(R.Items) = 0, 'fallback honours ext:');
  R := Rows(E, 'nosuchwordanywhere');
  Check(not R.IsContentResult and (R.Total = 0), 'no hit anywhere');
end;

function ReqTotal(E: TsgcFSearchEngine; const Req: string): Integer;
var
  vO: TJSONObject;
begin
  Result := -1;
  vO := JObj(E.HandleRequest(Req));
  if vO <> nil then
    try
      if vO.GetValue<Boolean>('ok') then
        Result := vO.GetValue<Integer>('total');
    finally
      vO.Free;
    end;
end;

// no content_case key in config.json: content search ignores case
procedure TestContentCase(E: TsgcFSearchEngine);
var
  R, R2: TsgcFSearchEngineRows;
begin
  R := Rows(E, 'grep:ZEBRACORN');
  Check(R.IsContentResult and (Length(R.Items) = 2) and
    (Copy(R.Items[0].LineText, R.Items[0].TextMatchPos + 1,
    R.Items[0].TextMatchLen) = 'zebracorn'), 'no setting: capitals find text');
  Check(Length(Rows(E, 'grep:frobnicateall').Items) = 3,
    'no setting: lowercase finds mixed case');
  // case: beats the setting
  Check(Length(Rows(E, 'grep:ZEBRACORN case:yes').Items) = 0,
    'case:yes beats the default');
  Check(Length(Rows(E, 'grep:zebracorn case:yes').Items) = 2,
    'case:yes finds the exact case');
  Check(Length(Rows(E, 'grep:frobnicateall case:yes').Items) = 0,
    'case:yes lowercase miss');
  Check(Length(Rows(E, 'grep:ZEBRACORN case:no').Items) = 2, 'case:no');
  // the words fallback follows the setting and case:
  R := Rows(E, 'QUASARVORTEX');
  Check(R.IsContentResult and (Length(R.Items) = 1) and AllEndWith(R,
    'unique.txt'), 'no setting: fallback ignores case');
  R := Rows(E, 'QUASARVORTEX case:yes');
  Check(not R.IsContentResult and (R.Total = 0), 'fallback case:yes miss');
  R := Rows(E, 'quasarvortex case:yes');
  Check(R.IsContentResult and (Length(R.Items) = 1), 'fallback case:yes match');
  // only an option: behaves like a query holding only limit:
  R := Rows(E, 'limit:100');
  R2 := Rows(E, 'case:yes');
  Check((R.Total > 0) and not R2.IsContentResult and (R2.Total = R.Total) and
    (Length(R2.Items) = Length(R.Items)), 'case: alone like limit: alone');
  // the direct Grep method
  E.Grep('ZEBRACORN', fsgmLiteral, '', 100, R);
  Check(Length(R.Items) = 2, 'Grep follows the setting');
  E.Grep('ZEBRACORN', fsgmLiteral, 'case:yes', 100, R);
  Check(Length(R.Items) = 0, 'Grep honours case:');
  // pipe: "case" field, then case: filter, then setting
  Check(ReqTotal(E, '{"grep":"ZEBRACORN"}') = 2, 'pipe: setting');
  Check(ReqTotal(E, '{"grep":"ZEBRACORN","case":true}') = 0, 'pipe: case true');
  Check(ReqTotal(E, '{"grep":"zebracorn","case":true}') = 2,
    'pipe: case true, exact case');
  Check(ReqTotal(E, '{"grep":"ZEBRACORN","q":"case:yes"}') = 0,
    'pipe: filter in q');
  Check(ReqTotal(E, '{"grep":"ZEBRACORN","q":"case:yes","case":false}') = 2,
    'pipe: case false beats filter');
  Check(ReqTotal(E, '{"grep":"ZEBRACORN","q":"case:no","case":true}') = 0,
    'pipe: case true beats filter');
  Check(ReqTotal(E, '{"grep":"ZEBRACORN","case":"yes"}') = 2,
    'pipe: non boolean case ignored');
end;

procedure TestLive(E: TsgcFSearchEngine; Rec: TRecorder);
var
  vEngine: TsgcFSearchEngine;
  vSw: TStopwatch;
  vOk: Boolean;
begin
  vEngine := E;
  vSw := TStopwatch.StartNew;
  WriteText(P('docs\live_newfile_qq.dat'), 'live');
  vOk := WaitUntil(function: Boolean
    begin
      Result := Rows(vEngine, 'live_newfile_qq').Total = 1;
    end, 2000);
  Check(vOk, 'new file visible by name within 2 s');
  Writeln(Format('live: new file visible by name after %d ms',
    [vSw.ElapsedMilliseconds]));
  vSw := TStopwatch.StartNew;
  WriteText(P('docs\live_content.txt'), 'a xylophonium line');
  vOk := WaitUntil(function: Boolean
    begin
      Result := Length(Rows(vEngine, 'grep:xylophonium').Items) = 1;
    end, 3000);
  Check(vOk, 'new .txt greppable within 3 s');
  Writeln(Format('live: new .txt greppable after %d ms',
    [vSw.ElapsedMilliseconds]));
  Check(TInterlocked.CompareExchange(Rec.Changes, 0, 0) > 0, 'OnChanged fired');
end;

procedure TestUsage(E: TsgcFSearchEngine);
var
  R: TsgcFSearchEngineRows;
  vSecond: string;
  i: Integer;
begin
  R := Rows(E, 'rank_test');
  Check(Length(R.Items) = 2, 'rank_test 2 rows');
  if Length(R.Items) <> 2 then
    Exit;
  vSecond := R.Items[1].Path;
  for i := 1 to 3 do
    E.RecordUse(vSecond, fsukOpen);
  R := Rows(E, 'rank_test');
  Check((Length(R.Items) = 2) and SameText(R.Items[0].Path, vSecond),
    'RecordUse moves the row up');
  Check(FileExists(GHome + '\usage.json'), 'usage.json written');
end;

procedure TestRequests(E: TsgcFSearchEngine);
var
  S: string;
  vO: TJSONObject;
  vArr: TJSONArray;
  vRes: TJSONObject;
  vThreads: array [0 .. 3] of TThread;
  vErrors: Integer;
  vEngine: TsgcFSearchEngine;
  i: Integer;
  vSw: TStopwatch;
begin
  vEngine := E;
  // op 1
  S := E.HandleRequest('{"id":1,"q":"alpha_notes","limit":5}');
  vO := JObj(S);
  Check(vO <> nil, 'op1 JSON');
  if vO <> nil then
    try
      Check(vO.GetValue<Boolean>('ok') and (vO.GetValue<Integer>('id') = 1),
        'op1 ok + id');
      Check(not vO.GetValue<Boolean>('content'), 'op1 content false');
      vArr := vO.GetValue<TJSONArray>('results');
      Check((vArr <> nil) and (vArr.Count = 1), 'op1 results');
      if (vArr <> nil) and (vArr.Count = 1) then
      begin
        vRes := vArr.Items[0] as TJSONObject;
        Check(vRes.GetValue<string>('name') = 'alpha_notes.txt', 'op1 name');
        Check(EndsStr('Z', vRes.GetValue<string>('mtime')) and
          (Length(vRes.GetValue<string>('mtime')) = 20), 'op1 mtime ISO');
        Check(vRes.GetValue<Integer>('size') > 0, 'op1 size');
        Check(vRes.GetValue<TJSONArray>('match').Count = 2, 'op1 match');
        Check(vRes.GetValue('score') <> nil, 'op1 score');
      end;
    finally
      vO.Free;
    end;
  // op 2
  S := E.HandleRequest('{"id":"two","grep":"zebracorn","mode":"literal",' +
    '"q":"ext:txt","limit":10}');
  vO := JObj(S);
  Check(vO <> nil, 'op2 JSON');
  if vO <> nil then
    try
      Check(vO.GetValue<Boolean>('ok') and (vO.GetValue<string>('id') = 'two'),
        'op2 ok + string id');
      Check(vO.GetValue<Boolean>('content'), 'op2 content true');
      vArr := vO.GetValue<TJSONArray>('results');
      Check((vArr <> nil) and (vArr.Count = 2), 'op2 results');
      if (vArr <> nil) and (vArr.Count > 0) then
      begin
        vRes := vArr.Items[0] as TJSONObject;
        Check((vRes.GetValue<Integer>('line') >= 1) and
          (Pos('zebracorn', vRes.GetValue<string>('text')) > 0) and
          (vRes.GetValue<TJSONArray>('tmatch').Count = 2), 'op2 line fields');
      end;
    finally
      vO.Free;
    end;
  S := E.HandleRequest('{"id":5,"grep":"Frob[a-z]+All","mode":"regex",' +
    '"q":"ext:pas"}');
  Check(JOk(S) and (Pos('Widget.pas', S) > 0) and (Pos('other.txt', S) = 0),
    'op2 regex mode');
  S := E.HandleRequest('{"id":10,"grep":"FrobnicateAll","mode":"sym"}');
  Check(JOk(S) and (Pos('Widget.pas', S) > 0), 'op2 sym mode');
  // op 3
  S := E.HandleRequest('{"id":3,"status":true}');
  vO := JObj(S);
  Check(vO <> nil, 'op3 JSON');
  if vO <> nil then
    try
      Check(vO.GetValue<Boolean>('ok') and
        (vO.GetValue<string>('state') = 'ready'), 'op3 state');
      Check(vO.GetValue<Integer>('files') >= CS_FILES, 'op3 files');
      Check(vO.GetValue<Integer>('folders') = CS_FOLDERS, 'op3 folders');
      Check(vO.GetValue<Integer>('pid') = Integer(GetCurrentProcessId),
        'op3 pid');
      Check(vO.GetValue<string>('version') <> '', 'op3 version');
      Check(vO.GetValue<TJSONArray>('roots').Count = 1, 'op3 roots');
      Check(vO.GetValue<string>('log') <> '', 'op3 log');
      Check(vO.GetValue('content_pending') <> nil, 'op3 content_pending');
      Check(vO.GetValue<Integer>('content_indexed') >= 5,
        'op3 content_indexed');
    finally
      vO.Free;
    end;
  // op 4
  S := E.HandleRequest('{"id":4,"use":"' +
    StringReplace(P('docs\beta_notes.txt'), '\', '\\', [rfReplaceAll]) +
    '","kind":"copy"}');
  Check(JOk(S) and (Pos('"id":4', S) > 0), 'op4 ok');
  Check(not JOk(E.HandleRequest('{"id":4,"use":"x","kind":"zzz"}')),
    'op4 bad kind');
  // not handled by the engine
  Check(E.HandleRequest('{"id":6,"show":true,"q":"x"}') = '', 'show -> empty');
  Check(E.HandleRequest('{"stop":true}') = '', 'stop -> empty');
  Check(E.HandleRequest('{"id":7,"foo":1}') = '', 'unknown -> empty');
  // errors
  S := E.HandleRequest('this is not json');
  Check((S <> '') and not JOk(S) and (Pos('"error"', S) > 0), 'malformed JSON');
  S := E.HandleRequest('[1,2]');
  Check((S <> '') and not JOk(S), 'non-object JSON');
  S := E.HandleRequest('{"id":8,"grep":"(","mode":"regex"}');
  Check(not JOk(S) and (Pos('"id":8', S) > 0), 'invalid regex -> ok:false');
  S := E.HandleRequest('{"id":9,"grep":"x","mode":"bogus"}');
  Check(not JOk(S) and (Pos('"id":9', S) > 0), 'bad mode -> ok:false');
  // concurrency: 4 threads x 50 requests
  vErrors := 0;
  vSw := TStopwatch.StartNew;
  for i := 0 to 3 do
  begin
    vThreads[i] := TThread.CreateAnonymousThread(procedure
      var
        k: Integer;
        vReq, vResp: string;
        vJ: TJSONObject;
      begin
        for k := 0 to 49 do
        begin
          case k mod 4 of
            0:
              vReq := Format('{"id":%d,"q":"file_ sort:size"}', [k]);
            1:
              vReq := Format('{"id":%d,"grep":"zebracorn","q":"ext:txt"}', [k]);
            2:
              vReq := Format('{"id":%d,"status":true}', [k]);
          else
            vReq := Format('{"id":%d,"q":"notes ext:txt"}', [k]);
          end;
          try
            vResp := vEngine.HandleRequest(vReq);
            vJ := JObj(vResp);
            try
              if (vJ = nil) or not vJ.GetValue<Boolean>('ok') or
                (vJ.GetValue<Integer>('id') <> k) then
                TInterlocked.Increment(vErrors);
            finally
              vJ.Free;
            end;
          except
            TInterlocked.Increment(vErrors);
          end;
        end;
      end);
    vThreads[i].FreeOnTerminate := False;
  end;
  for i := 0 to 3 do
    vThreads[i].Start;
  for i := 0 to 3 do
  begin
    vThreads[i].WaitFor;
    vThreads[i].Free;
  end;
  Check(vErrors = 0, Format('concurrent requests: %d errors', [vErrors]));
  Writeln(Format('requests: 200 concurrent requests in %d ms',
    [vSw.ElapsedMilliseconds]));
end;

// Fails the test (exit 1) unless the returned event is set within
// TimeoutMs: a deadlocked Checkpoint / Stop must not hang the test. The
// watchdog thread frees the event.
function StartWatchdog(const What: string; TimeoutMs: Cardinal): TEvent;
var
  vEvent: TEvent;
begin
  vEvent := TEvent.Create(nil, True, False, '');
  TThread.CreateAnonymousThread(procedure
    begin
      if vEvent.WaitFor(TimeoutMs) <> wrSignaled then
      begin
        Writeln(Format('[FAIL] %s did not return within %d ms',
          [What, TimeoutMs]));
        Flush(Output);
        ExitProcess(1);
      end;
      vEvent.Free;
    end).Start;
  Result := vEvent;
end;

// A content document indexed, then removed: a tombstone for the next save.
procedure ContentChurn(E: TsgcFSearchEngine; const Name: string);
var
  vBase: Integer;
begin
  vBase := E.Status.ContentIndexed;
  WriteText(P(Name), 'churn line zorbleplex');
  Check(WaitUntil(function: Boolean
    begin
      Result := E.Status.ContentIndexed = vBase + 1;
    end, 30000), Name + ' content indexed');
  DeleteFile(P(Name));
  Check(WaitUntil(function: Boolean
    begin
      Result := E.Status.ContentIndexed = vBase;
    end, 30000), Name + ' content removed');
end;

procedure TestCheckpointStop(E: TsgcFSearchEngine; Rec: TRecorder);
var
  vNames, vContent: string;
  vT0, vC0: TDateTime;
  vSw: TStopwatch;
  vDog: TEvent;
begin
  vNames := GHome + '\names.idx';
  vContent := GHome + '\content.idx';
  ContentChurn(E, 'docs\cp_churn1.txt');
  vT0 := TFile.GetLastWriteTime(vNames);
  if FileExists(vContent) then
    vC0 := TFile.GetLastWriteTime(vContent)
  else
    vC0 := 0;
  Sleep(20);
  vSw := TStopwatch.StartNew;
  vDog := StartWatchdog('Checkpoint after a removal', 30000);
  E.Checkpoint;
  vDog.SetEvent;
  Writeln(Format('checkpoint: %d ms', [vSw.ElapsedMilliseconds]));
  Check(TFile.GetLastWriteTime(vNames) > vT0, 'checkpoint rewrites names.idx');
  Check(FileExists(vContent) and (TFile.GetLastWriteTime(vContent) > vC0),
    'checkpoint rewrites content.idx');
  // changed after the checkpoint: Stop saves content.idx once the content
  // indexer is stopped
  ContentChurn(E, 'docs\cp_churn2.txt');
  vC0 := TFile.GetLastWriteTime(vContent);
  Sleep(20);
  vSw := TStopwatch.StartNew;
  vDog := StartWatchdog('Stop after a removal', 30000);
  E.Stop;
  vDog.SetEvent;
  Writeln(Format('stop: %d ms', [vSw.ElapsedMilliseconds]));
  Check(TFile.GetLastWriteTime(vContent) > vC0, 'stop rewrites content.idx');
  Check(E.State = fsesStopped, 'stopped');
  Check(EndsText('stopping,stopped', Rec.Text), 'states end with stopping,' +
    'stopped: ' + Rec.Text);
  E.Stop;
  Check(E.State = fsesStopped, 'second Stop is safe');
  // queries still answer after Stop
  Check(Rows(E, 'alpha_notes').Total = 1, 'search after Stop');
end;

procedure TestSecondRun(Rec: TRecorder);
var
  E: TsgcFSearchEngine;
  vSw: TStopwatch;
  vSt: TsgcFSearchEngineStatus;
  vCU: TsgcFSearchCatchUpResult;
  vMode: string;
begin
  // changes while no engine runs
  WriteText(P('dir05\while_stopped_zz.dat'), 'x');
  DeleteFile(P('dir06\file_06_000.dat'));
  E := TsgcFSearchEngine.Create(GHome);
  try
    E.OnStateChanged := Rec.OnState;
    vSw := TStopwatch.StartNew;
    E.Start;
    Check(WaitUntil(function: Boolean
      begin
        Result := E.State = fsesReady;
      end, 30000), 'second run reaches ready');
    vCU := E.LastCatchUp;
    case vCU.Mode of
      fscmJournal:
        vMode := 'journal';
      fscmRescan:
        vMode := 'rescan';
    else
      vMode := 'failed';
    end;
    Writeln(Format('second run: ready in %d ms, states %s, catch-up %s, ' +
      '%d records, %d folders re-listed', [vSw.ElapsedMilliseconds, Rec.Text,
      vMode, vCU.Records, vCU.Stats.Folders]));
    Check((Pos('loading', Rec.Text) > 0) and (Pos('catchup', Rec.Text) > 0),
      'second run loads + catches up');
    Check(Pos('crawling', Rec.Text) = 0, 'second run does not crawl');
    Check(vCU.Mode <> fscmFailed, 'catch-up did not fail');
    Check(Rows(E, 'while_stopped_zz').Total = 1, 'file added while stopped');
    Check(NameCount(Rows(E, 'file_06_000'), 'file_06_000.dat') = 0,
      'file deleted while stopped');
    vSt := E.Status;
    // + live_newfile_qq.dat, live_content.txt, while_stopped_zz.dat - 1
    Check(vSt.Files = CS_FILES + 2, Format('second run files %d', [vSt.Files]));
    Check(vSt.ContentIndexed >= 5, 'content.idx loaded');
    Check(Length(Rows(E, 'grep:zebracorn').Items) = 2, 'grep after reload');
    E.Stop;
    E.Stop;
    Check(E.State = fsesStopped, 'second run Stop twice');
  finally
    E.Free;
  end;
end;

function StartWithCase(const Value: string): TsgcFSearchEngine;
var
  vE: TsgcFSearchEngine;
begin
  WriteConfig(GHome, GTree, Value);
  vE := TsgcFSearchEngine.Create(GHome);
  vE.Start;
  Check(WaitUntil(function: Boolean
    begin
      Result := vE.State = fsesReady;
    end, 30000), 'content_case ' + Value + ' reaches ready');
  Result := vE;
end;

procedure TestCaseSetting;
var
  E: TsgcFSearchEngine;
  R: TsgcFSearchEngineRows;
begin
  // smart restores the capital letter rule
  E := StartWithCase('smart');
  try
    Check(Length(Rows(E, 'grep:ZEBRACORN').Items) = 0, 'smart: capital miss');
    Check(Length(Rows(E, 'grep:frobnicateall').Items) = 3,
      'smart: no capital ignores case');
    Check(Length(Rows(E, 'grep:FrobnicateAll').Items) = 3,
      'smart: capital, exact case');
    Check(Length(Rows(E, 'grep:ZEBRACORN case:no').Items) = 2,
      'case:no beats smart');
    Check(Length(Rows(E, 'grep:frobnicateall case:yes').Items) = 0,
      'case:yes beats smart');
    R := Rows(E, 'QUASARVORTEX');
    Check(not R.IsContentResult and (R.Total = 0), 'smart: fallback capital');
    R := Rows(E, 'quasarvortex');
    Check(R.IsContentResult and (Length(R.Items) = 1),
      'smart: fallback no capital');
    Check(ReqTotal(E, '{"grep":"ZEBRACORN"}') = 0, 'smart: pipe setting');
    Check(ReqTotal(E, '{"grep":"ZEBRACORN","case":false}') = 2,
      'smart: pipe case false');
    E.Stop;
  finally
    E.Free;
  end;
  E := StartWithCase('sensitive');
  try
    Check(Length(Rows(E, 'grep:frobnicateall').Items) = 0,
      'sensitive: no capital miss');
    Check(Length(Rows(E, 'grep:FrobnicateAll').Items) = 3,
      'sensitive: exact case');
    Check(Length(Rows(E, 'grep:FROBNICATEALL case:no').Items) = 3,
      'case:no beats sensitive');
    R := Rows(E, 'frobnicateall');
    Check(not R.IsContentResult, 'sensitive: fallback miss');
    R := Rows(E, 'FrobnicateAll');
    Check(R.IsContentResult and (Length(R.Items) = 3),
      'sensitive: fallback exact case');
    R := Rows(E, 'frobnicateall case:no');
    Check(R.IsContentResult and (Length(R.Items) = 3),
      'sensitive: fallback case:no');
    Check(ReqTotal(E, '{"grep":"frobnicateall"}') = 0,
      'sensitive: pipe setting');
    Check(ReqTotal(E, '{"grep":"frobnicateall","case":false}') = 3,
      'sensitive: pipe case false');
    E.Stop;
  finally
    E.Free;
  end;
end;

procedure TestStopDuringCrawl;
var
  E: TsgcFSearchEngine;
  vHome: string;
  vDelay: Integer;
  vSw: TStopwatch;
  vSeen, vTree: string;
  vIdx: TsgcFSearchIndex;
  i, j, vSaved: Integer;
begin
  vHome := GBase + '\home_stop';
  vTree := GBase + '\bigtree';
  for i := 0 to 59 do
    for j := 0 to 49 do
      WriteText(Format('%s\d%.2d\f%.2d_%.2d.dat', [vTree, i, i, j]), 'x');
  vSeen := '';
  vSaved := 0;
  for vDelay in [0, 1, 3, 5, 10, 20] do
  begin
    if DirectoryExists(vHome) then
      TDirectory.Delete(vHome, True);
    WriteConfig(vHome, vTree);
    E := TsgcFSearchEngine.Create(vHome);
    try
      E.Start;
      if vDelay > 0 then
        Sleep(vDelay);
      vSeen := vSeen + E.StateText + ' ';
      vSw := TStopwatch.StartNew;
      E.Stop;
      Check(vSw.ElapsedMilliseconds < 5000, 'Stop during startup is quick');
      Check(E.State = fsesStopped, 'stopped after early Stop');
      // a partial crawl is never saved
      if FileExists(vHome + '\names.idx') then
      begin
        vIdx := TsgcFSearchIndex.Create;
        try
          Check(vIdx.LoadFromFile(vHome + '\names.idx') and
            (vIdx.FileCount = 3000), 'saved index is complete');
          vSaved := vSaved + 1;
        finally
          vIdx.Free;
        end;
      end;
      E.Stop;
    finally
      E.Free;
    end;
  end;
  // Stop without Start
  E := TsgcFSearchEngine.Create(vHome);
  try
    E.Stop;
    Check(E.State = fsesStopped, 'Stop without Start');
  finally
    E.Free;
  end;
  Writeln(Format('early Stop states: %s (names.idx saved in %d of 6)',
    [Trim(vSeen), vSaved]));
end;

procedure PrintLog;
var
  vLines: TArray<string>;
  i: Integer;
begin
  if not FileExists(GHome + '\daemon.log') then
    Exit;
  vLines := TFile.ReadAllLines(GHome + '\daemon.log', TEncoding.UTF8);
  for i := 0 to High(vLines) do
    if ContainsText(vLines[i], 'crawled ') or
      ContainsText(vLines[i], 'catch-up') or ContainsText(vLines[i], ' saved')
      or ContainsText(vLines[i], 'loaded') or ContainsText(vLines[i], 'ready ')
    then
      Writeln('  log: ', Copy(vLines[i], 1, 160));
end;

// a folder below a file can never be created, the same as a read-only medium
procedure TestDataDirNotWritable;
var
  vE: TsgcFSearchEngine;
  vHome: string;
begin
  WriteText(GBase + '\blocker', 'x');
  vHome := GBase + '\blocker\data\PC';
  vE := TsgcFSearchEngine.Create(vHome);
  try
    Check(not DirectoryExists(vHome), 'not writable: no data folder');
    vE.Config.Roots := [GTree];
    vE.Config.Drives := [GTree];
    vE.Start;
    Check(WaitUntil(function: Boolean
      begin
        Result := vE.State in [fsesReady, fsesStopped];
      end, 30000), 'not writable: the first crawl ends');
    Check(NameCount(Rows(vE, 'size_small'), 'size_small.bin') = 1,
      'not writable: the crawled names can be searched');
    Check(vE.Status.LastError <> '',
      'not writable: the save error is reported');
    vE.Stop;
    Check(vE.State = fsesStopped, 'not writable: stops');
  finally
    vE.Free;
  end;
end;

var
  E: TsgcFSearchEngine;
  vRec: TRecorder;

begin
  try
    GBase := TPath.GetTempPath + 'sgcFSearchTests\engine';
    GBase := ExcludeTrailingPathDelimiter(GBase);
    if DirectoryExists(GBase) then
      TDirectory.Delete(GBase, True);
    GTree := GBase + '\tree';
    GHome := GBase + '\home';
    BuildTree;
    WriteConfig(GHome, GTree);
    SetEnvironmentVariable('SGCFSEARCH_HOME', PChar(GHome));
    vRec := TRecorder.Create;
    try
      E := nil;
      try
        TestFirstRun(E, vRec);
        TestContent(E);
        TestContentCase(E);
        TestLive(E, vRec);
        TestUsage(E);
        TestRequests(E);
        TestCheckpointStop(E, vRec);
      finally
        E.Free;
      end;
      vRec.States.Clear;
      TestSecondRun(vRec);
      TestCaseSetting;
    finally
      vRec.Free;
    end;
    TestStopDuringCrawl;
    TestDataDirNotWritable;
    PrintLog;
  except
    on Ex: Exception do
    begin
      Inc(GFails);
      Writeln('[FAIL] exception ', Ex.ClassName, ': ', Ex.Message);
    end;
  end;
  try
    TDirectory.Delete(GBase, True);
  except
    on Ex: Exception do
      Writeln('cleanup: ', Ex.Message);
  end;
  if GFails = 0 then
  begin
    Writeln(Format('[PASS] %d checks', [GChecks]));
    ExitCode := 0;
  end
  else
  begin
    Writeln(Format('%d of %d checks failed', [GFails, GChecks]));
    ExitCode := 1;
  end;

end.
