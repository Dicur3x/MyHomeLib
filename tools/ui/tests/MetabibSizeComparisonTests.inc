// Actual native import comparison, never a hand-written SQLite size model.
// DPR uses: System.JSON, System.Generics.Collections, System.Hash,
// unit_CollectionWorkerThread, unit_ImportMetabibThread, unit_ImportInpxThread.
// The owning wrapper stages both pinned inputs in its guarded G runtime,
// runs this mode with a 90-second process timeout and retains the private DBs.

procedure TestMetabibSizeComparison(const JSONLFile, INPXFile: string);
const
  JSONLSHA = 'BE20FC484097FA765EB65862BB4355300BFDD10927B4175E24F7A5CDE3B789BA';
  INPXSHA = '10EDD3B8CF8F6FC27140177C65A3B16430E479AB80B33AA71039E812E65C021E';
  RecordCount = 2000;
type
  TExpectedBook = record
    LibID, Title, Lang, Folder, FileName, Extension, Keywords: string;
    AuthorLast, AuthorFirst, AuthorMiddle, Genre, SeriesTitle: string;
    Annotation, Publisher, City, ISBN, PublisherSeries: string;
    InsideNo, Size, SeriesNo, PubYear, PublisherSeriesNo: Integer;
  end;
var
  Expected: TDictionary<string,TExpectedBook>;
  Lines: TStringList;
  JSON: TJSONValue;
  Row, Rec, Locator, Claims, Bib, Pub, Artifact, Person, Sequence: TJSONObject;
  Entry: TExpectedBook;
  Root, Folder, JSONLPath, INPXPath: string;
  MetaID, InpxID: Integer;
  Started: UInt64;
  ExpectedAnnotationBytes: Int64;
  Report, MetaStats, InpxStats: TJSONObject;
  MetaBytes, InpxBytes, MetaLiveBytes, InpxLiveBytes: Int64;

  procedure CheckDeadline;
  begin
    Require(GetTickCount64 - Started < 90000, 'Actual Metabib/INPX comparison exceeded 90 seconds');
  end;

  function ObjectValue(Value: TJSONValue; const Where: string): TJSONObject;
  begin
    Require(Value is TJSONObject, 'Expected JSON object at ' + Where);
    Result := TJSONObject(Value);
  end;

  function OnlyItem(Value: TJSONValue; const Where: string): TJSONValue;
  begin
    Require((Value is TJSONArray) and (TJSONArray(Value).Count = 1),
      'Expected exactly one independent fixture item at ' + Where);
    Result := TJSONArray(Value).Items[0];
  end;

  function ClaimValue(Group: TJSONObject; const Field: string): TJSONValue;
  begin
    Result := ObjectValue(OnlyItem(Group.GetValue(Field), Field), Field).GetValue('value');
    Require(Assigned(Result), 'Missing independent fixture claim ' + Field);
  end;

  function ClaimText(Group: TJSONObject; const Field: string): string;
  var Value: TJSONValue;
  begin
    Value := ClaimValue(Group, Field);
    Require(Value is TJSONString, 'Expected literal fixture text at ' + Field);
    Result := Value.Value;
  end;

  procedure ImportActual(ID: Integer; const FileName: string; Metabib: Boolean);
  var Worker: TCollectionWorker;
  begin
    if Metabib then Worker := TImportMetabibThread.Create(ID, FileName, gtFb2)
    else Worker := TImportInpxThread.Create(ID, FileName, gtFb2);
    try
      Worker.Start;
      while not Worker.Finished do
      begin
        CheckSynchronize(20);
        if GetTickCount64 - Started >= 90000 then
        begin
          Worker.Cancel;
          // The owning wrapper enforces the hard process deadline. Join the
          // canceled production worker before releasing its thread resources.
          Worker.WaitFor;
          CheckDeadline;
        end;
      end;
      Worker.WaitFor;
      if Assigned(Worker.FatalException) then
        raise Exception.Create('Native size import: ' + Exception(Worker.FatalException).Message);
      Require(Worker.Success and Worker.CommittedChanges, 'Actual size import did not commit successfully');
      CheckDeadline;
    finally Worker.Free; end;
  end;

  function VerifyDatabase(ID: Integer; Metabib: Boolean): TJSONObject;
  var DB: TSQLiteDatabase; Books, Relation: TSQLiteQuery;
    Seen: TDictionary<string,Boolean>; Info: TCollectionInfo; Value: TExpectedBook;
    LibID, Path: string; Count: Integer; PageSize, Pages, FreePages, Bytes, Footprint: Int64;
    procedure UniqueExpected(const Key: string);
    begin
      Require(Expected.TryGetValue(Key, Value), 'Imported unexpected library identity ' + Key);
      Require(not Seen.ContainsKey(Key), 'Imported a duplicate logical record/relation for ' + Key);
      Seen.Add(Key, True);
    end;
    procedure RequireText(At: Integer; const Wanted, Name: string);
    begin
      Require(Books.FieldAsString(At) = Wanted, Name + ' differs from independent JSON oracle for ' + LibID);
    end;
  begin
    Info := SystemDB.GetCollectionInfo(ID);
    Require(TPath.GetFullPath(Info.DBFileName).StartsWith(Root, True),
      'Native size database is outside the guarded runtime');
    DB := TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
    Seen := TDictionary<string,Boolean>.Create;
    Result := nil;
    try
      try
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books') = RecordCount, 'Native import lost fixture records');
      Require(DB.QuerySingleInt('SELECT COUNT(DISTINCT LibID) FROM Books') = RecordCount, 'Native import collapsed fixture library IDs');
      Books := DB.NewQuery('SELECT LibID,Title,Lang,Folder,FileName,Ext,InsideNo,BookSize,' +
        'IsDeleted,LibRate,KeyWords,Annotation,SearchAnnotation,Publisher,City,PubYear,ISBN,Translators ' +
        'FROM Books ORDER BY LibID');
      try
        Books.Open;
        while not Books.Eof do
        begin
          CheckDeadline;
          LibID := Books.FieldAsString(0); UniqueExpected(LibID);
          RequireText(1, Value.Title, 'Title'); RequireText(2, Value.Lang, 'Language');
          RequireText(3, Value.Folder, 'Archive'); RequireText(4, Value.FileName, 'Archive member');
          RequireText(5, Value.Extension, 'Extension'); RequireText(10, Value.Keywords, 'Keywords');
          Require((Books.FieldAsInt(6) = Value.InsideNo) and (Books.FieldAsInt(7) = Value.Size) and
            (Books.FieldAsInt(8) = 0) and (Books.FieldAsInt(9) = 4), 'Native import changed locator/size/deletion/rating for ' + LibID);
          if Metabib then
          begin
            RequireText(11, Value.Annotation, 'Annotation');
            RequireText(12, AnsiUpperCase(Value.Annotation), 'SearchAnnotation');
            RequireText(13, Value.Publisher, 'Publisher'); RequireText(14, Value.City, 'City');
            Require(Books.FieldAsInt(15) = Value.PubYear, 'Publication year was lost');
            RequireText(16, Value.ISBN, 'ISBN');
          end
          else
          begin
            for var At in TArray<Integer>.Create(11,12,13,14,16) do
              RequireText(At, '', 'Field absent from INPX');
            Require(Books.FieldAsInt(15) = 0, 'INPX invented a publication year');
          end;
          RequireText(17, '', 'Absent translators');
          Books.Next;
        end;
        Require(Seen.Count = Expected.Count, 'Native result is incomplete compared with parsed JSON records');
      finally Books.Free; end;

      CheckDeadline; Seen.Clear; Count := 0;
      Relation := DB.NewQuery('SELECT b.LibID,a.LastName,a.FirstName,a.MiddleName ' +
        'FROM Author_List al JOIN Books b ON b.BookID=al.BookID JOIN Authors a ON a.AuthorID=al.AuthorID');
      try
        Relation.Open;
        while not Relation.Eof do
        begin
          UniqueExpected(Relation.FieldAsString(0)); Inc(Count);
          Require((Relation.FieldAsString(1) = Value.AuthorLast) and
            (Relation.FieldAsString(2) = Value.AuthorFirst) and (Relation.FieldAsString(3) = Value.AuthorMiddle),
            'Native author relation differs from JSON oracle');
          Relation.Next;
        end;
        Require(Count = RecordCount, 'Native import lost or multiplied authors per logical book');
      finally Relation.Free; end;
      CheckDeadline; Seen.Clear; Count := 0;
      Relation := DB.NewQuery('SELECT b.LibID,g.FB2Code FROM Genre_List gl ' +
        'JOIN Books b ON b.BookID=gl.BookID JOIN Genres g ON g.GenreCode=gl.GenreCode');
      try
        Relation.Open;
        while not Relation.Eof do
        begin
          UniqueExpected(Relation.FieldAsString(0)); Inc(Count);
          Require(Relation.FieldAsString(1) = Value.Genre, 'Native genre relation differs from JSON oracle');
          Relation.Next;
        end;
        Require(Count = RecordCount, 'Native import lost or multiplied genre links');
      finally Relation.Free; end;
      CheckDeadline; Seen.Clear; Count := 0;
      Relation := DB.NewQuery('SELECT b.LibID,s.SeriesTitle,sl.SeqNumber,sl.IsPrimary FROM Series_List sl ' +
        'JOIN Books b ON b.BookID=sl.BookID JOIN Series s ON s.SeriesID=sl.SeriesID');
      try
        Relation.Open;
        while not Relation.Eof do
        begin
          UniqueExpected(Relation.FieldAsString(0)); Inc(Count);
          Require((Relation.FieldAsString(1) = Value.SeriesTitle) and (Relation.FieldAsInt(2) = Value.SeriesNo) and
            (Relation.FieldAsInt(3) = 1), 'Native primary series/number differs from JSON oracle');
          Relation.Next;
        end;
        Require(Count = RecordCount, 'Native import lost or multiplied primary cycle links');
      finally Relation.Free; end;
      CheckDeadline; Seen.Clear; Count := 0;
      Relation := DB.NewQuery('SELECT b.LibID,s.SeriesTitle,sl.SeqNumber FROM PublisherSeries_List sl ' +
        'JOIN Books b ON b.BookID=sl.BookID JOIN PublisherSeries s ON s.SeriesID=sl.SeriesID');
      try
        Relation.Open;
        while not Relation.Eof do
        begin
          UniqueExpected(Relation.FieldAsString(0)); Inc(Count);
          Require(Metabib and (Relation.FieldAsString(1) = Value.PublisherSeries) and
            (Relation.FieldAsInt(2) = Value.PublisherSeriesNo), 'Native publisher series differs from JSON oracle');
          Relation.Next;
        end;
        Require(Count = Ord(Metabib) * RecordCount, 'Publication series missing or invented by INPX');
      finally Relation.Free; end;
      CheckDeadline;
      Require(DB.QuerySingleString('PRAGMA quick_check') = 'ok', 'Native size fixture failed SQLite integrity');
      PageSize := DB.QuerySingleInt('PRAGMA page_size'); Pages := DB.QuerySingleInt('PRAGMA page_count');
      FreePages := DB.QuerySingleInt('PRAGMA freelist_count');
      Bytes := TFile.GetSize(Info.DBFileName); Footprint := Bytes;
      for var Suffix in TArray<string>.Create('-wal','-shm','-journal') do
      begin
        Path := Info.DBFileName + Suffix;
        if FileExists(Path) then Inc(Footprint, TFile.GetSize(Path));
      end;
      Require((PageSize > 0) and (Pages > 0) and (FreePages >= 0) and (FreePages < Pages) and
        (Bytes = PageSize * Pages), 'SQLite page footprint is inconsistent');
      Result := TJSONObject.Create;
      Result.AddPair('dbfile', Info.DBFileName);
      Result.AddPair('records', TJSONNumber.Create(RecordCount));
      Result.AddPair('page_size', TJSONNumber.Create(PageSize)); Result.AddPair('page_count', TJSONNumber.Create(Pages));
      Result.AddPair('freelist_count', TJSONNumber.Create(FreePages));
      Result.AddPair('file_bytes', TJSONNumber.Create(Bytes)); Result.AddPair('footprint_bytes', TJSONNumber.Create(Footprint));
      Result.AddPair('live_page_bytes', TJSONNumber.Create(PageSize * (Pages - FreePages)));
      var AnnotationBytes := DB.QuerySingleInt('SELECT COALESCE(SUM(length(CAST(COALESCE(Annotation,'''') AS BLOB))),0) FROM Books');
      var SearchBytes := DB.QuerySingleInt('SELECT COALESCE(SUM(length(CAST(COALESCE(SearchAnnotation,'''') AS BLOB))),0) FROM Books');
      Require(AnnotationBytes = Ord(Metabib) * ExpectedAnnotationBytes, 'Annotation bytes differ from independent JSON literal sum');
      Require(SearchBytes = AnnotationBytes, 'Normalized fixture annotation byte count differs from expected payload');
      Result.AddPair('annotation_bytes', TJSONNumber.Create(AnnotationBytes));
      Result.AddPair('search_annotation_bytes', TJSONNumber.Create(SearchBytes));
      Result.AddPair('author_links', TJSONNumber.Create(DB.QuerySingleInt('SELECT COUNT(*) FROM Author_List')));
      Result.AddPair('genre_links', TJSONNumber.Create(DB.QuerySingleInt('SELECT COUNT(*) FROM Genre_List')));
      Result.AddPair('series_links', TJSONNumber.Create(DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List')));
      Result.AddPair('publisher_series_links', TJSONNumber.Create(DB.QuerySingleInt('SELECT COUNT(*) FROM PublisherSeries_List')));
      except
        Result.Free; Result := nil; raise;
      end;
    finally
      Seen.Free; DB.Free;
    end;
  end;

begin
  RequireIsolatedRegression;
  Started := GetTickCount64; MetaID := 0; InpxID := 0;
  Root := IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath));
  Require(Root.StartsWith('G:\', True), 'Size comparison must remain in its private G runtime');
  JSONLPath := TPath.GetFullPath(JSONLFile); INPXPath := TPath.GetFullPath(INPXFile);
  Require(JSONLPath.StartsWith(Root, True) and INPXPath.StartsWith(Root, True), 'Stage size comparison sources in guarded runtime');
  Require(SameText(THashSHA2.GetHashStringFromFile(JSONLPath), JSONLSHA) and
    SameText(THashSHA2.GetHashStringFromFile(INPXPath), INPXSHA), 'Size comparison source hashes do not match independent fixture provenance');
  Expected := TDictionary<string,TExpectedBook>.Create; Lines := TStringList.Create;
  Report := nil; MetaStats := nil; InpxStats := nil;
  try
    Lines.LoadFromFile(JSONLPath, TEncoding.UTF8);
    Require(Lines.Count = RecordCount + 1, 'Independent JSONL must contain a header and 2000 records');
    JSON := TJSONObject.ParseJSONValue(Lines[0]);
    try
      Row := ObjectValue(JSON, 'header');
      Require((Row.GetValue<string>('schema') = 'metabib.dataset/1') and
        (Row.GetValue<string>('library') = 'librusec') and (Row.GetValue<Integer>('records') = RecordCount),
        'Independent Metabib dataset header differs');
      Artifact := ObjectValue(OnlyItem(Row.GetValue('archives'), 'archives'), 'archive');
      Require((Artifact.GetValue<string>('id') = 'arc') and (Artifact.GetValue<string>('name') = 'books.zip'),
        'Independent archive mapping differs');
    finally JSON.Free; end;
    ExpectedAnnotationBytes := 0;
    for var Line := 1 to Lines.Count - 1 do
    begin
      CheckDeadline; Entry := Default(TExpectedBook);
      JSON := TJSONObject.ParseJSONValue(Lines[Line]);
      try
        Row := ObjectValue(JSON, 'record');
        Require(Row.GetValue<string>('schema') = 'metabib.dataset_record/1', 'Independent record schema differs');
        Rec := ObjectValue(Row.GetValue('record'), 'record identity');
        Require(Rec.GetValue<string>('library') = 'librusec', 'Independent record changed source library');
        Locator := ObjectValue(Rec.GetValue('locator'), 'locator');
        Entry.LibID := Locator.GetValue('book_id').Value;
        Artifact := ObjectValue(OnlyItem(Row.GetValue('artifacts'), 'artifacts'), 'artifact');
        Artifact := ObjectValue(OnlyItem(Artifact.GetValue('occurrences'), 'occurrences'), 'occurrence');
        Require(Artifact.GetValue<string>('archive') = 'arc', 'Independent occurrence references another archive');
        Entry.Folder := 'books.zip'; Entry.FileName := ChangeFileExt(Artifact.GetValue<string>('entry'), '');
        Entry.Extension := ExtractFileExt(Artifact.GetValue<string>('entry'));
        Entry.InsideNo := Artifact.GetValue<Integer>('index'); Entry.Size := Artifact.GetValue<Integer>('uncompressed_size');
        Claims := ObjectValue(Row.GetValue('claims'), 'claims'); Bib := ObjectValue(Claims.GetValue('bibliographic'), 'bibliographic');
        Pub := ObjectValue(Claims.GetValue('publication'), 'publication');
        Entry.Title := ClaimText(Bib, 'title'); Entry.Lang := ClaimText(Bib, 'language'); Entry.Keywords := ClaimText(Bib, 'keywords');
        Entry.Annotation := ClaimText(Bib, 'annotation'); Entry.Publisher := ClaimText(Pub, 'publisher');
        Entry.City := ClaimText(Pub, 'city'); Entry.ISBN := ClaimText(Pub, 'isbn');
        Require(TryStrToInt(ClaimValue(Pub, 'year').Value, Entry.PubYear), 'Independent publication year is not an integer');
        Person := ObjectValue(OnlyItem(ClaimValue(Bib, 'authors'), 'authors'), 'person');
        Entry.AuthorLast := Person.GetValue<string>('last_name'); Entry.AuthorFirst := Person.GetValue<string>('first_name');
        Entry.AuthorMiddle := Person.GetValue<string>('middle_name');
        Person := ObjectValue(OnlyItem(ClaimValue(Bib, 'genres'), 'genres'), 'genre'); Entry.Genre := Person.GetValue<string>('code');
        Sequence := ObjectValue(OnlyItem(ClaimValue(Bib, 'sequences'), 'sequences'), 'sequence');
        Entry.SeriesTitle := Sequence.GetValue<string>('name'); Entry.SeriesNo := ObjectValue(Sequence.GetValue('number'), 'sequence number').GetValue<Integer>('value');
        Sequence := ObjectValue(OnlyItem(ClaimValue(Pub, 'sequences'), 'publication sequences'), 'publication sequence');
        Entry.PublisherSeries := Sequence.GetValue<string>('name');
        Entry.PublisherSeriesNo := ObjectValue(Sequence.GetValue('number'), 'publication sequence number').GetValue<Integer>('value');
        Require((Entry.LibID = IntToStr(10000 + Line)) and (Entry.Title <> '') and (Entry.Annotation <> '') and
          not Expected.ContainsKey(Entry.LibID), 'Independent oracle contains missing/duplicate identities or empty metadata');
        Inc(ExpectedAnnotationBytes, Length(TEncoding.UTF8.GetBytes(Entry.Annotation))); Expected.Add(Entry.LibID, Entry);
      finally JSON.Free; end;
    end;
    Require(Expected.Count = RecordCount, 'Independent JSON oracle is empty or incomplete');
    Folder := TPath.Combine(Root, 'metabib-size-books'); ForceDirectories(Folder);
    MetaID := SystemDB.CreateCollection('Native Metabib size', Folder, 'native-metabib-size.hlc2',
      CT_EXTERNAL_LOCAL_FB, Root + 'genres_fb2.glst');
    InpxID := SystemDB.CreateCollection('Native INPX size', Folder, 'native-inpx-size.hlc2',
      CT_EXTERNAL_LOCAL_FB, Root + 'genres_fb2.glst');
    ImportActual(MetaID, JSONLPath, True); ImportActual(InpxID, INPXPath, False);
    MetaStats := VerifyDatabase(MetaID, True); InpxStats := VerifyDatabase(InpxID, False);
    MetaBytes := MetaStats.GetValue<Int64>('file_bytes'); InpxBytes := InpxStats.GetValue<Int64>('file_bytes');
    MetaLiveBytes := MetaStats.GetValue<Int64>('live_page_bytes'); InpxLiveBytes := InpxStats.GetValue<Int64>('live_page_bytes');
    Report := TJSONObject.Create;
    Report.AddPair('kind', 'actual-native-import'); Report.AddPair('jsonl_sha256', JSONLSHA); Report.AddPair('inpx_sha256', INPXSHA);
    Report.AddPair('expected_records', TJSONNumber.Create(Expected.Count));
    Report.AddPair('oracle_annotation_bytes', TJSONNumber.Create(ExpectedAnnotationBytes));
    Report.AddPair('metabib', MetaStats); MetaStats := nil; Report.AddPair('inpx', InpxStats); InpxStats := nil;
    Report.AddPair('file_size_ratio', TJSONNumber.Create(MetaBytes / InpxBytes));
    Report.AddPair('live_page_ratio', TJSONNumber.Create(MetaLiveBytes / InpxLiveBytes));
    Report.AddPair('elapsed_ms', TJSONNumber.Create(Int64(GetTickCount64 - Started)));
    Require(SameText(THashSHA2.GetHashStringFromFile(JSONLPath), JSONLSHA) and
      SameText(THashSHA2.GetHashStringFromFile(INPXPath), INPXSHA), 'Native import modified source catalog bytes');
    Writeln('PASS actual native Metabib and INPX import preserve the same 2000 logical identities, titles, authors, genres, primary cycles and locators against independent JSON');
    Writeln('PASS Metabib retains annotation, publication metadata and publisher series absent from INPX; measured SQLite footprints do not impose a fixed size ratio');
    Writeln('METABIB_SIZE_COMPARISON ' + Report.ToJSON);
    TFile.WriteAllText(TPath.Combine(Root, 'metabib-size-comparison.json'), Report.ToJSON, TEncoding.UTF8);
    CheckDeadline;
  finally
    Report.Free; MetaStats.Free; InpxStats.Free; Lines.Free; Expected.Free;
  end;
end;
