{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Grep;

{$I sgcVer.inc}
{ Content search over the trigram index.

  - Candidates come from the trigram index (literal / words: the text,
  regex: the required literal runs of the top-level concatenation, symbol:
  the name), the Filter callback (engine name filters) runs on them in the
  calling thread, then every remaining file is verified by reading it fresh
  (re-extracting office / pdf files), on a few worker threads. Results never
  come from stale index data: a file that is gone or changed is re-queued to
  Indexer (when assigned).
  - Smart-case: case-sensitive only when the pattern holds an uppercase
  letter (escaped regex chars such as \W do not count).
  - Words mode: the file must hold every word; reported lines hold any word.
  - Limit is the maximum number of hits (lines); MaxLinesPerFile the lines
  reported per file. Hits are grouped per file, in docid order.
  - An invalid regex raises ERegularExpressionError from Search. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.RegularExpressions,
  // sgc
  sgcFSearch_Extract, sgcFSearch_Trigram;

const
  SGCFS_GREP_LINE_MAX = 200;
  SGCFS_GREP_LINE_LEAD = 60;

type
  TsgcFSearchGrepMode = (fsgmLiteral, fsgmWords, fsgmRegex, fsgmSymbol);

  TsgcFSearchGrepHit = record
    Path: string;
    LineNo: Integer; // 1-based
    LineText: string; // trimmed, at most SGCFS_GREP_LINE_MAX chars
    MatchPos: Integer; // 1-based, in LineText
    MatchLen: Integer; // clipped to the line
  end;

  TsgcFSearchGrepHits = TArray<TsgcFSearchGrepHit>;

  TsgcFSearchGrep = class
  private
    FIndexer: TsgcFSearchContentIndexer;
    FMaxLinesPerFile: Integer;
    FThreadCount: Integer;
    FMaxBytes: Int64;
    FElapsedMs: Int64;
    FCandidateCount: Integer;
    FFilesVerified: Integer;
    FFilesMatched: Integer;
    FCancelled: Boolean;
  public
    constructor Create;
    /// Smart-case rule (regex / symbol: escaped chars ignored).
    class function IsCaseSensitive(const Pattern: string;
      Mode: TsgcFSearchGrepMode): Boolean;
    /// Required literal runs (>= 3 chars) of a regex, top-level
    /// concatenation only; nil when the regex has a top-level alternation.
    class function RegexLiterals(const Pattern: string): TArray<string>;
    /// Definition regex used by the symbol mode.
    class function SymbolPattern(const Name: string): string;
    /// Runs a search, returns the number of hits.
    function Search(const ContentIndex: TsgcFSearchContentIndex;
      const Pattern: string; Mode: TsgcFSearchGrepMode; Limit: Integer;
      const Filter: TFunc<string, Boolean>;
      out Hits: TsgcFSearchGrepHits): Integer;
    /// Stops the running search (thread-safe).
    procedure Cancel;

    /// Re-queue target for gone / changed files (optional).
    property Indexer: TsgcFSearchContentIndexer read FIndexer write FIndexer;
    property MaxLinesPerFile: Integer read FMaxLinesPerFile
      write FMaxLinesPerFile;
    property ThreadCount: Integer read FThreadCount write FThreadCount;
    /// Files larger than this are not verified (default 64 MB).
    property MaxBytes: Int64 read FMaxBytes write FMaxBytes;
    // statistics of the last search
    property ElapsedMs: Int64 read FElapsedMs;
    property CandidateCount: Integer read FCandidateCount;
    property FilesVerified: Integer read FFilesVerified;
    property FilesMatched: Integer read FFilesMatched;
  end;

implementation

uses
  Winapi.ActiveX, System.Diagnostics, System.Math;

type
  TsgcFSearchGrepJob = class
  public
    Owner: TsgcFSearchGrep;
    Docs: TsgcFSearchContentDocs;
    Results: TArray<TsgcFSearchGrepHits>;
    Next: Integer;
    Hits: Integer;
    Verified: Integer;
    Limit: Integer;
    MaxLines: Integer;
    MaxBytes: Int64;
    Mode: TsgcFSearchGrepMode;
    CaseSensitive: Boolean;
    Needles: TArray<string>;
    RegexPattern: string;
    RegexOptions: TRegExOptions;
    Indexer: TsgcFSearchContentIndexer;
    function Verify(const Doc: TsgcFSearchContentDoc; var Regex: TRegEx)
      : TsgcFSearchGrepHits;
    procedure Run;
  end;

  TsgcFSearchGrepWorker = class(TThread)
  private
    FJob: TsgcFSearchGrepJob;
  protected
    procedure Execute; override;
  public
    constructor Create(Job: TsgcFSearchGrepJob);
  end;

  // Builds the hit of the line holding Text[MatchPos]. CountPos / LineNo
  // track the line count incrementally (matches come in text order).
function DoMakeHit(const Text: string; var CountPos, LineNo: Integer;
  MatchPos, MatchLen: Integer; out LineEnd: Integer): TsgcFSearchGrepHit;
var
  vStart, vEnd, vL, vR, n, k: Integer;
begin
  n := Length(Text);
  vStart := MatchPos;
  while (vStart > 1) and (Text[vStart - 1] <> #10) do
    Dec(vStart);
  for k := CountPos to vStart - 1 do
    if Text[k] = #10 then
      Inc(LineNo);
  if vStart > CountPos then
    CountPos := vStart;
  vEnd := MatchPos;
  while (vEnd <= n) and (Text[vEnd] <> #10) and (Text[vEnd] <> #13) do
    Inc(vEnd);
  LineEnd := vEnd;
  vL := vStart;
  while (vL < MatchPos) and (Text[vL] <= ' ') do
    Inc(vL);
  vR := vEnd - 1;
  while (vR >= MatchPos + MatchLen) and (Text[vR] <= ' ') do
    Dec(vR);
  if vR - vL + 1 > SGCFS_GREP_LINE_MAX then
  begin
    if MatchPos - vL > SGCFS_GREP_LINE_LEAD then
      vL := MatchPos - SGCFS_GREP_LINE_LEAD;
    if vR - vL + 1 > SGCFS_GREP_LINE_MAX then
      vR := vL + SGCFS_GREP_LINE_MAX - 1;
  end;
  Result.Path := '';
  Result.LineNo := LineNo;
  Result.LineText := Copy(Text, vL, vR - vL + 1);
  Result.MatchPos := MatchPos - vL + 1;
  Result.MatchLen := Max(0, Min(MatchLen, Min(vEnd, vR + 1) - MatchPos));
end;

{ TsgcFSearchGrepJob }

function TsgcFSearchGrepJob.Verify(const Doc: TsgcFSearchContentDoc;
  var Regex: TRegEx): TsgcFSearchGrepHits;
var
  vAttributes: Cardinal;
  vSize, vMTime: Int64;
  vText, vHay: string;
  vCount, vPos, vBest, vBestLen, vP, vCountPos, vLineNo, vLineEnd, i: Integer;
  vMatch: TMatch;

  procedure Add(MatchPos, MatchLen: Integer);
  begin
    if vCount = Length(Result) then
      SetLength(Result, vCount + 4);
    Result[vCount] := DoMakeHit(vText, vCountPos, vLineNo, MatchPos, MatchLen,
      vLineEnd);
    Result[vCount].Path := Doc.Path;
    Inc(vCount);
  end;

begin
  Result := nil;
  if not sgcFSearchGetFileInfo(Doc.Path, vAttributes, vSize, vMTime) then
  begin
    if Indexer <> nil then
      Indexer.NotifyRemoved(Doc.Path);
    Exit;
  end;
  if ((vSize <> Doc.Size) or (vMTime <> Doc.MTime)) and (Indexer <> nil) then
    Indexer.NotifyChanged(Doc.Path);
  if sgcFSearchExtractText(Doc.Path, MaxBytes, vText) <> fserOK then
    Exit;
  vCount := 0;
  vCountPos := 1;
  vLineNo := 1;
  case Mode of
    fsgmLiteral, fsgmWords:
      begin
        if CaseSensitive then
          vHay := vText
        else
          vHay := sgcFSearchFoldText(vText);
        if Mode = fsgmWords then
          for i := 0 to High(Needles) do
            if Pos(Needles[i], vHay) = 0 then
              Exit;
        vPos := 1;
        while vCount < MaxLines do
        begin
          vBest := 0;
          vBestLen := 0;
          for i := 0 to High(Needles) do
          begin
            vP := Pos(Needles[i], vHay, vPos);
            if (vP > 0) and ((vBest = 0) or (vP < vBest)) then
            begin
              vBest := vP;
              vBestLen := Length(Needles[i]);
            end;
          end;
          if vBest = 0 then
            Break;
          Add(vBest, vBestLen);
          vPos := Max(vLineEnd, vBest + 1);
        end;
      end;
    fsgmRegex, fsgmSymbol:
      begin
        vMatch := Regex.Match(vText);
        while vMatch.Success and (vCount < MaxLines) do
        begin
          Add(vMatch.Index, vMatch.Length);
          vPos := Max(vLineEnd, vMatch.Index + 1);
          if vPos > Length(vText) then
            Break;
          vMatch := Regex.Match(vText, vPos);
        end;
      end;
  end;
  SetLength(Result, vCount);
end;

procedure TsgcFSearchGrepJob.Run;
var
  vRegex: TRegEx;
  vHits: TsgcFSearchGrepHits;
  i: Integer;
begin
  if Mode in [fsgmRegex, fsgmSymbol] then
    vRegex := TRegEx.Create(RegexPattern, RegexOptions);
  while not Owner.FCancelled and (Hits < Limit) do
  begin
    i := TInterlocked.Increment(Next) - 1;
    if i >= Length(Docs) then
      Break;
    try
      vHits := Verify(Docs[i], vRegex);
    except
      vHits := nil;
    end;
    TInterlocked.Increment(Verified);
    if Length(vHits) > 0 then
    begin
      Results[i] := vHits;
      TInterlocked.Add(Hits, Length(vHits));
    end;
  end;
end;

{ TsgcFSearchGrepWorker }

constructor TsgcFSearchGrepWorker.Create(Job: TsgcFSearchGrepJob);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FJob := Job;
end;

procedure TsgcFSearchGrepWorker.Execute;
var
  vInit: HRESULT;
begin
  NameThreadForDebugging('sgcFSearch grep');
  vInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    try
      FJob.Run;
    except
      // a worker failure only loses its share of the files
    end;
  finally
    if Succeeded(vInit) then
      CoUninitialize;
  end;
end;

{ TsgcFSearchGrep }

constructor TsgcFSearchGrep.Create;
begin
  inherited Create;
  FMaxLinesPerFile := 5;
  FThreadCount := 4;
  FMaxBytes := 64 * 1024 * 1024;
end;

procedure TsgcFSearchGrep.Cancel;
begin
  FCancelled := True;
end;

class function TsgcFSearchGrep.IsCaseSensitive(const Pattern: string;
  Mode: TsgcFSearchGrepMode): Boolean;
var
  i: Integer;
begin
  i := 1;
  while i <= Length(Pattern) do
  begin
    if (Mode = fsgmRegex) and (Pattern[i] = '\') then
    begin
      Inc(i, 2);
      Continue;
    end;
    if sgcFSearchFoldChar(Pattern[i]) <> Pattern[i] then
      Exit(True);
    Inc(i);
  end;
  Result := False;
end;

class function TsgcFSearchGrep.RegexLiterals(const Pattern: string)
  : TArray<string>;
var
  vRun: string;
  vCount, i, n, vDepth: Integer;
  c, d: Char;

  procedure Flush;
  begin
    if Length(vRun) >= 3 then
    begin
      SetLength(Result, vCount + 1);
      Result[vCount] := vRun;
      Inc(vCount);
    end;
    vRun := '';
  end;

  procedure DropLast;
  begin
    if vRun <> '' then
      SetLength(vRun, Length(vRun) - 1);
  end;

// index just after the character class starting at Pattern[i] = '['
  function SkipClass(i: Integer): Integer;
  begin
    Inc(i);
    if (i <= n) and (Pattern[i] = '^') then
      Inc(i);
    if (i <= n) and (Pattern[i] = ']') then
      Inc(i);
    while (i <= n) and (Pattern[i] <> ']') do
    begin
      if Pattern[i] = '\' then
        Inc(i);
      Inc(i);
    end;
    Result := i + 1;
  end;

begin
  Result := nil;
  vCount := 0;
  n := Length(Pattern);
  // a top-level alternation means no literal is required
  vDepth := 0;
  i := 1;
  while i <= n do
  begin
    case Pattern[i] of
      '\':
        Inc(i);
      '[':
        begin
          i := SkipClass(i);
          Continue;
        end;
      '(':
        Inc(vDepth);
      ')':
        if vDepth > 0 then
          Dec(vDepth);
      '|':
        if vDepth = 0 then
          Exit;
    end;
    Inc(i);
  end;
  vRun := '';
  i := 1;
  while i <= n do
  begin
    c := Pattern[i];
    case c of
      '\':
        begin
          if i = n then
            Break;
          d := Pattern[i + 1];
          Inc(i, 2);
          if CharInSet(d, ['0' .. '9', 'A' .. 'Z', 'a' .. 'z']) then
          begin
            Flush;
            if CharInSet(d, ['p', 'P', 'x', 'k', 'g']) and (i <= n) and
              (Pattern[i] = '{') then
            begin
              while (i <= n) and (Pattern[i] <> '}') do
                Inc(i);
              Inc(i);
            end;
          end
          else
            vRun := vRun + d;
          Continue;
        end;
      '[':
        begin
          Flush;
          i := SkipClass(i);
          Continue;
        end;
      '(':
        begin
          Flush;
          vDepth := 1;
          Inc(i);
          while (i <= n) and (vDepth > 0) do
          begin
            case Pattern[i] of
              '\':
                Inc(i);
              '[':
                begin
                  i := SkipClass(i);
                  Continue;
                end;
              '(':
                Inc(vDepth);
              ')':
                Dec(vDepth);
            end;
            Inc(i);
          end;
          Continue;
        end;
      '*', '?':
        begin
          DropLast;
          Flush;
        end;
      '+', '.', '^', '$', ')', '|':
        Flush;
      '{':
        if (i < n) and CharInSet(Pattern[i + 1], ['0' .. '9', ',']) then
        begin
          if CharInSet(Pattern[i + 1], ['0', ',']) then
            DropLast;
          Flush;
          while (i <= n) and (Pattern[i] <> '}') do
            Inc(i);
        end
        else
          vRun := vRun + c;
    else
      vRun := vRun + c;
    end;
    Inc(i);
  end;
  Flush;
end;

class function TsgcFSearchGrep.SymbolPattern(const Name: string): string;
var
  vName: string;
begin
  vName := TRegEx.Escape(Name);
  Result := '(?:\b(?:function|procedure|constructor|destructor|def|class|fn|' +
    'func|interface|struct|enum|trait|impl|type|record|module|namespace|' +
    'const|let|var)[ \t]+(?:[\w.]+\.)?' + vName + '\b)' + '|(?:\b' + vName +
    '[ \t]*=[ \t]*(?:packed[ \t]+)?(?:class|record|interface)\b)' +
    '|(?:\bfunc[ \t]*\([^)\r\n]*\)[ \t]*' + vName + '\b)' +
    '|(?:^[ \t]*(?!(?:return|new|else|throw|await|yield|case|delete|if|' +
    'while|for|switch|sizeof|typeof)\b)(?:[\w:<>,*&\[\]]+[ \t]+)+[*&]*' + vName
    + '[ \t]*\()';
end;

function TsgcFSearchGrep.Search(const ContentIndex: TsgcFSearchContentIndex;
  const Pattern: string; Mode: TsgcFSearchGrepMode; Limit: Integer;
  const Filter: TFunc<string, Boolean>; out Hits: TsgcFSearchGrepHits): Integer;
var
  vWatch: TStopwatch;
  vJob: TsgcFSearchGrepJob;
  vLiterals: TArray<string>;
  vWorkers: TArray<TsgcFSearchGrepWorker>;
  vDocs: TsgcFSearchContentDocs;
  vCheck: TRegEx;
  vName: string;
  i, j, n, vThreads: Integer;
begin
  Hits := nil;
  Result := 0;
  FCancelled := False;
  FCandidateCount := 0;
  FFilesVerified := 0;
  FFilesMatched := 0;
  vWatch := TStopwatch.StartNew;
  try
    if (ContentIndex = nil) or (Trim(Pattern) = '') or (Limit <= 0) then
      Exit;
    vJob := TsgcFSearchGrepJob.Create;
    try
      vJob.Owner := Self;
      vJob.Mode := Mode;
      vJob.Limit := Limit;
      vJob.MaxLines := Max(1, FMaxLinesPerFile);
      vJob.MaxBytes := FMaxBytes;
      vJob.Indexer := FIndexer;
      vJob.CaseSensitive := IsCaseSensitive(Pattern, Mode);
      vJob.RegexOptions := [roNotEmpty, roMultiLine];
      if not vJob.CaseSensitive then
        Include(vJob.RegexOptions, roIgnoreCase);
      case Mode of
        fsgmLiteral:
          vLiterals := [Pattern];
        fsgmWords:
          vLiterals := Pattern.Split([' ', #9],
            TStringSplitOptions.ExcludeEmpty);
        fsgmRegex:
          begin
            vLiterals := RegexLiterals(Pattern);
            vJob.RegexPattern := '(*ANYCRLF)' + Pattern;
          end;
        fsgmSymbol:
          begin
            vName := Trim(Pattern);
            vLiterals := [vName];
            vJob.RegexPattern := '(*ANYCRLF)' + SymbolPattern(vName);
          end;
      end;
      if Mode in [fsgmLiteral, fsgmWords] then
      begin
        SetLength(vJob.Needles, Length(vLiterals));
        for i := 0 to High(vLiterals) do
          if vJob.CaseSensitive then
            vJob.Needles[i] := vLiterals[i]
          else
            vJob.Needles[i] := sgcFSearchFoldText(vLiterals[i]);
      end
      else
      begin
        vCheck := TRegEx.Create(vJob.RegexPattern, vJob.RegexOptions);
        vCheck.IsMatch('');
      end;
      // raises on an invalid pattern
      vDocs := ContentIndex.CandidateDocs(vLiterals);
      if Assigned(Filter) then
      begin
        n := 0;
        for i := 0 to High(vDocs) do
          if Filter(vDocs[i].Path) then
          begin
            if n <> i then
              vDocs[n] := vDocs[i];
            Inc(n);
          end;
        SetLength(vDocs, n);
      end;
      FCandidateCount := Length(vDocs);
      vJob.Docs := vDocs;
      SetLength(vJob.Results, Length(vDocs));
      vThreads := Min(FThreadCount, Length(vDocs) div 2);
      if vThreads <= 1 then
        vJob.Run
      else
      begin
        SetLength(vWorkers, vThreads);
        for i := 0 to vThreads - 1 do
          vWorkers[i] := TsgcFSearchGrepWorker.Create(vJob);
        for i := 0 to vThreads - 1 do
        begin
          vWorkers[i].WaitFor;
          vWorkers[i].Free;
        end;
      end;
      n := 0;
      for i := 0 to High(vJob.Results) do
      begin
        if n >= Limit then
          Break;
        if Length(vJob.Results[i]) = 0 then
          Continue;
        Inc(FFilesMatched);
        for j := 0 to High(vJob.Results[i]) do
        begin
          if n >= Limit then
            Break;
          if n = Length(Hits) then
            SetLength(Hits, Max(16, n * 2));
          Hits[n] := vJob.Results[i][j];
          Inc(n);
        end;
      end;
      SetLength(Hits, n);
      FFilesVerified := vJob.Verified;
      Result := n;
    finally
      vJob.Free;
    end;
  finally
    FElapsedMs := vWatch.ElapsedMilliseconds;
  end;
end;

end.
