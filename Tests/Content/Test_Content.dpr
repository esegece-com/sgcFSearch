{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program Test_Content;

{$I sgcVer.inc}
{$APPTYPE CONSOLE}

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes,
  System.IOUtils, System.Zip, System.Diagnostics, System.StrUtils,
  // sgc
  sgcFSearch_Types in '..\..\Source\sgcFSearch_Types.pas',
  sgcFSearch_NtApi in '..\..\Source\sgcFSearch_NtApi.pas',
  sgcFSearch_Index in '..\..\Source\sgcFSearch_Index.pas',
  sgcFSearch_Crawler in '..\..\Source\sgcFSearch_Crawler.pas',
  sgcFSearch_Config in '..\..\Source\sgcFSearch_Config.pas',
  sgcFSearch_Log in '..\..\Source\sgcFSearch_Log.pas',
  sgcFSearch_Extract in '..\..\Source\sgcFSearch_Extract.pas',
  sgcFSearch_Trigram in '..\..\Source\sgcFSearch_Trigram.pas',
  sgcFSearch_Grep in '..\..\Source\sgcFSearch_Grep.pas';

const
  CS_PAS = 'unit Code;'#13#10 + 'interface'#13#10 + 'type'#13#10 +
    '  TWidgetMaker = class(TObject)'#13#10 + '    procedure BuildWidget;'#13#10
    + '  end;'#13#10 + 'function ComputeTotal(A, B: Integer): Integer;'#13#10 +
    'implementation'#13#10 + 'procedure TWidgetMaker.BuildWidget;'#13#10 +
    'begin'#13#10 + '  ComputeTotal(1, 2);'#13#10 + 'end;'#13#10 + 'end.'#13#10;
  CS_PY = 'def compute_total(a, b):'#10 + '    return a + b'#10#10 +
    'class WidgetMaker:'#10 + '    pass'#10#10 + 'x = compute_total(1, 2)'#10;
  CS_W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

var
  GChecks, GFails: Integer;
  GBase, GTree, GHome, GMany: string;
  GHasPdf: Boolean;

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

function U8(const S: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(S);
end;

procedure WriteRaw(const FileName: string; const Bytes: TBytes);
begin
  ForceDirectories(ExtractFileDir(FileName));
  TFile.WriteAllBytes(FileName, Bytes);
end;

procedure MakeZip(const FileName: string;
  const Names, Contents: array of string);
var
  vZip: TZipFile;
  i: Integer;
begin
  vZip := TZipFile.Create;
  try
    vZip.Open(FileName, zmWrite);
    for i := 0 to High(Names) do
      vZip.Add(U8(Contents[i]), Names[i]);
    vZip.Close;
  finally
    vZip.Free;
  end;
end;

procedure MakePdf(const FileName, Text: string);
var
  vS, vStream: string;
  vOfs: array [1 .. 5] of Integer;
  i, vXref: Integer;
begin
  vStream := 'BT /F1 24 Tf 72 700 Td (' + Text + ') Tj ET';
  vS := '%PDF-1.4'#10;
  vOfs[1] := Length(vS);
  vS := vS + '1 0 obj'#10'<< /Type /Catalog /Pages 2 0 R >>'#10'endobj'#10;
  vOfs[2] := Length(vS);
  vS := vS + '2 0 obj'#10'<< /Type /Pages /Kids [3 0 R] /Count 1 >>'#10 +
    'endobj'#10;
  vOfs[3] := Length(vS);
  vS := vS + '3 0 obj'#10'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]'
    + ' /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>'#10'endobj'#10;
  vOfs[4] := Length(vS);
  vS := vS + '4 0 obj'#10'<< /Length ' + IntToStr(Length(vStream)) + ' >>'#10 +
    'stream'#10 + vStream + #10'endstream'#10'endobj'#10;
  vOfs[5] := Length(vS);
  vS := vS + '5 0 obj'#10'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica' +
    ' >>'#10'endobj'#10;
  vXref := Length(vS);
  vS := vS + 'xref'#10'0 6'#10'0000000000 65535 f'#13#10;
  for i := 1 to 5 do
    vS := vS + Format('%.10d 00000 n'#13#10, [vOfs[i]]);
  vS := vS + 'trailer'#10'<< /Size 6 /Root 1 0 R >>'#10'startxref'#10 +
    IntToStr(vXref) + #10'%%EOF'#10;
  WriteRaw(FileName, TEncoding.ASCII.GetBytes(vS));
end;

procedure CreateSamples;
var
  vBytes: TBytes;
  vBig: TStringBuilder;
begin
  WriteRaw(P('utf8.txt'), U8('Hello UTF8 caf'#$00E9' MixedCase needleone'#10 +
    'second line here'#10));
  WriteRaw(P('utf8bom.txt'), TBytes.Create($EF, $BB, $BF) +
    U8('bomneedle in a bom file'#10));
  WriteRaw(P('utf16.txt'), TBytes.Create($FF, $FE) + TEncoding.Unicode.GetBytes
    ('wide needle sixteen'#13#10'line two'));
  WriteRaw(P('ansi.txt'), TEncoding.ASCII.GetBytes('ansi caf') +
    TBytes.Create($E9) + TEncoding.ASCII.GetBytes(' ansimarker'#13#10));
  WriteRaw(P('README'), U8('noextmarker plain text'#10));
  WriteRaw(P('blob.qqq'), TEncoding.ASCII.GetBytes('abc') + TBytes.Create(0, 1,
    2) + TEncoding.ASCII.GetBytes('blobmarker'));
  WriteRaw(P('data.bin'), U8('binmarker'));
  WriteRaw(P('stale.txt'), U8('stalemarker first line'#10));
  WriteRaw(P('code.pas'), U8(CS_PAS));
  WriteRaw(P('script.py'), U8(CS_PY));
  WriteRaw(P('sub\deep\nested.md'), U8('nestedmarker deep'#10));
  WriteRaw(P('node_modules\lib.js'), U8('var excludedmarker = 1;'#10));
  vBig := TStringBuilder.Create;
  try
    vBig.Append('bigmarker'#10);
    while vBig.Length < 1536 * 1024 do
      vBig.Append('filler line for the big file'#10);
    WriteRaw(P('big.txt'), U8(vBig.ToString));
  finally
    vBig.Free;
  end;
  MakeZip(P('doc.docx'), ['[Content_Types].xml', 'word/document.xml',
    'word/header1.xml'], ['<?xml version="1.0"?><Types/>',
    '<?xml version="1.0" encoding="UTF-8"?><w:document ' + CS_W +
    '><w:body><w:p><w:r><w:t>Docx paragraph one</w:t></w:r></w:p><w:p><w:r>' +
    '<w:t xml:space="preserve">second &amp; docxmarker</w:t></w:r></w:p>' +
    '</w:body></w:document>', '<?xml version="1.0"?><w:hdr ' + CS_W +
    '><w:p><w:r><w:t>headermarker</w:t></w:r></w:p></w:hdr>']);
  MakeZip(P('book.xlsx'), ['xl/sharedStrings.xml', 'xl/worksheets/sheet1.xml'],
    ['<?xml version="1.0"?><sst><si><t>xlsxshared</t></si><si><r><t>rich</t>' +
    '</r><r><t>text</t></r></si></sst>', '<?xml version="1.0"?><worksheet>' +
    '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" ' +
    't="inlineStr"><is><t>inlinemarker</t></is></c></row></sheetData>' +
    '</worksheet>']);
  MakeZip(P('deck.pptx'), ['ppt/slides/slide1.xml'],
    ['<?xml version="1.0"?><p:sld><p:cSld><p:spTree><p:sp><p:txBody><a:p>' +
    '<a:r><a:t>pptxmarker slide</a:t></a:r></a:p></p:txBody></p:sp>' +
    '</p:spTree></p:cSld></p:sld>']);
  MakeZip(P('note.odt'), ['mimetype', 'content.xml'],
    ['application/vnd.oasis.opendocument.text',
    '<?xml version="1.0"?><office:document-content><office:body><office:text>' +
    '<text:h>Odt heading</text:h><text:p>odtmarker<text:s/>with<text:tab/>' +
    'tab &lt;x&gt;</text:p></office:text></office:body>' +
    '</office:document-content>']);
  MakePdf(P('paper.pdf'), 'pdfmarker hello');
  SetLength(vBytes, 0);
end;

function Extract(const Name: string; out Text: string;
  MaxBytes: Int64 = 1024 * 1024): TsgcFSearchExtractResult;
begin
  Result := sgcFSearchExtractText(P(Name), MaxBytes, Text);
end;

procedure TestExtract;
var
  vText: string;
begin
  Check((Extract('utf8.txt', vText) = fserOK) and (Pos('caf'#$00E9' MixedCase',
    vText) > 0), 'utf8 no bom');
  Check((Extract('utf8bom.txt', vText) = fserOK) and
    (Copy(vText, 1, 9) = 'bomneedle'), 'utf8 bom stripped');
  Check((Extract('utf16.txt', vText) = fserOK) and
    (Copy(vText, 1, 19) = 'wide needle sixteen'), 'utf16 le');
  Check((Extract('ansi.txt', vText) = fserOK) and (Pos('caf'#$00E9' ansimarker',
    vText) > 0), 'ansi 1252');
  Check((Extract('README', vText) = fserOK) and (Pos('noextmarker', vText) > 0),
    'no extension sniffed as text');
  Check(Extract('blob.qqq', vText) = fserBinary, 'unknown ext binary sniff');
  Check(Extract('data.bin', vText) = fserBinary, 'binary extension');
  Check(Extract('big.txt', vText) = fserTooBig, 'too big');
  Check(Extract('big.txt', vText, 0) = fserOK, 'no limit');
  Check(Extract('missing.txt', vText) = fserError, 'missing file');
  Check((Extract('code.pas', vText) = fserOK) and (vText = CS_PAS), 'pas');
  Check((Extract('doc.docx', vText) = fserOK) and
    (Pos('Docx paragraph one'#10'second & docxmarker', vText) > 0) and
    (Pos('headermarker', vText) > 0), 'docx: ' + vText);
  Check((Extract('book.xlsx', vText) = fserOK) and
    (Pos('xlsxshared', vText) > 0) and (Pos('richtext', vText) > 0) and
    (Pos('inlinemarker', vText) > 0) and (Pos('0', vText) = 0),
    'xlsx: ' + vText);
  Check((Extract('deck.pptx', vText) = fserOK) and
    (Pos('pptxmarker slide', vText) > 0), 'pptx');
  Check((Extract('note.odt', vText) = fserOK) and
    (Pos('Odt heading'#10, vText) > 0) and (Pos('odtmarker with'#9'tab <x>',
    vText) > 0), 'odt: ' + vText);
  Check(sgcFSearchFileKind('a.DOCX') = fsfkWord, 'kind case-insensitive');
  Check(sgcFSearchIsOfflineAttributes(SGCFS_ATTR_RECALL_ON_DATA_ACCESS) and
    sgcFSearchIsOfflineAttributes(FILE_ATTRIBUTE_OFFLINE) and
    not sgcFSearchIsOfflineAttributes(FILE_ATTRIBUTE_ARCHIVE), 'offline attrs');
  GHasPdf := sgcFSearchIFilterAvailable('pdf');
  Writeln('PDF IFilter registered: ', GHasPdf);
  if GHasPdf then
    Check((Extract('paper.pdf', vText) = fserOK) and
      (Pos('pdfmarker', vText) > 0), 'pdf ifilter: ' +
      IntToStr(Ord(Extract('paper.pdf', vText))) + ' ' + vText)
  else
    Check(Extract('paper.pdf', vText) = fserUnsupported, 'pdf unsupported');
end;

function HitsIn(const Hits: TsgcFSearchGrepHits; const Name: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Hits) do
    if EndsText('\' + Name, Hits[i].Path) then
      Inc(Result);
end;

function DoGrep(Grep: TsgcFSearchGrep; Content: TsgcFSearchContentIndex;
  const Pattern: string; Mode: TsgcFSearchGrepMode;
  out Hits: TsgcFSearchGrepHits): Integer;
begin
  Result := Grep.Search(Content, Pattern, Mode, 1000, nil, Hits);
end;

function MatchText(const Hit: TsgcFSearchGrepHit): string;
begin
  Result := Copy(Hit.LineText, Hit.MatchPos, Hit.MatchLen);
end;

procedure TestIndexAndGrep;
var
  vIndex: TsgcFSearchIndex;
  vCrawler: TsgcFSearchCrawler;
  vContent, vLoaded: TsgcFSearchContentIndex;
  vIndexer, vIndexer2: TsgcFSearchContentIndexer;
  vGrep: TsgcFSearchGrep;
  vHits: TsgcFSearchGrepHits;
  vDoc: TsgcFSearchContentDoc;
  vIds: TsgcFSearchDocIds;
  vLits: TArray<string>;
  vCount, i: Integer;
  vOk: Boolean;
begin
  vIndex := TsgcFSearchIndex.Create;
  vCrawler := TsgcFSearchCrawler.Create;
  vContent := TsgcFSearchContentIndex.Create;
  vLoaded := TsgcFSearchContentIndex.Create;
  vGrep := TsgcFSearchGrep.Create;
  vIndexer := nil;
  vIndexer2 := nil;
  try
    Check(vCrawler.CrawlRoot(vIndex, GTree, nil) >= 0, 'crawl tree');
    vIndexer := TsgcFSearchContentIndexer.Create(vIndex, vContent,
      [GTree], nil, 1);
    vIndexer.Start;
    Check(vIndexer.WaitIdle(60000), 'indexer idle');
    vGrep.Indexer := vIndexer;
    // what got indexed
    Check(vContent.FindDoc(P('utf8.txt'), vDoc) and (vDoc.Size > 0),
      'utf8 indexed');
    Check(vContent.FindDoc(P('sub\deep\nested.md'), vDoc), 'nested indexed');
    Check(vContent.FindDoc(P('doc.docx'), vDoc), 'docx indexed');
    Check(not vContent.FindDoc(P('node_modules\lib.js'), vDoc),
      'node_modules excluded');
    Check(not vContent.FindDoc(P('big.txt'), vDoc), 'big file not indexed');
    Check(not vContent.FindDoc(P('data.bin'), vDoc), 'binary ext not indexed');
    Check(vContent.FindDoc(P('blob.qqq'), vDoc), 'sniffed binary recorded');
    Check(Length(vContent.Candidates(['blobmarker'])) = 0, 'binary no text');
    Check(Length(vContent.Candidates(['excludedmarker'])) = 0, 'excluded text');
    Check(Length(vContent.Candidates(['bigmarker'])) = 0, 'big text');
    Check(vContent.FindDoc(P('paper.pdf'), vDoc) = GHasPdf, 'pdf per filter');
    if GHasPdf then
      Check(Length(vContent.Candidates(['pdfmarker'])) = 1, 'pdf candidate');
    Check(vIndexer.Pending = 0, 'pending 0');
    Check(vIndexer.Indexed >= 13, 'indexed count ' +
      IntToStr(vIndexer.Indexed));
    // candidates
    Check(Length(vContent.Candidates(['needle'])) = 3, 'needle x3');
    vIds := vContent.Candidates(['needle', 'SIXTEEN']);
    Check((Length(vIds) = 1) and SameText(vContent.DocPath(vIds[0]),
      P('utf16.txt')), 'intersection');
    Check(Length(vContent.Candidates(['needle', 'nothing_like_it'])) = 0,
      'intersection empty');
    vCount := Length(vContent.Candidates(nil));
    Check((vCount >= 13) and (Length(vContent.Candidates(['ab'])) = vCount),
      'short literal no constraint');
    Check(vGrep.CaseMode = fsgcInsensitive, 'case mode default insensitive');
    // literal + smart-case
    vGrep.CaseMode := fsgcSmart;
    Check((DoGrep(vGrep, vContent, 'mixedcase', fsgmLiteral, vHits) = 1) and
      (HitsIn(vHits, 'utf8.txt') = 1) and (vHits[0].LineNo = 1) and
      (vHits[0].LineText = 'Hello UTF8 caf'#$00E9' MixedCase needleone') and
      (vHits[0].MatchPos = 17) and (vHits[0].MatchLen = 9),
      'literal insensitive');
    Check(DoGrep(vGrep, vContent, 'MixedCase', fsgmLiteral, vHits) = 1,
      'literal sensitive match');
    Check(DoGrep(vGrep, vContent, 'MIXEDCASE', fsgmLiteral, vHits) = 0,
      'literal sensitive miss');
    Check((DoGrep(vGrep, vContent, 'caf'#$00E9, fsgmLiteral, vHits) = 2) and
      (HitsIn(vHits, 'ansi.txt') = 1) and (vGrep.FilesMatched = 2), 'accent');
    Check((DoGrep(vGrep, vContent, 'second line', fsgmLiteral, vHits) = 1) and
      (vHits[0].LineNo = 2), 'phrase line 2');
    Check((DoGrep(vGrep, vContent, 'docxmarker', fsgmLiteral, vHits) = 1) and
      (HitsIn(vHits, 'doc.docx') = 1) and (vHits[0].LineNo = 2), 'docx grep');
    Check((DoGrep(vGrep, vContent, 'inlinemarker', fsgmLiteral, vHits) = 1),
      'xlsx grep');
    Check((DoGrep(vGrep, vContent, 'odtmarker', fsgmLiteral, vHits) = 1),
      'odt grep');
    // words
    Check((DoGrep(vGrep, vContent, 'sixteen wide', fsgmWords, vHits) = 1) and
      (HitsIn(vHits, 'utf16.txt') = 1), 'words');
    Check(DoGrep(vGrep, vContent, 'wide absentword', fsgmWords, vHits) = 0,
      'words all required');
    // regex
    vLits := TsgcFSearchGrep.RegexLiterals('foo\d+bar(baz)?qux[a-z]*end?');
    Check((Length(vLits) = 3) and (vLits[0] = 'foo') and (vLits[1] = 'bar') and
      (vLits[2] = 'qux'), 'regex literals');
    Check(Length(TsgcFSearchGrep.RegexLiterals('abcd|efgh')) = 0,
      'regex alternation');
    Check((DoGrep(vGrep, vContent, 'compute_\w+\(', fsgmRegex, vHits) = 2) and
      (HitsIn(vHits, 'script.py') = 2) and (vHits[0].LineNo = 1) and
      (vHits[1].LineNo = 7), 'regex');
    Check((DoGrep(vGrep, vContent, 'zzqqzz|inlinemarker', fsgmRegex, vHits) = 1)
      and (HitsIn(vHits, 'book.xlsx') = 1), 'regex no literal');
    Check((DoGrep(vGrep, vContent, '\);$', fsgmRegex, vHits) = 1) and
      (HitsIn(vHits, 'code.pas') = 1) and (vHits[0].LineNo = 11),
      'regex crlf $');
    Check(DoGrep(vGrep, vContent, 'COMPUTE_\w+', fsgmRegex, vHits) = 0,
      'regex smart-case sensitive');
    Check(not TsgcFSearchGrep.IsCaseSensitive('\W\S\d', fsgmRegex) and
      TsgcFSearchGrep.IsCaseSensitive('A', fsgmLiteral), 'smart-case rule');
    vOk := False;
    try
      DoGrep(vGrep, vContent, 'abc(', fsgmRegex, vHits);
    except
      vOk := True;
    end;
    Check(vOk, 'invalid regex raises');
    // symbol
    Check((DoGrep(vGrep, vContent, 'ComputeTotal', fsgmSymbol, vHits) = 1) and
      (vHits[0].LineNo = 7), 'symbol function');
    Check((DoGrep(vGrep, vContent, 'BuildWidget', fsgmSymbol, vHits) = 2) and
      (vHits[0].LineNo = 5) and (vHits[1].LineNo = 9), 'symbol procedure');
    Check((DoGrep(vGrep, vContent, 'compute_total', fsgmSymbol, vHits) = 1) and
      (HitsIn(vHits, 'script.py') = 1) and (vHits[0].LineNo = 1), 'symbol def');
    Check((DoGrep(vGrep, vContent, 'WidgetMaker', fsgmSymbol, vHits) = 1) and
      (HitsIn(vHits, 'script.py') = 1), 'symbol class');
    Check((DoGrep(vGrep, vContent, 'TWidgetMaker', fsgmSymbol, vHits) >= 1) and
      (vHits[0].LineNo = 4), 'symbol pascal class');
    // insensitive: a capital letter changes nothing
    vGrep.CaseMode := fsgcInsensitive;
    Check((DoGrep(vGrep, vContent, 'MIXEDCASE', fsgmLiteral, vHits) = 1) and
      (HitsIn(vHits, 'utf8.txt') = 1) and (vHits[0].MatchPos = 17) and
      (vHits[0].MatchLen = 9) and (MatchText(vHits[0]) = 'MixedCase'),
      'insensitive literal');
    Check(DoGrep(vGrep, vContent, 'mixedcase', fsgmLiteral, vHits) = 1,
      'insensitive literal, no capital');
    Check((DoGrep(vGrep, vContent, 'SIXTEEN WIDE', fsgmWords, vHits) = 1) and
      (HitsIn(vHits, 'utf16.txt') = 1) and (MatchText(vHits[0]) = 'wide'),
      'insensitive words');
    Check((DoGrep(vGrep, vContent, 'COMPUTE_\w+\(', fsgmRegex, vHits) = 2) and
      (vHits[0].MatchPos = 5) and (MatchText(vHits[0]) = 'compute_total('),
      'insensitive regex');
    Check((DoGrep(vGrep, vContent, 'COMPUTETOTAL', fsgmSymbol, vHits) = 1) and
      (vHits[0].LineNo = 7) and (MatchText(vHits[0]) = 'function ComputeTotal'),
      'insensitive symbol');
    // sensitive: a text without capitals does not ignore case either
    vGrep.CaseMode := fsgcSensitive;
    Check((DoGrep(vGrep, vContent, 'MixedCase', fsgmLiteral, vHits) = 1) and
      (vHits[0].MatchPos = 17) and (MatchText(vHits[0]) = 'MixedCase'),
      'sensitive literal match');
    Check(DoGrep(vGrep, vContent, 'mixedcase', fsgmLiteral, vHits) = 0,
      'sensitive literal, no capital');
    Check(DoGrep(vGrep, vContent, 'MIXEDCASE', fsgmLiteral, vHits) = 0,
      'sensitive literal miss');
    Check((DoGrep(vGrep, vContent, 'sixteen wide', fsgmWords, vHits) = 1) and
      (MatchText(vHits[0]) = 'wide'), 'sensitive words match');
    Check(DoGrep(vGrep, vContent, 'mixedcase needleone', fsgmWords, vHits) = 0,
      'sensitive words, no capital');
    Check((DoGrep(vGrep, vContent, 'compute_\w+\(', fsgmRegex, vHits) = 2) and
      (vHits[0].MatchPos = 5) and (MatchText(vHits[0]) = 'compute_total('),
      'sensitive regex match');
    Check(DoGrep(vGrep, vContent, 'mixedcase', fsgmRegex, vHits) = 0,
      'sensitive regex, no capital');
    Check((DoGrep(vGrep, vContent, 'ComputeTotal', fsgmSymbol, vHits) = 1) and
      (vHits[0].LineNo = 7) and (MatchText(vHits[0]) = 'function ComputeTotal'),
      'sensitive symbol match');
    Check(DoGrep(vGrep, vContent, 'computetotal', fsgmSymbol, vHits) = 0,
      'sensitive symbol, no capital');
    vGrep.CaseMode := fsgcSmart;
    // filter callback
    vCount := vGrep.Search(vContent, 'marker', fsgmLiteral, 1000,
      function(Path: string): Boolean
      begin
        Result := EndsText('.docx', Path);
      end, vHits);
    Check((vCount = 2) and (HitsIn(vHits, 'doc.docx') = 2), 'filter');
    Check(vGrep.Search(vContent, 'marker', fsgmLiteral, 3, nil, vHits)
      = 3, 'limit');
    // stale verification: results follow the file on disk
    WriteRaw(P('stale.txt'), U8('nothing'#10'here stalemarker moved'#10'x'#10));
    Check((DoGrep(vGrep, vContent, 'stalemarker', fsgmLiteral, vHits) = 1) and
      (vHits[0].LineNo = 2), 'stale moved line');
    Check(vIndexer.WaitIdle(30000) and vContent.FindDoc(P('stale.txt'), vDoc)
      and (vDoc.Size = 33), 'stale re-queued');
    WriteRaw(P('stale.txt'), U8('gone now'#10));
    Check(DoGrep(vGrep, vContent, 'stalemarker', fsgmLiteral, vHits) = 0,
      'stale text gone');
    Check(vIndexer.WaitIdle(30000) and
      (Length(vContent.Candidates(['stalemarker'])) = 0), 'stale reindexed');
    // NotifyChanged picks up a new file
    WriteRaw(P('newfile.txt'), U8('brandnewmarker'#10));
    vIndexer.NotifyChanged(P('newfile.txt'));
    vIndexer.NotifyChanged(P('node_modules\new.js'));
    Check(vIndexer.WaitIdle(30000) and
      (Length(vContent.Candidates(['brandnewmarker'])) = 1), 'notify changed');
    Check(DoGrep(vGrep, vContent, 'brandnewmarker', fsgmLiteral, vHits) = 1,
      'notify grep');
    Check(not vIndexer.IsIndexablePath(P('node_modules\x.txt')) and
      not vIndexer.IsIndexablePath(P('a.exe')) and
      not vIndexer.IsIndexablePath('C:\elsewhere\x.txt') and
      vIndexer.IsIndexablePath(P('sub\x.txt')), 'indexable path');
    // remove + save / load
    vCount := vContent.DocCount;
    Check(vContent.Remove(P('utf8.txt')) and (vContent.DocCount = vCount - 1),
      'remove');
    Check(Length(vContent.Candidates(['needleone'])) = 0,
      'removed no candidate');
    vContent.SaveToFile(GHome + '\' + SGCFS_CONTENT_FILE);
    Check(vLoaded.LoadFromFile(GHome + '\' + SGCFS_CONTENT_FILE), 'load');
    Check((vLoaded.DocCount = vContent.DocCount) and
      (vLoaded.TrigramCount = vContent.TrigramCount), 'load counts');
    vIds := vLoaded.Candidates(['sixteen']);
    Check((Length(vIds) = 1) and SameText(vLoaded.DocPath(vIds[0]),
      P('utf16.txt')), 'load candidates');
    Check(not vLoaded.FindDoc(P('utf8.txt'), vDoc) and
      vLoaded.FindDoc(P('code.pas'), vDoc), 'load docs');
    Check(not vLoaded.LoadFromFile(GHome + '\nothere.idx'), 'load missing');
    // incremental restart: only the removed (still on disk) file is read
    vIndexer.Stop;
    Check(vCrawler.CrawlRoot(vIndex, GTree, nil) >= 0, 'recrawl');
    vIndexer2 := TsgcFSearchContentIndexer.Create(vIndex, vLoaded,
      [GTree], nil, 1);
    vIndexer2.Start;
    Check(vIndexer2.WaitIdle(60000) and (vIndexer2.Indexed = 1) and
      vLoaded.FindDoc(P('utf8.txt'), vDoc), 'incremental restart ' +
      IntToStr(vIndexer2.Indexed));
    // a deleted file: grep re-queues the removal
    DeleteFile(P('script.py'));
    vGrep.Indexer := vIndexer2;
    Check(DoGrep(vGrep, vLoaded, 'compute_total', fsgmLiteral, vHits) = 0,
      'deleted file no hit');
    Check(vIndexer2.WaitIdle(30000) and not vLoaded.FindDoc(P('script.py'),
      vDoc), 'deleted file removed');
    vIndexer2.NotifyRemoved(P('sub'));
    Check(vIndexer2.WaitIdle(30000) and
      not vLoaded.FindDoc(P('sub\deep\nested.md'), vDoc), 'folder removed');
    i := 0;
    Check(i = 0, 'done');
  finally
    vIndexer2.Free;
    vIndexer.Free;
    vGrep.Free;
    vLoaded.Free;
    vContent.Free;
    vCrawler.Free;
    vIndex.Free;
  end;
end;

procedure TestTimings;
const
  CS_DIRS = 10;
  CS_FILES = 100;
var
  vIndex: TsgcFSearchIndex;
  vCrawler: TsgcFSearchCrawler;
  vContent: TsgcFSearchContentIndex;
  vIndexer: TsgcFSearchContentIndexer;
  vGrep: TsgcFSearchGrep;
  vHits: TsgcFSearchGrepHits;
  vSB: TStringBuilder;
  vWatch: TStopwatch;
  d, f, w, vSeed: Integer;
  vBuild, vWord, vRare, vRegex: Int64;
begin
  vSeed := 12345;
  vSB := TStringBuilder.Create;
  try
    for d := 0 to CS_DIRS - 1 do
      for f := 0 to CS_FILES - 1 do
      begin
        vSB.Clear;
        vSB.Append('lorem ipsum file ').Append(d * CS_FILES + f).Append(#10);
        for w := 1 to 300 do
        begin
          vSeed := (vSeed * 1103515245 + 12345) and $7FFFFFFF;
          vSB.Append('wrd').Append(Char(Ord('a') + vSeed mod 26))
            .Append(Char(Ord('a') + (vSeed shr 8) mod 26))
            .Append(vSeed mod 100);
          if w mod 12 = 0 then
            vSB.Append(#10)
          else
            vSB.Append(' ');
        end;
        if d * CS_FILES + f = 500 then
          vSB.Append('uniquezebra marker'#10);
        WriteRaw(Format('%s\dir_%d\file_%d.txt', [GMany, d, f]),
          U8(vSB.ToString));
      end;
  finally
    vSB.Free;
  end;
  vIndex := TsgcFSearchIndex.Create;
  vCrawler := TsgcFSearchCrawler.Create;
  vContent := TsgcFSearchContentIndex.Create;
  vGrep := TsgcFSearchGrep.Create;
  vIndexer := nil;
  try
    Check(vCrawler.CrawlRoot(vIndex, GMany, nil) >= 0, 'crawl many');
    vWatch := TStopwatch.StartNew;
    vIndexer := TsgcFSearchContentIndexer.Create(vIndex, vContent,
      [GMany], nil, 16);
    vIndexer.Start;
    Check(vIndexer.WaitIdle(120000), 'many idle');
    vBuild := vWatch.ElapsedMilliseconds;
    Check(vContent.DocCount = CS_DIRS * CS_FILES, 'many docs');
    vGrep.MaxLinesPerFile := 1;
    Check(vGrep.Search(vContent, 'lorem ipsum', fsgmWords, 100000, nil, vHits)
      = CS_DIRS * CS_FILES, 'many common words');
    vWord := vGrep.ElapsedMs;
    Check(vGrep.Search(vContent, 'uniquezebra', fsgmWords, 100000, nil, vHits)
      = 1, 'many rare word');
    vRare := vGrep.ElapsedMs;
    Check(vGrep.Search(vContent, '\bwrdq[a-z]\d\b', fsgmRegex, 100000, nil,
      vHits) > 0, 'many regex');
    vRegex := vGrep.ElapsedMs;
    Writeln(Format('Timings (1000 files): index build %d ms, common words %d ms'
      + ', rare word %d ms, regex (all files) %d ms, trigrams %d',
      [vBuild, vWord, vRare, vRegex, vContent.TrigramCount]));
  finally
    vIndexer.Free;
    vGrep.Free;
    vContent.Free;
    vCrawler.Free;
    vIndex.Free;
  end;
end;

type
  TSaveThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Content: TsgcFSearchContentIndex;
    FileName: string;
    Error: string;
  end;

  // what the content indexer does while a checkpoint saves
  TWriterThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Content: TsgcFSearchContentIndex;
    Ops: Integer;
  end;

  // Exits the process with code 1 unless freed within the timeout. It
  // writes through WriteFile, from a message built in advance: after a heap
  // corruption the memory manager itself hangs.
  TWatchdog = class(TThread)
  private
    FDone: THandle;
    FMsg: AnsiString;
    FTimeoutMs: Cardinal;
  protected
    procedure Execute; override;
  public
    constructor Create(const What: string; TimeoutMs: Cardinal);
    destructor Destroy; override;
  end;

constructor TWatchdog.Create(const What: string; TimeoutMs: Cardinal);
begin
  inherited Create(False);
  FDone := CreateEvent(nil, True, False, nil);
  FMsg := AnsiString(Format('[FAIL] %s did not finish within %d ms'#13#10,
    [What, TimeoutMs]));
  FTimeoutMs := TimeoutMs;
end;

destructor TWatchdog.Destroy;
begin
  SetEvent(FDone);
  inherited; // waits for Execute
  CloseHandle(FDone);
end;

procedure TWatchdog.Execute;
var
  vWritten: Cardinal;
begin
  if WaitForSingleObject(FDone, FTimeoutMs) <> WAIT_OBJECT_0 then
  begin
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), PAnsiChar(FMsg)^, Length(FMsg),
      vWritten, nil);
    ExitProcess(1);
  end;
end;

procedure TSaveThread.Execute;
begin
  try
    Content.SaveToFile(FileName);
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TWriterThread.Execute;
var
  vDoc: TsgcFSearchContentDoc;
  vPath: string;
begin
  while not Terminated do
  begin
    vPath := Format('C:\sgcfs_cc\w%d.txt', [Ops mod 500]);
    Content.FindDoc(vPath, vDoc);
    if (Ops mod 3) = 0 then
      Content.Remove(vPath)
    else
      Content.AddOrUpdate(vPath, Ops, Ops, 'writer text ' + IntToStr(Ops));
    Inc(Ops);
  end;
end;

// SaveToFile on its own thread (the engine thread's role), timed; the
// TWatchdog of the caller fails the test if it never returns
procedure SaveWithin(Content: TsgcFSearchContentIndex;
const FileName, What: string);
var
  vThread: TSaveThread;
  vSw: TStopwatch;
begin
  vThread := TSaveThread.Create(True);
  vThread.Content := Content;
  vThread.FileName := FileName;
  vSw := TStopwatch.StartNew;
  vThread.Start;
  vThread.WaitFor;
  Writeln(Format('%s: %d ms', [What, vSw.ElapsedMilliseconds]));
  Check(vThread.Error = '', What + ' raised ' + vThread.Error);
  vThread.Free;
end;

function CcPath(i: Integer): string;
begin
  Result := Format('C:\sgcfs_cc\doc%.5d.txt', [i]);
end;

// SaveToFile compacts first, which trims every posting list to its length:
// with most documents tombstoned it must return, alone and while a writer
// appends to the trimmed lists (that overran them, corrupted the heap and
// hung every thread in the memory manager), and the file must load back
procedure TestSaveCompact;
const
  CS_DOCS = 3000;
var
  vContent, vLoaded: TsgcFSearchContentIndex;
  vWriter: TWriterThread;
  vDoc: TsgcFSearchContentDoc;
  vFile: string;
  vDog: TWatchdog;
  i, vLive: Integer;
begin
  vFile := GHome + '\compact.idx';
  Flush(Output);
  vDog := TWatchdog.Create('TestSaveCompact', 60000);
  vContent := TsgcFSearchContentIndex.Create;
  vLoaded := TsgcFSearchContentIndex.Create;
  try
    for i := 0 to CS_DOCS - 1 do
      vContent.AddOrUpdate(CcPath(i), i, i,
        Format('document %d shared marker qwertyzz value%d', [i, i * 7]));
    // 2 of every 3 removed, every 30th updated (its old docid dies too)
    for i := 0 to CS_DOCS - 1 do
      if (i mod 3) <> 0 then
        vContent.Remove(CcPath(i))
      else if (i mod 30) = 0 then
        vContent.AddOrUpdate(CcPath(i), i + 1, i,
          Format('document %d updated marker qwertyzz', [i]));
    vLive := vContent.DocCount;
    Check(vLive = CS_DOCS div 3, Format('live after removals: %d', [vLive]));
    SaveWithin(vContent, vFile, Format('save after %d removals',
      [CS_DOCS - vLive]));
    Check(vContent.DocCount = vLive, 'save keeps the live docs');
    Check(Length(vContent.Candidates(['qwertyzz'])) = vLive,
      'candidates after compact');
    Check(vLoaded.LoadFromFile(vFile), 'compacted file loads');
    Check(vLoaded.DocCount = vLive, 'loaded doc count');
    Check(Length(vLoaded.Candidates(['qwertyzz'])) = vLive,
      'loaded candidates');
    Check(Length(vLoaded.Candidates(['updated marker'])) = CS_DOCS div 30,
      'loaded updated docs');
    Check(vLoaded.FindDoc(CcPath(30), vDoc) and (vDoc.Size = 31),
      'updated doc round-trips');
    Check(not vLoaded.FindDoc(CcPath(1), vDoc), 'removed doc stays removed');
    // tombstones again, then save while a writer uses the index
    for i := 0 to CS_DOCS - 1 do
      if (i mod 6) = 3 then
        vContent.Remove(CcPath(i));
    vWriter := TWriterThread.Create(True);
    try
      vWriter.Content := vContent;
      vWriter.Start;
      Sleep(50);
      SaveWithin(vContent, vFile, 'save with a concurrent writer');
      vWriter.Terminate;
      vWriter.WaitFor;
      Check(vWriter.Ops > 0, 'writer ran');
    finally
      vWriter.Free;
    end;
    Check(vLoaded.LoadFromFile(vFile), 'concurrent save loads');
    Check(Length(vLoaded.Candidates(['qwertyzz'])) = CS_DOCS div 6,
      'concurrent save candidates');
    Check(vLoaded.FindDoc(CcPath(6), vDoc) and not vLoaded.FindDoc(CcPath(3),
      vDoc), 'concurrent save docs');
  finally
    vLoaded.Free;
    vContent.Free;
    vDog.Free;
  end;
end;

begin
  try
    CoInitializeEx(nil, COINIT_MULTITHREADED);
    GBase := IncludeTrailingPathDelimiter(TPath.GetTempPath) +
      'sgcFSearchTests\content';
    if TDirectory.Exists(GBase) then
      TDirectory.Delete(GBase, True);
    GTree := GBase + '\tree';
    GHome := GBase + '\home';
    GMany := GBase + '\many';
    ForceDirectories(GTree);
    ForceDirectories(GHome);
    SetEnvironmentVariable(SGCFS_HOME_ENV, PChar(GHome));
    CreateSamples;
    TestExtract;
    TestIndexAndGrep;
    TestSaveCompact;
    TestTimings;
    try
      TDirectory.Delete(GBase, True);
    except
      Writeln('cleanup failed');
    end;
    if GFails = 0 then
    begin
      Writeln('[PASS] ', GChecks, ' checks');
      ExitCode := 0;
    end
    else
    begin
      Writeln('[FAIL] ', GFails, ' of ', GChecks, ' checks failed');
      ExitCode := 1;
    end;
  except
    on E: Exception do
    begin
      Writeln('[FAIL] exception ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

end.
