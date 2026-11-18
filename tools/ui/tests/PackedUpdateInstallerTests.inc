type
  TPackedUpdateStartupProbe = class
    ProfileID,CatalogDigest:string;
    SourceID,PublishedID,BeforeCount:Integer;
    Applying,Confirmed,Seen:Boolean;
    Deadline:UInt64;
    procedure CheckOriginal;
    procedure Tick(Sender:TObject);
    function Confirm(const Text:string; Flags:Longint):Integer;
  end;

procedure TPackedUpdateStartupProbe.CheckOriginal;
var Original:IBookCollection; Digest:ICatalogContentDigest; Personal:TSQLiteDatabase;
begin
  Original:=SystemDB.GetCollection(SourceID);
  Require(Supports(Original,ICatalogContentDigest,Digest) and
    SameText(Digest.CaptureContentDigest(nil),CatalogDigest),
    'Resume changed the original catalogue');
  Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
  try Require(Personal.QuerySingleInt('SELECT count(*) FROM Bases')=BeforeCount,
    'Resume published a collection before confirmation');
  finally Personal.Free; end;
end;

function TPackedUpdateStartupProbe.Confirm(const Text:string; Flags:Longint):Integer;
begin
  Require(Seen and Applying and not Confirmed and ((Flags and MB_DEFBUTTON2)<>0) and
    (Pos('создать новую копию коллекции?',Text)>0),
    'Restored update did not ask to create a new copy with default No');
  CheckOriginal;
  Confirmed:=True;
  Result:=IDYES;
end;

procedure TPackedUpdateStartupProbe.Tick(Sender:TObject);
begin
  Require(GetTickCount64<Deadline,'Normal startup did not finish the restored library update');
  for var I:=0 to Screen.FormCount-1 do
    if Applying and (Screen.Forms[I] is TImportProgressFormEx) and
      (Screen.Forms[I].Caption='Обновление библиотеки') then
    begin
      var Progress:=TImportProgressFormEx(Screen.Forms[I]);
      if Assigned(Progress.WorkerThread) then Progress.WorkerThread.OnShowMessage:=Confirm;
      Exit;
    end;
  if Applying or Seen then Exit;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmLibraryUpdateSources) and
      (fsModal in Screen.Forms[I].FormState) and Screen.Forms[I].Visible then
    begin
      var Dialog:=TfrmLibraryUpdateSources(Screen.Forms[I]);
      var Review:=Dialog.Review;
      var Apply:=TButton(Dialog.FindComponent('btnApplyUpdateSource'));
      Require(Assigned(Review) and Review.Ready and not Dialog.Committed and Apply.Enabled and
        (Length(Dialog.Sources)=1) and (Dialog.Sources[0].ID=ProfileID) and
        (Review.NewBooks=1) and (Review.ChangedBooks=1) and
        (Review.AmbiguousArchives.Count=1) and (Pos('после установки модулей',
          TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption)>0),
        'Successor did not open the expected checked source and disk choice');
      CheckOriginal;
      Seen:=True;
      Applying:=True;
      try Apply.Click; finally Applying:=False; end;
      Require(Confirmed and Dialog.Committed and (Dialog.PublishedCollectionID>0) and
        (Review.MissingBooks=1),'Approving the restored review did not publish the expected new collection: '+
        TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption);
      PublishedID:=Dialog.PublishedCollectionID;
      Dialog.ModalResult:=mrOk;
      Exit;
    end;
end;

procedure StartPackedUpdateInstaller(const Folder,StateFile:string; Installed:TJSONObject;
  const Plan:ILibraryUpdateRestart; const Required:TArray<string>; const Fixture:TPackedInstallFixture);
var State:TJSONObject; Personal:TSQLiteDatabase; Head:TUpdateProposalServer; Server:TRepairServer;
  Updater:TSaveModuleUpdateForm; Releases:TComponentReleases; Info:TProgramRelease; Started:UInt64;
  function WaitForPrimary(const Caption:string):TButton;
  begin
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      var Prompt:=TForm(Updater.FindComponent('OptionalComponentPrompt'));
      Result:=nil;
      if Assigned(Prompt) then Result:=TButton(Prompt.FindComponent('ComponentPromptDownload'));
      Require(GetTickCount64-Started<45000,'Module prompt did not reach '+Caption);
    until Assigned(Result) and Result.Enabled and (Result.Caption=Caption);
  end;
begin
  State:=TJSONObject.Create;
  try
    State.AddPair('producer',TJSONNumber.Create(GetCurrentProcessId));
    State.AddPair('collection',TJSONNumber.Create(Fixture.CollectionID));
    State.AddPair('profile',Fixture.ProfileID);
    State.AddPair('catalog_digest',Plan.Request.CatalogDigest);
    State.AddPair('old_root',Fixture.OriginalRoot);
    State.AddPair('prior_index',Fixture.PreviousFile);
    State.AddPair('incoming_index',Fixture.IncomingFile);
    Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try State.AddPair('count',TJSONNumber.Create(Personal.QuerySingleInt('SELECT count(*) FROM Bases')));
    finally Personal.Free; end;
    TFile.WriteAllText(StateFile,State.ToJSON,TEncoding.UTF8);
  finally State.Free; end;
  Info:=Default(TProgramRelease);
  Info.ComponentID:='BookProcessing';
  Info.ComponentVersion:=Installed.GetValue<string>('version');
  Info.Tag:=ALREADER_FIXED_TAG;
  Info.DownloadURL:=Installed.GetValue<string>('url');
  Info.SHA256:=Installed.GetValue<string>('sha256');
  Info.Size:=Installed.GetValue<Int64>('size');
  Head:=TUpdateProposalServer.Create;
  Server:=TRepairServer.Create;
  Updater:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL);
  try
    Server.URLs.Add(Info.DownloadURL);
    Server.Files.Add(Folder+'save-module-fixture\'+Installed.GetValue<string>('name'));
    Updater.Server:=Server;
    Updater.OnRestart:=Updater.RestartRequested;
    Updater.RequestComponents(Required,'Продолжить проверенное обновление библиотеки после установки.',True,
      function:string begin Result:=Plan.Arm; end,
      procedure begin Plan.Disarm; end);
    Started:=GetTickCount64;
    while not TButton(Updater.FindComponent('UpdateCheckComponents')).Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<45000,'Module metadata check did not finish');
    end;
    Releases:=Default(TComponentReleases);
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID=Info.ComponentID then Releases[I]:=Info;
    Updater.ComponentsReceived(Releases,True,'');
    var Button:=WaitForPrimary('Скачать компонент');
    Require(Server.Requests=0,'The compact prompt downloaded before the test approved it');
    Button.Click;
    Button:=WaitForPrimary('Установить и перезапустить');
    Require((Server.Requests=1) and (Server.Failure='') and ComponentNeedsRepair(Folder,Info.ComponentID),
      'Prepared download did not leave the old module untouched');
    Button.Click;
    Require((Updater.Restarts=1) and Updater.PendingInstall and
      Updater.WillInstallComponent(Info.ComponentID) and Updater.LaunchInstallation,
      'The external component installer did not start');
  finally Updater.Free; Server.Free; Head.Free; end;
end;

procedure RunPackedUpdateInstallerChild;
var Folder,Report,StateFile,Argument:string; Handler:TSaveModuleExceptionHandler; Installed:TJSONObject;

  procedure CheckSuccessor;
  var State:TJSONObject; Probe:TPackedUpdateStartupProbe; Timer:TTimer; Original,Published:IBookCollection;
    Card:TBookRecord; ID:Integer; Body:TStream; Bytes:TBytes;
    procedure CheckBody(const LibID,Expected:string);
    begin
      ID:=Published.ResolveBookID(LibID,0);
      Require(ID>0,'Published catalogue lost book '+LibID);
      Published.GetBookRecord(CreateBookKey(ID,Published.CollectionID),Card,True);
      Body:=Card.GetBookStream(True,False);
      Require(Assigned(Body),'Could not read book '+LibID+' after startup');
      try
        SetLength(Bytes,Body.Size);
        Body.ReadBuffer(Bytes,Length(Bytes));
        Require(TEncoding.UTF8.GetString(Bytes)=Expected,'Restart chose the wrong copy for '+LibID);
      finally Body.Free; end;
    end;
  begin
    Require(not ComponentNeedsRepair(Folder,'BookProcessing') and
      (InstalledComponentVersion(Folder,'BookProcessing')=Installed.GetValue<string>('version')),
      'Successor did not have the verified repaired module');
    State:=TJSONObject.ParseJSONValue(TFile.ReadAllText(StateFile,TEncoding.UTF8)) as TJSONObject;
    Probe:=TPackedUpdateStartupProbe.Create;
    Timer:=TTimer.Create(nil);
    try
      Require(State.GetValue<Cardinal>('producer')<>GetCurrentProcessId,'The installer did not create a successor process');
      Require(not DirectoryExists(State.GetValue<string>('old_root')) and
        not FileExists(State.GetValue<string>('prior_index')) and
        not FileExists(State.GetValue<string>('incoming_index')),'Restart fixture left a source index or old archive reachable');
      Probe.SourceID:=State.GetValue<Integer>('collection');
      Probe.ProfileID:=State.GetValue<string>('profile');
      Probe.CatalogDigest:=State.GetValue<string>('catalog_digest');
      Probe.BeforeCount:=State.GetValue<Integer>('count');
      Probe.CheckOriginal;
      Require(Settings.ActiveCollection=Probe.SourceID,'Restart lost the original active collection');
      TfrmMain.DeferInitialCollection:=True;
      Application.CreateForm(TfrmMain,frmMain);
      Probe.Deadline:=GetTickCount64+90000;
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
      frmSplash.Hide; frmMain.Show; frmMain.StartInitialCollectionLoad;
      repeat
        Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
        Require(GetTickCount64<Probe.Deadline,'Successor did not open the resumed review');
      until Probe.PublishedID>0;
      Timer.Enabled:=False;
      Require(Probe.Confirmed and (Settings.ActiveCollection=Probe.PublishedID) and
        (Probe.SourceID<>Probe.PublishedID),'Main did not open the separately updated catalogue');
      Published:=SystemDB.GetCollection(Probe.PublishedID);
      Original:=SystemDB.GetCollection(Probe.SourceID);
      Require((Published.ResolveBookID('1002',0)=0) and
        (Published.ResolveBookID('1001',0)=Original.ResolveBookID('1001',0)),
        'Successor lost the exclusion or stable book identity');
      CheckBody('1003','New reviewed body');
      CheckBody('1004','Untouched legacy body');
      CheckBody('1001','Original body 1001');
      Require((Card.Rate=4) and (Card.Progress=37) and
        (Published.GetReview(Card.BookKey)='Личная заметка ё'),'Successor lost saved personal data');
      Require(not Assigned(TakeLibraryUpdateRestart(Settings.LibraryUpdateWorkPath,Argument)) and
        (Length(TDirectory.GetDirectories(Settings.LibraryUpdateWorkPath,'HomeLibre-library-resume-*'))=0),
        'Successor left replayable data or an owned restart directory');
      TFile.WriteAllText(Report,'PASS real packed update installer starts a successor that restores the checked review and publishes only after approval'+
        sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
    finally Timer.Free; Probe.Free; State.Free; end;
  end;

begin
  Folder:=ExtractFilePath(ParamStr(0));
  Report:=Folder+'save-module-result.txt'; StateFile:=Folder+'packed-update-module-state.json';
  Argument:='';
  for var I:=ParamCount downto 3 do
    if ParamStr(I).StartsWith(LIBRARY_UPDATE_RESUME_SWITCH) then begin Argument:=ParamStr(I); Break; end;
  try
    Installed:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'save-module-fixture\fixture.json',TEncoding.UTF8)) as TJSONObject;
    try
      Application.Initialize;
      Handler:=TSaveModuleExceptionHandler.Create;
      Handler.Report:=Report; Application.OnException:=Handler.Handle;
      try
        InitLocalization;
        Application.CreateForm(TDMUser,DMUser); DMUser.Init;
        Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
        frmSplash:=TfrmSplash.Create(Application);
        if Argument<>'' then CheckSuccessor
        else
        begin
          Require(ParamCount=2,'Installer restarted without its reviewed update token');
          Application.CreateForm(TfrmMain,frmMain);
          frmSplash.Hide;
          TestPackedSourceReview(True,True,False,
            procedure(const Plan:ILibraryUpdateRestart; const Required:TArray<string>; const Fixture:TPackedInstallFixture)
            begin StartPackedUpdateInstaller(Folder,StateFile,Installed,Plan,Required,Fixture); end);
        end;
      finally
        FreeAndNil(frmMain); FreeAndNil(frmSplash); FreeAndNil(dmImages); FreeAndNil(DMUser);
        Application.OnException:=nil; Handler.Free;
      end;
    finally Installed.Free; end;
  except on E:Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
end;
