program OfflinePrerequisiteDialogTest;

{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Program\lang.res'}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  Winapi.Windows, Winapi.Messages, Vcl.Forms, Vcl.ExtCtrls,
  unit_MHLTheme, unit_EpubPdfRuntime;

procedure Require(Value: Boolean; const Detail: string);
begin if not Value then raise Exception.Create(Detail); end;

procedure Trace(const Detail: string);
begin
  TFile.AppendAllText(ExtractFilePath(ParamStr(0))+'ui-stage.txt',Detail+sLineBreak,TEncoding.UTF8);
end;

type
  TJobAccounting = record
    TotalUserTime, TotalKernelTime, ThisPeriodUserTime, ThisPeriodKernelTime: Int64;
    TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses: DWORD;
  end;

  TPromptTimeout = class
    Fired: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TPromptTimeout.Tick(Sender: TObject);
var Prompt: HWND;
begin
  Prompt:=FindWindow('#32770','Сохранение EPUB в PDF');
  if (Prompt<>0) and (GetWindowThreadProcessId(Prompt,nil)=GetCurrentThreadId) then
  begin
    Fired:=True;
    PostMessage(Prompt,WM_COMMAND,IDCANCEL,0);
  end;
end;

procedure Run;
var Job: THandle; Limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  Accounting: TJobAccounting;
  RegistryRoot: HKEY; Disposition: DWORD; ID: TGUID; Key: string;
  Owner: TForm; Timer: TTimer; Timeout: TPromptTimeout; Installed: Boolean;
begin
  RequireIsolatedRegression;
  Trace('isolated');
  Require((ParamStr(1)='light') or (ParamStr(1)='dark'),'Specify light or dark');
  // This test can never launch an installer, even if its confirmation button
  // is clicked accidentally. No Windows-wide setting or runtime is changed.
  Job:=CreateJobObject(nil,nil);
  if Job=0 then RaiseLastOSError;
  try
    Limits:=Default(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    Limits.BasicLimitInformation.LimitFlags:=JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    Limits.BasicLimitInformation.ActiveProcessLimit:=1;
    if not SetInformationJobObject(Job,JobObjectExtendedLimitInformation,@Limits,SizeOf(Limits)) or
      not AssignProcessToJobObject(Job,GetCurrentProcess) then RaiseLastOSError;
    Trace('child-process fence active');
    CreateGUID(ID); Key:='Software\HomeLibrePrerequisiteDialog-'+GUIDToString(ID);
    if RegCreateKeyEx(HKEY_CURRENT_USER,PChar(Key),0,nil,REG_OPTION_VOLATILE,KEY_ALL_ACCESS,
      nil,RegistryRoot,@Disposition)<>ERROR_SUCCESS then RaiseLastOSError;
    try
      Require(Disposition=REG_CREATED_NEW_KEY,'Registry fixture must be new');
      Require(RegOverridePredefKey(HKEY_CURRENT_USER,RegistryRoot)=ERROR_SUCCESS,'Cannot isolate user registry');
      try
        Require(RegOverridePredefKey(HKEY_LOCAL_MACHINE,RegistryRoot)=ERROR_SUCCESS,'Cannot isolate machine registry');
        try
          Require(not WebView2RuntimeInstalled,'Private empty registry reported WebView2');
          Trace('runtime registration isolated');
          Application.Initialize; Application.MainFormOnTaskbar:=False;
          Trace('VCL initialized');
          SetMHLTheme(ParamStr(1)='dark');
          Trace('theme applied');
          Require(MHLThemeDark=(ParamStr(1)='dark'),'Requested theme was not applied');
          Owner:=TForm.CreateNew(nil); Timer:=TTimer.Create(nil); Timeout:=TPromptTimeout.Create;
          try
            Owner.Caption:='HomeLibre — проверка отмены установки';
            Owner.Position:=poScreenCenter; Owner.Width:=640; Owner.Height:=160;
            Owner.Show; Application.ProcessMessages;
            Timer.Interval:=300000;
            if ParamStr(2)='--auto-cancel' then Timer.Interval:=400;
            Timer.OnTimer:=Timeout.Tick;
            Trace('opening production prompt');
            Installed:=EnsureEpubPdfRuntime(Owner,ExtractFilePath(ParamStr(0))+'temp');
            Trace('production prompt returned');
            Require(not Installed,'Cancellation unexpectedly reported installation');
            Require((ParamStr(2)='--auto-cancel') or not Timeout.Fired,
              'Manual inspection expired; cancellation came from the safety timer');
          finally Timer.Free; Timeout.Free; Owner.Free; FinalizeMHLTheme; end;
          Require(not WebView2RuntimeInstalled,'Cancellation changed the runtime registration');
        finally RegOverridePredefKey(HKEY_LOCAL_MACHINE,0); end;
      finally RegOverridePredefKey(HKEY_CURRENT_USER,0); end;
    finally
      RegCloseKey(RegistryRoot);
      if Disposition=REG_CREATED_NEW_KEY then
        Require(RegDeleteKey(HKEY_CURRENT_USER,PChar(Key))=ERROR_SUCCESS,'Private registry fixture was not removed');
    end;
    Accounting:=Default(TJobAccounting);
    if not QueryInformationJobObject(Job,JobObjectBasicAccountingInformation,@Accounting,SizeOf(Accounting),nil) then
      RaiseLastOSError;
    Require(Accounting.TotalProcesses=1,'Prerequisite prompt launched a child process');
    Require(not DirectoryExists(ExtractFilePath(ParamStr(0))+'temp'),'Cancellation created installation work files');
    Writeln('PASS production prerequisite prompt cancelled; child processes=0; private registry removed');
  finally CloseHandle(Job); end;
end;

begin
  try Run;
  except on E:Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); ExitCode:=1; end; end;
end.
