// Optional components: all mutations are confined to the marked native runtime.
type
  TOptionalCheckWorker = class(TComponentCheckFixtureWorker)
  public Log: TStrings;
  protected
    function FetchText(const URL: string): string; override;
    function FetchHead(const URL: string): IHTTPResponse; override;
  end;
  TOptionalUpdateForm = class(TfrmProgramUpdate)
  private FHeadURL: string;
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread; override;
  public
    Requests: TStringList;
    DownloadID: string;
    constructor CreateForHead(const URL: string);
    destructor Destroy; override;
  end;
  TOptionalMirrorWorker = class(TComponentUpdateThread)
  protected function FetchText(const URL: string): string; override;
  public ReleaseJSON, FeedJSON: string;
  end;

function TOptionalCheckWorker.FetchText(const URL: string): string;
begin Log.Add(URL); Result:=inherited; end;
function TOptionalCheckWorker.FetchHead(const URL: string): IHTTPResponse;
begin Log.Add(URL); Result:=inherited; end;
constructor TOptionalUpdateForm.CreateForHead(const URL: string);
begin inherited Create(nil); FHeadURL:=URL; Requests:=TStringList.Create; end;
destructor TOptionalUpdateForm.Destroy;
begin inherited; Requests.Free; end;
function TOptionalUpdateForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
var Worker: TOptionalCheckWorker;
begin
  Worker:=TOptionalCheckWorker.Create(Window,FHeadURL,''); Worker.Log:=Requests; Result:=Worker;
end;
function TOptionalUpdateForm.CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin DownloadID:=Info.ComponentID; raise Exception.Create('OWN_OPTIONAL_DOWNLOAD_OBSERVED'); end;
function TOptionalMirrorWorker.FetchText(const URL: string): string;
begin
  if URL=PROGRAM_RELEASES_API then Exit(ReleaseJSON);
  if URL='https://github.com/Dicur3x/MyHomeLib/releases/download/'+PROGRAM_RELEASE_VERSION+'/'+COMPONENT_FEED_NAME then Exit(FeedJSON);
  if URL='https://www.alreader.com/' then Exit('<html>No Windows release available</html>');
  raise Exception.Create('Optional mirror fixture refused route: '+URL);
end;

procedure TestOptionalPackageInstallation;
var Feed: TJSONValue; Entries: TJSONArray; Entry: TJSONValue;
  Folder, Target, Archive, ID, Version, Job, Name, First, BeforeHash, PrivateFile, Profile: string;
  Files: TUpdateFiles; Refused: Boolean; InstalledHashes: TStringList;
begin
  RequireIsolatedRegression;
  Folder:=TPath.Combine(Settings.AppPath,'optional-packages');
  InstalledHashes:=TStringList.Create;
  Feed:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8));
  Target:=TPath.Combine(Settings.AppPath,'optional-install-target'); ForceDirectories(Target);
  PrivateFile:=TPath.Combine(Target,'Data\private-book.txt'); ForceDirectories(ExtractFileDir(PrivateFile));
  TFile.WriteAllText(PrivateFile,'Personal book bytes remain private and unchanged');
  TFile.WriteAllText(TPath.Combine(Target,'HomeLibRu.exe'),'Owned installer target marker, never executed');
  Profile:=TPath.Combine(Target,'Readers\AlReader\$savevtut.ini'); ForceDirectories(ExtractFileDir(Profile));
  TFile.WriteAllText(Profile,'existing local reader configuration');
  try
    Require((Feed is TJSONObject) and Feed.TryGetValue<TJSONArray>('components',Entries),'Missing actual package feed');
    for ID in TArray<string>.Create('AlReader','SumatraPDF','DjVuLibre','DocSharp') do
    begin
      Version:='';
      for Entry in Entries do
        if (Entry.GetValue<string>('id')=ID) and (Entry.GetValue<string>('platform')=ProgramUpdatePlatform) then
          Version:=Entry.GetValue<string>('version');
      Require(Version<>'','Generated package feed omitted '+ID);
      Archive:=TPath.Combine(Folder,ComponentArchiveName(ID,ProgramUpdatePlatform));
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
      try
        Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,Job,True,ID,Version);
        Require(Length(Files)>0,'Optional package has no files');
        First:=TPath.Combine(Target,StringReplace(Files[0].Name,'/',PathDelim,[rfReplaceAll]));
        ForceDirectories(ExtractFileDir(First)); TFile.WriteAllText(First,'Previous owned fixture component');
        BeforeHash:=UpdateSHA256(First); Refused:=False;
        try InstallProgramUpdate(Job,Target,nil,1); except on E: Exception do Refused:=E.Message='Имитированная ошибка установки'; end;
        Require(Refused and (UpdateSHA256(First)=BeforeHash),'Failed optional installation did not restore its original bytes');
      finally CleanProgramUpdate(Job); end;
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
      try
        Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,Job,True,ID,Version);
        InstallProgramUpdate(Job,Target);
        InstalledHashes.Values[ComponentFileName(ID)]:=UpdateSHA256(TPath.Combine(Target,StringReplace(ComponentFileName(ID),'/',PathDelim,[rfReplaceAll])));
        Require(not ComponentNeedsRepair(Target,ID),'Optional archive did not supply a complete '+ID+' installation');
        for var FileInfo in Files do
          if FileInfo.Name<>'Readers/AlReader/$savevtut.ini' then
          begin
            Name:=TPath.Combine(Target,StringReplace(FileInfo.Name,'/',PathDelim,[rfReplaceAll]));
            Require(UpdateSHA256(Name)=FileInfo.SHA256,'Installed optional component bytes differ from manifest');
          end;
        Require(TFile.ReadAllText(PrivateFile)='Personal book bytes remain private and unchanged','Optional installation changed a personal book');
        Require(TFile.ReadAllText(Profile)='existing local reader configuration','Optional installation replaced reader settings');
      finally CleanProgramUpdate(Job); end;
    end;
    Archive:=TPath.Combine(Folder,'minimal.zip');
    if FileExists(Archive) then
    begin
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
      try
        Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,Job);
        for ID in TArray<string>.Create('AlReader','SumatraPDF','DjVuLibre','DocSharp') do
          Require(not FileExists(TPath.Combine(Job,'payload\'+StringReplace(ComponentFileName(ID),'/',PathDelim,[rfReplaceAll]))),
            'Minimal distribution bundled an optional third-party component');
        InstallProgramUpdate(Job,Target);
        for var I:=0 to InstalledHashes.Count-1 do
        begin
          Name:=TPath.Combine(Target,StringReplace(InstalledHashes.Names[I],'/',PathDelim,[rfReplaceAll]));
          Require(UpdateSHA256(Name)=InstalledHashes.ValueFromIndex[I],'Minimal application update changed an installed optional component');
        end;
        Require(not ComponentNeedsRepair(Target,'7-Zip') and not ComponentNeedsRepair(Target,'SQLite'),'Minimal update omitted mandatory runtime files');
        Require(TFile.ReadAllText(PrivateFile)='Personal book bytes remain private and unchanged','Minimal application update changed a personal book');
        Require(TFile.ReadAllText(Profile)='existing local reader configuration','Minimal application update changed reader settings');
        Writeln('PASS minimal application archive verifies, installs mandatory runtime and preserves all four optional components and personal files');
      finally CleanProgramUpdate(Job); end;
    end;
    Writeln('PASS optional packages verify actual binary identities and hashes, install all four components, roll back injected failures and preserve personal files');
  finally Feed.Free; InstalledHashes.Free; end;
end;

procedure TestOptionalComponentWorkflow;
var Saved, EmptyRoot, DocFolder, HeldDoc, Source, Hash, Missing, ExpectedArchive, FeedURL: string;
  Dialog: TOptionalUpdateForm; Quiet: TfrmProgramUpdate; Server: TUpdateProposalServer;
  Worker: TOptionalMirrorWorker; Current: TProgramRelease; Releases: TComponentReleases;
  Status: TLabel; Notify: TCheckBox; Primary: TButton; View: TListView;
  Notes: TUpdateNotesView; OriginalTheme: Boolean;
  Reloaded: TMHLSettings; Host: TComponent; Book: TBookRecord; Bytes: TBytes;
  Ready, Observed, WasMoved: Boolean; Started: UInt64;
  procedure WaitCheck;
  begin
    Started:=GetTickCount64;
    while not (Dialog.FindComponent('UpdateCheckComponents') as TButton).Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<10000,'Targeted component check did not finish');
    end;
    Application.ProcessMessages;
  end;
  procedure SupplyOptionalUpdates;
  begin
    Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
    Current.DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+PROGRAM_RELEASE_VERSION+'/HomeLibRu.zip';
    Current.SHA256:=StringOfChar('a',64); Current.Size:=128;
    Require(Quiet.StartCheckCycle(True),'Cannot start quiet optional fixture');
    Quiet.ApplicationChecked(Current,True,''); Releases:=Default(TComponentReleases);
    for var I in CheckedComponentIndices do
      if IsOptionalComponent(ComponentIDs[I]) then
      begin
        Releases[I].ComponentID:=ComponentIDs[I]; Releases[I].ComponentVersion:='99.0'; Releases[I].Tag:='99.0';
        Releases[I].DownloadURL:='https://example.invalid/not-downloaded.zip'; Releases[I].Size:=128;
      end;
    Quiet.ComponentsReceived(Releases,True,'');
  end;
begin
  RequireIsolatedRegression;
  TestOptionalPackageInstallation;
  Saved:=Settings.OptionalComponentUpdates; Settings.OptionalComponentUpdates:='';
  Server:=nil; Dialog:=nil; Quiet:=nil; Host:=nil; WasMoved:=False;
  EmptyRoot:=TPath.Combine(Settings.AppPath,'optional-empty'); ForceDirectories(EmptyRoot);
  try
    for var ID in TArray<string>.Create('AlReader','SumatraPDF','DjVuLibre','DocSharp') do
      Require(not ComponentNotificationEnabled(ID,''),'Optional notifications enabled by default');
    Require(ComponentNotificationEnabled('SQLite','') and ComponentNotificationEnabled('7-Zip',''),
      'Core component updates disabled by optional policy');
    for var Ext in TArray<string>.Create('.fb2','.epub','.txt','.docx','.pptx','.xlsx') do
      Require(RequiredReaderComponent(EmptyRoot,Ext)='','Unrelated/modern format requested a legacy decoder');
    Require((RequiredReaderComponent(EmptyRoot,'.DJVU')='DjVuLibre') and
      (RequiredReaderComponent(EmptyRoot,'.doc')='DocSharp') and
      (RequiredReaderComponent(EmptyRoot,'.xls')='DocSharp'),'Missing format requirements were not recognized');
    Settings.OptionalComponentUpdates:=SetComponentNotification('SumatraPDF','',True); Settings.SaveSettings;
    Reloaded:=TMHLSettings.Create;
    try Reloaded.LoadSettings;
      Require(ComponentNotificationEnabled('SumatraPDF',Reloaded.OptionalComponentUpdates) and
        not ComponentNotificationEnabled('AlReader',Reloaded.OptionalComponentUpdates),'Explicit notification choice lost after reload');
    finally Reloaded.Free; end;
    Settings.OptionalComponentUpdates:='';
    Quiet:=TfrmProgramUpdate.Create(nil); SupplyOptionalUpdates;
    Require(not Quiet.Visible,'Unused optional component updates opened an automatic popup');
    Quiet.Free; Quiet:=nil;

    Server:=TUpdateProposalServer.Create; Dialog:=TOptionalUpdateForm.CreateForHead(Server.HeadURL);
    Require(Dialog.StartCheckCycle(True),'Cannot start filtered automatic check');
    Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
    Dialog.ApplicationChecked(Current,True,''); Dialog.CheckComponents(True); WaitCheck;
    Require((Dialog.Requests.Count>0) and not Dialog.Requests.Text.Contains('alreader') and
      not Dialog.Requests.Text.Contains('sumatrapdf') and not Dialog.Requests.Text.Contains('sourceforge') and
      not Dialog.Requests.Text.Contains('docsharp'),'Automatic transport checked an unused optional component');
    Dialog.Free; Dialog:=nil;
    Writeln('PASS optional updates are opt-in, persist independently, stay quiet and skip unused component network requests');

    DocFolder:=TPath.GetFullPath(TPath.Combine(Settings.AppPath,'tools/doc'));
    HeldDoc:=TPath.GetFullPath(TPath.Combine(Settings.AppPath,'tools/doc-held-'+TGUID.NewGuid.ToString));
    Require(DocFolder.StartsWith(TPath.GetFullPath(Settings.AppPath),True) and
      HeldDoc.StartsWith(TPath.GetFullPath(Settings.AppPath),True),'Optional decoder fixture escaped its marked runtime');
    TDirectory.Move(DocFolder,HeldDoc); WasMoved:=True;
    Quiet:=TfrmProgramUpdate.Create(nil); SupplyOptionalUpdates;
    Require(not Quiet.Visible,'Intentionally absent optional decoder triggered a full application repair');
    Quiet.Free; Quiet:=nil;
    Host:=TComponent.Create(nil); Ready:=False; Missing:='';
    Source:=TPath.Combine(Settings.AppPath,'needs-optional.doc'); SetLength(Bytes,512);
    Bytes[0]:=$D0; Bytes[1]:=$CF; Bytes[2]:=$11; Bytes[3]:=$E0; Bytes[4]:=$A1; Bytes[5]:=$B1; Bytes[6]:=$1A; Bytes[7]:=$E1;
    TFile.WriteAllBytes(Source,Bytes); Hash:=THashSHA2.GetHashStringFromFile(Source);
    Book:=Default(TBookRecord); Book.nodeType:=ntBookInfo; Book.CollectionRoot:=Settings.AppPath;
    Book.FileName:='needs-optional'; Book.FileExt:='.doc'; Book.BookProps:=[bpIsLocal]; Book.Size:=512; Book.LibID:='optional-doc';
    Book.BookKey:=CreateBookKey(987654,Settings.ActiveCollection);
    PrepareReaderFileInBackground(Host,Book,True,
      procedure(Name: string) begin Ready:=True; end,False,False,True,
      procedure(ID: string)
      begin
        Require(GetCurrentThreadID=MainThreadID,'Missing component callback ran inside decoder worker');
        Require(not ReaderPreparationsPending(Host),'Decoder worker survived the first-use callback'); Missing:=ID;
      end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(Host) do
    begin Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<10000,'Missing decoder preparation remained pending'); end;
    Require(not Ready and (Missing='DocSharp') and (THashSHA2.GetHashStringFromFile(Source)=Hash),
      'Missing decoder did not return through the safe first-use path or changed its source');
    FreeAndNil(Host);
    Dialog:=TOptionalUpdateForm.CreateForHead(Server.HeadURL);
    Dialog.RequestComponent('DocSharp','Для чтения этой книги нужна библиотека DocSharp.'); WaitCheck;
    Status:=Dialog.FindComponent('UpdateStatus') as TLabel;
    Primary:=Dialog.FindComponent('UpdatePrimary') as TButton;
    Notify:=Dialog.FindComponent('NotifyOptionalComponent') as TCheckBox;
    View:=Dialog.FindComponent('UpdateComponents') as TListView;
    Require(Assigned(View.Selected),'Requested component row is not selected');
    Require(Dialog.Visible and (View.Selected.Index=6) and not Notify.Checked and
      string(Status.Caption).Contains('МБ') and string(Status.Caption).Contains('DocSharp') and
      (Primary.Caption='Скачать компонент') and (Dialog.DownloadID=''),
      'First-use dialog omitted the component/size/choice or started downloading without a click');
    Notes:=Dialog.FindComponent('UpdateNotes') as TUpdateNotesView;
    if not Assigned(Notes) then for var Component in Dialog do if Component is TUpdateNotesView then Notes:=TUpdateNotesView(Component);
    Require(Assigned(Notes),'Optional dialog notes control absent');
    OriginalTheme:=MHLThemeDark;
    try
      for var Dark in [False,True] do
        for var PPI in [96,144,192] do
        begin
          SetMHLTheme(Dark); Dialog.ScaleForPPI(PPI);
          Dialog.ClientWidth:=MulDiv(760,PPI,96); Dialog.ClientHeight:=MulDiv(580,PPI,96); Application.ProcessMessages;
          Require(Notify.Visible and (Notify.Top>=Status.Top+Status.Height) and
            (Notes.Top>=Notify.Top+Notify.Height) and (Notes.Top+Notes.Height<=Primary.Top) and
            (Notify.Width>=Dialog.Canvas.TextWidth(Notify.Caption)+MulDiv(24,PPI,96)),
            'Optional notification choice overlaps text, changelog or primary action');
        end;
    finally SetMHLTheme(OriginalTheme); Dialog.ScaleForPPI(96); end;
    SendMessage(Notify.Handle,BM_CLICK,0,0);
    Require(ComponentNotificationEnabled('DocSharp',Settings.OptionalComponentUpdates),'Actual checkbox did not opt in to this component');
    SendMessage(Notify.Handle,BM_CLICK,0,0);
    Require(not ComponentNotificationEnabled('DocSharp',Settings.OptionalComponentUpdates),'Actual checkbox did not turn notifications back off');
    Require(not Dialog.Requests.Text.Contains('sqlite.org') and not Dialog.Requests.Text.Contains('alreader') and
      not Dialog.Requests.Text.Contains('sourceforge') and not Dialog.Requests.Text.Contains('sumatrapdf'),
      'First-use check fetched unrelated components');
    Observed:=False;
    try Primary.Click; except on E: Exception do Observed:=E.Message='OWN_OPTIONAL_DOWNLOAD_OBSERVED'; end;
    Require(Observed and (Dialog.DownloadID='DocSharp'),'Explicit first-use action queued another component');
    Dialog.Free; Dialog:=nil;
    Writeln('PASS first-use decoder request releases its worker, preserves source bytes, shows size and downloads only after an explicit click');

    ExpectedArchive:=ComponentArchiveName('AlReader',ProgramUpdatePlatform);
    FeedURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+PROGRAM_RELEASE_VERSION+'/'+COMPONENT_FEED_NAME;
    for var Foreign in [False,True] do
    begin
      Worker:=TOptionalMirrorWorker.Create(0,CreateComponentFixtureHTTP);
      try
        Worker.OnlyIDs:=TArray<string>.Create('AlReader');
        Worker.FeedJSON:=TFile.ReadAllText(Settings.AppPath+'COMPONENTS.json',TEncoding.UTF8);
        Worker.ReleaseJSON:='[{"tag_name":"'+PROGRAM_RELEASE_VERSION+'","draft":false,"assets":['+
          '{"name":"'+COMPONENT_FEED_NAME+'","browser_download_url":"'+FeedURL+'","size":100},'+
          '{"name":"'+ExpectedArchive+'","browser_download_url":"'+
          IfThen(Foreign,'https://example.invalid/','https://github.com/Dicur3x/MyHomeLib/releases/download/'+PROGRAM_RELEASE_VERSION+'/')+
          ExpectedArchive+'","digest":"sha256:'+StringOfChar('a',64)+'","size":128}]}]';
        Worker.Start; Worker.WaitFor;
        Require(Worker.Successful,'Published optional package check did not finish');
        Require((Worker.Releases[1].DownloadURL<>'')<>Foreign,'AlReader mirror accepted a foreign URL or lost a verified asset');
        if not Foreign then Require(Worker.Releases[1].SHA256=StringOfChar('a',64),
          'AlReader archive checksum did not come from the verified GitHub asset');
      finally Worker.Free; end;
    end;
    Writeln('PASS optional AlReader mirror uses matching GitHub assets and rejects a foreign archive URL');
  finally
    Host.Free; Dialog.Free; Quiet.Free; Server.Free;
    if WasMoved then TDirectory.Move(HeldDoc,DocFolder);
    Settings.OptionalComponentUpdates:=Saved; Settings.SaveSettings;
  end;
end;
