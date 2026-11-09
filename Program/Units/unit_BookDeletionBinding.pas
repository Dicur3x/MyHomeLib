unit unit_BookDeletionBinding;

interface

uses System.SysUtils, System.Classes, unit_Globals, unit_Interfaces;

const MAX_BOOK_DELETION_BINDING = 100000;

type
  // Only source identity is persisted, never annotations or a complete book
  // snapshot. Interpret it only on the thread that owns the database connection.
  TBookDeletionBinding = record
  private
    FCatalogueFile, FCatalogueKey: string;
    FCollectionID: Integer;
    FRemoveRecords: Boolean;
    FBooks: TArray<TBookRecord>;
    FCopyKeys: TArray<string>;
    FPrimaryBooks: TArray<TBookRecord>;
    procedure Validate;
    function CapturedInfo(const User: ISystemData): TCollectionInfo;
    function OpenCapturedCollection(const User: ISystemData): IBookCollection;
    function CheckCopyRows(const User: ISystemData; Commit: Boolean): Integer;
  public
    class function Capture(const Info: TCollectionInfo; const Books: TArray<TBookRecord>;
      RemoveRecords: Boolean): TBookDeletionBinding; static;
    class function CaptureCopies(const Info: TCollectionInfo; const Copies, PrimaryBooks: TArray<TBookRecord>;
      const SourceKeys: TArray<string>): TBookDeletionBinding; static;
    class function Parse(const JSON: string): TBookDeletionBinding; static;
    function ToJSON: string;
    procedure CheckBeforePhysicalRemoval(const User: ISystemData);
    function CommitRecords(const User: ISystemData): Integer;
    function CommitSourceMissing(const User: ISystemData): Integer;
    function CommitCopies(const User: ISystemData): Integer;
    function RemovesCopies: Boolean;
    function SourceKeys: TArray<string>;
    function PrimaryBooks: TArray<TBookRecord>;
    function ExpectedBooks: TArray<TBookRecord>;
    function Slice(const Indices: TArray<Integer>): TBookDeletionBinding;
    property CollectionID: Integer read FCollectionID;
    property RemoveRecords: Boolean read FRemoveRecords;
  end;

  TDuplicateFileDeletion = record
    Removed, Retained: TBookDeletionBinding;
  end;

implementation

uses System.JSON, System.IOUtils, System.Generics.Collections,
  SQLiteWrap, unit_ReaderCache, unit_ZipMemberDeletion;

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

function MatchesDeletionSource(const Current, Expected:TBookRecord):Boolean;
begin
  Result:=Current.BookKey.IsSameAs(Expected.BookKey) and (Current.LibID=Expected.LibID) and
    (Current.InsideNo=Expected.InsideNo) and (ReaderBookPhysicalIdentity(Expected)<>'') and
    (ReaderBookPhysicalIdentity(Current)=ReaderBookPhysicalIdentity(Expected));
end;

function SourceSnapshot(const Book:TBookRecord):TBookRecord;
begin
  Result:=Default(TBookRecord);
  Result.BookKey:=Book.BookKey; Result.LibID:=Book.LibID;
  Result.CollectionRoot:=TPath.GetFullPath(Book.CollectionRoot);
  Result.Folder:=Book.Folder; Result.FileName:=Book.FileName;
  Result.FileExt:=Book.FileExt; Result.InsideNo:=Book.InsideNo;
end;

procedure TBookDeletionBinding.Validate;
var Seen: TDictionary<string,Byte>;
  Key: string;
begin
  if (FCollectionID<=0) or (FCatalogueFile='') or (Length(FCatalogueKey)<>25) or
    (Length(FBooks)=0) or (Length(FBooks)>MAX_BOOK_DELETION_BINDING) then
    raise EReadError.Create('Неполная привязка удаления к коллекции.');
  if FCatalogueFile<>ExpandFileName(FCatalogueFile) then
    raise EReadError.Create('В журнале удаления нужен полный путь каталога.');
  if RemovesCopies and (FRemoveRecords or (Length(FCopyKeys)<>Length(FBooks)) or
    (Length(FPrimaryBooks)<>Length(FBooks))) then
    raise EReadError.Create('Неполная привязка дополнительных копий к коллекции.');
  Seen:=TDictionary<string,Byte>.Create;
  try
    for var I:=0 to High(FBooks) do
    begin
      var Book:=FBooks[I];
      Key:=IntToStr(Book.BookKey.BookID);
      if RemovesCopies then
      begin
        Key:=FCopyKeys[I];
        var Primary:=FPrimaryBooks[I];
        if (Key='') or not Primary.BookKey.IsSameAs(Book.BookKey) or Book.IsLinkedSource or
          (ReaderBookPhysicalIdentity(Primary)='') or
          (ReaderBookPhysicalIdentity(Primary)=ReaderBookPhysicalIdentity(Book)) then
          raise EReadError.Create('В журнале удаления дополнительная копия не отличается от основной.');
      end;
      if (Book.BookKey.DatabaseID<>FCollectionID) or (Book.BookKey.BookID<=0) or
        (ReaderBookPhysicalIdentity(Book)='') or Seen.ContainsKey(Key) then
        raise EReadError.Create('Список удаления содержит чужую или повторную запись книги.');
      Seen.Add(Key,0);
    end;
  finally Seen.Free; end;
end;

class function TBookDeletionBinding.Capture(const Info:TCollectionInfo;
  const Books:TArray<TBookRecord>; RemoveRecords:Boolean):TBookDeletionBinding;
begin
  Result:=Default(TBookDeletionBinding);
  Result.FCollectionID:=Info.ID; Result.FRemoveRecords:=RemoveRecords;
  Result.FCatalogueFile:=ExpandFileName(Info.DBFileName);
  // An ordinary record-only command does not need this filesystem receipt.
  // Capture is used only after physical source deletion has been requested.
  Result.FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(Result.FCatalogueFile),1,25);
  SetLength(Result.FBooks,Length(Books));
  for var I:=0 to High(Books) do
    Result.FBooks[I]:=SourceSnapshot(Books[I]);
  Result.Validate;
end;

class function TBookDeletionBinding.CaptureCopies(const Info: TCollectionInfo;
  const Copies, PrimaryBooks: TArray<TBookRecord>; const SourceKeys: TArray<string>): TBookDeletionBinding;
begin
  Result:=Default(TBookDeletionBinding);
  if (Length(Copies)=0) or (Length(Copies)<>Length(PrimaryBooks)) or
    (Length(Copies)<>Length(SourceKeys)) then
    raise EArgumentException.Create('Нужны точные сведения о дополнительных и основных копиях.');
  Result.FCollectionID:=Info.ID;
  Result.FCatalogueFile:=ExpandFileName(Info.DBFileName);
  Result.FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(Result.FCatalogueFile),1,25);
  Result.FCopyKeys:=Copy(SourceKeys);
  SetLength(Result.FBooks,Length(Copies)); SetLength(Result.FPrimaryBooks,Length(Copies));
  for var I:=0 to High(Copies) do
  begin
    Result.FBooks[I]:=SourceSnapshot(Copies[I]);
    Result.FPrimaryBooks[I]:=SourceSnapshot(PrimaryBooks[I]);
  end;
  Result.Validate;
end;

procedure WriteSource(Item:TJSONObject; const Book:TBookRecord);
begin
  Item.AddPair('id',TJSONNumber.Create(Book.BookKey.BookID)); Item.AddPair('libId',Book.LibID);
  Item.AddPair('root',Book.CollectionRoot); Item.AddPair('folder',Book.Folder);
  Item.AddPair('name',Book.FileName); Item.AddPair('extension',Book.FileExt);
  Item.AddPair('inside',TJSONNumber.Create(Book.InsideNo));
  Item.AddPair('physical',ReaderBookPhysicalIdentity(Book));
end;

function ReadSource(Item:TJSONObject; CollectionID:Integer):TBookRecord;
begin
  Result:=Default(TBookRecord);
  Result.BookKey:=CreateBookKey(PositiveNumber(Item,'id'),CollectionID);
  Result.LibID:=Text(Item,'libId'); Result.CollectionRoot:=Text(Item,'root');
  Result.Folder:=Text(Item,'folder'); Result.FileName:=Text(Item,'name'); Result.FileExt:=Text(Item,'extension');
  var Inside:=Item.GetValue('inside');
  if not (Inside is TJSONNumber) or not TryStrToInt(Inside.Value,Result.InsideNo) then
    raise EReadError.Create('Повреждён номер файла внутри архива.');
  if (ReaderBookPhysicalIdentity(Result)='') or
    (ReaderBookPhysicalIdentity(Result)<>Text(Item,'physical')) then
    raise EReadError.Create('Путь книги не совпадает с журналом удаления.');
end;

function TBookDeletionBinding.ToJSON:string;
var Obj,Item,Primary:TJSONObject; Books:TJSONArray;
begin
  Validate; Obj:=TJSONObject.Create;
  try
    if RemovesCopies then Obj.AddPair('schema',TJSONNumber.Create(2))
    else Obj.AddPair('schema',TJSONNumber.Create(1));
    Obj.AddPair('collection',TJSONNumber.Create(FCollectionID));
    Obj.AddPair('catalogueFile',FCatalogueFile); Obj.AddPair('catalogueKey',FCatalogueKey);
    Obj.AddPair('removeRecords',TJSONBool.Create(FRemoveRecords));
    Books:=TJSONArray.Create; Obj.AddPair('books',Books);
    for var I:=0 to High(FBooks) do
    begin
      Item:=TJSONObject.Create; Books.AddElement(Item);
      WriteSource(Item,FBooks[I]);
      if RemovesCopies then
      begin
        Item.AddPair('sourceKey',FCopyKeys[I]);
        Primary:=TJSONObject.Create; Item.AddPair('primary',Primary);
        WriteSource(Primary,FPrimaryBooks[I]);
      end;
    end;
    Result:=Obj.ToJSON;
    if Length(TEncoding.UTF8.GetBytes(Result))>4*1024*1024 then
      raise EWriteError.Create('Слишком много книг для одного журнала удаления. Выберите меньше книг.');
  finally Obj.Free; end;
end;

class function TBookDeletionBinding.Parse(const JSON:string):TBookDeletionBinding;
var Value,Primary:TJSONValue; Obj,Item:TJSONObject; Items:TJSONArray; Schema:Integer;
begin
  Result:=Default(TBookDeletionBinding);
  if Length(TEncoding.UTF8.GetBytes(JSON))>4*1024*1024 then
    raise EReadError.Create('Слишком большой журнал записей для удаления.');
  Value:=TJSONObject.ParseJSONValue(JSON);
  try
    if not (Value is TJSONObject) then raise EReadError.Create('Повреждена привязка удаления к коллекции.');
    Obj:=TJSONObject(Value);
    Schema:=PositiveNumber(Obj,'schema');
    if not (Schema in [1,2]) or not (Obj.GetValue('books') is TJSONArray) or
      not (Obj.GetValue('removeRecords') is TJSONBool) then
      raise EReadError.Create('Неподдерживаемый журнал записей для удаления.');
    Result.FCollectionID:=PositiveNumber(Obj,'collection');
    Result.FCatalogueFile:=Text(Obj,'catalogueFile'); Result.FCatalogueKey:=Text(Obj,'catalogueKey');
    Result.FRemoveRecords:=TJSONBool(Obj.GetValue('removeRecords')).AsBoolean;
    Items:=TJSONArray(Obj.GetValue('books'));
    if Items.Count>MAX_BOOK_DELETION_BINDING then raise EReadError.Create('Слишком много записей в журнале удаления.');
    SetLength(Result.FBooks,Items.Count);
    if Schema=2 then
    begin
      SetLength(Result.FCopyKeys,Items.Count); SetLength(Result.FPrimaryBooks,Items.Count);
    end;
    for var I:=0 to Items.Count-1 do
    begin
      if not (Items.Items[I] is TJSONObject) then raise EReadError.Create('Повреждена запись книги в журнале удаления.');
      Item:=TJSONObject(Items.Items[I]); Result.FBooks[I]:=ReadSource(Item,Result.FCollectionID);
      if Schema=2 then
      begin
        Result.FCopyKeys[I]:=Text(Item,'sourceKey');
        Primary:=Item.GetValue('primary');
        if not (Primary is TJSONObject) then raise EReadError.Create('В журнале удаления отсутствует основная копия.');
        Result.FPrimaryBooks[I]:=ReadSource(TJSONObject(Primary),Result.FCollectionID);
      end;
    end;
    Result.Validate;
  finally Value.Free; end;
end;

function TBookDeletionBinding.ExpectedBooks:TArray<TBookRecord>;
begin Result:=Copy(FBooks); end;

function TBookDeletionBinding.RemovesCopies:Boolean;
begin Result:=Length(FCopyKeys)>0; end;

function TBookDeletionBinding.SourceKeys:TArray<string>;
begin Result:=Copy(FCopyKeys); end;

function TBookDeletionBinding.PrimaryBooks:TArray<TBookRecord>;
begin Result:=Copy(FPrimaryBooks); end;

function TBookDeletionBinding.Slice(const Indices:TArray<Integer>):TBookDeletionBinding;
begin
  // Validate the resulting slice, not the complete selection for every
  // archive. Capture/Parse already validated the source snapshot.
  Result:=Self;
  Result.FBooks:=nil; SetLength(Result.FBooks,Length(Indices));
  if RemovesCopies then
  begin
    Result.FCopyKeys:=nil; SetLength(Result.FCopyKeys,Length(Indices));
    Result.FPrimaryBooks:=nil; SetLength(Result.FPrimaryBooks,Length(Indices));
  end;
  for var I:=0 to High(Indices) do
  begin
    if (Indices[I]<0) or (Indices[I]>=Length(FBooks)) then
      raise EArgumentException.Create('Неверная запись книги в плане удаления.');
    Result.FBooks[I]:=FBooks[Indices[I]];
    if RemovesCopies then
    begin
      Result.FCopyKeys[I]:=FCopyKeys[Indices[I]];
      Result.FPrimaryBooks[I]:=FPrimaryBooks[Indices[I]];
    end;
  end;
  Result.Validate;
end;

function TBookDeletionBinding.CapturedInfo(const User:ISystemData):TCollectionInfo;
begin
  Validate;
  if not Assigned(User) then raise EInvalidOperation.Create('База коллекций не открыта.');
  Result:=User.GetCollectionInfo(FCollectionID);
  if (Result.ID<>FCollectionID) or not SameFileName(ExpandFileName(Result.DBFileName),FCatalogueFile) or
    (Copy(ArchiveDeletionSourceIdentity(FCatalogueFile),1,25)<>FCatalogueKey) then
    raise EReadError.Create('Коллекция была заменена. Записи из другой коллекции не удалены.');
end;

function TBookDeletionBinding.OpenCapturedCollection(const User:ISystemData):IBookCollection;
begin
  var Info:=CapturedInfo(User);
  Result:=User.GetCollection(Info.ID);
end;

function TBookDeletionBinding.CheckCopyRows(const User:ISystemData; Commit:Boolean):Integer;
var DB:TSQLiteDatabase; Primary,CopyRow,DeleteRow:TSQLiteQuery;
  Info:TCollectionInfo; Current:TBookRecord; BookID:Integer;

  procedure ReadRow(Row:TSQLiteQuery; ID:Integer; const Root:string);
  begin
    Current:=Default(TBookRecord);
    Current.BookKey:=CreateBookKey(ID,FCollectionID);
    Current.CollectionRoot:=Root;
    Current.LibID:=Row.FieldAsString(0); Current.Folder:=Row.FieldAsString(1);
    Current.FileName:=Row.FieldAsString(2); Current.FileExt:=Row.FieldAsString(3);
    Current.InsideNo:=Row.FieldAsInt(4);
  end;

begin
  Result:=0; Info:=CapturedInfo(User);
  if Commit then DB:=TSQLiteDatabase.Create(Info.DBFileName)
  else DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
  Primary:=nil; CopyRow:=nil; DeleteRow:=nil;
  try
    if Commit then DB.Start('','IMMEDIATE') else DB.Start;
    Primary:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?');
    CopyRow:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,BookID FROM CatalogBookCopies WHERE SourceKey=?');
    if Commit then DeleteRow:=DB.NewQuery('DELETE FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?');
    for var I:=0 to High(FBooks) do
    begin
      CopyRow.SetParam(0,FCopyKeys[I]); CopyRow.Open;
      if CopyRow.Eof then
      begin
        CopyRow.Reset;
        // A receipt may replay after the catalogue commit has already succeeded.
        if Commit then Continue;
        raise EReadError.Create('Дополнительная копия исчезла. Повторите выбор файлов.');
      end;
      BookID:=CopyRow.FieldAsInt(6);
      ReadRow(CopyRow,BookID,CopyRow.FieldAsString(5));
      CopyRow.Reset;
      if not MatchesDeletionSource(Current,FBooks[I]) then
        raise EReadError.Create('Дополнительная копия изменилась. Повторите выбор файлов.');
      Primary.SetParam(0,BookID); Primary.Open;
      if Primary.Eof then raise EReadError.Create('Карточка основной копии исчезла.');
      ReadRow(Primary,BookID,Info.GetRootPath);
      Primary.Reset;
      if not MatchesDeletionSource(Current,FPrimaryBooks[I]) then
        raise EReadError.Create('Основная копия изменилась. Повторите выбор файлов.');
      if Commit then
      begin
        // Keep the source-to-book mapping, the main card and personal data.
        DeleteRow.SetParam(0,FCopyKeys[I]); DeleteRow.SetParam(1,BookID);
        DeleteRow.ExecSQL; DeleteRow.Reset;
        Inc(Result);
      end;
    end;
    if Commit then DB.Commit;
  finally
    DeleteRow.Free; CopyRow.Free; Primary.Free;
    try
      if DB.InTransaction then DB.Rollback;
    finally DB.Free; end;
  end;
end;

function TBookDeletionBinding.CommitCopies(const User:ISystemData):Integer;
begin
  if not RemovesCopies then raise EInvalidOperation.Create('Этот журнал не удаляет дополнительные копии.');
  Result:=CheckCopyRows(User,True);
end;

procedure TBookDeletionBinding.CheckBeforePhysicalRemoval(const User:ISystemData);
var Writer:IBookIdentityDeletionWriter; Expected:TBookRecord; Match:TBookIdentityPredicate;
begin
  if RemovesCopies then
  begin
    CheckCopyRows(User,False);
    Exit;
  end;
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
  if FRemoveRecords or RemovesCopies then raise EInvalidOperation.Create('Этот журнал не меняет доступность файлов.');
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
