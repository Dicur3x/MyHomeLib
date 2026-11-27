// Real compact download, prepared files, external installer and a successor
// process. Only the network transport is redirected to owned loopback data.
procedure RunKindleSaveModuleRestartChild; forward;
procedure RunPackingModuleRestartChild; forward;
procedure RunSqlCatalogueModuleRestartChild; forward;
procedure RunCompressionModuleRestartChild; forward;
procedure RunPackedUpdateInstallerChild; forward;
procedure RunPdfZipSaveRestartChild; forward;
type
  TSaveModuleExceptionHandler = class
    Report: string;
    procedure Handle(Sender: TObject; E: Exception);
  end;
  TSaveModuleUpdateForm = class(TOptionalUpdateForm)
  public
    Server: TRepairServer;
    Restarts: Integer;
    procedure RestartRequested(Sender: TObject);
    function LaunchLegacyInstallation: Boolean;
  protected
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease;
      const Job: string): TProgramDownloadThread; override;
  end;

procedure TSaveModuleExceptionHandler.Handle(Sender: TObject; E: Exception);
begin
  TFile.WriteAllText(Report,'FAIL VCL '+E.ClassName+': '+E.Message,TEncoding.UTF8);
  Winapi.Windows.ExitProcess(1);
end;

procedure TSaveModuleUpdateForm.RestartRequested(Sender: TObject);
begin Inc(Restarts); end;

function TSaveModuleUpdateForm.LaunchLegacyInstallation: Boolean;
var Ready, Request: TJSONObject; Args: TJSONArray; Job, Helper, Command: string;
  Startup: TStartupInfo; Process: TProcessInformation;
begin
  // Exact pre5.33 request protocol: notably no application field. Run the
  // actual new helper, as an old catalogue updating to a new release would.
  Ready:=TJSONObject.ParseJSONValue(TFile.ReadAllText(
    TPath.Combine(ProgramUpdateCache(Settings.AppPath),'ready.json'),TEncoding.UTF8)) as TJSONObject;
  try Job:=Ready.GetValue<string>('job'); finally Ready.Free; end;
  Helper:=TPath.Combine(Job,'HomeLibRuUpdater.exe');
  TFile.Copy(InstallationHelperSource,Helper,False);
  Request:=TJSONObject.Create;
  try
    Request.AddPair('target',ExcludeTrailingPathDelimiter(Settings.AppPath));
    Request.AddPair('pid',TJSONNumber.Create(GetCurrentProcessId));
    Request.AddPair('tag',ALREADER_FIXED_TAG);
    Request.AddPair('sha256',UpdateSHA256(TPath.Combine(Job,'release.zip')));
    Request.AddPair('commandLine',string(GetCommandLine));
    Request.AddPair('recover',TJSONBool.Create(False));
    Args:=TJSONArray.Create;
    for var I:=1 to ParamCount do Args.Add(ParamStr(I));
    Request.AddPair('args',Args);
    TFile.WriteAllText(TPath.Combine(Job,'request.json'),Request.ToJSON,TEncoding.UTF8);
  finally Request.Free; end;
  ArmBookSaveContinuation(Settings.SettingsFileName,'BookConverter');
  Command:='"'+Helper+'" --job "'+Job+'"'; UniqueString(Command);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Result:=CreateProcess(PChar(Helper),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Job),Startup,Process);
  if Result then begin CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
end;

function TSaveModuleUpdateForm.CreateDownloadWorker(Window: HWND;
  const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin Result:=TRepairWorker.Create(Window,Info,Job,Server); end;

procedure RunSaveModuleRestartChild;
var Head: TUpdateProposalServer; Server: TRepairServer; Dialog: TSaveModuleUpdateForm;
  Root: TJSONObject; Releases: TComponentReleases; Info: TProgramRelease;
  Small: TForm; Primary: TButton; Started: UInt64;
  Plan: TBookSaveContinuation; Options: TBookSendOptions; Probe: TUnifiedSendProbe;
  Report, Source, SourceHash, Package: string;
  ExceptionHandler: TSaveModuleExceptionHandler; ReviewParent: TForm;
  procedure TraceStep(const Value: string);
  begin TFile.AppendAllText(ExtractFilePath(ParamStr(0))+'save-module-trace.txt',
    IntToStr(GetCurrentProcessId)+' '+Value+sLineBreak,TEncoding.UTF8); end;
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
  if ParamStr(2)='pdf-zip' then begin RunPdfZipSaveRestartChild; Exit; end;
  if ParamStr(2)='kindle' then begin RunKindleSaveModuleRestartChild; Exit; end;
  if ParamStr(2)='packing' then begin RunPackingModuleRestartChild; Exit; end;
  if ParamStr(2)='sql' then begin RunSqlCatalogueModuleRestartChild; Exit; end;
  if ParamStr(2)='compression' then begin RunCompressionModuleRestartChild; Exit; end;
  if ParamStr(2)='packed-update' then begin RunPackedUpdateInstallerChild; Exit; end;
  // This early child entry precedes the shared DMUser/Settings bootstrap.
  Report:=ExtractFilePath(ParamStr(0))+'save-module-result.txt';
  Source:=ExtractFilePath(ParamStr(0))+'module-source.pdf'; SourceHash:=UpdateSHA256(Source);
  TraceStep('child entry');
  try
    Application.Initialize;
    ExceptionHandler:=TSaveModuleExceptionHandler.Create; ExceptionHandler.Report:=Report;
    Application.OnException:=ExceptionHandler.Handle;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    TraceStep('processing='+InstalledComponentVersion(Settings.AppPath,'BookProcessing'));
    try
      if InstalledComponentVersion(Settings.AppPath,'BookProcessing')='2.7.0.1105' then
      begin
        // Production always has a main host/catalogue, even when its launcher
        // is hidden. A bare console child must recreate that VCL prerequisite.
        Application.CreateForm(TForm,ReviewParent); ReviewParent.Caption:='Save restart review';
        Require(FileExists(Settings.AppPath+'tools/bookconvert/SAVE_OPTIONS_API.txt'),
          'Actual installer lost Save As capability marker');
        for var Unrelated in ['images','pdfium','djvu'] do
          Require(not DirectoryExists(Settings.AppPath+'tools/'+Unrelated),
            'Base processing installed an unrelated decoder: '+Unrelated);
        Require(not FileExists(Settings.AppPath+'tools/kindle/COMPONENT.json') and
          not FileExists(Settings.AppPath+'tools/office/COMPONENT.json') and
          not FileExists(Settings.AppPath+'tools/xps/COMPONENT.json'),
          'Base processing installed unrelated format component identities');
        Require(TakeBookSaveContinuation(Settings.SettingsFileName,Plan),
          'Actual restarted process did not receive its pending save');
        TraceStep('continuation taken');
        Require(SameFileName(Plan.SourceFile,Source),'Restart replaced the source book');
        Probe:=TUnifiedSendProbe.Create;
        try
          Probe.Initial:=Plan.Options; Probe.VerifyInitial:=True;
          Probe.Deadline:=GetTickCount64+10000;
          Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
          TraceStep('opening restored review');
          Require(not ChooseBookSendOptions(1,'C:\wrong-fallback',emFB2,Options,False,
            [FileBook(Plan.SourceFile)],@Plan.Options),'Restored review started a save without approval');
          Require((Probe.Dialogs=1) and (Probe.Failure=''),'Actual restarted Save As review did not appear');
        finally Probe.Timer.Free; Probe.Free; end;
        TraceStep('restored review cancelled'); ReviewParent.Free;
        ClearBookSaveContinuation(Settings.SettingsFileName,Plan.Token);
        Require(not TakeBookSaveContinuation(Settings.SettingsFileName,Plan),'Restart plan was consumed twice');
        Require(not DirectoryExists(Settings.AppPath+'module-output'),'Restored review wrote output before confirmation');
        Require(UpdateSHA256(Source)=SourceHash,'Download/install/restart changed source book');
        TFile.WriteAllText(Report,'PASS compact legacy converter to independent processing download actual installer restart restored review cancel and unchanged source'+
          sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
        Exit;
      end;
      Require(InstalledComponentVersion(Settings.AppPath,'BookConverter')='2.7.0.1102',
        'Actual restart regression requires the published old converter');
      Require(not FileExists(Settings.AppPath+'tools/bookconvert/SAVE_OPTIONS_API.txt'),
        'Old converter falsely supports new Save As options');
      Options:=Default(TBookSendOptions); Options.Folder:=Settings.AppPath+'module-output';
      Options.Mode:=emEpub; Options.ExplicitFormat:=True; Options.ZipEachBook:=True;
      Options.FileNameTemplate:='[%n - ]%t'; Options.FolderTemplate:='%f\[%s]';
      Options.ImageQuality:='economy|auto|except=1,9-10';
      StoreBookSaveContinuation(Settings.SettingsFileName,'BookConverter',Options,nil,Source);
      Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'save-module-fixture/fixture.json',TEncoding.UTF8)) as TJSONObject;
      try
        Info:=Default(TProgramRelease); Info.ComponentID:='BookProcessing';
        Info.ComponentVersion:='2.7.0.1105'; Info.Tag:=ALREADER_FIXED_TAG;
        Info.DownloadURL:=Root.GetValue<string>('url');
        Info.SHA256:=Root.GetValue<string>('sha256'); Info.Size:=Root.GetValue<Int64>('size');
        Package:=Settings.AppPath+'save-module-fixture/'+Root.GetValue<string>('name');
      finally Root.Free; end;
      Head:=TUpdateProposalServer.Create; Server:=TRepairServer.Create;
      Dialog:=TSaveModuleUpdateForm.CreateForHead(Head.HeadURL); Dialog.Server:=Server;
      try
        Server.URLs.Add(Info.DownloadURL); Server.Files.Add(Package);
        Dialog.OnRestart:=Dialog.RestartRequested;
        Dialog.RequestComponent('BookConverter','Для сжатия изображений нужен обновлённый модуль конвертации.',True);
        WaitFor(function: Boolean begin Result:=(Dialog.FindComponent('UpdateCheckComponents') as TButton).Enabled; end,
          'Compact module check did not complete');
        Releases:=Default(TComponentReleases);
        for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
          if UPDATE_COMPONENTS[I].ID='BookProcessing' then Releases[I]:=Info;
        Dialog.ComponentsReceived(Releases,True,''); Application.ProcessMessages;
        Small:=Dialog.FindComponent('OptionalComponentPrompt') as TForm;
        Require(Assigned(Small) and Small.Visible and not Dialog.Visible,'Real module operation exposed the full updater');
        Primary:=Small.FindComponent('ComponentPromptDownload') as TButton;
        Require(Primary.Enabled and (Server.Requests=0),'Compact module downloaded without an explicit action');
        Primary.Click;
        WaitFor(function: Boolean begin Result:=Primary.Enabled; end,'Real module download did not complete');
        Require(Primary.Caption='Установить и перезапустить','Real module download failed: '+TMemo(Small.FindComponent('ComponentPromptReason')).Text);
        Require((Server.Requests=1) and (Server.Failure=''),'Real converter used an unexpected download source');
        Require((InstalledComponentVersion(Settings.AppPath,'BookConverter')='2.7.0.1102') and
          not FileExists(Settings.AppPath+'tools/bookconvert/SAVE_OPTIONS_API.txt'),
          'Download preparation modified installed converter before approval');
        Primary.Click;
        Require((Dialog.Restarts=1) and Dialog.PendingInstall and Dialog.WillInstallComponent('BookConverter'),
          'Explicit install did not retain the requested component');
        if ParamStr(2)='legacy-request' then
          Require(Dialog.LaunchLegacyInstallation,'Legacy request installer did not launch')
        else Require(Dialog.LaunchInstallation,'Actual installer did not launch');
        TraceStep('installer launched');
        Require(FileExists(BookSaveContinuationFile(Settings.SettingsFileName)+'.ready'),
          'Actual installer did not arm the matching save continuation');
      finally Dialog.Free; Server.Free; Head.Free; end;
      TraceStep('initial child closing');
    finally
      FreeAndNil(DMUser); Application.OnException:=nil; ExceptionHandler.Free;
    end;
  except
    on E: Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
end;

procedure SetPdfRestartFixtureSubsystem(const FileName: string);
var Stream: TFileStream; Header: Cardinal; Subsystem: Word;
begin
  // The real Reader is a GUI application. Its private test replacement must
  // not ask Windows to allocate a console on restart from the GUI updater.
  Stream:=TFileStream.Create(FileName,fmOpenReadWrite or fmShareExclusive);
  try
    Stream.Position:=$3C; Stream.ReadBuffer(Header,SizeOf(Header));
    Stream.Position:=Header+24+68;
    Stream.ReadBuffer(Subsystem,SizeOf(Subsystem));
    Require(Subsystem=IMAGE_SUBSYSTEM_WINDOWS_CUI,'Expected a console test executable');
    Subsystem:=IMAGE_SUBSYSTEM_WINDOWS_GUI;
    Stream.Position:=Stream.Position-SizeOf(Subsystem);
    Stream.WriteBuffer(Subsystem,SizeOf(Subsystem));
  finally Stream.Free; end;
end;

procedure TestSaveModuleRestart;
var Child, Command, Report, Text: string; Startup: TStartupInfo; Request: TJSONObject;
  Process: TProcessInformation; Started: UInt64; Code, SuccessorPID: Cardinal; Successor: THandle;
begin
  RequireIsolatedRegression;
  Require(IsProgramUpdateApplicationName('homelibru.exe') and
    IsProgramUpdateApplicationName('HOMELIBREADER.EXE'),'Updater rejects Windows filename case');
  Request:=TJSONObject.Create;
  try
    Require(ReadProgramUpdateApplication(Request)='HomeLibRu.exe','Old update request lost its default application');
    Request.AddPair('application','homelibru.exe');
    Require(ReadProgramUpdateApplication(Request)='homelibru.exe','Explicit update application name changed');
  finally Request.Free; end;
  for var Invalid in ['Other.exe','HomeLibRu.exe.exe','..\HomeLibRu.exe',
    'C:\HomeLibRu.exe','HomeLibReader.exe ',''] do
    Require(not IsProgramUpdateApplicationName(Invalid),'Updater accepted an unrelated executable name');
  Child:=ParamStr(2);
  // Exercise the current shipping filename; the HomeLibre EXE migration is
  // separately queued and must cover every updater/reader filename consumer.
  if Child='kindle' then Child:='HomeLibReader.exe';
  if Child='pdf-zip' then Child:='HomeLibreReader.exe';
  if (Child='legacy-request') or (Child='packing') or (Child='sql') then Child:='HomeLibRu.exe';
  if (Child='compression') or (Child='packed-update') then Child:='HomeLibre.exe';
  if Child='' then Child:='HomeLibReader.exe';
  Require(IsProgramUpdateApplicationName(Child),'Unexpected real updater regression application');
  Writeln('TRACE actual installer application ',Child);
  Child:=Settings.AppPath+Child; Report:=Settings.AppPath+'save-module-result.txt';
  TFile.Copy(ParamStr(0),Child,False);
  if ParamStr(2)='pdf-zip' then SetPdfRestartFixtureSubsystem(Child);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Command:='"'+Child+'" save-module-restart-child';
  if ParamStr(2)='kindle' then Command:=Command+' kindle';
  if ParamStr(2)='pdf-zip' then Command:=Command+' pdf-zip "--open='+Settings.AppPath+'module-source.zip"';
  if ParamStr(2)='packing' then Command:=Command+' packing';
  if ParamStr(2)='sql' then Command:=Command+' sql';
  if ParamStr(2)='compression' then Command:=Command+' compression';
  if ParamStr(2)='packed-update' then Command:=Command+' packed-update';
  if ParamStr(2)='legacy-request' then
  begin Command:=Command+' legacy-request'; Writeln('TRACE pre5.33 request omits application'); end;
  // The real reader restart protection pins its --open input. Test mode
  // arguments are not a book filename; retain a genuine existing input too.
  if SameText(ExtractFileName(Child),'HomeLibReader.exe') then
    if ParamStr(2)='kindle' then Command:=Command+' "--open='+Settings.AppPath+'module-source.fb2"'
    else Command:=Command+' "--open='+Settings.AppPath+'module-source.pdf"';
  UniqueString(Command);
  Require(CreateProcess(PChar(Child),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Settings.AppPath),Startup,Process),'Cannot start real module restart regression');
  try
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(10);
      Require(GetTickCount64-Started<180000,'Real installer restart did not complete');
      if FileExists(Report) then Break;
      if WaitForSingleObject(Process.hProcess,0)=WAIT_OBJECT_0 then
      begin
        Require(GetExitCodeProcess(Process.hProcess,Code),'Cannot read initial module child exit');
        Require(Code=0,'Initial module child failed before actual installer restart');
      end;
    until False;
    Text:=TFile.ReadAllText(Report,TEncoding.UTF8);
    Require(Text.StartsWith('PASS '),Text); Writeln(Text);
    Require(WaitForSingleObject(Process.hProcess,10000)=WAIT_OBJECT_0,'Initial module child remains active');
    Require(TryStrToUInt(Text.Split([#10])[1].Trim,SuccessorPID),'Restart report omits its successor process');
    Successor:=OpenProcess(SYNCHRONIZE,False,SuccessorPID);
    if Successor<>0 then
      try Require(WaitForSingleObject(Successor,10000)=WAIT_OBJECT_0,'Restored review process remains active');
      finally CloseHandle(Successor); end;
  finally CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
end;

type
  TPdfSaveCheckWorker = class(TComponentUpdateThread)
  public
    ReleaseJSON, FeedJSON: string;
  protected
    function FetchText(const URL: string): string; override;
  end;

  TPdfSaveUpdateForm = class(TfrmProgramUpdate)
  public
    Server: TRepairServer;
    Bundles: string;
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease;
      const Job: string): TProgramDownloadThread; override;
    function StartInstallationHelper(const Helper, Parameters, Directory: string): THandle; override;
  end;

  TPdfSaveHost = class(TfrmReaderHost)
  public
    Server: TRepairServer;
    Bundles: string;
  protected
    function CreateUpdates: TfrmProgramUpdate; override;
    function BookSaveProgressClass: TBookSaveProgressClass; override;
  end;

  TPdfSaveProgress = class(TExportToDeviceProgressForm)
  protected
    function ShowMessage(const Text: string; Flags: Longint = MB_OK): Integer; override;
  public
    class var CompleteNotice: string;
  end;

  TPdfSaveRestartDriver = class
  public
    Host: TPdfSaveHost;
    Folder: string;
    Successor, SaveStarted, DownloadStarted, InstallStarted, Done: Boolean;
    ReviewCount: Integer;
    procedure Tick(Sender: TObject);
  end;

function TPdfSaveCheckWorker.FetchText(const URL: string): string;
begin
  if URL=COMPONENT_MIRROR_API then Exit(ReleaseJSON);
  if URL='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+COMPONENT_FEED_NAME then
    Exit(FeedJSON);
  raise Exception.Create('Unexpected PDF save component request: '+URL);
end;

function TPdfSaveUpdateForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
var Probe: TPdfSaveCheckWorker;
begin
  Probe:=TPdfSaveCheckWorker.Create(Window,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
  Probe.ReleaseJSON:=TFile.ReadAllText(Bundles+'local-mirror-release.json',TEncoding.UTF8);
  Probe.FeedJSON:=TFile.ReadAllText(Bundles+COMPONENT_FEED_NAME,TEncoding.UTF8);
  Result:=Probe;
end;

function TPdfSaveUpdateForm.CreateDownloadWorker(Window: HWND;
  const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin
  Result:=TRepairWorker.Create(Window,Info,Job,Server);
end;

function TPdfSaveUpdateForm.StartInstallationHelper(const Helper, Parameters, Directory: string): THandle;
var Startup: TStartupInfo; Process: TProcessInformation; Command: string;
begin
  Require(not LaunchInstallation,'A reentrant installer launch was accepted before the first process handle arrived');
  // Keep the actual helper on the test's private desktop.
  Command:='"'+Helper+'" '+Parameters; UniqueString(Command);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Win32Check(CreateProcess(PChar(Helper),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Directory),Startup,Process));
  CloseHandle(Process.hThread);
  Result:=Process.hProcess;
end;

function TPdfSaveHost.CreateUpdates: TfrmProgramUpdate;
var Dialog: TPdfSaveUpdateForm;
begin
  Dialog:=TPdfSaveUpdateForm.CreateForReader(Self);
  Dialog.Bundles:=Bundles; Dialog.Server:=Server;
  Result:=Dialog;
end;

function TPdfSaveHost.BookSaveProgressClass: TBookSaveProgressClass;
begin Result:=TPdfSaveProgress; end;

function TPdfSaveProgress.ShowMessage(const Text: string; Flags: Longint): Integer;
begin
  if (Flags and $F)<>MB_OK then Exit(IDCANCEL);
  CompleteNotice:=Text;
  Result:=IDOK;
end;

procedure TPdfSaveRestartDriver.Tick(Sender: TObject);
var View: TfrmBuiltinReader; Primary: TButton; Entry: TMenuItem;
begin
  for var I:=Screen.FormCount-1 downto 0 do
  begin
    var Form:=Screen.Forms[I];
    if not Form.Visible then Continue;
    if Form is TBookSendOptionsForm then
    begin
      Require(Assigned(Form.PopupParent) and (Form.PopupParent is TfrmBuiltinReader),
        'Save As is not owned by the visible PDF reader');
      Inc(ReviewCount); Require(ReviewCount=1,'The same save review was shown twice');
      var FormatBox:=Form.FindComponent('SendFormat') as TComboBox;
      var Destination:=Form.FindComponent('SendDestination') as TEdit;
      var Mask:=Form.FindComponent('SaveNameTemplate') as TEdit;
      var Images:=Form.FindComponent('SendImages') as TComboBox;
      var Grayscale:=Form.FindComponent('SendGrayscale') as TCheckBox;
      var Subfolders:=Form.FindComponent('SaveSubfolders') as TCheckBox;
      if Successor then
        Require((FormatBox.Text='Преобразовать в EPUB') and (Destination.Text=Folder+'module-output') and
          (Mask.Text='После обновления') and (Images.ItemIndex=BOOK_QUALITY_MAXIMUM) and
          Grayscale.Checked and not Subfolders.Checked,
          'The restarted Save As lost the format, destination, name or image settings')
      else
      begin
        FormatBox.ItemIndex:=FormatBox.Items.IndexOf('Преобразовать в EPUB');
        Require(FormatBox.ItemIndex>=0,'PDF Save As offers no EPUB format');
        FormatBox.OnChange(FormatBox);
        Destination.Text:=Folder+'module-output'; Mask.Text:='После обновления';
        Images.ItemIndex:=BOOK_QUALITY_MAXIMUM; Images.OnChange(Images);
        Grayscale.Checked:=True; Subfolders.Checked:=False;
      end;
      Require(not (Form.FindComponent('SkipDamagedFB2Image') as TCheckBox).Visible,
        'PDF in a ZIP shows a setting for FB2 images');
      Require(not FileExists(Folder+'module-output\После обновления.epub'),
        'Save As created output before approval');
      Form.ModalResult:=mrOk;
      Exit;
    end;
    if Form.Name='OptionalComponentPrompt' then
    begin
      Require(not Successor,'EPUB export requested another module after upgrading BookProcessing');
      if InstallStarted then Exit;
      Primary:=Form.FindComponent('ComponentPromptDownload') as TButton;
      if not Primary.Enabled then Exit;
      if DownloadStarted then
      begin
        Require(Primary.Caption='Установить и перезапустить',
          'The compatible BookProcessing archive could not be prepared: '+
          (Form.FindComponent('ComponentPromptReason') as TMemo).Text);
        Require((Host.Server.Requests=2) and (Host.Server.Failure='') and
          (BookProcessingSaveOptionsAPI(Folder)=8),
          'Download changed the old module or fetched more than the two required packages');
        InstallStarted:=True;
        Primary.Click;
        Require(FileExists(BookSaveContinuationFile(Settings.SettingsFileName)+'.ready'),
          'The reader did not arm the pending save for its successor');
        Done:=True;
      end
      else
      begin
        Require(string(Primary.Caption).StartsWith('Скачать'),
          'The reader did not offer the compatible component: '+
          (Form.FindComponent('ComponentPromptReason') as TMemo).Text);
        DownloadStarted:=True; Primary.Click;
      end;
      Exit;
    end;
  end;
  for var I:=0 to Host.ComponentCount-1 do
    if Host.Components[I] is TfrmBuiltinReader then
    begin
      View:=TfrmBuiltinReader(Host.Components[I]);
      if not (View.Visible and View.Ready) or View.PageLoading then Exit;
      if Successor then
      begin
        if FileExists(BookSaveContinuationFile(Settings.SettingsFileName)) or
          not FileExists(Folder+'module-output\После обновления.epub') then Exit;
        Done:=True; View.Close; Exit;
      end;
      if SaveStarted then
      begin
        Require(not FileExists(Folder+'module-output\После обновления.epub'),
          'The partial processing installation bypassed the update request');
        Exit;
      end;
      for var J:=0 to View.Menu.Items[0].Count-1 do
      begin
        Entry:=View.Menu.Items[0].Items[J];
        if Entry.Caption<>'Сохранить как…' then Continue;
        SaveStarted:=True; Entry.Click; Exit;
      end;
      Require(False,'The real PDF reading window offers no Save As command');
    end;
end;

procedure RunPdfZipSaveRestartChild;
var Folder, Report, Source, Hash, BundleFolder, OutputFile, Content: string;
  Host: TPdfSaveHost; Server: TRepairServer; Driver: TPdfSaveRestartDriver;
  Timer: TTimer; ExceptionHandler: TSaveModuleExceptionHandler; Started: UInt64;
  Fixture: TJSONObject; Archive: TZipFile; Data: TBytes;
  Version: string;
  procedure TraceStep(const Value: string);
  begin
    TFile.AppendAllText(Folder+'save-module-trace.txt',
      IntToStr(GetCurrentProcessId)+' '+Value+sLineBreak,TEncoding.UTF8);
  end;
begin
  Folder:=ExtractFilePath(ParamStr(0)); Report:=Folder+'save-module-result.txt';
  Source:=Folder+'module-source.zip'; Hash:=UpdateSHA256(Source);
  BundleFolder:=Folder+'save-module-fixture\';
  try
    TraceStep('child entry');
    Require(SameText(Hash,TFile.ReadAllText(Folder+'module-source.sha256',TEncoding.ASCII)),
      'The archived PDF changed between the old process and its successor');
    Application.Initialize;
    ExceptionHandler:=TSaveModuleExceptionHandler.Create; ExceptionHandler.Report:=Report;
    Application.OnException:=ExceptionHandler.Handle;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    TraceStep('profile initialized');
    Server:=TRepairServer.Create; Host:=TPdfSaveHost.Create(nil);
    Driver:=TPdfSaveRestartDriver.Create; Timer:=TTimer.Create(nil);
    try
      Host.Server:=Server; Host.Bundles:=BundleFolder;
      Fixture:=TJSONObject.ParseJSONValue(TFile.ReadAllText(BundleFolder+'fixture.json',TEncoding.UTF8)) as TJSONObject;
      try
        Version:=Fixture.GetValue<string>('version');
        for var Entry in Fixture.GetValue<TJSONArray>('components') do
        begin
          Server.URLs.Add(Entry.GetValue<string>('url'));
          Server.Files.Add(BundleFolder+Entry.GetValue<string>('name'));
        end;
        Require(Server.URLs.Count=2,'Fixture must contain exactly BookProcessing and ImageProcessing');
        Driver.Successor:=InstalledComponentVersion(Folder,'BookProcessing')=Version;
      finally Fixture.Free; end;
      if Driver.Successor then
      begin
        TraceStep('successor with installed component');
        Require((BookProcessingSaveOptionsAPI(Folder)>=BOOK_PROCESSING_EXTENDED_EXPORT_API) and
          not ComponentNeedsRepair(Folder,'BookProcessing') and not ComponentNeedsRepair(Folder,'ImageProcessing'),
          'The successor lacks one of the required modules');
      end
      else
      begin
        Require(not FileExists(Folder+'pdf-save-started.marker') and (BookProcessingSaveOptionsAPI(Folder)=8),
          'The installer restarted without upgrading the old beta 16 module');
        TFile.WriteAllText(Folder+'pdf-save-started.marker','Owned fixture, one install request');
      end;
      Driver.Host:=Host; Driver.Folder:=Folder;
      Timer.Interval:=50; Timer.OnTimer:=Driver.Tick;
      Host.OpenInitialFile(Source);
      Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
        Require(GetTickCount64-Started<120000,'Timed out opening, updating or exporting the archived PDF');
      until Driver.Done;
      TraceStep('reader workflow completed');
      Require((Driver.ReviewCount=1) and (UpdateSHA256(Source)=Hash),'The PDF source changed or its save was duplicated');
      if Driver.Successor then
      begin
        Require((Server.Requests=0) and not FileExists(BookSaveContinuationFile(Settings.SettingsFileName)),
          'The export downloaded again or left a pending save');
        Require(TPdfSaveProgress.CompleteNotice.StartsWith('Копии сохранены: 1 из 1. Ошибок сохранения нет.'),
          'The resumed export did not report one complete save');
        OutputFile:=Folder+'module-output\После обновления.epub';
        Archive:=TZipFile.Create;
        try
          Archive.Open(OutputFile,zmRead);
          Archive.Read('mimetype',Data);
          Require(TEncoding.ASCII.GetString(Data)='application/epub+zip','Export did not create an EPUB');
          Content:='';
          for var Name in Archive.FileNames do
            if Name.EndsWith('.xhtml') then
            begin Archive.Read(Name,Data); Content:=Content+TEncoding.UTF8.GetString(Data); end;
          Require(Content.Contains('First readable paragraph') and Content.Contains('Last paragraph'),
            'EPUB lost the first or last text from the archived PDF');
        finally Archive.Free; end;
        TFile.WriteAllText(Report,'PASS beta 16 PDF in ZIP installs both required modules in one restart and exports with restored settings'+
          sLineBreak+IntToStr(GetCurrentProcessId),TEncoding.UTF8);
      end;
    finally
      Timer.Free; Driver.Free; Host.Free; Server.Free; FreeAndNil(DMUser);
      Application.OnException:=nil; ExceptionHandler.Free;
    end;
  except
    on E: Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
end;
