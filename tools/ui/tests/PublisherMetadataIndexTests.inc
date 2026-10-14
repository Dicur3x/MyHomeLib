// FB2 publisher enrichment through the production parser, worker and SQLite DAO.
// Include after AddBook. Requires unit_FB2PublisherMetadataReader and
// unit_PublisherSeriesSource in the DPR uses. Disposable guarded runtime only.

procedure TestPublisherMetadataIndex;
const
  NamespaceURI = 'http://www.gribuser.ru/xml/fictionbook/2.0';
var
  Reader: TFB2PublisherMetadataReader;
  Collection, Reopened: IBookCollection;
  Info: TCollectionInfo;
  ID, I, ReplacementID: Integer;
  IDs: array[0..4] of Integer;
  Files, Hashes: array[0..4] of string;
  Folder, BeforeData, OldKey, NewKey, ErrorText, GuardState: string;
  Book, SourceSnapshot: TBookRecord;
  Series, BeforeSeries: TBookSeries;
  Parsed: TFB2PublisherSeries;
  Writer: TSQLiteDatabase;
  Source: TPublisherSeriesSource;
  LockedSources: TArray<TFileStream>;
  Failed: Boolean;
  TraceCount, RunNumber: Integer;

  procedure TracePublisher(const Phase: string);
  begin
    // Bounded diagnostics in this five-book private fixture only.
    if TraceCount >= 256 then Exit;
    Inc(TraceCount); Writeln('TRACE publisher metadata ', Phase); Flush(Output);
  end;

  function Metadata(const PublishInfo: string): string;
  begin
    Result := '<?xml version="1.0" encoding="utf-8"?>' +
      '<FictionBook xmlns="' + NamespaceURI + '"><description>' +
      '<title-info><book-title>Source title must not replace catalog</book-title>' +
      '<sequence name="Unrelated author cycle" number="99"/></title-info>' +
      '<publish-info>' + PublishInfo + '</publish-info></description>' +
      '<body><section><p>Source text</p></section></body></FictionBook>';
  end;

  procedure Parse(const XML, ExpectedPublisher: string;
    ExpectedStatus: TFB2MetadataStatus; ExpectedSeries: Integer = 0);
  var Input: TStringStream; Status: TFB2MetadataStatus; OriginalHash: string;
  begin
    Input := TStringStream.Create(XML, TEncoding.UTF8);
    try
      OriginalHash := THashSHA2.GetHashString(XML);
      Status := Reader.Read(Input, Parsed, ErrorText);
      Require(Status = ExpectedStatus,
        'FB2 publisher status ' + IntToStr(Ord(Status)) + ': ' + ErrorText);
      Require(Reader.LastPublisher = ExpectedPublisher,
        'FB2 publisher captured a wrong namespace, stale or partial value');
      Require(Length(Parsed) = ExpectedSeries, 'Publisher parsing changed series output');
      Require(THashSHA2.GetHashString(Input.DataString) = OriginalHash,
        'Publisher parser changed its borrowed input');
    finally Input.Free; end;
  end;

  function DataSnapshot: string;
  var DB: TSQLiteDatabase; Columns: TSQLiteQuery; SQL, Name: string;
    procedure AppendRows(const Query: string);
    var Values: TSQLiteQuery; Value: string;
    begin
      Values := DB.NewQuery(Query);
      try
        Values.Open;
        while not Values.Eof do
        begin
          for var Column := 0 to Values.ColCount - 1 do
          begin
            Value := Values.FieldAsString(Column);
            Result := Result + IntToStr(Length(Value)) + ':' + Value;
          end;
          Result := Result + #10;
          Values.Next;
        end;
      finally Values.Free; end;
    end;
  begin
    TracePublisher('snapshot begin');
    Result := '';
    DB := TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
    TracePublisher('snapshot read-only connection ready');
    try
      SQL := '';
      Columns := DB.NewQuery('PRAGMA table_info(Books)');
      try
        Columns.Open;
        while not Columns.Eof do
        begin
          Name := Columns.FieldAsString(1);
          if not SameText(Name, 'Publisher') then
          begin
            if SQL <> '' then SQL := SQL + ',';
            SQL := SQL + 'quote("' + Name + '")';
          end;
          Columns.Next;
        end;
      finally Columns.Free; end;
      TracePublisher('snapshot columns ready');
      AppendRows('SELECT ' + SQL + ' FROM Books ORDER BY BookID');
      TracePublisher('snapshot Books ready');
      AppendRows('SELECT * FROM Author_List ORDER BY BookID,AuthorID');
      TracePublisher('snapshot Author_List ready');
      AppendRows('SELECT * FROM Genre_List ORDER BY BookID,GenreCode');
      TracePublisher('snapshot Genre_List ready');
      AppendRows('SELECT * FROM Series_List ORDER BY BookID,SeriesID');
      TracePublisher('snapshot Series_List ready');
    finally
      TracePublisher('snapshot connection free begin'); DB.Free;
      TracePublisher('snapshot connection free end');
    end;
    TracePublisher('snapshot end');
  end;

  procedure ConfigureWriter(const DB: TSQLiteDatabase);
  begin
    // Direct fixture connections must honor the same active trigger contract
    // as a normal DAO writer; the production triggers remain installed.
    DB.AddFunction('MHL_TRIGGERS_ON', 0, EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON', 0, EnableScaleFixtureTriggers);
    Require((DB.QuerySingleInt('SELECT MHL_TRIGGERS_ON()') = 1) and
      (DB.QuerySingleInt('SELECT MHL_SERIES_TRIGGERS_ON()') = 1),
      'Publisher fixture writer did not enable the production trigger contracts');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''trigger'' AND name=''TRBooks_AU''') = 1,
      'Publisher fixture removed its production Books update trigger');
  end;

  procedure RunIndexer(Indexed, Errors, Cached: Integer;
    Force: Boolean = False; CancelBeforeStart: Boolean = False);
  var Worker: TIndexPublisherSeriesThread; LogPath: string;
  begin
    Inc(RunNumber);
    TracePublisher(Format('worker %d create begin expected=%d/%d/%d force=%s canceled=%s',
      [RunNumber, Indexed, Errors, Cached, BoolToStr(Force, True), BoolToStr(CancelBeforeStart, True)]));
    Worker := TIndexPublisherSeriesThread.Create(ID, Force);
    TracePublisher('worker created');
    LogPath := Worker.ErrorLogFileName;
    try
      if CancelBeforeStart then Worker.Cancel;
      TracePublisher('worker Start begin'); Worker.Start;
      TracePublisher('worker Start returned; CheckSynchronize wait begin');
      // RTL skips Execute when Terminate preceded Start, so TWorker's own
      // Finished flag is never published in this deliberate pre-start case.
      // Join the actual native thread; keep all zero-change/counter oracles.
      if not CancelBeforeStart then
        while not Worker.Finished do CheckSynchronize(20);
      TracePublisher('worker join WaitFor begin'); Worker.WaitFor;
      TracePublisher('worker WaitFor returned');
      if Assigned(Worker.FatalException) then
      begin
        TracePublisher('worker FatalException: ' + Copy(Exception(Worker.FatalException).Message, 1, 240));
        raise Exception.Create('Publisher enrichment worker: ' +
          Exception(Worker.FatalException).Message);
      end;
      TracePublisher(Format('worker counters=%d/%d/%d committed=%s success=%s',
        [Worker.IndexedCount, Worker.FailedCount, Worker.CachedCount,
         BoolToStr(Worker.CommittedChanges, True), BoolToStr(Worker.Success, True)]));
      Require((Worker.IndexedCount = Indexed) and (Worker.FailedCount = Errors) and
        (Worker.CachedCount = Cached), Format(
        'Publisher enrichment counters: indexed=%d errors=%d cached=%d, expected %d/%d/%d',
        [Worker.IndexedCount, Worker.FailedCount, Worker.CachedCount, Indexed, Errors, Cached]));
      Require(Worker.CommittedChanges = (Indexed > 0), 'Publisher worker did not report its durable commit state');
      Require(Worker.Success = not CancelBeforeStart, 'Publisher worker completion state differs from its actual cancellation');
      TracePublisher('worker counter oracles passed');
    finally
      TracePublisher('worker free begin'); Worker.Free;
      TracePublisher('worker free returned');
      if FileExists(LogPath) then TFile.Delete(LogPath);
      TracePublisher('worker temporary log cleanup returned');
    end;
  end;

  procedure ExpectPublisher(Index: Integer; const Expected: string);
  begin
    Collection.GetBookRecord(CreateBookKey(IDs[Index], ID), Book, True);
    Require(Book.Publisher = Expected, 'Publisher enrichment erased or misassigned catalog metadata');
  end;

  procedure ExpectSearch(const InCollection: IBookCollection;
    const Publisher, Title: string);
  var Criteria: TBookSearchCriteria; Iterator: IBookIterator; Value: TBookRecord;
  begin
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := -1;
    Criteria.CollapseMultiSeriesResults := True;
    Criteria.Publisher := '="' + Publisher + '"';
    Iterator := InCollection.Search(Criteria, False);
    Require((Iterator.RecordCount = 1) and Iterator.Next(Value) and
      (Value.Title = Title), 'Indexed publisher is missing from real catalog search');
    Require(not Iterator.Next(Value), 'Publisher search returned another book');
  end;

  function IndexKey(BookID: Integer): string;
  var DB: TSQLiteDatabase;
  begin
    DB := TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
    try
      Result := DB.QuerySingleString(
        'SELECT SourceKey FROM PublisherSeries_Index WHERE BookID=?', [BookID]);
    finally DB.Free; end;
  end;

  function GuardSnapshot(BookID: Integer): string;
  var DB: TSQLiteDatabase; Rows: TSQLiteQuery; Value: string;
    procedure Append(const SQL: string);
    begin
      Rows := DB.NewQuery(SQL, [BookID]);
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          for var Column := 0 to Rows.ColCount - 1 do
          begin
            Value := Rows.FieldAsString(Column);
            Result := Result + IntToStr(Length(Value)) + ':' + Value;
          end;
          Result := Result + #10; Rows.Next;
        end;
      finally Rows.Free; end;
    end;
  begin
    Result := DataSnapshot;
    DB := TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
    try
      Append('SELECT quote(Publisher) FROM Books WHERE BookID=?');
      Append('SELECT s.SeriesTitle,sl.SeqNumber,sl.OrdNum FROM PublisherSeries_List sl ' +
        'JOIN PublisherSeries s ON s.SeriesID=sl.SeriesID WHERE sl.BookID=? ORDER BY sl.OrdNum,s.SeriesTitle');
      Append('SELECT SourceKey FROM PublisherSeries_Index WHERE BookID=?');
    finally DB.Free; end;
  end;

  procedure ExpectStaleRejection(const Snapshot: TBookRecord; const LabelText: string);
  begin
    TracePublisher('stale guard begin: ' + LabelText);
    GuardState := GuardSnapshot(Snapshot.BookKey.BookID);
    Failed := False;
    try
      Collection.CompletePublisherSeriesIndex(Snapshot.BookKey, Series,
        OldKey, 'Must not leak from source A', @Snapshot);
    except
      on E: Exception do
      begin
        Failed := E.Message.Contains('изменились во время чтения FB2');
        if not Failed then raise;
      end;
    end;
    Require(Failed and (GuardSnapshot(Snapshot.BookKey.BookID) = GuardState),
      'Stale publisher identity changed replacement metadata, personal state, series or claim: ' + LabelText);
    TracePublisher('stale guard passed: ' + LabelText);
  end;

  function LegacyKey(const Value: TBookRecord): string;
  var Data: TWin32FileAttributeData; Parts: TJSONArray; Path, Stamp: string;
  begin
    Path := ExpandFileName(Value.GetBookFileName);
    Require(GetFileAttributesEx(PChar(Path), GetFileExInfoStandard, @Data),
      'Publisher source stamp fixture is unavailable');
    Stamp := IntToHex(Data.nFileSizeHigh, 8) + IntToHex(Data.nFileSizeLow, 8) +
      IntToHex(Data.ftLastWriteTime.dwHighDateTime, 8) +
      IntToHex(Data.ftLastWriteTime.dwLowDateTime, 8);
    Parts := TJSONArray.Create;
    try
      Parts.Add('publisher-metadata-v2');
      Parts.Add(LowerCase(Path)); Parts.Add(Stamp);
      Parts.Add(Ord(Value.GetBookFormat));
      Parts.Add(Value.FileName + Value.FileExt);
      Parts.Add(Value.InsideNo); Parts.Add(Value.LibID);
      Result := THashSHA2.GetHashString(Parts.ToJSON);
    finally Parts.Free; end;
  end;

begin
  TraceCount := 0; RunNumber := 0;
  RequireIsolatedRegression; TracePublisher('parser begin');
  Reader := TFB2PublisherMetadataReader.Create;
  try
    Parse(Metadata('<publisher>  Ёжик &amp; <![CDATA[Élan]]>  </publisher>' +
      '<sequence name="Издательская серия" number="23"/>'),
      'Ёжик & Élan', fmsComplete, 1);
    Parse(StringReplace(Metadata('<publisher>Correct</publisher>'),
      '<title-info>', '<title-info><publisher>Wrong title-info</publisher>', []),
      'Correct', fmsComplete);
    Parse(Metadata('<x:publisher xmlns:x="urn:foreign">Wrong namespace</x:publisher>' +
      '<wrapper><publisher>Wrong depth</publisher></wrapper>'), '', fmsComplete);
    Parse(StringReplace(Metadata('<publisher>Unqualified</publisher>'),
      '<publisher>', '<publisher xmlns="">', []), 'Unqualified', fmsComplete);
    Parse(Metadata('<publisher>' + StringOfChar('x', 4096) + '</publisher>'),
      StringOfChar('x', 4096), fmsComplete);
    Parse(Metadata('<publisher>' + StringOfChar('x', 4097) + '</publisher>'),
      '', fmsInvalid);
    Parse(Metadata('<publisher>Bad<emphasis>nested</emphasis></publisher>'),
      '', fmsInvalid);
    Parse(Metadata('<publisher>First</publisher><publisher>Second</publisher>'),
      '', fmsInvalid);
    Parse(Metadata('<publisher>Same</publisher><publisher>Same</publisher>'),
      'Same', fmsComplete);
    Parse(Metadata('<publisher/>'), '', fmsComplete);
    Parse('<FictionBook><body/></FictionBook>', '', fmsNoMetadata);
    Require(Reader.Read(nil, Parsed, ErrorText) = fmsInvalid, 'Missing publisher input accepted');
    Require(Reader.LastPublisher = '', 'Missing input retained publisher from previous book');
    var Input := TStringStream.Create(Metadata('<publisher>Canceled</publisher>'), TEncoding.UTF8);
    try
      Require(Reader.Read(Input, Parsed, ErrorText,
        function: Boolean begin Result := True; end) = fmsCanceled,
        'Publisher cancellation was ignored');
      Require(Reader.LastPublisher = '', 'Canceled read exposed incomplete publisher');
    finally Input.Free; end;
  finally Reader.Free; end;
  Writeln('PASS FB2 publisher parser uses bounded complete publish-info text, namespaces, depth and resets after invalid/canceled input');

  Flush(Output); TracePublisher('parser finished; collection setup begin');
  Folder := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath, 'publisher-enrichment-fixture'));
  ForceDirectories(Folder);
  ID := SystemDB.CreateCollection('FB2 publisher enrichment', Folder,
    'publisher-enrichment.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  TracePublisher('private collection created');
  Collection := SystemDB.GetCollection(ID);
  Info := SystemDB.GetCollectionInfo(ID);
  TracePublisher('private collection opened');
  try
    for I := 0 to High(IDs) do
    begin
      TracePublisher('fixture book setup begin ' + IntToStr(I));
      IDs[I] := AddBook(Collection, 'Publisher source ' + IntToStr(I),
        'Preserved author', 'ru', 'Preserved author cycle', 'prose_contemporary');
      Collection.GetBookRecord(CreateBookKey(IDs[I], ID), Book, True);
      if I in [1,2,3,4] then Book.Publisher := 'Known publisher ' + IntToStr(I);
      Book.Annotation := 'Preserved annotation ё'; Book.ISBN := '978-fixture-' + IntToStr(I);
      Book.Translators := 'Preserved translator'; Book.City := 'Preserved city'; Book.PubYear := 2001;
      Collection.UpdateBook(Book);
      Collection.AddBookSeries(IDs[I], 'Preserved secondary cycle', 7);
      Collection.SetRate(Book.BookKey, 5); Collection.SetProgress(Book.BookKey, 63);
      Collection.SetReview(Book.BookKey, 'Личная заметка ё 😀');
      Files[I] := Book.GetBookFileName;
      TracePublisher('fixture book setup end ' + IntToStr(I));
    end;
    TracePublisher('raw FB2 file setup begin');
    TFile.WriteAllText(Files[0], Metadata('<publisher>Ёжик &amp; Élan</publisher>' +
      '<sequence name="Indexed publisher series" number="23"/>'), TEncoding.UTF8);
    TFile.WriteAllText(Files[1], Metadata('<sequence name="Publisher absent series" number="7"/>'), TEncoding.UTF8);
    TFile.WriteAllText(Files[2], Metadata('<publisher>' + StringOfChar('x', 4097) + '</publisher>' +
      '<sequence name="Must not leak" number="8"/>'), TEncoding.UTF8);
    TFile.WriteAllText(Files[3], Metadata('<publisher xmlns="urn:foreign">Must not leak</publisher>'), TEncoding.UTF8);
    TFile.WriteAllText(Files[4], Metadata('<publisher>Publisher-only Press</publisher>'), TEncoding.UTF8);
    for I := 0 to High(Files) do Hashes[I] := THashSHA2.GetHashStringFromFile(Files[I]);
    TracePublisher('five raw FB2 files hashed; legacy v2 setup begin');
    TSeriesHelper.Add(Series, 0, 'Old publisher series', 11, False);
    Collection.SetBookPublisherSeries(CreateBookKey(IDs[2], ID), Series);
    Collection.GetBookRecord(CreateBookKey(IDs[0], ID), Book, True);
    OldKey := LegacyKey(Book);
    Collection.CompletePublisherSeriesIndex(Book.BookKey, nil, OldKey);
    Source := TPublisherSeriesSource.Create(nil);
    try NewKey := Source.GetSourceKey(Book); finally Source.Free; end;
    Require((OldKey <> NewKey) and (IndexKey(IDs[0]) = OldKey),
      'Legacy v2 fixture was not stored unchanged before an explicit indexing pass');
    TracePublisher('legacy v2 marker ready; baseline snapshot begin');
    BeforeData := DataSnapshot;
    TracePublisher('baseline snapshot ready; first worker begin');
    RunIndexer(4, 1, 0);
    TracePublisher('first worker returned; enrichment/search oracles begin');
    Require(IndexKey(IDs[0]) = NewKey, 'Explicit index did not replace a legacy v2 source key with v3');
    ExpectPublisher(0, 'Ёжик & Élan'); ExpectPublisher(1, 'Known publisher 1');
    ExpectPublisher(2, 'Known publisher 2'); ExpectPublisher(3, 'Known publisher 3');
    ExpectPublisher(4, 'Known publisher 4');
    Series := Collection.GetBookPublisherSeries(CreateBookKey(IDs[0], ID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Indexed publisher series') and
      (Series[0].SeqNumber = 23), 'Publisher and series did not come from the same complete source');
    Series := Collection.GetBookPublisherSeries(CreateBookKey(IDs[2], ID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Old publisher series') and
      (IndexKey(IDs[2]) = ''), 'Invalid publisher replaced previous series or certified its source');
    Require(DataSnapshot = BeforeData, 'Publisher enrichment changed unrelated metadata or personal state');
    ExpectSearch(Collection, 'Ёжик & Élan', 'Publisher source 0');
    ExpectSearch(Collection, 'Known publisher 4', 'Publisher source 4');
    for I := 0 to High(Files) do Require(THashSHA2.GetHashStringFromFile(Files[I]) = Hashes[I],
      'Publisher enrichment changed a source FB2');
    TracePublisher('first enrichment/search/source hash oracles passed; cache/error pass begin');
    RunIndexer(0, 1, 4);
    TFile.WriteAllText(Files[2], Metadata(''), TEncoding.UTF8);
    RunIndexer(1, 0, 4);
    ExpectPublisher(2, 'Known publisher 2');
    RunIndexer(0, 0, 5);
    TracePublisher('cache passes ready; reopen begin');
    Reopened := TBookCollection_SQLite.Create(Info, SystemDB);
    TracePublisher('reopen returned; publisher search begin');
    ExpectSearch(Reopened, 'Ёжик & Élan', 'Publisher source 0');
    Reopened := nil;
    TracePublisher('reopened search passed; exclusive-source cache begin');
    // Exclusive locks make any unnecessary descriptor read fail; source stamps
    // remain readable and every unchanged v3 entry must be satisfied by cache.
    SetLength(LockedSources, Length(Files));
    try
      for I := 0 to High(Files) do
        LockedSources[I] := TFileStream.Create(Files[I], fmOpenRead or fmShareExclusive);
      RunIndexer(0, 0, 5);
    finally
      for var LockedSource in LockedSources do LockedSource.Free;
      LockedSources := nil;
    end;
    TracePublisher('exclusive-source cache passed; pre-cancel begin');
    RunIndexer(0, 0, 0, True, True);
    Require(DataSnapshot = BeforeData, 'Cache, reopen or cancellation changed non-publisher book data');
    Writeln('PASS real publisher index enriches/searches catalog, preserves absent/invalid values and personal metadata, migrates v2 only on explicit scan and reuses v3 cache after reopen');

    Flush(Output); TracePublisher('atomic negative completion begin');
    // Abort the last statement after publisher and series updates to prove that
    // all three changes share the real production savepoint.
    OldKey := IndexKey(IDs[0]);
    BeforeSeries := Collection.GetBookPublisherSeries(CreateBookKey(IDs[0], ID));
    Series := nil; TSeriesHelper.Add(Series, 0, 'Must rollback series', 99, False);
    Writer := TSQLiteDatabase.Create(Info.DBFileName);
    try
      ConfigureWriter(Writer);
      // Whitespace is the one missing-publisher case: the failing transaction
      // must actually attempt enrichment before its final marker is aborted.
      Writer.ExecSQL('UPDATE Books SET Publisher=''  '' WHERE BookID=?', [IDs[0]]);
      Require((Writer.QuerySingleInt('SELECT changes()') = 1) and
        (Writer.QuerySingleString('SELECT Publisher FROM Books WHERE BookID=?', [IDs[0]]) = '  '),
        'Atomic publisher fixture did not prepare its actual missing value');
      Collection.GetBookRecord(CreateBookKey(IDs[0], ID), SourceSnapshot, True);
      Writer.ExecSQL('CREATE TRIGGER FailPublisherCompletion BEFORE INSERT ON PublisherSeries_Index ' +
        'WHEN NEW.BookID=' + IntToStr(IDs[0]) + ' AND NEW.SourceKey=''rollback-test'' ' +
        'BEGIN SELECT RAISE(ABORT,''Synthetic publisher completion failure''); END');
      Failed := False;
      try Collection.CompletePublisherSeriesIndex(CreateBookKey(IDs[0], ID),
        Series, 'rollback-test', 'Must rollback publisher', @SourceSnapshot);
      except on E: Exception do Failed := True; end;
      TracePublisher('atomic negative completion returned; rollback oracles begin');
      Require(Failed, 'Synthetic completion failure did not reach production savepoint');
      ExpectPublisher(0, '  ');
      Series := Collection.GetBookPublisherSeries(CreateBookKey(IDs[0], ID));
      Require((Length(Series) = Length(BeforeSeries)) and (Length(Series) = 1) and
        (Series[0].SeriesTitle = BeforeSeries[0].SeriesTitle) and
        (Series[0].SeqNumber = BeforeSeries[0].SeqNumber) and (IndexKey(IDs[0]) = OldKey),
        'Failed publisher completion partially saved series or source key');
      TracePublisher('rollback oracles passed; completion restoration begin');
      Writer.ExecSQL('DROP TRIGGER FailPublisherCompletion');
      Collection.CompletePublisherSeriesIndex(CreateBookKey(IDs[0], ID),
        BeforeSeries, OldKey, 'Ёжик & Élan', @SourceSnapshot);
      Collection.SetBookPublisherSeries(CreateBookKey(IDs[0], ID), BeforeSeries);
      ExpectPublisher(0, 'Ёжик & Élan');
      Collection.CompletePublisherSeriesIndex(CreateBookKey(IDs[0], ID), BeforeSeries, OldKey);
      ExpectPublisher(0, 'Ёжик & Élan');
      Require(Writer.QuerySingleString('PRAGMA quick_check') = 'ok', 'Publisher savepoint damaged catalog integrity');
    finally Writer.Free; end;
    Require(DataSnapshot = BeforeData, 'Atomic publisher update changed unrelated metadata');
    Writeln('PASS publisher, publisher series and source completion roll back atomically; legacy series setters keep known publishers');

    Flush(Output); TracePublisher('reused BookID safety fixture begin');
    ReplacementID := AddBook(Collection, 'Stale publisher source A',
      'Preserved replacement author', 'ru', 'Preserved replacement cycle', 'prose_contemporary');
    Collection.GetBookRecord(CreateBookKey(ReplacementID, ID), SourceSnapshot, True);
    TFile.WriteAllText(SourceSnapshot.GetBookFileName,
      Metadata('<publisher>Publisher A must not leak</publisher>'), TEncoding.UTF8);
    Source := TPublisherSeriesSource.Create(nil);
    try OldKey := Source.GetSourceKey(SourceSnapshot); finally Source.Free; end;
    Require(OldKey <> '', 'Stale snapshot has no actual source identity');
    Series := nil; TSeriesHelper.Add(Series, 0, 'Current B publisher series', 17, False);
    Writer := TSQLiteDatabase.Create(Info.DBFileName);
    try
      ConfigureWriter(Writer);
      // A full reimport may reuse an integer ID for another physical/source
      // book. Keep that exact ID while replacing its identity and catalog data.
      Writer.ExecSQL('UPDATE Books SET LibID=?,Title=?,FileName=?,InsideNo=?,BookSize=?,Publisher=?,Annotation=? WHERE BookID=?',
        ['replacement-B', 'Replacement book B', 'replacement-source-B', 9, 333,
         'Known publisher B', 'Preserved replacement annotation ё', ReplacementID]);
      Require(Writer.QuerySingleInt('SELECT changes()') = 1,
        'Stale publisher fixture did not replace exactly one current catalog row');
      Require(Writer.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID=? AND LibID=? AND Title=? AND FileName=? AND InsideNo=? AND BookSize=? AND Publisher=? AND Annotation=?',
        [ReplacementID, 'replacement-B', 'Replacement book B', 'replacement-source-B', 9, 333,
         'Known publisher B', 'Preserved replacement annotation ё']) = 1,
        'Stale publisher fixture has no actual replacement B identity and metadata');
      Require((Writer.QuerySingleString('SELECT SearchTitle FROM Books WHERE BookID=?', [ReplacementID]) = 'REPLACEMENT BOOK B') and
        (Writer.QuerySingleString('SELECT SearchFileName FROM Books WHERE BookID=?', [ReplacementID]) = 'REPLACEMENT-SOURCE-B'),
        'Direct replacement writer did not run the real metadata search trigger');
      Collection.SetRate(SourceSnapshot.BookKey, 4); Collection.SetProgress(SourceSnapshot.BookKey, 71);
      Collection.SetReview(SourceSnapshot.BookKey, 'Личная заметка replacement B 😀');
      Collection.CompletePublisherSeriesIndex(SourceSnapshot.BookKey, Series, 'current-B-source');
      Series := nil; TSeriesHelper.Add(Series, 0, 'Source A series must not leak to B', 99, False);
      ExpectStaleRejection(SourceSnapshot, 'reimport reused BookID');

      Collection.GetBookRecord(SourceSnapshot.BookKey, Book, True);
      SourceSnapshot := Book;
      TFile.WriteAllText(SourceSnapshot.GetBookFileName,
        Metadata('<publisher>Different publisher B</publisher>'), TEncoding.UTF8);
      Source := TPublisherSeriesSource.Create(nil);
      try OldKey := Source.GetSourceKey(SourceSnapshot); finally Source.Free; end;
      Require(OldKey <> '', 'Replacement snapshot has no actual source identity');
      Writer.ExecSQL('UPDATE Books SET FileName=? WHERE BookID=?', ['relocated-source-B', ReplacementID]);
      Require((Writer.QuerySingleInt('SELECT changes()') = 1) and
        (Writer.QuerySingleString('SELECT FileName FROM Books WHERE BookID=?', [ReplacementID]) = 'relocated-source-B') and
        (Writer.QuerySingleString('SELECT SearchFileName FROM Books WHERE BookID=?', [ReplacementID]) = 'RELOCATED-SOURCE-B'),
        'Changed-path stale fixture did not relocate the current row with active triggers');
      ExpectStaleRejection(SourceSnapshot, 'same LibID but changed source path');
      Writer.ExecSQL('UPDATE Books SET FileName=? WHERE BookID=?', [SourceSnapshot.FileName, ReplacementID]);

      // Capture first, then mutate the actual system property. Comparing a
      // freshly reloaded root with itself would incorrectly pass this case.
      Collection.GetBookRecord(CreateBookKey(ReplacementID, ID), SourceSnapshot, True);
      SystemDB.SetProperty(ID, PROP_ROOTFOLDER, Folder + 'relocated-root');
      try ExpectStaleRejection(SourceSnapshot, 'collection root changed after snapshot');
      finally SystemDB.SetProperty(ID, PROP_ROOTFOLDER, Folder); end;
      Series := nil; TSeriesHelper.Add(Series, 0, 'Current B publisher series', 17, False);
      Collection.CompletePublisherSeriesIndex(SourceSnapshot.BookKey, Series,
        'current-B-known-preserved', 'Different source publisher', @SourceSnapshot);
      Collection.GetBookRecord(SourceSnapshot.BookKey, Book, True);
      Require((Book.Publisher = 'Known publisher B') and (Book.Rate = 4) and (Book.Progress = 71) and
        (Book.Review = 'Личная заметка replacement B 😀'), 'Guarded fill overwrote known publisher or personal state');
      Require(Writer.QuerySingleString('PRAGMA quick_check') = 'ok', 'Stale identity refusal damaged catalog integrity');
    finally Writer.Free; end;
    Writeln('PASS publisher fill preserves known catalog values and rejects reused BookID, changed source path and changed collection root before any metadata/series/source-claim mutation');
  finally
    TracePublisher('collection cleanup references begin'); Reopened := nil; Collection := nil;
    TracePublisher('collection cleanup delete begin'); SystemDB.DeleteCollection(ID, True);
    TracePublisher('collection cleanup delete returned');
  end;
  TracePublisher('publisher metadata fixture finished');
end;
