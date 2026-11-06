// The public updater receives real module ZIPs over the existing loopback
// fixture and launches a new catalogue process with the one-time argument.
procedure RunPackingModuleRestartChild;
var Root: TJSONObject; Entry: TJSONValue; Releases: TComponentReleases; Info: TProgramRelease;
  Head: TUpdateProposalServer; Server: TRepairServer; Updater: TSaveModuleUpdateForm;
  ExceptionHandler: TSaveModuleExceptionHandler; ReviewParent, Prompt: TForm; Primary: TButton;
  Request: TCollectionPackingRequest; Options: TCollectionPackingOptions;
  Collection: IBookCollection; Book: TBookRecord; SourceID, BookID: Integer;
  Dialog: TfrmCollectionPackingProgress; Probe: TPackingReviewProbe;
  Timer: TTimer; Snapshot: TCollectionPackingSnapshot; Started: UInt64;
  Folder, Report, Version, Source, SourceRoot, Destination: string;
  Required: TArray<string>;

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
        Require(TakePackingContinuation(Settings.SettingsFileName,ParamStr(3),Request),
          'The real updater did not pass the pending packing request to the successor');
        Collection:=SystemDB.GetCollection(Request.SourceID);
        Request.CheckIdentity(Collection.GetProperty(PROP_DATAFILE),Collection.CollectionRoot,Collection.CollectionID);
        Require(SameFileName(Request.OutputRoot,Destination) and (Request.Inpx='') and
          (Request.ImageProfile=pipMaximum) and Request.ImageGrayscale,'Restart changed destination or image profile');
        Application.CreateForm(TForm,ReviewParent);
        Options:=Default(TCollectionPackingOptions);
        Options.CatalogFile:=Request.CatalogFile; Options.SourceRoot:=Request.SourceRoot;
        Options.SourceID:=Request.SourceID; Options.OutputRoot:=Request.OutputRoot;
        Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
        Options.DisplayName:='Packed after component restart';
        Options.ImageProfile:=Request.ImageProfile; Options.ImageGrayscale:=Request.ImageGrayscale;
        Options.Python:=FindBookProcessingPython(Folder);
        Options.SevenZip:=TPath.Combine(Folder,'tools/7zip/7za.exe');
        Options.Script:=TPath.Combine(Folder,'tools/collectionpack/pack_collection.py');
        Dialog:=TfrmCollectionPackingProgress.Create(ReviewParent);
        Probe:=TPackingReviewProbe.Create;
        Timer:=TTimer.Create(nil);
        try
          Probe.Dialog:=Dialog; Probe.Cancel:=True; Probe.CheckFreshOutput:=True;
          Probe.OutputRoot:=Destination; Probe.ExpectedBooks:=1;
          Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
          try
            Snapshot:=Dialog.Execute(Options,True);
            Snapshot.Free;
            Require(False,'Packing ran without accepting the restored review');
          except on E:EAbort do ; end;
          Require(Probe.SawEstimate,'Restored packing review was not shown');
        finally Timer.Free; Probe.Free; Dialog.Free; ReviewParent.Free; end;
        Require(not TakePackingContinuation(Settings.SettingsFileName,ParamStr(3),Request) and
          not DirectoryExists(TPath.Combine(Destination,'archives')) and
          (UpdateSHA256(Source)=UpdateSHA256(Folder+'module-source.fb2')),
          'Restart replayed the request, altered a source book or published archives before approval');
        Collection:=nil;
        TFile.WriteAllText(Report,'PASS compact packing download actual installer restart restores selected profile and canceled review'+
          sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
        Exit;
      end;

      Require(ComponentNeedsRepair(Folder,'BookProcessing') and ComponentNeedsRepair(Folder,'ImageProcessing'),
        'Packing first-use fixture already has a requested component');
      ForceDirectories(SourceRoot); ForceDirectories(Destination);
      TFile.Copy(Folder+'module-source.fb2',Source);
      SourceID:=SystemDB.CreateCollection('Packing restart source',SourceRoot,'packing-restart.hlc2',
        CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
      Collection:=SystemDB.GetCollection(SourceID);
      BookID:=AddBook(Collection,'Packing restart book','Fixture author','ru','','prose_contemporary');
      Collection.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
      Book.FileName:='sample'; Book.FileExt:='.fb2'; Collection.UpdateBook(Book);
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
          Required:=Required+[Info.ComponentID];
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
