// Independent completion, first-use archives and the fixed reader source.
type
  TF531Worker = class(TComponentCheckFixtureWorker)
  public Gate, Entered: TEvent;
  protected function FetchText(const URL: string): string; override;
  end;
  TF531Form = class(TfrmProgramUpdate)
  private Head: string;
  protected function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease; const Job: string): TProgramDownloadThread; override;
  public WorkersCreated: Integer; DownloadObserved: Boolean; Gate, Entered: TEvent;
    constructor CreateTest(const URL: string);
    destructor Destroy; override;
  end;

function TF531Worker.FetchText(const URL: string): string;
begin
  if URL.Contains('sqlite.org/') then
  begin
    Entered.SetEvent;
    while Gate.WaitFor(20)<>wrSignaled do if Terminated then Abort;
  end;
  Result:=inherited;
end;
constructor TF531Form.CreateTest(const URL: string);
begin
  Head:=URL; Gate:=TEvent.Create(nil,True,False,''); Entered:=TEvent.Create(nil,True,False,'');
  inherited Create(nil);
end;
destructor TF531Form.Destroy;
begin inherited; Entered.Free; Gate.Free; end;
function TF531Form.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
var W: TF531Worker;
begin Inc(WorkersCreated); W:=TF531Worker.Create(Window,Head,''); W.Gate:=Gate; W.Entered:=Entered; Result:=W; end;

function TF531Form.CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease; const Job: string): TProgramDownloadThread;
begin
  DownloadObserved:=ReleaseInfo.ComponentID='7-Zip';
  raise Exception.Create('F531_DOWNLOAD_OBSERVED');
end;

procedure TestMetadataFirstUse531;
var CID: Integer; Collection: IBookCollection; Book: TBookRecord;
  Plan: TCollectionMetadataPlan; Counts: TMetadataSyncCounts;
  Preview: TMetadataPreviewThread; Indexer: TIndexPublisherSeriesThread;
  Form: TfrmBookMetadataFill; BeforeHash: string; Rejected: Boolean; Started: UInt64;
  procedure WaitForWorker(Worker: TWorker);
  var Began: UInt64;
  begin
    Began:=GetTickCount64;
    while not Worker.Finished do
    begin Application.ProcessMessages; CheckSynchronize(1); Sleep(5);
      Require(GetTickCount64-Began<10000,'Missing decoder left its metadata worker running'); end;
    Worker.WaitFor;
  end;
begin
  CID:=SystemDB.CreateCollection('Metadata dependency',Settings.AppPath,'metadata-sevenzip.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=1 to 16 do
  begin
    Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Book.CollectionRoot:=Settings.AppPath;
    Book.Title:='Dependency '+IntToStr(I); Book.FileName:='book-'+IntToStr(I); Book.FileExt:='.fb2';
    Book.Folder:='needs-sevenzip.7z'; Book.LibID:='dependency-'+IntToStr(I); Book.Size:=100;
    Book.BookProps:=[bpIsLocal]; Collection.InsertBook(Book,False,False);
  end;
  BeforeHash:=UpdateSHA256(Settings.AppPath+'needs-sevenzip.7z'); Plan:=nil; Rejected:=False;
  try
    try Plan:=PreviewCollectionMetadata(Collection,[msfPublisher],Counts);
    except on E: EMHLComponentRequired do Rejected:=E.ComponentID='7-Zip'; end;
    Require(Rejected and not Assigned(Plan),'Metadata scan turned a missing decoder into repeated book errors');
  finally Plan.Free; end;
  Preview:=TMetadataPreviewThread.Create(CID,[msfPublisher]);
  try
    Preview.Start; WaitForWorker(Preview);
    Require((Preview.FatalException is EMHLComponentRequired) and not Preview.Completed,
      'Metadata preview lost its typed dependency while joining child readers');
  finally Preview.Free; end;
  Indexer:=TIndexPublisherSeriesThread.Create(CID,True);
  try
    Indexer.Start; WaitForWorker(Indexer);
    Require((Indexer.FatalException is EMHLComponentRequired) and (Indexer.FailedCount=0),
      'Publisher-series scan continued reporting every book as damaged');
  finally Indexer.Free; end;
  Form:=TfrmBookMetadataFill.CreateForCollection(Application,CID);
  try
    Form.Show; TButton(Form.FindComponent('btnMetadataPreview')).Click; Started:=GetTickCount64;
    while Form.Busy do
    begin Application.ProcessMessages; CheckSynchronize(1); Sleep(5);
      Require(GetTickCount64-Started<10000,'Metadata dialog did not release its missing decoder worker'); end;
    Require((Form.RequiredComponent='7-Zip') and not Form.Visible,
      'Metadata dialog did not close before handing its dependency back to the caller');
  finally Form.Free; end;
  Collection.GetBookRecord(CreateBookKey(1,CID),Book,True);
  Require((Book.Title='Dependency 1') and (Book.Publisher='') and
    (UpdateSHA256(Settings.AppPath+'needs-sevenzip.7z')=BeforeHash),
    'Missing metadata component changed the catalogue or source archive');
  Writeln('PASS post530 metadata dependency stops readers and indexing once and releases the modal scan before first-use handoff');
end;

procedure TestFirstUseSevenZip531;
var SavedPath, SavedPF, SavedPF32, Tools, Held, Source, Hash, Missing: string;
  Host: TComponent; Book: TBookRecord; Ready: Boolean; Started: UInt64;
  Archive: TMHLZip; Zip: TZipFile; Input, Output: TMemoryStream;
begin
  RequireIsolatedRegression;
  Tools:=TPath.Combine(Settings.AppPath,'tools/7zip'); Held:=Tools+'-held-531';
  Require(not DirectoryExists(Held),'Dependency fixture would replace an existing directory');
  SavedPath:=GetEnvironmentVariable('PATH'); SavedPF:=GetEnvironmentVariable('ProgramFiles');
  SavedPF32:=GetEnvironmentVariable('ProgramFiles(x86)');
  Source:=TPath.Combine(Settings.AppPath,'needs-sevenzip.7z'); TFile.WriteAllText(Source,'Owned archive requiring a decoder');
  Hash:=UpdateSHA256(Source); Host:=nil;
  TDirectory.Move(Tools,Held);
  try
    // Process-local environment only: no installed tool or user setting is changed.
    SetEnvironmentVariable('PATH',''); SetEnvironmentVariable('ProgramFiles',''); SetEnvironmentVariable('ProgramFiles(x86)','');
    Require(FindExternalTool('7z.exe','7zip')='','Dependency fixture unexpectedly found an installed extractor');
    Zip:=TZipFile.Create; Input:=TMemoryStream.Create;
    try
      var Bytes:=TEncoding.UTF8.GetBytes('ordinary zip stays native'); Input.WriteBuffer(Bytes[0],Length(Bytes)); Input.Position:=0;
      Zip.Open(Settings.AppPath+'ordinary-531.zip',zmWrite); Zip.Add(Input,'book.txt'); Zip.Close;
    finally Input.Free; Zip.Free; end;
    Archive:=TMHLZip.Create(Settings.AppPath+'ordinary-531.zip',True);
    try Output:=Archive.ExtractToStream(0);
      try Require(Output.Size=25,'Ordinary ZIP started requiring 7-Zip'); finally Output.Free; end;
    finally Archive.Free; end;
    Host:=TComponent.Create(nil); Ready:=False; Missing:='';
    Book:=Default(TBookRecord); Book.nodeType:=ntBookInfo; Book.CollectionRoot:=Settings.AppPath;
    Book.FileName:='needs-sevenzip'; Book.FileExt:='.7z'; Book.BookProps:=[bpIsLocal]; Book.Size:=TFile.GetSize(Source);
    Book.LibID:='sevenzip-first-use'; Book.BookKey:=CreateBookKey(987653,Settings.ActiveCollection);
    PrepareReaderFileInBackground(Host,Book,True,
      procedure(Name: string) begin Ready:=True; end,False,False,True,
      procedure(ID: string)
      begin
        Require(GetCurrentThreadID=MainThreadID,'7-Zip prompt ran inside the archive worker');
        Require(not ReaderPreparationsPending(Host),'7-Zip prompt retained its archive worker'); Missing:=ID;
      end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(Host) do
    begin Application.ProcessMessages; CheckSynchronize(1); Sleep(5); Require(GetTickCount64-Started<5000,'Missing 7-Zip preparation did not finish'); end;
    Require(not Ready and (Missing='7-Zip') and (UpdateSHA256(Source)=Hash),'Archive first use did not ask for 7-Zip or changed the source');
    Host.Free; Host:=TComponent.Create(nil); Ready:=False; Missing:='';
    TFile.WriteAllText(Settings.AppPath+'inner-decoder-531.txt','Ordinary prepared text');
    Book.FileName:='inner-decoder-531'; Book.FileExt:='.txt'; Book.LibID:='inner-decoder-first-use';
    PrepareReaderFileInBackground(Host,Book,True,
      procedure(Name: string)
      begin Ready:=True; raise EMHLComponentRequired.Create('7-Zip','Owned late decoder fixture'); end,
      False,False,False,procedure(ID: string) begin Missing:=ID; end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(Host) do
    begin Application.ProcessMessages; CheckSynchronize(1); Sleep(5); Require(GetTickCount64-Started<5000,'Late decoder preparation remained pending'); end;
    Require(Ready and (Missing='7-Zip'),'Reader construction lost the first-use decoder prompt');
    TestMetadataFirstUse531;

  finally
    Host.Free;
    SetEnvironmentVariable('PATH',PChar(SavedPath)); SetEnvironmentVariable('ProgramFiles',PChar(SavedPF));
    SetEnvironmentVariable('ProgramFiles(x86)',PChar(SavedPF32)); TDirectory.Move(Held,Tools);
  end;
  Writeln('PASS post530 native ZIP stays independent and missing 7-Zip reaches the first-use UI callback');
end;

procedure TestFeedback531;
var Server: TUpdateProposalServer; Form: TF531Form; View: TListView;
  Primary, Check: TButton; Started: UInt64; Info: TProgramRelease;
  Fixture, Empty, Target, Job: string; Root: TJSONValue; Downloader: TRepairWorker;
  DownloadServer: TRepairServer; Files: TUpdateFiles;
begin
  RequireIsolatedRegression;
  Server:=TUpdateProposalServer.Create; Form:=TF531Form.CreateTest(Server.HeadURL);
  try
    Require(Form.StartCheckCycle(False),'Cannot start independent completion check');
    Info:=Default(TProgramRelease); Info.Tag:=PROGRAM_RELEASE_VERSION; Form.ApplicationChecked(Info,True,'');
    Form.CheckComponents(False); Form.Show;
    Require(Form.Entered.WaitFor(3000)=wrSignaled,'Slow component fixture did not start');
    View:=Form.FindComponent('UpdateComponents') as TListView;
    Started:=GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(1); Sleep(5);
      Require(GetTickCount64-Started<5000,'Ready component remained blocked by a slow site');
    until (View.Items[5].SubItems[2]<>'Проверяется…') and (View.Items[5].SubItems[1]<>'—');
    Require(View.Items[1].SubItems[2]='Проверяется…','Paused component lost its individual waiting state');
    View.Items[5].Selected:=True; View.Items[5].Focused:=True; Application.ProcessMessages;
    Primary:=Form.FindComponent('UpdatePrimary') as TButton;
    Require(Primary.Enabled and string(Primary.Caption).Contains('Скачать'),'Ready optional archive is not actionable while another site is pending');
    Form.RequestComponent('7-Zip','Owned request during a pending check');
    Check:=Form.FindComponent('UpdateCheckComponents') as TButton;
    var Observed:=False;
    try Primary.Click; except on E: Exception do Observed:=E.Message='F531_DOWNLOAD_OBSERVED'; end;
    Require(Observed and Form.DownloadObserved,'Ready component action still waits for the complete check cycle');
    Form.Gate.SetEvent; Started:=GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(1); Sleep(5);
      Require(GetTickCount64-Started<10000,'Component coordinator did not finish');
    until Check.Enabled;
    Require(Form.WorkersCreated=1,'Explicit ready download restarted its queued component check');
    Writeln('PASS post530 component results and actions arrive independently of a slow source');
  finally Form.Free; Server.Free; end;
  Server:=TUpdateProposalServer.Create; Form:=TF531Form.CreateTest(Server.HeadURL);
  try
    Form.CheckComponents(False); Require(Form.Entered.WaitFor(3000)=wrSignaled,'Close fixture did not start');
    Started:=GetTickCount64; Form.Free; Form:=nil;
    Require(GetTickCount64-Started<3000,'Closing component checks left a child worker pending');
  finally Form.Free; Server.Free; end;
  Writeln('PASS post530 close joins parallel component probes without stale delivery');

  Fixture:=TPath.Combine(Settings.AppPath,'post530-fixtures'); Empty:=TPath.Combine(Settings.AppPath,'post530-empty'); ForceDirectories(Empty);
  Info:=FixedAlReaderRelease;
  Require((Info.Size=ALREADER_FIXED_SIZE) and not Info.OfficialComponent and not Info.CheckOnly and
    SameText(Info.SHA256,UpdateSHA256(TPath.Combine(Fixture,ALREADER_FIXED_NAME))), 'Fixed AlReader bytes or source identity changed');
  for var Arch in ['Win32','Win64'] do
  begin
    Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-alreader-'+Arch); ForceDirectories(Job);
    try
      Files:=PrepareProgramUpdate(TPath.Combine(Fixture,ALREADER_FIXED_NAME),Info.SHA256,Info.Tag,Arch,Job,True,'AlReader',Info.ComponentVersion);
      VerifyPreparedProgramUpdate(Job,Info.Tag,Arch);
      Require(Length(Files)=15,'Fixed AlReader archive has unexpected files');
    finally CleanProgramUpdate(Job); end;
  end;
  Writeln('PASS post530 one pinned AlReader archive verifies for both host architectures');

  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Fixture,'sevenzip.json'),TEncoding.UTF8));
  try Require(ParseRasterComponent(Root.ToJSON,'7-Zip',Info),'Cannot parse official 26.05 metadata'); finally Root.Free; end;
  Require((Info.ComponentVersion='26.05') and (Info.SecondaryURL<>'') and IsUpdateSHA256(Info.SecondarySHA256), '26.05 bootstrap was not authenticated');
  Require(IsOptionalComponent('7-Zip') and not ComponentNotificationEnabled('7-Zip',''), 'Absent 7-Zip triggers mandatory update notifications');
  DownloadServer:=TRepairServer.Create;
  try
    DownloadServer.URLs.Add(Info.DownloadURL); DownloadServer.Files.Add(TPath.Combine(Fixture,'sevenzip.exe'));
    DownloadServer.URLs.Add(Info.SecondaryURL); DownloadServer.Files.Add(TPath.Combine(Fixture,'7zr.exe'));
    for var Corrupt in [True,False] do
    begin
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-sevenzip-'+IntToStr(Ord(Corrupt))); ForceDirectories(Job);
      var DownloadInfo:=Info; if Corrupt then DownloadInfo.SecondarySHA256:=StringOfChar('0',64);
      Downloader:=TRepairWorker.Create(0,DownloadInfo,Job,DownloadServer); Downloader.RuntimePath:=Empty;
      try
        Downloader.Start; Downloader.WaitFor;
        if Corrupt then Require(not Downloader.Successful and Downloader.ErrorText.Contains('контрольная сумма'), 'Untrusted bootstrap was executed or accepted')
        else
        begin
          Require(Downloader.Successful,'Fresh optional 7-Zip download failed: '+Downloader.ErrorText);
          VerifyPreparedProgramUpdate(Job,'26.05',ProgramUpdatePlatform);
          Target:=TPath.Combine(Settings.AppPath,'post530-installed'); ForceDirectories(Target);
          TFile.WriteAllText(TPath.Combine(Target,'HomeLibRu.exe'),'Owned target marker; never executed');
          InstallProgramUpdate(Job,Target);
          Require(not ComponentNeedsRepair(Target,'7-Zip') and
            (ComponentDisplayVersion('7-Zip',InstalledComponentVersion(Target,'7-Zip'))='26.05'), 'First install needs an unavailable old 7za or installed the wrong version');
        end;
      finally Downloader.Free; CleanProgramUpdate(Job); end;
    end;
  finally DownloadServer.Free; end;
  Writeln('PASS post530 official 7-Zip 26.05 installs without a previous unpacker and rejects a changed bootstrap');
  TestFirstUseSevenZip531;
  TestFirstBookList;
end;


procedure TestMinimalFirstInstall531;
var Fixture, MainJob, Runtime, Job, Package, PrivateFile: string;
  Index: TJSONObject; Files: TUpdateFiles; Zip: TZipFile; PrivateHash: string;
begin
  RequireIsolatedRegression;
  Fixture:=TPath.Combine(Settings.AppPath,'repair-fixtures');
  Index:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Fixture,'fixtures.json'),TEncoding.UTF8)) as TJSONObject;
  MainJob:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-minimum-531');
  try
    Files:=PrepareProgramUpdate(TPath.Combine(Fixture,'application.zip'),Index.GetValue<string>('application_sha256'),
      Index.GetValue<string>('tag'),ProgramUpdatePlatform,MainJob);
    Runtime:=TPath.Combine(MainJob,'payload');
    for var ID in ['AlReader','SumatraPDF','7-Zip','DjVuLibre','DocSharp'] do
      Require(not FileExists(TPath.Combine(Runtime,ComponentFileName(ID))), 'Minimal archive includes optional runtime: '+ID);
    Require(FileExists(TPath.Combine(Runtime,'tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dpr')),
      'Minimal DjVu bridge lost its matching source');
    PrivateFile:=TPath.Combine(TPath.Combine(Runtime,'Data'),'private-first-use.txt'); ForceDirectories(ExtractFileDir(PrivateFile));
    TFile.WriteAllText(PrivateFile,'Owned private file must survive first component installation'); PrivateHash:=UpdateSHA256(PrivateFile);
    Job:=TPath.combine(Settings.AppPath,'HomeLibRu-update-minimum-sevenzip'); ForceDirectories(Job);
    try
      PrepareOfficialComponent(TPath.Combine(Fixture,'sevenzip.zip'),Job,'7-Zip',Index.GetValue<string>('sevenzip_version'),ProgramUpdatePlatform,'',Settings.AppPath);
      InstallProgramUpdate(Job,Runtime);
      Require(not ComponentNeedsRepair(Runtime,'7-Zip'),'Portable 7-Zip is incomplete after installation');
    finally CleanProgramUpdate(Job); end;
    Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-minimum-doc'); ForceDirectories(Job);
    try
      PrepareOfficialComponent(TPath.Combine(Fixture,'doc.nupkg'),Job,'DocSharp',Index.GetValue<string>('doc_version'),ProgramUpdatePlatform,
        TPath.Combine(Fixture,'common.nupkg'),Runtime,TArray<string>.Create(TPath.Combine(Fixture,'ppt.nupkg'),TPath.Combine(Fixture,'xls.nupkg')));
      InstallProgramUpdate(Job,Runtime);
      Require(not ComponentNeedsRepair(Runtime,'DocSharp'),'First-use DocSharp is incomplete in the actual minimal archive');
    finally CleanProgramUpdate(Job); end;
    Package:=TPath.Combine(Settings.AppPath,'minimum-djvu-controlled.zip'); Zip:=TZipFile.Create;
    try
      Zip.Open(Package,zmWrite);
      for var Name in ['ddjvu.exe','djvused.exe','libdjvulibre.dll','libjpeg.dll','libtiff.dll','libz.dll','COPYING.txt'] do
        Zip.Add(TPath.Combine(Settings.AppPath,'tools/djvu/'+Name),Name);
      Zip.Close;
    finally Zip.Free; end;
    Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-minimum-djvu'); ForceDirectories(Job);
    try
      PrepareOfficialComponent(Package,Job,'DjVuLibre','3.5.29',ProgramUpdatePlatform,
        TPath.Combine(Settings.AppPath,'tools/djvu/djvulibre-3.5.29.tar.gz'),Runtime);
      InstallProgramUpdate(Job,Runtime);
      Require(not ComponentNeedsRepair(Runtime,'DjVuLibre'),'First-use DjVuLibre is incomplete in the actual minimal archive');
    finally CleanProgramUpdate(Job); end;
    Require(UpdateSHA256(PrivateFile)=PrivateHash,'First-use component installation changed a private file');
    Writeln('PASS minimal first install verifies actual archive, excludes optional binaries and installs 7-Zip DocSharp DjVuLibre with preserved private files');
  finally Index.Free; CleanProgramUpdate(MainJob); end;
end;
