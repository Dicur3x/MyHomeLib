// A disposable catalogue exercises the actual first query, not an in-memory iterator.
procedure TestFirstBookList;
const Total = 60000;
var
  ID, Kind, Seen, Expected, Count, Prepares: Integer;
  DB: TSQLiteDatabase;
  Collection: IBookCollection;
  Criteria: TBookSearchCriteria;
  Filter: TFilterValue;
  Iterator, Other: IBookIterator;
  LoadMemos: Boolean;
  Book: TBookRecord;
  Started, Prepared: UInt64;
  BeforeHash: string;
  Factory: TFunc<IBookIterator>;
begin
  DB := TSQLiteDatabase.Create(':memory:');
  try
    for var Value in TArray<string>.Create('', 'Кириллица ё ї ў — 😀 中文', StringOfChar('Ж', 200000)) do
    begin
      var Query := DB.NewQuery('SELECT ?,NULL,-1234567890123,CAST(12.5 AS REAL)');
      try
        Query.SetParam(0,Value); Query.Open;
        Require((Query.FieldAsString(0) = Value) and not Query.FieldIsNull(0) and
          Query.FieldIsNull(1) and (Query.FieldAsString(1) = '') and
          (Query.FieldAsString(2) = '-1234567890123') and (Query.FieldAsString(3) = '12.5'),
          'Direct UTF8 fields changed NULL empty Unicode long or numeric values');
      finally Query.Free; end;
    end;
  finally DB.Free; end;
  ID := SystemDB.CreateCollection('First list benchmark', Settings.AppPath,
    'first-list.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(ID);
  var Genre := Collection.EnsureGenre('prose_contemporary','Проза','Проза');
  var Author := Default(TAuthorData);
  Author.LastName := 'Автор'; Author.FirstName := 'Первый'; Collection.EnsureAuthor(Author);
  Author.FirstName := 'Второй'; Collection.EnsureAuthor(Author);
  DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(ID).DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.Start;
    try
      DB.ExecSQL('INSERT INTO Series(SeriesID,SeriesTitle) VALUES(1,''Основная серия''),(2,''Другая серия'')');
      DB.ExecSQL('INSERT INTO PublisherSeries(SeriesID,SeriesTitle,SearchSeriesTitle) VALUES(1,''Книжная серия'',''КНИЖНАЯ СЕРИЯ'')');
      DB.ExecSQL('WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<' + IntToStr(Total) + ') ' +
        'INSERT INTO Books(BookID,LibID,Title,SeriesID,SeqNumber,UpdateDate,Lang,Folder,FileName,InsideNo,Ext,BookSize,IsDeleted,Translators,Publisher,City,PubYear,ISBN,Review) ' +
        'SELECT x,CAST(x AS TEXT),printf(''Книга %06d'',x),1,x,''2026-10-01'',''ru'',''archive.zip'',CAST(x AS TEXT),x,''.fb2'',12345,x%10=0,' +
        '''Переводчик'',''Издатель'',''Москва'',2020,''978-1-23'',CASE WHEN x=1 THEN ''Личный отзыв'' ELSE NULL END FROM n');
      DB.ExecSQL('UPDATE Books SET Title=''Привет'' WHERE BookID IN (1,10)');
      DB.ExecSQL('UPDATE Books SET Title=''Привет 100%_ ''''quoted'''''' WHERE BookID=2');
      DB.ExecSQL('UPDATE Books SET UpdateDate=''2024-02-29 12:34:56'' WHERE BookID=2');
      DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) SELECT BookID,1 FROM Books');
      DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) SELECT BookID,2 FROM Books WHERE BookID%5=0');
      DB.ExecSQL('INSERT INTO Genre_List(BookID,GenreCode) SELECT BookID,' + QuotedStr(Genre.GenreCode) + ' FROM Books');
      DB.ExecSQL('INSERT INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) SELECT BookID,2,BookID+100,0,1 FROM Books WHERE BookID%5=0');
      DB.ExecSQL('INSERT INTO PublisherSeries_List(BookID,SeriesID,SeqNumber,OrdNum) SELECT BookID,1,BookID,0 FROM Books');
      DB.Commit;
    except DB.Rollback; raise; end;
  finally DB.Free; end;
  Collection := SystemDB.GetCollection(ID);
  Collection.SetHideDeleted(True);
  Filter := Default(TFilterValue); Filter.ValueInt := 1;
  BeforeHash := THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(ID).DBFileName);
  Factory := function: IBookIterator
    begin
      case Kind of
        0, 1, 2: Result := Collection.Search(Criteria, LoadMemos);
        3, 7: Result := Collection.GetBookIterator(bmByAuthor, LoadMemos, @Filter);
        4, 6: Result := Collection.GetBookIterator(bmBySeries, LoadMemos, @Filter);
        5: Result := Collection.GetBookIterator(bmByPublisherSeries, LoadMemos, @Filter);
      else raise Exception.Create('Unknown first-list fixture mode'); end;
    end;
  LoadMemos := False;
  for Kind := 0 to 7 do
  begin
    Filter.ValueInt := 1;
    if Kind >= 6 then Filter.ValueInt := 2;
    Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
    Criteria.Deleted := Kind <> 1; Criteria.FileExt := '.fb2';
    Criteria.CollapseMultiSeriesResults := Kind <> 2;
    Expected := Total - Total div 10;
    if Kind = 1 then Expected := Total;
    if Kind = 2 then Inc(Expected, Total div 10);
    if Kind >= 6 then Expected := Total div 10;
    StartSQLiteProfile;
    Started := GetTickCount64;
    Iterator := Factory();
    Prepared := GetTickCount64 - Started;
    Count := Iterator.RecordCount; Seen := 0;
    while Iterator.Next(Book) do
    begin
      Inc(Seen);
      Require(not Criteria.Deleted or not (bpIsDeleted in Book.BookProps), 'Deleted book escaped first-list condition');
      Require((Length(Book.Authors) >= 1) and (Length(Book.Genres) = 1) and
        (Length(Book.PublisherSeries) = 1) and Book.PublisherSeriesKnown and
        (Book.Translators = 'Переводчик') and (Book.City = 'Москва') and
        (Book.PubYear = 2020) and (Book.ISBN = '978-1-23'), 'First-list metadata missing');
      if Book.BookKey.BookID = 2 then
        Require(Abs(Book.Date - (EncodeDate(2024,2,29) + EncodeTime(12,34,56,0))) < 0.0000001, 'Changed timestamp reused an earlier date')
      else Require(Book.Date = EncodeDate(2026,10,1), 'Repeated date changed after timestamp row');
      Require((Book.Authors[0].AuthorID > 0) and (Book.Authors[0].LastName = 'Автор') and
        (Length(Book.Authors) = 1 + Ord(Book.BookKey.BookID mod 5 = 0)), 'Author cache lost names or coauthors');
      if Kind = 6 then Require((Book.SeriesID = 2) and (Book.Series = 'Другая серия') and
        (Book.SeqNumber = Book.BookKey.BookID + 100), 'Secondary series replaced by primary relationship');
      if Kind = 5 then Require(Book.PublisherSeqNumber = Book.BookKey.BookID, 'Publisher sequence lost');
    end;
    Iterator := nil;
    Writeln('PROFILE first-list query=',Kind,' prepare_ms=',Prepared,
      ' total_ms=',GetTickCount64-Started,' rows=',Seen); Flush(Output);
    SaveSQLiteProfile(Settings.AppPath + 'first-list-' + IntToStr(Kind) + '.tsv');
    StopSQLiteProfile;
    var Lines := TFile.ReadAllLines(Settings.AppPath + 'first-list-' + IntToStr(Kind) + '.tsv');
    Prepares := 0;
    for var LineNo := 1 to High(Lines) do
    begin
      var Parts := Lines[LineNo].Split([#9]);
      if (Length(Parts) >= 3) and (Parts[1] = 'prepare') then Inc(Prepares, StrToInt(Parts[2]));
    end;
    Writeln('PROFILE first-list query=',Kind,' prepared_statements=',Prepares);
    Require(Prepares < 30, 'First list has returned to per-book SQL queries');
    Require((Count = Expected) and (Seen = Expected), 'First-list count and rows differ');
    Started := GetTickCount64;
    frmMain.FillBooksTree(frmMain.tvBooksSR, nil,
      Factory, True, True, nil);
    Writeln('PROFILE first-list actual tree query=',Kind,' total_ms=',GetTickCount64-Started); Flush(Output);
  end;
  Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.Deleted:=True;
  Criteria.QueryMode:=sqmText; Criteria.Title:='привет'; Criteria.CollapseMultiSeriesResults:=True;
  for var SearchKind:=0 to 3 do
  begin
    if SearchKind=1 then Criteria.Deleted:=False;
    if SearchKind=2 then begin Criteria.Deleted:=True; Criteria.Title:='100%_ ''quoted'''; end;
    if SearchKind=3 then begin Criteria.Title:=''; Criteria.ExactTitle:='Привет'; end;
    Iterator:=Collection.Search(Criteria,False); Seen:=0;
    while Iterator.Next(Book) do begin Inc(Seen); Require(Book.Title.Contains('Привет'),'Title scan returned an unrelated book'); end;
    Expected:=2; if SearchKind=1 then Expected:=3 else if SearchKind>=2 then Expected:=1;
    Count:=Iterator.RecordCount;
    Writeln('PROFILE title case=',SearchKind,' seen=',Seen,' count=',Count,' expected=',Expected);
    Require((Seen=Expected) and (Count=Expected),'Title + deleted/literal/exact search changed results');
    Iterator:=nil;
  end;
  Writeln('PASS first-list title prefilter preserves Cyrillic literal percent underscore quotes exact title and hidden deleted');
  LoadMemos := True;
  Criteria.CollapseMultiSeriesResults := True;
  for Kind := 3 to 5 do
  begin
    Filter.ValueInt := 1;
    Iterator := Factory();
    Require(Iterator.Next(Book) and (Book.BookKey.BookID = 1) and
      (Book.Review = 'Личный отзыв') and (bpHasReview in Book.BookProps), 'Stream lost review payload');
    Other := Factory();
    Require(Other.Next(Book) and (Book.BookKey.BookID = 1), 'Nested stream starts at wrong book');
    Other := nil;
    Require(Iterator.Next(Book) and (Book.BookKey.BookID = 2), 'Nested iterator cleanup disturbed original stream');
    Iterator := nil;
  end;
  Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(ID).DBFileName) = BeforeHash,
    'First-list reads modified catalogue or personal data');
  // The reported path: a fresh Search view, all fields empty, only hide-deleted.
  ShowPage(PAGE_SEARCH);
  var CollectionItem := TMenuItem.Create(nil);
  try CollectionItem.Tag := ID; frmMain.miActiveCollectionClick(CollectionItem);
  finally CollectionItem.Free; end;
  frmMain.DoClearFilter(False);
  frmMain.cbDeleted.Checked := True;
  frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
  frmMain.cbCollapseMultiSeriesResults.Checked := True;
  Started := GetTickCount64;
  frmMain.DoApplyFilter(nil);
  Seen := 0;
  var Node := frmMain.tvBooksSR.GetFirst;
  while Assigned(Node) do
  begin
    var Data := PBookRecord(frmMain.tvBooksSR.GetNodeData(Node));
    if Assigned(Data) and (Data.nodeType = ntBookInfo) then
    begin
      Inc(Seen);
      Require(not (bpIsDeleted in Data.BookProps), 'Actual first Apply returned a deleted book');
    end;
    Node := frmMain.tvBooksSR.GetNext(Node);
  end;
  Require(Seen = Total - Total div 10, 'Actual first Apply lost books');
  Writeln('PROFILE first-list actual empty-fields hide-deleted Apply ms=',GetTickCount64-Started,' rows=',Seen);
  Writeln('PASS first-list actual queries preserve compact expanded deleted metadata counts and source bytes');
end;
