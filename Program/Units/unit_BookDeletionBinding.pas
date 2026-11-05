unit unit_BookDeletionBinding;

interface

uses System.SysUtils, System.Classes, unit_Globals, unit_Interfaces;

type
  // Only source identity is persisted, never annotations or a complete book
  // snapshot. Interpret it only on the thread that owns the database connection.
  TBookDeletionBinding = record
  private
    FCatalogueFile, FCatalogueKey: string;
    FCollectionID: Integer;
    FRemoveRecords: Boolean;
    FBooks: TArray<TBookRecord>;
    procedure Validate;
    function OpenCapturedCollection(const User: ISystemData): IBookCollection;
  public
    class function Capture(const Info: TCollectionInfo; const Books: TArray<TBookRecord>;
      RemoveRecords: Boolean): TBookDeletionBinding; static;
    class function Parse(const JSON: string): TBookDeletionBinding; static;
    function ToJSON: string;
    procedure CheckBeforePhysicalRemoval(const User: ISystemData);
    function CommitRecords(const User: ISystemData): Integer;
    function CommitSourceMissing(const User: ISystemData): Integer;
    function ExpectedBooks: TArray<TBookRecord>;
    function Slice(const Indices: TArray<Integer>): TBookDeletionBinding;
    property CollectionID: Integer read FCollectionID;
    property RemoveRecords: Boolean read FRemoveRecords;
  end;

implementation

uses System.JSON, System.IOUtils, System.Generics.Collections,
  unit_ReaderCache, unit_ZipMemberDeletion;

function Text(Obj: TJSONObject; const Name: string): string;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONString) then raise EReadError.Create('Повреждены сведения о книге в журнале удаления.');
  Result:=Value.Value;
end;

function PositiveNumber(Obj: TJSONObject; const Name: string): Integer;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONNumber) or not TryStrToInt(Value.Value,Result) or (Result<=0) then
    raise EReadError.Create('Неверный номер записи в журнале удаления.');
end;

procedure TBookDeletionBinding.Validate;
var Seen: TDictionary<Integer,Byte>;
begin
  if (FCollectionID<=0) or (FCatalogueFile='') or (Length(FCatalogueKey)<>25) or
    (Length(FBooks)=0) or (Length(FBooks)>100000) then
    raise EReadError.Create('Неполная привязка удаления к коллекции.');
  if FCatalogueFile<>ExpandFileName(FCatalogueFile) then
    raise EReadError.Create('В журнале удаления нужен полный путь каталога.');
  Seen:=TDictionary<Integer,Byte>.Create;
  try
    for var Book in FBooks do
    begin
      if (Book.BookKey.DatabaseID<>FCollectionID) or (Book.BookKey.BookID<=0) or
        (ReaderBookPhysicalIdentity(Book)='') or Seen.ContainsKey(Book.BookKey.BookID) then
        raise EReadError.Create('Список удаления содержит чужую или повторную запись книги.');
      Seen.Add(Book.BookKey.BookID,0);
    end;
  finally Seen.Free; end;
end;

class function TBookDeletionBinding.Capture(const Info:TCollectionInfo;
  const Books:TArray<TBookRecord>; RemoveRecords:Boolean):TBookDeletionBinding;
var B:PBookRecord;
begin
  Result:=Default(TBookDeletionBinding);
  Result.FCollectionID:=Info.ID; Result.FRemoveRecords:=RemoveRecords;
  Result.FCatalogueFile:=ExpandFileName(Info.DBFileName);
  // An ordinary record-only command does not need this filesystem receipt.
  // Capture is used only after physical source deletion has been requested.
  Result.FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(Result.FCatalogueFile),1,25);
  SetLength(Result.FBooks,Length(Books));
  for var I:=0 to High(Books) do
  begin
    B:=@Result.FBooks[I]; B^.Clear;
    B^.BookKey:=Books[I].BookKey; B^.LibID:=Books[I].LibID;
    B^.CollectionRoot:=TPath.GetFullPath(Books[I].CollectionRoot);
    B^.Folder:=Books[I].Folder; B^.FileName:=Books[I].FileName;
    B^.FileExt:=Books[I].FileExt; B^.InsideNo:=Books[I].InsideNo;
  end;
  Result.Validate;
end;

function TBookDeletionBinding.ToJSON:string;
var Obj,Item:TJSONObject; Books:TJSONArray;
begin
  Validate; Obj:=TJSONObject.Create;
  try
    Obj.AddPair('schema',TJSONNumber.Create(1));
    Obj.AddPair('collection',TJSONNumber.Create(FCollectionID));
    Obj.AddPair('catalogueFile',FCatalogueFile); Obj.AddPair('catalogueKey',FCatalogueKey);
    Obj.AddPair('removeRecords',TJSONBool.Create(FRemoveRecords));
    Books:=TJSONArray.Create; Obj.AddPair('books',Books);
    for var Book in FBooks do
    begin
      Item:=TJSONObject.Create; Books.AddElement(Item);
      Item.AddPair('id',TJSONNumber.Create(Book.BookKey.BookID)); Item.AddPair('libId',Book.LibID);
      Item.AddPair('root',Book.CollectionRoot); Item.AddPair('folder',Book.Folder);
      Item.AddPair('name',Book.FileName); Item.AddPair('extension',Book.FileExt);
      Item.AddPair('inside',TJSONNumber.Create(Book.InsideNo));
      Item.AddPair('physical',ReaderBookPhysicalIdentity(Book));
    end;
    Result:=Obj.ToJSON;
    if Length(TEncoding.UTF8.GetBytes(Result))>4*1024*1024 then
      raise EWriteError.Create('Слишком много книг для одного журнала удаления. Выберите меньше книг.');
  finally Obj.Free; end;
end;

class function TBookDeletionBinding.Parse(const JSON:string):TBookDeletionBinding;
var Value:TJSONValue; Obj,Item:TJSONObject; Items:TJSONArray; B:PBookRecord;
begin
  Result:=Default(TBookDeletionBinding);
  if Length(TEncoding.UTF8.GetBytes(JSON))>4*1024*1024 then
    raise EReadError.Create('Слишком большой журнал записей для удаления.');
  Value:=TJSONObject.ParseJSONValue(JSON);
  try
    if not (Value is TJSONObject) then raise EReadError.Create('Повреждена привязка удаления к коллекции.');
    Obj:=TJSONObject(Value);
    if (PositiveNumber(Obj,'schema')<>1) or not (Obj.GetValue('books') is TJSONArray) or
      not (Obj.GetValue('removeRecords') is TJSONBool) then
      raise EReadError.Create('Неподдерживаемый журнал записей для удаления.');
    Result.FCollectionID:=PositiveNumber(Obj,'collection');
    Result.FCatalogueFile:=Text(Obj,'catalogueFile'); Result.FCatalogueKey:=Text(Obj,'catalogueKey');
    Result.FRemoveRecords:=TJSONBool(Obj.GetValue('removeRecords')).AsBoolean;
    Items:=TJSONArray(Obj.GetValue('books'));
    if Items.Count>100000 then raise EReadError.Create('Слишком много записей в журнале удаления.');
    SetLength(Result.FBooks,Items.Count);
    for var I:=0 to Items.Count-1 do
    begin
      if not (Items.Items[I] is TJSONObject) then raise EReadError.Create('Повреждена запись книги в журнале удаления.');
      Item:=TJSONObject(Items.Items[I]); B:=@Result.FBooks[I]; B^.Clear;
      B^.BookKey:=CreateBookKey(PositiveNumber(Item,'id'),Result.FCollectionID);
      B^.LibID:=Text(Item,'libId'); B^.CollectionRoot:=Text(Item,'root');
      B^.Folder:=Text(Item,'folder'); B^.FileName:=Text(Item,'name'); B^.FileExt:=Text(Item,'extension');
      var Inside:=Item.GetValue('inside');
      if not (Inside is TJSONNumber) or not TryStrToInt(Inside.Value,B^.InsideNo) then
        raise EReadError.Create('Повреждён номер файла внутри архива.');
      if (ReaderBookPhysicalIdentity(B^)='') or
        (ReaderBookPhysicalIdentity(B^)<>Text(Item,'physical')) then
        raise EReadError.Create('Путь книги не совпадает с журналом удаления.');
    end;
    Result.Validate;
  finally Value.Free; end;
end;

function TBookDeletionBinding.ExpectedBooks:TArray<TBookRecord>;
begin Result:=Copy(FBooks); end;

function TBookDeletionBinding.Slice(const Indices:TArray<Integer>):TBookDeletionBinding;
var Selected:TArray<TBookRecord>;
begin
  // Validate the resulting slice, not the complete selection for every
  // archive. Capture/Parse already validated the source snapshot.
  SetLength(Selected,Length(Indices));
  for var I:=0 to High(Indices) do
  begin
    if (Indices[I]<0) or (Indices[I]>=Length(FBooks)) then
      raise EArgumentException.Create('Неверная запись книги в плане удаления.');
    Selected[I]:=FBooks[Indices[I]];
  end;
  Result:=Self; Result.FBooks:=Selected; Result.Validate;
end;

function TBookDeletionBinding.OpenCapturedCollection(const User:ISystemData):IBookCollection;
begin
  Validate;
  if not Assigned(User) then raise EInvalidOperation.Create('База коллекций не открыта.');
  var Info:=User.GetCollectionInfo(FCollectionID);
  if (Info.ID<>FCollectionID) or not SameFileName(ExpandFileName(Info.DBFileName),FCatalogueFile) or
    (Copy(ArchiveDeletionSourceIdentity(FCatalogueFile),1,25)<>FCatalogueKey) then
    raise EReadError.Create('Коллекция была заменена. Записи из другой коллекции не удалены.');
  // Do not GetCollection before proving that its existing file is the one
  // captured by the confirmed operation: opening a missing path may create DB.
  Result:=User.GetCollection(FCollectionID);
end;

function MatchesDeletionSource(const Current, Expected:TBookRecord):Boolean;
begin
  Result:=Current.BookKey.IsSameAs(Expected.BookKey) and (Current.LibID=Expected.LibID) and
    (Current.InsideNo=Expected.InsideNo) and (ReaderBookPhysicalIdentity(Expected)<>'') and
    (ReaderBookPhysicalIdentity(Current)=ReaderBookPhysicalIdentity(Expected));
end;

procedure TBookDeletionBinding.CheckBeforePhysicalRemoval(const User:ISystemData);
var Writer:IBookIdentityDeletionWriter; Expected:TBookRecord; Match:TBookIdentityPredicate;
begin
  if not Supports(OpenCapturedCollection(User),IBookIdentityDeletionWriter,Writer) then
    raise EInvalidOperation.Create('Коллекция не поддерживает безопасное удаление файлов.');
  Match:=function(const Current:TBookRecord):Boolean
    begin Result:=MatchesDeletionSource(Current,Expected); end;
  for Expected in FBooks do
    if Writer.DeleteBookIfIdentity(Expected,Match,True)<>bdwReady then
      raise EReadError.Create('Книга или её личная карточка изменилась. Файл не удалён.');
end;

function TBookDeletionBinding.CommitRecords(const User:ISystemData):Integer;
var Collection:IBookCollection; Writer:IBookIdentityDeletionWriter;
  Expected:TBookRecord; Match:TBookIdentityPredicate;
begin
  Result:=0;
  if not FRemoveRecords then raise EInvalidOperation.Create('Этот журнал сохраняет записи в коллекции.');
  Collection:=OpenCapturedCollection(User);
  if not Supports(Collection,IBookIdentityDeletionWriter,Writer) then
    raise EInvalidOperation.Create('Коллекция не поддерживает безопасное завершение удаления.');
  Match:=function(const Current:TBookRecord):Boolean
    begin
      Result:=MatchesDeletionSource(Current,Expected);
    end;
  // Check all identities before the first DB mutation. Each actual write
  // checks again in its own transaction and can be replayed after a failure.
  for Expected in FBooks do
    if not (Writer.DeleteBookIfIdentity(Expected,Match,True) in [bdwReady,bdwMissing]) then
      raise EReadError.Create('Книга или её личная карточка изменилась. Журнал удаления сохранён.');
  for Expected in FBooks do
    case Writer.DeleteBookIfIdentity(Expected,Match) of
      bdwDeleted: Inc(Result);
      bdwMissing: ;
      else raise EReadError.Create('Не удалось завершить удаление записи. Журнал сохранён для продолжения.');
    end;
end;

function TBookDeletionBinding.CommitSourceMissing(const User:ISystemData):Integer;
var Collection:IBookCollection; CheckWriter:IBookIdentityDeletionWriter;
  Writer,PersonalWriter:IBookIdentityPersonalWriter;
  Expected,Changed:TBookRecord; Match:TBookIdentityPredicate;
  State:TBookIdentityWriteResult;
begin
  Result:=0;
  if FRemoveRecords then raise EInvalidOperation.Create('Этот журнал предназначен для удаления записей.');
  Collection:=OpenCapturedCollection(User);
  if not Supports(Collection,IBookIdentityDeletionWriter,CheckWriter) or
    not Supports(Collection,IBookIdentityPersonalWriter,Writer) or
    not Supports(User,IBookIdentityPersonalWriter,PersonalWriter) then
    raise EInvalidOperation.Create('Коллекция не поддерживает безопасное изменение доступности файла.');
  Match:=function(const Current:TBookRecord):Boolean
    begin
      Result:=MatchesDeletionSource(Current,Expected);
    end;
  for Expected in FBooks do
    if not (CheckWriter.DeleteBookIfIdentity(Expected,Match,True) in [bdwReady,bdwMissing]) then
      raise EReadError.Create('Книга или её личная карточка изменилась. Журнал удаления сохранён.');
  for Expected in FBooks do
  begin
    Changed:=Expected; Exclude(Changed.BookProps,bpIsLocal);
    State:=Writer.TrySetIdentityPersonal(Changed,[bpfIsLocal],Match);
    // A catalogue row can have been removed while this confirmed operation
    // was running. Only a still-matching saved card may be updated then.
    if State=biwNoCard then State:=PersonalWriter.TrySetIdentityPersonal(Changed,[bpfIsLocal],Match);
    case State of
      biwSaved: Inc(Result);
      biwNoCard: ;
      else raise EReadError.Create('Не удалось обновить доступность файла. Записи и журнал сохранены.');
    end;
  end;
end;

end.
