procedure TestCatalogAudit(const One, Two: IBookCollection; OneID, TwoID: Integer);
var
  FileName, BeforeFile: string;
  Data: TUserData;
  Criteria: TBookSearchCriteria;
  Titles: TStringList;
  Iterator: IBookIterator;
  Book, Personal: TBookRecord;
  LegacyOneID, LegacyTwoID: Integer;

  procedure LoadText(const Text: string);
  begin
    TFile.WriteAllText(FileName, Text, TEncoding.UTF8);
    LoadOldUserData(FileName, Data);
  end;

  procedure RejectText(const Text, Expected: string);
  var ErrorText: string;
  begin
    Data := TUserData.Create;
    try
      Data.Extras.AddExtra(0, 'existing-id', 4, 60, 'Сохранённая заметка #ё');
      Data.Groups.AddGroup(88, 'Существующая группа').AddBook(0, 'existing-id');
      ErrorText := '';
      try LoadText(Text); except on E: EConvertError do ErrorText := E.Message; end;
      Require(ErrorText.Contains(Expected) and ErrorText.Contains('строка'),
        'Invalid legacy file had no useful line error: ' + ErrorText);
      Require((Data.Extras.Count = 1) and (Data.Extras[0].LibID = 'existing-id') and
        (Data.Extras[0].Review = 'Сохранённая заметка #ё') and (Data.Groups.Count = 1) and
        (Data.Groups[0].Count = 1) and (Data.Groups[0].GroupID = 88),
        'Invalid legacy import exposed partial personal data');
    finally FreeAndNil(Data); end;
  end;

  procedure ExpectSearch(const Collection: IBookCollection; const Query: string;
    const Expected: array of string);
  var Wanted: TStringList;
  begin
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := -1;
    Criteria.CollapseMultiSeriesResults := True;
    Criteria.Title := Query;
    Iterator := Collection.Search(Criteria, False);
    Titles.Clear;
    Require(Iterator.RecordCount = Length(Expected), 'Quoted title count mismatch: ' + Query);
    while Iterator.Next(Book) do Titles.Add(Book.Title);
    Wanted := TStringList.Create;
    try
      for var Title in Expected do Wanted.Add(Title);
      Titles.Sort; Wanted.Sort;
      Require(Titles.Text = Wanted.Text, 'Quoted title results mismatch: ' + Query);
    finally Wanted.Free; end;
    Iterator := nil;
  end;

begin
  RequireIsolatedRegression;
  FileName := TPath.Combine(Settings.AppPath, 'catalog-audit-legacy.mhlud');
  Data := nil;
  Titles := TStringList.Create;
  try
    Data := TUserData.Create;
    LoadText('Старый экспорт HomeLib'#13#10#13#10 +
      '# Группы'#13#10'Первая группа'#13#10'Вторая #группа ё'#13#10#13#10 +
      '# Рейтинги'#13#10'101 5'#13#10#13#10 +
      '# Прочитанное'#13#10'101 100'#13#10 +
      '# Рецензии'#13#10'101 Отзыв #метка ё Unicode'#13#10 +
      '# Избранное'#13#10'101 Вторая #группа ё'#13#10'102');
    Require((Data.Groups.Count = 2) and (Data.Groups[0].GroupName = 'Первая группа') and
      (Data.Groups[0].Count = 0) and (Data.Groups[1].GroupName = 'Вторая #группа ё') and
      (Data.Groups[1].Count = 2) and (Data.Groups[1][0].LibID = '101') and
      (Data.Groups[1][1].LibID = '102'), 'Legacy named or historical bare group membership changed');
    Require((Data.Extras.Count = 3) and (Data.Extras[0].Rating = 5) and
      (Data.Extras[1].Progress = 100) and (Data.Extras[2].Review = 'Отзыв #метка ё Unicode'),
      'Legacy values, section boundaries or hashtag review lost');
    BeforeFile := THashSHA2.GetHashStringFromFile(FileName);
    FreeAndNil(Data);
    Data := TUserData.Create;
    LoadOldUserData(FileName, Data);
    Require(THashSHA2.GetHashStringFromFile(FileName) = BeforeFile, 'Legacy source was modified');
    FreeAndNil(Data);
    Writeln('PASS catalog audit legacy headers, blanks, Unicode, hashtag reviews and historical groups preserve source bytes');

    Data := TUserData.Create;
    LoadText('# Группы'#13#10'Единственная группа');
    Require((Data.Groups.Count = 1) and (Data.Groups[0].GroupName = 'Единственная группа'),
      'Legacy final group requires a following section');
    FreeAndNil(Data);
    Data := TUserData.Create;
    LoadText('# Рейтинги'#13#10'101 3');
    Require((Data.Extras.Count = 1) and (Data.Extras[0].Rating = 3),
      'Legacy final rating requires a following section');
    FreeAndNil(Data);
    Data := TUserData.Create;
    LoadText('prelude'#13#10#13#10'# Неизвестное'#13#10'future value'#13#10'# Рецензии'#13#10'1 #сохранено');
    Require((Data.Extras.Count = 1) and (Data.Extras[0].Review = '#сохранено'),
      'Legacy unknown section or inline hashtag blocked subsequent valid values');
    FreeAndNil(Data);
    RejectText('# Рейтинги'#13#10'101 5'#13#10'102 not-a-number', 'числовое');
    RejectText('# Группы'#13#10'Группа'#13#10'# Избранное'#13#10'101 Нет такой группы', 'неизвестная группа');
    RejectText('# Группы'#13#10'Группа'#13#10'# Избранное'#13#10'101', 'вторая группа');
    RejectText('# Группы'#13#10'Группа'#13#10'Группа', 'повторяется');
    Writeln('PASS catalog audit legacy EOF and invalid late rows complete without partial personal data');

    LegacyOneID := AddBook(One, 'catalog-audit-personal-id', 'Legacy audit', 'ru', '', '0.1');
    LegacyTwoID := AddBook(Two, 'catalog-audit-personal-id', 'Legacy audit', 'ru', '', '0.1');
    One.AddBookToGroup(CreateBookKey(LegacyOneID, OneID), FAVORITES_GROUP_ID);
    Two.AddBookToGroup(CreateBookKey(LegacyTwoID, TwoID), FAVORITES_GROUP_ID);
    One.SetRate(CreateBookKey(LegacyOneID, OneID), 2);
    One.SetProgress(CreateBookKey(LegacyOneID, OneID), 42);
    One.SetReview(CreateBookKey(LegacyOneID, OneID), 'Прежний отзыв');
    Two.SetRate(CreateBookKey(LegacyTwoID, TwoID), 3);
    Two.SetProgress(CreateBookKey(LegacyTwoID, TwoID), 55);
    Two.SetReview(CreateBookKey(LegacyTwoID, TwoID), 'Другая коллекция #ё');
    Data := TUserData.Create;
    LoadText('# Группы'#13#10'Audit #группа ё'#13#10 +
      '# Рейтинги'#13#10'catalog-audit-personal-id 5'#13#10 +
      '# Прочитанное'#13#10'catalog-audit-personal-id 100'#13#10 +
      '# Рецензии'#13#10'catalog-audit-personal-id Новый отзыв #метка ё'#13#10 +
      '# Избранное'#13#10'catalog-audit-personal-id Audit #группа ё');
    One.ImportUserData(Data, nil);
    One.GetBookRecord(CreateBookKey(LegacyOneID, OneID), Book, True);
    SystemDB.GetBookRecord(Book.BookKey, Personal);
    Require((Book.Rate = 5) and (Book.Progress = 100) and
      (One.GetReview(Book.BookKey) = 'Новый отзыв #метка ё') and
      (Personal.Rate = Book.Rate) and (Personal.Progress = Book.Progress) and
      (SystemDB.GetReview(Book.BookKey) = 'Новый отзыв #метка ё'),
      'Legacy separate sections disagree between catalog and personal card');
    Iterator := SystemDB.GetBookIterator(Data.Groups[0].GroupID, OneID);
    Require((Iterator.RecordCount = 1) and Iterator.Next(Book) and
      (Book.BookKey.BookID = LegacyOneID) and (Book.BookKey.DatabaseID = OneID),
      'Legacy named group did not resolve the actual book in the requested collection');
    Iterator := nil;
    FreeAndNil(Data);
    Data := TUserData.Create;
    LoadText('# Рейтинги'#13#10'catalog-audit-personal-id 4');
    One.ImportUserData(Data, nil);
    One.GetBookRecord(CreateBookKey(LegacyOneID, OneID), Book, True);
    SystemDB.GetBookRecord(Book.BookKey, Personal);
    Require((Book.Rate = 4) and (Book.Progress = 100) and
      (Personal.Rate = 4) and (Personal.Progress = 100) and
      (SystemDB.GetReview(Book.BookKey) = 'Новый отзыв #метка ё'),
      'A rating-only import erased existing progress or review');
    Two.GetBookRecord(CreateBookKey(LegacyTwoID, TwoID), Book, True);
    SystemDB.GetBookRecord(Book.BookKey, Personal);
    Require((Book.Rate = 3) and (Book.Progress = 55) and
      (Personal.Rate = 3) and (Personal.Progress = 55) and
      (SystemDB.GetReview(Book.BookKey) = 'Другая коллекция #ё'),
      'User data import changed another collection with the same library ID');
    FreeAndNil(Data);
    Writeln('PASS catalog audit actual legacy import preserves catalog and personal cards, named groups and a second collection');

    AddBook(One, 'Audit A > B', 'Audit search', 'ru', '', '0.1');
    AddBook(One, 'Audit A = B', 'Audit search', 'ru', '', '0.1');
    AddBook(One, 'Audit I LIKE SQL', 'Audit search', 'ru', '', '0.1');
    AddBook(One, 'Audit O''Reilly > SQL', 'Audit search', 'ru', '', '0.1');
    AddBook(One, 'Audit double "quote" < SQL', 'Audit search', 'ru', '', '0.1');
    AddBook(Two, 'Audit A > B', 'Audit search', 'ru', '', '0.1');
    AddBook(Two, 'Audit other collection', 'Audit search', 'ru', '', '0.1');
    ExpectSearch(One, '="Audit A > B"', ['Audit A > B']);
    ExpectSearch(One, '="Audit A = B"', ['Audit A = B']);
    ExpectSearch(One, 'LIKE "%Audit I LIKE SQL%"', ['Audit I LIKE SQL']);
    ExpectSearch(One, '=''Audit O''''Reilly > SQL''', ['Audit O''Reilly > SQL']);
    ExpectSearch(One, '="Audit double ""quote"" < SQL"', ['Audit double "quote" < SQL']);
    ExpectSearch(One, '(="Audit A > B" OR'#13#10'="Audit A = B")', ['Audit A > B', 'Audit A = B']);
    ExpectSearch(Two, '="Audit A > B"', ['Audit A > B']);
    ExpectSearch(One, '="Audit other collection"', []);
    ExpectSearch(Two, '="Audit other collection"', ['Audit other collection']);
    Writeln('PASS catalog audit quoted comparisons, LIKE, doubled quotes and multiline OR stay literal and collection scoped');
  finally
    Iterator := nil;
    Titles.Free;
    Data.Free;
  end;
end;
