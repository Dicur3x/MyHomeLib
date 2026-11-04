procedure TestPackingInpx;
var Source, PackedSource, Updated: IBookCollection; Book, Card: TBookRecord;
  Options: TCollectionPackingOptions; Snapshot: TCollectionPackingSnapshot;
  LegacyUpdate: TManualUpdateThread;
  SourceID, PackedID, UpdatedID, ChangedID, RetainedID, NewID, MissingID: Integer;
  Root, UpdateRoot, IndexFile, BeforeCatalog, BeforeHash, BeforePackedPath: string;
  Archive: TZipFile;

  procedure AddZipText(const Name, Value: string);
  begin
    Archive.Add(TEncoding.UTF8.GetBytes(Value),Name);
  end;

  function Row(const Title, FileName, LibID: string): string;
  begin
    Result:='Автор,Тест:'#4'prose_contemporary:'#4+Title+#4'Цикл из INPX'#4'1'#4+
      FileName+#4'123'#4+LibID+#4'0'#4'txt'#4'2026-11-04'#4'ru';
  end;

  function AddInput(const Title, Name, LibID, Value: string): Integer;
  begin
    Result:=AddBook(Source,Title,'Автор','ru','Существующая серия','prose_contemporary');
    Source.GetBookRecord(CreateBookKey(Result,SourceID),Book,True);
    Book.FileName:=Name; Book.FileExt:='.txt'; Book.LibID:=LibID;
    Source.UpdateBook(Book);
    TFile.WriteAllBytes(TPath.Combine(Root,Name+'.txt'),TEncoding.UTF8.GetBytes(Value));
  end;

  function ReviewUpdate(Cancel: Boolean): TCollectionPackingSnapshot;
  var Dialog: TfrmCollectionPackingProgress; Probe: TPackingReviewProbe; Timer: TTimer;
  begin
    Result:=nil;
    Dialog:=TfrmCollectionPackingProgress.Create(nil);
    Probe:=TPackingReviewProbe.Create;
    Timer:=TTimer.Create(nil);
    try
      Probe.Dialog:=Dialog; Probe.Cancel:=Cancel;
      Probe.ExpectedBooks:=4; Probe.ExpectedUnavailable:=1;
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
      try
        Result:=Dialog.Execute(Options,True,IndexFile,UpdateRoot);
      except
        on E:EAbort do if not Cancel then raise;
      end;
      Require(Probe.SawEstimate and (Assigned(Result)<>Cancel),
        'INPX estimate did not honor cancellation or continuation');
    finally
      Timer.Free; Probe.Free; Dialog.Free;
    end;
  end;

  function ReadText(const Collection: IBookCollection; ID: Integer): string;
  var Value: TBookRecord; Stream: TStream; Bytes: TBytes;
  begin
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Value,True);
    Stream:=Value.GetBookStream(True,False);
    try
      Require(Assigned(Stream),'Expected exact packed text stream');
      SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
      Result:=TEncoding.UTF8.GetString(Bytes);
    finally Stream.Free; end;
  end;

begin
  Root:=Settings.AppPath+'packing-inpx-source';
  UpdateRoot:=Settings.AppPath+'packing-inpx-input';
  ForceDirectories(Root); ForceDirectories(UpdateRoot);
  SourceID:=SystemDB.CreateCollection('INPX packing source',Root,'packing-inpx-source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  ChangedID:=AddInput('Earlier title','changed','10001','Earlier bytes');
  RetainedID:=AddInput('Untouched title','untouched','10002','Untouched bytes');
  Source.SetRate(CreateBookKey(ChangedID,SourceID),4);
  Source.SetProgress(CreateBookKey(ChangedID,SourceID),37);
  Source.SetReview(CreateBookKey(ChangedID,SourceID),'Личная заметка');
  Source.AddBookToGroup(CreateBookKey(ChangedID,SourceID),FAVORITES_GROUP_ID);

  Options:=Default(TCollectionPackingOptions);
  Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.SourceID:=SourceID;
  Options.SourceRoot:=Root; Options.OutputRoot:=Settings.AppPath+'packing-inpx-copy';
  Options.DisplayName:='Packed before INPX';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared;
    PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  PackedSource:=SystemDB.GetCollection(PackedID);
  PackedSource.GetBookRecord(CreateBookKey(RetainedID,PackedID),Book,True);
  BeforePackedPath:=Book.GetBookFileName;
  BeforeCatalog:=PackedSource.GetProperty(PROP_DATAFILE);
  BeforeHash:=THashSHA2.GetHashStringFromFile(BeforeCatalog);
  Archive:=TZipFile.Create;
  try
    Archive.Open(TPath.Combine(UpdateRoot,'books.zip'),zmWrite);
    AddZipText('unrelated.txt','Unrelated first member');
    AddZipText('new.txt','New bytes from INPX');
    AddZipText('changed.txt','Changed bytes from INPX');
  finally Archive.Free; end;
  IndexFile:=TPath.Combine(UpdateRoot,'selected.inpx');
  Archive:=TZipFile.Create;
  try
    Archive.Open(IndexFile,zmWrite);
    AddZipText('structure.info','AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG');
    AddZipText('books.inp',Row('Changed title','changed','10001')+sLineBreak+
      Row('New title','new','10003')+sLineBreak+Row('Absent member','missing','10004')+sLineBreak);
    AddZipText('absent.inp',Row('Untouched title','untouched','10002')+sLineBreak);
    AddZipText('version.info','20261104');
  finally Archive.Free; end;

  Options.CatalogFile:=BeforeCatalog; Options.SourceID:=PackedID;
  Options.SourceRoot:=Options.OutputRoot; Options.DisplayName:='Packed after INPX';
  Require(IsPackedCollectionCatalog(BeforeCatalog) and
    not IsPackedCollectionCatalog(Source.GetProperty(PROP_DATAFILE)), 'Packed catalogue marker recognition failed');
  LegacyUpdate:=TManualUpdateThread.Create(PackedID,IndexFile,True,gtFb2);
  try
    LegacyUpdate.Start; LegacyUpdate.WaitFor;
    Require(not LegacyUpdate.Success and not LegacyUpdate.CommittedChanges,
      'Ordinary full import replaced a packed catalogue');
  finally LegacyUpdate.Free; end;
  ReviewUpdate(True);
  Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName) and
    (THashSHA2.GetHashStringFromFile(BeforeCatalog)=BeforeHash),'Canceling the estimate changed the active collection');
  Snapshot:=ReviewUpdate(False);
  try
    Require((Snapshot.PlannedLocations>=3) and (Snapshot.Status.Unavailable=1),
      'INPX preparation did not distinguish an absent archive member');
    Require((Snapshot.Status.SourcesDone=2) and (Snapshot.Status.Reused=1),
      'INPX preparation reprocessed an unchanged source');
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
      'An INPX update was registered before publication');
    UpdatedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;

  Updated:=SystemDB.GetCollection(UpdatedID);
  Require(Updated.ResolveBookID('10001',0)=ChangedID,'INPX changed the stable book number');
  Updated.GetBookRecord(CreateBookKey(ChangedID,UpdatedID),Book,True);
  Require(Book.Title='Changed title','Updated INPX metadata was not stored');
  SystemDB.GetBookRecord(CreateBookKey(ChangedID,UpdatedID),Card);
  Require((Card.Rate=4) and (Card.Progress=37) and
    (SystemDB.GetReview(Card.BookKey)='Личная заметка') and SameFileName(Card.GetBookFileName,Book.GetBookFileName),
    'INPX update lost personal data or left its physical card pointing at the old edition');
  Require(ReadText(Updated,ChangedID)='Changed bytes from INPX','Changed archive member was not updated exactly');
  Require(ReadText(Updated,RetainedID)='Untouched bytes','INPX update changed a retained book');
  Updated.GetBookRecord(CreateBookKey(RetainedID,UpdatedID),Book,True);
  Require(SameFileName(Book.GetBookFileName,BeforePackedPath),'INPX changed the untouched archive locator');
  NewID:=Updated.ResolveBookID('10003',0);
  Require((NewID>0) and (ReadText(Updated,NewID)='New bytes from INPX'),'New INPX book was not packed');
  MissingID:=Updated.ResolveBookID('10004',0);
  Require(MissingID>0,'An unavailable INPX book disappeared from the catalogue');
  Updated.GetBookRecord(CreateBookKey(MissingID,UpdatedID),Book,True);
  Require(not (bpIsLocal in Book.BookProps),'Missing INPX member was resolved to an unrelated archive entry');
  Require((SystemDB.GetCollectionInfo(UpdatedID).DataVersion=20261104) and
    (SystemDB.GetCollectionInfo(PackedID).DataVersion<>20261104),'INPX version changed the old collection');
  Require((THashSHA2.GetHashStringFromFile(BeforeCatalog)=BeforeHash) and
    (ReadText(PackedSource,ChangedID)='Earlier bytes'),'INPX modified a registered previous catalogue or its books');
  Writeln('PASS selected INPX adds and replaces exact books, retains prior archives and IDs, and publishes a separate generation');
  Writeln('PASS selected INPX estimate cancels and continues, and legacy full import refuses a packed catalogue');
end;
