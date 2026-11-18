procedure TestPackedSourceReview;
  procedure Scenario(WithHistory:Boolean);
var Folder,OriginalRoot,HeldRoot,PackedRoot,Incoming,BaseIndex,NextIndex:string;
  Source,PackedCollection:IBookCollection; SourceID,PackedID,FirstID,SecondID:Integer;
  Options:TCollectionPackingOptions; Snapshot:TCollectionPackingSnapshot;
  Profile:TLibraryUpdateSource; Dialog:TfrmLibraryUpdateSources;
  Catalog,Personal:TSQLiteDatabase; BeforeRows,BeforePersonal,BeforeINI:string;
  Zip:TZipFile; Worker:TManualUpdateThread; Book:TBookRecord;
  Stage:TStagedLibraryIndex; ReviewPlan:TLibraryUpdateReview; ApplyWorker:TCollectionWorker;
  Probe:TLibraryApplyProbe; CacheInfo:TCatalogSource; CacheHash:string;

  procedure Index(const FileName:string; NewBook:Boolean; Changed:Boolean=False);
    function Row(ID:Integer):string;
    begin
      if Changed and (ID=1001) then
        Exit('Автор,Тест:'#4'prose_contemporary:'#4'Corrected publisher 1001'#4#4#4'1001'#4'456'#4'1001'#4'0'#4'txt'#4'2026-11-19'#4'ru'+sLineBreak);
      Result:='Автор,Тест:'#4'prose_contemporary:'#4'Publisher '+IntToStr(ID)+#4#4#4+
        IntToStr(ID)+#4'123'#4+IntToStr(ID)+#4'0'#4'txt'#4'2026-11-18'#4'ru'+sLineBreak;
    end;
  var Z:TZipFile;
  begin
    Z:=TZipFile.Create;
    try
      Z.Open(FileName,zmWrite);
      Z.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Z.Add(TEncoding.UTF8.GetBytes(Row(1001)+Row(1002)),'books.inp');
      if NewBook then Z.Add(TEncoding.UTF8.GetBytes(Row(1003)),'new.inp');
    finally Z.Free; end;
  end;

  procedure Review(Deleted,OldArchiveDelivered:Boolean; Changed:Boolean=False);
  var Stream:TStream; Bytes:TBytes;
  begin
    Catalog:=TSQLiteDatabase.CreateReadOnly(PackedCollection.GetProperty(PROP_DATAFILE));
    Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    Dialog:=nil;
    try
      BeforeRows:=ReaderAllCatalogRows(Catalog); BeforePersonal:=ReaderAllCatalogRows(Personal);
      BeforeINI:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
      Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
      if WithHistory then
      begin
        Require((Length(Dialog.Sources)=1) and SameText(Dialog.Sources[0].ID,Profile.ID),
          'Packed copy did not retain its source profile');
        Dialog.ReplaceSource(0,Profile);
      end
      else Dialog.AppendSource(Profile);
      Dialog.CheckSource;
      Require(Assigned(Dialog.Review) and Dialog.Review.Ready,'Packed source profile did not finish review');
      Require((Dialog.Review.NewBooks=1) and (Dialog.Review.ChangedBooks=Ord(Changed)),
        'Packed source review confused packed sizes or deleted rows with publisher changes: '+Dialog.Review.Summary);
      Require((Dialog.Review.NeededArchives.Count=1) and SameText(Dialog.Review.NeededArchives[0],'new.zip'),
        'Packed source review asks for old archives instead of only the new archive: '+Dialog.Review.NeededArchives.Text);
      Require(Dialog.Review.Summary.Contains('упакованной копии'),
        'Packed source review does not explain its publisher baseline');
      Require((ReaderAllCatalogRows(Catalog)=BeforeRows) and (ReaderAllCatalogRows(Personal)=BeforePersonal) and
        (THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=BeforeINI),
        'Packed source review wrote catalogue personal data or settings');
      PackedCollection.GetBookRecord(CreateBookKey(FirstID,PackedID),Book,True);
      Stream:=Book.GetBookStream(True,False);
      try
        Require(Assigned(Stream),'Packed book cannot be read with originals offline');
        SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
        Require(TEncoding.UTF8.GetString(Bytes)='Original body 1001','Packed source review changed the old book');
      finally Stream.Free; end;
      Require((Book.Rate=4) and (Book.Progress=37) and (PackedCollection.GetReview(Book.BookKey)='Личная заметка ё'),
        'Packed source review lost personal data');
      Require(Catalog.QuerySingleInt('SELECT BookSize FROM HomeLibrePackingPublishers WHERE BookID=?',[FirstID])=123,
        'Packed publisher snapshot lost the original nominal index size');
      if Deleted then Require(PackedCollection.ResolveBookID('1002',0)=0,'Packed review resurrected a deleted card');
      if WithHistory then Require(THashSHA2.GetHashStringFromFile(CacheInfo.CacheFile)=CacheHash,
        'Packed source review rewrote the authoritative pre-packing cache');
      Writeln('PASS packed source profile compares original names sizes and dates with only new archive needed and no writes deleted=',Ord(Deleted),' history=',Ord(WithHistory),' old_archive_delivered=',Ord(OldArchiveDelivered),' genuine_publisher_change=',Ord(Changed)); Flush(Output);
    finally Dialog.Free; Personal.Free; Catalog.Free; end;
  end;

  procedure ApplyPackedProfile(Full: Boolean);
  var
    Applied: IBookCollection;
    NewID, ArrivalID: Integer;
    PreviousFile, PreviousHash: string;
    Stream: TStream;
    Bytes: TBytes;
    AppliedHistory: TCatalogSource;
    procedure DeliverArchive(const Name, Entry, Content: string);
    var Archive: TZipFile;
    begin
      Archive:=TZipFile.Create;
      try
        Archive.Open(TPath.Combine(Incoming,Name),zmWrite);
        Archive.Add(TEncoding.UTF8.GetBytes(Content),Entry);
      finally Archive.Free; end;
    end;
    function ApplyFromWindow: Integer;
    var Driver: TLibraryWindowDriver; Timer: TTimer; Action: TAction; Choice: TMenuItem;
    begin
      Choice:=TMenuItem.Create(nil);
      try Choice.Tag:=PackedID; frmMain.miActiveCollectionClick(Choice);
      finally Choice.Free; end;
      frmMain.Show; Application.ProcessMessages;
      Driver:=TLibraryWindowDriver.Create; Timer:=TTimer.Create(nil);
      try
        Driver.Profile:=Profile; Driver.Accept:=True; Driver.Timer:=Timer;
        Driver.PackedUpdate:=True; Driver.ProtectedCollectionID:=PackedID;
        Timer.Interval:=1; Timer.OnTimer:=Driver.Tick; Timer.Enabled:=True;
        Action:=TAction(frmMain.FindComponent('acUpdateLibrary'));
        Action.Update; Require(Action.Enabled,'Packed source update action stayed disabled');
        Action.Execute;
        Require(Driver.Started and Driver.Confirmed and (Driver.Failure=''),
          'Packed source window: '+Driver.Failure);
        Result:=Driver.PublishedCollectionID;
        Require((Result>0) and IsWindowEnabled(frmMain.Handle) and (Settings.ActiveCollection=Result),
          'Closing the source window did not activate the new packed generation');
      finally Timer.Free; Driver.Free; end;
    end;
    function ApplyTo(ID: Integer; Accept: Boolean; CancelBeforeRegistration: Boolean=False): Integer;
    begin
      Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
      ReviewPlan:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        ApplyWorker:=CreateLibraryReviewWorker(ID,ReviewPlan);
        try TOORun(ApplyWorker); Require(ApplyWorker.Success,'Packed application review failed');
        finally ApplyWorker.Free; end;
        Probe:=TLibraryApplyProbe.Create;
        Probe.Accept:=Accept;
        ApplyWorker:=CreateLibraryApplyWorker(ID,ReviewPlan,False);
        try
          ApplyWorker.OnShowMessage:=Probe.Confirm;
          if CancelBeforeRegistration then
            LibraryUpdateTestPoint:=procedure(Point: string)
            begin
              if Point='packed-before-registration' then raise EAbort.Create('Verification cancellation');
            end;
          ApplyWorker.Start; ApplyWorker.WaitFor;
          if Assigned(ApplyWorker.FatalException) then
            raise Exception.Create('Packed application: '+Exception(ApplyWorker.FatalException).Message);
          Require(Probe.Confirmed,'Packed application did not ask for confirmation');
          Require(ApplyWorker.Success=(Accept and not CancelBeforeRegistration),'Packed application worker outcome mismatch');
          Require(ApplyWorker.CommittedChanges=(Accept and not CancelBeforeRegistration),'Packed application committed unexpectedly');
          Result:=ReviewPlan.PublishedCollectionID;
          Require((Result>0)=(Accept and not CancelBeforeRegistration),'Packed application returned the wrong collection ID');
        finally LibraryUpdateTestPoint:=nil; ApplyWorker.Free; Probe.Free; end;
      finally ReviewPlan.Free; Stage.Free; end;
    end;
    procedure CheckBody(ID: Integer; const Expected: string);
    begin
      Applied.GetBookRecord(CreateBookKey(ID,Applied.CollectionID),Book,True);
      Stream:=Book.GetBookStream(True,False);
      try
        SetLength(Bytes,Stream.Size);
        Stream.ReadBuffer(Bytes,Length(Bytes));
        Require(TEncoding.UTF8.GetString(Bytes)=Expected,'Unexpected packed payload for '+Book.FileName);
      finally Stream.Free; end;
    end;
  begin
    Profile.Full:=Full;
    Index(NextIndex,True,True);
    PackedCollection.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,
      WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
    PreviousFile:=PackedCollection.GetProperty(PROP_DATAFILE);
    PreviousHash:=THashSHA2.GetHashStringFromFile(PreviousFile);
    DeliverArchive('new.zip','1003.txt','New reviewed body');
    ApplyTo(PackedID,False);
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Declining changed the original packed catalog');
    ApplyTo(PackedID,True,True);
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Cancellation changed the original packed catalog');
    NewID:=ApplyFromWindow;
    Require(NewID<>PackedID,'Reviewed update replaced the original collection');
    Applied:=SystemDB.GetCollection(NewID,True);
    Require(Assigned(Applied) and LoadLibraryUpdateHistory(Applied,Profile,AppliedHistory),
      'Reviewed packed generation has no published source history');
    Require(Applied.ResolveBookID('1001',0)=FirstID,'Reviewed packed generation changed the stable book ID');
    Require(Applied.ResolveBookID('1002',0)=0,'Reviewed packed generation restored a deleted card');
    CheckBody(FirstID,'Original body 1001');
    Require((Book.Title='Corrected publisher 1001') and (Book.Rate=4) and (Book.Progress=37) and
      (Applied.GetReview(Book.BookKey)='Личная заметка ё'),'Reviewed packed generation lost metadata or personal data');
    ArrivalID:=Applied.ResolveBookID('1003',0);
    Require(ArrivalID>0,'Reviewed packed generation omitted the delivered new book');
    CheckBody(ArrivalID,'New reviewed body');

    DeliverArchive('books.zip','1001.txt','Delivered replacement body 1001');
    NewID:=ApplyTo(NewID,True);
    Applied:=SystemDB.GetCollection(NewID,True);
    Require(Applied.ResolveBookID('1001',0)=FirstID,'Pending delivery changed the stable book ID');
    Require(Applied.ResolveBookID('1003',0)=ArrivalID,'Pending delivery changed the previously delivered ID');
    CheckBody(FirstID,'Delivered replacement body 1001');
    CheckBody(ArrivalID,'New reviewed body');
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Publishing the new copy rewrote the original packed catalog');
    Writeln('PASS packed source profile applied separately and completed pending delivery full=',Ord(Full));
    Flush(Output);
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Packed source review requires an isolated G: runtime');
  Folder:=Settings.AppPath+'packed-source-review-'+IntToStr(Ord(WithHistory))+'\'; OriginalRoot:=Folder+'original'; HeldRoot:=Folder+'original-held';
  PackedRoot:=Folder+'packed'; Incoming:=Folder+'incoming'; ForceDirectories(OriginalRoot); ForceDirectories(Incoming);
  BaseIndex:=TPath.Combine(OriginalRoot,'base.inpx'); NextIndex:=TPath.Combine(Incoming,'next.inpx');
  Index(BaseIndex,False); Index(NextIndex,True);
  Zip:=TZipFile.Create;
  try
    Zip.Open(TPath.Combine(OriginalRoot,'books.zip'),zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1001'),'1001.txt');
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1002'),'1002.txt');
  finally Zip.Free; end;
  SourceID:=SystemDB.CreateCollection('Packed source review originals '+IntToStr(Ord(WithHistory)),OriginalRoot,Folder+'source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Worker:=TManualUpdateThread.Create(SourceID,BaseIndex,False,gtFb2);
  try TOORun(Worker); Require(Worker.Success,'Packed review original INPX import failed'); finally Worker.Free; end;
  Source:=SystemDB.GetCollection(SourceID); FirstID:=Source.ResolveBookID('1001',0); SecondID:=Source.ResolveBookID('1002',0);
  Source.SetRate(CreateBookKey(FirstID,SourceID),4); Source.SetProgress(CreateBookKey(FirstID,SourceID),37);
  Source.SetReview(CreateBookKey(FirstID,SourceID),'Личная заметка ё');
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Packed publisher';
  Profile.Location:=Incoming; Profile.IndexFile:='next.inpx'; Profile.BooksRoot:=Incoming;
  if WithHistory then
  begin
    // The raw cache numbers deliberately differ from the live stable IDs.
    Catalog:=TSQLiteDatabase.Create(Source.GetProperty(PROP_DATAFILE));
    try
      Catalog.ExecSQL('UPDATE Books SET BookID=BookID+100');
      Catalog.ExecSQL('UPDATE Author_List SET BookID=BookID+100');
      Catalog.ExecSQL('UPDATE Genre_List SET BookID=BookID+100');
      Catalog.ExecSQL('UPDATE Series_List SET BookID=BookID+100');
      Catalog.ExecSQL('UPDATE PublisherSeries_List SET BookID=BookID+100');
      Catalog.ExecSQL('UPDATE PublisherSeries_Index SET BookID=BookID+100');
    finally Catalog.Free; end;
    // Personal rows follow the stable IDs in this isolated fixture only.
    Personal:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
    try
      Personal.ExecSQL('UPDATE Books SET BookID=BookID+100 WHERE DatabaseID=?',[SourceID]);
      Personal.ExecSQL('UPDATE BookGroups SET BookID=BookID+100 WHERE DatabaseID=?',[SourceID]);
    finally Personal.Free; end;
    FirstID:=FirstID+100; SecondID:=SecondID+100; Source:=SystemDB.GetCollection(SourceID,True);
    var InitialProfile:=Profile; InitialProfile.Location:=OriginalRoot;
    InitialProfile.IndexFile:='base.inpx'; InitialProfile.BooksRoot:=OriginalRoot;
    Stage:=TStagedLibraryIndex.Fetch(InitialProfile,Settings.UpdatePath,nil);
    ReviewPlan:=TLibraryUpdateReview.Create(InitialProfile,Stage);
    try
      ApplyWorker:=CreateLibraryReviewWorker(SourceID,ReviewPlan);
      try TOORun(ApplyWorker); Require(ApplyWorker.Success,'Pre-packing profile review failed'); finally ApplyWorker.Free; end;
      Probe:=TLibraryApplyProbe.Create; Probe.Accept:=True;
      ApplyWorker:=CreateLibraryApplyWorker(SourceID,ReviewPlan,False);
      try
        ApplyWorker.OnShowMessage:=Probe.Confirm; ApplyWorker.Start; ApplyWorker.WaitFor;
        if Assigned(ApplyWorker.FatalException) then raise Exception.Create('Pre-packing application: '+Exception(ApplyWorker.FatalException).Message);
        Require(Probe.Confirmed and ApplyWorker.Success and ApplyWorker.CommittedChanges,
          'Pre-packing profile application did not save an authoritative baseline');
      finally ApplyWorker.Free; Probe.Free; end;
    finally ReviewPlan.Free; Stage.Free; end;
    Source:=SystemDB.GetCollection(SourceID,True);
    Require(LoadLibraryUpdateHistory(Source,Profile,CacheInfo),'Applied pre-packing profile has no history');
    CacheHash:=THashSHA2.GetHashStringFromFile(CacheInfo.CacheFile);
    Catalog:=TSQLiteDatabase.CreateReadOnly(CacheInfo.CacheFile);
    try Require(Catalog.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=''1001''')<>FirstID,
      'Packed history fixture did not separate cache IDs from live stable IDs'); finally Catalog.Free; end;
  end;
  Options:=Default(TCollectionPackingOptions); Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.SourceRoot:=OriginalRoot; Options.OutputRoot:=PackedRoot; Options.SourceID:=SourceID;
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.DisplayName:='Packed source profile baseline '+IntToStr(Ord(WithHistory));
  Options.Python:=Settings.AppPath+'tools\python\python.exe'; Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared; PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  PackedCollection:=SystemDB.GetCollection(PackedID);
  Require(RenameFile(OriginalRoot,HeldRoot),'Cannot hide owned original archive folder');
  try
    for var Deleted:=False to True do
    begin
      if Deleted then PackedCollection.DeleteBook(CreateBookKey(SecondID,PackedID));
      Review(Deleted,False);
      TFile.Copy(TPath.Combine(HeldRoot,'books.zip'),TPath.Combine(Incoming,'books.zip'),False);
      try
        Review(Deleted,True);
        Index(NextIndex,True,True);
        try Review(Deleted,True,True); finally Index(NextIndex,True); end;
      finally TFile.Delete(TPath.Combine(Incoming,'books.zip')); end;
    end;
    ApplyPackedProfile(WithHistory);
  finally Require(RenameFile(HeldRoot,OriginalRoot),'Cannot restore owned original folder'); end;
end;

begin
  Scenario(False); Scenario(True);
end;
