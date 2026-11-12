type
  TImageInstallerForm = class(TRepairForm)
  private
    FChild: THandle;
  protected
    function StartInstallationHelper(const Helper, Parameters, Directory: string): THandle; override;
  public
    Starts: Integer;
    function RealShellProbe(const Helper, Directory: string): THandle;
    procedure StopOwnedHelper;
    destructor Destroy; override;
  end;

function TImageInstallerForm.StartInstallationHelper(const Helper, Parameters, Directory: string): THandle;
var Startup: TStartupInfo; Process: TProcessInformation; Command: string;
begin
  Require(Parameters.StartsWith('--job "') and Directory.StartsWith(Settings.AppPath),
    'Repeated install fixture escaped its own cache');
  Inc(Starts); Command:='"'+Helper+'" --parent 60000'; UniqueString(Command);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  // A real owned process holds the exact destination EXE open, reproducing 32.
  // Only its work is replaced with a bounded sleep; production launch is normal.
  if not CreateProcess(PChar(Helper),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Directory),Startup,Process) then RaiseLastOSError;
  CloseHandle(Process.hThread);
  if not DuplicateHandle(GetCurrentProcess,Process.hProcess,GetCurrentProcess,@FChild,
    0,False,DUPLICATE_SAME_ACCESS) then
  begin TerminateProcess(Process.hProcess,75); CloseHandle(Process.hProcess); RaiseLastOSError; end;
  Result:=Process.hProcess;
end;

procedure TImageInstallerForm.StopOwnedHelper;
begin
  if FChild=0 then Exit;
  if WaitForSingleObject(FChild,0)=WAIT_TIMEOUT then
    Require(TerminateProcess(FChild,75),'Could not stop owned helper fixture');
  Require(WaitForSingleObject(FChild,10000)=WAIT_OBJECT_0,'Owned helper fixture did not stop');
  CloseHandle(FChild); FChild:=0;
end;

destructor TImageInstallerForm.Destroy;
begin StopOwnedHelper; inherited; end;

function TImageInstallerForm.RealShellProbe(const Helper, Directory: string): THandle;
begin Result:=inherited StartInstallationHelper(Helper,'--parent 60000',Directory); end;

procedure TestImageUpdateIdentity;
var Server: TRepairServer; Dialog: TImageInstallerForm; Info: TProgramRelease;
  Primary: TButton; Status: TLabel; Root: TJSONObject;
  Fixture, Cache, Job, ReadyName, Helper, Digest, HelperHash, RequestHash, ManifestHash: string;
  Deadline: UInt64; Copied: Boolean; Error: DWORD; RealProcess: THandle;
  procedure FindControls;
  begin
    Primary:=nil; Status:=nil;
    for var Control in Dialog do
    begin
      if (Control is TButton) and TButton(Control).Default then Primary:=TButton(Control);
      if (Control is TLabel) and (Control.Name='UpdateStatus') then Status:=TLabel(Control);
    end;
    Require(Assigned(Primary) and Assigned(Status),'Image update controls missing');
  end;
  procedure ReadReady;
  begin
    Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReadyName,TEncoding.UTF8)) as TJSONObject;
    Require(Assigned(Root),'Ready metadata missing');
  end;
begin
  RequireIsolatedRegression;
  Fixture:=TPath.Combine(Settings.AppPath,'image-fixtures');
  Require(ParseImageComponent(TFile.ReadAllText(TPath.Combine(Fixture,'release.json'),TEncoding.UTF8),
    'JPEG XL',Info),'Image fixture metadata failed');
  Require(Info.Tag='v'+Info.ComponentVersion,'Expected the upstream v-prefixed identity');
  Require(not FileExists(Settings.AppPath+'HomeLibRuUpdater.exe'),'Fixture must not replace an installed helper');
  TFile.Copy(TPath.Combine(Fixture,'native-helper.exe'),Settings.AppPath+'HomeLibRuUpdater.exe');
  HelperHash:=UpdateSHA256(Settings.AppPath+'HomeLibRuUpdater.exe');
  Server:=TRepairServer.Create; Dialog:=nil; Job:='';
  try
    Server.URLs.Add(Info.DownloadURL);
    if ProgramUpdatePlatform='Win64' then Server.Files.Add(TPath.Combine(Fixture,'jxl-x64-windows-static.zip'))
    else Server.Files.Add(TPath.Combine(Fixture,'jxl-x86-windows-static.zip'));
    Dialog:=TImageInstallerForm.CreateForServer(Server); FindControls;
    Dialog.SetRelease(Info); Primary.Click; Deadline:=GetTickCount64+90000;
    repeat
      Application.ProcessMessages; CheckSynchronize(0); Sleep(1);
      Require(GetTickCount64<Deadline,'Image update preparation timed out: '+string(Status.Caption));
      Require(not (Primary.Enabled and (Primary.Caption='Повторить загрузку')),
        'Image update preparation failed: '+string(Status.Caption));
    until Primary.Enabled and (Primary.Caption='Установить и перезапустить');
    Cache:=ProgramUpdateCache(Settings.AppPath); ReadyName:=TPath.Combine(Cache,'ready.json');
    ReadReady;
    try
      Job:=Root.GetValue<string>('job'); Digest:=Root.GetValue<string>('sha256');
      Require(Root.GetValue<string>('tag')=Info.ComponentVersion,'Normal download saved the author label instead of prepared version');
      VerifyPreparedProgramUpdate(Job,Info.ComponentVersion,ProgramUpdatePlatform);
      Root.RemovePair('tag').Free; Root.AddPair('tag',Info.Tag);
      TFile.WriteAllText(ReadyName,Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
    ManifestHash:=UpdateSHA256(TPath.Combine(Job,'manifest.json'));
    FreeAndNil(Dialog);
    Dialog:=TImageInstallerForm.CreateForServer(Server); FindControls;
    Require(Dialog.RestoreReady,'An old official JPEG XL download could not be restored');
    ReadReady;
    try
      Require((Root.GetValue<string>('tag')=Info.ComponentVersion) and
        (Root.GetValue<string>('sha256')=Digest),'Cache repair changed the source checksum or retained the wrong version');
    finally Root.Free; end;
    Require(Server.Requests=1,'Cache repair unexpectedly downloaded the package again');
    Writeln('PASS official JPEG XL form prepares, persists and restores the numeric installation identity without redownload');
    Require(Dialog.LaunchInstallation,'First installer launch failed: '+string(Status.Caption));
    RequestHash:=UpdateSHA256(TPath.Combine(Job,'request.json'));
    Helper:=TPath.Combine(Job,'HomeLibRuUpdater.exe');
    Copied:=Winapi.Windows.CopyFile(PChar(Settings.AppPath+'HomeLibRuUpdater.exe'),PChar(Helper),False);
    Error:=GetLastError;
    Require(not Copied and (Error=ERROR_SHARING_VIOLATION),'Owned running helper did not reproduce Windows 32');
    Require(Dialog.LaunchInstallation,'Reentrant shutdown did not keep the active installer');
    Require((Dialog.Starts=1) and (UpdateSHA256(TPath.Combine(Job,'request.json'))=RequestHash),
      'Reentrant installation started twice or overwrote its request');
    Writeln('PASS repeated close/install reuses the active helper without copying its locked EXE or rewriting request');
    Dialog.StopOwnedHelper;
    Require(Dialog.LaunchInstallation and (Dialog.Starts=2),
      'A finished helper incorrectly blocked a new attempt: '+string(Status.Caption));
    Dialog.StopOwnedHelper;
    Writeln('PASS a terminated helper permits a new installation attempt');
    RealProcess:=Dialog.RealShellProbe(Helper,Job);
    try
      Require(WaitForSingleObject(RealProcess,0)=WAIT_TIMEOUT,'Production shell launch returned no live helper');
      Require(TerminateProcess(RealProcess,75),'Could not stop production shell fixture');
      Require(WaitForSingleObject(RealProcess,10000)=WAIT_OBJECT_0,'Production shell fixture did not exit');
    finally CloseHandle(RealProcess); end;
    Writeln('PASS production ShellExecuteEx returns an owned live process handle');
    FreeAndNil(Dialog);
    ReadReady;
    try
      Root.RemovePair('tag').Free; Root.AddPair('tag','v9.9.9');
      TFile.WriteAllText(ReadyName,Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
    Dialog:=TImageInstallerForm.CreateForServer(Server);
    Require(not Dialog.RestoreReady,'An unrelated cached release mismatch was silently accepted');
    Require(UpdateSHA256(TPath.Combine(Job,'manifest.json'))=ManifestHash,
      'Cache identity repair changed the prepared manifest');
    Writeln('PASS unrelated cache identities remain rejected and prepared manifest remains unchanged');
  finally
    Dialog.Free; Server.Free;
    if Job<>'' then CleanProgramUpdate(Job);
    if FileExists(ReadyName) then TFile.Delete(ReadyName);
    Require(UpdateSHA256(Settings.AppPath+'HomeLibRuUpdater.exe')=HelperHash,'Fixture helper changed');
    TFile.Delete(Settings.AppPath+'HomeLibRuUpdater.exe');
  end;
end;
