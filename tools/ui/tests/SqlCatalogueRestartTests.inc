type
  TSqlCatalogueResumeProbe = class
    Window: HWND;
    Dialogs: Integer;
    procedure Tick(Sender: TObject);
  end;

function FindSqlCatalogueDialog(Window: HWND; Param: LPARAM): BOOL; stdcall;
var Caption: array[0..127] of Char;
begin
  Result:=True;
  GetWindowText(Window,Caption,Length(Caption));
  if string(Caption)='Импорт SQL-дампов' then
  begin PHandle(Param)^:=Window; Result:=False; end;
end;

procedure TSqlCatalogueResumeProbe.Tick(Sender: TObject);
var Found: HWND;
begin
  Found:=0;
  EnumThreadWindows(GetCurrentThreadId,@FindSqlCatalogueDialog,LPARAM(@Found));
  if (Found=0) or (Found=Window) then Exit;
  Window:=Found;
  Inc(Dialogs);
  PostMessage(Found,WM_CLOSE,0,0);
end;

procedure RunSqlCatalogueModuleRestartChild;
var
  Folder, Report, Version: string;
  Root: TJSONObject; Entry: TJSONValue;
  Head: TUpdateProposalServer; Server: TRepairServer; Updater: TSaveModuleUpdateForm;
  Info: TProgramRelease; Releases: TComponentReleases;
  Small: TForm; Primary: TButton;
  Started: UInt64; CID: Integer;
  Collection: IBookCollection;
  Probe: TSqlCatalogueResumeProbe; Timer: TTimer;
  ExceptionHandler: TSaveModuleExceptionHandler;

  procedure WaitFor(const Condition: TFunc<Boolean>; const Failure: string);
  begin
    Started:=GetTickCount64;
    while not Condition() do
    begin
      Application.ProcessMessages;
      CheckSynchronize(2);
      Sleep(5);
      Require(GetTickCount64-Started<60000,Failure);
    end;
  end;

  procedure WaitForPrimary(const Caption: string);
  begin
    WaitFor(function: Boolean
      begin
        Small:=Updater.FindComponent('OptionalComponentPrompt') as TForm;
        if not Assigned(Small) then Exit(False);
        Primary:=Small.FindComponent('ComponentPromptDownload') as TButton;
        Result:=Assigned(Primary) and Primary.Enabled and (Primary.Caption=Caption);
      end,'SQL component prompt did not reach '+Caption);
  end;

begin
  Folder:=ExtractFilePath(ParamStr(0));
  Report:=Folder+'save-module-result.txt';
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
  try
    try
      Version:=Root.GetValue<string>('version');
      Application.Initialize;
      ExceptionHandler:=TSaveModuleExceptionHandler.Create;
      ExceptionHandler.Report:=Report;
      Application.OnException:=ExceptionHandler.Handle;
      InitLocalization;
      Application.CreateForm(TDMUser,DMUser);
      DMUser.Init;
      try
        if ParamCount>2 then
        begin
          Require((ParamStr(3)=SQL_CATALOGUE_RESUME_SWITCH) and
            not ComponentNeedsRepair(Folder,'BookProcessing') and
            (InstalledComponentVersion(Folder,'BookProcessing')=Version),
            'The real installer lost the SQL operation argument or installed module');
          for var Unrelated in ['kindle','office','xps','doc','djvu','pdfium','images','7zip'] do
            Require(not DirectoryExists(TPath.Combine(Folder,'tools/'+Unrelated)),
              'SQL import installed an unrelated module');
          Require(FileExists(TPath.Combine(Folder,SQL_CATALOGUE_WORKER)) and
            FileExists(TPath.Combine(Folder,SQL_DUMP_PARSER)),'SQL import scripts were not installed');
          TfrmMain.DeferInitialCollection:=True;
          Application.CreateForm(TdmImages,dmImages);
          dmImages.ApplyThemeIcons;
          frmSplash:=TfrmSplash.Create(Application);
          Probe:=TSqlCatalogueResumeProbe.Create;
          Timer:=TTimer.Create(nil);
          try
            Timer.Interval:=20;
            Timer.OnTimer:=Probe.Tick;
            Application.CreateForm(TfrmMain,frmMain);
            frmSplash.Hide;
            frmMain.Show;
            frmMain.Update;
            frmMain.StartInitialCollectionLoad;
            WaitFor(function: Boolean
              begin Result:=(Probe.Dialogs>0) and not IsWindow(Probe.Window) and
                not frmMain.StartupLoading; end,'SQL source choice did not return after actual module installation');
            frmMain.Perform(WM_RESUME_SQL_CATALOGUE,0,0);
            Application.ProcessMessages;
            Require(Probe.Dialogs=1,'SQL source choice replayed after the first restart');
          finally
            Timer.Free;
            Probe.Free;
            FreeAndNil(frmMain);
            FreeAndNil(frmSplash);
            FreeAndNil(dmImages);
          end;
          TFile.WriteAllText(Report,
            'PASS compact SQL module download actual installer restart returns to source choice once'+sLineBreak+
            IntToStr(GetCurrentProcessId),TEncoding.UTF8);
          Exit;
        end;

        Require(ComponentNeedsRepair(Folder,'BookProcessing') and
          not FileExists(TPath.Combine(Folder,SQL_CATALOGUE_WORKER)),
          'SQL first-use fixture already has the processing module');
        CID:=SystemDB.CreateCollection('Before SQL component',Folder,'before-sql.hlc2',
          CT_PRIVATE_FB,Settings.SystemFileName[sfGenresFB2]);
        Collection:=SystemDB.GetCollection(CID);
        AddBook(Collection,'Existing book','Fixture author','ru','','prose_contemporary');
        Collection:=nil;
        Settings.ActiveCollection:=CID;
        Settings.ActivePage:=PAGE_AUTHORS;
        Settings.SaveSettings;
        Head:=TUpdateProposalServer.Create;
        Server:=TRepairServer.Create;
        Updater:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL);
        try
          Updater.Server:=Server;
          Updater.OnRestart:=Updater.RestartRequested;
          Releases:=Default(TComponentReleases);
          Require(Root.GetValue<TJSONArray>('components').Count=1,'SQL import must request one module');
          Entry:=Root.GetValue<TJSONArray>('components')[0];
          Info:=Default(TProgramRelease);
          Info.ComponentID:=Entry.GetValue<string>('id');
          Require(Info.ComponentID='BookProcessing','SQL import requested a different module');
          Info.ComponentVersion:=Version;
          Info.Tag:=ALREADER_FIXED_TAG;
          Info.DownloadURL:=Entry.GetValue<string>('url');
          Info.SHA256:=Entry.GetValue<string>('sha256');
          Info.Size:=Entry.GetValue<Int64>('size');
          Server.URLs.Add(Info.DownloadURL);
          Server.Files.Add(Folder+'save-module-fixture/'+Entry.GetValue<string>('name'));
          for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
            if UPDATE_COMPONENTS[I].ID=Info.ComponentID then Releases[I]:=Info;
          Updater.RequestComponents(TArray<string>.Create('BookProcessing'),
            'Для создания онлайн-каталога из SQL-дампов нужен модуль подготовки книг.',True,
            function: string begin Result:=SQL_CATALOGUE_RESUME_SWITCH; end);
          WaitFor(function: Boolean
            begin Result:=(Updater.FindComponent('UpdateCheckComponents') as TButton).Enabled; end,
            'SQL component check did not finish');
          Updater.ComponentsReceived(Releases,True,'');
          WaitForPrimary('Скачать компонент');
          Require((Server.Requests=0) and Small.Visible and not Updater.Visible,
            'SQL first use downloaded without approval or opened the full updater');
          Primary.Click;
          WaitForPrimary('Установить и перезапустить');
          Require((Server.Requests=1) and (Server.Failure=''),
            'SQL first use downloaded an unrelated package');
          Primary.Click;
          Require((Updater.Restarts=1) and Updater.PendingInstall and Updater.LaunchInstallation,
            'SQL component installation did not schedule the real restart');
        finally Updater.Free; Server.Free; Head.Free; end;
      finally FreeAndNil(DMUser); Application.OnException:=nil; ExceptionHandler.Free; end;
    except
      on E:Exception do
      begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
    end;
  finally Root.Free; end;
end;
