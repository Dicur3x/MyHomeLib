type
  TPackedInstallFixture = record
    CollectionID:Integer;
    ProfileID,IncomingFile,PreviousFile,OriginalRoot:string;
  end;
  TPackedInstaller = reference to procedure(const Plan:ILibraryUpdateRestart;
    const Required:TArray<string>; const Fixture:TPackedInstallFixture);

  TPreviousIndexEditorProbe = class
    Timer:TTimer;
    Path, Failure:string;
    Visited:Boolean;
    procedure FillPreviousIndex(Sender:TObject);
  end;

procedure TPreviousIndexEditorProbe.FillPreviousIndex(Sender:TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmLibraryUpdateSourceEditor) and
      (fsModal in Screen.Forms[I].FormState) then
    begin
      var Editor:=TfrmLibraryUpdateSourceEditor(Screen.Forms[I]);
      Timer.Enabled:=False;
      try
        var Previous:=Editor.FindComponent('edUpdateSourcePreviousIndex');
        Require((Previous is TEdit) and TEdit(Previous).Visible,'Old catalogue source has no previous INPX field');
        TEdit(Previous).Text:=Path;
        TButton(Editor.FindComponent('btnAcceptUpdateSource')).Click;
        Require(Editor.ModalResult=mrOk,'Previous INPX editor did not accept the selected path');
        Visited:=True;
      except
        on E:Exception do
        begin Failure:=E.Message; Editor.ModalResult:=mrCancel; end;
      end;
      Exit;
    end;
end;

function ApplyPackedUpdateFromMain(const Profile: TLibraryUpdateSource; ID: Integer;
  const MissingArchive: string=''; NewBooks: Integer=0; ChangedBooks: Integer=0): Integer;
var
  Driver: TLibraryWindowDriver;
  Timer: TTimer;
  Action: TAction;
  Choice: TMenuItem;
begin
  Choice:=TMenuItem.Create(nil);
  try Choice.Tag:=ID; frmMain.miActiveCollectionClick(Choice);
  finally Choice.Free; end;
  frmMain.Show; Application.ProcessMessages;
  Driver:=TLibraryWindowDriver.Create; Timer:=TTimer.Create(nil);
  try
    Driver.Profile:=Profile; Driver.Accept:=True; Driver.Timer:=Timer;
    Driver.PackedUpdate:=True; Driver.ProtectedCollectionID:=ID;
    Driver.ExpectedMissingArchive:=MissingArchive;
    Driver.ExpectedNewBooks:=NewBooks; Driver.ExpectedChangedBooks:=ChangedBooks;
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

procedure TestPackedSourceReview(LegacyOnly:Boolean=False; ManualPrevious:Boolean=False; ModuleRestart:Boolean=False;
  const StartInstaller:TPackedInstaller=nil; const IncomingFormat:string='inpx');
  procedure Scenario(WithHistory:Boolean);
var Folder,OriginalRoot,HeldRoot,PackedRoot,Incoming,BaseIndex,NextIndex,PreviousInput:string;
  Source,PackedCollection:IBookCollection; SourceID,PackedID,FirstID,SecondID,UntouchedID,OmittedID:Integer;
  Options:TCollectionPackingOptions; Snapshot:TCollectionPackingSnapshot;
  Profile:TLibraryUpdateSource; Dialog:TfrmLibraryUpdateSources;
  Catalog,Personal:TSQLiteDatabase; BeforeRows,BeforePersonal,BeforeINI:string;
  Zip:TZipFile; Worker:TManualUpdateThread; Book:TBookRecord;
  Stage:TStagedLibraryIndex; ReviewPlan:TLibraryUpdateReview; ApplyWorker:TCollectionWorker;
  Probe:TLibraryApplyProbe; CacheInfo:TCatalogSource; CacheHash:string;

  procedure MetabibIndex(const FileName:string; Changed:Boolean);
  var Records:TMemoryStream; Dataset:TFileStream; Archives:TArray<TMetabibExportArchive>; BookCount:Integer;
    procedure AddRecord(ID:Integer; const Carrier:string);
    var Item:TBookRecord; Location:TMetabibExportLocation; Genre:TMetabibGenre;
    begin
      Item:=Default(TBookRecord);
      Item.LibID:=IntToStr(ID); Item.Title:='Publisher '+Item.LibID;
      Item.Lang:='ru'; Item.Date:=EncodeDate(2026,11,18);
      TAuthorsHelper.Add(Item.Authors,'Автор','Тест','');
      Genre:=Default(TMetabibGenre); Genre.Code:='prose_contemporary';
      Location:=Default(TMetabibExportLocation);
      Location.ArchiveID:=Carrier; Location.EntryName:=Item.LibID+'.txt';
      Location.ExportBookID:=ID; Location.UncompressedSize:=123;
      if ID=1002 then Location.EntryIndex:=1;
      if Changed and (ID=1001) then
      begin
        Item.Title:='Corrected publisher 1001';
        Item.Date:=EncodeDate(2026,11,19); Location.UncompressedSize:=456;
      end;
      TMetabibWriter.WriteRecord(Records,Item,TArray<TMetabibGenre>.Create(Genre),Location,'flibusta','fixture');
      Inc(BookCount);
    end;
    procedure AddArchive(const Name:string; Entries:Integer);
    var Entry:TMetabibExportArchive;
    begin
      Entry:=Default(TMetabibExportArchive);
      Entry.ID:=Name; Entry.Name:=Name+'.zip'; Entry.Ordinal:=Length(Archives); Entry.Entries:=Entries;
      Archives:=Archives+[Entry];
    end;
  begin
    BookCount:=0; Records:=TMemoryStream.Create;
    try
      AddArchive('books',2); AddRecord(1001,'books'); AddRecord(1002,'books');
      AddArchive('new',1); AddRecord(1003,'new');
      if LegacyOnly then begin AddArchive('untouched',1); AddRecord(1004,'untouched'); end;
      Dataset:=TFileStream.Create(FileName,fmCreate);
      try TMetabibWriter.WriteDataset(Dataset,Records,'packed-standalone-fixture','flibusta','3.0',
        EncodeDate(2026,11,19),BookCount,Archives);
      finally Dataset.Free; end;
    finally Records.Free; end;
  end;

  procedure Index(const FileName:string; NewBook:Boolean; Changed:Boolean=False; Version:Integer=0);
    function Row(ID:Integer):string;
    begin
      if Changed and (ID=1001) then
        Exit('Автор,Тест:'#4'prose_contemporary:'#4'Corrected publisher 1001'#4#4#4'1001'#4'456'#4'1001'#4'0'#4'txt'#4'2026-11-19'#4'ru'+sLineBreak);
      Result:='Автор,Тест:'#4'prose_contemporary:'#4'Publisher '+IntToStr(ID)+#4#4#4+
        IntToStr(ID)+#4'123'#4+IntToStr(ID)+#4'0'#4'txt'#4'2026-11-18'#4'ru'+sLineBreak;
    end;
  var Z:TZipFile;
  begin
    if SameText(ExtractFileExt(FileName),'.jsonl') then
    begin
      MetabibIndex(FileName,Changed);
      Exit;
    end;
    Z:=TZipFile.Create;
    try
      Z.Open(FileName,zmWrite);
      Z.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      if ManualPrevious then
      begin
        if Version=0 then Version:=20261117+Ord(NewBook);
        Z.Add(TEncoding.UTF8.GetBytes(IntToStr(Version)),'version.info');
      end;
      Z.Add(TEncoding.UTF8.GetBytes(Row(1001)+Row(1002)),'books.inp');
      if LegacyOnly and not NewBook then
        Z.Add(TEncoding.UTF8.GetBytes(Row(1004)),'untouched.inp');
      if (IncomingFormat<>'inpx') and not NewBook then
        Z.Add(TEncoding.UTF8.GetBytes(Row(1005)),'omitted.inp');
      if NewBook then Z.Add(TEncoding.UTF8.GetBytes(Row(1003)),'new.inp');
    finally Z.Free; end;
  end;

  procedure CheckManualPreviousSelection;
  var EditorProbe:TPreviousIndexEditorProbe; SavedProfile:TLibraryUpdateSource;
    WrongVersion,WrongBook,Warnings,BeforeHash:string; BeforeWorkspace:Integer;
    Restored:TLibraryUpdateSources;
    procedure Reject(const Path, Explanation:string);
    var Report:string;
    begin
      Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
      try
        var Input:=Profile;
        Input.PreviousIndexFile:=Path;
        Dialog.AppendSource(Input);
        TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
        Report:=TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption;
        Require(not Assigned(Dialog.Review) and not TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled and
          Report.Contains(Explanation),'Previous INPX check for "'+ExtractFileName(Path)+'" expected "'+Explanation+'": '+Report);
      finally FreeAndNil(Dialog); end;
    end;
  begin
    WrongVersion:=TPath.Combine(Folder,'wrong-version.inpx');
    WrongBook:=TPath.Combine(Folder,'wrong-book.inpx');
    Index(WrongVersion,False,False,20261118);
    Index(WrongBook,False,True,20261117);
    BeforeHash:=THashSHA2.GetHashStringFromFile(PackedCollection.GetProperty(PROP_DATAFILE));
    BeforeWorkspace:=Length(TDirectory.GetDirectories(Settings.UpdatePath,'HomeLibre-index-*'));
    Reject('','выберите его в настройке источника');
    Reject(WrongVersion,'не совпадает с версией сжатой коллекции');
    Reject(WrongBook,'не подтверждает исходный файл');
    Require(THashSHA2.GetHashStringFromFile(PackedCollection.GetProperty(PROP_DATAFILE))=BeforeHash,
      'Rejected previous INPX changed the original catalogue');
    Require(Length(TDirectory.GetDirectories(Settings.UpdatePath,'HomeLibre-index-*'))=BeforeWorkspace,
      'Rejected previous INPX leaked a private review folder');
    Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
    EditorProbe:=TPreviousIndexEditorProbe.Create;
    try
      Dialog.AppendSource(Profile);
      EditorProbe.Path:=PreviousInput;
      EditorProbe.Timer:=TTimer.Create(Dialog);
      EditorProbe.Timer.Interval:=1;
      EditorProbe.Timer.OnTimer:=EditorProbe.FillPreviousIndex;
      EditorProbe.Timer.Enabled:=True;
      TButton(Dialog.FindComponent('btnEditUpdateSource')).Click;
      Require(EditorProbe.Visited and (EditorProbe.Failure=''),'Could not edit the previous index path: '+EditorProbe.Failure);
      SavedProfile:=Dialog.Sources[0];
      Require(SavedProfile.PreviousIndexFile=PreviousInput,'Edited previous index did not reach the profile');
      Restored:=ReadLibraryUpdateSources(WriteLibraryUpdateSources(Dialog.Sources));
      Require((Length(Restored)=1) and (Restored[0].PreviousIndexFile=PreviousInput),'JSON lost the previous index path');
      Restored:=ImportLegacyUpdateSources(ExportLegacyUpdateSources(Dialog.Sources),'',Warnings);
      Require((Length(Restored)=1) and (Restored[0].PreviousIndexFile=PreviousInput),'INI lost the previous index path');
      Profile:=SavedProfile;
    finally
      EditorProbe.Timer.Free;
      EditorProbe.Free;
      FreeAndNil(Dialog);
    end;
    Writeln('PASS legacy packed source editor accepts the previous INPX and rejects missing version and artifact mismatches');
    Flush(Output);
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
      if LegacyOnly then
        Require(Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''HomeLibrePackingPublishers''')=0,
          'Legacy preview wrote publisher metadata into the original catalogue')
      else
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
    function QueueModuleRestart(out Required:TArray<string>):ILibraryUpdateRestart;
    var Dialog:TfrmLibraryUpdateSources;
    begin
      Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
      try
        Dialog.AllowModuleRestart:=True;
        Dialog.SelectProfile(Profile.ID);
        Dialog.CheckSource;
        Dialog.ApplyReviewed(True);
        Result:=Dialog.PendingRestart;
        Required:=Dialog.RestartComponents;
        Require(Assigned(Result) and not Dialog.Committed and (Length(Required)=1) and
          SameText(Required[0],'BookProcessing'),
          'Missing module did not defer the checked update: '+TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption);
      finally Dialog.Free; end;
    end;
    procedure StartActualInstaller;
    var Pending:ILibraryUpdateRestart; Required:TArray<string>; Fixture:TPackedInstallFixture; Archive:TZipFile;
    begin
      Archive:=TZipFile.Create;
      try
        Archive.Open(TPath.Combine(PackedRoot,'new.zip'),zmWrite);
        Archive.Add(TEncoding.UTF8.GetBytes('Other archive from the collection root'),'1003.txt');
      finally Archive.Free; end;
      var Tool:=Settings.AppPath+'tools\python\python.exe';
      Require(RenameFile(Tool,Tool+'.held'),'Could not hide the private module runtime before real installation');
      Pending:=QueueModuleRestart(Required);
      Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Preparing module installation wrote the catalogue');
      Require(RenameFile(NextIndex,NextIndex+'.held'),'Could not take the new INPX offline');
      Require(RenameFile(PreviousInput,PreviousInput+'.held'),'Could not take the earlier INPX offline');
      Fixture.CollectionID:=PackedID; Fixture.ProfileID:=Profile.ID;
      Fixture.IncomingFile:=NextIndex; Fixture.PreviousFile:=PreviousInput; Fixture.OriginalRoot:=OriginalRoot;
      Settings.ActiveCollection:=PackedID;
      Settings.SaveSettings;
      StartInstaller(Pending,Required,Fixture);
    end;
    function ApplyThroughModuleRestart:Integer;
    var Pending,Restored:ILibraryUpdateRestart; Dialog:TfrmLibraryUpdateSources;
      WorkRoot,Tool,Argument,BackupFile:string; Probe:TLibraryApplyProbe;
      ApplyWorker:TCollectionWorker; Required:TArray<string>;
      function Queue:ILibraryUpdateRestart;
      begin Result:=QueueModuleRestart(Required); end;
      procedure Decline;
      var Abandoned:ILibraryUpdateRestart;
      begin
        Abandoned:=Queue;
        Require(Assigned(Abandoned),'No update was prepared to decline');
      end;
      function ArmUpdate:string;
      var Plan:ILibraryUpdateRestart;
      begin
        Plan:=Queue;
        Result:=Plan.Arm;
      end;
      procedure RejectTampered(const Name,Reason:string);
      var Token,PrivateDirectory:string; Plan:ILibraryUpdateRestart; Invalid:TStagedLibraryIndex; Denied:Boolean;
      begin
        Token:=ArmUpdate;
        PrivateDirectory:=TPath.Combine(WorkRoot,'HomeLibre-library-resume-'+
          Copy(Token,Length(LIBRARY_UPDATE_RESUME_SWITCH)+1,38));
        TFile.AppendAllText(TPath.Combine(PrivateDirectory,Name),'changed',TEncoding.UTF8);
        Denied:=False;
        try
          Plan:=TakeLibraryUpdateRestart(WorkRoot,Token);
          Require(Assigned(Plan),'Corruption test did not reach the restart plan');
          Invalid:=Plan.OpenIndex(False);
          Invalid.Free;
        except on E:EReadError do Denied:=Pos(Reason,E.Message)>0; end;
        Require(Denied,'Changed restart data was accepted: '+Name);
      end;
    begin
      WorkRoot:=Settings.LibraryUpdateWorkPath;
      Tool:=Settings.AppPath+'tools\python\python.exe';
      BackupFile:=Tool+'.held';
      Require(RenameFile(Tool,BackupFile),'Could not hide the private BookProcessing runtime');
      try
        Decline;
        Require(Length(TDirectory.GetDirectories(WorkRoot,'HomeLibre-library-resume-*'))=0,
          'Declining the missing module left a saved restart');
        RejectTampered('resume.json','Параметры продолжения обновления изменились');
        RejectTampered('incoming.inpx','Служебная копия индекса обновления изменилась');
        Require(Length(TDirectory.GetDirectories(WorkRoot,'HomeLibre-library-resume-*'))=0,
          'Rejecting changed restart data retained a private bundle');
        Pending:=Queue;
        Argument:=Pending.Arm;
        Pending.Disarm;
        Require(not Assigned(TakeLibraryUpdateRestart(WorkRoot,Argument)),
          'A failed installer launch left a usable restart token');
        Argument:=Pending.Arm;
        Require(not Assigned(TakeLibraryUpdateRestart(WorkRoot,LIBRARY_UPDATE_RESUME_SWITCH+
          TGUID.NewGuid.ToString+':'+StringOfChar('0',64))),'A different token claimed another update');
        Pending:=nil;
      finally Require(RenameFile(BackupFile,Tool),'Could not restore the private BookProcessing runtime'); end;
      Require(RenameFile(NextIndex,NextIndex+'.held'),'Could not hide the incoming index');
      Require(RenameFile(PreviousInput,PreviousInput+'.restart-held'),'Could not hide the earlier index');
      try
        Restored:=TakeLibraryUpdateRestart(WorkRoot,Argument);
        Require(Assigned(Restored) and Restored.Request.PreferNewRoot and
          not Assigned(TakeLibraryUpdateRestart(WorkRoot,Argument)),'Continuation did not keep the archive choice or was consumed twice');
        Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
        try
          Dialog.RestoreRestart(Restored);
          Require(Assigned(Dialog.Review) and Dialog.Review.Ready and not Dialog.Committed and
            (Dialog.Review.NewBooks=1) and (Dialog.Review.ChangedBooks=1),
            'Restoring the update did not present the original review');
          Restored:=nil;
          Probe:=TLibraryApplyProbe.Create;
          Probe.Accept:=True;
          ApplyWorker:=CreateLibraryApplyWorker(PackedID,Dialog.Review,True);
          try
            ApplyWorker.OnShowMessage:=Probe.Confirm;
            ApplyWorker.Start; ApplyWorker.WaitFor;
            if Assigned(ApplyWorker.FatalException) then
              raise Exception.Create('Resumed update: '+Exception(ApplyWorker.FatalException).Message);
            Require(Probe.Confirmed and ApplyWorker.CommittedChanges,'Resumed update bypassed confirmation or failed to publish');
            Result:=Dialog.Review.PublishedCollectionID;
          finally ApplyWorker.Free; Probe.Free; end;
        finally Dialog.Free; end;
      finally
        Require(RenameFile(NextIndex+'.held',NextIndex),'Could not restore the incoming index');
        Require(RenameFile(PreviousInput+'.restart-held',PreviousInput),'Could not restore the earlier index');
      end;
      Require((Result>0) and (Result<>PackedID) and (Length(TDirectory.GetDirectories(WorkRoot,'HomeLibre-library-resume-*'))=0),
        'Resumed update did not publish separately or left restart data');
      Writeln('PASS missing BookProcessing resumes a verified packed update with both original indexes offline');
      Flush(Output);
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
    procedure CheckRepeatReview(ID:Integer);
    begin
      Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
      ReviewPlan:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        ApplyWorker:=CreateLibraryReviewWorker(ID,ReviewPlan);
        try TOORun(ApplyWorker);
          Require(ApplyWorker.Success and (ReviewPlan.NewBooks=0) and
            (ReviewPlan.ChangedBooks=0) and (ReviewPlan.NeededArchives.Count=0),
            'Repeating the same snapshot still schedules a change: '+ReviewPlan.Summary);
        finally ApplyWorker.Free; end;
      finally ReviewPlan.Free; Stage.Free; end;
    end;
  begin
    Profile.Full:=Full;
    Index(NextIndex,True,True);
    PackedCollection.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,
      WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
    PreviousFile:=PackedCollection.GetProperty(PROP_DATAFILE);
    PreviousHash:=THashSHA2.GetHashStringFromFile(PreviousFile);
    DeliverArchive('new.zip','1003.txt','New reviewed body');
    if Assigned(StartInstaller) then
    begin
      StartActualInstaller;
      Exit;
    end;
    ApplyTo(PackedID,False);
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Declining changed the original packed catalog');
    ApplyTo(PackedID,True,True);
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Cancellation changed the original packed catalog');
    if ModuleRestart then NewID:=ApplyThroughModuleRestart else NewID:=ApplyPackedUpdateFromMain(Profile,PackedID);
    Require(NewID<>PackedID,'Reviewed update replaced the original collection');
    Applied:=SystemDB.GetCollection(NewID,True);
    Require(Assigned(Applied) and LoadLibraryUpdateHistory(Applied,Profile,AppliedHistory),
      'Reviewed packed generation has no published source history');
    Require(Applied.ResolveBookID('1001',0)=FirstID,'Reviewed packed generation changed the stable book ID');
    Require(Applied.ResolveBookID('1002',0)=0,'Reviewed packed generation restored a deleted card');
    if IncomingFormat<>'inpx' then
    begin
      Require(PackedCollection.ResolveBookID('1005',0)=OmittedID,'Publishing changed the original collection');
      if Full or (IncomingFormat='jsonl') then
        Require(Applied.ResolveBookID('1005',0)=0,'The new full catalogue retained a record missing from its index')
      else
        Require(Applied.ResolveBookID('1005',0)=OmittedID,'An incremental package removed an unrelated record');
    end;
    CheckBody(FirstID,'Original body 1001');
    Require((Book.Title='Corrected publisher 1001') and (Book.Rate=4) and (Book.Progress=37) and
      (Applied.GetReview(Book.BookKey)='Личная заметка ё'),'Reviewed packed generation lost metadata or personal data');
    ArrivalID:=Applied.ResolveBookID('1003',0);
    Require(ArrivalID>0,'Reviewed packed generation omitted the delivered new book');
    CheckBody(ArrivalID,'New reviewed body');
    if LegacyOnly then
    begin
      Require(Applied.ResolveBookID('1004',0)=UntouchedID,'Legacy update lost the unrelated existing book');
      CheckBody(UntouchedID,'Untouched legacy body');
      Catalog:=TSQLiteDatabase.CreateReadOnly(Applied.GetProperty(PROP_DATAFILE));
      try
        Require(Catalog.QuerySingleInt('SELECT BookSize FROM HomeLibrePackingPublishers WHERE BookID=?',[UntouchedID])=123,
          'Legacy update did not restore publisher metadata for the unrelated book');
      finally Catalog.Free; end;
    end;

    if ManualPrevious then
      Require(RenameFile(PreviousInput,PreviousInput+'.held'),'Could not hide the chosen previous INPX for retry');
    DeliverArchive('books.zip','1001.txt','Delivered replacement body 1001');
    NewID:=ApplyTo(NewID,True);
    Applied:=SystemDB.GetCollection(NewID,True);
    Require(Applied.ResolveBookID('1001',0)=FirstID,'Pending delivery changed the stable book ID');
    Require(Applied.ResolveBookID('1003',0)=ArrivalID,'Pending delivery changed the previously delivered ID');
    CheckBody(FirstID,'Delivered replacement body 1001');
    CheckBody(ArrivalID,'New reviewed body');
    if LegacyOnly then
    begin
      CheckBody(UntouchedID,'Untouched legacy body');
      Writeln('PASS legacy packed INPX uses a trusted previous index and preserves untouched and deleted books');
      if ManualPrevious then Writeln('PASS legacy packed update creates reusable history for a manually selected previous INPX');
    end;
    Require(THashSHA2.GetHashStringFromFile(PreviousFile)=PreviousHash,'Publishing the new copy rewrote the original packed catalog');
    Writeln('PASS packed source profile applied separately and completed pending delivery full=',Ord(Full));
    if IncomingFormat<>'inpx' then
    begin
      CheckRepeatReview(NewID);
      Writeln('PASS standalone packed publisher update through the ordinary window format=',IncomingFormat,
        ' history=',Ord(WithHistory),' manual=',Ord(ManualPrevious));
    end;
    Flush(Output);
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Packed source review requires an isolated G: runtime');
  Folder:=Settings.AppPath+'packed-source-review-'+IntToStr(Ord(WithHistory))+'\'; OriginalRoot:=Folder+'original'; HeldRoot:=Folder+'original-held';
  PackedRoot:=Folder+'packed'; Incoming:=Folder+'incoming'; ForceDirectories(OriginalRoot); ForceDirectories(Incoming);
  BaseIndex:=TPath.Combine(OriginalRoot,'base.inpx');
  NextIndex:=TPath.Combine(Incoming,'next.'+IncomingFormat);
  Index(BaseIndex,False); Index(NextIndex,True);
  if ManualPrevious then
  begin
    PreviousInput:=TPath.Combine(Folder,'прежний полный.inpx');
    TFile.Copy(BaseIndex,PreviousInput,False);
  end;
  Zip:=TZipFile.Create;
  try
    Zip.Open(TPath.Combine(OriginalRoot,'books.zip'),zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1001'),'1001.txt');
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1002'),'1002.txt');
  finally Zip.Free; end;
  if IncomingFormat<>'inpx' then
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(TPath.Combine(OriginalRoot,'omitted.zip'),zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('Body outside the update'),'1005.txt');
    finally Zip.Free; end;
  end;
  if ManualPrevious then
  begin
    var TextFile:=TPath.Combine(Folder,'1004.txt');
    TFile.WriteAllBytes(TextFile,TEncoding.UTF8.GetBytes('Untouched legacy body'));
    var Sink:=TMemoryStream.Create;
    try
      RunExternalToolToStream(Settings.AppPath+'tools\7zip\7za.exe',
        TArray<string>.Create('a','-t7z','-mx=0','-y',TPath.Combine(OriginalRoot,'untouched.7z'),TextFile),Sink);
    finally Sink.Free; end;
  end
  else if LegacyOnly then
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(TPath.Combine(OriginalRoot,'untouched.zip'),zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('Untouched legacy body'),'1004.txt');
    finally Zip.Free; end;
  end;
  SourceID:=SystemDB.CreateCollection('Packed source review originals '+IntToStr(Ord(WithHistory)),OriginalRoot,Folder+'source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Worker:=TManualUpdateThread.Create(SourceID,BaseIndex,False,gtFb2);
  try TOORun(Worker); Require(Worker.Success,'Packed review original INPX import failed'); finally Worker.Free; end;
  Source:=SystemDB.GetCollection(SourceID); FirstID:=Source.ResolveBookID('1001',0); SecondID:=Source.ResolveBookID('1002',0);
  Source.SetRate(CreateBookKey(FirstID,SourceID),4); Source.SetProgress(CreateBookKey(FirstID,SourceID),37);
  Source.SetReview(CreateBookKey(FirstID,SourceID),'Личная заметка ё');
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Packed publisher';
  Profile.Location:=Incoming; Profile.IndexFile:=ExtractFileName(NextIndex); Profile.BooksRoot:=Incoming;
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
  if IncomingFormat<>'inpx' then
  begin
    OmittedID:=PackedCollection.ResolveBookID('1005',0);
    Require(OmittedID>0,'The packed original lacks the book omitted by the new index');
  end;
  if LegacyOnly then
  begin
    UntouchedID:=PackedCollection.ResolveBookID('1004',0);
    Require(UntouchedID>0,'Legacy fixture is missing its untouched baseline card');
    Catalog:=TSQLiteDatabase.Create(PackedCollection.GetProperty(PROP_DATAFILE));
    try
      Catalog.ExecSQL('DROP TABLE HomeLibrePackingPublishers');
    finally Catalog.Free; end;
    PackedCollection:=SystemDB.GetCollection(PackedID,True);
  end;
  Require(RenameFile(OriginalRoot,HeldRoot),'Cannot hide owned original archive folder');
  try
    if Assigned(StartInstaller) then
    begin
      Profile.PreviousIndexFile:=PreviousInput;
      PackedCollection.DeleteBook(CreateBookKey(SecondID,PackedID));
      ApplyPackedProfile(False);
      Exit;
    end;
    if ManualPrevious then CheckManualPreviousSelection;
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
    ApplyPackedProfile(WithHistory and not LegacyOnly);
  finally
    if not Assigned(StartInstaller) then
      Require(RenameFile(HeldRoot,OriginalRoot),'Cannot restore owned original folder');
  end;
end;

begin
  Require(MatchText(IncomingFormat,['inpx','jsonl','zip']),'Unsupported standalone fixture format');
  if not LegacyOnly or ManualPrevious then Scenario(False);
  if not ManualPrevious then Scenario(True);
end;

procedure TestPackedBoundSourceApply(const MetabibFormat: string=''; EmptySnapshot: Boolean=False);
var
  Folder, Download, PackedRoot, OriginalFile, OriginalSHA: string;
  Sources: TCatalogSources;
  Profile: TLibraryUpdateSource;
  SourceID, PackedID, SharedID, OtherID, ResultID: Integer;
  Source, Target: IBookCollection;
  Options: TCollectionPackingOptions;
  Snapshot: TCollectionPackingSnapshot;
  Merge: TCatalogMergeWorker;
  Plan: TCollectionMergePlan;
  Refresh: TCatalogRefreshWorker;
  Book: TBookRecord;
  PreferredPath, OriginalLowerPath, OriginalOtherPath, PreferredSourceName: string;

  function Row(ID: Integer; const Name, Title: string; Replaced: Boolean=False): string;
  begin
    Result:='Author,Test:'#4'prose_contemporary:'#4+Title+#4#4#4+Name+#4+
      IntToStr(123+Ord(Replaced))+#4+IntToStr(ID)+#4'0'#4'txt'#4'2026-11-18'#4'ru'+sLineBreak;
  end;

  procedure WriteArchive(const FileName, Member, Body: string);
  var Archive: TZipFile;
  begin
    Archive:=TZipFile.Create;
    try
      Archive.Open(FileName,zmWrite);
      Archive.Add(TEncoding.UTF8.GetBytes(Body),Member+'.txt');
    finally Archive.Free; end;
  end;

  procedure WriteIndex(const FileName, SharedTitle, OtherTitle: string; Revised: Boolean);
  var Archive: TZipFile;
  begin
    Archive:=TZipFile.Create;
    try
      Archive.Open(FileName,zmWrite);
      Archive.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Archive.Add(TEncoding.UTF8.GetBytes('20261118'),'version.info');
      Archive.Add(TEncoding.UTF8.GetBytes(Row(2001,'shared',SharedTitle,Revised)),'shared.inp');
      if OtherTitle<>'' then Archive.Add(TEncoding.UTF8.GetBytes(Row(2002,'other',OtherTitle)),'other.inp');
      if Revised then Archive.Add(TEncoding.UTF8.GetBytes(Row(2003,'arrival','Bound arrival')),'arrival.inp');
    finally Archive.Free; end;
  end;

  procedure WriteZstdFixture(const JSONL, FileName: string);
  var
    Module: HMODULE;
    CompressBound: function(Size: NativeUInt): NativeUInt; cdecl;
    Compress: function(Dest: Pointer; Capacity: NativeUInt; Source: Pointer;
      Size: NativeUInt; Level: Integer): NativeUInt; cdecl;
    IsError: function(Code: NativeUInt): Cardinal; cdecl;
    Plain, Encoded: TBytes;
    Size: NativeUInt;
  begin
    Module:=LoadLibrary(PChar(Settings.AppPath+'libzstd.dll'));
    Require(Module<>0,'Test Zstandard DLL is unavailable');
    try
      CompressBound:=GetProcAddress(Module,'ZSTD_compressBound');
      Compress:=GetProcAddress(Module,'ZSTD_compress');
      IsError:=GetProcAddress(Module,'ZSTD_isError');
      Require(Assigned(CompressBound) and Assigned(Compress) and Assigned(IsError),'Test Zstandard export is missing');
      Plain:=TFile.ReadAllBytes(JSONL);
      SetLength(Encoded,CompressBound(Length(Plain)));
      Size:=Compress(@Encoded[0],Length(Encoded),@Plain[0],Length(Plain),3);
      Require((IsError(Size)=0) and (Size<=NativeUInt(Length(Encoded))),'Cannot write test Zstandard catalogue');
      SetLength(Encoded,Size);
      TFile.WriteAllBytes(FileName,Encoded);
    finally FreeLibrary(Module); end;
  end;

  procedure WriteMetabib(const FileName: string);
  var
    Records: TMemoryStream;
    Dataset: TFileStream;
    Archive: TZipFile;
    Archives: TArray<TMetabibExportArchive>;
    JSONL: string;

    procedure AddRecord(ID, Size: Integer; const Member, Title: string);
    var
      Item: TBookRecord;
      Location: TMetabibExportLocation;
      Genre: TMetabibGenre;
      Volume: TMetabibExportArchive;
    begin
      Item:=Default(TBookRecord);
      Item.Title:=Title; Item.LibID:=IntToStr(ID); Item.Lang:='ru';
      Item.Date:=EncodeDate(2026,11,18);
      TAuthorsHelper.Add(Item.Authors,'Author','Test','');
      Genre:=Default(TMetabibGenre); Genre.Code:='prose_contemporary';
      Location:=Default(TMetabibExportLocation);
      Location.ArchiveID:=Member; Location.EntryName:=Member+'.txt';
      Location.ExportBookID:=ID; Location.UncompressedSize:=Size;
      Volume:=Default(TMetabibExportArchive);
      Volume.ID:=Member; Volume.Name:=Member+'.zip'; Volume.Ordinal:=Length(Archives);
      Volume.Entries:=1; Archives:=Archives+[Volume];
      TMetabibWriter.WriteRecord(Records,Item,TArray<TMetabibGenre>.Create(Genre),Location,'flibusta','fixture');
    end;
  begin
    JSONL:=TPath.Combine(Download,'revised.jsonl');
    Records:=TMemoryStream.Create;
    try
      if not EmptySnapshot then
      begin
        AddRecord(2001,124,'shared','Lower revised');
        AddRecord(2002,123,'other','Corrected other title');
        AddRecord(2003,123,'arrival','Bound arrival');
      end;
      Dataset:=TFileStream.Create(JSONL,fmCreate);
      try TMetabibWriter.WriteDataset(Dataset,Records,'packed-source-fixture','flibusta','3.0',
        EncodeDate(2026,11,18),Length(Archives),Archives);
      finally Dataset.Free; end;
      if MetabibFormat='jsonl.gz' then
        RunExternalToolToStream(Settings.AppPath+'tools\7zip\7za.exe',
          TArray<string>.Create('a','-tgzip','-y',FileName,JSONL),Records);
    finally Records.Free; end;
    if MetabibFormat='zip' then
    begin
      Archive:=TZipFile.Create;
      try
        Archive.Open(FileName,zmWrite);
        Archive.Add(JSONL,'catalogue.jsonl');
      finally Archive.Free; end;
    end;
    if MetabibFormat='jsonl.zst' then WriteZstdFixture(JSONL,FileName);
    Require(FileExists(FileName) and TMetabibReader.IsDatasetFile(FileName),
      'Written index did not classify as Metabib');
  end;

  function FindID(const Collection: IBookCollection; const ID: string): Integer;
  var Books: IBookIterator; Item: TBookRecord;
  begin
    Books:=Collection.GetBookIterator(bmAll,True);
    while Books.Next(Item) do
      if Item.DisplayLibID=ID then Exit(Item.BookKey.BookID);
    Result:=0;
  end;

  function Content(const Item: TBookRecord): string;
  var Stream: TStream; Bytes: TBytes;
  begin
    Stream:=Item.GetBookStream(True,False);
    Require(Assigned(Stream),'Packed bound source has an unreadable copy');
    try
      SetLength(Bytes,Stream.Size);
      Stream.ReadBuffer(Bytes,Length(Bytes));
      Result:=TEncoding.UTF8.GetString(Bytes);
    finally Stream.Free; end;
  end;

  function Update(ID, NewBooks, ChangedBooks, MissingBooks: Integer): Integer;
  var Stage: TStagedLibraryIndex; Review: TLibraryUpdateReview;
    Worker: TCollectionWorker; Probe: TLibraryApplyProbe;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
    Review:=TLibraryUpdateReview.Create(Profile,Stage);
    try
      Worker:=CreateLibraryReviewWorker(ID,Review);
      try TOORun(Worker); Require(Worker.Success and Review.Ready,'Bound packed review failed');
      finally Worker.Free; end;
      Require((Review.NewBooks=NewBooks) and (Review.ChangedBooks=ChangedBooks) and
        (Review.NeededArchives.Count=MissingBooks),
        'Bound packed review requests an old archive or miscounts changes: '+Review.Summary);
      if MissingBooks>0 then Require(SameText(Review.NeededArchives[0],'shared.zip'),
        'The bound packed review requested the wrong archive');
      Probe:=TLibraryApplyProbe.Create;
      Probe.Accept:=True;
      Worker:=CreateLibraryApplyWorker(ID,Review,False);
      try
        Worker.OnShowMessage:=Probe.Confirm;
        Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then
          raise Exception.Create('Bound packed apply: '+Exception(Worker.FatalException).Message);
        Result:=Review.PublishedCollectionID;
        Require(Probe.Confirmed and Worker.Success and Worker.CommittedChanges and (Result>0) and (Result<>ID),
          'Bound packed apply did not publish a new collection');
        Require(Review.MissingBooks=MissingBooks,'Bound packed apply miscounts missing books: '+Review.MissingDetails);
      finally Worker.Free; Probe.Free; end;
    finally Review.Free; Stage.Free; end;
  end;

  procedure RejectEmptyMetabib;
  var
    Stage: TStagedLibraryIndex;
    Review: TLibraryUpdateReview;
    Worker: TCollectionWorker;
    Probe: TLibraryApplyProbe;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        Worker:=CreateLibraryReviewWorker(PackedID,Review);
        try TOORun(Worker); Require(Worker.Success and Review.Ready and
          (Review.NewBooks=0) and (Review.ChangedBooks=0),'The empty Metabib header was not read');
        finally Worker.Free; end;
        Probe:=TLibraryApplyProbe.Create;
        try
          Worker:=CreateLibraryApplyWorker(PackedID,Review,False);
          try
            Worker.OnShowMessage:=Probe.Confirm;
            Worker.Start; Worker.WaitFor;
            Require(not Probe.Confirmed and not Worker.CommittedChanges and
              Assigned(Worker.FatalException) and
              Exception(Worker.FatalException).Message.Contains('Полный индекс пуст'),
              'Empty Metabib was not rejected as a full snapshot with append selected');
            Require((Review.PublishedCollectionID=0) and
              (THashSHA2.GetHashStringFromFile(OriginalFile)=OriginalSHA),
              'Rejected empty Metabib modified the original catalogue');
          finally Worker.Free; end;
        finally Probe.Free; end;
      finally Review.Free; end;
    finally Stage.Free; end;
    Writeln('PASS empty Metabib is rejected as a full snapshot even with append selected: ',MetabibFormat);
    Flush(Output);
  end;

  procedure CheckUpdated(ID: Integer; ReplacementArrived: Boolean);
  var Copies: TArray<TBookRecord>; FoundFirst, FoundSecond: Boolean; Baseline: TCatalogSource;
  begin
    Target:=SystemDB.GetCollection(ID,True);
    Require(LoadLibraryUpdateHistory(Target,Profile,Baseline),'Bound packed apply lost its source-specific publisher history');
    Require((FindID(Target,'2001')=SharedID) and (FindID(Target,'2002')=OtherID),
      'Bound packed update changed retained book IDs');
    Target.GetBookRecord(CreateBookKey(SharedID,ID),Book,True);
    Require((Book.Title='Preferred original') and (Content(Book)='Preferred original body') and
      (Book.GetBookFileName=PreferredPath) and (Book.CollectionName=PreferredSourceName) and
      (Book.Rate=4) and (Book.Progress=42) and (Target.GetReview(Book.BookKey)='Saved bound review'),
      'Bound packed update changed preferred copy or personal fields');
    var UserData:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try
      Require(UserData.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE DatabaseID=? AND BookID=? AND GroupID=?',
        [ID,SharedID,FAVORITES_GROUP_ID])=1,'Bound packed update lost the favorites membership');
    finally UserData.Free; end;
    Copies:=Target.GetCatalogBookCopies(Book.BookKey);
    Require(Length(Copies)=2,'Bound packed update duplicated or lost a copy');
    FoundFirst:=False; FoundSecond:=False;
    for var CopyBook in Copies do
    begin
      if CopyBook.CollectionName=Sources[0].Name then
        FoundFirst:=(Content(CopyBook)='Preferred original body') and (CopyBook.GetBookFileName=PreferredPath);
      if CopyBook.CollectionName=Sources[1].Name then
        if ReplacementArrived then
          FoundSecond:=(Content(CopyBook)='Replaced lower body') and (CopyBook.GetBookFileName<>OriginalLowerPath)
        else FoundSecond:=(Content(CopyBook)='Lower original body') and (CopyBook.GetBookFileName=OriginalLowerPath);
    end;
    Require(FoundFirst and FoundSecond,'Bound packed update replaced the wrong payload');
    Target.GetBookRecord(CreateBookKey(OtherID,ID),Book,True);
    Require((Book.Title='Corrected other title') and (Content(Book)='Retained other body') and
      (Book.GetBookFileName=OriginalOtherPath),'Metadata-only update replaced an existing packed payload');
    var ArrivalID:=FindID(Target,'2003');
    Require(ArrivalID>0,'Bound packed apply lost the new book');
    Target.GetBookRecord(CreateBookKey(ArrivalID,ID),Book,True);
    Require(Content(Book)='Bound arrival body','Bound packed apply did not install the new member');
    Require(THashSHA2.GetHashStringFromFile(OriginalFile)=OriginalSHA,'Bound packed publication rewrote the original catalogue');
  end;

begin
  RequireIsolatedRegression;
  Folder:=Settings.AppPath+'packed-bound-update';
  Download:=TPath.Combine(Folder,'download'); ForceDirectories(Download);
  PackedRoot:=TPath.Combine(Folder,'packed');
  SetLength(Sources,2);
  for var I:=0 to High(Sources) do
  begin
    Sources[I].ID:=TCatalogSource.NewID;
    Sources[I].Name:='Bound source '+IntToStr(I);
    Sources[I].Root:=TPath.Combine(Folder,'source-'+IntToStr(I));
    Sources[I].LibraryNamespace:='flibusta';
    ForceDirectories(Sources[I].Root);
    Sources[I].INPXFile:=TPath.Combine(Sources[I].Root,'original.inpx');
    if I=0 then
    begin
      WriteIndex(Sources[I].INPXFile,'Preferred original','',False);
      WriteArchive(TPath.Combine(Sources[I].Root,'shared.zip'),'shared','Preferred original body');
    end
    else
    begin
      WriteIndex(Sources[I].INPXFile,'Preferred original','Old other title',False);
      WriteArchive(TPath.Combine(Sources[I].Root,'shared.zip'),'shared','Lower original body');
      WriteArchive(TPath.Combine(Sources[I].Root,'other.zip'),'other','Retained other body');
    end;
    Refresh:=TCatalogRefreshWorker.Create(Sources[I]);
    try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Could not refresh the packed source fixture: '+Refresh.Error);
      Sources[I]:=Refresh.Source;
    finally Refresh.Free; end;
  end;
  SourceID:=SystemDB.CreateCollection('Original bound collection',Folder,TPath.Combine(Folder,'original.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Source:=SystemDB.GetCollection(SourceID); SaveCatalogSources(Source,Sources);
  Merge:=TCatalogMergeWorker.CreatePreview(SourceID,Sources,mpSourcePriority);
  try Merge.Start; Merge.WaitFor; Require(Merge.Success,Merge.Error); Plan:=Merge.TakePlan;
  finally Merge.Free; end;
  try
    Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Folder,'merge-backup'));
    try Merge.Start; Merge.WaitFor; Require(Merge.Success,Merge.Error);
    finally Merge.Free; end;
  finally Plan.Free; end;
  Source:=SystemDB.GetCollection(SourceID,True);
  SharedID:=FindID(Source,'2001'); OtherID:=FindID(Source,'2002');
  Require((SharedID>0) and (OtherID>0) and (SharedID<>OtherID) and
    (Length(Source.GetCatalogBookCopies(CreateBookKey(SharedID,SourceID)))=2),
    'Bound source fixture did not merge both copies into one card');
  Source.SetRate(CreateBookKey(SharedID,SourceID),4);
  Source.SetProgress(CreateBookKey(SharedID,SourceID),42);
  Source.SetReview(CreateBookKey(SharedID,SourceID),'Saved bound review');
  Source.AddBookToGroup(CreateBookKey(SharedID,SourceID),FAVORITES_GROUP_ID);

  Options:=Default(TCollectionPackingOptions);
  Options.SourceID:=SourceID; Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.SourceRoot:=Folder;
  Options.OutputRoot:=PackedRoot; Options.DisplayName:='Packed bound collection';
  Options.Python:=Settings.AppPath+'tools\python\python.exe';
  Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared; PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  Target:=SystemDB.GetCollection(PackedID);
  Target.GetBookRecord(CreateBookKey(SharedID,PackedID),Book,True);
  Require(Content(Book)='Preferred original body','Packed fixture picked the wrong preferred source');
  PreferredPath:=Book.GetBookFileName; PreferredSourceName:=Book.CollectionName;
  var OriginalCopies:=Target.GetCatalogBookCopies(Book.BookKey);
  Require(Length(OriginalCopies)=2,'Packing did not retain both original copies');
  for var OriginalCopy in OriginalCopies do
    if (OriginalCopy.CollectionName=Sources[1].Name) and (Content(OriginalCopy)='Lower original body') then
      OriginalLowerPath:=OriginalCopy.GetBookFileName;
  Require((OriginalLowerPath<>'') and (OriginalLowerPath<>PreferredPath),
    'Packing did not retain the independent lower-priority payload');
  Target.GetBookRecord(CreateBookKey(OtherID,PackedID),Book,True); OriginalOtherPath:=Book.GetBookFileName;
  OriginalFile:=Target.GetProperty(PROP_DATAFILE);
  for var S in Sources do Require(RenameFile(S.Root,S.Root+'-held'),'Could not hide the source archive root');
  Profile:=TLibraryUpdateSource.NewSource;
  Profile.Name:='Packed bound publisher'; Profile.CatalogSourceID:=Sources[1].ID;
  Profile.Location:=Download; Profile.BooksRoot:=Download;
  if MetabibFormat='' then
  begin
    Profile.IndexFile:='revised.inpx';
    WriteIndex(TPath.Combine(Download,Profile.IndexFile),'Lower revised','Corrected other title',True);
  end
  else
  begin
    Require(MatchText(MetabibFormat,['jsonl','jsonl.gz','jsonl.zst','zip']),'Unsupported test Metabib container');
    Profile.IndexFile:='revised.'+MetabibFormat;
    Profile.Full:=False;
    WriteMetabib(TPath.Combine(Download,Profile.IndexFile));
    Target.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
  end;
  OriginalSHA:=THashSHA2.GetHashStringFromFile(OriginalFile);
  if EmptySnapshot then begin RejectEmptyMetabib; Exit; end;
  WriteArchive(TPath.Combine(Download,'arrival.zip'),'arrival','Bound arrival body');
  if MetabibFormat='' then ResultID:=Update(PackedID,1,2,1)
  else ResultID:=ApplyPackedUpdateFromMain(Profile,PackedID,'shared.zip',1,2);
  CheckUpdated(ResultID,False);
  Writeln('PASS missing archive retains the earlier packed source copy'); Flush(Output);
  if MetabibFormat='' then Profile.Full:=False;
  WriteArchive(TPath.Combine(Download,'shared.zip'),'shared','Replaced lower body');
  ResultID:=Update(ResultID,0,1,0); CheckUpdated(ResultID,True);
  ResultID:=Update(ResultID,0,0,0); CheckUpdated(ResultID,True);
  Writeln('PASS packed bound update replaces only the selected source and retains preferred and metadata-only payloads');
  if MetabibFormat<>'' then Writeln('PASS Metabib updates a bound packed source through the ordinary window and repeats cleanly: ',MetabibFormat);
  Flush(Output);
end;
