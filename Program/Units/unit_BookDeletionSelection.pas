unit unit_BookDeletionSelection;

interface

uses System.Classes, System.SysUtils, unit_CollectionWorkerThread, unit_Globals,
  unit_BookDeletionBinding, SQLiteWrap;

type
  TBookDeletionSelector = record
    ID: Integer;
    Name: string;
  end;

  TBookDeletionSelection = class(TCollectionWorker)
  private
    FMode: TBookIteratorMode;
    FSelectors: TArray<TBookDeletionSelector>;
    FCatalogueFile, FCatalogueKey: string;
    FRemoveRecords: Boolean;
    FBinding: TBookDeletionBinding;
    procedure CheckSelector(DB:TSQLiteDatabase; const Selector: TBookDeletionSelector);
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const Info: TCollectionInfo; Mode: TBookIteratorMode;
      const Selectors: TArray<TBookDeletionSelector>; RemoveRecords: Boolean);
    property Binding: TBookDeletionBinding read FBinding;
  end;

implementation

uses System.IOUtils, System.Generics.Collections, Vcl.ComCtrls,
  unit_Interfaces, unit_ZipMemberDeletion;

constructor TBookDeletionSelection.Create(const Info:TCollectionInfo; Mode:TBookIteratorMode;
  const Selectors:TArray<TBookDeletionSelector>; RemoveRecords:Boolean);
begin
  inherited Create(Info.ID);
  if not (Mode in [bmByAuthor,bmBySeries,bmByPublisherSeries]) or
    (Length(Selectors)=0) or (Length(Selectors)>1024) then
    raise EArgumentException.Create('Выберите от 1 до 1024 авторов или серий.');
  FMode:=Mode; FRemoveRecords:=RemoveRecords; FSelectors:=Copy(Selectors);
  FCatalogueFile:=ExpandFileName(Info.DBFileName);
  FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(FCatalogueFile),1,25);
  for var Selector in FSelectors do
    if (Selector.ID<=0) or (Selector.Name='') then
      raise EArgumentException.Create('Выберите автора или названную серию.');
end;

procedure TBookDeletionSelection.CheckSelector(DB:TSQLiteDatabase; const Selector:TBookDeletionSelector);
var Query:TSQLiteQuery; CurrentName,SQL:string;
begin
  case FMode of
    bmByAuthor: SQL:='SELECT LastName,FirstName,MiddleName FROM Authors WHERE AuthorID=?';
    bmBySeries: SQL:='SELECT SeriesTitle FROM Series WHERE SeriesID=?';
    bmByPublisherSeries: SQL:='SELECT SeriesTitle FROM PublisherSeries WHERE SeriesID=?';
  end;
  Query:=DB.NewQuery(SQL);
  try
    Query.SetParam(0,Selector.ID); Query.Open;
    if Query.Eof then raise EReadError.Create('Автор или серия изменились. Повторите выбор.');
    if FMode=bmByAuthor then
    begin
      var Author:TAuthorData; Author.Clear;
      Author.LastName:=Query.FieldAsString(0); Author.FirstName:=Query.FieldAsString(1);
      Author.MiddleName:=Query.FieldAsString(2); CurrentName:=Author.GetFullName;
    end
    else CurrentName:=Query.FieldAsString(0);
    if CurrentName<>Selector.Name then
      raise EReadError.Create('Автор или серия изменились. Повторите выбор.');
  finally Query.Free; end;
end;

procedure TBookDeletionSelection.WorkFunction;
var Books:TList<TBookRecord>; Seen:TDictionary<Integer,Byte>; Iterator:IBookIterator;
  Book:TBookRecord; Filter:TFilterValue;
begin
  SetProgressHint(pbstMarquee); SetComment('Подготовка списка книг. Файлы не изменяются…');
  var Info:=FSystemData.GetCollectionInfo(FCollectionID);
  if not SameFileName(ExpandFileName(Info.DBFileName),FCatalogueFile) or
    (Copy(ArchiveDeletionSourceIdentity(FCatalogueFile),1,25)<>FCatalogueKey) then
    raise EReadError.Create('Коллекция была заменена. Повторите выбор авторов или серий.');
  // This collection belongs to this read worker, not the visible Main view.
  FCollection.SetHideDeleted(False); FCollection.SetShowLocalOnly(not FRemoveRecords);
  // View iterators write temporary match rows. Observe only committed
  // catalogue changes from a separate read-only connection.
  var Observer:=TSQLiteDatabase.CreateReadOnly(FCatalogueFile);
  Books:=nil; Seen:=nil;
  try
    var Revision:=Observer.QuerySingleInt('PRAGMA main.data_version');
    Books:=TList<TBookRecord>.Create; Seen:=TDictionary<Integer,Byte>.Create;
    for var I:=0 to High(FSelectors) do
    begin
      if Canceled then Abort;
      CheckSelector(Observer,FSelectors[I]); Filter.ValueInt:=FSelectors[I].ID;
      Iterator:=FCollection.GetBookIterator(FMode,False,@Filter);
      while Iterator.Next(Book) do
      begin
        if Canceled then Abort;
        if Book.BookKey.DatabaseID<>FCollectionID then
          raise EReadError.Create('Получена книга из другой коллекции. Удаление не началось.');
        if Seen.ContainsKey(Book.BookKey.BookID) then Continue;
        if Books.Count>=100000 then
          raise EReadError.Create('В выборе больше 100000 книг. Выберите меньше авторов или серий.');
        Seen.Add(Book.BookKey.BookID,0); Books.Add(Book);
        if Books.Count mod 100=0 then SetComment(Format('Найдено книг: %d',[Books.Count]));
      end;
      Iterator:=nil;
      SetComment(Format('Найдено книг: %d · проверено авторов или серий: %d из %d',
        [Books.Count,I+1,Length(FSelectors)]));
    end;
    if Canceled then Abort;
    if (Revision<>Observer.QuerySingleInt('PRAGMA main.data_version')) or
      (Copy(ArchiveDeletionSourceIdentity(FCatalogueFile),1,25)<>FCatalogueKey) then
      raise EReadError.Create('Каталог изменился во время подготовки списка. Повторите выбор.');
    if Books.Count>0 then FBinding:=TBookDeletionBinding.Capture(Info,Books.ToArray,FRemoveRecords);
    FOperationSuccess:=True;
  finally Iterator:=nil; Seen.Free; Books.Free; Observer.Free; end;
end;

end.
