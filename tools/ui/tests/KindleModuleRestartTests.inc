// Real two-package first use, external updater and a fresh reader successor.
type
  TKindleRestoredReviewProbe = class
    Timer: TTimer;
    Initial: TBookSendOptions;
    Dialogs: Integer;
    Failure: string;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

procedure TKindleRestoredReviewProbe.Tick(Sender: TObject);
var Dialog: TForm;
begin
  Require(GetTickCount64<Deadline,'Restored Kindle review did not appear');
  for var I:=Screen.FormCount-1 downto 0 do
  begin
    Dialog:=Screen.Forms[I];
    if not (Dialog is TBookSendOptionsForm) or not Dialog.Visible then Continue;
    Timer.Enabled:=False; Inc(Dialogs);
    try
      Require(string(TComboBox(Dialog.FindComponent('SendFormat')).Text).Contains('MOBI'),
        'Actual restart lost the MOBI format');
      Require(TComboBox(Dialog.FindComponent('SendImages')).ItemIndex=0,
        'Actual restart lost original image quality');
      Require(TEdit(Dialog.FindComponent('SendDestination')).Text=Initial.Folder,
        'Actual restart lost the destination');
      Require(TEdit(Dialog.FindComponent('SaveNameTemplate')).Text=Initial.FileNameTemplate,
        'Actual restart lost the filename mask');
      Require(TCheckBox(Dialog.FindComponent('SaveSubfolders')).Checked and
        (TEdit(Dialog.FindComponent('SaveFolderTemplate')).Text=Initial.FolderTemplate),
        'Actual restart lost the folder mask');
      Require(not Assigned(Dialog.FindComponent('SendZIP')),
        'Actual restart restored the obsolete ZIP checkbox');
    except on E:Exception do Failure:=E.Message; end;
    Dialog.ModalResult:=mrCancel; Exit;
  end;
end;

procedure RunKindleSaveModuleRestartChild;
var Head: TUpdateProposalServer; Server: TRepairServer; Dialog: TSaveModuleUpdateForm;
  Root: TJSONObject; Releases: TComponentReleases; Entries: TJSONArray;
  Info: TProgramRelease; Small, ReviewParent: TForm; Primary: TButton;
  Started: UInt64; Plan: TBookSaveContinuation; Options: TBookSendOptions;
  Probe: TKindleRestoredReviewProbe; Report, Source, SourceHash, Version, Folder: string;
  ExceptionHandler: TSaveModuleExceptionHandler;
  procedure WaitFor(const Condition: TFunc<Boolean>; const Failure: string);
  begin
    Started:=GetTickCount64;
    while not Condition() do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<120000,Failure);
    end;
  end;
begin
  Folder:=ExtractFilePath(ParamStr(0)); Report:=Folder+'save-module-result.txt';
  Source:=Folder+'module-source.fb2'; SourceHash:=UpdateSHA256(Source);
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(
    Folder+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
  try Version:=Root.GetValue<string>('version'); finally Root.Free; end;
  try
    Application.Initialize;
    ExceptionHandler:=TSaveModuleExceptionHandler.Create; ExceptionHandler.Report:=Report;
    Application.OnException:=ExceptionHandler.Handle;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    try
      if InstalledComponentVersion(Settings.AppPath,'BookProcessing')=Version then
      begin
        Require(InstalledComponentVersion(Settings.AppPath,'KindleExport')=Version,
          'Two-package restart lost the Kindle writer');
        Require(FileExists(Settings.AppPath+'tools/bookconvert/KINDLE_OUTPUT_API.txt'),
          'Actual updater lost the Kindle output capability marker');
        for var Unrelated in ['images','pdfium','djvu','kindle','office','xps','doc','7zip'] do
          Require(not DirectoryExists(Settings.AppPath+'tools/'+Unrelated),
            'FB2 to Kindle first use installed an unrelated decoder: '+Unrelated);
        Application.CreateForm(TForm,ReviewParent); ReviewParent.Caption:='Возврат к сохранению MOBI';
        try
          Require(TakeBookSaveContinuation(Settings.SettingsFileName,Plan),
            'Actual Kindle successor did not receive its pending save');
          Require(SameFileName(Plan.SourceFile,Source) and (Plan.Options.Mode=emMobi),
            'Kindle restart changed the source or selected output format');
          Probe:=TKindleRestoredReviewProbe.Create;
          try
            Probe.Initial:=Plan.Options;
            Probe.Deadline:=GetTickCount64+10000;
            Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
            Require(not ChooseBookSendOptions(1,'C:\wrong-fallback',emFB2,Options,False,
              [FileBook(Plan.SourceFile)],@Plan.Options),
              'Restored Kindle review saved without an explicit action');
            Require((Probe.Dialogs=1) and (Probe.Failure=''),
              'Actual restarted Kindle review failed: '+Probe.Failure);
          finally Probe.Timer.Free; Probe.Free; end;
        finally ReviewParent.Free; end;
        ClearBookSaveContinuation(Settings.SettingsFileName,Plan.Token);
        Require(not TakeBookSaveContinuation(Settings.SettingsFileName,Plan),
          'Actual Kindle restart consumed a continuation twice');
        Require(not DirectoryExists(Folder+'module-output'),
          'Restored Kindle review published a book before confirmation');
        Require(UpdateSHA256(Source)=SourceHash,'Kindle restart changed the original book');
        TFile.WriteAllText(Report,
          'PASS compact two-component Kindle download actual installer restart restored MOBI review cancel and unchanged source'+
          sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
        Exit;
      end;
      Require(not FileExists(Folder+'kindle-first-use-started.marker'),
        'Actual updater restarted without the required modules; inspect update-error.log');
      TFile.WriteAllText(Folder+'kindle-first-use-started.marker','Owned test: exactly one installation attempt');
      Require((InstalledComponentVersion(Settings.AppPath,'BookProcessing')='') and
        (InstalledComponentVersion(Settings.AppPath,'KindleExport')=''),
        'Two-package first use must start without processing or writer modules');
      Options:=Default(TBookSendOptions); Options.Folder:=Folder+'module-output';
      Options.Mode:=emMobi; Options.ExplicitFormat:=True; Options.ImageQuality:='original';
      Options.FileNameTemplate:='[%n - ]%t'; Options.FolderTemplate:='%f\[%s]';
      Options.RequiredComponents:=TArray<string>.Create('BookProcessing','KindleExport');
      StoreBookSaveContinuation(Settings.SettingsFileName,'BookProcessing',Options,nil,Source);
      Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(
        Folder+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
      Head:=TUpdateProposalServer.Create; Server:=TRepairServer.Create;
      Dialog:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL); Dialog.Server:=Server;
      try
        Releases:=Default(TComponentReleases);
        Entries:=Root.GetValue<TJSONArray>('components'); Require(Entries.Count=2,'Expected exactly two packages');
        for var Entry in Entries do
        begin
          Info:=Default(TProgramRelease); Info.ComponentID:=Entry.GetValue<string>('id');
          Info.ComponentVersion:=Version; Info.Tag:=ALREADER_FIXED_TAG;
          Info.DownloadURL:=Entry.GetValue<string>('url'); Info.SHA256:=Entry.GetValue<string>('sha256');
          Info.Size:=Entry.GetValue<Int64>('size');
          Server.URLs.Add(Info.DownloadURL);
          Server.Files.Add(Folder+'save-module-fixture/'+Entry.GetValue<string>('name'));
          for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
            if UPDATE_COMPONENTS[I].ID=Info.ComponentID then Releases[I]:=Info;
        end;
        Dialog.OnRestart:=Dialog.RestartRequested;
        Dialog.RequestComponents(Options.RequiredComponents,
          'Чтобы сохранить книгу в MOBI, нужны модули обработки книг и создания файлов для Kindle.',True);
        WaitFor(function: Boolean begin Result:=(Dialog.FindComponent('UpdateCheckComponents') as TButton).Enabled; end,
          'Compact two-package component check did not complete');
        Dialog.ComponentsReceived(Releases,True,''); Application.ProcessMessages;
        Small:=Dialog.FindComponent('OptionalComponentPrompt') as TForm;
        Require(Assigned(Small) and Small.Visible and not Dialog.Visible,
          'Two-package first use exposed the full updater');
        Primary:=Small.FindComponent('ComponentPromptDownload') as TButton;
        Require(Primary.Enabled and (Server.Requests=0),'First use downloaded before an explicit action');
        Primary.Click;
        WaitFor(function: Boolean begin Result:=Primary.Enabled; end,'Two-package download did not complete');
        Require(Primary.Caption='Установить и перезапустить',
          'Two-package download failed: '+TMemo(Small.FindComponent('ComponentPromptReason')).Text);
        Require((Server.Requests=2) and (Server.Failure=''),
          'First use did not download exactly its two requested packages');
        Require((InstalledComponentVersion(Settings.AppPath,'BookProcessing')='') and
          (InstalledComponentVersion(Settings.AppPath,'KindleExport')=''),
          'Download changed installed modules before install approval');
        Primary.Click;
        Require((Dialog.Restarts=1) and Dialog.PendingInstall and
          Dialog.WillInstallComponent('BookProcessing') and Dialog.WillInstallComponent('KindleExport'),
          'Combined installation lost one of its two components');
        Require(Dialog.LaunchInstallation,'Actual combined installer did not launch');
        Require(FileExists(BookSaveContinuationFile(Settings.SettingsFileName)+'.ready'),
          'Combined installation did not arm the matching continuation');
      finally Dialog.Free; Server.Free; Head.Free; Root.Free; end;
    finally FreeAndNil(DMUser); Application.OnException:=nil; ExceptionHandler.Free; end;
  except
    on E:Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
end;
