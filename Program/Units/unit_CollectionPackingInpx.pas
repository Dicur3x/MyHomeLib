unit unit_CollectionPackingInpx;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Globals,
  unit_Interfaces, unit_ImportInpxThread, unit_CollectionBackup, unit_CollectionPacking,
  unit_MHLArchiveHelpers;

type
  TCollectionPackingReview = reference to procedure(const Status: TCollectionPackingStatus);

  TCollectionPackingInpxWorker = class(TImportInpxThreadBase)
  private
    FOptions: TCollectionPackingOptions;
    FInpx, FUpdateRoot: string;
    FSnapshot: TCollectionPackingSnapshot;
    FProgress: TCollectionPackingProgress;
    FBeforePack: TCollectionPackingReview;
    FLookup: TSQLiteQuery;
    FPersonal: TSQLiteDatabase;
    FArchive: TMHLZip;
    FArchiveName: string;
    FSeen: TDictionary<string, Boolean>;
    procedure ImportDelta(const CatalogFile, PersonalFile: string);
    function LocateInput(var Book: TBookRecord): Boolean;
  protected
    procedure WorkFunction; override;
    function StoreImportedBook(const Book: TBookRecord; CheckFiles: Boolean;
      const Collection: IBookCollection; Cache: TImportCache): Integer; override;
  public
    constructor Create(const Options: TCollectionPackingOptions; const Inpx, UpdateRoot: string;
      const Progress: TCollectionPackingProgress = nil;
      const BeforePack: TCollectionPackingReview = nil);
    destructor Destroy; override;
    function ReadStatus: TCollectionPackingStatus;
    function TakeSnapshot: TCollectionPackingSnapshot;
  end;

implementation

uses System.IOUtils, System.Variants, Winapi.Windows, unit_Consts, unit_Database_SQLite;

type
  // The INPX parser needs the chosen source root. Ordinary catalogue reads
  // still resolve old packed rows relative to the packed collection's root.
  TPackingCatalogSnapshot = class(TBookCollection_SQLite)
  public
    UpdateRoot: string;
    function GetProperty(const PropID: TPropertyID): Variant; override;
    procedure SetProperty(const PropID: TPropertyID; const Value: Variant); override;
  end;

function TPackingCatalogSnapshot.GetProperty(const PropID: TPropertyID): Variant;
begin
  if PropID=PROP_ROOTFOLDER then Exit(UpdateRoot);
  Result:=inherited GetProperty(PropID);
end;

procedure TPackingCatalogSnapshot.SetProperty(const PropID: TPropertyID; const Value: Variant);
var ID: Integer;
begin
  if not isCollectionProp(PropID) then Exit;
  ID:=FCollectionInfo.ID;
  FCollectionInfo.ID:=INVALID_COLLECTION_ID;
  try inherited SetProperty(PropID,Value);
  finally FCollectionInfo.ID:=ID; end;
end;

constructor TCollectionPackingInpxWorker.Create(const Options: TCollectionPackingOptions;
  const Inpx, UpdateRoot: string; const Progress: TCollectionPackingProgress;
  const BeforePack: TCollectionPackingReview);
begin
  inherited Create(MHL_INVALID_ID);
  FOptions:=Options; FInpx:=Inpx; FProgress:=Progress; FBeforePack:=BeforePack;
  FUpdateRoot:=IncludeTrailingPathDelimiter(TPath.GetFullPath(UpdateRoot));
  FGenresType:=gtFb2;
  FKeepCollectionProps:=True;
end;

destructor TCollectionPackingInpxWorker.Destroy;
begin
  inherited;
  FSnapshot.Free;
end;

function TCollectionPackingInpxWorker.ReadStatus: TCollectionPackingStatus;
begin
  Result:=FSnapshot.Status;
end;

function TCollectionPackingInpxWorker.TakeSnapshot: TCollectionPackingSnapshot;
begin
  if not Finished or not Success or not Assigned(FSnapshot) then
    raise EInvalidOperation.Create('Копия с обновлением INPX ещё не подготовлена.');
  Result:=FSnapshot;
  FSnapshot:=nil;
end;

procedure TCollectionPackingInpxWorker.WorkFunction;
begin
  if not SameText(ExtractFileExt(FInpx),'.inpx') then
    raise EArgumentException.Create('Выберите файл обновления с расширением .inpx.');
  if not DirectoryExists(FUpdateRoot) then
    raise EDirectoryNotFoundException.Create('Папка файлов обновления недоступна.');
  FSnapshot:=TCollectionPackingSnapshot.Create(FOptions);
  try
    FSnapshot.Prepare(
      function: Boolean begin Result:=Canceled; end,
      FProgress,
      procedure(const CatalogFile, PersonalFile: string)
      begin ImportDelta(CatalogFile,PersonalFile); end);
    if Assigned(FBeforePack) then
    begin
      FBeforePack(FSnapshot.Status);
      FSnapshot.Pack;
      FSnapshot.ApplyPrepared;
    end;
    FSnapshot.ClearNotifications;
    FOperationSuccess:=True;
  except
    FreeAndNil(FSnapshot);
    raise;
  end;
end;

procedure TCollectionPackingInpxWorker.ImportDelta(const CatalogFile, PersonalFile: string);
var Info: TCollectionInfo; Reader: TSQLiteDatabase; Target: IBookCollection;
  Snapshot: TPackingCatalogSnapshot; Version, PreviousLastID: Integer;
begin
  Info:=FSystemData.GetCollectionInfo(FOptions.SourceID);
  if isOnlineCollection(Info.CollectionType) then
    raise ENotSupportedException.Create('Обновление сжатой копии из INPX доступно для локальной коллекции.');
  Info.DBFileName:=CatalogFile;
  Info.RootFolder:=IncludeTrailingPathDelimiter(FOptions.SourceRoot);
  Reader:=TSQLiteDatabase.CreateReadOnly(CatalogFile);
  try
    if Reader.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibPackingOrigins''')=0 then
      raise EInvalidOperation.Create('Для дозапаковки выберите ранее сжатую коллекцию.');
    FLookup:=Reader.NewQuery(
      'SELECT b.BookID FROM Books b LEFT JOIN HomeLibPackingOrigins o ON '+
      'o.Folder=b.Folder AND o.FileName=b.FileName AND o.Ext=b.Ext '+
      'WHERE b.LibID=? AND b.Ext=? AND coalesce(o.OriginalFileName,b.FileName)=? COLLATE NOCASE LIMIT 2');
    FPersonal:=TSQLiteDatabase.Create(PersonalFile);
    FSeen:=TDictionary<string, Boolean>.Create;
    Snapshot:=TPackingCatalogSnapshot.Create(Info,FSystemData);
    Target:=Snapshot; Snapshot.UpdateRoot:=FUpdateRoot;
    Target.BeginBulkOperation;
    try
      PreviousLastID:=Target.StartCatalogUpdateTracking(False);
      Import(FInpx,False,Target);
      if Canceled then raise EAbort.Create('Подготовка обновления INPX отменена.');
      if FSeen.Count=0 then raise EInvalidOperation.Create('В выбранном INPX нет записей книг.');
      Target.FinishCatalogUpdateTracking(False,PreviousLastID);
      Target.EndBulkOperation(True);
    except
      if Target.InBulkOperation then Target.EndBulkOperation(False);
      raise;
    end;
    Version:=StrToIntDef(VarToStr(Target.GetProperty(PROP_DATAVERSION)),Info.DataVersion);
    if Version>Info.DataVersion then
      FPersonal.ExecSQL('UPDATE Bases SET DataVersion=? WHERE DatabaseID=?',[Version,FOptions.SourceID]);
  finally
    Target:=nil;
    FreeAndNil(FSeen); FreeAndNil(FArchive); FreeAndNil(FPersonal); FreeAndNil(FLookup);
    Reader.Free;
  end;
end;

function TCollectionPackingInpxWorker.LocateInput(var Book: TBookRecord): Boolean;
var Container, Physical: string; Format: TBookFormat; Error: Cardinal;
begin
  if Book.FileName='' then raise EArgumentException.Create('В записи INPX отсутствует имя файла.');
  Book.CollectionRoot:=FUpdateRoot;
  Container:=Book.GetBookContainer;
  Physical:=TPath.GetFullPath(Book.GetBookFileName(Container));
  if not Physical.StartsWith(FUpdateRoot,True) then
    raise EArgumentException.Create('Путь книги выходит за выбранную папку обновления: '+Book.FileName);
  Format:=Book.GetBookFormat(Container);
  Book.Folder:=TPath.GetFullPath(Container);
  if Format in [bfRaw,bfFb2,bfFbd] then Book.Folder:=IncludeTrailingPathDelimiter(Book.Folder);
  // The index of an INP row is not a safe locator in a monthly archive.
  if Format in [bfFb2Archive,bfRawArchive] then Book.InsideNo:=-1;
  if not SameFileName(FArchiveName,Physical) and
    (GetFileAttributes(PChar(Physical))=INVALID_FILE_ATTRIBUTES) then
  begin
    Error:=GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then Exit(False);
    RaiseLastOSError(Error);
  end;
  if Format in [bfFb2Archive,bfRawArchive,bfFbd] then
  begin
    if not SameFileName(FArchiveName,Physical) then
    begin
      FreeAndNil(FArchive); FArchiveName:='';
      FArchive:=TMHLZip.Create(Physical,True,False,
        function: Boolean begin Result:=Canceled; end);
      FArchiveName:=Physical;
    end;
    try
      FArchive.ResolveBookName(Book.FileName+Book.FileExt,Book.InsideNo,True);
    except
      on E:EArchiveBookEntryNotFound do Exit(False);
    end;
  end;
  Result:=True;
end;

function TCollectionPackingInpxWorker.StoreImportedBook(const Book: TBookRecord; CheckFiles: Boolean;
  const Collection: IBookCollection; Cache: TImportCache): Integer;
var Incoming, Old, Updated: TBookRecord; Available: Boolean; Identity: string;
  Updater: IBookMergeMetadataDeltaUpdater;
  Publisher:IPackingPublisherWriter;
  AuthorKey:string; AuthorID:Integer;
  function HasAuthor(const Authors:TBookAuthors; ID:Integer):Boolean;
  begin
    for var Item in Authors do if Item.AuthorID=ID then Exit(True);
    Result:=False;
  end;
  function HasGenre(const Genres:TBookGenres; const Code:string):Boolean;
  begin
    for var Item in Genres do if Item.GenreCode=Code then Exit(True);
    Result:=False;
  end;
  function SameAuthors:Boolean;
  begin
    for var Item in Updated.Authors do if not HasAuthor(Old.Authors,Item.AuthorID) then Exit(False);
    for var Item in Old.Authors do if not HasAuthor(Updated.Authors,Item.AuthorID) then Exit(False);
    Result:=True;
  end;
  function SameGenres:Boolean;
  begin
    for var Item in Updated.Genres do if not HasGenre(Old.Genres,Item.GenreCode) then Exit(False);
    for var Item in Old.Genres do if not HasGenre(Updated.Genres,Item.GenreCode) then Exit(False);
    Result:=True;
  end;
  procedure SavePublisher(ID:Integer);
  var Original:TBookRecord;
  begin
    if not Supports(Collection,IPackingPublisherWriter,Publisher) then
      raise ENotSupportedException.Create('Коллекция не поддерживает сохранение исходных сведений индекса.');
    Original:=Book; Original.BookKey:=CreateBookKey(ID,Collection.CollectionID);
    Publisher.StorePackingPublisherMetadata(Original,FUpdateRoot,Available);
  end;
begin
  if (Trim(Book.LibID)='') or (Book.LibID='0') then
    raise EArgumentException.Create('В записи INPX отсутствует устойчивый идентификатор: '+Book.Title);
  Identity:=Book.LibID+#1+LowerCase(Book.FileName)+#1+LowerCase(Book.FileExt);
  if FSeen.ContainsKey(Identity) then
    raise EArgumentException.Create('Одну запись обновления указывают разные пути: '+Book.Title);
  FSeen.Add(Identity,True);

  Incoming:=Book;
  Available:=LocateInput(Incoming);
  if Available then Include(Incoming.BookProps,bpIsLocal)
  else Exclude(Incoming.BookProps,bpIsLocal);
  Result:=0;
  FLookup.Reset;
  try
    FLookup.SetParam(0,Book.LibID); FLookup.SetParam(1,Book.FileExt); FLookup.SetParam(2,Book.FileName);
    FLookup.Open;
    if not FLookup.Eof then
    begin
      Result:=FLookup.FieldAsInt(0); FLookup.Next;
      if not FLookup.Eof then
        raise EInvalidOperation.Create('В сжатой коллекции несколько записей с этим исходным именем: '+Book.Title);
    end;
  finally FLookup.Reset; end;
  if Result=0 then
  begin
    Result:=Collection.InsertBook(Incoming,False,False,Cache);
    if Result>0 then SavePublisher(Result);
    Exit;
  end;

  Collection.GetBookRecord(CreateBookKey(Result,Collection.CollectionID),Old,True);
  Updated:=Old;
  Updated.Title:=Book.Title;
  Updated.Series:=Book.Series; Updated.SeqNumber:=Book.SeqNumber;
  Updated.Authors:=Copy(Book.Authors); Updated.Genres:=Copy(Book.Genres);
  Updated.Normalize;
  // The delta writer deliberately leaves memberships to its caller. Resolve
  // incoming source metadata in this private catalogue, including retained
  // payloads whose original archives are no longer available. Share the parser
  // cache and leave identical membership sets untouched on repeated indexes.
  for var I:=0 to High(Updated.Authors) do
  begin
    AuthorKey:='';
    if Assigned(Cache) then AuthorKey:=Cache.AuthorKey(Updated.Authors[I].LastName,
      Updated.Authors[I].FirstName,Updated.Authors[I].MiddleName);
    if Assigned(Cache) and Cache.TryGetAuthor(AuthorKey,AuthorID) then Updated.Authors[I].AuthorID:=AuthorID
    else
    begin
      Updated.Authors[I]:=Collection.EnsureAuthor(Updated.Authors[I]);
      if Assigned(Cache) then Cache.AddAuthor(AuthorKey,Updated.Authors[I].AuthorID);
    end;
  end;
  for var I:=0 to High(Updated.Genres) do
    if Updated.Genres[I].FB2GenreCode<>'' then
      Updated.Genres[I]:=Collection.EnsureGenre(Updated.Genres[I].FB2GenreCode,Updated.Genres[I].GenreAlias,'');
  Updated.Lang:=Book.Lang;
  Updated.Date:=Book.Date;
  Updated.LibRate:=Book.LibRate;
  if Book.KeyWords<>'' then Updated.KeyWords:=Book.KeyWords;
  if bpIsDeleted in Book.BookProps then Include(Updated.BookProps,bpIsDeleted)
  else Exclude(Updated.BookProps,bpIsDeleted);
  if Available then
  begin
    Updated.Folder:=Incoming.Folder; Updated.FileName:=Incoming.FileName;
    Updated.InsideNo:=Incoming.InsideNo; Updated.Size:=Incoming.Size;
    Include(Updated.BookProps,bpIsLocal);
    FPersonal.ExecSQL('UPDATE Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,BookSize=?,IsLocal=1 '+
      'WHERE DatabaseID=? AND BookID=? AND LibID=? AND Folder=? AND FileName=? AND Ext=?',
      [Updated.Folder,Updated.FileName,Updated.FileExt,Updated.InsideNo,Updated.Size,
       FOptions.SourceID,Result,Old.LibID,Old.Folder,Old.FileName,Old.FileExt]);
  end;
  if not Supports(Collection,IBookMergeMetadataDeltaUpdater,Updater) then
    raise ENotSupportedException.Create('Коллекция не поддерживает обновление карточки книги.');
  Updater.UpdateBookMetadataDelta(Old,Updated,False);
  if not SameAuthors then Collection.SetBookAuthors(Result,Updated.Authors,True);
  if not SameGenres then Collection.SetBookGenres(Result,Updated.Genres,True);
  Collection.AddBookSeries(Result,Book.Series,Book.SeqNumber,Cache);
  SavePublisher(Result);
end;

end.
