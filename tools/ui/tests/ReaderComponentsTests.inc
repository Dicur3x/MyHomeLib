// Standalone reader must never offer a catalogue application update.
type
  TReaderModuleWorker = class(TComponentUpdateThread)
  public Requests: TStrings; ComponentID: string;
  protected function FetchText(const URL: string): string; override;
  end;
  TReaderModuleForm = class(TfrmProgramUpdate)
  public Requests: TStringList; DownloadID, RequestedID: string;
    constructor Create(AOwner: TComponent); override;
    constructor CreateForCatalogue(AOwner: TComponent);
    destructor Destroy; override;
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread; override;
  end;

function TReaderModuleWorker.FetchText(const URL: string): string;
var FeedURL, PackageURL, PackageName: string;
begin
  Requests.Add(URL);
  FeedURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+COMPONENT_FEED_NAME;
  PackageName:=ComponentVersionedArchiveName(ComponentID,'999.0',ProgramUpdatePlatform);
  PackageURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+PackageName;
  if URL=COMPONENT_MIRROR_API then Exit('{"draft":false,"tag_name":"'+ALREADER_FIXED_TAG+'","assets":['+
    '{"name":"'+COMPONENT_FEED_NAME+'","size":400,"browser_download_url":"'+FeedURL+'"},'+
    '{"name":"'+PackageName+'","size":128,"digest":"sha256:'+StringOfChar('a',64)+'","browser_download_url":"'+PackageURL+'"}]}');
  if URL=FeedURL then Exit('{"format":1,"components":[{"id":"'+ComponentID+'","version":"999.0","archive":"'+PackageName+'","platform":"'+
    ProgramUpdatePlatform+'","history":[{"version":"999.0","date":"2026-10-25","notes":"Owned test PDF module"}]}]}');
  raise Exception.Create('Unexpected reader module request: '+URL);
end;
constructor TReaderModuleForm.Create(AOwner: TComponent);
begin inherited; Requests:=TStringList.Create; UseReaderComponents; end;
constructor TReaderModuleForm.CreateForCatalogue(AOwner: TComponent);
begin inherited Create(AOwner); Requests:=TStringList.Create; end;
destructor TReaderModuleForm.Destroy;
begin inherited; Requests.Free; end;
function TReaderModuleForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
var Probe: TReaderModuleWorker;
begin
  Probe:=TReaderModuleWorker.Create(Window,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
  Probe.Requests:=Requests; Probe.ComponentID:=RequestedID;
  Probe.PreferReadyDjvu:=RequestedID='DjVuLibre'; Result:=Probe;
end;
function TReaderModuleForm.CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin DownloadID:=Info.ComponentID; raise Exception.Create('OWN_READER_DOWNLOAD_OBSERVED'); end;

// An FB2 catalogue offers external applications but hides absent format modules.
// Already installed modules still serve catalogue conversion and stay visible.
procedure TestCatalogueMissingReaderModules;
var Dialog: TReaderModuleForm; View: TListView; Folder, Held: string;
  HeldFolders: TStringList; HadDoc: Boolean; Started: UInt64; RequiredRow: TListItem;
  function ContainsID(const ID: string): Boolean;
  begin
    Result:=False;
    for var Item in View.Items do if Item.Caption.Contains(ID) then Exit(True);
  end;
begin
  RequireIsolatedRegression;
  Require(not FileExists(Settings.AppPath+'HomeLibReader.exe'),
    'Minimal catalogue probe unexpectedly contains the reader');
  HadDoc:=DirectoryExists(Settings.AppPath+'tools\doc');
  HeldFolders:=TStringList.Create;
  try
    // The wrapper normally stages DOC, WebP and the archive DLL. Temporarily
    // hold only those owned fixture folders to exercise the minimal FB2 case.
    for var Name in ['doc','webp','7zip'] do
    begin
      Folder:=Settings.AppPath+'tools\'+Name; Held:=Folder+'-hidden-by-fixture';
      Require(not DirectoryExists(Held),'Owned decoder hold directory already exists');
      if DirectoryExists(Folder) then
      begin TDirectory.Move(Folder,Held); HeldFolders.Add(Folder); end;
    end;
    for var Component in UPDATE_COMPONENTS do
      if IsOptionalComponent(Component.ID) then
        Require(ComponentNeedsRepair(Settings.AppPath,Component.ID),
          'Minimal catalogue fixture contains an optional component: '+Component.ID);
    Dialog:=TReaderModuleForm.CreateForCatalogue(nil);
    try
      View:=Dialog.FindComponent('UpdateComponents') as TListView;
      Require(Assigned(View),'Catalogue component list is absent');
      for var Component in UPDATE_COMPONENTS do
        if IsOptionalComponent(Component.ID) and (Component.ID<>'AlReader') and (Component.ID<>'SumatraPDF') then
          Require(not ContainsID(Component.ID),
            'FB2 catalogue displays an absent optional component: '+Component.ID);
      Require((View.Items.Count=4) and View.Items[0].Caption.Contains('HomeLibre') and
        View.Items[1].Caption.Contains('AlReader') and View.Items[2].Caption.Contains('SumatraPDF'),
        'Catalogue must offer AlReader and Sumatra immediately below HomeLibre');
      for var Row in TArray<TListItem>.Create(View.Items[1],View.Items[2]) do
        Require(Row.SubItems[0]='не установлен','Absent external reader falsely appears installed');
      Require(ContainsID('SQLite'),'Catalogue lost its mandatory database component');
      Dialog.RequestedID:='PDFium';
      Dialog.RequestComponent('PDFium','Owned catalogue conversion needs PDF support.');
      Started:=GetTickCount64; RequiredRow:=nil;
      repeat
        Application.ProcessMessages; Sleep(10);
        for var Item in View.Items do if Item.Caption.Contains('PDFium') then RequiredRow:=Item;
      until (Assigned(RequiredRow) and (RequiredRow.SubItems[1]='999.0')) or
        (GetTickCount64-Started>5000);
      Require(Assigned(RequiredRow) and RequiredRow.Selected and
        (RequiredRow.SubItems[1]='999.0') and ContainsID('SQLite'),
        'Explicit catalogue conversion request did not reveal its module');
      Require((View.Items.Count=5) and (Dialog.Requests.Count=2),
        'Catalogue first use revealed or checked unrelated hidden modules');
    finally Dialog.Free; end;
    // A reader installed for native FB2/EPUB must not expose unrelated DOC
    // or DjVu modules. This fixture is a versioned PE, never executed.
    for var Name in ['HomeLibReader.exe','HomeLibRuUpdater.exe','HomeLibReader-LICENSE.txt','libzstd.dll','NOTICE'] do
      Require(not FileExists(Settings.AppPath+Name),'Owned core marker would replace a fixture file');
    try
      TFile.Copy(ParamStr(0),Settings.AppPath+'HomeLibReader.exe');
      for var Name in ['HomeLibRuUpdater.exe','HomeLibReader-LICENSE.txt','libzstd.dll','NOTICE'] do
        TFile.WriteAllText(Settings.AppPath+Name,'Owned complete reader inventory marker; never executed');
      Require(not ComponentNeedsRepair(Settings.AppPath,'HomeLibReader'),
        'Owned reader inventory fixture is incomplete');
      Dialog:=TReaderModuleForm.CreateForCatalogue(nil);
      try
        View:=Dialog.FindComponent('UpdateComponents') as TListView;
        Require(ContainsID('HomeLibReader') and (View.Items.Count=5),
          'Installing native FB2 reader exposed unrelated optional modules');
      finally Dialog.Free; end;
    finally
      for var Name in ['HomeLibReader.exe','HomeLibRuUpdater.exe','HomeLibReader-LICENSE.txt','libzstd.dll','NOTICE'] do
        if FileExists(Settings.AppPath+Name) then TFile.Delete(Settings.AppPath+Name);
    end;
  finally
    try
      for var Index:=HeldFolders.Count-1 downto 0 do
        TDirectory.Move(HeldFolders[Index]+'-hidden-by-fixture',HeldFolders[Index]);
    finally HeldFolders.Free; end;
  end;
  // Installed DOC support may be needed for conversion with no reader present.
  if HadDoc then
  begin
    Require(not ComponentNeedsRepair(Settings.AppPath,'DocSharp'),'Owned DOC fixture was not restored');
    Dialog:=TReaderModuleForm.CreateForCatalogue(nil);
    try
      View:=Dialog.FindComponent('UpdateComponents') as TListView;
      Require(ContainsID('DocSharp'),'Installed catalogue conversion module was hidden');
      Require(not ContainsID('DjVuLibre'),'Restoring DOC revealed an unrelated absent module');
    finally Dialog.Free; end;
  end;
  Writeln('PASS catalogue FB2 baseline offers external readers first hides absent format modules and keeps installed conversion modules');
end;

procedure TestReaderComponents;
var Dialog: TReaderModuleForm; View: TListView; Primary: TButton; History: TComboBox;
  EmptyRoot, LegacyFile: string; Started: UInt64; PDFRow: TListItem; Missing: string;
  PreparationOwner: TComponent;
begin
  RequireIsolatedRegression;
  TestCatalogueMissingReaderModules;
  for var Pair in ['Readers\AlReader\AlReader2.exe=AlReader','AlReader\AlReader2.exe=AlReader',
    'Readers\SumatraPDF\SumatraPDF.exe=SumatraPDF'] do
    Require(MissingExternalReaderComponent(Settings.AppPath,Pair.Split(['='])[0])=Pair.Split(['='])[1],
      'Missing bundled external reader lost its first-use installation: '+Pair);
  Require((MissingExternalReaderComponent(Settings.AppPath,'')='') and
    (MissingExternalReaderComponent(Settings.AppPath,'Custom\AlReader2.exe')='') and
    (MissingExternalReaderComponent(Settings.AppPath,ParamStr(0))=''),
    'External install request replaced an existing custom reader or Windows association');
  // The lightweight native adapters must survive a standalone core install,
  // while optional third-party engines cannot leak into that package.
  for var Name in TArray<string>.Create(
    'tools/doc/HomeLibDoc.exe',
    'tools/doc/HomeLibDoc-MIT.txt',
    'tools/doc/DocSharp-MIT.txt',
    'tools/doc/b2xtranslator-BSD-3-Clause.txt',
    'tools/djvu/HomeLibDjvu.exe',
    'tools/djvu/COPYING.txt',
    'tools/djvu/COPYRIGHT',
    'tools/djvu/IJG-README.txt',
    'tools/djvu/LIBTIFF-COPYRIGHT.txt',
    'tools/djvu/ZLIB-README.txt',
    'tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dpr',
    'tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dproj',
    'tools/djvu/HomeLibDjvu-source/LICENSE',
    'tools/djvu/HomeLibDjvu-source/README.md',
    'tools/djvu/HomeLibDjvu-source/unit_DjvuProtocol.pas') do
    Require(SafeComponentFile('HomeLibReader',Name),'Reader core rejects first-use adapter: '+Name);
  for var Name in ['tools/doc/DocSharp.Binary.Doc.dll','tools/djvu/libdjvulibre.dll',
    'tools/webp/libwebp.dll','tools/pdfium/pdfium.dll','tools/kindle/python/python.exe',
    'tools/djvu/HomeLibDjvu-source/../../libdjvulibre.dll'] do
    Require(not SafeComponentFile('HomeLibReader',Name),'Reader core accepts an optional engine or unsafe path: '+Name);
  EmptyRoot:=TPath.Combine(Settings.AppPath,'reader-missing-modules'); ForceDirectories(EmptyRoot);
  for var Pair in TArray<string>.Create('.pdf=PDFium','.djvu=DjVuLibre','.doc=DocSharp',
    '.xls=DocSharp','.chm=7-Zip','.cbr=7-Zip','.cb7=7-Zip','.webp=WebP') do
    Require(RequiredReaderComponent(EmptyRoot,Pair.Split(['='])[0])=Pair.Split(['='])[1],
      'Missing format dependency lost: '+Pair);
  for var Ext in TArray<string>.Create('.fb2','.epub','.txt','.docx') do
    Require(RequiredReaderComponent(EmptyRoot,Ext)='','Native format prompted for unnecessary module');
  // These formats used to fail while reading dependency timestamps, before
  // reaching the converter's typed first-use exception.
  for var Ext in TArray<string>.Create('.lit','.lrf','.pdb','.rgo','.tiff','.docm') do
  begin
    LegacyFile:=TPath.Combine(Settings.AppPath,'missing-converter'+Ext);
    TFile.WriteAllText(LegacyFile,'Owned dependency probe; never decoded'); Missing:='';
    try
      if IsOfficeReaderFormat(Ext) then PrepareOfficeReaderFile(LegacyFile,LegacyFile)
      else PrepareLegacyReaderFile(LegacyFile,LegacyFile);
    except on E: EMHLComponentRequired do Missing:=E.ComponentID; end;
    Require(Missing='BookProcessing','Rare/Office format did not request its shared processing module: '+Ext);
  end;
  LegacyFile:=TPath.Combine(Settings.AppPath,'missing-prepare.pdf');
  TFile.WriteAllText(LegacyFile,'%PDF-1.4'+sLineBreak+'Owned dependency probe'); Missing:='';
  PreparationOwner:=TComponent.Create(nil);
  try
    var Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(41,0); Book.NodeType:=ntBookInfo;
    Book.CollectionRoot:=ExtractFilePath(LegacyFile); Book.FileName:=ChangeFileExt(ExtractFileName(LegacyFile),'');
    Book.FileExt:='.pdf'; Include(Book.BookProps,bpIsLocal);
    PrepareReaderFileInBackground(PreparationOwner,Book,True,
      procedure(Prepared: string) begin raise Exception.Create('Missing PDF unexpectedly opened'); end,
      False,True,True,procedure(ID: string) begin Missing:=ID; end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(PreparationOwner) do
    begin Application.ProcessMessages; Sleep(10); Require(GetTickCount64-Started<5000,'Module handoff did not finish'); end;
    Require(Missing='PDFium','Actual background preparation lost the missing module callback');
  finally PreparationOwner.Free; end;
  // An interrupted/partial package also needs a repair offer, before any
  // interpreter is run. These marker files are deliberately not executables.
  ForceDirectories(TPath.Combine(Settings.AppPath,'tools\kindle\python'));
  ForceDirectories(TPath.Combine(Settings.AppPath,'tools\bookconvert'));
  TFile.WriteAllText(TPath.Combine(Settings.AppPath,'tools\kindle\python\python.exe'),'Owned partial module marker');
  TFile.WriteAllText(TPath.Combine(Settings.AppPath,'tools\bookconvert\office_inputs.py'),'Owned partial module marker');
  LegacyFile:=TPath.Combine(Settings.AppPath,'missing-converter.docm'); Missing:='';
  try PrepareOfficeReaderFile(LegacyFile,LegacyFile);
  except on E: EMHLComponentRequired do Missing:=E.ComponentID; end;
  Require(Missing='BookProcessing','Partial Office module did not offer repair');
  // A decoder may first be needed while constructing the reading view, after
  // extraction has finished. Each request must survive release of that worker.
  LegacyFile:=TPath.Combine(Settings.AppPath,'native-module-handoff.fb2');
  TFile.WriteAllText(LegacyFile,'<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Owned module handoff</book-title><lang>ru</lang></title-info></description><body><section><p>Native text</p></section></body></FictionBook>',TEncoding.UTF8);
  for var ID in TArray<string>.Create('PDFium','DjVuLibre','DocSharp','7-Zip','WebP','JPEG XL',
    'BookProcessing','ImageProcessing','Kindle','LegacyBooks','LegacyOffice','XPS') do
  begin
    Missing:=''; PreparationOwner:=TComponent.Create(nil);
    try
      var Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(41,0); Book.NodeType:=ntBookInfo;
      Book.CollectionRoot:=ExtractFilePath(LegacyFile); Book.FileName:=ChangeFileExt(ExtractFileName(LegacyFile),'');
      Book.FileExt:='.fb2'; Include(Book.BookProps,bpIsLocal);
      PrepareReaderFileInBackground(PreparationOwner,Book,True,
        procedure(Prepared: string)
        begin
          Require(not ReaderPreparationsPending(PreparationOwner),'Module request retained its preparation worker');
          raise EMHLComponentRequired.Create(ID,'Owned decoder request');
        end,False,False,False,procedure(ComponentID: string) begin Missing:=ComponentID; end);
      Started:=GetTickCount64;
      while ReaderPreparationsPending(PreparationOwner) do
      begin Application.ProcessMessages; Sleep(10); Require(GetTickCount64-Started<5000,'Decoder handoff did not finish'); end;
      Require(Missing=ID,'Reading view lost its first-use decoder request: '+ID);
    finally PreparationOwner.Free; end;
  end;
  for var RequestedID in TArray<string>.Create('PDFium','BookProcessing','ImageProcessing','Kindle','LegacyBooks','LegacyOffice','XPS') do
  begin
  Dialog:=TReaderModuleForm.Create(nil); Dialog.RequestedID:=RequestedID;
  try
    View:=Dialog.FindComponent('UpdateComponents') as TListView;
    Primary:=Dialog.FindComponent('UpdatePrimary') as TButton;
    History:=Dialog.FindComponent('UpdateHistoryComponent') as TComboBox;
    Require(Assigned(View) and Assigned(Primary) and Assigned(History),'Reader component controls missing');
    for var Item in View.Items do
      Require((Item.Caption<>'HomeLibre') and not Item.Caption.Contains('SQLite') and
        not Item.Caption.Contains('AlReader') and not Item.Caption.Contains('SumatraPDF'),
        'Catalogue/external-reader component leaked into standalone view');
    Require((History.Items.IndexOf('HomeLibre')<0),'Catalogue release leaked into reader history');
    Dialog.RequestComponent(RequestedID,'Для этой книги нужен дополнительный модуль.');
    Started:=GetTickCount64; PDFRow:=nil;
    repeat
      Application.ProcessMessages; Sleep(10);
      for var Item in View.Items do if Item.Caption.Contains(RequestedID) then PDFRow:=Item;
    until (Assigned(PDFRow) and (PDFRow.SubItems[1]='999.0') and Primary.Enabled) or
      (GetTickCount64-Started>5000);
    Require(Assigned(PDFRow) and PDFRow.Selected and (PDFRow.SubItems[1]='999.0') and Primary.Enabled,
      'Missing PDF did not become selected installable module');
    Require((Dialog.Requests.Count=2) and (Dialog.Requests[0]=COMPONENT_MIRROR_API),
      'First-use module request checked unrelated components');
    Require(Assigned(Primary.OnClick),'Reader download action missing');
    try Primary.OnClick(Primary);
    except on E: Exception do if E.Message<>'OWN_READER_DOWNLOAD_OBSERVED' then raise; end;
    Require(Dialog.DownloadID=RequestedID,'Filtered row attempted another component or catalogue download');
  finally Dialog.Free; end;
  end;
  Writeln('PASS standalone reader hides catalogue updates and resolves missing format modules with correct independent download');
end;

procedure TestReaderPackageInstallation;
var Folder, Target, Archive, ID, Version, Job, PrivateFile, Tag, ReopenFile, Profile: string;
  Feed: TJSONValue; Entries: TJSONArray; Files: TUpdateFiles;
begin
  RequireIsolatedRegression;
  Folder:=GetEnvironmentVariable('HLRU_READER_PACKAGES');
  Require((Folder<>'') and DirectoryExists(Folder),'Specify owned reader packages for installation test');
  Feed:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8));
  Target:=TPath.Combine(Settings.AppPath,'reader-install-target'); ForceDirectories(Target);
  PrivateFile:=TPath.Combine(Target,'private-reader-settings.txt'); TFile.WriteAllText(PrivateFile,'keep my data');
  TFile.WriteAllText(TPath.Combine(Target,'HomeLibReader.exe'),'Owned target marker, never executed');
  try
    Require((Feed is TJSONObject) and Feed.TryGetValue<TJSONArray>('components',Entries),'Missing reader module feed');
    for ID in TArray<string>.Create('HomeLibReader','PDFium','BookConverter') do
    begin
      Version:='';
      for var Entry in Entries do
        if (Entry.GetValue<string>('id')=ID) and (Entry.GetValue<string>('platform')=ProgramUpdatePlatform) then
          Version:=Entry.GetValue<string>('version');
      Require(Version<>'','Reader module feed omitted '+ID);
      Archive:=TPath.Combine(Folder,ComponentArchiveName(ID,ProgramUpdatePlatform));
      var Zip:=TZipFile.Create;
      try
        Zip.Open(Archive,zmRead); var Data: TBytes; Zip.Read(UPDATE_MANIFEST,Data);
        var Identity:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
        try Tag:=Identity.GetValue<string>('release'); finally Identity.Free; end;
      finally Zip.Free; end;
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
      try
        Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),Tag,ProgramUpdatePlatform,Job,True,ID,Version);
        Require(PreparedIncludesComponent(Job,ID) and not PreparedIncludesComponent(Job,'nonexistent'),
          'Prepared reader installation lost its component identity');
        InstallProgramUpdate(Job,Target);
        Require(not ComponentNeedsRepair(Target,ID),'Reader module installation is incomplete: '+ID);
        Require(InstalledComponentVersion(Target,ID)=Version,'Wrong installed reader module version');
        for var Entry in Files do
          Require(UpdateSHA256(TPath.Combine(Target,Entry.Name))=Entry.SHA256,'Installed reader module differs from verified bytes');
        Require(TFile.ReadAllText(PrivateFile)='keep my data','Reader module installation changed personal data');
        ReopenFile:=GetEnvironmentVariable('HLRU_READER_REOPEN_FILE');
        if (ID='BookConverter') and (ReopenFile<>'') then
        begin
          Require(FileExists(ReopenFile),'Missing owned reader restart fixture');
          Profile:=TPath.Combine(Target,'owned-reader-profile'); ForceDirectories(Profile);
          var Ini:=TMemIniFile.Create(TPath.Combine(Profile,'HomeLibReader.ini'),TEncoding.UTF8);
          try Ini.WriteString('ReaderSession','PendingFile',ReopenFile); Ini.UpdateFile; finally Ini.Free; end;
          var Request:=TJSONObject.Create; var Arguments:=TJSONArray.Create;
          try
            Request.AddPair('target',Target); Request.AddPair('application','HomeLibReader.exe');
            Request.AddPair('pid',TJSONNumber.Create(0)); Request.AddPair('tag',Tag);
            Request.AddPair('sha256',UpdateSHA256(Archive));
            Arguments.Add('--profile='+Profile); Request.AddPair('args',Arguments);
            TFile.WriteAllText(TPath.Combine(Job,'request.json'),Request.ToJSON,TEncoding.UTF8);
          finally Request.Free; end;
          TFile.Copy(Archive,TPath.Combine(Job,'release.zip'));
          TFile.Copy(TPath.Combine(Target,'HomeLibRuUpdater.exe'),TPath.Combine(Job,'HomeLibRuUpdater.exe'));
          Writeln('READER_RESTART_PLAN ',Job);
          Job:=''; // Explicit --keep run owns this plan until normal UI verification.
        end;
      finally if Job<>'' then CleanProgramUpdate(Job); end;
    end;
    Require(RequiredReaderComponent(Target,'.pdf')='','Installed PDF module is still reported missing');
    Writeln('PASS real reader PDF and conversion packages verify architecture hashes versions and install without catalogue preserving personal files');
  finally Feed.Free; end;
end;
