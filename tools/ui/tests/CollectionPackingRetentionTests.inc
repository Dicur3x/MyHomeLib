procedure TestPackingRetention(const OriginalOptions:TCollectionPackingOptions; PackedID:Integer;
  const BookIDs:TArray<Integer>; const ExpectedHashes:TArray<string>);
var Options:TCollectionPackingOptions; Existing, Preview, ResultCollection:IBookCollection;
  DB:TSQLiteDatabase; Snapshot:TCollectionPackingSnapshot; Book:TBookRecord;
  ExistingCatalog, CatalogHash, PreviewFile, External, OldInputs, MovedInputs, NewHash:string;
  NewBookID, NewCollectionID:Integer; Status:TCollectionPackingStatus; PreviewInfo:TCollectionInfo;
  function HashBook(const RecordValue:TBookRecord):string;
  var Stream:TStream;
  begin
    Stream:=RecordValue.GetBookStream(True,False);
    try Require(Assigned(Stream),'Retained book cannot be opened'); Result:=THashSHA2.GetHashString(Stream);
    finally Stream.Free; end;
  end;
begin
  Existing:=SystemDB.GetCollection(PackedID);
  ExistingCatalog:=Existing.GetProperty(PROP_DATAFILE); CatalogHash:=THashSHA2.GetHashStringFromFile(ExistingCatalog);
  PreviewFile:=Settings.AppPath+'packing-monthly-preview.hlc2';
  DB:=TSQLiteDatabase.CreateReadOnly(ExistingCatalog);
  try DB.BackupTo(PreviewFile); finally DB.Free; end;
  External:=Settings.AppPath+'monthly-input'; ForceDirectories(External);
  TFile.WriteAllText(External+'\monthly.txt','Новая книга из выбранного обновления. Final sentence.',TEncoding.UTF8);
  NewHash:=THashSHA2.GetHashStringFromFile(External+'\monthly.txt');
  PreviewInfo:=SystemDB.GetCollectionInfo(PackedID); PreviewInfo.DBFileName:=PreviewFile;
  Preview:=TBookCollection_SQLite.Create(PreviewInfo,SystemDB);
  try
    NewBookID:=AddBook(Preview,'Monthly addition','Новый автор','ru','Новая серия','prose_contemporary');
    Preview.GetBookRecord(CreateBookKey(NewBookID,Preview.CollectionID),Book,True);
    Book.Folder:=External; Book.FileName:='monthly'; Book.FileExt:='.txt'; Preview.UpdateBook(Book);
  finally Preview:=nil; end;
  Options:=OriginalOptions; Options.CatalogFile:=PreviewFile; Options.SourceID:=PackedID;
  Options.SourceRoot:=OriginalOptions.OutputRoot; Options.Dataset:=''; Options.DisplayName:='Дозапакованная проверочная копия';
  OldInputs:=ExcludeTrailingPathDelimiter(OriginalOptions.SourceRoot); MovedInputs:=OldInputs+'-unavailable';
  Require(RenameFile(OldInputs,MovedInputs),'Cannot make owned original fixtures temporarily unavailable');
  Snapshot:=nil;
  try
    Snapshot:=TCollectionPackingSnapshot.Create(Options); Snapshot.Prepare;
    DB:=TSQLiteDatabase.CreateReadOnly(Snapshot.PlanFile);
    try
      Require((DB.QuerySingleInt('SELECT count(*) FROM retained')>=7) and
        (DB.QuerySingleInt('SELECT count(*) FROM books')=1),'Native incremental plan reopens original payloads or omits new book');
    finally DB.Free; end;
    Snapshot.Pack; Status:=Snapshot.Status;
    Require((Status.SourcesDone=6) and (Status.Reused=5) and (Status.BooksDone>=8),
      'Native retained progress does not distinguish old payloads and a new input');
    Snapshot.ApplyPrepared;
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),'Incremental preparation published before review');
    NewCollectionID:=Snapshot.RegisterNew(SystemDB);
    Require((NewCollectionID<>PackedID) and FileExists(ExistingCatalog) and
      (THashSHA2.GetHashStringFromFile(ExistingCatalog)=CatalogHash),'Incremental preview replaced the active catalogue');
    ResultCollection:=SystemDB.GetCollection(NewCollectionID);
    for var I:=0 to High(BookIDs) do
    begin
      ResultCollection.GetBookRecord(CreateBookKey(BookIDs[I],NewCollectionID),Book,True);
      Require(HashBook(Book)=ExpectedHashes[I],'Incremental retention changed a completed book');
    end;
    ResultCollection.GetBookRecord(CreateBookKey(NewBookID,NewCollectionID),Book,True);
    Require(HashBook(Book)=NewHash,'Incremental addition changed the new book');
    SystemDB.GetBookRecord(CreateBookKey(BookIDs[0],NewCollectionID),Book);
    Require((Book.Rate=4) and (Book.Progress=37) and (SystemDB.GetReview(Book.BookKey)='Личная заметка #ё'),
      'Incremental preparation lost private card or reading state');
  finally
    ResultCollection:=nil; Snapshot.Free;
    Require(RenameFile(MovedInputs,OldInputs),'Cannot restore owned original fixtures');
  end;
  Writeln('PASS native incremental retained payloads without originals plus new external book preserve metadata private cards and active catalogue');
end;
