procedure TestCollectionPacking;
var Source, CopyCollection: IBookCollection; Options: TCollectionPackingOptions;
  Snapshot: TCollectionPackingSnapshot; Book, Copied, Personal: TBookRecord;
  SourceID, CopyID: Integer; IDs: TArray<Integer>; Hashes: TArray<string>;
  Root, Destination, CatalogPath, CatalogHash, ArchiveHash, PersonalBefore: string;
  DB: TSQLiteDatabase; Zip: TZipFile; Cancel, Rejected, CancelRegistration: Boolean;
  ProgressCalls, RegistrationChecks: Integer;
  function BookHash(const Value: TBookRecord): string;
  var Stream: TStream;
  begin
    Stream:=Value.GetBookStream(True,False);
    try Require(Assigned(Stream),'Packing fixture has no book stream'); Result:=THashSHA2.GetHashString(Stream);
    finally Stream.Free; end;
  end;
  function PersonalValue(ID: Integer): string;
  var Store: TSQLiteDatabase;
  begin
    Store:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try Result:=Store.QuerySingleString('SELECT hex(Review)||''|''||Rate||''|''||Progress||''|''||Folder||''|''||FileName '+
      'FROM Books WHERE BookID=? AND DatabaseID=?',[IDs[0],ID]);
    finally Store.Free; end;
  end;
begin
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'mixed-save-inputs');
  Destination:=Settings.AppPath+'compressed-copy'; Cancel:=False; CancelRegistration:=False;
  ProgressCalls:=0; RegistrationChecks:=0;
  SourceID:=SystemDB.CreateCollection('Packing source',Root,'packing-source.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID); SetLength(IDs,5); SetLength(Hashes,5);
  for var I:=0 to 4 do
  begin
    IDs[I]:=AddBook(Source,'Packing '+IntToStr(I),'Автор Ё','ru','Серия Ё','prose_contemporary');
    Source.GetBookRecord(CreateBookKey(IDs[I],SourceID),Book,True);
    Book.FileName:='source'; Book.FileExt:=TArray<string>.Create('.fb2','.epub','.pdf','.djvu','.fb2')[I];
    if I=4 then begin Book.Folder:='legacy.zip'; Book.FileName:='obsolete-name'; Book.InsideNo:=0; end;
    Source.UpdateBook(Book);
  end;
  Zip:=TZipFile.Create;
  try Zip.Open(Root+'legacy.zip',zmWrite); Zip.Add(TFile.ReadAllBytes(Root+'source.fb2'),'actual-book.fb2');
  finally Zip.Free; end;
  Source.SetRate(CreateBookKey(IDs[0],SourceID),4); Source.SetProgress(CreateBookKey(IDs[0],SourceID),37);
  Source.SetReview(CreateBookKey(IDs[0],SourceID),'Личная заметка #ё');
  Source.AddBookToGroup(CreateBookKey(IDs[0],SourceID),FAVORITES_GROUP_ID);
  SystemDB.SetProperty(SourceID,PROP_DATAVERSION,20261028);
  SystemDB.SetProperty(SourceID,PROP_URL,'https://example.invalid/library/');
  SystemDB.SetProperty(SourceID,PROP_CONNECTIONSCRIPT,'GET %URL%b/%LIBID%/get'#13#10'CHECK');
  CatalogPath:=Source.GetProperty(PROP_DATAFILE);
  DB:=TSQLiteDatabase.Create(CatalogPath);
  try
    DB.ExecSQL('CREATE TABLE IF NOT EXISTS CatalogBookCopies(SourceKey TEXT PRIMARY KEY,BookID INTEGER,SourceName TEXT,Root TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER,LibID TEXT)');
    DB.ExecSQL('INSERT INTO CatalogBookCopies VALUES(?,?,?,?,?,?,?,?,?,?)',
      ['alternate-source',IDs[0],'Другой источник',Root,'','source','.epub',0,123,'alternate-libid']);
  finally DB.Free; end;
  for var I:=0 to High(IDs) do
  begin Source.GetBookRecord(CreateBookKey(IDs[I],SourceID),Book,True); Hashes[I]:=BookHash(Book); end;
  CatalogHash:=THashSHA2.GetHashStringFromFile(CatalogPath);
  ArchiveHash:=THashSHA2.GetHashStringFromFile(Root+'legacy.zip'); PersonalBefore:=PersonalValue(SourceID);
  Options:=Default(TCollectionPackingOptions); Options.CatalogFile:=CatalogPath;
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.SourceID:=SourceID;
  Options.Dataset:='native-packing-fixture';
  Options.SourceRoot:=Root; Options.OutputRoot:=Destination; Options.DisplayName:='Сжатая копия Ё';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Writeln('TRACE packing prepare'); Flush(Output);
    Snapshot.Prepare(function:Boolean begin
      if CancelRegistration then Inc(RegistrationChecks);
      Result:=Cancel or (CancelRegistration and (RegistrationChecks>=4)); end,
      procedure(const Stage:string; Current,Total:Int64) begin Inc(ProgressCalls); Writeln('TRACE packing ',Stage,' ',Current,'/',Total); Flush(Output); end);
    Require(Snapshot.PlannedLocations>=7,'Packing omitted personal or alternate file locations');
    RequirePackingLeaseBusy(Options);
    Snapshot.Pack; Cancel:=True; Rejected:=False;
    try Snapshot.ApplyPrepared; except on E:EAbort do Rejected:=True; end;
    Require(Rejected,'Canceled remapping was published'); Cancel:=False;
    Snapshot.ApplyPrepared;
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),'Prepared copy registered before confirmation');
    CancelRegistration:=True; Rejected:=False;
    try Snapshot.RegisterNew(SystemDB); except on E:EAbort do Rejected:=True; end;
    CancelRegistration:=False;
    Require(Rejected and (RegistrationChecks>=4) and FileExists(Snapshot.CatalogFile) and
      not FileExists(Destination+'\collection.hlc2') and
      not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
      'Canceled final registration left a partially published collection');
    CopyID:=Snapshot.RegisterNew(SystemDB);
    Require(CopyID<>SourceID,'Packing replaced original collection');
  finally Snapshot.Free; end;
  Require(ProgressCalls>0,'Packing provided no progress');
  Require(Length(TDirectory.GetDirectories(Destination,'.job-*'))=0,'Packing retained disposable snapshots');
  CopyCollection:=SystemDB.GetCollection(CopyID);
  for var I:=0 to High(IDs) do
  begin
    CopyCollection.GetBookRecord(CreateBookKey(IDs[I],CopyID),Copied,True);
    Source.GetBookRecord(CreateBookKey(IDs[I],SourceID),Book,True);
    Require((Copied.Title=Book.Title) and (Copied.Series=Book.Series) and
      (TAuthorsHelper.GetList(Copied.Authors)=TAuthorsHelper.GetList(Book.Authors)),
      'Packing changed book metadata');
    Require(Copied.GetBookFileName.StartsWith(Destination,True),'Compressed book still refers to original storage');
    Require(BookHash(Copied)=Hashes[I],'Packing changed exact book bytes: '+IntToStr(I));
    Require(BookHash(Book)=Hashes[I],'Packing changed source book bytes: '+IntToStr(I));
    if I<2 then
    begin
      var Stream:=Copied.GetBookStream(True,False); var Name:=Destination+'\read-check'+Copied.FileExt;
      try var OutputFile:=TFileStream.Create(Name,fmCreate); try OutputFile.CopyFrom(Stream,0); finally OutputFile.Free; end;
      finally Stream.Free; end;
      var Document:=TReaderDocument.Create;
      try Document.Load(Name); Require(Document.PlainText.Contains('Full text, final sentence.'),'Packed book cannot be read');
      finally Document.Free; end;
    end;
  end;
  SystemDB.GetBookRecord(CreateBookKey(IDs[0],CopyID),Personal);
  Require((Personal.Rate=4) and (Personal.Progress=37) and
    (SystemDB.GetReview(Personal.BookKey)='Личная заметка #ё'),'Packing lost private card or reading progress');
  Require(Personal.GetBookFileName.StartsWith(Destination,True),'Personal card still refers to original storage');
  var Iterator:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,CopyID);
  Require((Iterator.RecordCount=1) and Iterator.Next(Book) and (Book.BookKey.BookID=IDs[0]),'Packing lost group membership');
  Iterator:=nil;
  Require((SystemDB.GetCollectionInfo(CopyID).DataVersion=20261028) and
    (SystemDB.GetCollectionInfo(CopyID).URL='https://example.invalid/library/') and
    (SystemDB.GetCollectionInfo(CopyID).Script=SystemDB.GetCollectionInfo(SourceID).Script),
    'Packing lost INPX or download settings');
  var Copies:=CopyCollection.GetCatalogBookCopies(CreateBookKey(IDs[0],CopyID));
  Require((Length(Copies)=1) and Copies[0].GetBookFileName.StartsWith(Destination,True) and
    (BookHash(Copies[0])=Hashes[1]),'Packing omitted alternate source bytes');
  Require((THashSHA2.GetHashStringFromFile(CatalogPath)=CatalogHash) and
    (THashSHA2.GetHashStringFromFile(Root+'legacy.zip')=ArchiveHash) and
    (PersonalValue(SourceID)=PersonalBefore),'Packing modified original catalogue books or personal card');
  Writeln('PASS native packing separate clone exact FB2 EPUB PDF DjVu legacy ZIP personal cards alternate copies groups and update settings');
  TestPackingLeaseRecovery(Options);
  TestPackingProgress(Options);
  TestPackingRetention(Options,CopyID,IDs,Hashes);
end;
