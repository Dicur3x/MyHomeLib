// The public updater receives real module ZIPs over the existing loopback
// fixture and launches a new catalogue process with the one-time argument.
type
  TPackingStartupReviewProbe = class(TPackingReviewProbe)
    Main: TfrmMain;
    procedure Tick(Sender: TObject); reintroduce;
  end;

procedure TPackingStartupReviewProbe.Tick(Sender: TObject);
var StartButton: TButton;
begin
  if Main=nil then Exit;
  Dialog:=Main.FindComponent('CollectionPackingProgress') as TfrmCollectionPackingProgress;
  if Dialog=nil then Exit;
  StartButton:=Dialog.FindComponent('btnContinuePacking') as TButton;
  if StartButton.Visible and not SawEstimate then
    Require(Pos(PackingImageProfileCaption(pipMaximum,True),
      (Dialog.FindComponent('lblPackingStage') as TLabel).Caption)>0,
      'Normal startup changed the restored maximum grayscale profile');
  inherited Tick(Sender);
end;

procedure RunPackingModuleRestartChild;
var Root: TJSONObject; Entry: TJSONValue; Releases: TComponentReleases; Info: TProgramRelease;
  Head: TUpdateProposalServer; Server: TRepairServer; Updater: TSaveModuleUpdateForm;
  ExceptionHandler: TSaveModuleExceptionHandler; Prompt: TForm; Primary: TButton;
  Request: TCollectionPackingRequest; Options: TCollectionPackingOptions;
  Collection: IBookCollection; Book: TBookRecord; SourceID, BookID: Integer;
  Dialog: TfrmCollectionPackingProgress; Probe: TPackingStartupReviewProbe;
  Timer: TTimer; Snapshot: TCollectionPackingSnapshot; Started: UInt64;
  Folder, Report, Version, Source, SourceRoot, Destination: string;
  Required: TArray<string>; PackedCollection: IBookCollection; PackedStream: TStream;

  procedure WaitForPrimary(const Caption: string);
  begin
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Prompt:=Updater.FindComponent('OptionalComponentPrompt') as TForm;
      Primary:=nil;
      if Assigned(Prompt) then Primary:=Prompt.FindComponent('ComponentPromptDownload') as TButton;
      Require(GetTickCount64-Started<45000,'Compact packing module prompt did not reach '+Caption);
    until Assigned(Primary) and Primary.Enabled and (Primary.Caption=Caption);
  end;

begin
  Folder:=ExtractFilePath(ParamStr(0));
  Report:=Folder+'save-module-result.txt';
  SourceRoot:=Folder+'packing-source';
  Source:=TPath.Combine(SourceRoot,'sample.fb2');
  Destination:=Folder+'packing-destination';
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
  try
  try
    Version:=Root.GetValue<string>('version');
    Application.Initialize;
    ExceptionHandler:=TSaveModuleExceptionHandler.Create;
    ExceptionHandler.Report:=Report;
    Application.OnException:=ExceptionHandler.Handle;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    try
      if ParamCount>2 then
      begin
        Require(not ComponentNeedsRepair(Folder,'BookProcessing') and not ComponentNeedsRepair(Folder,'ImageProcessing') and
          (InstalledComponentVersion(Folder,'BookProcessing')=Version) and
          (InstalledComponentVersion(Folder,'ImageProcessing')=Version),'Restart lost either packing dependency');
        for var Unrelated in ['kindle','office','xps','doc','djvu','pdfium','jpeg-xl'] do
          Require(not DirectoryExists(TPath.Combine(Folder,'tools/'+Unrelated)),'Packing installed an unrelated component');
        SourceID:=Settings.ActiveCollection;
        Collection:=SystemDB.GetCollection(SourceID);
        Require(Collection.CollectionDisplayName='Packing restart source',
          'Restart lost the active source collection');
        Options:=Default(TCollectionPackingOptions);
        Options.CatalogFile:=Collection.GetProperty(PROP_DATAFILE);
        Options.SourceRoot:=Collection.CollectionRoot;
        Options.SourceID:=SourceID;
        Options.OutputRoot:=Destination;
        Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
        Options.DisplayName:='Packed after component restart';
        Options.ImageProfile:=pipMaximum;
        Options.ImageGrayscale:=True;
        Require((Length(ResolvePackingTools(Folder,Options))=0) and FileExists(Options.Script) and
          SameFileName(Options.Script,TPath.Combine(Folder,PACKING_WORKER_FILE)),
          'Packing worker was not installed as part of BookProcessing');
        InitLocalization;
        TfrmMain.DeferInitialCollection:=True;
        Application.CreateForm(TdmImages,dmImages);
        dmImages.ApplyThemeIcons;
        frmSplash:=TfrmSplash.Create(Application);
        Probe:=TPackingStartupReviewProbe.Create;
        Timer:=TTimer.Create(nil);
        try
          Probe.Cancel:=True; Probe.CheckFreshOutput:=True;
          Probe.OutputRoot:=Destination; Probe.ExpectedBooks:=1;
          Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
          Application.CreateForm(TfrmMain,frmMain);
          Probe.Main:=frmMain;
          Require(Assigned(frmMain.FindComponent('miPackCollection')),
            'Normal catalogue menu has no packing command');
          frmSplash.Hide;
          frmMain.Show;
          frmMain.Update;
          frmMain.StartInitialCollectionLoad;
          Started:=GetTickCount64;
          while not Probe.SawEstimate or frmMain.StartupLoading or
            Assigned(frmMain.FindComponent('CollectionPackingProgress')) do
          begin
            Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
            Require(GetTickCount64-Started<60000,
              'Normal startup did not restore and cancel the packing review');
          end;
          Require(Probe.SawEstimate,'Restored packing review was not shown');
        finally
          Timer.Free; Probe.Free;
          FreeAndNil(frmMain); FreeAndNil(frmSplash); FreeAndNil(dmImages);
        end;
        Require(not TakePackingContinuation(Settings.SettingsFileName,ParamStr(3),Request) and
          not DirectoryExists(TPath.Combine(Destination,'archives')) and
          (UpdateSHA256(Source)=UpdateSHA256(Folder+'module-source.fb2')),
          'Restart replayed the request, altered a source book or published archives before approval');
        Dialog:=TfrmCollectionPackingProgress.Create(nil);
        try Snapshot:=Dialog.Execute(Options,False);
        finally Dialog.Free; end;
        try
          Require(Snapshot.Status.BooksDone=1,'Installed worker did not pack the book');
          PackedCollection:=SystemDB.GetCollection(Snapshot.RegisterNew(SystemDB));
        finally Snapshot.Free; end;
        Require(PackedCollection.CollectionID<>Collection.CollectionID,'Packing replaced the source catalogue');
        BookID:=PackedCollection.ResolveBookID('Packing restart book',0);
        Require(BookID>0,'Packed copy lost the selected book identity');
        PackedCollection.GetBookRecord(CreateBookKey(BookID,PackedCollection.CollectionID),Book,True);
        PackedStream:=Book.GetBookStream(True,False);
        try
          Require(Assigned(PackedStream) and SameText(THashSHA2.GetHashString(PackedStream),UpdateSHA256(Source)) and
            SameText(UpdateSHA256(Source),UpdateSHA256(Folder+'module-source.fb2')),
            'Packing through the downloaded worker lost the original book bytes');
        finally PackedStream.Free; end;
        PackedCollection:=nil;
        Collection:=nil;
        TFile.WriteAllText(Options.Script,'# corrupted isolated worker',TEncoding.ASCII);
        Required:=ResolvePackingTools(Folder,Options);
        Require((Length(Required)=1) and (Required[0]='BookProcessing') and ComponentNeedsRepair(Folder,'BookProcessing'),
          'A corrupt installed worker must offer same-version BookProcessing repair');
        TFile.WriteAllText(Report,'PASS compact packing download actual installer restart restores selected profile and canceled review through normal catalogue startup'+
          sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
        Exit;
      end;

      Require(ComponentNeedsRepair(Folder,'BookProcessing') and ComponentNeedsRepair(Folder,'ImageProcessing') and
        not FileExists(TPath.Combine(Folder,PACKING_WORKER_FILE)),
        'Packing first-use fixture already has a requested component');
      Options:=Default(TCollectionPackingOptions);
      Required:=ResolvePackingTools(Folder,Options);
      Require((Length(Required)=1) and (Required[0]='BookProcessing'),
        'Original-quality packing should request only BookProcessing when 7-Zip is available');
      Options.ImageProfile:=pipMaximum;
      Options.ImageGrayscale:=True;
      Required:=ResolvePackingTools(Folder,Options);
      Require((Length(Required)=2) and (Required[0]='BookProcessing') and (Required[1]='ImageProcessing'),
        'Grayscale packing requested unrelated components');
      ForceDirectories(SourceRoot); ForceDirectories(Destination);
      TFile.Copy(Folder+'module-source.fb2',Source);
      SourceID:=SystemDB.CreateCollection('Packing restart source',SourceRoot,'packing-restart.hlc2',
        CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
      Collection:=SystemDB.GetCollection(SourceID);
      BookID:=AddBook(Collection,'Packing restart book','Fixture author','ru','','prose_contemporary');
      Collection.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
      Book.FileName:='sample'; Book.FileExt:='.fb2'; Collection.UpdateBook(Book);
      Settings.ActiveCollection:=SourceID;
      Settings.ActivePage:=PAGE_AUTHORS;
      Settings.SaveSettings;
      Request:=Default(TCollectionPackingRequest);
      Request.SourceID:=SourceID; Request.CatalogFile:=Collection.GetProperty(PROP_DATAFILE);
      Request.SourceRoot:=Collection.CollectionRoot; Request.OutputRoot:=Destination;
      Request.ImageProfile:=pipMaximum; Request.ImageGrayscale:=True;
      Request.CaptureIdentity;
      Collection:=nil;
      Head:=TUpdateProposalServer.Create;
      Server:=TRepairServer.Create;
      Updater:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL);
      try
        Updater.Server:=Server; Updater.OnRestart:=Updater.RestartRequested;
        Releases:=Default(TComponentReleases);
        for Entry in Root.GetValue<TJSONArray>('components') do
        begin
          Info:=Default(TProgramRelease);
          Info.ComponentID:=Entry.GetValue<string>('id'); Info.ComponentVersion:=Version; Info.Tag:=ALREADER_FIXED_TAG;
          Info.DownloadURL:=Entry.GetValue<string>('url'); Info.SHA256:=Entry.GetValue<string>('sha256');
          Info.Size:=Entry.GetValue<Int64>('size');
          Server.URLs.Add(Info.DownloadURL);
          Server.Files.Add(Folder+'save-module-fixture/'+Entry.GetValue<string>('name'));
          Require(IndexText(Info.ComponentID,Required)>=0,'Unexpected packing module in the feed');
          for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
            if UPDATE_COMPONENTS[I].ID=Info.ComponentID then Releases[I]:=Info;
        end;
        Updater.RequestComponents(Required,'Для сжатия коллекции нужны два компонента.',True,
          function: string begin Result:=StorePackingContinuation(Settings.SettingsFileName,Request); end);
        Started:=GetTickCount64;
        while not (Updater.FindComponent('UpdateCheckComponents') as TButton).Enabled do
        begin
          Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
          Require(GetTickCount64-Started<45000,'Packing component check did not finish');
        end;
        Updater.ComponentsReceived(Releases,True,'');
        WaitForPrimary('Скачать компоненты');
        Require((Server.Requests=0) and not Updater.Visible,'Packing downloaded without approval or exposed the full updater');
        Primary.Click; WaitForPrimary('Установить и перезапустить');
        Require((Server.Requests=2) and (Server.Failure=''),'Packing downloaded the wrong number of components');
        Primary.Click;
        Require((Updater.Restarts=1) and Updater.PendingInstall and Updater.LaunchInstallation,
          'Packing did not schedule one actual updater restart');
      finally Updater.Free; Server.Free; Head.Free; end;
    finally FreeAndNil(DMUser); Application.OnException:=nil; ExceptionHandler.Free; end;
  except
    on E:Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
  finally Root.Free; end;
end;
