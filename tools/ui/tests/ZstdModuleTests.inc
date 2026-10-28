type
  TZstdPackageForm = class(TCMForm)
  public Server: TCMServer;
  protected function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread; override;
  end;
  TZstdPromptActions = class
    Dialog: TZstdPackageForm;
    Timer: TTimer;
    Started: UInt64;
    Phase: Integer;
    Cancel, Corrupt: Boolean;
    Error: string;
    procedure Tick(Sender: TObject);
  end;

function TZstdPackageForm.CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin
  var Worker:=TCMDownload.Create(Window,CreateHTTPClientGlobal,Info,Job);
  Worker.Server:=Server; Result:=Worker;
end;

procedure TZstdPromptActions.Tick(Sender: TObject);
var Prompt: TForm; Button: TButton;
begin
  Prompt:=Dialog.FindComponent('OptionalComponentPrompt') as TForm;
  if not Assigned(Prompt) then Exit;
  try
    if GetTickCount64-Started>20000 then raise Exception.Create('Zstandard modal operation timed out');
    Button:=Prompt.FindComponent('ComponentPromptDownload') as TButton;
    if not Prompt.Visible or not Button.Enabled then Exit;
    if Phase=0 then Require(string((Prompt.FindComponent('ComponentPromptReason') as TMemo).Text).Contains('МБ'),
      'Zstandard first-use prompt omitted download size');
    if Cancel then
    begin Timer.Enabled:=False; (Prompt.FindComponent('ComponentPromptCancel') as TButton).Click; Exit; end;
    if (Phase=0) and (Button.Caption='Скачать компонент') then
    begin Phase:=1; Button.Click; Exit; end;
    if (Phase=1) and (Button.Caption='Установить библиотеку') then
    begin Phase:=2; Button.Click; Exit; end;
    if Phase=2 then raise Exception.Create('Zstandard installation did not close its successful prompt: '+
      string((Prompt.FindComponent('ComponentPromptReason') as TMemo).Text));
    if Corrupt and (Button.Caption='Повторить загрузку') then
    begin Timer.Enabled:=False; (Prompt.FindComponent('ComponentPromptCancel') as TButton).Click; Exit; end;
  except on E: Exception do
  begin Error:=E.Message; Timer.Enabled:=False; Prompt.ModalResult:=mrCancel; end; end;
end;

procedure TestOptionalZstdModule;
const CompressedCatalogue = 'KLUv/WDlAI0IACaQMR9gh9MGwEC93T27xPAE+GJ3G4MTtqCBmu68UGIAWDgnJwAoACkA6IxpxgBQt1bb2aMX8HFStSwMLyb/eBLQya6PKSRN19kc/ZpEIHsjBdwrl6UJ3j5c1UAfNKXdUUYh+emFGo6eza0fR2f0DQJ0lgpFIN+PJEwyluw0i+sRSIZCgiRHuJL5QdzGM2i3liDJkthNPxD0RTJLE/lZ9uMBg9aa0p7YTYR8DquuDwkDjzpFqtZGRTjHh1WVNLFGT+EPpSkNSYayJRsAdpvCDSNwaI1mv9nvf8a6ujgnxoAlCpQtA6zlg7QpRwvtZaGuWJXDwuJDOqTWRliYhGHgBwcUGRtrmIhgFaeaDYUxH1CRAQ==';
var Folder, Metadata, Feed, Archive, Source, SourceHash, Ready, Legacy: string;
  Info: TProgramRelease; Server: TCMServer; Dialog: TZstdPackageForm; Actions: TZstdPromptActions;
  Reader: TMetabibReader; Book: TMetabibBook; Bytes: TBytes; Installed: Boolean;
  ReaderComponents: TfrmProgramUpdate;
begin
  RequireIsolatedRegression;
  Require(not FileExists(Settings.AppPath+'libzstd.dll'),'Optional Zstandard check must start without the DLL');
  Require(IsOptionalComponent('Zstandard') and not ComponentNotificationEnabled('Zstandard',''),
    'Zstandard must be optional without default update notifications');
  for var Name in ['HomeLibRu.exe','HomeLibReader.exe','sqlite3.dll','Data/collections.db','../libzstd.dll'] do
    Require(not SafeComponentFile('Zstandard',Name),'Zstandard package gained foreign file: '+Name);
  for var Name in ['library.inpx','catalogue.jsonl','catalogue.jsonl.gz','catalogue.zip','book.fb2','book.epub'] do
    Require(RequiredCatalogComponent(Settings.AppPath,Name)='','Ordinary catalogue or book requested Zstandard');
  Require(RequiredCatalogComponent(Settings.AppPath,'catalogue.JSONL.ZST')='Zstandard','Compressed catalogue did not request its decoder');
  Folder:=GetEnvironmentVariable('HOMELIB_ZSTD_COMPONENT_PACKAGES');
  Require(Folder<>'','Zstandard check requires actual packaged DLL');
  Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
  Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
  Require(ParseComponentMirror(Metadata,Feed,'Zstandard','',Info),'Zstandard feed rejected');
  Archive:=TPath.Combine(Folder,ComponentVersionedArchiveName('Zstandard',Info.ComponentVersion,ProgramUpdatePlatform));
  Source:=Settings.AppPath+'catalogue.jsonl.zst';
  TFile.WriteAllBytes(Source,TNetEncoding.Base64.DecodeStringToBytes(CompressedCatalogue)); SourceHash:=UpdateSHA256(Source);
  TFile.WriteAllText(Settings.AppPath+'HomeLibRu.exe','unchanged catalogue sentinel');
  Ready:=TPath.Combine(ProgramUpdateCache(Settings.AppPath),'ready.json'); ForceDirectories(ExtractFilePath(Ready));
  TFile.WriteAllText(Ready,'unchanged separately prepared update');
  Server:=TCMServer.Create;
  try
    Server.MirrorURL:=Info.DownloadURL; Server.PackageBytes:=TFile.ReadAllBytes(Archive);
    for var CaseIndex:=0 to 2 do
    begin
      Dialog:=TZstdPackageForm.Create(nil); Actions:=TZstdPromptActions.Create;
      try
        Dialog.Server:=Server; Dialog.Metadata:=Metadata; Dialog.Feed:=Feed;
        for var Item in (Dialog.FindComponent('UpdateComponents') as TListView).Items do
          Require(not string(Item.Caption).Contains('Zstandard'),'Absent Zstandard appeared without first-use request');
        Actions.Dialog:=Dialog; Actions.Cancel:=CaseIndex=0; Actions.Corrupt:=CaseIndex=1;
        Server.CorruptMirror:=Actions.Corrupt;
        Actions.Timer:=TTimer.Create(Dialog); Actions.Timer.Interval:=30; Actions.Timer.OnTimer:=Actions.Tick;
        Actions.Started:=GetTickCount64;
        Installed:=Dialog.InstallComponentForOperation('Zstandard','Выбранный каталог останется на месте.');
        Actions.Timer.Enabled:=False;
        Require(Actions.Error='',Actions.Error);
        Require(Installed=(CaseIndex=2),'Zstandard cancellation, corruption or installation returned wrong outcome');
        Require(FileExists(Settings.AppPath+'libzstd.dll')=(CaseIndex=2),'Cancelled or corrupt download installed Zstandard');
        Require(UpdateSHA256(Source)=SourceHash,'Zstandard request changed selected catalogue');
        Require(TFile.ReadAllText(Ready)='unchanged separately prepared update','Inline module clobbered another pending update');
      finally Dialog.Free; Actions.Free; end;
    end;
  finally Server.Free; end;
  Require(not ComponentNeedsRepair(Settings.AppPath,'Zstandard'),'Installed Zstandard runtime is incomplete');
  Require(RequiredCatalogComponent(Settings.AppPath,Source)='','Installed module still blocks catalogue');
  Require(GetModuleHandle(PChar(Settings.AppPath+'libzstd.dll'))=0,'Update discovery executed the DLL');
  Legacy:=Settings.AppPath+'legacy-zstd'; ForceDirectories(Legacy);
  TFile.Copy(Settings.AppPath+'libzstd.dll',TPath.Combine(Legacy,'libzstd.dll'));
  Require(InstalledComponentVersion(Legacy,'Zstandard')='1.5.7','Existing official DLL without descriptor stopped working');
  Bytes:=TFile.ReadAllBytes(TPath.Combine(Legacy,'libzstd.dll')); Bytes[High(Bytes)]:=Bytes[High(Bytes)] xor 1;
  TFile.WriteAllBytes(TPath.Combine(Legacy,'libzstd.dll'),Bytes);
  Require(ComponentNeedsRepair(Legacy,'Zstandard'),'Modified legacy DLL was accepted');
  ReaderComponents:=TfrmProgramUpdate.Create(nil);
  try
    ReaderComponents.UseReaderComponents;
    for var Item in (ReaderComponents.FindComponent('UpdateComponents') as TListView).Items do
      Require(not string(Item.Caption).Contains('Zstandard'),'Standalone reader listed catalogue decoder');
  finally ReaderComponents.Free; end;
  Writeln('PASS optional Zstandard real compact download cancel tamper install without restart preserves catalogue and pending update'); Flush(Output);
  Reader:=TMetabibReader.Create(Source);
  try
    Require((Reader.LibraryName='optional-zstd') and (Reader.ReadNext(Book)=unit_MetabibReader.mrOk) and
      (Book.BookID=101) and (Book.Title='Optional catalogue book') and (Reader.ReadNext(Book)=unit_MetabibReader.mrEof),
      'Newly installed Zstandard did not read the selected Metabib catalogue');
  finally Reader.Free; end;
  Require(UpdateSHA256(Source)=SourceHash,'Reading Metabib modified its original file');
  Require(EnsureCatalogReaderComponent(nil,Source),'Available catalogue module did not continue operation');
  Writeln('PASS optional Zstandard newly installed official decoder reads actual Metabib header book and EOF; ordinary formats remain independent'); Flush(Output);
end;
