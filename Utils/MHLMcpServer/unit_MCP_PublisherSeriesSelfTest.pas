unit unit_MCP_PublisherSeriesSelfTest;

interface

uses
  unit_Globals,
  unit_Interfaces;

procedure CheckPublisherSeries(const SystemData: ISystemData;
  var Collection: IBookCollection; const CollectionFile: string;
  const BookIDs: TArray<Integer>);

implementation

uses
  System.Classes,
  System.IOUtils,
  System.SysUtils,
  SQLiteWrap,
  unit_Consts,
  unit_Database_SQLite,
  unit_SQLiteUtils;

procedure Require(const Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create('Publisher series: ' + Message);
end;

function IndexedSourceKey(const Collection: IBookCollection;
  const BookID: Integer): string;
var
  Iterator: IPublisherSeriesIndexIterator;
  Book: TBookRecord;
begin
  Iterator := Collection.GetPublisherSeriesIndexIterator;
  while Iterator.Next(Book, Result) do
    if Book.BookKey.BookID = BookID then Exit;
  raise Exception.Create('Publisher index fixture book not found');
end;

procedure CheckPublisherIndexAtomicity(const SystemData: ISystemData;
  const FileName: string; var Collection: IBookCollection; const Key: TBookKey;
  const Series: TBookSeries);
var
  Database: TSQLiteDatabase;
  Failed: Boolean;
begin
  // Upgrade an existing publisher-series database without rebuilding its data.
  Collection := nil;
  Database := TSQLiteDatabase.Create(FileName);
  try
    Database.ExecSQL('DROP TRIGGER TRBooks_BD_PublisherSeriesIndex');
    Database.ExecSQL('DROP TABLE PublisherSeries_Index');
  finally
    Database.Free;
  end;
  Collection := TBookCollection_SQLite.CreateTemp(FileName, SystemData);
  Require(Length(Collection.GetBookPublisherSeries(Key)) = 1,
    'adding the index cache changed existing publisher series');
  Require(IndexedSourceKey(Collection, Key.BookID) = '',
    'new cache invented a successful source');
  Collection.CompletePublisherSeriesIndex(Key, Series, 'original-source');
  Collection := nil;
  Collection := TBookCollection_SQLite.CreateTemp(FileName, SystemData);
  Require(IndexedSourceKey(Collection, Key.BookID) = 'original-source',
    'successful source did not survive reopening');

  Collection.BeginBulkOperation;
  try
    Collection.CompletePublisherSeriesIndex(Key, nil, 'empty-source');
    Require((IndexedSourceKey(Collection, Key.BookID) = 'empty-source') and
      (Length(Collection.GetBookPublisherSeries(Key)) = 0),
      'successful empty metadata was not indexed');
  finally
    Collection.EndBulkOperation(False);
  end;
  Require((IndexedSourceKey(Collection, Key.BookID) = 'original-source') and
    (Length(Collection.GetBookPublisherSeries(Key)) = 1),
    'caller rollback did not restore both metadata and source');

  Database := TSQLiteDatabase.Create(FileName);
  try
    Database.ExecSQL('CREATE TRIGGER FixtureRejectSource BEFORE INSERT ON ' +
      'PublisherSeries_Index WHEN NEW.SourceKey = ''rejected-source'' BEGIN ' +
      'SELECT RAISE(ABORT, ''fixture source failure''); END');
  finally
    Database.Free;
  end;
  try
    Failed := False;
    try
      Collection.CompletePublisherSeriesIndex(Key, nil, 'rejected-source');
    except
      on E: Exception do Failed := True;
    end;
    Require(Failed, 'source failure injection did not run');
    Require((IndexedSourceKey(Collection, Key.BookID) = 'original-source') and
      (Length(Collection.GetBookPublisherSeries(Key)) = 1),
      'source write failure left partially replaced publisher series');
  finally
    Database := TSQLiteDatabase.Create(FileName);
    try
      Database.ExecSQL('DROP TRIGGER FixtureRejectSource');
    finally
      Database.Free;
    end;
  end;
  Failed := False;
  try
    Collection.CompletePublisherSeriesIndex(Key, nil, '');
  except
    on E: EArgumentException do Failed := True;
  end;
  Require(Failed and (IndexedSourceKey(Collection, Key.BookID) = 'original-source'),
    'empty source key was accepted or changed completion state');
  Collection.SetBookPublisherSeries(Key, Series);
  Require(IndexedSourceKey(Collection, Key.BookID) = '',
    'ordinary metadata replacement retained a stale source marker');
  Collection.CompletePublisherSeriesIndex(Key, nil, 'empty-source');
  Require((IndexedSourceKey(Collection, Key.BookID) = 'empty-source') and
    (Length(Collection.GetBookPublisherSeries(Key)) = 0),
    'committed empty metadata was not indexed');
  Collection.CompletePublisherSeriesIndex(Key, Series, 'before-recreation');
end;

procedure CheckCollectionRecreation(const SystemData: ISystemData);
var
  FileName: string;
  Scratch: IBookCollection;
  Items: ISeriesIterator;
  Database: TSQLiteDatabase;
  Statements: TStringList;
  Statement: string;
  Book: TBookRecord;
  Key: TBookKey;
  Series: TBookSeries;
  OldBookID, NewBookID, Pass: Integer;
begin
  // This database is never registered in the profile. Reuse its file and IDs
  // through both embedded schema scripts, without touching the main fixture.
  FileName := TPath.GetTempFileName;
  try
    TBookCollection_SQLite.CreateCollection(SystemData, FileName, CT_PRIVATE_FB,
      ExtractFilePath(ParamStr(0)) + GENRES_FB2_FILENAME);
    for Pass := 0 to 1 do
    begin
      Scratch := TBookCollection_SQLite.CreateTemp(FileName, SystemData);
      Book.Clear;
      Book.Title := 'Old collection book';
      Book.FileName := 'old-collection-book';
      Book.FileExt := FB2_EXTENSION;
      Book.LibID := Book.FileName;
      SetLength(Book.Authors, 1);
      Book.Authors[0].LastName := 'Old author';
      SetLength(Book.Genres, 1);
      Book.Genres[0].FB2GenreCode := 'prose_contemporary';
      Book.Series := 'Old author cycle';
      Book.SeqNumber := 4;
      OldBookID := Scratch.InsertBook(Book, False, False);
      Key := CreateBookKey(OldBookID, Scratch.CollectionID);
      Series := nil;
      TSeriesHelper.Add(Series, 0, 'Old publisher series', 9, False);
      Scratch.SetBookPublisherSeries(Key, Series);
      Require(Length(Scratch.GetBookPublisherSeries(Key)) = 1,
        'recreation fixture publisher metadata missing');
      if Pass = 0 then
        CheckPublisherIndexAtomicity(SystemData, FileName, Scratch, Key, Series)
      else
        Scratch.CompletePublisherSeriesIndex(Key, Series, 'before-recreation');
      Scratch := nil;

      if Pass = 0 then
        TBookCollection_SQLite.CreateCollection(SystemData, FileName, CT_PRIVATE_FB,
          ExtractFilePath(ParamStr(0)) + GENRES_FB2_FILENAME)
      else
      begin
        Database := TSQLiteDatabase.Create(FileName);
        try
          Statements := ReadResourceAsStringList('RecreateCollectionTables');
          try
            for Statement in Statements do
              if Trim(Statement) <> '' then Database.ExecSQL(Statement);
          finally
            Statements.Free;
          end;
        finally
          Database.Free;
        end;
      end;

      Scratch := TBookCollection_SQLite.CreateTemp(FileName, SystemData);
      Database := TSQLiteDatabase.Create(FileName);
      try
        Require(Database.QuerySingleInt('SELECT COUNT(*) FROM Books') = 0,
          'recreation retained old books');
        Require(Database.QuerySingleInt('SELECT COUNT(*) FROM PublisherSeries_Index') = 0,
          'recreation retained successful source markers');
      finally
        Database.Free;
      end;
      Book.Series := '';
      Book.SeqNumber := 0;
      Book.Title := 'Replacement collection book';
      NewBookID := Scratch.InsertBook(Book, False, False);
      Require(NewBookID = OldBookID, 'recreation fixture did not reuse a book ID');
      Key := CreateBookKey(NewBookID, Scratch.CollectionID);
      Require(Length(Scratch.GetBookPublisherSeries(Key)) = 0,
        'reused book ID inherited old publisher metadata');
      Require(IndexedSourceKey(Scratch, NewBookID) = '',
        'reused book ID inherited a completed source');
      Items := Scratch.GetPublisherSeriesIterator('*');
      Require(Items.RecordCount = 0, 'recreation retained publisher series');
      Items := nil;
      Require(Length(Scratch.GetBookSeries(Key)) = 0,
        'reused book ID inherited old author cycles');
      Scratch.CompletePublisherSeriesIndex(Key, Series, 'before-delete');
      Database := TSQLiteDatabase.Create(FileName);
      try
        Database.ExecSQL('DELETE FROM Books WHERE BookID = ?', [NewBookID]);
        Require(Database.QuerySingleInt('SELECT COUNT(*) FROM PublisherSeries_Index') = 0,
          'book deletion retained its completed source');
      finally
        Database.Free;
      end;
      NewBookID := Scratch.InsertBook(Book, False, False);
      Key := CreateBookKey(NewBookID, Scratch.CollectionID);
      Scratch.CompletePublisherSeriesIndex(Key, Series, 'before-truncate');
      Scratch.TruncateTablesBeforeImport;
      Database := TSQLiteDatabase.Create(FileName);
      try
        Require(Database.QuerySingleInt('SELECT COUNT(*) FROM PublisherSeries_Index') = 0,
          'full reimport retained completed source markers');
      finally
        Database.Free;
      end;
      Scratch := nil;
    end;
  finally
    Items := nil;
    Scratch := nil;
    TFile.Delete(FileName);
  end;
end;

procedure CheckPublisherIndexIterator(const Collection: IBookCollection;
  const ExpectedCount, FirstBookID, LastBookID: Integer);
var
  Iterator: IPublisherSeriesIndexIterator;
  Book, FullBook: TBookRecord;
  SourceKey, FirstFolder, LastFolder: string;
  Seen: TArray<Integer>;
  Count, I: Integer;
  SavedHideDeleted, SavedLocalOnly: Boolean;
begin
  Collection.GetBookRecord(CreateBookKey(FirstBookID, Collection.CollectionID), FullBook, False);
  FirstFolder := FullBook.Folder;
  Collection.GetBookRecord(CreateBookKey(LastBookID, Collection.CollectionID), FullBook, False);
  LastFolder := FullBook.Folder;
  SavedHideDeleted := Collection.GetHideDeleted;
  SavedLocalOnly := Collection.GetShowLocalOnly;
  Collection.SetFolder(CreateBookKey(FirstBookID, Collection.CollectionID), 'aaa-index-fixture/');
  Collection.SetFolder(CreateBookKey(LastBookID, Collection.CollectionID), 'zzz-index-fixture/');
  try
    Collection.SetHideDeleted(True);
    Collection.SetShowLocalOnly(True);
    Iterator := Collection.GetPublisherSeriesIndexIterator;
    Require(Iterator.RecordCount = ExpectedCount, 'index iterator applied a browser filter');
    SetLength(Seen, ExpectedCount);
    Count := 0;
    while Iterator.Next(Book, SourceKey) do
    begin
      Require(Count < ExpectedCount, 'index iterator duplicated rows during writes');
      for I := 0 to Count - 1 do
        Require(Seen[I] <> Book.BookKey.BookID, 'index iterator repeated a book');
      Seen[Count] := Book.BookKey.BookID;
      Inc(Count);
      Collection.GetBookRecord(Book.BookKey, FullBook, False);
      Require((Book.Title = FullBook.Title) and (Book.Folder = FullBook.Folder) and
        (Book.FileName = FullBook.FileName) and (Book.FileExt = FullBook.FileExt) and
        (Book.InsideNo = FullBook.InsideNo) and (Book.LibID = FullBook.LibID) and
        (Book.CollectionRoot = FullBook.CollectionRoot) and
        ((bpIsLocal in Book.BookProps) = (bpIsLocal in FullBook.BookProps)) and
        ((bpIsDeleted in Book.BookProps) = (bpIsDeleted in FullBook.BookProps)),
        'lightweight iterator lost source metadata');
      Require((Length(Book.Authors) = 0) and (Length(Book.Genres) = 0) and
        (Book.Series = '') and (Book.Annotation = '') and (Book.Review = '') and
        not Book.PublisherSeriesKnown, 'index iterator loaded unrelated metadata');
      Require(SourceKey = '', 'new fixture unexpectedly has a completed source');
      Collection.CompletePublisherSeriesIndex(Book.BookKey,
        Collection.GetBookPublisherSeries(Book.BookKey), 'iterator-' + IntToStr(Book.BookKey.BookID));
    end;
    Require((Count = ExpectedCount) and (Seen[0] = FirstBookID) and
      (Seen[Count - 1] = LastBookID), 'index iterator lost archive grouping or rows');
    Require((Book.BookKey.BookID <= 0) and (SourceKey = ''),
      'index iterator left stale output after EOF');
    Iterator := nil;
    Require(IndexedSourceKey(Collection, FirstBookID) = 'iterator-' + IntToStr(FirstBookID),
      'iterator did not return the stored source key');
  finally
    Iterator := nil;
    Collection.SetHideDeleted(SavedHideDeleted);
    Collection.SetShowLocalOnly(SavedLocalOnly);
    Collection.SetFolder(CreateBookKey(FirstBookID, Collection.CollectionID), FirstFolder);
    Collection.SetFolder(CreateBookKey(LastBookID, Collection.CollectionID), LastFolder);
  end;
end;

procedure CheckPublisherSeries(const SystemData: ISystemData;
  var Collection: IBookCollection; const CollectionFile: string;
  const BookIDs: TArray<Integer>);
var
  CollectionID, SeriesID, RemoteBookID: Integer;
  OriginalSeriesID, OriginalNumber: Integer;
  OriginalSeries, SchemaVersion: string;
  PublisherLink: string;
  SavedHideDeleted, SavedLocalOnly: Boolean;
  Series, Stored: TBookSeries;
  Book, Original: TBookRecord;
  Filter: TFilterValue;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  LegacyDatabase: TSQLiteDatabase;

  procedure CheckBooks(const Books: IBookIterator; const Expected: array of Integer;
    const PublisherNumber: Integer = -1);
  var
    Row: TBookRecord;
    Count, I: Integer;
    Found: Boolean;
  begin
    Require(Books.RecordCount = Length(Expected), 'incorrect book count');
    Count := 0;
    while Books.Next(Row) do
    begin
      Found := False;
      for I := Low(Expected) to High(Expected) do
        Found := Found or (Row.BookKey.BookID = Expected[I]);
      Require(Found, 'unexpected book');
      if Row.BookKey.BookID = BookIDs[0] then
      begin
        Require((Row.SeriesID = OriginalSeriesID) and
          (Row.Series = OriginalSeries) and (Row.SeqNumber = OriginalNumber),
          'publisher view overwrote the author cycle');
        Require((Row.Lang = Original.Lang) and
          (Length(Row.Genres) = Length(Original.Genres)), 'language or genres changed');
        if PublisherNumber >= 0 then
          Require(Row.PublisherSeqNumber = PublisherNumber, 'publisher number was lost');
      end;
      Inc(Count);
    end;
    Require(Count = Length(Expected), 'book iterator count differs from rows');
  end;

  function CountPublisherSeries(const Prefix: string): Integer;
  var
    Items: ISeriesIterator;
    Item: TSeriesData;
    Reported: Integer;
  begin
    Items := Collection.GetPublisherSeriesIterator(Prefix);
    Reported := Items.RecordCount;
    Result := 0;
    while Items.Next(Item) do Inc(Result);
    Require(Result = Reported, 'series iterator count differs from rows');
  end;

begin
  CheckCollectionRecreation(SystemData);
  TSeriesHelper.Add(Series, 42, 'Print & <Classics> <br> </a><a href="999">', 7, False);
  PublisherLink := TSeriesHelper.GetLinkList(Series, True);
  Require(PublisherLink = '<a href="42">Print & <' + #$200B +
    'Classics> <' + #$200B + 'br> <' + #$200B + '/a><' + #$200B +
    'a href="999"></a> ' + #$2116 + ' 7',
    'literal link title escaping failed: ' + PublisherLink);
  Require(Pos('<a href="999">', PublisherLink) = 0,
    'title injected a different link');
  Require(Pos('<br>', PublisherLink) = 0, 'title injected a row separator');
  Require(Series[0].SeriesTitle = 'Print & <Classics> <br> </a><a href="999">',
    'link formatting changed stored metadata');
  Series := nil;

  CollectionID := Collection.CollectionID;
  SchemaVersion := Collection.GetProperty(PROP_SCHEMA_VERSION);
  Collection.GetBookRecord(CreateBookKey(BookIDs[0], CollectionID), Original, False);
  OriginalSeriesID := Original.SeriesID;
  OriginalSeries := Original.Series;
  OriginalNumber := Original.SeqNumber;
  Require(Length(Collection.GetBookSeries(Original.BookKey)) = 2,
    'fixture must retain its secondary author cycle');

  // Simulate a populated pre-feature collection, then use the normal reopen
  // path twice. The migration must be additive, idempotent and free of backfill.
  Collection := nil;
  SystemData.ClearCollectionCache;
  LegacyDatabase := TSQLiteDatabase.Create(CollectionFile);
  try
    LegacyDatabase.ExecSQL('DROP TRIGGER IF EXISTS TRBooks_BD_PublisherSeries');
    LegacyDatabase.ExecSQL('DROP TABLE PublisherSeries_List');
    LegacyDatabase.ExecSQL('DROP TABLE PublisherSeries');
  finally
    LegacyDatabase.Free;
  end;
  Collection := SystemData.GetCollection(CollectionID);
  Require(string(Collection.GetProperty(PROP_SCHEMA_VERSION)) = SchemaVersion,
    'legacy schema ID changed');
  Iterator := Collection.GetBookIterator(bmAll, False);
  Require(Iterator.RecordCount = Length(BookIDs), 'migration changed book count');
  Iterator := nil;
  Require(Length(Collection.GetBookSeries(Original.BookKey)) = 2,
    'migration lost secondary author cycles');
  Require(CountPublisherSeries('') = 0, 'migration invented publisher metadata');
  Collection := nil;
  SystemData.ClearCollectionCache;
  Collection := SystemData.GetCollection(CollectionID);
  Require(CountPublisherSeries('') = 0, 'repeated migration changed empty index');

  SavedHideDeleted := Collection.GetHideDeleted;
  SavedLocalOnly := Collection.GetShowLocalOnly;
  Collection.BeginBulkOperation;
  try
    Collection.SetHideDeleted(False);
    Collection.SetShowLocalOnly(False);
    TSeriesHelper.Add(Series, 0, OriginalSeries, 6001, False);
    TSeriesHelper.Add(Series, 0, 'Print & <Classics>', 2, False);
    TSeriesHelper.Add(Series, 0, 'Print & <Classics>', 2, False);
    Collection.SetBookPublisherSeries(Original.BookKey, Series);
    Stored := Collection.GetBookPublisherSeries(Original.BookKey);
    Require((Length(Stored) = 2) and (Stored[0].SeriesTitle = OriginalSeries) and
      (Stored[0].SeqNumber = 6001) and (Stored[1].SeqNumber = 2),
      'multiple series, deduplication, order or large numbering failed');
    SeriesID := Stored[0].SeriesID;
    Filter.ValueInt := SeriesID;
    CheckBooks(Collection.GetBookIterator(bmByPublisherSeries, False, @Filter),
      [BookIDs[0]], 6001);
    Require(CountPublisherSeries('print') = 1, 'case-insensitive prefix failed');
    Require(CountPublisherSeries(OriginalSeries) = 1, 'non-Latin prefix failed');

    // An ordinary edit loads no publisher array. It must not erase that array.
    Collection.GetBookRecord(Original.BookKey, Book, False);
    Require(not Book.PublisherSeriesKnown, 'lightweight record loaded extra metadata');
    Collection.UpdateBook(Book);
    Require(Length(Collection.GetBookPublisherSeries(Original.BookKey)) = 2,
      'ordinary book edit erased publisher metadata');
    Collection.GetBookRecord(Original.BookKey, Book, True);
    Require(Book.PublisherSeriesKnown and (Length(Book.PublisherSeries) = 2),
      'full book record lost publisher metadata');

    Book.BookKey.Clear;
    Book.FileName := 'publisher-remote';
    Book.LibID := 'publisher-remote';
    Exclude(Book.BookProps, bpIsLocal);
    RemoteBookID := Collection.InsertBook(Book, False, False);
    Require(RemoteBookID <> 0, 'publisher import fixture was not inserted');
    CheckPublisherIndexIterator(Collection, Length(BookIDs) + 1, BookIDs[1], BookIDs[0]);
    CheckBooks(Collection.GetBookIterator(bmByPublisherSeries, False, @Filter),
      [BookIDs[0], RemoteBookID], 6001);
    Collection.SetShowLocalOnly(True);
    CheckBooks(Collection.GetBookIterator(bmByPublisherSeries, False, @Filter),
      [BookIDs[0]], 6001);
    Collection.SetShowLocalOnly(False);

    Series := nil;
    TSeriesHelper.Add(Series, 0, '2026 print editions', -5, False);
    Collection.SetBookPublisherSeries(CreateBookKey(BookIDs[4], CollectionID), Series);
    Stored := Collection.GetBookPublisherSeries(CreateBookKey(BookIDs[4], CollectionID));
    Require((Length(Stored) = 1) and (Stored[0].SeqNumber = 0),
      'negative publisher number was not normalized');
    Require(CountPublisherSeries(ALPHA_FILTER_NON_ALPHA) = 1,
      'non-alphabetic prefix filter failed');
    Require(Length(Collection.GetBookSeries(CreateBookKey(BookIDs[4], CollectionID))) = 0,
      'publisher series became an author cycle');

    Series := nil;
    TSeriesHelper.Add(Series, 0, 'Deleted print series', 7, False);
    Collection.SetBookPublisherSeries(CreateBookKey(BookIDs[5], CollectionID), Series);
    Stored := Collection.GetBookPublisherSeries(CreateBookKey(BookIDs[5], CollectionID));
    Filter.ValueInt := Stored[0].SeriesID;
    CheckBooks(Collection.GetBookIterator(bmByPublisherSeries, False, @Filter), [BookIDs[5]]);
    Require(CountPublisherSeries('Deleted') = 1, 'deleted series not shown');
    Collection.SetHideDeleted(True);
    CheckBooks(Collection.GetBookIterator(bmByPublisherSeries, False, @Filter), []);
    Require(CountPublisherSeries('Deleted') = 0, 'deleted series not hidden');

    Filter.ValueInt := Original.Authors[0].AuthorID;
    CheckBooks(Collection.GetBookIterator(bmByAuthor, False, @Filter),
      [BookIDs[0], BookIDs[1], RemoteBookID]);
    Filter.ValueString := Original.Genres[0].GenreCode;
    CheckBooks(Collection.GetBookIterator(bmByGenre, False, @Filter),
      [BookIDs[0], BookIDs[1], RemoteBookID]);
    CheckBooks(Collection.GetBookIterator(bmByGenreRecursive, False, @Filter),
      [BookIDs[0], BookIDs[1], RemoteBookID]);
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := -1;
    Criteria.CollapseMultiSeriesResults := True;
    Criteria.Lang := Original.Lang;
    Criteria.Genre := 'g.GenreCode = ' + QuotedStr(Original.Genres[0].GenreCode);
    Criteria.Deleted := True;
    CheckBooks(Collection.Search(Criteria, False),
      [BookIDs[0], BookIDs[1], RemoteBookID]);
    Criteria.Series := 'Print';
    CheckBooks(Collection.Search(Criteria, False), []);

    // Favorites use canonical author-cycle metadata, never publisher IDs.
    SystemData.AddBookToGroup(Original.BookKey, FAVORITES_GROUP_ID, Original);
    try
      CheckBooks(SystemData.GetBookIterator(FAVORITES_GROUP_ID), [BookIDs[0]]);
    finally
      SystemData.DeleteBook(Original.BookKey);
    end;

    Collection.SetBookPublisherSeries(Original.BookKey, nil);
    Require(Length(Collection.GetBookPublisherSeries(Original.BookKey)) = 0,
      'successful empty metadata did not clear old series');
    Require(Length(Collection.GetBookSeries(Original.BookKey)) = 2,
      'clearing publisher metadata changed author cycles');
  finally
    Collection.EndBulkOperation(False);
    Collection.SetHideDeleted(SavedHideDeleted);
    Collection.SetShowLocalOnly(SavedLocalOnly);
  end;
  Require(CountPublisherSeries('') = 0, 'publisher updates escaped caller rollback');
  Require(IndexedSourceKey(Collection, Original.BookKey.BookID) = '',
    'index completion escaped caller rollback');
end;

end.
