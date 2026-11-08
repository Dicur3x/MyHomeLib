unit unit_EpubPdfRuntime;

interface

uses Vcl.Forms;

function WebView2RuntimeInstalled: Boolean;
function EnsureEpubPdfRuntime(Owner: TForm; const TempFolder: string): Boolean;

implementation

uses System.Classes, System.SysUtils, System.IOUtils, System.Win.Registry, System.RegularExpressions,
  System.SyncObjs, System.Net.HttpClient, Winapi.Windows, Vcl.Controls, Vcl.Dialogs, Vcl.StdCtrls,
  Vcl.ComCtrls, Vcl.ExtCtrls, unit_MHLHttpClient, unit_UpdateAuthenticity, unit_MHLTheme;

const
  WebView2BootstrapperURL = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  MaxBootstrapperBytes = 8*1024*1024;
  StageDownloading = 0;
  StageInstalling = 1;
  StageCancelled = -1;

function WebView2RuntimeInstalled: Boolean;
const ClientKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  function Registered(Root: HKEY; View: LongWord): Boolean;
  var Registry: TRegistry; Version: string;
  begin
    Registry:=TRegistry.Create(KEY_READ or View);
    try
      Registry.RootKey:=Root;
      if not Registry.OpenKeyReadOnly(ClientKey) or not Registry.ValueExists('pv') or
        (Registry.GetDataType('pv')<>rdString) then Exit(False);
      Version:=Trim(Registry.ReadString('pv'));
      Result:=TRegEx.IsMatch(Version,'^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') and
        (Version.Trim(['0','.'])<>'');
    finally Registry.Free; end;
  end;
begin
  Result:=Registered(HKEY_CURRENT_USER,0) or Registered(HKEY_LOCAL_MACHINE,KEY_WOW64_32KEY);
end;

type
  TWebViewInstallThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FTempFolder: string;
    FStage: Integer;
    procedure ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);
    function StartInstaller(const FileName: string): THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(const TempFolder: string);
    destructor Destroy; override;
    procedure CancelDownload;
    function Stage: Integer;
  end;

  TWebViewInstallProgress = class(TForm)
  private
    FWorker: TWebViewInstallThread;
    FStatus: TLabel;
    FCancel: TButton;
    procedure Poll(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure QueryClose(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateProgress(Owner: TForm; Worker: TWebViewInstallThread);
  end;

constructor TWebViewInstallThread.Create(const TempFolder: string);
begin
  inherited Create(True);
  FTempFolder:=TempFolder;
  FHTTP:=CreateHTTPClientUpdate;
  FHTTP.ConnectionTimeout:=10000;
  FHTTP.ResponseTimeout:=15000;
  FHTTP.OnReceiveData:=ReceiveData;
end;

destructor TWebViewInstallThread.Destroy;
begin
  inherited;
  FHTTP.Free;
end;

function TWebViewInstallThread.Stage: Integer;
begin Result:=TInterlocked.CompareExchange(FStage,StageDownloading,StageDownloading); end;

procedure TWebViewInstallThread.CancelDownload;
begin TInterlocked.CompareExchange(FStage,StageCancelled,StageDownloading); end;

procedure TWebViewInstallThread.ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);
begin
  Abort:=(Stage=StageCancelled) or (ContentLength>MaxBootstrapperBytes) or (ReadCount>MaxBootstrapperBytes);
end;

function TWebViewInstallThread.StartInstaller(const FileName: string): THandle;
var Startup: TStartupInfo; Process: TProcessInformation; Command: string;
begin
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Command:='"'+FileName+'" /silent /install'; UniqueString(Command);
  if not CreateProcess(PChar(FileName),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(ExtractFileDir(FileName)),Startup,Process) then RaiseLastOSError;
  CloseHandle(Process.hThread);
  Result:=Process.hProcess;
end;

procedure TWebViewInstallThread.Execute;
var WorkFolder, FileName: string; ID: TGUID; Output: TFileStream; Process: THandle; ExitCode: DWORD;
begin
  if WebView2RuntimeInstalled or (Stage=StageCancelled) then Exit;
  CreateGUID(ID);
  WorkFolder:=TPath.Combine(FTempFolder,'HomeLibre-WebView2-'+GUIDToString(ID));
  if not CreateDirectory(PChar(WorkFolder),nil) then RaiseLastOSError;
  FileName:=TPath.Combine(WorkFolder,'MicrosoftEdgeWebView2Setup.exe');
  try
    Output:=TFileStream.Create(FileName,fmCreate or fmShareExclusive);
    try
      var Reply:=FHTTP.Get(WebView2BootstrapperURL,Output);
      if Stage=StageCancelled then Exit;
      if (Reply.StatusCode<>200) or (Output.Size<=0) or (Output.Size>MaxBootstrapperBytes) then
        raise Exception.Create('Microsoft не вернула допустимый файл установщика WebView2.');
    finally Output.Free; end;
    if Stage=StageCancelled then Exit;
    Output:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
    try
      VerifyWebView2BootstrapperSignature(FileName);
      if WebView2RuntimeInstalled then Exit;
      if TInterlocked.CompareExchange(FStage,StageInstalling,StageDownloading)<>StageDownloading then Exit;
      Process:=StartInstaller(FileName);
    finally Output.Free; end;
    try
      if WaitForSingleObject(Process,INFINITE)<>WAIT_OBJECT_0 then RaiseLastOSError;
      if not GetExitCodeProcess(Process,ExitCode) then RaiseLastOSError;
      if (ExitCode<>0) and not WebView2RuntimeInstalled then
        raise Exception.CreateFmt('Установщик Microsoft завершился с кодом 0x%.8x.',[ExitCode]);
    finally CloseHandle(Process); end;
  finally
    try
      if FileExists(FileName) then TFile.Delete(FileName);
    finally
      TDirectory.Delete(WorkFolder,False);
    end;
  end;
end;

constructor TWebViewInstallProgress.CreateProgress(Owner: TForm; Worker: TWebViewInstallThread);
begin
  inherited CreateNew(Owner);
  FWorker:=Worker;
  Name:='WebViewInstallProgress'; Caption:='Установка WebView2';
  Position:=poOwnerFormCenter; BorderStyle:=bsDialog; ClientWidth:=395; ClientHeight:=120;
  PopupMode:=pmExplicit; PopupParent:=Owner;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.SetBounds(16,14,363,34);
  FStatus.AutoSize:=False; FStatus.WordWrap:=True;
  FStatus.Caption:='Скачиваем установщик с сайта Microsoft…';
  var Bar:=TProgressBar.Create(Self); Bar.Parent:=Self;
  Bar.SetBounds(16,52,363,12); Bar.Style:=pbstMarquee;
  FCancel:=TButton.Create(Self); FCancel.Parent:=Self; FCancel.SetBounds(280,80,99,26);
  FCancel.Caption:='Отмена'; FCancel.Cancel:=True; FCancel.OnClick:=CancelClick;
  var Timer:=TTimer.Create(Self); Timer.Interval:=100; Timer.OnTimer:=Poll;
  OnCloseQuery:=QueryClose;
  ApplyMHLControlTheme(Self);
end;

procedure TWebViewInstallProgress.CancelClick(Sender: TObject);
begin FWorker.CancelDownload; Poll(nil); end;

procedure TWebViewInstallProgress.QueryClose(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=WaitForSingleObject(FWorker.Handle,0)=WAIT_OBJECT_0;
  if not CanClose then CancelClick(nil);
end;

procedure TWebViewInstallProgress.Poll(Sender: TObject);
begin
  if WaitForSingleObject(FWorker.Handle,0)=WAIT_OBJECT_0 then
  begin ModalResult:=mrOk; Exit; end;
  FCancel.Enabled:=FWorker.Stage=StageDownloading;
  case FWorker.Stage of
    StageInstalling: FStatus.Caption:='Microsoft устанавливает WebView2 Runtime…';
    StageCancelled: FStatus.Caption:='Отменяем загрузку…';
  end;
end;

function EnsureEpubPdfRuntime(Owner: TForm; const TempFolder: string): Boolean;
var Prompt: TTaskDialog; Worker: TWebViewInstallThread; Progress: TWebViewInstallProgress;
begin
  if WebView2RuntimeInstalled then Exit(True);
  Result:=False;
  Prompt:=TTaskDialog.Create(Owner);
  try
    Prompt.Caption:='Сохранение EPUB в PDF';
    Prompt.Title:='Установить Microsoft WebView2 Runtime?';
    Prompt.Text:='Эта среда нужна для вёрстки EPUB в PDF. Скачаем установщик Microsoft (около 2 МБ). '+
      'Он загрузит дополнительный пакет среды. Его размер зависит от системы.';
    Prompt.CommonButtons:=[tcbCancel]; Prompt.Flags:=[tfAllowDialogCancellation];
    var Button:=TTaskDialogButtonItem(Prompt.Buttons.Add);
    Button.Caption:='Скачать и установить'; Button.ModalResult:=mrOk;
    if not Prompt.Execute(Owner.Handle) or (Prompt.ModalResult<>mrOk) then Exit;
  finally Prompt.Free; end;
  Worker:=TWebViewInstallThread.Create(TempFolder);
  try
    Progress:=TWebViewInstallProgress.CreateProgress(Owner,Worker);
    try
      Worker.Start;
      Progress.ShowModal;
    finally Progress.Free; end;
    Worker.WaitFor;
    if Worker.Stage=StageCancelled then Exit;
    if Worker.FatalException is Exception then
      MessageDlg('Не удалось установить WebView2. '+Exception(Worker.FatalException).Message,mtError,[mbOK],0)
    else if not WebView2RuntimeInstalled then
      MessageDlg('Среда WebView2 пока недоступна. После завершения установки повторите действие.',
        mtInformation,[mbOK],0)
    else Result:=True;
  finally Worker.Free; end;
end;

end.
