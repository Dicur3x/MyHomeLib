type
  TCompressionModuleProbe = class
    Source,OriginalSHA:string;
    OptionsSeen,ResultSeen:Boolean;
    procedure Tick(Sender:TObject);
  end;

procedure TCompressionModuleProbe.Tick(Sender:TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionOptions) and Screen.Forms[I].Visible then
    begin
      Require(not OptionsSeen,'Installed compression opened its settings twice'); OptionsSeen:=True;
      var Dialog:=TfrmBookCompressionOptions(Screen.Forms[I]); var Choice:=Dialog.SelectedOptions;
      Require((Pos('после установки компонентов',Dialog.Caption)>0) and
        (Choice.Profile='maximum') and Choice.Grayscale and not Choice.ReviewResults and
        not Choice.EstimateFirst and not Choice.OnlyNew and Choice.BackupOriginals and
        SameFileName(Choice.WorkRoot,Settings.AppPath+'compression-module-work') and
        SameFileName(Choice.BackupFolder,Settings.AppPath+'compression-module-backup'),
        'Actual module restart lost its selected compression choices');
      Require(UpdateSHA256(Source)=OriginalSHA,'Module installation changed books before compression approval');
      TButton(Dialog.FindComponent('CompressionStart')).Click; Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionProgress) and Screen.Forms[I].Visible then
    begin
      var Dialog:=TfrmBookCompressionProgress(Screen.Forms[I]);
      if TButton(Dialog.FindComponent('CompressionStop')).Caption<>'Закрыть' then Exit;
      var Note:=TLabel(Dialog.FindComponent('CompressionNote')).Caption;
      Require((Pos('Не удалось',Note)=0) and (Pos('Ошибка',Note)=0),'Installed compression failed: '+Note);
      Require(UpdateSHA256(Source)<>OriginalSHA,'Approved installed compression did not reduce its source');
      ResultSeen:=True; TButton(Dialog.FindComponent('CompressionStop')).Click; Exit;
    end;
end;

procedure RunCompressionModuleRestartChild;
var Root,State:TJSONObject; Releases:TComponentReleases; Info:TProgramRelease;
    Head:TUpdateProposalServer; Server:TRepairServer; Updater:TSaveModuleUpdateForm;
    Handler:TSaveModuleExceptionHandler; Prompt:TForm; Primary:TButton; Started:UInt64;
    Identity:TCollectionPackingRequest; Request:TBookCompressionContinuation;
    Options:TBookCompressionOperationOptions; Required:TArray<string>; Collection:IBookCollection;
    SourceID,BookID,Stored:Integer; Book,Card:TBookRecord; Zip:TZipFile; Stream:TStream;
    Folder,Report,Source,OriginalSHA,Name,Argument:string; Probe:TCompressionModuleProbe; Timer:TTimer;

  procedure WaitPrimary(const Caption:string);
  begin
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Prompt:=Updater.FindComponent('OptionalComponentPrompt') as TForm; Primary:=nil;
      if Assigned(Prompt) then Primary:=Prompt.FindComponent('ComponentPromptDownload') as TButton;
      Require(GetTickCount64-Started<45000,'Compression module prompt did not reach '+Caption);
    until Assigned(Primary) and Primary.Enabled and (Primary.Caption=Caption);
  end;

  procedure RequestModules;
  begin
    Updater.RequestComponents(Required,'Продолжить сжатие выбранной книги после установки модулей.',True,
      function:string
      begin Inc(Stored); Result:=StoreCompressionContinuation(Settings.SettingsFileName,Request); end);
    Started:=GetTickCount64;
    while not TButton(Updater.FindComponent('UpdateCheckComponents')).Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<45000,'Compression module metadata check did not finish');
    end;
    Updater.ComponentsReceived(Releases,True,''); WaitPrimary('Скачать компоненты');
  end;

begin
  Folder:=ExtractFilePath(ParamStr(0)); Report:=Folder+'save-module-result.txt';
  Source:=Folder+'compression-module-source\shared.zip';
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
  try
    try
      Application.Initialize; Handler:=TSaveModuleExceptionHandler.Create; Handler.Report:=Report;
      Application.OnException:=Handler.Handle; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
      try
        if ParamCount>2 then
        begin
          for var Entry in Root.GetValue<TJSONArray>('components') do
          begin
            Name:=Entry.GetValue<string>('id');
            Require(not ComponentNeedsRepair(Folder,Name) and
              (InstalledComponentVersion(Folder,Name)=Entry.GetValue<string>('version')),
              'Compression restart lost installed '+Name);
          end;
          for var Unrelated in ['kindle','office','xps','doc','djvu','pdfium','jpeg-xl'] do
            Require(not DirectoryExists(Folder+'tools/'+Unrelated),'Compression installed an unrelated component');
          State:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'compression-module-state.json',TEncoding.UTF8)) as TJSONObject;
          try SourceID:=State.GetValue<Integer>('collection'); OriginalSHA:=State.GetValue<string>('source_sha256');
          finally State.Free; end;
          Require(Settings.ActiveCollection=SourceID,'Compression restart changed its active collection');
          InitLocalization; TfrmMain.DeferInitialCollection:=True;
          Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
          frmSplash:=TfrmSplash.Create(Application); Probe:=TCompressionModuleProbe.Create; Timer:=TTimer.Create(nil);
          try
            Probe.Source:=Source; Probe.OriginalSHA:=OriginalSHA; Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
            Application.CreateForm(TfrmMain,frmMain); frmSplash.Hide; frmMain.Show; frmMain.StartInitialCollectionLoad;
            Started:=GetTickCount64;
            repeat
              Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
              Require(GetTickCount64-Started<90000,'Installed compression did not finish through the normal main window');
            until Probe.ResultSeen;
            Require(Probe.OptionsSeen,'Compression after installation bypassed settings approval');
          finally Timer.Free; Probe.Free; FreeAndNil(frmMain); FreeAndNil(dmImages); FreeAndNil(frmSplash); end;
          Collection:=SystemDB.GetCollection(SourceID,True);
          BookID:=Collection.ResolveBookID('Compression restart book',0);
          Require(BookID>0,'Installed compression lost its selected book');
          Collection.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
          Stream:=Book.GetBookStream(True,False);
          try Require(Assigned(Stream) and (Stream.Size=Book.Size) and
            (Stream.Size< TFile.GetSize(Folder+'module-source.fb2')),'Installed compression did not publish measured book bytes');
          finally Stream.Free; end;
          SystemDB.GetBookRecord(Book.BookKey,Card);
          Require((Card.Progress=37) and (Card.Review='Keep module restart note'),'Installed compression changed personal data');
          Require(Length(TDirectory.GetFiles(Folder+'compression-module-backup','*.zip'))=1,
            'Installed compression lost the selected original backup');
          Require(not TakeCompressionContinuation(Settings.SettingsFileName,ParamStr(3),Request),
            'Installed compression request can be replayed');
          TFile.WriteAllText(Report,'PASS compact compression download cancel retry actual installer HomeLibre restart exact selected settings approved compression backup and retained personal data'+
            sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
          Exit;
        end;

        Require(ComponentNeedsRepair(Folder,'BookProcessing') and ComponentNeedsRepair(Folder,'ImageProcessing'),
          'Compression first-use fixture already has its processing modules');
        ForceDirectories(ExtractFileDir(Source)); ForceDirectories(Folder+'compression-module-backup');
        Zip:=TZipFile.Create;
        try Zip.Open(Source,zmWrite);
          Zip.Add(TFile.ReadAllBytes(Folder+'module-source.fb2'),'sample.fb2',zcStored);
          Zip.Add(TEncoding.UTF8.GetBytes('Unselected neighboring bytes must remain exact.'),'neighbor.bin',zcStored);
        finally Zip.Free; end;
        OriginalSHA:=UpdateSHA256(Source);
        SourceID:=SystemDB.CreateCollection('Compression restart source',ExtractFileDir(Source),
          'compression-module.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
        Collection:=SystemDB.GetCollection(SourceID);
        BookID:=AddBook(Collection,'Compression restart book','Author','en','','prose_contemporary');
        Collection.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
        Book.LibID:='Compression restart book'; Book.Folder:='shared.zip'; Book.FileName:='sample';
        Book.FileExt:='.fb2'; Book.InsideNo:=0; Book.Size:=TFile.GetSize(Folder+'module-source.fb2'); Collection.UpdateBook(Book);
        Collection.SetProgress(Book.BookKey,37); Collection.SetReview(Book.BookKey,'Keep module restart note');
        Collection.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
        Settings.ActiveCollection:=SourceID; Settings.ActivePage:=PAGE_AUTHORS; Settings.SaveSettings;
        Identity:=Default(TCollectionPackingRequest); Identity.SourceID:=SourceID;
        Identity.CatalogFile:=Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
        Identity.SourceRoot:=Collection.CollectionRoot;
        Options:=Default(TBookCompressionOperationOptions); Options.Profile:='maximum'; Options.Grayscale:=True;
        Options.WorkRoot:=Folder+'compression-module-work'; Options.BackupOriginals:=True;
        Options.BackupFolder:=Folder+'compression-module-backup'; Options.QueueName:=TGUID.NewGuid.ToString;
        Required:=ResolveSelectedCompressionTools(Folder,Options);
        Require((Length(Required)=2) and MatchText('BookProcessing',Required) and MatchText('ImageProcessing',Required),
          'Selected compression requested unrelated or missing modules');
        Request:=CaptureCompressionContinuation(Identity,crsSelected,Options,[Book]);
        State:=TJSONObject.Create;
        try State.AddPair('collection',TJSONNumber.Create(SourceID)); State.AddPair('catalog',Identity.CatalogFile);
          State.AddPair('source_sha256',OriginalSHA);
          TFile.WriteAllText(Folder+'compression-module-state.json',State.ToJSON,TEncoding.UTF8);
        finally State.Free; end;
        Collection:=nil; Stored:=0; Head:=TUpdateProposalServer.Create; Server:=TRepairServer.Create;
        Updater:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL); Updater.Server:=Server;
        try
          Updater.OnRestart:=Updater.RestartRequested; Releases:=Default(TComponentReleases);
          for var Entry in Root.GetValue<TJSONArray>('components') do
          begin
            Info:=Default(TProgramRelease); Info.ComponentID:=Entry.GetValue<string>('id');
            Info.ComponentVersion:=Entry.GetValue<string>('version'); Info.Tag:=ALREADER_FIXED_TAG;
            Info.DownloadURL:=Entry.GetValue<string>('url'); Info.SHA256:=Entry.GetValue<string>('sha256');
            Info.Size:=Entry.GetValue<Int64>('size'); Server.URLs.Add(Info.DownloadURL);
            Server.Files.Add(Folder+'save-module-fixture/'+Entry.GetValue<string>('name'));
            for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
              if UPDATE_COMPONENTS[I].ID=Info.ComponentID then Releases[I]:=Info;
          end;
          RequestModules; Require(Server.Requests=0,'Compression downloaded without approval');
          Server.DelayMS:=1500; Primary.Click; Started:=GetTickCount64;
          while Server.Requests=0 do
          begin Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
            Require(GetTickCount64-Started<15000,'Canceled compression download never began'); end;
          TButton(Prompt.FindComponent('ComponentPromptCancel')).Click; WaitPrimary('Повторить загрузку');
          Require((Stored=0) and not Updater.PendingInstall and
            not FileExists(Settings.SettingsFileName+'.pending-compression.jsonl') and
            ComponentNeedsRepair(Folder,'BookProcessing') and ComponentNeedsRepair(Folder,'ImageProcessing') and
            (UpdateSHA256(Source)=OriginalSHA),'Canceling module download changed source, modules or queued compression');
          Server.DelayMS:=0; RequestModules; Primary.Click; WaitPrimary('Установить и перезапустить');
          Require((Server.Requests=3) and (Server.Failure='') and (Stored=0) and
            (UpdateSHA256(Source)=OriginalSHA),'Compression retry prepared an unexpected module or changed source');
          Primary.Click;
          Require((Updater.Restarts=1) and Updater.PendingInstall and Updater.LaunchInstallation and (Stored=1),
            'Compression did not schedule exactly one actual installer and continuation');
        finally Updater.Free; Server.Free; Head.Free; end;
      finally Collection:=nil; FreeAndNil(DMUser); Application.OnException:=nil; Handler.Free; end;
    except on E:Exception do
      begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
    end;
  finally Root.Free; end;
end;
