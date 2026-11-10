{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Search;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.DateUtils, System.Math, System.Generics.Collections, System.SyncObjs,
  // sgc
  sgcFSearch_Types in '..\..\Source\sgcFSearch_Types.pas',
  sgcFSearch_Index in '..\..\Source\sgcFSearch_Index.pas',
  sgcFSearch_Config in '..\..\Source\sgcFSearch_Config.pas',
  sgcFSearch_Match in '..\..\Source\sgcFSearch_Match.pas',
  sgcFSearch_Query in '..\..\Source\sgcFSearch_Query.pas',
  sgcFSearch_Usage in '..\..\Source\sgcFSearch_Usage.pas',
  sgcFSearch_Search in '..\..\Source\sgcFSearch_Search.pas';

const
  CS_MB = Int64(1024) * 1024;
  CS_FT_DAY = 864000000000.0;
  CS_SYNTH_ENTRIES = 2000000;

var
  GChecks, GFails: Integer;
  GHome: string;
  GIdx: TsgcFSearchIndex;
  GUsage: TsgcFSearchUsage;
  GS: TsgcFSearchSearcher;
  GNowFT: Int64;
  GBuild, GDocs, GSrc, GLib, GPhotos: Integer;
  GSeed: Cardinal = 2463534242;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(GChecks);
  if not Cond then
  begin
    Inc(GFails);
    Writeln('[FAIL] ', Msg);
  end;
end;

{ ---- parser ------------------------------------------------------------- }

function FT(const D: TDateTime): Int64;
begin
  Result := sgcFSearchLocalDateTimeToFileTime(D);
end;

function HasStr(const A: TArray<string>; const S: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(A) do
    if A[i] = S then
      Exit(True);
  Result := False;
end;

procedure TestParser;
var
  q: TsgcFSearchQuery;
  vNow: TDateTime;
  S: string;
begin
  vNow := EncodeDate(2026, 11, 3) + EncodeTime(15, 0, 0, 0);
  q := sgcFSearchParseQuery('foo  Bar', vNow);
  Check((Length(q.Terms) = 2) and (q.Terms[1].Folded = 'bar') and
    (q.Terms[1].Text = 'Bar') and (q.Terms[0].Kind = fsmkContains) and
    q.HasNameTerms and (Length(q.Warnings) = 0), 'parse words');
  q := sgcFSearchParseQuery('''exact ^pre suf$ !ex !^tmp ^both$', vNow);
  Check((Length(q.Terms) = 6) and (q.Terms[0].Kind = fsmkExact) and
    (q.Terms[0].Folded = 'exact') and (q.Terms[1].Kind = fsmkPrefix) and
    (q.Terms[2].Kind = fsmkSuffix) and (q.Terms[2].Folded = 'suf') and
    q.Terms[3].Exclude and (q.Terms[3].Kind = fsmkContains) and
    q.Terms[4].Exclude and (q.Terms[4].Kind = fsmkPrefix) and
    (q.Terms[5].Kind = fsmkExact), 'parse modifiers');
  q := sgcFSearchParseQuery('"my file" ''"a b"', vNow);
  Check((Length(q.Terms) = 2) and (q.Terms[0].Text = 'my file') and
    (q.Terms[1].Kind = fsmkExact) and (q.Terms[1].Text = 'a b'),
    'parse quotes');
  q := sgcFSearchParseQuery('!only', vNow);
  Check((Length(q.Terms) = 1) and not q.HasNameTerms, 'exclude only');
  q := sgcFSearchParseQuery('src\Main a/b/c node_modules\', vNow);
  Check((Length(q.Terms) = 3) and (q.Terms[0].Folded = 'main') and
    (Length(q.Terms[0].Dirs) = 1) and (q.Terms[0].Dirs[0] = 'src') and
    (Length(q.Terms[1].Dirs) = 2) and (q.Terms[1].Dirs[1] = 'b') and
    (q.Terms[1].Folded = 'c') and (q.Terms[2].Folded = '') and
    (q.Terms[2].Dirs[0] = 'node_modules'), 'parse path tokens');
  q := sgcFSearchParseQuery
    ('*.pas Report* a?c !*.tmp src\*.pas "my rep*"', vNow);
  Check((Length(q.Terms) = 6) and (q.Terms[0].Kind = fsmkWildcard) and
    (q.Terms[0].Folded = '*.pas') and (q.Terms[1].Kind = fsmkWildcard) and
    (q.Terms[1].Folded = 'report*') and (q.Terms[1].Text = 'Report*') and
    (q.Terms[2].Kind = fsmkWildcard) and (q.Terms[2].Folded = 'a?c') and
    q.Terms[3].Exclude and (q.Terms[3].Kind = fsmkWildcard) and
    (q.Terms[3].Folded = '*.tmp') and (q.Terms[4].Kind = fsmkWildcard) and
    (q.Terms[4].Folded = '*.pas') and (Length(q.Terms[4].Dirs) = 1) and
    (q.Terms[4].Dirs[0] = 'src') and (q.Terms[5].Kind = fsmkWildcard) and
    (q.Terms[5].Text = 'my rep*') and q.HasNameTerms, 'parse wildcards');
  q := sgcFSearchParseQuery('''*.PAS ^rep*$ s*c\main path:a*b', vNow);
  Check((Length(q.Terms) = 3) and (q.Terms[0].Kind = fsmkWildcard) and
    (q.Terms[0].Folded = '*.pas') and (q.Terms[1].Kind = fsmkWildcard) and
    (q.Terms[1].Folded = 'rep*') and (q.Terms[2].Kind = fsmkContains) and
    (q.Terms[2].Dirs[0] = 's*c') and (Length(q.PathTexts) = 1) and
    (q.PathTexts[0] = 'a*b'), 'parse wildcard modifiers, dirs and filters');
  q := sgcFSearchParseQuery('ext:pas,.DFM ext:', vNow);
  Check((Length(q.Exts) = 2) and (q.Exts[1] = 'dfm') and
    (Length(q.Warnings) = 1), 'parse ext');
  q := sgcFSearchParseQuery('type:images,folders type:bogus', vNow);
  Check(HasStr(q.TypeExts, 'jpg') and q.TypeDirs and q.HasType and
    (Length(q.Warnings) = 1), 'parse type');
  Check(sgcFSearchTypeExtensions('code') <> '', 'type code');
  Check(sgcFSearchParseQuery('kind:folder').Kind = fskDir, 'kind folder');
  Check(sgcFSearchParseQuery('kind:file').Kind = fskFile, 'kind file');
  q := sgcFSearchParseQuery('kind:x', vNow);
  Check((q.Kind = fskAny) and (Length(q.Warnings) = 1), 'kind invalid');
  q := sgcFSearchParseQuery('in:"C:\Program Files" in:~ in:D:/x/', vNow);
  Check((Length(q.InPaths) = 3) and (q.InPaths[0] = 'C:\Program Files') and
    (q.InPaths[1] = sgcFSearchExpandUserPath('~')) and (q.InPaths[2] = 'D:\x'),
    'parse in');
  q := sgcFSearchParseQuery('path:Foo/Bar', vNow);
  Check((Length(q.PathTexts) = 1) and (q.PathTexts[0] = 'foo\bar'),
    'parse path');
  q := sgcFSearchParseQuery('size:>10mb', vNow);
  Check(q.HasSize and (q.SizeMin = 10 * CS_MB + 1) and (q.SizeMax = High(Int64)
    ), 'size >');
  q := sgcFSearchParseQuery('size:<1k', vNow);
  Check(q.HasSize and (q.SizeMin = 0) and (q.SizeMax = 1023), 'size <');
  q := sgcFSearchParseQuery('size:1mb..5mb', vNow);
  Check((q.SizeMin = CS_MB) and (q.SizeMax = 5 * CS_MB), 'size range');
  q := sgcFSearchParseQuery('size:>=1.5k size:<=2g', vNow);
  Check((q.SizeMin = 1536) and (q.SizeMax = 2 * 1024 * CS_MB),
    'size >= <= combined');
  q := sgcFSearchParseQuery('size:empty', vNow);
  Check(q.HasSize and q.SizeEmpty and (q.SizeMax = 0), 'size empty');
  q := sgcFSearchParseQuery('size:abc', vNow);
  Check((not q.HasSize) and (Length(q.Warnings) = 1), 'size invalid');
  q := sgcFSearchParseQuery('mtime:today', vNow);
  Check(q.HasMTime and (q.MTimeMin = FT(EncodeDate(2026, 11, 3))) and
    (q.MTimeMax = High(Int64)), 'mtime today');
  q := sgcFSearchParseQuery('mtime:yesterday', vNow);
  Check((q.MTimeMin = FT(EncodeDate(2026, 11, 2))) and
    (q.MTimeMax = FT(EncodeDate(2026, 11, 3))), 'mtime yesterday');
  q := sgcFSearchParseQuery('mtime:week', vNow);
  Check(q.MTimeMin = FT(EncodeDate(2026, 10, 28)), 'mtime week');
  q := sgcFSearchParseQuery('mtime:<7d', vNow);
  Check(q.MTimeMin = FT(vNow - 7), 'mtime <7d');
  q := sgcFSearchParseQuery('mtime:>30d', vNow);
  Check((q.MTimeMax = FT(vNow - 30)) and (q.MTimeMin = Low(Int64)),
    'mtime >30d');
  q := sgcFSearchParseQuery('mtime:>2026-01-01', vNow);
  Check(q.MTimeMin = FT(EncodeDate(2026, 1, 2)), 'mtime > date');
  q := sgcFSearchParseQuery('mtime:2026-10-01..2026-10-31', vNow);
  Check((q.MTimeMin = FT(EncodeDate(2026, 10, 1))) and
    (q.MTimeMax = FT(EncodeDate(2026, 11, 1))), 'mtime range');
  q := sgcFSearchParseQuery('mtime:bogus', vNow);
  Check((not q.HasMTime) and (Length(q.Warnings) = 1), 'mtime invalid');
  q := sgcFSearchParseQuery('re:^IMG_\d+ re:(', vNow);
  Check((q.NameRegex = '^IMG_\d+') and (Length(q.Warnings) = 1), 'parse re');
  q := sgcFSearchParseQuery('limit:5 limit:x', vNow);
  Check((q.Limit = 5) and (Length(q.Warnings) = 1), 'parse limit');
  q := sgcFSearchParseQuery('case:yes', vNow);
  Check(q.HasCase and (q.CaseMode = fsgcSensitive) and (Length(q.Terms) = 0) and
    not q.HasNameTerms and not q.HasContentFilters and (Length(q.Warnings) = 0),
    'parse case:yes');
  q := sgcFSearchParseQuery('CASE:No grep:x report', vNow);
  Check(q.HasCase and (q.CaseMode = fsgcInsensitive) and (q.Grep = 'x') and
    (Length(q.Terms) = 1) and (q.Terms[0].Text = 'report') and
    (Length(q.Warnings) = 0), 'parse case:no');
  q := sgcFSearchParseQuery('case:yes case:no', vNow);
  Check(q.HasCase and (q.CaseMode = fsgcInsensitive), 'case: last one wins');
  q := sgcFSearchParseQuery('case:maybe report', vNow);
  Check((not q.HasCase) and (Length(q.Terms) = 1) and
    (q.Terms[0].Text = 'report') and (Length(q.Warnings) = 1) and
    (q.Warnings[0] = 'invalid case: maybe'), 'case invalid');
  q := sgcFSearchParseQuery('case:', vNow);
  Check((not q.HasCase) and (Length(q.Terms) = 0) and (Length(q.Warnings) = 1),
    'case empty');
  q := sgcFSearchParseQuery('report', vNow);
  Check(not q.HasCase, 'case not given');
  q := sgcFSearchParseQuery('sort:name', vNow);
  Check((q.Sort = fssName) and not q.SortDesc, 'sort name');
  q := sgcFSearchParseQuery('sort:size', vNow);
  Check((q.Sort = fssSize) and q.SortDesc, 'sort size');
  q := sgcFSearchParseQuery('sort:size-asc', vNow);
  Check((q.Sort = fssSize) and not q.SortDesc, 'sort size-asc');
  q := sgcFSearchParseQuery('sort:-date', vNow);
  Check((q.Sort = fssDate) and not q.SortDesc, 'sort -date');
  q := sgcFSearchParseQuery('sort:bogus', vNow);
  Check((q.Sort = fssRank) and (Length(q.Warnings) = 1), 'sort invalid');
  q := sgcFSearchParseQuery('sort:dir', vNow);
  Check((q.Sort = fssDir) and not q.SortDesc, 'sort dir');
  q := sgcFSearchParseQuery('sort:directory', vNow);
  Check((q.Sort = fssDir) and not q.SortDesc, 'sort directory');
  q := sgcFSearchParseQuery('sort:folder', vNow);
  Check((q.Sort = fssDir) and not q.SortDesc, 'sort folder');
  q := sgcFSearchParseQuery('sort:path', vNow);
  Check((q.Sort = fssDir) and not q.SortDesc, 'sort path');
  q := sgcFSearchParseQuery('sort:-dir', vNow);
  Check((q.Sort = fssDir) and q.SortDesc, 'sort -dir');
  q := sgcFSearchParseQuery('sort:dir-desc', vNow);
  Check((q.Sort = fssDir) and q.SortDesc, 'sort dir-desc');
  q := sgcFSearchParseQuery('sort:dir-asc', vNow);
  Check((q.Sort = fssDir) and not q.SortDesc, 'sort dir-asc');
  q := sgcFSearchParseQuery('grep:"foo bar" regex:ba+r sym:TFoo ext:pas', vNow);
  Check((q.Grep = 'foo bar') and (q.ContentRegex = 'ba+r') and (q.Sym = 'TFoo')
    and q.HasContentFilters and not q.HasNameTerms, 'content filters');
  q := sgcFSearchParseQuery('foo:bar "ext:pas" C:\x', vNow);
  Check((Length(q.Terms) = 3) and (q.Terms[0].Folded = 'foo:bar') and
    (q.Terms[1].Folded = 'ext:pas') and (Length(q.Exts) = 0) and
    (q.Terms[2].Folded = 'x') and (q.Terms[2].Dirs[0] = 'c:'),
    'unknown keys literal');
  // chips
  S := 'foo ext:pas';
  Check(sgcFSearchQueryGetFilter(S, 'ext') = 'pas', 'chip get');
  Check(sgcFSearchQueryGetFilter(S, 'in') = '', 'chip get missing');
  Check(sgcFSearchQuerySetFilter(S, 'ext', 'txt') = 'foo ext:txt',
    'chip set replace');
  S := sgcFSearchQuerySetFilter('foo', 'in', 'C:\Program Files');
  Check(S = 'foo in:"C:\Program Files"', 'chip set quoted: ' + S);
  Check(sgcFSearchQueryGetFilter(S, 'IN') = 'C:\Program Files',
    'chip round trip');
  Check(sgcFSearchQueryRemoveFilter(S, 'in') = 'foo', 'chip remove');
  Check(sgcFSearchQueryRemoveFilter('a size:>1k b size:<5m', 'size') = 'a b',
    'chip remove all');
  Check(sgcFSearchQuerySetFilter('a size:>1k b size:<5m', 'size', 'empty')
    = 'a size:empty b', 'chip set dedups');
end;

{ ---- saved filters ------------------------------------------------------ }

procedure TestApplySaved;

  procedure Stable(const Text, Saved: string);
  var
    vOnce: string;
  begin
    vOnce := sgcFSearchQueryApplySaved(Text, Saved);
    Check(sgcFSearchQueryApplySaved(vOnce, Saved) = vOnce,
      'saved stable: [' + Text + '] + [' + Saved + '] = ' + vOnce);
  end;

var
  S: string;
begin
  // typed words stay
  Check(sgcFSearchQueryApplySaved('foo bar', 'ext:pas') = 'foo bar ext:pas',
    'saved keeps typed words');
  S := sgcFSearchQueryApplySaved('"my file" size:>1k', 'ext:pas');
  Check(S = '"my file" size:>1k ext:pas', 'saved keeps quoted word: ' + S);
  // a key is replaced, the other filters stay
  Check(sgcFSearchQueryApplySaved('ext:txt foo', 'ext:pas') = 'ext:pas foo',
    'saved replaces a key in place');
  Check(sgcFSearchQueryApplySaved('a EXT:txt b ext:md', 'ext:pas')
    = 'a ext:pas b', 'saved replaces every filter of the key');
  S := sgcFSearchQueryApplySaved('in:C:\a foo mtime:year',
    'ext:pas mtime:week');
  Check(S = 'in:C:\a foo mtime:week ext:pas',
    'saved replaces only its keys: ' + S);
  // a repeated key is kept whole
  S := sgcFSearchQueryApplySaved('bar in:C:\old', 'in:C:\a in:D:\b');
  Check(S = 'bar in:C:\a in:D:\b', 'saved repeated key: ' + S);
  S := sgcFSearchQueryApplySaved('in:C:\x path:y', 'path:a in:C:\z path:b');
  Check(S = 'in:C:\z path:a path:b', 'saved repeated and single key: ' + S);
  S := sgcFSearchQueryApplySaved('x', 'in:"C:\A B" in:"D:\C D"');
  Check(S = 'x in:"C:\A B" in:"D:\C D"', 'saved repeated quoted key: ' + S);
  // quoted values survive
  S := sgcFSearchQueryApplySaved('foo', 'in:"C:\My Projects" ext:pas');
  Check(S = 'foo in:"C:\My Projects" ext:pas', 'saved quoted value: ' + S);
  Check(sgcFSearchQueryGetFilter(S, 'in') = 'C:\My Projects',
    'saved quoted value reads back');
  S := sgcFSearchQueryApplySaved('in:"D:\Old Stuff" a', 'in:"C:\My Projects"');
  Check(S = 'in:"C:\My Projects" a', 'saved quoted value replaces: ' + S);
  // words are added once
  Check(sgcFSearchQueryApplySaved('foo', 'foo bar bar') = 'foo bar',
    'saved words added once');
  Check(sgcFSearchQueryApplySaved('FOO', 'foo') = 'FOO',
    'saved word already there, other case');
  S := sgcFSearchQueryApplySaved('foo', '"my file"');
  Check(S = 'foo "my file"', 'saved quoted word added: ' + S);
  Check(sgcFSearchQueryApplySaved('ext:foo', 'foo') = 'ext:foo foo',
    'saved word is not a filter value');
  Check(sgcFSearchQueryApplySaved('a', 'C:\x foo:bar') = 'a C:\x foo:bar',
    'saved unknown keys are words');
  // an empty value removes the key
  Check(sgcFSearchQueryApplySaved('in:C:\a b', 'in:') = 'b',
    'saved empty value');
  // open quotes do not swallow what is added
  S := sgcFSearchQueryApplySaved('"foo', 'ext:pas');
  Check(S = '"foo" ext:pas', 'saved closes an open quote: ' + S);
  // empty text and empty saved
  Check(sgcFSearchQueryApplySaved('', '') = '', 'saved empty both');
  Check(sgcFSearchQueryApplySaved('foo  ext:txt', '') = 'foo  ext:txt',
    'saved empty saved');
  Check(sgcFSearchQueryApplySaved('foo', '   ') = 'foo', 'saved blank saved');
  S := 'ext:pas in:C:\Projects mtime:week';
  Check(sgcFSearchQueryApplySaved('', S) = S, 'saved empty text');
  Check(sgcFSearchQueryApplySaved('   ', 'foo') = 'foo', 'saved blank text');
  Check(sgcFSearchQueryApplySaved('', 'uniq ext:pas') = 'uniq ext:pas',
    'saved empty text keeps the saved order');
  Check(sgcFSearchQueryApplySaved('', 'foo ext:pas bar') = 'foo ext:pas bar',
    'saved empty text, word between filters');
  // applying twice changes nothing
  Stable('', 'ext:pas in:C:\Projects mtime:week');
  Stable('foo bar', 'ext:pas foo in:"C:\My Projects" baz');
  Stable('ext:txt in:C:\x in:C:\y word', 'in:a ext:p in:b foo');
  Stable('a b', 'path:x in:y path:z in:w q');
  Stable('"open', 'ext:pas');
  Stable('x', 'in:"open');
  Stable('foo   bar', 'baz');
  Stable('FOO', 'foo "my file" ext:pas');
end;

{ ---- match -------------------------------------------------------------- }

procedure TestMatch;
var
  vF: TsgcFSearchFuzzy;
  p, l: Integer;
  S, n: string;
begin
  Check(sgcFSearchFold('AbC' + #$00C4) = 'abc' + #$00E4, 'fold');
  Check(sgcFSearchFoldChar(#$D800) = #$D800, 'fold surrogate');
  S := 'MyReport';
  Check(sgcFSearchIsWordStart(PChar(S), Length(S), 2), 'camel boundary');
  S := 'domain';
  Check(not sgcFSearchIsWordStart(PChar(S), Length(S), 2), 'no boundary');
  S := 'file_name';
  Check(sgcFSearchIsWordStart(PChar(S), Length(S), 5), 'underscore boundary');
  S := 'abc123';
  Check(sgcFSearchIsWordStart(PChar(S), Length(S), 3), 'digit boundary');
  S := 'Main.RS';
  n := 'main';
  Check(sgcFSearchPosFold(PChar(S), Length(S), PChar(n), Length(n)) = 0,
    'pos fold');
  n := '.rs';
  Check(sgcFSearchEndsWithFold(PChar(S), Length(S), PChar(n), Length(n)),
    'ends fold');
  n := 'main.rs';
  Check(sgcFSearchSameFold(PChar(S), Length(S), PChar(n), Length(n)),
    'same fold');
  n := 'mai';
  Check(sgcFSearchStartsWithFold(PChar(S), Length(S), PChar(n), Length(n)),
    'starts fold');
  n := 'main.rs';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkContains, nil, p, l) = SGCFS_QUALITY_EXACT, 'quality exact');
  n := 'rs';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkContains, nil, p, l) = SGCFS_QUALITY_WORD) and (p = 5), 'quality word');
  // wildcards (folded pattern, whole name)
  n := '*.rs';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_SUBSTR) and (p = 4) and (l = 3),
    'wild suffix');
  n := 'ma*';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_PREFIX) and (p = 0) and (l = 2),
    'wild prefix');
  n := '?ain.r?';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_EXACT) and (p = 1) and (l = 5),
    'wild question exact');
  n := '?in.rs';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_NONE, 'wild question one char');
  n := '*.r';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_NONE, 'wild whole name');
  n := '*';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_SUBSTR) and (p = 0) and (l = 0),
    'wild star only');
  S := 'ab';
  n := '**a**b**';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_SUBSTR, 'wild pattern longer');
  n := 'a?b';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_NONE, 'wild ? needs a char');
  S := 'XaXAB.Txt';
  n := '*ab*.txt';
  Check((sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_SUBSTR) and (p = 3) and (l = 2),
    'wild backtrack highlight');
  S := StringOfChar('a', 400);
  n := '*a*a*a*a*a*a*b';
  Check(sgcFSearchMatchQualityRaw(PChar(S), Length(S), PChar(n), Length(n),
    fsmkWildcard, nil, p, l) = SGCFS_QUALITY_NONE, 'wild no blowup');
  n := 'mian.rs';
  vF.Init(PChar(n), Length(n));
  S := 'main.rs';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy transposition');
  S := 'xmain.rsx';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy inside');
  S := 'mn.rs';
  Check(not vF.Match(PChar(S), Length(S), p, l), 'fuzzy distance 2');
  n := 'recieve';
  vF.Init(PChar(n), Length(n));
  S := 'receive.txt';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy recieve');
  S := 'recive.txt';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy deletion');
  S := 'reciieve';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy insertion');
  S := 'rexieve';
  Check(vF.Match(PChar(S), Length(S), p, l), 'fuzzy substitution');
  S := 'resolve';
  Check(not vF.Match(PChar(S), Length(S), p, l), 'fuzzy no match');
  n := 'mian';
  vF.Init(PChar(n), Length(n));
  S := 'main';
  Check(not vF.Match(PChar(S), Length(S), p, l), 'fuzzy needs 5 letters');
end;

{ ---- handcrafted index -------------------------------------------------- }

function AddF(Parent: Integer; const Name: string; Size: Int64;
  AgeDays: Double): Integer;
var
  vItem: TsgcFSearchListingItem;
begin
  vItem := Default (TsgcFSearchListingItem);
  vItem.Name := Name;
  vItem.Attributes := FILE_ATTRIBUTE_ARCHIVE;
  vItem.Size := Size;
  vItem.MTime := GNowFT - Round(AgeDays * CS_FT_DAY);
  Result := GIdx.AddChild(Parent, vItem);
end;

function AddD(Parent: Integer; const Name: string): Integer;
var
  vItem: TsgcFSearchListingItem;
begin
  vItem := Default (TsgcFSearchListingItem);
  vItem.Name := Name;
  vItem.Attributes := FILE_ATTRIBUTE_DIRECTORY;
  vItem.MTime := GNowFT - Round(1.5 * CS_FT_DAY);
  Result := GIdx.AddChild(Parent, vItem);
end;

procedure BuildSmall;
var
  c, D, n: Integer;
begin
  GIdx.BeginWrite;
  try
    c := GIdx.Root(GIdx.AddRoot('C:\T', 1)).EntryIdx;
    D := GIdx.Root(GIdx.AddRoot('D:\Other', 2)).EntryIdx;
    GSrc := AddD(c, 'src');
    AddF(GSrc, 'main.rs', 100, 0);
    AddF(GSrc, 'mainframe.txt', 2000, 3);
    AddF(GSrc, 'receive.txt', 10, 10);
    GLib := AddD(GSrc, 'lib');
    AddF(GLib, 'helper.pas', 2048, 40);
    AddF(GLib, 'Helper.dfm', 1024, 40);
    GDocs := AddD(c, 'docs');
    AddF(GDocs, 'report_2025.pdf', 5 * CS_MB, 400);
    AddF(GDocs, 'report_draft.docx', CS_MB + CS_MB div 2, 2);
    AddF(GDocs, 'MyReport.txt', 100, 2);
    AddF(GDocs, 'my file.txt', 0, 2);
    AddD(GDocs, 'empty');
    AddF(GDocs, 'alpha_one.txt', 10, 5);
    AddF(GDocs, 'alpha_two.txt', 10, 5);
    n := AddD(c, 'node_modules');
    AddF(n, 'main.js', 50, 5);
    AddF(AddD(n, 'pkg'), 'index.js', 70, 5);
    GBuild := AddD(c, 'build');
    AddF(GBuild, 'app.exe', 20 * CS_MB, 100);
    AddF(GBuild, 'gone.txt', 5, 1);
    GPhotos := AddD(c, 'photos');
    AddF(GPhotos, 'IMG_001.jpg', 3 * CS_MB, 8);
    AddF(GPhotos, 'clip.mp4', 50 * CS_MB, 8);
    AddF(GPhotos, 'song.mp3', 4 * CS_MB, 8);
    AddF(c, 'domain.txt', 10, 1);
    AddF(D, 'main.rs', 10, 1);
  finally
    GIdx.EndWrite;
  end;
end;

function Run(const q: string; out R: TsgcFSearchResults): string;
var
  i: Integer;
begin
  GS.Search(q, 0, R);
  Result := '';
  GIdx.BeginRead;
  try
    for i := 0 to High(R.Items) do
    begin
      if i > 0 then
        Result := Result + ',';
      Result := Result + GIdx.NameOf(R.Items[i].EntryIdx);
    end;
  finally
    GIdx.EndRead;
  end;
end;

function Names(const q: string): string;
var
  vR: TsgcFSearchResults;
begin
  Result := Run(q, vR);
end;

function Total(const q: string): Integer;
var
  vR: TsgcFSearchResults;
begin
  GS.Search(q, 0, vR);
  Result := vR.Total;
end;

function Has(const q, Name: string): Boolean;
begin
  Result := Pos(',' + Name + ',', ',' + Names(q) + ',') > 0;
end;

function First(const q: string): string;
var
  S: string;
  p: Integer;
begin
  S := Names(q);
  p := Pos(',', S);
  if p > 0 then
    Result := Copy(S, 1, p - 1)
  else
    Result := S;
end;

function Last(const q: string): string;
var
  S: string;
begin
  S := Names(q);
  Result := Copy(S, LastDelimiter(',', S) + 1, MaxInt);
end;

function FindIdx(const Path: string): Integer;
begin
  GIdx.BeginRead;
  try
    Result := GIdx.FindPath(Path);
  finally
    GIdx.EndRead;
  end;
end;

function MF(const Path, q: string): Boolean;
var
  vIdx: Integer;
begin
  GIdx.BeginRead;
  try
    vIdx := GIdx.FindPath(Path);
    Result := (vIdx >= 0) and GS.MatchesFilters(vIdx, sgcFSearchParseQuery(q));
  finally
    GIdx.EndRead;
  end;
end;

procedure TestSearch;
var
  vR, vOnly: TsgcFSearchResults;
  S: string;
  i: Integer;
  vItems: TsgcFSearchListingItems;
  vU2: TsgcFSearchUsage;
  vOk: Boolean;
begin
  BuildSmall;
  // tiers and ranking
  S := Run('main', vR);
  Check((vR.Total = 5) and (First('main') = 'main.rs') and
    (Last('main') = 'domain.txt'), 'main tiers: ' + S);
  Check(Total('''main.rs') = 2, 'exact modifier');
  S := Run('main.rs', vR);
  Check((vR.Total = 3) and (S = 'main.rs,main.rs,main.js'),
    'exact then fuzzy: ' + S);
  S := Run('report', vR);
  Check((vR.Total = 3) and (Last('report') = 'MyReport.txt') and
    (vR.Items[2].MatchPos = 2) and (vR.Items[2].MatchLen = 6),
    'word boundary camel: ' + S);
  Check((vR.Items[0].MatchPos = 0) and not vR.Items[0].IsDir, 'highlight');
  Check(Total('^main') = 4, 'prefix modifier');
  Check((Total('txt$') = 8) and Has('txt$', 'domain.txt') and not Has('txt$',
    'report_2025.pdf'), 'suffix modifier');
  Check((Total('!node_modules\ main') = 4) and not Has('!node_modules\ main',
    'main.js'), 'exclude path token');
  Check((Total('main !rs') = 3) and not Has('main !rs', 'main.rs'),
    'exclude word');
  Check((Total('main !^main') = 1) and Has('main !^main', 'domain.txt'),
    'exclude prefix');
  Check(Names('"my file"') = 'my file.txt', 'quoted term');
  Check(Total('alpha one') = 1, 'two words AND');
  // fuzzy
  Check(Has('mian.rs', 'main.rs'), 'fuzzy mian.rs');
  Check(Has('recieve', 'receive.txt'), 'fuzzy recieve');
  Check(Total('mian') = 0, 'no fuzzy under 5 letters');
  // path tokens
  Check((Total('src\main') = 2) and Has('src\main', 'mainframe.txt') and
    not Has('src\main', 'main.js'), 'path token src\main');
  Check(Total('lib\helper') = 2, 'path token lib\helper');
  Check(Total('docs\main') = 0, 'path token no match');
  Check(Total('T\src\lib\help') = 2, 'path token through root');
  Check(Total('src\') = 6, 'path token trailing separator');
  // wildcards
  S := Run('*.pas', vR);
  Check((S = 'helper.pas') and (vR.Items[0].MatchPos = 6) and
    (vR.Items[0].MatchLen = 4), 'wild *.pas: ' + S);
  Check(Names('H*.DFM') = 'Helper.dfm', 'wild case-insensitive');
  S := Run('report*', vR);
  Check((vR.Total = 2) and not Has('report*', 'MyReport.txt') and
    (vR.Items[0].MatchPos = 0) and (vR.Items[0].MatchLen = 6),
    'wild prefix: ' + S);
  Check((Total('*report*') = 3) and Has('*report*', 'MyReport.txt'),
    'wild contains');
  Check(Names('rep*2025*.pdf') = 'report_2025.pdf', 'wild several stars');
  Check((Total('m??n.rs') = 2) and (Total('m?n.rs') = 0), 'wild ? length');
  S := Run('* ext:pas', vR);
  Check((vR.Total = 1) and (vR.Items[0].MatchPos = 0) and
    (vR.Items[0].MatchLen = 0), 'wild star only: ' + S);
  Check(Total('* kind:file') = 20, 'wild star matches every name');
  Check((Total('main !*.rs') = 3) and not Has('main !*.rs', 'main.rs'),
    'wild exclude');
  Check((Names('src\*.pas') = 'helper.pas') and (Total('src\*.txt') = 2) and
    (Total('docs\*.pas') = 0), 'wild path token');
  Check(Names('"my f*"') = 'my file.txt', 'wild quoted');
  Check((Names('''*.pas') = 'helper.pas') and (Names('^*.pas$') = 'helper.pas'),
    'wild redundant modifiers');
  Check(Has('recieve', 'receive.txt') and (Total('recie*') = 0),
    'wild no typo tolerance');
  // filters
  Check(Names('ext:pas') = 'helper.pas', 'ext');
  Check(Total('ext:pas,dfm') = 2, 'ext list');
  Check(Names('type:images') = 'IMG_001.jpg', 'type images');
  Check(Names('type:videos') = 'clip.mp4', 'type videos');
  Check(Names('type:audio') = 'song.mp3', 'type audio');
  Check(Total('type:folders') = 8, 'type folders');
  Check(Total('kind:dir') = 8, 'kind dir (roots excluded)');
  Check(Total('kind:file') = 20, 'kind file');
  Check(Total('size:>10mb') = 2, 'size >');
  Check(Total('size:<1k') = 11, 'size <');
  Check(Total('size:1mb..5mb') = 4, 'size range');
  Check((Total('size:empty') = 2) and Has('size:empty', 'empty') and
    Has('size:empty', 'my file.txt'), 'size empty');
  Check(Names('mtime:today') = 'main.rs', 'mtime today');
  Check(Has('mtime:<7d kind:file limit:1000', 'mainframe.txt') and
    not Has('mtime:<7d kind:file limit:1000', 'receive.txt'), 'mtime <7d');
  Check(Total('mtime:>30d kind:file') = 4, 'mtime >30d');
  S := 'mtime:>' + FormatDateTime('yyyy-mm-dd', Now - 200);
  Check(Has(S, 'helper.pas') and not Has(S, 'report_2025.pdf'), 'mtime > date');
  S := 'mtime:' + FormatDateTime('yyyy-mm-dd', Now - 50) + '..' +
    FormatDateTime('yyyy-mm-dd', Now - 30);
  Check(Has(S, 'helper.pas') and not Has(S, 'app.exe'), 'mtime date range');
  Check(Names('re:^IMG_\d+') = 'IMG_001.jpg', 're filter');
  Check(Total('path:node_modules') = 4, 'path filter');
  Check(Total('path:pkg\index') = 1, 'path filter with separator');
  // in:
  Check(Total('in:C:\T\src') = 6, 'in scope');
  Check(Total('in:D:\Other main') = 1, 'in other root');
  Check(Total('in:C:\T\src in:D:\Other main') = 3, 'in repeated OR');
  Check(Total('in:C:\ main') = 4, 'in above root');
  Check(Total('in:C:\Nope main') = 0, 'in missing');
  // roots
  Check(Names('Other') = 'D:\Other', 'root matches by name');
  // sort orders and folder totals
  S := Run('kind:dir sort:size', vR);
  Check((Length(vR.Items) > 0) and (First('kind:dir sort:size') = 'photos') and
    (vR.Items[0].Size = 57 * CS_MB), 'sort size folders: ' + S);
  vOk := False;
  for i := 0 to High(vR.Items) do
    if (vR.Items[i].EntryIdx = GDocs) and
      (vR.Items[i].Size = 5 * CS_MB + CS_MB + CS_MB div 2 + 120) then
      vOk := True;
  Check(vOk, 'folder total docs');
  vOk := False;
  for i := 0 to High(vR.Items) do
    if (vR.Items[i].EntryIdx = GSrc) and
      (vR.Items[i].Size = 100 + 2000 + 10 + 2048 + 1024) then
      vOk := True;
  Check(vOk, 'folder total nested');
  Check(First('kind:file sort:size-asc') = 'my file.txt', 'sort size asc');
  Check(First('kind:file sort:date') = 'main.rs', 'sort date');
  Check(First('kind:file sort:-date') = 'report_2025.pdf', 'sort date asc');
  Check(First('kind:file sort:name') = 'alpha_one.txt', 'sort name');
  Check(First('kind:file sort:name-desc') = 'song.mp3', 'sort name desc');
  S := Run('main', vR);
  Check(vR.Items[0].Size = 10, 'file size in results');
  // limit
  S := Run('main limit:2', vR);
  Check((Length(vR.Items) = 2) and (vR.Total = 5), 'limit');
  GS.Search('main', 3, vR);
  Check(Length(vR.Items) = 3, 'limit argument');
  // total is the true match count when the limit is below it
  GS.Search('ext:txt', 2, vR);
  Check((Length(vR.Items) = 2) and (vR.Total = 8), 'filter-only total: ' +
    IntToStr(vR.Total));
  GS.Search('kind:file in:C:\T\src', 2, vR);
  Check((Length(vR.Items) = 2) and (vR.Total = 5),
    'kind in total: ' + IntToStr(vR.Total));
  GS.Search('kind:dir sort:size in:C:\T', 3, vR);
  Check((Length(vR.Items) = 3) and (vR.Total = 8), 'sort size total: ' +
    IntToStr(vR.Total));
  GS.Search('ext:txt limit:1', 0, vR);
  Check((Length(vR.Items) = 1) and (vR.Total = 8),
    'limit: total: ' + IntToStr(vR.Total));
  // a query holding only case: behaves like one holding only limit:
  GS.Search('limit:100', 0, vR);
  GS.Search('case:yes', 100, vOnly);
  Check((vR.Total > 0) and (vOnly.Total = vR.Total) and
    (Length(vOnly.Items) = Length(vR.Items)), 'case: alone like limit: alone');
  // tombstones
  Check(Total('gone') = 1, 'gone before');
  SetLength(vItems, 1);
  vItems[0] := Default (TsgcFSearchListingItem);
  vItems[0].Name := 'app.exe';
  vItems[0].Attributes := FILE_ATTRIBUTE_ARCHIVE;
  vItems[0].Size := 20 * CS_MB;
  GIdx.BeginWrite;
  try
    GIdx.ApplyFolderListing(GBuild, vItems);
  finally
    GIdx.EndWrite;
  end;
  Check(Total('gone') = 0, 'tombstone not returned');
  Check(Total('kind:file') = 19, 'tombstone not counted');
  Check(First('kind:dir sort:size') = 'photos', 'totals after change');
  // usage boost
  Check(Names('alpha') = 'alpha_one.txt,alpha_two.txt', 'alpha order');
  GUsage.RecordUse('c:\t\DOCS\alpha_two.txt', fsukOpen,
    sgcFSearchNowFileTime, False);
  Check(Names('alpha') = 'alpha_two.txt,alpha_one.txt', 'usage boost order');
  Check(Abs(GUsage.Boost('C:\T\docs\alpha_two.txt') - 1) < 0.01,
    'usage boost value');
  GUsage.RecordUse('C:\T\x.txt', fsukCopy, sgcFSearchNowFileTime -
    Round(14 * CS_FT_DAY), False);
  Check(Abs(GUsage.Boost('C:\T\x.txt') - 0.35) < 0.01, 'usage copy half-life');
  Check(GUsage.Save and FileExists(GUsage.FileName), 'usage save');
  vU2 := TsgcFSearchUsage.Create(GUsage.FileName);
  try
    Check((vU2.Count = 2) and (Abs(vU2.Boost('C:\T\DOCS\ALPHA_TWO.TXT') - 1) <
      0.01), 'usage load');
  finally
    vU2.Free;
  end;
  vU2 := TsgcFSearchUsage.Create;
  try
    Check(SameText(vU2.FileName, IncludeTrailingPathDelimiter(sgcFSearchDataDir)
      + SGCFS_USAGE_FILE), 'usage default file');
  finally
    vU2.Free;
  end;
  // MatchesFilters (engine side)
  Check(MF('C:\T\src\lib\helper.pas', 'ext:pas'), 'mf ext');
  Check(not MF('C:\T\src\lib\helper.pas', 'ext:txt'), 'mf ext no');
  Check(MF('C:\T\src\lib\helper.pas', 'in:C:\T\src size:>1k grep:x'),
    'mf in size');
  Check(not MF('C:\T\src\lib\helper.pas', 'in:C:\T\docs'), 'mf in no');
  Check(not MF('C:\T\src\lib\helper.pas', '!lib\ grep:x'), 'mf exclude dir');
  Check(not MF('C:\T\src\lib\helper.pas', '!*.pas grep:x') and
    MF('C:\T\src\lib\helper.pas', '!*.txt grep:x'), 'mf exclude wildcard');
  Check(MF('C:\T\src\lib\helper.pas', 'nomatch path:lib type:code'),
    'mf ignores name terms');
  Check(not MF('C:\T', ''), 'mf root');
  Check(FindIdx('C:\T\build\gone.txt') < 0, 'gone path');
  Check(not sgcFSearchParseQuery('grep:foo ext:pas').HasNameTerms,
    'has name terms');
end;

{ ---- synthetic 2M index and timings ------------------------------------- }

/// Folders that hold an entry, outermost first. Caller holds the read lock.
function DirChain(Idx: Integer): TArray<Integer>;
begin
  Result := nil;
  Idx := GIdx.Entries[Idx].ParentIdx;
  while Idx >= 0 do
  begin
    Result := [Idx] + Result;
    Idx := GIdx.Entries[Idx].ParentIdx;
  end;
end;

/// True when the results follow sort:dir, checked on the folded names of the
/// folders one by one. Two folders with the same folded name in one folder
/// keep apart by entry index.
function InDirOrder(const R: TsgcFSearchResults): Boolean;
var
  i, j, c: Integer;
  vA, vB: TArray<Integer>;
begin
  Result := True;
  GIdx.BeginRead;
  try
    for i := 1 to High(R.Items) do
    begin
      vA := DirChain(R.Items[i - 1].EntryIdx);
      vB := DirChain(R.Items[i].EntryIdx);
      c := 0;
      j := 0;
      while (c = 0) and (j < Length(vA)) and (j < Length(vB)) do
      begin
        if vA[j] <> vB[j] then
        begin
          c := CompareStr(sgcFSearchFold(GIdx.NameOf(vA[j])),
            sgcFSearchFold(GIdx.NameOf(vB[j])));
          if c = 0 then
            c := vA[j] - vB[j];
        end;
        Inc(j);
      end;
      if c = 0 then
        c := Length(vA) - Length(vB);
      if c = 0 then
        c := CompareStr(sgcFSearchFold(GIdx.NameOf(R.Items[i - 1].EntryIdx)),
          sgcFSearchFold(GIdx.NameOf(R.Items[i].EntryIdx)));
      if c > 0 then
        Exit(False);
    end;
  finally
    GIdx.EndRead;
  end;
end;

procedure TestSortDir;
const
  CS_ASC = 'alpha.txt,Zeta.txt,n.txt,a.txt,Beta.txt,c.txt,x1.txt,b.txt,' +
    'm.txt,p.txt,r.txt,q.txt';
  CS_DESC = 'q.txt,r.txt,p.txt,m.txt,b.txt,x1.txt,c.txt,Beta.txt,a.txt,' +
    'n.txt,Zeta.txt,alpha.txt';
var
  vC, vD, vSub, vDeep, vDup1, vDup2, vApple, vSub2: Integer;
begin
  // a new index, the items go in out of order on purpose
  GS.Free;
  GIdx.Free;
  GIdx := TsgcFSearchIndex.Create;
  GS := TsgcFSearchSearcher.Create(GIdx, GUsage);
  GIdx.BeginWrite;
  try
    vD := GIdx.Root(GIdx.AddRoot('D:\S', 2)).EntryIdx;
    vC := GIdx.Root(GIdx.AddRoot('C:\R', 1)).EntryIdx;
    AddF(vD, 'm.txt', 1, 1);
    // same folded name twice in one folder (case sensitive folder)
    vDup1 := AddD(vD, 'dup');
    vDup2 := AddD(vD, 'DUP');
    AddF(vDup1, 'r.txt', 1, 1);
    AddF(vDup2, 'q.txt', 1, 1);
    AddF(vDup1, 'p.txt', 1, 1);
    // a raw compare of the paths would put sub2 before Sub\...
    vSub2 := AddD(vC, 'sub2');
    AddF(vSub2, 'b.txt', 1, 1);
    vSub := AddD(vC, 'Sub');
    vDeep := AddD(vSub, 'deep');
    AddF(vDeep, 'x1.txt', 1, 1);
    AddF(vDeep, 'c.txt', 1, 1);
    AddF(vSub, 'Beta.txt', 1, 1);
    AddF(vSub, 'a.txt', 1, 1);
    vApple := AddD(vC, 'Apple');
    AddF(vApple, 'n.txt', 1, 1);
    AddF(vC, 'Zeta.txt', 1, 1);
    AddF(vC, 'alpha.txt', 1, 1);
  finally
    GIdx.EndWrite;
  end;
  Check(Names('ext:txt sort:dir') = CS_ASC,
    'sort dir: component order, contents together, names inside');
  Check(Names('ext:txt sort:directory') = CS_ASC, 'sort directory order');
  Check(Names('ext:txt sort:folder') = CS_ASC, 'sort folder order');
  Check(Names('ext:txt sort:path') = CS_ASC, 'sort path order');
  Check(Names('ext:txt sort:dir-desc') = CS_DESC, 'sort dir-desc order');
  Check(Names('ext:txt sort:-dir') = CS_DESC, 'sort -dir order');
  Check(Names('kind:dir sort:dir') = 'Apple,Sub,sub2,deep,dup,DUP',
    'sort dir: folders by their parent path');
  Check(Names('s kind:dir sort:dir') = 'D:\S,Sub,sub2',
    'sort dir: a root has no parent and goes first');
  Check(Names('ext:txt sort:dir limit:3') = 'alpha.txt,Zeta.txt,n.txt',
    'sort dir: limit keeps the first ones');
  Check(Total('ext:txt sort:dir limit:3') = 12, 'sort dir: total with limit');
end;

function Rnd(n: Integer): Integer;
begin
  GSeed := GSeed xor (GSeed shl 13);
  GSeed := GSeed xor (GSeed shr 17);
  GSeed := GSeed xor (GSeed shl 5);
  Result := Integer(GSeed mod Cardinal(n));
end;

procedure BuildSynth(out FolderCount: Integer);
const
  CS_SYL: array [0 .. 29] of string = ('ka', 'lo', 'mi', 'ne', 'ru', 'sa', 'to',
    'vi', 'ber', 'con', 'dex', 'fal', 'gor', 'hin', 'jun', 'kel', 'lim', 'mor',
    'nap', 'pel', 'qua', 'ras', 'sim', 'tor', 'ux', 'ven', 'wil', 'xen',
    'yor', 'zed');
  CS_WORDS: array [0 .. 19] of string = ('report', 'invoice', 'budget',
    'project', 'summary', 'config', 'helper', 'main', 'index', 'client',
    'server', 'image', 'photo', 'music', 'backup', 'notes', 'draft', 'final',
    'data', 'test');
  CS_EXT: array [0 .. 19] of string = ('txt', 'pas', 'dfm', 'cs', 'js', 'pdf',
    'docx', 'png', 'jpg', 'json', 'xml', 'md', 'exe', 'dll', 'zip', 'mp3',
    'mp4', 'h', 'cpp', 'py');
  CS_COMMON: array [0 .. 15] of string = ('index.js', 'README.md', 'main.rs',
    'Makefile', 'package.json', 'config.yml', 'LICENSE', '.gitignore',
    'setup.py', 'app.config', 'Program.cs', 'main.pas', 'Unit1.pas',
    'Unit1.dfm', 'favicon.ico', 'style.css');
  CS_NUM: array [0 .. 3] of string = ('IMG_', 'DSC_', 'Scan_', 'report_');
  CS_DIRS: array [0 .. 7] of string = ('src', 'lib', 'bin', 'obj', 'docs',
    'test', 'assets', 'node_modules');
var
  vWords: TArray<string>;
  vFolders, vDepth: TArray<Integer>;
  vNF, i, j, k, f, R, vRoot, vCount: Integer;
  vItem: TsgcFSearchListingItem;
  w1, w2: string;
  function Cap(const S: string): string;
  begin
    Result := UpperCase(Copy(S, 1, 1)) + Copy(S, 2, MaxInt);
  end;
  function AddFolder(Parent, D: Integer; const Name: string): Integer;
  begin
    vItem.Name := Name;
    vItem.Attributes := FILE_ATTRIBUTE_DIRECTORY;
    vItem.Size := 0;
    Result := GIdx.AddChild(Parent, vItem);
    if vNF = Length(vFolders) then
    begin
      SetLength(vFolders, vNF * 2);
      SetLength(vDepth, vNF * 2);
    end;
    vFolders[vNF] := Result;
    vDepth[vNF] := D;
    Inc(vNF);
    Inc(vCount);
  end;

begin
  SetLength(vWords, 1500);
  for i := 0 to High(CS_WORDS) do
    vWords[i] := CS_WORDS[i];
  for i := Length(CS_WORDS) to High(vWords) do
  begin
    vWords[i] := CS_SYL[Rnd(30)] + CS_SYL[Rnd(30)];
    if Rnd(2) = 0 then
      vWords[i] := vWords[i] + CS_SYL[Rnd(30)];
  end;
  SetLength(vFolders, 1024);
  SetLength(vDepth, 1024);
  vNF := 0;
  vCount := 0;
  vItem := Default (TsgcFSearchListingItem);
  GIdx.BeginWrite;
  try
    vRoot := GIdx.Root(GIdx.AddRoot('C:\Synth', 7)).EntryIdx;
    // skeleton: d0..d9 \ 10 \ 10 (depth 1..3)
    for i := 0 to 9 do
    begin
      f := AddFolder(vRoot, 1, 'd' + IntToStr(i));
      for j := 0 to 9 do
      begin
        R := AddFolder(f, 2, vWords[Rnd(Length(vWords))] + IntToStr(j));
        for k := 0 to 9 do
          AddFolder(R, 3, Cap(vWords[Rnd(Length(vWords))]) + '_' + IntToStr(k));
      end;
    end;
    while vCount < CS_SYNTH_ENTRIES do
    begin
      repeat
        f := Rnd(vNF);
      until vDepth[f] < 8;
      if Rnd(10) = 0 then
      begin
        if Rnd(4) = 0 then
          w1 := CS_DIRS[Rnd(8)]
        else
          w1 := vWords[Rnd(Length(vWords))] + '_' + IntToStr(Rnd(50));
        AddFolder(vFolders[f], vDepth[f] + 1, w1);
        Continue;
      end;
      w1 := vWords[Rnd(Length(vWords))];
      w2 := vWords[Rnd(Length(vWords))];
      R := Rnd(100);
      if R < 25 then
        vItem.Name := w1 + '_' + w2 + '.' + CS_EXT[Rnd(20)]
      else if R < 45 then
        vItem.Name := Cap(w1) + Cap(w2) + '.' + CS_EXT[Rnd(20)]
      else if R < 60 then
        vItem.Name := CS_COMMON[Rnd(16)]
      else if R < 80 then
        vItem.Name := CS_NUM[Rnd(4)] + IntToStr(2000 + Rnd(30)) + '_' +
          IntToStr(Rnd(1000)) + '.' + CS_EXT[Rnd(20)]
      else
        vItem.Name := w1 + IntToStr(Rnd(1000)) + '.' + CS_EXT[Rnd(20)];
      vItem.Attributes := FILE_ATTRIBUTE_ARCHIVE;
      vItem.Size := Rnd(1000000) + Int64(Rnd(100)) * Rnd(1000000);
      vItem.MTime := GNowFT - Int64(Rnd(2000)) * Round(CS_FT_DAY);
      GIdx.AddChild(vFolders[f], vItem);
      Inc(vCount);
    end;
  finally
    GIdx.EndWrite;
  end;
  FolderCount := vNF;
end;

function Ticks: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function TicksToMs(T: Int64): Double;
var
  vFreq: Int64;
begin
  QueryPerformanceFrequency(vFreq);
  Result := T * 1000.0 / vFreq;
end;

procedure TimeQuery(const Lbl, q: string);
var
  vT: array [0 .. 4] of Double;
  vR: TsgcFSearchResults;
  i, j: Integer;
  x: Double;
begin
  for i := 0 to 4 do
  begin
    GS.Search(q, 100, vR);
    vT[i] := vR.ElapsedMs;
  end;
  for i := 0 to 3 do
    for j := i + 1 to 4 do
      if vT[j] < vT[i] then
      begin
        x := vT[i];
        vT[i] := vT[j];
        vT[j] := x;
      end;
  Writeln(Format
    ('[TIME] %-12s %-28s median %7.2f ms  (min %.2f, max %.2f) hits %d',
    [Lbl, '"' + q + '"', vT[2], vT[0], vT[4], vR.Total]));
  Check(Length(vR.Items) > 0, 'synthetic query has results: ' + q);
end;

procedure CheckTotal(const q: string);
var
  vR: TsgcFSearchResults;
  vAll: Integer;
begin
  GS.Search(q, 1000000, vR);
  vAll := Length(vR.Items);
  GS.Search(q, 5, vR);
  Check((vAll > 5) and (Length(vR.Items) = 5) and (vR.Total = vAll),
    Format('synthetic total %s: %d of %d', [q, vR.Total, vAll]));
end;

procedure TestSynthetic;
var
  vT0: Int64;
  vFolders, i: Integer;
  vR, vTop: TsgcFSearchResults;
  vSame: Boolean;
begin
  GS.Free;
  GIdx.Free;
  GIdx := TsgcFSearchIndex.Create;
  GS := TsgcFSearchSearcher.Create(GIdx, GUsage);
  vT0 := Ticks;
  BuildSynth(vFolders);
  GIdx.BeginRead;
  try
    Writeln(Format
      ('[INFO] synthetic index: %d entries, %d folders, %d distinct names, built in %.0f ms',
      [GIdx.EntryCount, vFolders, GIdx.NameCount, TicksToMs(Ticks - vT0)]));
    Check(GIdx.EntryCount >= CS_SYNTH_ENTRIES, 'synthetic size');
  finally
    GIdx.EndRead;
  end;
  GS.Search('report', 100, vR);
  Writeln(Format
    ('[INFO] first search (folds the name pool): %.2f ms, folded cache %.1f MB',
    [vR.ElapsedMs, GS.FoldedMemory / CS_MB]));
  TimeQuery('one word', 'report');
  TimeQuery('typo word', 'reprot');
  TimeQuery('two words', 'report 2015');
  TimeQuery('filtered', 'ext:pas in:C:\Synth\d3');
  // many chunks: the total does not depend on the limit
  CheckTotal('ext:pas in:C:\Synth\d3');
  CheckTotal('kind:dir in:C:\Synth\d3');
  CheckTotal('kind:dir sort:size in:C:\Synth');
  CheckTotal('ext:pas');
  GS.Search('report sort:size', 100, vR);
  Writeln(Format('[INFO] first sort:size (folder totals): %.2f ms',
    [vR.ElapsedMs]));
  TimeQuery('sort:size', 'report sort:size');
  // sort:dir across many chunks: the limit returns the first ones
  GS.Search('report sort:dir', 1000000, vR);
  GS.Search('report sort:dir', 50, vTop);
  vSame := (vR.Total = vTop.Total) and (Length(vTop.Items) = 50);
  for i := 0 to High(vTop.Items) do
    vSame := vSame and (vTop.Items[i].EntryIdx = vR.Items[i].EntryIdx);
  Check(vSame, 'sort dir: limit returns the first ones of the full order');
  Check(InDirOrder(vR), 'sort dir: matches a compare on the full paths');
  TimeQuery('sort:dir', 'report sort:dir');
  TimeQuery('path token', 'src\main');
end;

begin
  try
    GHome := IncludeTrailingPathDelimiter(TPath.GetTempPath) +
      'sgcFSearchTests\search';
    if TDirectory.Exists(GHome) then
      TDirectory.Delete(GHome, True);
    ForceDirectories(GHome);
    SetEnvironmentVariable(PChar(SGCFS_HOME_ENV), PChar(GHome));
    GNowFT := sgcFSearchNowFileTime;
    TestParser;
    TestApplySaved;
    TestMatch;
    GIdx := TsgcFSearchIndex.Create;
    GUsage := TsgcFSearchUsage.Create(GHome + '\usage.json');
    GS := TsgcFSearchSearcher.Create(GIdx, GUsage);
    try
      TestSearch;
      GUsage.Clear;
      TestSortDir;
      TestSynthetic;
    finally
      GS.Free;
      GIdx.Free;
      GUsage.Free;
    end;
    TDirectory.Delete(GHome, True);
  except
    on E: Exception do
    begin
      Inc(GFails);
      Writeln('[FAIL] exception ', E.ClassName, ': ', E.Message);
    end;
  end;
  if GFails = 0 then
  begin
    Writeln('[PASS] ', GChecks, ' checks');
    ExitCode := 0;
  end
  else
  begin
    Writeln('[FAILED] ', GFails, ' of ', GChecks, ' checks');
    ExitCode := 1;
  end;

end.
