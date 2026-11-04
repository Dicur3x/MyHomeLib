procedure TestPackingReal(MenuFixture: Boolean = False);
var Root, PackedRoot: string; Options: TCollectionPackingOptions;
  Source, Copy1, Copy2, Copy3: IBookCollection;
  LegacyImport: TManualUpdateThread;
  Snapshot: TCollectionPackingSnapshot; Dialog: TfrmCollectionPackingProgress;
  FirstID, BookID: Integer;

  function Stage(Number: Integer): string;
  begin Result:=TPath.Combine(Root,IntToStr(Number)); end;

  procedure VerifyCopy(const Collection: IBookCollection; Number: Integer; ExportOriginals: Boolean);
  var Expected: TJSONObject; Item: TJSONPair; Book: TBookRecord; Stream: TStream;
    Original, Hash, OutputFolder: string; Books: TArray<TBookRecord>;
    Worker: TExportToDeviceThread; Results: TBookExportResults;
  begin
    Expected:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Stage(Number),'expected.json'))) as TJSONObject;
    try
      for Item in Expected do
      begin
        BookID:=Collection.ResolveBookID(Item.JsonString.Value,0);
        Require(BookID>0,'Packed original book was lost: '+Item.JsonString.Value);
        Collection.GetBookRecord(CreateBookKey(BookID,Collection.CollectionID),Book,True);
        Original:=Item.JsonValue.GetValue<string>('ext');
        Hash:=Item.JsonValue.GetValue<string>('sha256');
        Require(Book.FileExt=Original,'Packing changed the declared format: '+Original);
        Stream:=Book.GetBookStream(True,False);
        try
          Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Hash),
            'Packed native book stream changed: '+Original);
        finally Stream.Free; end;
        Books:=Books+[Book];
      end;
      if not ExportOriginals then Exit;
      OutputFolder:=TPath.Combine(Root,'export-'+IntToStr(Number));
      ForceDirectories(OutputFolder);
      Worker:=TExportToDeviceThread.Create;
      try
        Worker.StandaloneBooks:=Books; Worker.DeviceDir:=OutputFolder;
        Worker.FolderTemplate:=''; Worker.FileNameTemplate:='%t';
        Worker.KeepSourceFormat:=True; Worker.ImageQuality:='original';
        Worker.NameCollision:=bncKeepBoth;
        Worker.Start; Worker.WaitFor;
        Require(not Assigned(Worker.FatalException),'Packed original export worker failed');
        Results:=Worker.Results;
        Require(SuccessfulBookExportCount(Results)=Expected.Count,'Some packed originals were not exported');
        for Item in Expected do
        begin
          Original:='book-'+Item.JsonString.Value+Item.JsonValue.GetValue<string>('ext');
          Hash:=Item.JsonValue.GetValue<string>('sha256');
          Require(SameText(THashSHA2.GetHashStringFromFile(TPath.Combine(OutputFolder,Original)),Hash),
            'Packed original export changed bytes: '+Original);
        end;
      finally Worker.Free; end;
    finally Expected.Free; end;
  end;

  function UpdateCopy(const Existing: IBookCollection; Number: Integer): IBookCollection;
  var Before, Filename: string; NewID: Integer;
  begin
    Filename:=Existing.GetProperty(PROP_DATAFILE);
    Before:=THashSHA2.GetHashStringFromFile(Filename);
    Options.SourceID:=Existing.CollectionID;
    Options.CatalogFile:=Filename;
    Options.SourceRoot:=PackedRoot;
    Options.DisplayName:='Real packing update '+IntToStr(Number);
    Dialog:=TfrmCollectionPackingProgress.Create(nil);
    try Snapshot:=Dialog.Execute(Options,False,TPath.Combine(Stage(Number),'index.inpx'),Stage(Number));
    finally Dialog.Free; end;
    try
      Require((Snapshot.Status.Reused>=Number+1) and (Snapshot.Status.Unavailable=0),
        'Incremental packing did not reuse old sources or lost a file');
      NewID:=Snapshot.RegisterNew(SystemDB);
    finally Snapshot.Free; end;
    Require(SameText(THashSHA2.GetHashStringFromFile(Filename),Before),
      'Updating altered the preceding catalogue');
    Result:=SystemDB.GetCollection(NewID);
    Require(SystemDB.GetCollectionInfo(NewID).DataVersion=20261101+Number,
      'The updated catalogue did not record the correct INPX version');
  end;

begin
  Root:=TPath.Combine(Settings.AppPath,'packing-real-input');
  PackedRoot:=TPath.Combine(Settings.AppPath,'packing-real-output');
  FirstID:=SystemDB.CreateCollection('Real mixed originals',Stage(0),'packing-real.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  LegacyImport:=TManualUpdateThread.Create(FirstID,TPath.Combine(Stage(0),'index.inpx'),False,gtFb2);
  try
    LegacyImport.Start; LegacyImport.WaitFor;
    Require(LegacyImport.Success and LegacyImport.CommittedChanges,'Cannot import the real library sample');
  finally LegacyImport.Free; end;
  Source:=SystemDB.GetCollection(FirstID);
  VerifyCopy(Source,0,False);
  Options:=Default(TCollectionPackingOptions);
  Options.SourceID:=FirstID; Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Options.SourceRoot:=Stage(0); Options.OutputRoot:=PackedRoot;
  Options.DisplayName:='Real mixed packed copy';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared;
    Copy1:=SystemDB.GetCollection(Snapshot.RegisterNew(SystemDB));
  finally Snapshot.Free; end;
  if MenuFixture then
  begin
    Settings.ActiveCollection:=Copy1.CollectionID;
    Settings.ActivePage:=PAGE_AUTHORS;
    Settings.RestoreBookViews:=rbvAutomatic;
    Settings.SaveSettings;
    Writeln('PASS production menu fixture starts with the original packed catalogue');
    Exit;
  end;
  Copy2:=UpdateCopy(Copy1,1);
  Copy3:=UpdateCopy(Copy2,2);
  VerifyCopy(Copy1,0,False);
  VerifyCopy(Copy2,1,False);
  VerifyCopy(Copy3,2,True);
  Require(Copy1.ResolveBookID('102',0)=Copy3.ResolveBookID('102',0),
    'A second real update changed the stable EPUB book number');
  Require(Copy1.ResolveBookID('103',0)=Copy3.ResolveBookID('103',0),
    'A second real update changed the stable PDF book number');
  Writeln('PASS real mixed packed books survive two INPX updates and export with exact original bytes');
end;

procedure VerifyPackingMenu;
var Info: TCollectionInfo; Collection: IBookCollection; Book: TBookRecord;
  Expected: TJSONObject; Stream: TStream; BookID: Integer;
begin
  Info:=SystemDB.GetCollectionInfo(Settings.ActiveCollection);
  Writeln('TRACE saved catalogue id=',Info.ID,' version=',Info.DataVersion,' title=',Info.DisplayName);
  Require(Info.DisplayName.StartsWith('Real mixed packed copy (') and
    (Info.DataVersion=20261102),'Production menu did not open the new packed catalogue');
  Collection:=SystemDB.GetCollection(Info.ID);
  BookID:=Collection.ResolveBookID('103',0);
  Require(BookID>0,'Production menu lost the updated PDF');
  Collection.GetBookRecord(CreateBookKey(BookID,Info.ID),Book,True);
  Expected:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Settings.AppPath,'packing-real-input/1/expected.json'))) as TJSONObject;
  try
    Stream:=Book.GetBookStream(True,False);
    try
      Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),
        Expected.GetValue<TJSONObject>('103').GetValue<string>('sha256')),
        'Production menu did not publish the updated PDF bytes');
    finally Stream.Free; end;
  finally Expected.Free; end;
  Require(SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,'Real mixed packed copy') and
    (Collection.ResolveBookID('107',0)>0),'Production menu lost the old catalogue or the new DOCX');
  Writeln('PASS production menu published the expected real INPX update separately');
end;
