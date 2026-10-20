procedure TestFeedback529Series;
var C: IBookCollection; ID, BookID, BeforeCount: Integer; Plan: TSeriesAliasPlan;
  DB: TSQLiteDatabase; FileName, Backup: string; Book: TBookRecord; Rejected: Boolean;
  function Add(const Title, Author, Series, LibID: string;
    const Lang: string = 'ru'; const Ext: string = '.fb2'): Integer;
  var Value: TBookRecord;
  begin
    Value:=Default(TBookRecord); Value.Title:=Title; Value.Series:=Series;
    Value.FileName:=Title; Value.FileExt:=Ext; Value.LibID:=LibID;
    Value.Lang:=Lang; Value.Size:=100; Include(Value.BookProps,bpIsLocal);
    TAuthorsHelper.Add(Value.Authors,Author,'','');
    Result:=C.InsertBook(Value,False,False);
  end;
  function Scalar(const SQL: string): Integer;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(FileName);
    try Result:=DB.QuerySingleInt(SQL); finally DB.Free; end;
  end;
begin
  ID:=SystemDB.CreateCollection('Feedback529 aliases',Settings.AppPath,
    'feedback529-series.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(ID);
  FileName:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  C.BeginBulkOperation;
  try
    Add('Изменённое название','Автор','Академия для всех','flibusta:660063');
    Add('Старое название [litres]','Автор','академия для всех[p]','merged:{first}:flibusta:660063');
    Add('Книга ЗАВР','Автор','Академия З.А.В.Р.','flibusta:101');
    Add('Книга ЗАВР','Автор','Академия З.А.В.Р.[[p]]','merged:{second}:flibusta:101');
    Add('Изумруд','Автор','Академия Изумруд (Межавторский цикл)','flibusta:202');
    Add('Изумруд','Автор','Академия Изумруд (Межавторский цикл)[m]','merged:{first}:flibusta:202');
    Add('Изумруд','Автор','Академия Изумруд [Межавторский цикл]','merged:{second}:flibusta:202');
    Add('Одна книга','Автор','Ложное совпадение','flibusta:303');
    Add('Другая книга','Автор','Ложное совпадение[p]','flibusta:404');
    Add('Книга из Флибусты','Автор','Разные библиотеки','flibusta:700');
    Add('Другая книга из Либрусека','Автор','Разные библиотеки[m]','librusec:700');
    Add('Первая авторская','Автор','Авторский цикл','unknown-one');
    Add('Вторая авторская','Автор','Авторский цикл[a]','unknown-two');
    Add('Одинаковая книга','Автор','Разные пометки [Гром]','flibusta:800');
    Add('Одинаковая книга','Автор','Разные пометки [Мед]','flibusta:800');
    Add('Одинаковая книга между библиотеками','Автор','Общий цикл','flibusta:810');
    Add('Одинаковая книга между библиотеками','Автор','Общий цикл[m]','librusec:820');
    Add('Совпадает только название','Первый автор','Разные авторы','flibusta:830');
    Add('Совпадает только название','Второй автор','Разные авторы[m]','librusec:840');
    Add('Одна книга другого формата','Автор','Разные форматы','flibusta:850');
    Add('Одна книга другого формата','Автор','Разные форматы[p]','flibusta:850','ru','.epub');
    BookID:=Add('Общая запись','Автор','Общая запись цикла','same-record');
    C.AddBookSeries(BookID,'Общая запись цикла[m]',1);
    Add('Первая в цепочке','Автор','Цепочка','flibusta:860');
    Add('Первая в цепочке','Автор','Цепочка[p]','merged:{first}:flibusta:860');
    Add('Вторая в цепочке','Автор','Цепочка[p]','flibusta:870');
    Add('Вторая в цепочке','Автор','Цепочка[m]','merged:{second}:flibusta:870');
    C.EndBulkOperation(True);
  except if C.InBulkOperation then C.EndBulkOperation(False); raise; end;
  C.SetRate(CreateBookKey(BookID,ID),4); C.SetProgress(CreateBookKey(BookID,ID),37);
  C.AddBookToGroup(CreateBookKey(BookID,ID),FAVORITES_GROUP_ID);
  BeforeCount:=Scalar('SELECT COUNT(*) FROM Books');
  Plan:=TSeriesAliasPlan.Create(C,SystemDB);
  try
    Plan.Preview(nil);
    if Plan.Count<>9 then Writeln(Plan.Report.Text);
    Require(Plan.Count=9,'Verified publisher/mixed/bracket aliases missed, or unrelated cycles included: '+IntToStr(Plan.Count));
    Require((Scalar('SELECT COUNT(*) FROM Books')=BeforeCount) and
      (Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle=''Академия для всех[p]''')=1),
      'Series preview changed catalog records');
    Backup:=Settings.AppPath+'feedback529-series-backup'; Plan.Apply(Backup,nil,nil);
    Require((Scalar('SELECT COUNT(*) FROM Books')=BeforeCount) and
      FileExists(Backup+'\destination.hlc2') and FileExists(Backup+'\system.hlc2'),
      'Series merge removed books or omitted backup');
    Require(Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle IN '+
      '(''Академия для всех[p]'',''Академия З.А.В.Р.[[p]]'',''Академия Изумруд (Межавторский цикл)[m]'',''Академия Изумруд [Межавторский цикл]'',''Цепочка[p]'',''Цепочка[m]'')')=0,
      'Reported duplicate series or transitive aliases remain');
    Require(Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle IN '+
      '(''Ложное совпадение[p]'',''Разные библиотеки[m]'',''Разные авторы[m]'',''Разные форматы[p]'',''Разные пометки [Гром]'',''Разные пометки [Мед]'')')=6,
      'Unverified cycles, colliding library IDs, formats or meaningful labels merged');
    C.GetBookRecord(CreateBookKey(BookID,ID),Book,False);
    Require((Book.Rate=4) and (Book.Progress=37) and (Length(C.GetBookSeries(Book.BookKey))=1),
      'Alias merge lost personal fields or duplicated the same membership');
    SystemDB.GetBookRecord(Book.BookKey,Book);
    Require((Book.Rate=4) and (Book.Series='Общая запись цикла'), 'Grouped book card was not preserved');
    Plan.Preview(nil); Require(Plan.Count=0,'Verified aliases are not idempotent');
    Rejected:=False;
    try Plan.Preview(function: Boolean begin Result:=True; end);
    except on E:EAbort do Rejected:=True; end;
    Require(Rejected,'Series preview ignored cancellation');
    Add('После отмены','Автор','Новая серия','flibusta:880'); Rejected:=False;
    try Plan.Apply(Settings.AppPath+'feedback529-unreviewed',nil,nil);
    except on E:Exception do Rejected:=True; end;
    Require(Rejected,'Cancelled/unreviewed series plan could be applied');
  finally Plan.Free; C:=nil; end;
  Writeln('PASS feedback529 verified publisher/mixed/bracket and transitive series aliases; unrelated cycles, formats, library collisions, personal cards, backup and cancellation');
end;
