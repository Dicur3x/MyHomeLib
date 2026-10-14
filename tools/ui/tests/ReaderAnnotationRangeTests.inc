// Standalone include for BuiltinReaderTest. Requires System.JSON,
// System.Win.ComObj and System.Variants in the owning DPR uses list.
procedure AuditReaderAnnotationRangesAndExports;
var
  Root, Profile, FileName, BeforeHash, ID, HTML, XML, StylesXML, BeforeProfile: string;
  Store, Reopened, Stale: TReaderAnnotations; Note: TReaderAnnotation;
  Notes, Hits, ReopenedNotes: TArray<TReaderAnnotation>; Index: TReaderAnnotationIndex;
  Document, Styles: OleVariant; Stream: TMemoryStream; Zip: TZipFile; Bytes: TBytes;
  Locked: TFileStream; Failed: Boolean; MaxVisited, TotalVisited: Integer;
  Layouts: TDictionary<string,Boolean>; JSON: System.JSON.TJSONValue;
  BeforeState, BodyText: string;

  function XMLDocument(const Content: string): OleVariant;
  begin
    Result:=System.Win.ComObj.CreateOleObject('Msxml2.DOMDocument.6.0');
    Result.async:=False; Require(Boolean(Result.loadXML(Content)),'Export produced malformed XML');
    Result.setProperty('SelectionNamespaces','xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"');
  end;

  function Occurrences(const Value, Needle: string): Integer;
  var At: Integer;
  begin
    Result:=0; At:=1;
    while At<=Length(Value) do
    begin At:=PosEx(Needle,Value,At); if At=0 then Break; Inc(Result); Inc(At,Length(Needle)); end;
  end;

  function NoteSnapshot(const Entries: TArray<TReaderAnnotation>): string;
  var Text: TStringBuilder;
  begin
    Text:=TStringBuilder.Create;
    try
      for var Item in Entries do
        Text.Append(Item.ID).Append(#1).Append(Item.BookID).Append(#1).Append(Item.BookTitle).Append(#1).
          Append(Item.Title).Append(#1).Append(Item.Text).Append(#1).Append(Item.Quote).Append(#1).
          Append(Item.Place).Append(#1).Append(Item.Created).Append(#1).Append(Item.Position).Append(#1).
          Append(Item.RangeStart).Append(#1).Append(Item.RangeEnd).Append(#1).
          Append(BoolToStr(Item.RangeIsPageText,True)).Append(#13);
      Result:=THashSHA2.GetHashString(Text.ToString);
    finally Text.Free; end;
  end;

  procedure RequireIDs(const Found: TArray<TReaderAnnotation>; First, Last, Page: Integer; PageText, PointMarkers: Boolean);
  var Expected: TList<string>; InRange: Boolean;
  begin
    Expected:=TList<string>.Create;
    try
      for var Item in Notes do
      begin
        if ReaderAnnotationHasRange(Item) then
          InRange:=(Item.RangeIsPageText=PageText) and
            (not PageText or (Item.Position=Page)) and (Item.RangeStart<Last) and (Item.RangeEnd>First)
        else if not PointMarkers then InRange:=False
        else if PageText then InRange:=Item.Position=Page
        else InRange:=(Item.Position>=First) and (Item.Position<Last);
        if InRange then Expected.Add(Item.ID);
      end;
      Require(Length(Found)=Expected.Count,'Indexed annotation query differs from independent interval oracle');
      for var I:=0 to High(Found) do
        Require(Found[I].ID=Expected[I],'Indexed annotation query changed identity or stable note order');
    finally Expected.Free; end;
  end;

  procedure CheckInvalidJSON(const Source: string);
  var SourceHash: string; Rejected: Boolean;
  begin
    TFile.WriteAllText(FileName,Source,TEncoding.UTF8); SourceHash:=THashSHA2.GetHashStringFromFile(FileName);
    Rejected:=False;
    try
      var Invalid:=TReaderAnnotations.Create(Profile);
      Invalid.Free;
    except on E: Exception do Rejected:=not (E is EAccessViolation); end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(FileName)=SourceHash),
      'Invalid/future annotation JSON was accepted, dereferenced nil or altered');
  end;

begin
  RequireIsolatedRegression;
  Require(TPath.GetFullPath(GetCurrentDir).StartsWith('G:\',True),'Annotation tests must remain in a private G fixture');
  Root:=TPath.Combine(GetCurrentDir,'annotation-ranges-'+TGUID.NewGuid.ToString);
  ForceDirectories(Root); Profile:=TPath.Combine(Root,'reader.ini'); FileName:=TPath.Combine(Root,'reader-notes.json');
  TFile.WriteAllText(Profile,'[Protected]'+sLineBreak+'Keep=ё і ў 😀',TEncoding.UTF8);
  BeforeProfile:=THashSHA2.GetHashStringFromFile(Profile);

  TFile.WriteAllText(FileName,
    '{"version":1,"notes":[{"id":"legacy","book":"one","bookTitle":"Legacy book","title":"Legacy explicit title",'+
    '"text":"Legacy explicit title body remains exact.","quote":"Original quote ё 😀","place":"Page 5","created":"2026-10-14T01:00:00Z","position":42}]}',
    TEncoding.UTF8);
  BeforeHash:=THashSHA2.GetHashStringFromFile(FileName);
  Store:=TReaderAnnotations.Create(Profile);
  try
    Require(THashSHA2.GetHashStringFromFile(FileName)=BeforeHash,'Loading a legacy notes file rewrote it');
    ReopenedNotes:=Store.Items; Require((Length(ReopenedNotes)=1) and not ReaderAnnotationHasRange(ReopenedNotes[0]),
      'Legacy notes acquired a guessed text range');
    BeforeHash:=NoteSnapshot(ReopenedNotes);
    Note:=Default(TReaderAnnotation); Note.BookID:='one'; Note.BookTitle:='Новая книга'; Note.Position:=100;
    Note.Text:='BODY_ONLY_ONCE_ё_😀'; Note.Quote:='QUOTE_ONLY_ONCE'; Note.RangeStart:=105; Note.RangeEnd:=123;
    ID:=Store.Put(Note);
    Require((Store.Items[1].Title='') and (ReaderAnnotationDisplayTitle(Store.Items[1])='—'),
      'Optional blank title was filled from body text or not represented by a dash');
    Reopened:=TReaderAnnotations.Create(Profile);
    try
      Require(NoteSnapshot(TArray<TReaderAnnotation>.Create(Reopened.Items[0]))=BeforeHash,
        'Saving a new ranged note altered legacy explicit title, quote, body or context');
      Require((Reopened.Items[1].RangeStart=105) and (Reopened.Items[1].RangeEnd=123) and
        not Reopened.Items[1].RangeIsPageText,'Global character range did not survive reopen');
    finally Reopened.Free; end;
    Note:=Store.Items[1]; Note.RangeIsPageText:=True; Note.Position:=7; Store.Put(Note);
    Reopened:=TReaderAnnotations.Create(Profile);
    try
      Require((Reopened.Items[1].Position=7) and Reopened.Items[1].RangeIsPageText and
        (Reopened.Items[1].RangeStart=105),'Page-local range changed the original page navigation position');
    finally Reopened.Free; end;
    XML:=TFile.ReadAllText(FileName,TEncoding.UTF8);
    JSON:=System.JSON.TJSONObject.ParseJSONValue(XML);
    try
      Require(JSON is System.JSON.TJSONObject,'Saved ranged notes are not JSON');
      Require(System.JSON.TJSONObject(JSON).GetValue<Integer>('version')=1,'Range support broke legacy schema version');
      var Rows:=System.JSON.TJSONArray(System.JSON.TJSONObject(JSON).GetValue('notes'));
      Require(System.JSON.TJSONObject(Rows.Items[0]).GetValue('rangeStart')=nil,'Legacy no-range note was rewritten with a guessed interval');
    finally JSON.Free; end;
    BeforeHash:=THashSHA2.GetHashStringFromFile(FileName); BeforeState:=NoteSnapshot(Store.Items);
    Locked:=TFileStream.Create(FileName,fmOpenRead or fmShareExclusive);
    try
      Note:=Store.Items[1]; Note.Text:='Replacement that must not survive a failed save';
      Failed:=False; try Store.Put(Note); except Failed:=True; end;
      Require(Failed and (NoteSnapshot(Store.Items)=BeforeState),'Failed notes save changed the in-memory range or body');
    finally Locked.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName)=BeforeHash,'Failed notes save damaged the old JSON');
    Stale:=TReaderAnnotations.Create(Profile);
    try
      BeforeHash:=THashSHA2.GetHashStringFromFile(FileName);
      BeforeState:=NoteSnapshot(Stale.Items);
      Note:=Store.Items[1]; Note.Text:='BODY_ONLY_ONCE_ё_😀 — новая редакция'; Store.Put(Note);
      Require(THashSHA2.GetHashStringFromFile(FileName)<>BeforeHash,
        'Concurrent-save fixture did not create a distinct newer revision');
      BeforeHash:=THashSHA2.GetHashStringFromFile(FileName); Failed:=False;
      Note:=Stale.Items[1]; Note.Text:='OUTDATED_EDIT_that_must_not_replace_newer_body';
      var SaveError:='';
      try Stale.Put(Note); except on E: Exception do begin Failed:=True; SaveError:=E.Message; end; end;
      Require(Failed and SaveError.Contains('изменены в другом окне') and
        (THashSHA2.GetHashStringFromFile(FileName)=BeforeHash) and
        (NoteSnapshot(Stale.Items)=BeforeState),
        'Concurrent annotation save overwrote a newer file or changed its rejected in-memory revision');
    finally Stale.Free; end;
    Note:=Store.Items[1]; Note.Text:='BODY_ONLY_ONCE_ё_😀'; Store.Put(Note);
    Writeln('PASS ranged notes preserve legacy v1 fields and blank titles, paged offsets, atomic failures and concurrent revisions');

    Notes:=TArray<TReaderAnnotation>.Create(Store.Items[1]);
    Layouts:=TDictionary<string,Boolean>.Create;
    try
      for var Style:=0 to 3 do
      begin
        HTML:=ReaderAnnotationsText(Notes,True,Style);
        Require((Occurrences(HTML,Notes[0].Text)=1) and (Occurrences(HTML,Notes[0].Quote)=1) and
          HTML.Contains('<h3>—</h3>'),'HTML repeats an optional title body, omits quote or invents a title');
        Require(HTML.Contains('<small>'+Notes[0].Created+'</small>'),
          'Empty note location invented a leading separator before the HTML creation date');
        Require(HTML.Contains('padding:') and HTML.Contains('line-height:'),'HTML style has no layout geometry');
        var Geometry:=Copy(HTML,Pos('<style>',HTML),Pos('</style>',HTML)-Pos('<style>',HTML));
        Require(not Layouts.ContainsKey(Geometry),'HTML export styles have identical geometry'); Layouts.Add(Geometry,True);
        TFile.WriteAllText(TPath.Combine(Root,'notes-style-'+IntToStr(Style)+'.html'),HTML,TEncoding.UTF8);
        Bytes:=ReaderAnnotationsDocx(Notes,Style); TFile.WriteAllBytes(TPath.Combine(Root,'notes-style-'+IntToStr(Style)+'.docx'),Bytes);
        Stream:=TMemoryStream.Create; Zip:=TZipFile.Create;
        try
          Stream.WriteBuffer(Bytes[0],Length(Bytes)); Stream.Position:=0; Zip.Open(Stream,zmRead);
          Require(Zip.FileCount=5,'DOCX export changed its required OPC parts');
          Zip.Read('word/document.xml',Bytes); XML:=TEncoding.UTF8.GetString(Bytes);
          Zip.Read('word/styles.xml',Bytes); StylesXML:=TEncoding.UTF8.GetString(Bytes);
          for var Part in TArray<string>.Create('[Content_Types].xml','_rels/.rels','word/_rels/document.xml.rels') do
          begin Zip.Read(Part,Bytes); Document:=XMLDocument(TEncoding.UTF8.GetString(Bytes)); Document:=Unassigned; end;
        finally Zip.Free; Stream.Free; end;
        Document:=XMLDocument(XML); Styles:=XMLDocument(StylesXML);
        BodyText:=VarToStr(Document.text);
        Require((Occurrences(BodyText,Notes[0].Text)=1) and (Occurrences(BodyText,Notes[0].Quote)=1),
          'DOCX repeats note body or loses its quote');
        Require(VarToStr(Document.selectSingleNode('//w:p[w:pPr/w:pStyle[@w:val="Heading2"]]/w:r/w:t').text)='—',
          'DOCX blank title is not a dash');
        Require(VarToStr(Document.selectSingleNode('//w:p[w:pPr/w:pStyle[@w:val="Context"]]/w:r/w:t').text)=Notes[0].Created,
          'Empty note location invented a leading separator before the DOCX creation date');
        var Margin:=VarToStr(Document.selectSingleNode('//w:sectPr/w:pgMar/@w:left').text);
        Require(not Layouts.ContainsKey('margin:'+Margin),'DOCX styles differ only in colour/font instead of page layout');
        Layouts.Add('margin:'+Margin,True);
        Require((Integer(Document.selectNodes('//w:tbl').length)>0)=(Style=2),'Modern DOCX cards do not have a real boxed layout');
        Require((Integer(Document.selectNodes('//w:pgBorders').length)>0)=(Style=3),'Paper DOCX has no page frame, or other style has one');
        Require((Integer(Styles.selectNodes('//w:style[@w:styleId="Heading1"]/w:pPr/w:jc[@w:val="center"]').length)>0)=(Style=1),
          'Classical DOCX heading alignment is not distinct');
        Require(Integer(Styles.selectNodes('//w:style[@w:styleId="Normal"]/w:pPr/w:widowControl').length)=1,
          'DOCX allows a lone first or last body line on another page');
        Require(Integer(Styles.selectNodes('//w:style[@w:styleId="Context"]/w:pPr/w:keepNext').length)=1,
          'DOCX separates the note location from its quote or body');
        Require(Integer(Document.selectNodes('//w:p[w:pPr/w:pStyle[@w:val="Quote"]]/w:pPr/w:keepLines').length)=1,
          'DOCX permits a short quote to split across pages');
        Document:=Unassigned; Styles:=Unassigned;
        var QuoteProbe:=Notes[0]; QuoteProbe.Quote:=StringOfChar('Q',401);
        Bytes:=ReaderAnnotationsDocx(TArray<TReaderAnnotation>.Create(QuoteProbe),Style);
        Stream:=TMemoryStream.Create; Zip:=TZipFile.Create;
        try
          Stream.WriteBuffer(Bytes[0],Length(Bytes)); Stream.Position:=0; Zip.Open(Stream,zmRead);
          Zip.Read('word/document.xml',Bytes); Document:=XMLDocument(TEncoding.UTF8.GetString(Bytes));
          Require(Integer(Document.selectNodes('//w:p[w:pPr/w:pStyle[@w:val="Quote"]]/w:pPr/w:keepLines').length)=0,
            'DOCX forces long quotes into an indivisible page block');
          Require(Occurrences(VarToStr(Document.text),QuoteProbe.Quote)=1,'DOCX lost a long quote');
        finally Document:=Unassigned; Zip.Free; Stream.Free; end;
      end;
      Require(Occurrences(ReaderAnnotationsText(Notes,False),Notes[0].Text)=1,'Plain export duplicates the body as a title');
      Require(ReaderAnnotationsText(Notes,False).Contains(sLineBreak+Notes[0].Created+sLineBreak),
        'Empty note location invented a leading separator in plain text export');
      SetLength(Notes,20);
      for var I:=0 to High(Notes) do
      begin
        Note:=Default(TReaderAnnotation); Note.ID:='stress-'+IntToStr(I); Note.BookID:='export-pagination';
        Note.BookTitle:='Длинная книга № '+IntToStr(I+1)+' — Ёжик и українська література';
        if Odd(I) then Note.Title:='Название заметки '+IntToStr(I+1);
        Note.Place:='Глава '+IntToStr(I+1)+', страница '+IntToStr(I*7+1); Note.Created:='2026-10-14T12:00:00Z';
        Note.Text:='STRESS_BODY_'+IntToStr(I)+' ';
        for var Repetition:=1 to 8 do Note.Text:=Note.Text+
          'Ёжик, українська література, белорусское ў, café и улыбка 😀. ';
        Note.Quote:='STRESS_QUOTE_'+IntToStr(I)+' '+
          'Цитата с русским ё, українським і, белорусским ў, café и emoji 😀. '+
          'Продолжение цитаты должно переноситься внутри страницы и оставаться читаемым.';
        Notes[I]:=Note;
      end;
      for var Style:=0 to 3 do
      begin
        HTML:=ReaderAnnotationsText(Notes,True,Style);
        for var I:=0 to High(Notes) do
          Require((Occurrences(HTML,'STRESS_BODY_'+IntToStr(I)+' ')=1) and
            (Occurrences(HTML,'STRESS_QUOTE_'+IntToStr(I)+' ')=1), 'Long HTML export lost or duplicated a note');
        TFile.WriteAllText(TPath.Combine(Root,'notes-stress-style-'+IntToStr(Style)+'.html'),HTML,TEncoding.UTF8);
        Bytes:=ReaderAnnotationsDocx(Notes,Style);
        TFile.WriteAllBytes(TPath.Combine(Root,'notes-stress-style-'+IntToStr(Style)+'.docx'),Bytes);
        Stream:=TMemoryStream.Create; Zip:=TZipFile.Create;
        try
          Stream.WriteBuffer(Bytes[0],Length(Bytes)); Stream.Position:=0; Zip.Open(Stream,zmRead);
          Zip.Read('word/document.xml',Bytes); Document:=XMLDocument(TEncoding.UTF8.GetString(Bytes));
          BodyText:=VarToStr(Document.text);
          for var I:=0 to High(Notes) do
            Require((Occurrences(BodyText,'STRESS_BODY_'+IntToStr(I)+' ')=1) and
              (Occurrences(BodyText,'STRESS_QUOTE_'+IntToStr(I)+' ')=1), 'Long DOCX export lost or duplicated a note');
        finally Document:=Unassigned; Zip.Free; Stream.Free; end;
      end;
      Writeln('PASS blank annotation titles export as dash with body once; four well-formed HTML/DOCX layouts preserve quotes and Unicode');
    finally Layouts.Free; end;
  finally Store.Free; end;

  SetLength(Notes,1005);
  for var I:=0 to 999 do
  begin
    Note:=Default(TReaderAnnotation); Note.ID:='range-'+IntToStr(I); Note.BookID:='query-fixture';
    Note.RangeStart:=I*100; Note.RangeEnd:=Note.RangeStart+10; Note.Position:=Note.RangeStart; Notes[I]:=Note;
  end;
  Note:=Default(TReaderAnnotation); Note.ID:='long-overlap'; Note.BookID:='query-fixture';
  Note.RangeStart:=50; Note.RangeEnd:=30000; Note.Position:=0; Notes[1000]:=Note;
  Note:=Default(TReaderAnnotation); Note.ID:='legacy-point'; Note.BookID:='query-fixture'; Note.Position:=0; Notes[1001]:=Note;
  Note:=Default(TReaderAnnotation); Note.ID:='pdf-page-0'; Note.BookID:='query-fixture';
  Note.Position:=0; Note.RangeIsPageText:=True; Note.RangeStart:=7; Note.RangeEnd:=15; Notes[1002]:=Note;
  Note.ID:='pdf-page-1'; Note.Position:=1; Notes[1003]:=Note;
  Note:=Default(TReaderAnnotation); Note.ID:='max-point'; Note.BookID:='query-fixture'; Note.Position:=MaxInt; Notes[1004]:=Note;
  Index:=TReaderAnnotationIndex.Create(Notes);
  try
    MaxVisited:=0; TotalVisited:=0;
    for var I:=0 to 999 do
    begin
      var First:=I*100+2; var Last:=First+6;
      Hits:=Index.Query(First,Last); RequireIDs(Hits,First,Last,-1,False,True);
      MaxVisited:=Max(MaxVisited,Index.LastVisitedNodes); Inc(TotalVisited,Index.LastVisitedNodes);
    end;
    Require((MaxVisited<80) and (TotalVisited<80000),'1000 page queries scanned the entire notes array');
    RequireIDs(Index.Query(0,8),0,8,-1,False,True);
    RequireIDs(Index.HitTest(0),0,1,-1,False,False);
    RequireIDs(Index.Query(7,8,True,0),7,8,0,True,True);
    RequireIDs(Index.HitTest(7,True,0),7,8,0,True,False);
    RequireIDs(Index.Query(7,8,True,1),7,8,1,True,True);
    RequireIDs(Index.Query(15,16,True,0),15,16,0,True,True);
    Hits:=Index.QueryPage(0);
    Require((Length(Hits)=2) and (Hits[0].ID='legacy-point') and (Hits[1].ID='pdf-page-0'),
      'Exact page lookup lost a no-quote legacy marker or mixed global ranges/pages');
    Hits:=Index.QueryPage(MaxInt);
    Require((Length(Hits)=1) and (Hits[0].ID='max-point'),'Point indexing overflowed its integer boundary');
    Require((Length(Index.Query(-1,5))=0) and (Length(Index.Query(4,4))=0) and
      (Length(Index.HitTest(MaxInt))=0),'Invalid annotation queries overflow or produce phantom hits');
    Notes[0].RangeStart:=500000; Notes[0].Text:='Mutated caller snapshot';
    Hits:=Index.HitTest(2); Require((Length(Hits)=1) and (Hits[0].ID='range-0') and
      (Hits[0].RangeStart=0),'Annotation index holds the caller mutable array');
    Writeln('PASS 1000 indexed annotation page queries match independent overlapping/point/page oracle; max_nodes=',MaxVisited,
      ' total_nodes=',TotalVisited,' and no full scan per paint');
  finally Index.Free; end;

  for var InvalidRange in TArray<string>.Create(
    '"rangeStart":0', '"rangeEnd":10', '"rangeIsPageText":true',
    '"rangeStart":-1,"rangeEnd":10', '"rangeStart":10,"rangeEnd":9',
    '"rangeStart":0,"rangeEnd":2147483648', '"rangeStart":"0","rangeEnd":10',
    '"rangeStart":0,"rangeEnd":10,"rangeIsPageText":"true"') do
    CheckInvalidJSON('{"version":1,"notes":[{"id":"bad","book":"one","position":0,"text":"Safe",'+InvalidRange+'}]}');
  CheckInvalidJSON('{"version":2,"notes":[]}');
  Require(THashSHA2.GetHashStringFromFile(Profile)=BeforeProfile,'Range notes changed an existing reader profile');
  Writeln('PASS invalid, overflowing, partial and future annotation schema stays untouched; reader profile is unchanged');
  Writeln('ANNOTATION_EXPORT_FIXTURES ',Root);
end;
