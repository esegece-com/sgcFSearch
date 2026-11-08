{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Engine;

{$I sgcVer.inc}
{ Engine facade used by the GUI app and the pipe server.

  Owns the config (DataDir\config.json, defaults when missing), the name
  index, crawler, watcher, usage, searcher, content index + indexer.

  Lifecycle (Start returns at once, a background thread below normal
  priority runs it):
  - names.idx loads: loading -> catchup (journal catch-up per root, roots of
  Config.Drives missing from the index are crawled) -> ready;
  - first run: crawling (journal position queried per root BEFORE its crawl,
  stored with SetRootJournal, then a journal catch-up of the changes made
  during the crawl), names.idx saved -> ready;
  - content.idx is loaded after names.idx, the content indexer (below normal
  priority) starts over Config.ExpandedRoots once the names are ready;
  - ready: watcher running, checkpoint every 5 minutes when the Generation
  changed (journal Snapshot per root, then SaveToFile; content.idx too).
  A partial index (crawl or catch-up interrupted by Stop) is never saved.
  Queries work in every state (partial index during the crawl).

  Events: OnChanged (index changed by the watcher, throttled to at most one
  per 100 ms) and OnStateChanged fire on the engine thread (OnStateChanged
  also on the thread calling Stop). Handlers must not block on the main
  thread (TThread.Synchronize): use TThread.Queue or PostMessage. Stop pumps
  CheckSynchronize while waiting when called from the main thread.

  Thread safety: Search, Grep, HandleRequest, RecordUse, Status, Checkpoint
  and Stop may be called from any thread concurrently.
  - TsgcFSearchSearcher.Search is safe for concurrent calls: every cache
  (folded names, usage boosts, folder totals) is synced under its internal
  lock while the index read lock is held, each search then works on its own
  run object with references to immutable snapshots of the caches. One
  shared instance.
  - TsgcFSearchGrep keeps per-search state (cancel flag, statistics) in the
  instance: one instance per call.
  - The content filter callback takes the index read lock per call (never
  nested), the content index locks itself.
  Destroy must be called when no other thread uses the engine any more. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.JSON,
  // sgc
  sgcFSearch_Types, sgcFSearch_Index, sgcFSearch_Crawler, sgcFSearch_Config,
  sgcFSearch_Log, sgcFSearch_Watcher, sgcFSearch_Journal, sgcFSearch_Match,
  sgcFSearch_Query, sgcFSearch_Usage, sgcFSearch_Search, sgcFSearch_Trigram,
  sgcFSearch_Grep;

const
  SGCFS_ENGINE_VERSION = '1.0.2';
  SGCFS_CHECKPOINT_INTERVAL_MS = 5 * 60 * 1000;
  SGCFS_CHANGED_THROTTLE_MS = 100;

type
  TsgcFSearchEngineState = (fsesStarting, fsesLoading, fsesCrawling,
    fsesCatchUp, fsesReady, fsesStopping, fsesStopped);

  TsgcFSearchEngineStateEvent = procedure(Sender: TObject;
    State: TsgcFSearchEngineState) of object;

  TsgcFSearchEngineRow = record
    Path: string;
    Name: string;
    IsDir: Boolean;
    Size: Int64; // -1 = unknown (folders without sort:size)
    MTime: Int64; // FILETIME UTC, 0 = unknown
    Score: Single;
    MatchPos: Integer; // name highlight, 0-based, -1 = none
    MatchLen: Integer;
    IsContent: Boolean;
    LineNo: Integer; // content hits, 1-based
    LineText: string;
    TextMatchPos: Integer; // 0-based in LineText, -1 = none
    TextMatchLen: Integer;
  end;

  TsgcFSearchEngineRows = record
    Items: TArray<TsgcFSearchEngineRow>;
    Total: Integer; // name: all matches; content: hit lines
    ElapsedMs: Double;
    IsContentResult: Boolean;
  end;

  TsgcFSearchEngineStatus = record
    State: TsgcFSearchEngineState;
    Files: Integer;
    Folders: Integer;
    Crawled: Int64; // entries listed by the crawls of this session
    ContentPending: Integer; // queued files, +1 while the initial scan runs
    ContentIndexed: Integer; // documents in the content index
    Roots: TArray<string>;
    LastError: string;
  end;

  TsgcFSearchEngine = class
  private
    FDataDir: string;
    FConfig: TsgcFSearchConfig;
    FIndex: TsgcFSearchIndex;
    FCrawler: TsgcFSearchCrawler;
    FWatcher: TsgcFSearchWatcher;
    FUsage: TsgcFSearchUsage;
    FSearcher: TsgcFSearchSearcher;
    FContent: TsgcFSearchContentIndex;
    FIndexer: TsgcFSearchContentIndexer;
    FIndexerAbandoned: Boolean; // did not stop in DoShutdown: never freed
    FThread: TThread;
    FLock: TCriticalSection;
    FCheckpointLock: TCriticalSection;
    FStopEvent: TEvent;
    FChangeEvent: TEvent;
    FDoneEvent: TEvent;
    FState: TsgcFSearchEngineState;
    FStarted: Boolean;
    FStopping: Boolean;
    FReady: Boolean;
    FCrawling: Boolean;
    FLastError: string;
    FCrawledBase: Int64;
    FPlannedRoots: TArray<string>;
    FSavedGen: Int64;
    FContentSavedGen: Int64;
    FLastCheckpoint: UInt64;
    FStartTick: UInt64;
    FChangedGen: Int64;
    FLastCatchUp: TsgcFSearchCatchUpResult;
    FOnChanged: TsgcFSearchChangedEvent;
    FOnStateChanged: TsgcFSearchEngineStateEvent;
    function DoFileName(const Name: string): string;
    procedure DoSetState(Value: TsgcFSearchEngineState);
    procedure DoSetError(const Msg: string);
    function DoLoad: Boolean;
    procedure DoCatchUp;
    procedure DoCrawl(const Roots: TArray<string>);
    procedure DoStartLive;
    procedure DoServiceLoop;
    procedure DoShutdown;
    procedure DoRun;
    procedure DoSaveNames;
    procedure DoSaveContent;
    function DoCheckpoint(Force: Boolean): Boolean;
    procedure DoWatcherChanged(Sender: TObject; Generation: Int64);
    procedure DoWatcherFilesChanged(Sender: TObject;
      const Paths: TArray<string>; Removed: Boolean);
    procedure DoNameSearch(const Query: TsgcFSearchQuery; Limit: Integer;
      out Rows: TsgcFSearchEngineRows);
    procedure DoContentSearch(const Query: TsgcFSearchQuery;
      const Pattern: string; Mode: TsgcFSearchGrepMode; Limit: Integer;
      NameTerms: Boolean; out Rows: TsgcFSearchEngineRows);
    function DoRowsToJSON(const Rows: TsgcFSearchEngineRows;
      Response: TJSONObject): string;
    function DoErrorJSON(const Id: TJSONValue; const Msg: string): string;
    function GetState: TsgcFSearchEngineState;
    function GetLastCatchUp: TsgcFSearchCatchUpResult;
  public
    /// aDataDir '' = sgcFSearchDataDir. Loads DataDir\config.json.
    constructor Create(const aDataDir: string = '');
    destructor Destroy; override;
    /// Starts the lifecycle thread and returns at once (only once).
    procedure Start;
    /// Final checkpoint (watcher still running), then stops the watcher,
    /// the indexer and the engine thread. Idempotent, any thread, cancels a
    /// running crawl (a journal catch-up rescan runs to its end).
    procedure Stop;
    /// Saves names.idx (journal Snapshot first) when the index changed since
    /// the last save, or always with Force, and content.idx when it
    /// changed. Only once the engine is ready. Any thread.
    procedure Checkpoint(Force: Boolean = False);
    /// Protocol op 1 semantics. Raises on an invalid content regex.
    procedure Search(const Text: string; Limit: Integer;
      out Rows: TsgcFSearchEngineRows);
    /// Protocol op 2: content search, FilterText supplies the name filters.
    procedure Grep(const Pattern: string; Mode: TsgcFSearchGrepMode;
      const FilterText: string; Limit: Integer;
      out Rows: TsgcFSearchEngineRows);
    procedure RecordUse(const Path: string; Kind: TsgcFSearchUsageKind);
    function Status: TsgcFSearchEngineStatus;
    function StateText: string;
    /// Pipe protocol ops 1-4; '' for any other op (show, stop, unknown).
    /// Never raises, thread-safe.
    function HandleRequest(const Line: string): string;
    property DataDir: string read FDataDir;
    property Config: TsgcFSearchConfig read FConfig;
    property State: TsgcFSearchEngineState read GetState;
    /// Aggregate of the last startup catch-up (worst mode, summed counts).
    property LastCatchUp: TsgcFSearchCatchUpResult read GetLastCatchUp;
    property OnChanged: TsgcFSearchChangedEvent read FOnChanged
      write FOnChanged;
    property OnStateChanged: TsgcFSearchEngineStateEvent read FOnStateChanged
      write FOnStateChanged;
  end;

function sgcFSearchEngineStateText(State: TsgcFSearchEngineState): string;
function sgcFSearchGrepModeFromText(const Text: string;
  out Mode: TsgcFSearchGrepMode): Boolean;

implementation

const
  CS_STATE_TEXT: array [TsgcFSearchEngineState] of string = ('starting',
    'loading', 'crawling', 'catchup', 'ready', 'stopping', 'stopped');
  CS_CATCHUP_TEXT: array [TsgcFSearchCatchUpMode] of string = ('journal',
    'rescan', 'failed');

type
  TsgcFSearchEngineThread = class(TThread)
  private
    FEngine: TsgcFSearchEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(const aEngine: TsgcFSearchEngine);
  end;

function sgcFSearchEngineStateText(State: TsgcFSearchEngineState): string;
begin
  Result := CS_STATE_TEXT[State];
end;

function sgcFSearchGrepModeFromText(const Text: string;
  out Mode: TsgcFSearchGrepMode): Boolean;
var
  vText: string;
begin
  Result := True;
  vText := LowerCase(Trim(Text));
  if (vText = '') or (vText = 'literal') or (vText = 'grep') then
    Mode := fsgmLiteral
  else if vText = 'words' then
    Mode := fsgmWords
  else if vText = 'regex' then
    Mode := fsgmRegex
  else if (vText = 'sym') or (vText = 'symbol') then
    Mode := fsgmSymbol
  else
  begin
    Mode := fsgmLiteral;
    Result := False;
  end;
end;

function DoElapsedMs(T0: Int64): Double;
var
  vCount, vFreq: Int64;
begin
  QueryPerformanceFrequency(vFreq);
  QueryPerformanceCounter(vCount);
  Result := (vCount - T0) * 1000.0 / vFreq;
end;

function DoQpc: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function DoISOTime(FileTime: Int64): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"',
    sgcFSearchFileTimeToDateTimeUTC(FileTime));
end;

{ TsgcFSearchEngineThread }

constructor TsgcFSearchEngineThread.Create(const aEngine: TsgcFSearchEngine);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEngine := aEngine;
end;

procedure TsgcFSearchEngineThread.Execute;
begin
  FEngine.DoRun;
end;

{ TsgcFSearchEngine }

constructor TsgcFSearchEngine.Create(const aDataDir: string = '');
begin
  inherited Create;
  if aDataDir = '' then
    FDataDir := sgcFSearchDataDir
  else
  begin
    FDataDir := ExcludeTrailingPathDelimiter(aDataDir);
    ForceDirectories(FDataDir);
  end;
  FLock := TCriticalSection.Create;
  FCheckpointLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FChangeEvent := TEvent.Create(nil, False, False, '');
  FDoneEvent := TEvent.Create(nil, True, False, '');
  FConfig := TsgcFSearchConfig.Create;
  FConfig.LoadFromFile(DoFileName(SGCFS_CONFIG_FILE));
  FIndex := TsgcFSearchIndex.Create;
  FCrawler := TsgcFSearchCrawler.Create;
  FUsage := TsgcFSearchUsage.Create(DoFileName(SGCFS_USAGE_FILE));
  FSearcher := TsgcFSearchSearcher.Create(FIndex, FUsage);
  FContent := TsgcFSearchContentIndex.Create;
  FState := fsesStarting;
  FSavedGen := -1;
  FContentSavedGen := FContent.Generation;
end;

destructor TsgcFSearchEngine.Destroy;
begin
  Stop;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FreeAndNil(FWatcher);
  if FIndexerAbandoned then
    FIndexer := nil
  else
    FreeAndNil(FIndexer);
  FreeAndNil(FSearcher);
  FreeAndNil(FUsage);
  FreeAndNil(FContent);
  FreeAndNil(FCrawler);
  FreeAndNil(FIndex);
  FreeAndNil(FConfig);
  FreeAndNil(FDoneEvent);
  FreeAndNil(FChangeEvent);
  FreeAndNil(FStopEvent);
  FreeAndNil(FCheckpointLock);
  FreeAndNil(FLock);
  inherited;
end;

function TsgcFSearchEngine.DoFileName(const Name: string): string;
begin
  Result := FDataDir + '\' + Name;
end;

function TsgcFSearchEngine.GetState: TsgcFSearchEngineState;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchEngine.GetLastCatchUp: TsgcFSearchCatchUpResult;
begin
  FLock.Enter;
  try
    Result := FLastCatchUp;
  finally
    FLock.Leave;
  end;
end;

function TsgcFSearchEngine.StateText: string;
begin
  Result := sgcFSearchEngineStateText(GetState);
end;

procedure TsgcFSearchEngine.DoSetState(Value: TsgcFSearchEngineState);
var
  vChanged: Boolean;
begin
  FLock.Enter;
  try
    // never leave stopping / stopped once Stop ran
    if FStopping and not(Value in [fsesStopping, fsesStopped]) then
      Exit;
    if (FState = fsesStopped) and (Value = fsesStopping) then
      Exit;
    vChanged := FState <> Value;
    FState := Value;
  finally
    FLock.Leave;
  end;
  if vChanged then
  begin
    sgcFSearchLog('engine: state ' + CS_STATE_TEXT[Value]);
    if Assigned(FOnStateChanged) then
      try
        FOnStateChanged(Self, Value);
      except
        on E: Exception do
          sgcFSearchLog('engine: OnStateChanged error: ' + E.Message);
      end;
  end;
end;

procedure TsgcFSearchEngine.DoSetError(const Msg: string);
begin
  FLock.Enter;
  try
    FLastError := Msg;
  finally
    FLock.Leave;
  end;
  sgcFSearchLog('engine: ' + Msg);
end;

procedure TsgcFSearchEngine.Start;
begin
  FLock.Enter;
  try
    if FStarted or FStopping then
      Exit;
    FStarted := True;
    FStartTick := GetTickCount64;
    FThread := TsgcFSearchEngineThread.Create(Self);
  finally
    FLock.Leave;
  end;
  FThread.Priority := tpLower;
  FThread.Start;
end;

procedure TsgcFSearchEngine.Stop;
var
  vThread: TThread;
begin
  FLock.Enter;
  try
    FStopping := True;
    vThread := FThread;
  finally
    FLock.Leave;
  end;
  DoSetState(fsesStopping);
  FStopEvent.SetEvent;
  if vThread = nil then
  begin
    DoSetState(fsesStopped);
    Exit;
  end;
  // called from the engine thread (an event handler): it finishes alone
  if GetCurrentThreadId = vThread.ThreadID then
    Exit;
  // CrawlRoot resets its cancel flag when it starts: cancel until done
  while FDoneEvent.WaitFor(20) <> wrSignaled do
  begin
    FCrawler.Cancel;
    if GetCurrentThreadId = MainThreadID then
      CheckSynchronize(0);
  end;
end;

function TsgcFSearchEngine.DoLoad: Boolean;
var
  vFile: string;
  vT0: Int64;
  vRoots, vFiles, vFolders: Integer;
begin
  Result := False;
  vFile := DoFileName(SGCFS_INDEX_FILE);
  if FileExists(vFile) then
  begin
    DoSetState(fsesLoading);
    vT0 := DoQpc;
    try
      Result := FIndex.LoadFromFile(vFile);
    except
      on E: Exception do
      begin
        DoSetError('names.idx load error: ' + E.Message);
        Result := False;
      end;
    end;
    FIndex.BeginRead;
    try
      vRoots := FIndex.RootCount;
      vFiles := FIndex.FileCount;
      vFolders := FIndex.FolderCount;
    finally
      FIndex.EndRead;
    end;
    if Result and (vRoots > 0) then
      sgcFSearchLog(Format('engine: names.idx loaded, %d files, %d folders, ' +
        '%d roots, %.0f ms', [vFiles, vFolders, vRoots, DoElapsedMs(vT0)]))
    else
    begin
      Result := False;
      sgcFSearchLog('engine: names.idx invalid or empty, full crawl');
      FIndex.BeginWrite;
      try
        FIndex.Clear;
      finally
        FIndex.EndWrite;
      end;
    end;
    FIndex.BeginRead;
    try
      FSavedGen := FIndex.Generation;
    finally
      FIndex.EndRead;
    end;
  end;
  vFile := DoFileName(SGCFS_CONTENT_FILE);
  if FileExists(vFile) then
  begin
    vT0 := DoQpc;
    try
      if FContent.LoadFromFile(vFile) then
        sgcFSearchLog(Format('engine: content.idx loaded, %d docs, %.0f ms',
          [FContent.DocCount, DoElapsedMs(vT0)]))
      else
        sgcFSearchLog('engine: content.idx invalid, rebuilt by the indexer');
    except
      on E: Exception do
        DoSetError('content.idx load error: ' + E.Message);
    end;
  end;
  FContentSavedGen := FContent.Generation;
end;

procedure TsgcFSearchEngine.DoCatchUp;
var
  vSkip, vMissing: TArray<string>;
  vCount, i: Integer;
  vRes, vAll: TsgcFSearchCatchUpResult;
  vT0: Int64;
  vPath: string;
begin
  DoSetState(fsesCatchUp);
  vSkip := FConfig.ExpandedSkip;
  FIndex.BeginRead;
  try
    vCount := FIndex.RootCount;
  finally
    FIndex.EndRead;
  end;
  vAll := Default (TsgcFSearchCatchUpResult);
  vAll.Mode := fscmJournal;
  for i := 0 to vCount - 1 do
  begin
    if FStopping then
      Exit;
    vT0 := DoQpc;
    vRes := TsgcFSearchJournal.CatchUp(FIndex, i, vSkip);
    FIndex.BeginRead;
    try
      vPath := FIndex.Root(i).Path;
    finally
      FIndex.EndRead;
    end;
    sgcFSearchLog(Format('engine: catch-up %s: %s, %d records, %d unknown ' +
      'refs, %d folders re-listed, %.0f ms', [vPath, CS_CATCHUP_TEXT[vRes.Mode],
      vRes.Records, vRes.UnknownRefs, vRes.Stats.Folders, DoElapsedMs(vT0)]));
    if Ord(vRes.Mode) > Ord(vAll.Mode) then
      vAll.Mode := vRes.Mode;
    Inc(vAll.Records, vRes.Records);
    Inc(vAll.UnknownRefs, vRes.UnknownRefs);
    Inc(vAll.Stats.Folders, vRes.Stats.Folders);
    Inc(vAll.Stats.Added, vRes.Stats.Added);
    Inc(vAll.Stats.Removed, vRes.Stats.Removed);
    Inc(vAll.Stats.Updated, vRes.Stats.Updated);
    Inc(vAll.Stats.Subtrees, vRes.Stats.Subtrees);
    Inc(vAll.Stats.Errors, vRes.Stats.Errors);
    vAll.NextUsn := vRes.NextUsn;
    FLock.Enter;
    try
      FLastCatchUp := vAll;
    finally
      FLock.Leave;
    end;
  end;
  // configured roots the saved index does not hold yet
  vMissing := nil;
  FIndex.BeginRead;
  try
    for i := 0 to High(FPlannedRoots) do
      if FIndex.FindRoot(FPlannedRoots[i]) < 0 then
        vMissing := vMissing + [FPlannedRoots[i]];
  finally
    FIndex.EndRead;
  end;
  if Length(vMissing) > 0 then
    DoCrawl(vMissing);
end;

procedure TsgcFSearchEngine.DoCrawl(const Roots: TArray<string>);
var
  vSkip: TArray<string>;
  vRoot: string;
  vHasJournal: Boolean;
  vJournalId: UInt64;
  vNextUsn, vFirstUsn, vT0: Int64;
  vNo: Integer;
  vRes: TsgcFSearchCatchUpResult;
begin
  if Length(Roots) = 0 then
    Exit;
  DoSetState(fsesCrawling);
  vSkip := FConfig.ExpandedSkip;
  for vRoot in Roots do
  begin
    if FStopping then
      Exit;
    // journal position before the crawl: the catch-up replays what changed
    // while the crawl ran
    vHasJournal := TsgcFSearchJournal.Query(vRoot, vJournalId, vNextUsn,
      vFirstUsn);
    FLock.Enter;
    try
      FCrawling := True;
    finally
      FLock.Leave;
    end;
    vT0 := DoQpc;
    vNo := FCrawler.CrawlRoot(FIndex, vRoot, vSkip);
    FLock.Enter;
    try
      FCrawling := False;
      FCrawledBase := FCrawledBase + FCrawler.Entries;
    finally
      FLock.Leave;
    end;
    if FStopping or FCrawler.Cancelled then
    begin
      sgcFSearchLog('engine: crawl of ' + vRoot + ' cancelled');
      Exit;
    end;
    if vNo < 0 then
    begin
      DoSetError('cannot open root ' + vRoot);
      Continue;
    end;
    sgcFSearchLog(Format('engine: crawled %s: %d entries, %d folders, ' +
      '%d errors, %.0f ms, journal %s', [vRoot, FCrawler.Entries,
      FCrawler.FoldersDone, FCrawler.Errors, DoElapsedMs(vT0),
      BoolToStr(vHasJournal, True)]));
    FIndex.BeginWrite;
    try
      if vHasJournal then
        FIndex.SetRootJournal(vNo, vJournalId, vNextUsn)
      else
        FIndex.SetRootJournal(vNo, 0, 0);
    finally
      FIndex.EndWrite;
    end;
    if vHasJournal then
    begin
      vT0 := DoQpc;
      vRes := TsgcFSearchJournal.CatchUp(FIndex, vNo, vSkip);
      sgcFSearchLog(Format('engine: post-crawl catch-up %s: %s, %d records, ' +
        '%.0f ms', [vRoot, CS_CATCHUP_TEXT[vRes.Mode], vRes.Records,
        DoElapsedMs(vT0)]));
    end;
  end;
  if not FStopping then
    DoSaveNames;
end;

procedure TsgcFSearchEngine.DoSaveNames;
var
  vGen, vT0: Int64;
  vFiles, vFolders: Integer;
begin
  FIndex.BeginRead;
  try
    vGen := FIndex.Generation;
    vFiles := FIndex.FileCount;
    vFolders := FIndex.FolderCount;
  finally
    FIndex.EndRead;
  end;
  vT0 := DoQpc;
  FIndex.SaveToFile(DoFileName(SGCFS_INDEX_FILE));
  FSavedGen := vGen;
  sgcFSearchLog(Format('engine: names.idx saved, %d files, %d folders, ' +
    '%.0f ms', [vFiles, vFolders, DoElapsedMs(vT0)]));
end;

procedure TsgcFSearchEngine.DoSaveContent;
var
  vGen, vT0: Int64;
begin
  vGen := FContent.Generation;
  if vGen = FContentSavedGen then
    Exit;
  vT0 := DoQpc;
  FContent.SaveToFile(DoFileName(SGCFS_CONTENT_FILE));
  FContentSavedGen := vGen;
  sgcFSearchLog(Format('engine: content.idx saved, %d docs, %.0f ms',
    [FContent.DocCount, DoElapsedMs(vT0)]));
end;

function TsgcFSearchEngine.DoCheckpoint(Force: Boolean): Boolean;
var
  vGen: Int64;
  vCount, i: Integer;
begin
  Result := False;
  FCheckpointLock.Enter;
  try
    try
      if not FReady then
        Exit;
      FLastCheckpoint := GetTickCount64;
      FIndex.BeginRead;
      try
        vGen := FIndex.Generation;
        vCount := FIndex.RootCount;
      finally
        FIndex.EndRead;
      end;
      if Force or (vGen <> FSavedGen) then
      begin
        for i := 0 to vCount - 1 do
          TsgcFSearchJournal.Snapshot(FIndex, i);
        DoSaveNames;
        Result := True;
      end;
      DoSaveContent;
    except
      on E: Exception do
        DoSetError('checkpoint error: ' + E.Message);
    end;
  finally
    FCheckpointLock.Leave;
  end;
end;

procedure TsgcFSearchEngine.Checkpoint(Force: Boolean = False);
begin
  DoCheckpoint(Force);
end;

procedure TsgcFSearchEngine.DoStartLive;
var
  vRoots, vSkip: TArray<string>;
  vT0: Int64;
begin
  vT0 := DoQpc;
  vRoots := FConfig.ExpandedRoots;
  vSkip := FConfig.ExpandedSkip;
  FIndexer := TsgcFSearchContentIndexer.Create(FIndex, FContent, vRoots, vSkip,
    FConfig.ContentMaxSizeMB);
  FIndexer.Priority := tpLower;
  FWatcher := TsgcFSearchWatcher.Create(FIndex, vSkip);
  FWatcher.OnChanged := DoWatcherChanged;
  FWatcher.OnFilesChanged := DoWatcherFilesChanged;
  // index saves, content.idx and daemon.log must not feed changes back
  FWatcher.IgnorePaths := [FDataDir];
  FWatcher.Start;
  FIndexer.Start;
  FLastCheckpoint := GetTickCount64;
  FCheckpointLock.Enter;
  try
    FReady := True;
  finally
    FCheckpointLock.Leave;
  end;
  sgcFSearchLog(Format('engine: watcher on %d roots, content indexer on %d ' +
    'roots, %.0f ms', [FWatcher.WatchedCount, Length(vRoots),
    DoElapsedMs(vT0)]));
  DoSetState(fsesReady);
  sgcFSearchLog(Format('engine: ready %d ms after Start',
    [Int64(GetTickCount64 - FStartTick)]));
end;

procedure TsgcFSearchEngine.DoServiceLoop;
var
  vHandles: array [0 .. 1] of THandle;
  vWait: Cardinal;
begin
  vHandles[0] := FStopEvent.Handle;
  vHandles[1] := FChangeEvent.Handle;
  while not FStopping do
  begin
    vWait := WaitForMultipleObjects(2, @vHandles[0], False, 1000);
    if vWait = WAIT_OBJECT_0 then
      Break;
    if vWait = WAIT_OBJECT_0 + 1 then
    begin
      if Assigned(FOnChanged) then
        try
          FOnChanged(Self, TInterlocked.Read(FChangedGen));
        except
          on E: Exception do
            sgcFSearchLog('engine: OnChanged error: ' + E.Message);
        end;
      // throttle: changes in the next 100 ms are coalesced
      if FStopEvent.WaitFor(SGCFS_CHANGED_THROTTLE_MS) = wrSignaled then
        Break;
    end;
    if GetTickCount64 - FLastCheckpoint >= SGCFS_CHECKPOINT_INTERVAL_MS then
      DoCheckpoint(False);
  end;
end;

procedure TsgcFSearchEngine.DoShutdown;
const
  CS_STOP_WAIT_MS = 3000;
var
  vT0: Int64;
begin
  vT0 := DoQpc;
  // snapshot + save while the watcher still runs
  DoCheckpoint(True);
  FCheckpointLock.Enter;
  try
    FReady := False;
  finally
    FCheckpointLock.Leave;
  end;
  try
    // bounded: a thread stuck in a file system call must not keep the
    // process alive, it is abandoned and content.idx is saved anyway
    if FWatcher <> nil then
      FWatcher.Stop(CS_STOP_WAIT_MS);
    if (FIndexer <> nil) and not FIndexer.Stop(CS_STOP_WAIT_MS) then
    begin
      FIndexerAbandoned := True;
      sgcFSearchLog(Format('engine: content indexer did not stop within ' +
        '%d ms, abandoned', [CS_STOP_WAIT_MS]));
    end;
    if FIndexer <> nil then
    begin
      FCheckpointLock.Enter;
      try
        DoSaveContent;
      finally
        FCheckpointLock.Leave;
      end;
    end;
  except
    on E: Exception do
      DoSetError('shutdown error: ' + E.Message);
  end;
  sgcFSearchLog(Format('engine: stopped, shutdown %.0f ms',
    [DoElapsedMs(vT0)]));
end;

procedure TsgcFSearchEngine.DoRun;
var
  vLoaded: Boolean;
  vRoots: TArray<string>;
  i: Integer;
begin
  try
    try
      sgcFSearchLog('engine: start, data dir ' + FDataDir);
      if Length(FConfig.Drives) > 0 then
      begin
        vRoots := FConfig.Drives;
        vRoots := Copy(vRoots);
        for i := 0 to High(vRoots) do
          vRoots[i] := sgcFSearchExpandUserPath(vRoots[i]);
      end
      else
        vRoots := TsgcFSearchCrawler.EnumFixedDrives;
      FLock.Enter;
      try
        FPlannedRoots := vRoots;
      finally
        FLock.Leave;
      end;
      vLoaded := DoLoad;
      if not FStopping then
      begin
        if vLoaded then
          DoCatchUp
        else
          DoCrawl(vRoots);
      end;
      if not FStopping then
      begin
        DoStartLive;
        DoServiceLoop;
      end;
    except
      on E: Exception do
        DoSetError('engine thread error: ' + E.Message);
    end;
    DoShutdown;
  finally
    DoSetState(fsesStopping);
    DoSetState(fsesStopped);
    FDoneEvent.SetEvent;
  end;
end;

procedure TsgcFSearchEngine.DoWatcherChanged(Sender: TObject;
  Generation: Int64);
begin
  TInterlocked.Exchange(FChangedGen, Generation);
  FChangeEvent.SetEvent;
end;

procedure TsgcFSearchEngine.DoWatcherFilesChanged(Sender: TObject;
  const Paths: TArray<string>; Removed: Boolean);
var
  vIndexer: TsgcFSearchContentIndexer;
  i: Integer;
begin
  vIndexer := FIndexer;
  if vIndexer = nil then
    Exit;
  for i := 0 to High(Paths) do
    if vIndexer.IsIndexablePath(Paths[i]) then
    begin
      if Removed then
        vIndexer.NotifyRemoved(Paths[i])
      else
        vIndexer.NotifyChanged(Paths[i]);
    end;
end;

procedure TsgcFSearchEngine.DoNameSearch(const Query: TsgcFSearchQuery;
  Limit: Integer; out Rows: TsgcFSearchEngineRows);
var
  vRes: TsgcFSearchResults;
  vSame: Boolean;
  i, n: Integer;
  vRow: TsgcFSearchEngineRow;
begin
  Rows := Default (TsgcFSearchEngineRows);
  FSearcher.Search(Query, Limit, vRes);
  Rows.Total := vRes.Total;
  Rows.ElapsedMs := vRes.ElapsedMs;
  SetLength(Rows.Items, Length(vRes.Items));
  n := 0;
  // Search released its read lock: resolve the paths under a new one
  FIndex.BeginRead;
  try
    vSame := FIndex.Generation = vRes.Generation;
    for i := 0 to High(vRes.Items) do
    begin
      if not vSame then
        if (vRes.Items[i].EntryIdx >= FIndex.EntryCount) or
          not FIndex.IsLive(vRes.Items[i].EntryIdx) or
          (FIndex.EntryPtr(vRes.Items[i].EntryIdx).NameId <> vRes.Items[i]
          .NameId) then
          Continue;
      vRow := Default (TsgcFSearchEngineRow);
      vRow.Path := FIndex.FullPath(vRes.Items[i].EntryIdx);
      vRow.Name := FIndex.NameOf(vRes.Items[i].EntryIdx);
      vRow.IsDir := vRes.Items[i].IsDir;
      vRow.Size := vRes.Items[i].Size;
      vRow.MTime := vRes.Items[i].MTime;
      vRow.Score := vRes.Items[i].Score;
      vRow.MatchPos := vRes.Items[i].MatchPos;
      vRow.MatchLen := vRes.Items[i].MatchLen;
      vRow.TextMatchPos := -1;
      Rows.Items[n] := vRow;
      Inc(n);
    end;
  finally
    FIndex.EndRead;
  end;
  SetLength(Rows.Items, n);
end;

procedure TsgcFSearchEngine.DoContentSearch(const Query: TsgcFSearchQuery;
  const Pattern: string; Mode: TsgcFSearchGrepMode; Limit: Integer;
  NameTerms: Boolean; out Rows: TsgcFSearchEngineRows);
var
  vQ: TsgcFSearchQuery;
  vTerms, vWilds: TArray<string>;
  vFiltered: Boolean;
  vFilter: TFunc<string, Boolean>;
  vGrep: TsgcFSearchGrep;
  vHits: TsgcFSearchGrepHits;
  vT0: Int64;
  vLimit, i, vIdx: Integer;
  vEntry: PsgcFSearchEntry;
  vRow: TsgcFSearchEngineRow;
begin
  Rows := Default (TsgcFSearchEngineRows);
  Rows.IsContentResult := True;
  vT0 := DoQpc;
  vQ := Query;
  if vQ.Limit > 0 then
    vLimit := vQ.Limit
  else if Limit > 0 then
    vLimit := Limit
  else
    vLimit := SGCFS_DEFAULT_LIMIT;
  // positive name terms of an explicit content query: folded substrings of
  // the file name (the words fallback searches them as content instead),
  // wildcard terms as patterns on the whole name
  vTerms := nil;
  vWilds := nil;
  if NameTerms then
    for i := 0 to High(vQ.Terms) do
      if not vQ.Terms[i].Exclude and (vQ.Terms[i].Folded <> '') then
      begin
        if vQ.Terms[i].Kind = fsmkWildcard then
          vWilds := vWilds + [vQ.Terms[i].Folded]
        else
          vTerms := vTerms + [vQ.Terms[i].Folded];
      end;
  vFiltered := (Length(vTerms) > 0) or (Length(vWilds) > 0) or
    (Length(vQ.Exts) > 0) or vQ.HasType or (vQ.Kind <> fskAny) or
    (Length(vQ.InPaths) > 0) or (Length(vQ.PathTexts) > 0) or vQ.HasSize or
    vQ.HasMTime or (vQ.NameRegex <> '');
  if not vFiltered then
    for i := 0 to High(vQ.Terms) do
      if vQ.Terms[i].Exclude then
        vFiltered := True;
  vFilter := nil;
  if vFiltered then
    vFilter := function(Path: string): Boolean var vEnt, j, vPos, vLen: Integer;
vName:
  string;
  begin
    Result := False;
    FIndex.BeginRead;
    try
      vEnt := FIndex.FindPath(Path);
      if (vEnt < 0) or not FSearcher.MatchesFilters(vEnt, vQ) then
        Exit;
      if (Length(vTerms) > 0) or (Length(vWilds) > 0) then
      begin
        vName := sgcFSearchFold(FIndex.NameOf(vEnt));
        for j := 0 to High(vTerms) do
          if Pos(vTerms[j], vName) = 0 then
            Exit;
        for j := 0 to High(vWilds) do
          if sgcFSearchMatchQuality(PChar(vName), nil, Length(vName),
            PChar(vWilds[j]), Length(vWilds[j]), fsmkWildcard, nil, vPos, vLen)
            = SGCFS_QUALITY_NONE then
            Exit;
      end;
      Result := True;
    finally
      FIndex.EndRead;
    end;
  end;
  vGrep := TsgcFSearchGrep.Create;
  try
    vGrep.Indexer := FIndexer;
    vGrep.Search(FContent, Pattern, Mode, vLimit, vFilter, vHits);
  finally
    vGrep.Free;
  end;
  Rows.Total := Length(vHits);
  SetLength(Rows.Items, Length(vHits));
  FIndex.BeginRead;
  try
    for i := 0 to High(vHits) do
    begin
      vRow := Default (TsgcFSearchEngineRow);
      vRow.Path := vHits[i].Path;
      vRow.Name := ExtractFileName(vHits[i].Path);
      vRow.Size := -1;
      vRow.MatchPos := -1;
      vIdx := FIndex.FindPath(vHits[i].Path);
      if vIdx >= 0 then
      begin
        vEntry := FIndex.EntryPtr(vIdx);
        vRow.IsDir := (vEntry.Flags and SGCFS_FLAG_DIR) <> 0;
        if not vRow.IsDir then
          vRow.Size := vEntry.Size;
        vRow.MTime := vEntry.MTime;
      end;
      vRow.IsContent := True;
      vRow.LineNo := vHits[i].LineNo;
      vRow.LineText := vHits[i].LineText;
      if vHits[i].MatchPos > 0 then
        vRow.TextMatchPos := vHits[i].MatchPos - 1
      else
        vRow.TextMatchPos := -1;
      vRow.TextMatchLen := vHits[i].MatchLen;
      Rows.Items[i] := vRow;
    end;
  finally
    FIndex.EndRead;
  end;
  Rows.ElapsedMs := DoElapsedMs(vT0);
end;

procedure TsgcFSearchEngine.Search(const Text: string; Limit: Integer;
  out Rows: TsgcFSearchEngineRows);
var
  vQ: TsgcFSearchQuery;
  vWords: string;
  vContent: TsgcFSearchEngineRows;
  i: Integer;
begin
  vQ := sgcFSearchParseQuery(Text);
  if vQ.HasContentFilters then
  begin
    if vQ.Grep <> '' then
      DoContentSearch(vQ, vQ.Grep, fsgmLiteral, Limit, True, Rows)
    else if vQ.ContentRegex <> '' then
      DoContentSearch(vQ, vQ.ContentRegex, fsgmRegex, Limit, True, Rows)
    else
      DoContentSearch(vQ, vQ.Sym, fsgmSymbol, Limit, True, Rows);
    Exit;
  end;
  DoNameSearch(vQ, Limit, Rows);
  if (Rows.Total = 0) and vQ.HasNameTerms then
  begin
    // content fallback: every name word must be in the file (a wildcard
    // pattern is not a content word)
    vWords := '';
    for i := 0 to High(vQ.Terms) do
      if not vQ.Terms[i].Exclude and (vQ.Terms[i].Text <> '') and
        (vQ.Terms[i].Kind <> fsmkWildcard) then
      begin
        if vWords <> '' then
          vWords := vWords + ' ';
        vWords := vWords + vQ.Terms[i].Text;
      end;
    if vWords <> '' then
    begin
      DoContentSearch(vQ, vWords, fsgmWords, Limit, False, vContent);
      if Length(vContent.Items) > 0 then
      begin
        vContent.ElapsedMs := vContent.ElapsedMs + Rows.ElapsedMs;
        Rows := vContent;
      end;
    end;
  end;
end;

procedure TsgcFSearchEngine.Grep(const Pattern: string;
  Mode: TsgcFSearchGrepMode; const FilterText: string; Limit: Integer;
  out Rows: TsgcFSearchEngineRows);
begin
  DoContentSearch(sgcFSearchParseQuery(FilterText), Pattern, Mode, Limit,
    True, Rows);
end;

procedure TsgcFSearchEngine.RecordUse(const Path: string;
  Kind: TsgcFSearchUsageKind);
begin
  FUsage.RecordUse(Path, Kind);
end;

function TsgcFSearchEngine.Status: TsgcFSearchEngineStatus;
var
  vCrawling: Boolean;
  vPlanned: TArray<string>;
  vIndexer: TsgcFSearchContentIndexer;
  i: Integer;
begin
  Result := Default (TsgcFSearchEngineStatus);
  FLock.Enter;
  try
    Result.State := FState;
    Result.LastError := FLastError;
    Result.Crawled := FCrawledBase;
    vCrawling := FCrawling;
    vPlanned := FPlannedRoots;
  finally
    FLock.Leave;
  end;
  if vCrawling then
    Result.Crawled := Result.Crawled + FCrawler.Entries;
  FIndex.BeginRead;
  try
    Result.Files := FIndex.FileCount;
    Result.Folders := FIndex.FolderCount;
    SetLength(Result.Roots, FIndex.RootCount);
    for i := 0 to High(Result.Roots) do
      Result.Roots[i] := FIndex.Root(i).Path;
  finally
    FIndex.EndRead;
  end;
  if Length(Result.Roots) = 0 then
    Result.Roots := vPlanned;
  vIndexer := FIndexer;
  if vIndexer <> nil then
  begin
    Result.ContentPending := vIndexer.Pending;
    if not vIndexer.ScanDone and (Result.State = fsesReady) then
      Inc(Result.ContentPending);
  end;
  Result.ContentIndexed := FContent.DocCount;
end;

function TsgcFSearchEngine.DoErrorJSON(const Id: TJSONValue;
  const Msg: string): string;
var
  vR: TJSONObject;
begin
  try
    vR := TJSONObject.Create;
    try
      if Id <> nil then
        vR.AddPair('id', TJSONValue(Id.Clone));
      vR.AddPair('ok', TJSONBool.Create(False));
      vR.AddPair('error', Msg);
      Result := vR.ToJSON;
    finally
      vR.Free;
    end;
  except
    Result := '{"ok":false,"error":"internal error"}';
  end;
end;

function TsgcFSearchEngine.DoRowsToJSON(const Rows: TsgcFSearchEngineRows;
  Response: TJSONObject): string;
var
  vArr, vPair: TJSONArray;
  vO: TJSONObject;
  i: Integer;
begin
  Response.AddPair('ok', TJSONBool.Create(True));
  Response.AddPair('total', TJSONNumber.Create(Rows.Total));
  Response.AddPair('ms',
    TJSONNumber.Create(Round(Rows.ElapsedMs * 1000) / 1000));
  Response.AddPair('content', TJSONBool.Create(Rows.IsContentResult));
  vArr := TJSONArray.Create;
  Response.AddPair('results', vArr);
  for i := 0 to High(Rows.Items) do
  begin
    vO := TJSONObject.Create;
    vArr.AddElement(vO);
    vO.AddPair('path', Rows.Items[i].Path);
    vO.AddPair('name', Rows.Items[i].Name);
    vO.AddPair('dir', TJSONBool.Create(Rows.Items[i].IsDir));
    if Rows.Items[i].Size >= 0 then
      vO.AddPair('size', TJSONNumber.Create(Rows.Items[i].Size));
    if Rows.Items[i].MTime > 0 then
      vO.AddPair('mtime', DoISOTime(Rows.Items[i].MTime));
    if not Rows.Items[i].IsContent then
      vO.AddPair('score', TJSONNumber.Create(Round(Rows.Items[i].Score *
        100) / 100));
    if Rows.Items[i].MatchPos >= 0 then
    begin
      vPair := TJSONArray.Create;
      vPair.Add(Rows.Items[i].MatchPos);
      vPair.Add(Rows.Items[i].MatchLen);
      vO.AddPair('match', vPair);
    end;
    if Rows.Items[i].IsContent then
    begin
      vO.AddPair('line', TJSONNumber.Create(Rows.Items[i].LineNo));
      vO.AddPair('text', Rows.Items[i].LineText);
      if Rows.Items[i].TextMatchPos >= 0 then
      begin
        vPair := TJSONArray.Create;
        vPair.Add(Rows.Items[i].TextMatchPos);
        vPair.Add(Rows.Items[i].TextMatchLen);
        vO.AddPair('tmatch', vPair);
      end;
    end;
  end;
  Result := Response.ToJSON;
end;

function TsgcFSearchEngine.HandleRequest(const Line: string): string;
var
  vV, vId, vField: TJSONValue;
  vO, vR: TJSONObject;
  vLimit: Integer;
  vMode: TsgcFSearchGrepMode;
  vRows: TsgcFSearchEngineRows;
  vStatus: TsgcFSearchEngineStatus;
  vRoots: TJSONArray;
  vKind: string;
  i: Integer;
begin
  Result := '';
  vV := nil;
  vR := nil;
  vId := nil;
  try
    try
      vV := TJSONObject.ParseJSONValue(Line);
      if not(vV is TJSONObject) then
        Exit(DoErrorJSON(nil, 'invalid JSON request'));
      vO := TJSONObject(vV);
      vId := vO.GetValue('id');
      // ops of the app
      if (vO.GetValue('show') <> nil) or (vO.GetValue('stop') <> nil) then
        Exit('');
      vLimit := 0;
      vField := vO.GetValue('limit');
      if vField is TJSONNumber then
        vLimit := TJSONNumber(vField).AsInt;
      vR := TJSONObject.Create;
      if vId <> nil then
        vR.AddPair('id', TJSONValue(vId.Clone));
      if vO.GetValue('grep') <> nil then
      begin
        vField := vO.GetValue('mode');
        if vField = nil then
          vMode := fsgmLiteral
        else if not sgcFSearchGrepModeFromText(vField.Value, vMode) then
          Exit(DoErrorJSON(vId, 'unknown grep mode: ' + vField.Value));
        vField := vO.GetValue('q');
        if vField <> nil then
          Grep(vO.GetValue('grep').Value, vMode, vField.Value, vLimit, vRows)
        else
          Grep(vO.GetValue('grep').Value, vMode, '', vLimit, vRows);
        Result := DoRowsToJSON(vRows, vR);
      end
      else if vO.GetValue('q') <> nil then
      begin
        Search(vO.GetValue('q').Value, vLimit, vRows);
        Result := DoRowsToJSON(vRows, vR);
      end
      else if vO.GetValue('status') <> nil then
      begin
        vStatus := Status;
        vR.AddPair('ok', TJSONBool.Create(True));
        vR.AddPair('state', sgcFSearchEngineStateText(vStatus.State));
        vR.AddPair('files', TJSONNumber.Create(vStatus.Files));
        vR.AddPair('folders', TJSONNumber.Create(vStatus.Folders));
        vR.AddPair('crawled', TJSONNumber.Create(vStatus.Crawled));
        vR.AddPair('content_pending',
          TJSONNumber.Create(vStatus.ContentPending));
        vR.AddPair('content_indexed',
          TJSONNumber.Create(vStatus.ContentIndexed));
        vR.AddPair('pid', TJSONNumber.Create(Int64(GetCurrentProcessId)));
        vR.AddPair('version', SGCFS_ENGINE_VERSION);
        vRoots := TJSONArray.Create;
        vR.AddPair('roots', vRoots);
        for i := 0 to High(vStatus.Roots) do
          vRoots.Add(vStatus.Roots[i]);
        vR.AddPair('log', sgcFSearchLogFileName);
        if vStatus.LastError <> '' then
          vR.AddPair('last_error', vStatus.LastError);
        Result := vR.ToJSON;
      end
      else if vO.GetValue('use') <> nil then
      begin
        vKind := '';
        vField := vO.GetValue('kind');
        if vField <> nil then
          vKind := LowerCase(vField.Value);
        if (vKind = '') or (vKind = 'open') then
          RecordUse(vO.GetValue('use').Value, fsukOpen)
        else if vKind = 'copy' then
          RecordUse(vO.GetValue('use').Value, fsukCopy)
        else
          Exit(DoErrorJSON(vId, 'unknown use kind: ' + vKind));
        vR.AddPair('ok', TJSONBool.Create(True));
        Result := vR.ToJSON;
      end
      else
        Result := '';
    except
      on E: Exception do
        Result := DoErrorJSON(vId, E.Message);
    end;
  finally
    vR.Free;
    vV.Free;
  end;
end;

end.
