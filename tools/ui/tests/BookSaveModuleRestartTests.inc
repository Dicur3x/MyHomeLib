// Real compact download, prepared files, external installer and a successor
// process. Only the network transport is redirected to owned loopback data.
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
    Request.AddPair('tag','2.7.0_pre5.35');
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
  // This early child entry precedes the shared DMUser/Settings bootstrap.
  Report:=ExtractFilePath(ParamStr(0))+'save-module-result.txt';
  Source:=ExtractFilePath(ParamStr(0))+'module-source.pdf'; SourceHash:=UpdateSHA256(Source);
  TraceStep('child entry');
  try
    Application.Initialize;
    ExceptionHandler:=TSaveModuleExceptionHandler.Create; ExceptionHandler.Report:=Report;
    Application.OnException:=ExceptionHandler.Handle;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    TraceStep('component='+InstalledComponentVersion(Settings.AppPath,'BookConverter'));
    try
      if InstalledComponentVersion(Settings.AppPath,'BookConverter')='2.7.0.1103' then
      begin
        // Production always has a main host/catalogue, even when its launcher
        // is hidden. A bare console child must recreate that VCL prerequisite.
        Application.CreateForm(TForm,ReviewParent); ReviewParent.Caption:='Save restart review';
        Require(FileExists(Settings.AppPath+'tools/bookconvert/SAVE_OPTIONS_API.txt'),
          'Actual installer lost Save As capability marker');
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
        TFile.WriteAllText(Report,'PASS compact converter 1102 to 1103 download actual installer restart restored review cancel and unchanged source'+
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
        Info:=Default(TProgramRelease); Info.ComponentID:='BookConverter';
        Info.ComponentVersion:='2.7.0.1103'; Info.Tag:='2.7.0_pre5.35';
        Info.DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+Info.Tag+'/HomeLibRu-BookConverter-test.zip';
        Info.SHA256:=Root.GetValue<string>('sha256'); Info.Size:=Root.GetValue<Int64>('size');
        Package:=Settings.AppPath+'save-module-fixture/HomeLibRu-BookConverter-'+ProgramUpdatePlatform+'.zip';
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
          if UPDATE_COMPONENTS[I].ID='BookConverter' then Releases[I]:=Info;
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
  if Child='legacy-request' then Child:='HomeLibRu.exe';
  if Child='' then Child:='HomeLibReader.exe';
  Require(IsProgramUpdateApplicationName(Child),'Unexpected real updater regression application');
  Writeln('TRACE actual installer application ',Child);
  Child:=Settings.AppPath+Child; Report:=Settings.AppPath+'save-module-result.txt';
  TFile.Copy(ParamStr(0),Child,False);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Command:='"'+Child+'" save-module-restart-child';
  if ParamStr(2)='legacy-request' then
  begin Command:=Command+' legacy-request'; Writeln('TRACE pre5.33 request omits application'); end;
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
