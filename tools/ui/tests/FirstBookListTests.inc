// Independent snapshot of the established display format, including its
// historical treatment of whitespace, empty parts, initials and UTF-16.
procedure TestBookDisplayNames;
var
  Values: TArray<string>;
  LastName, FirstName, MiddleName, NickName, Expected: string;
  Initials: Boolean;
  Authors: TBookAuthors;
  Genres: TBookGenres;
  Checked, Count, Index: Integer;

  function EstablishedName(const LastPart, FirstPart, MiddlePart, NickPart: string;
    const Short: Boolean): string;
  begin
    Result := LastPart;
    if FirstPart <> '' then
      if Short then Result := Result + ' ' + FirstPart[1] + '.'
      else Result := Result + ' ' + FirstPart;
    if MiddlePart <> '' then
      if Short then Result := Result + ' ' + MiddlePart[1] + '.'
      else Result := Result + ' ' + MiddlePart;
    if NickPart <> '' then
      if Result = '' then Result := NickPart
      else Result := Result + '(' + NickPart + ')';
  end;
begin
  Values := TArray<string>.Create('', 'А', 'ё', 'Анна-Мария', '😀', 'А'+#0+'Б', ' Имя  имя ');
  Checked := 0;
  for LastName in Values do
    for FirstName in Values do
      for MiddleName in Values do
        for NickName in TArray<string>.Create('', 'Ник ё', '😀') do
          for Initials := False to True do
          begin
            Expected := EstablishedName(LastName,FirstName,MiddleName,NickName,Initials);
            Require(unit_FB2Utils.FormatName(LastName,FirstName,MiddleName,NickName,Initials)=Expected,
              'Display name changed empty/Unicode/whitespace/initials/nickname formatting');
            Inc(Checked);
          end;
  for Count := 0 to 12 do
  begin
    SetLength(Authors,Count); SetLength(Genres,Count);
    Expected := '';
    for Index := 0 to Count-1 do
    begin
      Authors[Index].LastName := 'Автор '+IntToStr(Index);
      Authors[Index].FirstName := Values[Index mod Length(Values)];
      Authors[Index].MiddleName := Values[(Index+1) mod Length(Values)];
      if Index>0 then Expected := Expected+', ';
      Expected := Expected+EstablishedName(Authors[Index].LastName,Authors[Index].FirstName,
        Authors[Index].MiddleName,'',False);
    end;
    Require(TAuthorsHelper.GetList(Authors)=Expected,'Author display list changed order or separators');
    Expected := '';
    for Index := 0 to Count-1 do
    begin
      Genres[Index].GenreAlias := Values[Index mod Length(Values)];
      if Index>0 then Expected := Expected+' / ';
      Expected := Expected+Genres[Index].GenreAlias;
    end;
    Require(TGenresHelper.GetList(Genres)=Expected,'Genre display list changed empty values or separators');
  end;
  Writeln('PASS book display labels preserve established Unicode whitespace initials nicknames empty single multiple authors genres cases=',Checked);
end;

// The fixed ISO fast path must remain equivalent to the former RTL parser.
procedure TestSQLiteDateDecoding;
var
  DB: TSQLiteDatabase;
  Query: TSQLiteQuery;
  Formats: TFormatSettings;
  Values: TArray<string>;
  Value: string;
  Expected, Actual: TDateTime;
  Valid, ReadValid: Boolean;
  Index, Checked: Integer;
begin
  Formats := TFormatSettings.Create($0800);
  Formats.ShortDateFormat := 'yyyy-mm-dd'; Formats.LongDateFormat := 'yyyy-mm-dd';
  Formats.DateSeparator := '-'; Formats.ShortTimeFormat := 'hh:nn:ss.zzz';
  Formats.LongTimeFormat := 'hh:nn:ss.zzz'; Formats.TimeSeparator := ':';
  Values := TArray<string>.Create('1000-01-01', '9999-12-31', '1900-02-28',
    '2000-02-29', '2024-02-29', '2026-10-24', '0001-01-01', '0099-01-01',
    '2024-2-9', ' 2024-02-29 ', '2024-02-29 12:34:56',
    '2024-02-29 12:34:56.123', '2026-10-24 00:00:00.001',
    '1900-02-29', '2023-02-29', '2024-13-01', '2024-00-01', '2024-01-00',
    '2024-01-32', '0000-01-01', '2024-02-2x', '2024/02/29', '', 'not a date');
  DB := TSQLiteDatabase.Create(':memory:');
  try
    Query := DB.NewQuery('SELECT ?');
    try
      Checked := 0;
      for Index := 0 to Length(Values) + 1023 do
      begin
        if Index < Length(Values) then Value := Values[Index]
        else Value := FormatDateTime('yyyy-mm-dd',
          EncodeDate(1896,1,1) + (Index-Length(Values))*79, Formats);
        Valid := TryStrToDateTime(Value, Expected, Formats);
        Query.Reset; Query.SetParam(0, Value); Query.Open;
        ReadValid := True; Actual := 0;
        try Actual := Query.FieldAsDateTime(0);
        except on E: EConvertError do ReadValid := False; end;
        Require(Valid = ReadValid, 'Catalogue date validation differs from the former RTL parser: ' + Value);
        if Valid then Require(Abs(Actual - Expected) < 0.00000000001,
          'Catalogue date or timestamp changed: ' + Value);
        Inc(Checked);
      end;
      Writeln('PASS fixed ISO catalogue dates preserve RTL calendar timestamps legacy forms and invalid dates cases=',Checked);
    finally Query.Free; end;
  finally DB.Free; end;
end;

// Compare the optimized stream against the former SQL collation, including
// coauthor ordering, NULL vs empty names and case-insensitive ties.
procedure TestStreamAuthorOrder;
var
  Collection: IBookCollection;
  DB: TSQLiteDatabase;
  CID, BookID, AuthorID, Mode, Seen, Position: Integer;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  Book: TBookRecord;
  Expected: TSQLiteQuery;
  LastNames: TArray<string>;
  FirstName, MiddleName, BeforeHash: string;
begin
  CID := SystemDB.CreateCollection('Coauthor order', Settings.AppPath,
    'stream-author-order.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  for BookID := 1 to 4 do AddBook(Collection, 'Order ' + IntToStr(BookID), 'Temporary author', 'ru', 'One series', '0.1');
  DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(CID).DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    // SQLite resolves disabled trigger functions while preparing each insert.
    DB.AddFunction('MHL_FULLNAME',4,EnableScaleFixtureTriggers);
    DB.Start;
    try
      DB.ExecSQL('DELETE FROM Author_List');
      LastNames := TArray<string>.Create('Яков', 'Автор', 'АВТОР', 'Ёж', 'Еж', 'Émile', 'Emile', '张', '😀');
      for AuthorID := 1 to 72 do
      begin
        case AuthorID mod 4 of
          0: FirstName := 'NULL';
          1: FirstName := QuotedStr('');
          2: FirstName := QuotedStr('Анна');
        else FirstName := QuotedStr('анна'); end;
        case AuthorID mod 3 of
          0: MiddleName := 'NULL';
          1: MiddleName := QuotedStr('');
        else MiddleName := QuotedStr('Ё'); end;
        DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName,FirstName,MiddleName) VALUES(' +
          IntToStr(100 + AuthorID) + ',' + QuotedStr(LastNames[AuthorID mod Length(LastNames)]) +
          ',' + FirstName + ',' + MiddleName + ')');
        DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,' + IntToStr(100 + AuthorID) + ')');
        if AuthorID mod 3 = 0 then
          DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(2,' + IntToStr(100 + AuthorID) + ')');
      end;
      DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(4,101)');
      DB.Commit;
    except DB.Rollback; raise; end;
    BeforeHash := THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName);
    for Mode := 0 to 3 do
    begin
      Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
      Criteria.CollapseMultiSeriesResults := Mode <> 3;
      Criteria.Deleted := Mode = 1;
      if Mode = 3 then Criteria.FileExt := '.fb2';
      if Mode = 2 then begin Criteria.QueryMode := sqmText; Criteria.Title := 'Order'; end;
      Writeln('TRACE streamed coauthor case=',Mode); Flush(Output);
      if Mode = 0 then Iterator := Collection.GetBookIterator(bmAll, False)
      else Iterator := Collection.Search(Criteria, False);
      Seen := 0;
      while Iterator.Next(Book) do
      begin
        Inc(Seen);
        Expected := DB.NewQuery('SELECT a.AuthorID FROM Author_List al JOIN Authors a ON a.AuthorID=al.AuthorID ' +
          'WHERE al.BookID=' + IntToStr(Book.BookKey.BookID) +
          ' ORDER BY a.LastName,a.FirstName,a.MiddleName,al.AuthorID');
        try
          Expected.Open; Position := 0;
          while not Expected.Eof do
          begin
            Require((Position < Length(Book.Authors)) and
              (Book.Authors[Position].AuthorID = Expected.FieldAsInt(0)),
              'Streaming coauthors changed SQL Unicode/NULL/tie ordering');
            Inc(Position); Expected.Next;
          end;
          Require(Position = Length(Book.Authors), 'Streaming coauthors added or lost an author');
        finally Expected.Free; end;
      end;
      Require(Seen = 4, 'Coauthor ordering fixture lost a book');
      Iterator := nil;
    end;
    Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName) = BeforeHash,
      'Coauthor ordering changed catalogue bytes');
    Writeln('PASS streamed coauthors match SQL order for Unicode NULL empty names case ties zero single and 72-author books');
  finally DB.Free; end;
end;

// The full visible stream skips deleted metadata at both ends and in gaps.
// Compare with independent per-book queries, including empty relationship lists.
procedure TestVisibleMetadataStreams;
var
  Collection: IBookCollection;
  DB: TSQLiteDatabase;
  CID, I, Mode, Seen: Integer;
  IDs: array[1..9] of Integer;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  Book, Expected: TBookRecord;
  PublisherSeries: TBookSeries;
  BeforeHash: string;
begin
  CID := SystemDB.CreateCollection('Visible metadata gaps', Settings.AppPath,
    'visible-metadata-gaps.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath+'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  for I:=1 to 9 do
    IDs[I]:=AddBook(Collection,'Visible gap '+IntToStr(I),'Author '+IntToStr(I),
      'ru','Primary '+IntToStr(I),'0.1',I in [1,3,4,8,9]);
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(CID).DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.Start;
    try
      DB.ExecSQL('DELETE FROM Author_List WHERE BookID=?',[IDs[6]]);
      DB.ExecSQL('DELETE FROM Genre_List WHERE BookID=?',[IDs[6]]);
      DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) SELECT ?,AuthorID FROM Author_List WHERE BookID=?',[IDs[5],IDs[2]]);
      DB.ExecSQL('INSERT INTO Series(SeriesID,SeriesTitle) VALUES(100,''Additional visible series'')');
      DB.ExecSQL('INSERT INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) VALUES(?,100,37,0,1)',[IDs[5]]);
      DB.ExecSQL('INSERT INTO PublisherSeries(SeriesID,SeriesTitle) VALUES(1,''First publisher series''),(2,''Second publisher series'')');
      DB.ExecSQL('INSERT INTO PublisherSeries_List(BookID,SeriesID,SeqNumber,OrdNum) SELECT BookID,1,BookID,1 FROM Books WHERE BookID<>?',[IDs[6]]);
      DB.ExecSQL('INSERT INTO PublisherSeries_List(BookID,SeriesID,SeqNumber,OrdNum) SELECT BookID,2,BookID+20,0 FROM Books WHERE BookID<>?',[IDs[6]]);
      DB.Commit;
    except DB.Rollback; raise; end;
    BeforeHash:=THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName);
    for Mode:=0 to 1 do
    begin
      Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
      Criteria.Deleted:=True; Criteria.CollapseMultiSeriesResults:=Mode=0;
      Iterator:=Collection.Search(Criteria,True); Seen:=0;
      Require(Iterator.RecordCount=4+Mode,'Visible metadata count includes deleted books or loses an expanded series');
      while Iterator.Next(Book) do
      begin
        Inc(Seen);
        Require(not (bpIsDeleted in Book.BookProps),'Visible metadata returned a deleted book');
        Collection.GetBookRecord(Book.BookKey,Expected,True);
        Require((Book.Title=Expected.Title) and (Book.LibID=Expected.LibID) and
          (Book.FileName=Expected.FileName) and (Book.Date=Expected.Date) and
          (Length(Book.Authors)=Length(Expected.Authors)) and
          (Length(Book.Genres)=Length(Expected.Genres)), 'Visible metadata lost or reused book data across a gap');
        for I:=0 to High(Expected.Authors) do
          Require((Book.Authors[I].AuthorID=Expected.Authors[I].AuthorID) and
            (Book.Authors[I].LastName=Expected.Authors[I].LastName), 'Visible metadata shifted coauthors across a deleted book');
        for I:=0 to High(Expected.Genres) do
          Require(Book.Genres[I].GenreCode=Expected.Genres[I].GenreCode,'Visible metadata shifted genres across a deleted book');
        PublisherSeries:=Collection.GetBookPublisherSeries(Book.BookKey);
        Require(Book.PublisherSeriesKnown and (Length(Book.PublisherSeries)=Length(PublisherSeries)),
          'Visible metadata lost publisher series or reused an empty book relationship');
        for I:=0 to High(PublisherSeries) do
          Require((Book.PublisherSeries[I].SeriesID=PublisherSeries[I].SeriesID) and
            (Book.PublisherSeries[I].SeriesTitle=PublisherSeries[I].SeriesTitle) and
            (Book.PublisherSeries[I].SeqNumber=PublisherSeries[I].SeqNumber), 'Visible publisher series order or numbers changed');
        if (Mode=1) and (Book.SeriesID=100) then
          Require((Book.BookKey.BookID=IDs[5]) and (Book.SeqNumber=37), 'Expanded relation changed the owning book')
        else Require((Book.SeriesID=Expected.SeriesID) and (Book.Series=Expected.Series),
          'Visible metadata changed primary series');
      end;
      Require(Seen=4+Mode,'Visible metadata row count changed'); Iterator:=nil;
    end;
    Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName)=BeforeHash,
      'Visible metadata reads changed catalogue bytes');
    Writeln('PASS full visible metadata matches independent lookups across leading middle trailing deleted gaps empty lists coauthors and expanded series');
  finally DB.Free; end;
end;

// Full-list snapshots and both storage-bound fallbacks must preserve ordinary
// joined-query results, including invalid links and a renamed author on reopen.
procedure TestAuthorStreamBounds;
var
  CID, AuthorID, Phase, Kind, Seen: Integer;
  Collection: IBookCollection;
  DB: TSQLiteDatabase;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  Book, Expected: TBookRecord;
  BeforeHash: string;
begin
  CID := SystemDB.CreateCollection('Author stream bounds', Settings.AppPath,
    'author-stream-bounds.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath+'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  AddBook(Collection,'Bound one','Автор границ','ru','Series','0.1');
  AddBook(Collection,'Bound two','Автор границ','ru','Series','0.1');
  DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(CID).DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_FULLNAME',4,EnableScaleFixtureTriggers);
    AuthorID := DB.QuerySingleInt('SELECT MIN(AuthorID) FROM Author_List');
    DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,9999999)');
    for Phase := 0 to 8 do
    begin
      if Phase=1 then
        // An unrelated name exceeds the byte budget. It must stay unmaterialized.
        DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(1000000,CAST(zeroblob(16777217) AS TEXT))');
      if Phase=2 then
      begin
        DB.ExecSQL('DELETE FROM Authors WHERE AuthorID=1000000');
        DB.ExecSQL('WITH RECURSIVE n(x) AS (SELECT 1000 UNION ALL SELECT x+1 FROM n WHERE x<263145) '+
          'INSERT INTO Authors(AuthorID,LastName) SELECT x,''Unused'' FROM n');
      end;
      if Phase=3 then
      begin
        DB.ExecSQL('DELETE FROM Authors WHERE AuthorID BETWEEN 1000 AND 263145');
        DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(4294967297,''Unreferenced wide ID'')');
      end;
      if Phase=4 then
      begin
        DB.ExecSQL('DELETE FROM Authors WHERE AuthorID=4294967297');
        DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(-2147483648,''Низкий ID''),(2147483647,''Высокий ID'')');
        DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,-2147483648),(2,2147483647)');
      end;
      if Phase=5 then
      begin
        DB.ExecSQL('DELETE FROM Author_List WHERE AuthorID IN (-2147483648,2147483647)');
        DB.ExecSQL('DELETE FROM Authors WHERE AuthorID IN (-2147483648,2147483647)');
        DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(-2,''До нуля''),(0,''Нулевой автор''),(4,''После нуля'')');
        DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,-2),(1,0),(2,4),(2,-1)');
      end;
      if Phase in [6,7,8] then
      begin
        DB.ExecSQL('DELETE FROM Author_List');
        DB.ExecSQL('DELETE FROM Authors');
        if Phase=6 then
        begin
          DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(2147483645,''Перед верхней границей''),(2147483647,''Верхняя граница'')');
          DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,2147483645),(1,2147483646),(2,2147483647)');
        end;
        if Phase=7 then
        begin
          DB.ExecSQL('INSERT INTO Authors(AuthorID,LastName) VALUES(-2147483648,''Нижняя граница''),(-2147483646,''После нижней границы'')');
          DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,-2147483648),(1,-2147483647),(2,-2147483646)');
        end;
        if Phase=8 then
          DB.ExecSQL('INSERT INTO Author_List(BookID,AuthorID) VALUES(1,0),(2,2147483647)');
      end;
      DB.ExecSQL('UPDATE Authors SET FirstName=? WHERE AuthorID=?',['Ёж 😀 '+IntToStr(Phase),AuthorID]);
      BeforeHash := THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName);
      for Kind := 0 to 1 do
      begin
        Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
        Criteria.Deleted := True; Criteria.CollapseMultiSeriesResults := True;
        if Kind=0 then Iterator := Collection.GetBookIterator(bmAll,False)
        else Iterator := Collection.Search(Criteria,False);
        Require(Iterator.RecordCount=2,'Author stream bounds changed the book count'); Seen:=0;
        while Iterator.Next(Book) do
        begin
          Inc(Seen); Collection.GetBookRecord(Book.BookKey,Expected,False);
          Require(Length(Book.Authors)=Length(Expected.Authors),
            'Author snapshot or bounded fallback created or lost an author');
          for var Position:=0 to High(Book.Authors) do
            Require((Book.Authors[Position].AuthorID=Expected.Authors[Position].AuthorID) and
              (Book.Authors[Position].LastName=Expected.Authors[Position].LastName) and
              (Book.Authors[Position].FirstName=Expected.Authors[Position].FirstName) and
              (Book.Authors[Position].MiddleName=Expected.Authors[Position].MiddleName),
              'Author snapshot or bounded fallback lost names, kept stale data or changed order');
        end;
        Require(Seen=2,'Author snapshot or bounded fallback lost a book'); Iterator:=nil;
      end;
      Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(CID).DBFileName)=BeforeHash,
        'Author snapshot or bounded fallback changed catalogue bytes');
      Writeln('PASS full author stream matches independent lookups with dangling links renamed Unicode authors bound=',Phase); Flush(Output);
    end;
  finally DB.Free; end;
end;

// A disposable catalogue exercises the actual first query, not an in-memory iterator.
procedure TestFirstBookList(const LargeOnly: Boolean = False);
var
  Total: Integer;
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
  procedure CheckStoredBook(const Stored, ReadBook: TBookRecord);
  var Index: Integer;
    procedure CheckGenre(const Left, Right: TGenreData);
    begin
      Require((Left.GenreCode=Right.GenreCode) and (Left.ParentCode=Right.ParentCode) and
        (Left.FB2GenreCode=Right.FB2GenreCode) and (Left.GenreAlias=Right.GenreAlias),
        'Stored book lost genre strings after iterator advanced');
    end;
  begin
    Require((Stored.nodeType=ReadBook.nodeType) and Stored.BookKey.IsSameAs(ReadBook.BookKey) and
      (Stored.SeriesID=ReadBook.SeriesID) and (Stored.Title=ReadBook.Title) and
      (Stored.Series=ReadBook.Series) and (Stored.CollectionName=ReadBook.CollectionName) and
      (Stored.Lang=ReadBook.Lang) and (Stored.Size=ReadBook.Size) and (Stored.Rate=ReadBook.Rate) and
      (Stored.SeqNumber=ReadBook.SeqNumber) and (Stored.Progress=ReadBook.Progress) and
      (Stored.LibRate=ReadBook.LibRate) and (Stored.BookProps=ReadBook.BookProps) and
      (Stored.Date=ReadBook.Date) and (Stored.FileExt=ReadBook.FileExt) and
      (Stored.FileName=ReadBook.FileName) and (Stored.LibID=ReadBook.LibID) and
      (Stored.Folder=ReadBook.Folder) and (Stored.InsideNo=ReadBook.InsideNo) and
      (Stored.KeyWords=ReadBook.KeyWords) and (Stored.CollectionRoot=ReadBook.CollectionRoot) and
      (Stored.Annotation=ReadBook.Annotation) and (Stored.Review=ReadBook.Review) and
      (Stored.Translators=ReadBook.Translators) and (Stored.Publisher=ReadBook.Publisher) and
      (Stored.City=ReadBook.City) and (Stored.PubYear=ReadBook.PubYear) and
      (Stored.ISBN=ReadBook.ISBN) and (Stored.PublisherSeriesKnown=ReadBook.PublisherSeriesKnown) and
      (Stored.PublisherSeqNumber=ReadBook.PublisherSeqNumber),
      'Stored book fields changed after the original iterator and temporary record were released');
    CheckGenre(Stored.RootGenre,ReadBook.RootGenre);
    Require((Length(Stored.Authors)=Length(ReadBook.Authors)) and
      (Length(Stored.Genres)=Length(ReadBook.Genres)) and
      (Length(Stored.PublisherSeries)=Length(ReadBook.PublisherSeries)),
      'Stored book array lifetime changed after iterator release');
    for Index:=0 to High(Stored.Authors) do
      Require((Stored.Authors[Index].AuthorID=ReadBook.Authors[Index].AuthorID) and
        (Stored.Authors[Index].FirstName=ReadBook.Authors[Index].FirstName) and
        (Stored.Authors[Index].MiddleName=ReadBook.Authors[Index].MiddleName) and
        (Stored.Authors[Index].LastName=ReadBook.Authors[Index].LastName),
        'Stored book authors changed after iterator release');
    for Index:=0 to High(Stored.Genres) do CheckGenre(Stored.Genres[Index],ReadBook.Genres[Index]);
    for Index:=0 to High(Stored.PublisherSeries) do
      Require((Stored.PublisherSeries[Index].SeriesID=ReadBook.PublisherSeries[Index].SeriesID) and
        (Stored.PublisherSeries[Index].SeriesTitle=ReadBook.PublisherSeries[Index].SeriesTitle) and
        (Stored.PublisherSeries[Index].SeqNumber=ReadBook.PublisherSeries[Index].SeqNumber) and
        (Stored.PublisherSeries[Index].IsPrimary=ReadBook.PublisherSeries[Index].IsPrimary),
        'Stored book publisher series changed after iterator release');
  end;
begin
  if not LargeOnly then
  begin TestBookDisplayNames; TestSQLiteDateDecoding; TestStreamAuthorOrder; TestVisibleMetadataStreams; TestAuthorStreamBounds; end;
  Total:=60000;
  if LargeOnly then Total:=1500000;
  DB := TSQLiteDatabase.Create(':memory:');
  try
    var TextCache := Default(TSQLiteTextCache);
    for var Value in TArray<string>.Create('', 'Кириллица ё ї ў — 😀 中文',
      'Кириллица ё ї ў — 😀 中文', 'Другое значение', '', StringOfChar('Ж', 200000), 'Короткое') do
    begin
      var Query := DB.NewQuery('SELECT ?,NULL,-1234567890123,CAST(12.5 AS REAL)');
      try
        Query.SetParam(0,Value); Query.Open;
        Require(not Query.FieldIsNull(0) and Query.FieldIsNull(1) and
          not Query.FieldIsNull(2) and not Query.FieldIsNull(3),
          'NULL checks changed empty text or numeric fields before decoding');
        Require((Query.FieldAsString(0) = Value) and not Query.FieldIsNull(0) and
          Query.FieldIsNull(1) and (Query.FieldAsString(1) = '') and
          (Query.FieldAsString(2) = '-1234567890123') and (Query.FieldAsString(3) = '12.5'),
          'Direct UTF8 fields changed NULL empty Unicode long or numeric values');
        Require(Query.FieldAsSharedString(0,TextCache) = Value,
          'Repeated UTF8 field changed Unicode, empty or oversized text');
        var Edited := Query.FieldAsSharedString(0,TextCache);
        if Edited <> '' then Edited[1] := '#';
        Require(Query.FieldAsSharedString(0,TextCache) = Value,
          'Editing a returned string changed the cached catalogue field');
        Require(Query.FieldAsSharedString(1,TextCache) = '', 'Shared field changed SQL NULL');
        Require(Query.FieldAsSharedString(2,TextCache) = '-1234567890123', 'Shared field changed numeric text');
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
      DB.ExecSQL('UPDATE Books SET Annotation=''Аннотация с иллюстрациями 😀 中文'',KeyWords=''ключевые слова ё'' WHERE BookID=1');
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
    // Count prepared statements; per-row step timing is unnecessary here.
    StartSQLiteProfile(False);
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
    // Compare the actual UI rows with an independent fresh query, including
    // expanded-series duplicates and a final partial allocation group.
    Iterator := Factory();
    var Row := frmMain.tvBooksSR.GetFirst;
    var RowCount := 0;
    while Iterator.Next(Book) do
    begin
      Require(Assigned(Row), 'Actual first-list tree ended before the query');
      var RowData := PBookRecord(frmMain.tvBooksSR.GetNodeData(Row));
      Require((RowData.NodeType = ntBookInfo) and
        RowData.BookKey.IsSameAs(Book.BookKey) and (RowData.SeriesID = Book.SeriesID) and
        (RowData.SeqNumber = Book.SeqNumber) and (RowData.Title = Book.Title) and
        (RowData.ListOrder = RowCount), 'Actual first-list row order or metadata changed');
      CheckStoredBook(RowData^,Book);
      Inc(RowCount); Row := frmMain.tvBooksSR.GetNext(Row);
    end;
    Require((Row = nil) and (RowCount = Expected), 'Actual first-list tree retained empty or extra rows');
    Iterator := nil;
    if LargeOnly then Break;
  end;
  Writeln('PASS first-list stored book strings nested arrays scalars survive iterator release rebuild expanded series and fresh-query comparison');
  if not LargeOnly then
  begin
    Kind := 0; Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
    Criteria.Deleted := True; Criteria.CollapseMultiSeriesResults := True;
    var Languages := TComboBox.Create(nil);
    try
      Languages.Parent := frmMain; Languages.Visible := False;
      Languages.Items.Add('en'); Languages.ItemIndex := 0;
      frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, Factory, True, True, nil);
      Require(frmMain.tvBooksSR.GetFirst = nil, 'Language exclusion retained an empty list row');
      Languages.ItemIndex := Languages.Items.IndexOf('ru');
      Require(Languages.ItemIndex >= 0, 'Excluded source language was not registered');
      var Selection := Default(TBookKey); Selection.DatabaseID := ID; Selection.BookID := 2;
      frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, Factory, True, True, @Selection);
      var Selected := frmMain.tvBooksSR.FocusedNode;
      Require(Assigned(Selected) and PBookRecord(frmMain.tvBooksSR.GetNodeData(Selected)).BookKey.IsSameAs(Selection),
        'Reload after language exclusion lost the requested book focus');
      Writeln('PASS flat first-list language exclusion leaves no blank rows and reload restores book focus');
    finally Languages.Free; end;
  end;
  if not LargeOnly then
  begin
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
  Kind:=3; Filter.ValueInt:=1;
  frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Factory,True,True,nil);
  Iterator:=Factory();
  var MemoRow:=frmMain.tvBooksSR.GetFirst;
  for var MemoIndex:=1 to 3 do
  begin
    Require(Iterator.Next(Book) and Assigned(MemoRow),'Memo ownership fixture ended early');
    CheckStoredBook(PBookRecord(frmMain.tvBooksSR.GetNodeData(MemoRow))^,Book);
    if MemoIndex=1 then Require((Book.Review='Личный отзыв') and
      (Book.Annotation='Аннотация с иллюстрациями 😀 中文') and (Book.KeyWords='ключевые слова ё'),
      'Stored-book memo fixture did not exercise populated Unicode fields');
    MemoRow:=frmMain.tvBooksSR.GetNext(MemoRow);
  end;
  Iterator:=nil;
  frmMain.tvBooksSR.Clear;
  Writeln('PASS first-list stored Unicode annotation review keywords survive iterator destruction and tree clear');
  Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(ID).DBFileName) = BeforeHash,
    'First-list reads modified catalogue or personal data');
  end;
  // The reported path: a fresh Search view, all fields empty, only hide-deleted.
  ShowPage(PAGE_SEARCH);
  var CollectionItem := TMenuItem.Create(nil);
  try CollectionItem.Tag := ID; frmMain.miActiveCollectionClick(CollectionItem);
  finally CollectionItem.Free; end;
  frmMain.DoClearFilter(False);
  frmMain.cbDeleted.Checked := True;
  frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
  frmMain.cbCollapseMultiSeriesResults.Checked := True;
  StartSQLiteProfile(False);
  Started := GetTickCount64;
  frmMain.DoApplyFilter(nil);
  var AppliedMS := GetTickCount64 - Started;
  SaveSQLiteProfile(Settings.AppPath + 'first-list-apply.tsv');
  StopSQLiteProfile;
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
  Writeln('PROFILE first-list actual empty-fields hide-deleted Apply ms=',AppliedMS,' rows=',Seen);
  Writeln('PASS first-list actual queries preserve compact expanded deleted metadata counts and source bytes');
end;
