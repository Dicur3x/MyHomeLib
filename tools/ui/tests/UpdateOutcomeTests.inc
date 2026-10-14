// Additional uses: unit_CollectionWorkerThread, unit_libupdateThread,
// unit_ImportFB2Thread, unit_ImportFBDThread, unit_ImportMetabibThread,
// unit_SystemDatabase_SQLite. All data lives in a new private G: profile.

type
  TOOCollectionAccess = class(TCollectionWorker)
    procedure OpenFixture(const Profile: string);
  end;

  TOOManualWorker = class(TManualUpdateThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure CollectionCommitted(const CollectionID: Integer); override;
  public
    FixtureProfile: string;
    FailAfterCommit: Boolean;
  end;

  TOOMetabibWorker = class(TMetabibManualUpdateThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
  public
    FixtureProfile: string;
  end;

  TOOINPXWorker = class(TImportInpxThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
  public
    FixtureProfile: string;
  end;

  TOOMetabibImportWorker = class(TImportMetabibThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
  public
    FixtureProfile: string;
  end;

  TOOFB2Worker = class(TImportFB2Thread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure ProcessFileListArchive; override;
  public
    FixtureProfile: string;
    CancelArchivePhase: Boolean;
  end;

  TOOFBDWorker = class(TImportFBDThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure ProcessFileList; override;
  public
    FixtureProfile: string;
    CancelImport: Boolean;
  end;

  TOOBatchWorker = class(TLibUpdateThread)
  private
    FFixtureCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure WorkFunction; override;
  public
    FixtureProfile, FirstIndex, SecondIndex: string;
    FirstCID, SecondCID: Integer;
  end;

  TOOEvents = class
    Worker: TCollectionWorker;
    CancelOnProgress: Boolean;
    Messages: TStringList;
    function Message(const Text: string; Flags: Longint): Integer;
    procedure Progress(Percent: Integer);
    procedure Warning(const Text: string; Severity: TTeletypeSeverity);
  end;

procedure TOOCollectionAccess.OpenFixture(const Profile: string);
begin
  FSystemData:=TSystemData_SQLite.Create(Profile);
  if FCollectionID<>MHL_INVALID_ID then
  begin
    FCollection:=FSystemData.GetCollection(FCollectionID);
    FCollectionRoot:=FCollection.GetProperty(PROP_ROOTFOLDER);
  end;
end;

function TOOInitialize(Worker: TCollectionWorker; const Profile: string): Boolean;
var HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  Result:=Succeeded(HR);
  Require(Result or (HR=RPC_E_CHANGED_MODE),'Outcome fixture COM initialization failed');
  try TOOCollectionAccess(Worker).OpenFixture(Profile);
  except if Result then CoUninitialize; raise; end;
end;

procedure TOOManualWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOManualWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOManualWorker.CollectionCommitted(const CollectionID: Integer);
begin
  inherited;
  if FailAfterCommit then raise EInvalidOperation.Create('Injected postcommit continuation/remap failure');
end;
procedure TOOMetabibWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOMetabibWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOINPXWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOINPXWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOMetabibImportWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOMetabibImportWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOFB2Worker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOFB2Worker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOFB2Worker.ProcessFileListArchive;
begin
  if CancelArchivePhase then Cancel else inherited;
end;
procedure TOOFBDWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOFBDWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOFBDWorker.ProcessFileList;
begin
  if CancelImport then Cancel else inherited;
end;
procedure TOOBatchWorker.Initialize;
begin FFixtureCOM:=TOOInitialize(Self,FixtureProfile); end;
procedure TOOBatchWorker.Uninitialize;
begin try inherited; finally if FFixtureCOM then CoUninitialize; end; end;
procedure TOOBatchWorker.WorkFunction;
begin
  // Run the real update/commit/remap implementation and the production batch
  // CID notification. A local scheduler avoids internet/download side effects.
  Require(UpdateCollection(FirstIndex,FirstCID,False,'First private fixture'),
    'First outcome batch update failed');
  Cancel;
  Require(not UpdateCollection(SecondIndex,SecondCID,True,'Second private fixture'),
    'Canceled second outcome batch update committed');
end;

function TOOEvents.Message(const Text: string; Flags: Longint): Integer;
begin Messages.Add(Text); if (Flags and $F)=MB_YESNO then Result:=IDYES else Result:=IDOK; end;
procedure TOOEvents.Progress(Percent: Integer);
begin if CancelOnProgress and (Percent>0) then Worker.Cancel; end;
procedure TOOEvents.Warning(const Text: string; Severity: TTeletypeSeverity);
begin Messages.Add(Text); end;

procedure TOORun(Worker: TCollectionWorker; CancelDuring: Boolean = False);
var Events: TOOEvents;
begin
  Events:=TOOEvents.Create;
  Events.Messages:=TStringList.Create; Events.Worker:=Worker; Events.CancelOnProgress:=CancelDuring;
  try
    Worker.OnShowMessage:=Events.Message; Worker.OnTeletype:=Events.Warning;
    Worker.OnProgress:=Events.Progress;
    Worker.Start; Worker.WaitFor;
    Require(Worker.Finished,'Outcome worker failed to publish completion');
    if Assigned(Worker.FatalException) then
      raise Exception.Create('Outcome worker fatal: '+Exception(Worker.FatalException).Message);
    Writeln('TRACE outcome ',Worker.ClassName,' success=',Ord(Worker.Success),
      ' committed=',Ord(Worker.CommittedChanges),' canceled=',Ord(Worker.Canceled),
      ' messages=',Events.Messages.Count);
  finally
    Worker.OnShowMessage:=nil; Worker.OnTeletype:=nil; Worker.OnProgress:=nil;
    Events.Messages.Free; Events.Free;
  end;
end;

procedure TOOIndex(const FileName, Title, LibraryID: string);
var Zip: TZipFile; Data: TBytes;
begin
  Zip:=TZipFile.Create;
  try
    Zip.Open(FileName,zmWrite);
    Data:=TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG');
    Zip.Add(Data,'structure.info');
    Data:=TEncoding.UTF8.GetBytes('Автор,Тест:'#4'prose_contemporary:'#4+Title+#4#4#4+
      LibraryID+#4'100'#4+LibraryID+#4'0'#4'fb2'#4'2026-10-13'#4'ru');
    Zip.Add(Data,'books.inp');
  finally Zip.Free; end;
end;

function TOOBookCount(const SystemData: ISystemData; CID: Integer): Integer;
var Collection: IBookCollection; Authors, Series: Integer;
begin
  Collection:=SystemData.GetCollection(CID,True);
  Collection.GetStatistics(Authors,Result,Series);
end;

procedure TestUpdateOutcomes;
var Folder, Profile, BookRoot, FB2Root, EmptyRoot, Index1, Index2, BadIndex, Dataset, BadDataset, SourceHash: string;
  SystemData: ISystemData; Collection: IBookCollection; IDs: TArray<Integer>;
  CID, CancelCID, BatchCID1, BatchCID2, FB2CID, FBDCID, MetaCID, ImportCID: Integer;
  Manual: TOOManualWorker; Metabib: TOOMetabibWorker; Importer: TOOINPXWorker;
  MetaImporter: TOOMetabibImportWorker; FB2: TOOFB2Worker; FBD: TOOFBDWorker; Batch: TOOBatchWorker;
  SavedSort: Boolean; Seed, Stored: TBookRecord; SeedID: Integer;

  procedure RequireSeed;
  begin
    Collection:=SystemData.GetCollection(CID,True);
    Collection.GetBookRecord(CreateBookKey(SeedID,CID),Stored,True);
    Require((Stored.LibID=Seed.LibID) and (Stored.Title=Seed.Title) and
      (Stored.Rate=4) and (Stored.Progress=37) and
      (Stored.Review='Не терять мою заметку ё') and (Stored.Annotation='Не терять аннотацию'),
      'Outcome notifications changed existing personal book metadata');
    Collection:=nil;
  end;

  function NewCollection(const Name, Root: string): Integer;
  begin
    Result:=SystemData.CreateCollection(Name,Root,Folder+TGUID.NewGuid.ToString+'.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  end;

begin
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:') and SameText(ExtractFileDrive(Settings.DataPath),'G:'),
    'Outcome fixtures require isolated G: app/profile');
  Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'update-outcomes-'+TGUID.NewGuid.ToString));
  BookRoot:=Folder+'books\'; FB2Root:=Folder+'fb2\'; EmptyRoot:=Folder+'empty\';
  ForceDirectories(BookRoot); ForceDirectories(FB2Root); ForceDirectories(EmptyRoot);
  Profile:=Folder+'private-system.sqlite';
  TSystemData_SQLite.CreateSystemTables(Profile); SystemData:=TSystemData_SQLite.Create(Profile);
  SavedSort:=Settings.EnableSort; Settings.EnableSort:=False;
  try
    Index1:=Folder+'source-1.inpx'; Index2:=Folder+'source-2.inpx'; BadIndex:=Folder+'invalid.inpx';
    TOOIndex(Index1,'Первая новая книга','1101'); TOOIndex(Index2,'Вторая новая книга','2202');
    TFile.WriteAllText(BadIndex,'invalid ZIP source, preserve catalogue',TEncoding.UTF8);
    Dataset:=Folder+'empty-metabib.jsonl'; BadDataset:=Folder+'invalid-metabib.jsonl';
    TFile.WriteAllText(Dataset,'{"schema":"metabib.dataset/1","record_schema":"metabib.dataset_record/1","library":"Outcome fixture","records":0}'+sLineBreak,TEncoding.UTF8);
    TFile.WriteAllText(BadDataset,'{"schema":"invalid"}'+sLineBreak,TEncoding.UTF8);
    SourceHash:=THashSHA2.GetHashStringFromFile(Index1);
    CID:=NewCollection('Outcomes manual',BookRoot); Collection:=SystemData.GetCollection(CID);
    Seed:=Default(TBookRecord); Seed.Title:='Исходная книга'; Seed.LibID:='seed-keep'; Seed.Lang:='ru';
    Seed.FileName:='seed'; Seed.FileExt:='.fb2'; Seed.Folder:='seed-dir'; Seed.Size:=100; Seed.Date:=Now;
    TAuthorsHelper.Add(Seed.Authors,'Автор','Исходный',''); TGenresHelper.Add(Seed.Genres,'','','prose_contemporary');
    SeedID:=Collection.InsertBook(Seed,False,False); Require(SeedID>0,'Outcome seed insertion failed');
    Seed.BookKey:=CreateBookKey(SeedID,CID);
    Collection.SetRate(Seed.BookKey,4); Collection.SetProgress(Seed.BookKey,37);
    Collection.SetReview(Seed.BookKey,'Не терять мою заметку ё'); Collection.SetAnnotation(Seed.BookKey,'Не терять аннотацию');
    Collection.AddBookToGroup(Seed.BookKey,FAVORITES_GROUP_ID); Collection:=nil;

    for var Path in TArray<string>.Create(Folder+'missing.inpx',BadIndex) do
    begin
      Manual:=TOOManualWorker.Create(CID,Path,True,gtFb2); Manual.FixtureProfile:=Profile;
      try
        TOORun(Manual);
        Require(not Manual.Success and not Manual.CommittedChanges,'Invalid/missing manual update falsely reported success/change');
        Require(TOOBookCount(SystemData,CID)=1,'Invalid update changed catalogue'); RequireSeed;
      finally Manual.Free; end;
    end;
    CancelCID:=NewCollection('Outcomes cancellation',BookRoot);
    Manual:=TOOManualWorker.Create(CancelCID,Index2,True,gtFb2); Manual.FixtureProfile:=Profile;
    try
      TOORun(Manual,True);
      Require(Manual.Canceled and not Manual.Success and not Manual.CommittedChanges,'Canceled manual update reported a commit');
      Require(TOOBookCount(SystemData,CancelCID)=0,'Canceled manual update retained partial rows');
    finally Manual.Free; end;
    Manual:=TOOManualWorker.Create(CID,Index1,False,gtFb2); Manual.FixtureProfile:=Profile;
    try
      TOORun(Manual);
      Require(Manual.Success and Manual.CommittedChanges,'Successful manual update lost outcome flags');
      Require(TOOBookCount(SystemData,CID)=2,'Successful manual import missing'); RequireSeed;
    finally Manual.Free; end;
    Manual:=TOOManualWorker.Create(CID,Index2,False,gtFb2);
    Manual.FixtureProfile:=Profile; Manual.FailAfterCommit:=True;
    try
      TOORun(Manual);
      Require(not Manual.Success and Manual.CommittedChanges,'Postcommit failure concealed durable catalogue changes');
      Require(TOOBookCount(SystemData,CID)=3,'Postcommit failure reverted or lost committed import'); RequireSeed;
    finally Manual.Free; end;
    BatchCID1:=NewCollection('Outcomes first batch',BookRoot); BatchCID2:=NewCollection('Outcomes second batch',BookRoot);
    Batch:=TOOBatchWorker.Create;
    Batch.FixtureProfile:=Profile; Batch.FirstCID:=BatchCID1; Batch.SecondCID:=BatchCID2;
    Batch.FirstIndex:=Index1; Batch.SecondIndex:=Index2;
    try
      TOORun(Batch); IDs:=Batch.CommittedCollectionIDs;
      Require(Batch.Canceled and not Batch.Success and Batch.CommittedChanges,'Partial batch lost cancellation/commit distinction');
      Require((Length(IDs)=1) and (IDs[0]=BatchCID1),'Batch refresh IDs included rolled-back CID or omitted committed CID');
      IDs[0]:=-123; Require(Batch.CommittedCollectionIDs[0]=BatchCID1,'Committed CID getter exposed mutable internal array');
      Require((TOOBookCount(SystemData,BatchCID1)=1) and (TOOBookCount(SystemData,BatchCID2)=0),'Partial batch persisted wrong collection');
    finally Batch.Free; end;

    MetaCID:=NewCollection('Outcomes metabib',EmptyRoot);
    Metabib:=TOOMetabibWorker.Create(MetaCID,BadDataset,gtFb2); Metabib.FixtureProfile:=Profile;
    try TOORun(Metabib); Require(not Metabib.Success and not Metabib.CommittedChanges,'Bad metabib reported success'); finally Metabib.Free; end;
    Metabib:=TOOMetabibWorker.Create(MetaCID,Dataset,gtFb2); Metabib.FixtureProfile:=Profile; Metabib.Canceled:=True;
    try TOORun(Metabib); Require(not Metabib.Success and not Metabib.CommittedChanges,'Canceled metabib reported success'); finally Metabib.Free; end;
    Metabib:=TOOMetabibWorker.Create(MetaCID,Dataset,gtFb2); Metabib.FixtureProfile:=Profile;
    try TOORun(Metabib); Require(Metabib.Success and Metabib.CommittedChanges,'Valid metabib lost successful commit'); finally Metabib.Free; end;
    ImportCID:=NewCollection('Outcomes INPX wizard worker',BookRoot);
    Importer:=TOOINPXWorker.Create(ImportCID,Index1,gtFb2); Importer.FixtureProfile:=Profile;
    try TOORun(Importer); Require(Importer.Success and Importer.CommittedChanges,'Wizard INPX worker lost outcome'); finally Importer.Free; end;
    MetaImporter:=TOOMetabibImportWorker.Create(MetaCID,Dataset,gtFb2); MetaImporter.FixtureProfile:=Profile;
    try TOORun(MetaImporter); Require(MetaImporter.Success and MetaImporter.CommittedChanges,'Wizard metabib worker lost outcome'); finally MetaImporter.Free; end;

    Require(FileExists(Settings.AppPath+'conversion-fixtures\source.fb2'),'Outcome FB2 source fixture missing');
    TFile.Copy(Settings.AppPath+'conversion-fixtures\source.fb2',FB2Root+'payload.fb2',False);
    FB2CID:=NewCollection('Outcomes FB2 partial import',FB2Root);
    FB2:=TOOFB2Worker.Create(FB2CID,afZip); FB2.FixtureProfile:=Profile; FB2.CancelArchivePhase:=True;
    try
      TOORun(FB2);
      Require(FB2.Canceled and not FB2.Success and FB2.CommittedChanges,'Late archive cancellation hid earlier plain-FB2 commit');
      Require(TOOBookCount(SystemData,FB2CID)=1,'Earlier committed FB2 disappeared after archive cancellation');
    finally FB2.Free; end;
    FBDCID:=NewCollection('Outcomes FBD',EmptyRoot);
    FBD:=TOOFBDWorker.Create(FBDCID); FBD.FixtureProfile:=Profile; FBD.CancelImport:=True;
    try TOORun(FBD); Require(FBD.Canceled and not FBD.Success and not FBD.CommittedChanges,'Canceled FBD reported a commit'); finally FBD.Free; end;
    FBD:=TOOFBDWorker.Create(FBDCID); FBD.FixtureProfile:=Profile;
    try TOORun(FBD); Require(FBD.Success and FBD.CommittedChanges,'Completed FBD lost outcome'); finally FBD.Free; end;
    RequireSeed;
    Require(THashSHA2.GetHashStringFromFile(Index1)=SourceHash,'Outcome notification rewrote input archive');
    Writeln('PASS update outcomes: invalid/cancel rollback, actual commit flags, postcommit failure, copied affected CIDs, private data preservation, FB2 partial phases and INPX/metabib/FBD workers');
  finally
    Collection:=nil; SystemData:=nil; Settings.EnableSort:=SavedSort;
  end;
end;
