type
  TCMServer = class
    HTTP: TIdHTTPServer;
    URL, OriginalURL, MirrorURL, FeedURL, SecondaryURL, Metadata, Feed: string;
    Original, PackageBytes, ExtractorBytes: TBytes;
    OriginalRequests, MetadataRequests, FeedRequests, MirrorRequests: Integer;
    OriginalStatus: Integer;
    CorruptMirror: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  end;
  TCMDownload = class(TProgramDownloadThread)
    Server: TCMServer;
    CancelOriginal: Boolean;
    protected function FetchDownload(const URL: string; Content: TStream): IHTTPResponse; override;
  end;
  TCMCheck = class(TComponentUpdateThread)
    Metadata, Feed: string;
    Requests: Integer;
    protected function FetchText(const URL: string): string; override;
  end;

  TCMForm = class(TfrmProgramUpdate)
  public Metadata, Feed: string;
  protected function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
  end;

function TCMForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin
  var Checker:=TCMCheck.Create(Window,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
  Checker.Metadata:=Metadata; Checker.Feed:=Feed; Result:=Checker;
end;

constructor TCMServer.Create;
begin
  inherited;
  HTTP:=TIdHTTPServer.Create(nil); HTTP.OnCommandGet:=Command;
  var Binding:=HTTP.Bindings.Add; Binding.IP:='127.0.0.1'; Binding.Port:=0;
  HTTP.Active:=True; URL:='http://127.0.0.1:'+IntToStr(HTTP.Bindings[0].Port);
  OriginalStatus:=503;
end;

destructor TCMServer.Destroy;
begin HTTP.Active:=False; HTTP.Free; inherited; end;

procedure TCMServer.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
var Data: TBytes; Stream: TMemoryStream;
begin
  Response.ResponseNo:=200;
  if Request.Document='/original' then
  begin InterlockedIncrement(OriginalRequests); Response.ResponseNo:=OriginalStatus; Data:=Original; end
  else if Request.Document='/metadata' then
  begin InterlockedIncrement(MetadataRequests); Data:=TEncoding.UTF8.GetBytes(Metadata); end
  else if Request.Document='/feed' then
  begin InterlockedIncrement(FeedRequests); Data:=TEncoding.UTF8.GetBytes(Feed); end
  else if Request.Document='/extractor' then Data:=ExtractorBytes
  else if Request.Document='/mirror' then
  begin
    InterlockedIncrement(MirrorRequests); Data:=Copy(PackageBytes);
    if CorruptMirror then Data[High(Data)]:=Data[High(Data)] xor 1;
  end
  else begin Response.ResponseNo:=404; Data:=nil; end;
  Stream:=TMemoryStream.Create;
  if Length(Data)>0 then Stream.WriteBuffer(Data[0],Length(Data));
  Stream.Position:=0; Response.ContentStream:=Stream; Response.FreeContentStream:=True;
  Response.ContentType:='application/octet-stream';
end;

function TCMDownload.FetchDownload(const URL: string; Content: TStream): IHTTPResponse;
var Route: string;
begin
  if URL=Server.OriginalURL then
  begin if CancelOriginal then begin Terminate; Abort; end; Route:='/original'; end
  else if (Server.SecondaryURL<>'') and (URL=Server.SecondaryURL) then Route:='/extractor'
  else if URL=COMPONENT_MIRROR_API then Route:='/metadata'
  else if URL=Server.FeedURL then Route:='/feed'
  else if URL=Server.MirrorURL then Route:='/mirror'
  else raise Exception.Create('Unrecognized mirror test transport route');
  Result:=inherited FetchDownload(Server.URL+Route,Content);
end;

function TCMCheck.FetchText(const URL: string): string;
begin
  Inc(Requests);
  if URL=COMPONENT_MIRROR_API then Exit(Metadata);
  if URL='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+COMPONENT_FEED_NAME then Exit(Feed);
  raise Exception.Create('Owned unavailable publisher');
end;

procedure TestIBKOriginalMirror;
var Server: TCMServer; Worker: TCMDownload; Info, Source: TProgramRelease;
  Folder, Job: string; Started: UInt64;
begin
  Folder:=GetEnvironmentVariable('HOMELIB_IBK_SOURCE_ARCHIVES');
  Require(Folder<>'','Original IBK mirror check requires explicit verified source archive folder');
  Server:=TCMServer.Create; Worker:=nil;
  try
    Server.PackageBytes:=TFile.ReadAllBytes(TPath.Combine(Folder,'original.zip'));
    Server.ExtractorBytes:=TFile.ReadAllBytes(TPath.Combine(Folder,'innoextract.zip'));
    Server.MirrorURL:=IBK_MIRROR_PREFIX+IBK_MIRROR_NAME;
    Server.SecondaryURL:=IBK_MIRROR_PREFIX+IBK_EXTRACTOR_MIRROR_NAME;
    Server.Metadata:='{"draft":false,"tag_name":"'+ALREADER_FIXED_TAG+'","assets":['+
      '{"name":"'+IBK_MIRROR_NAME+'","size":'+IntToStr(IBK_PACKAGE_SIZE)+',"digest":"sha256:'+IBK_PACKAGE_SHA256+'","browser_download_url":"'+Server.MirrorURL+'"},'+
      '{"name":"'+IBK_EXTRACTOR_MIRROR_NAME+'","size":'+IntToStr(IBK_EXTRACTOR_SIZE)+',"digest":"sha256:'+IBK_EXTRACTOR_SHA256+'","browser_download_url":"'+Server.SecondaryURL+'"}]}';
    Require(ParseIBKMirror(Server.Metadata,IBK_VERSION,Info),'Original IBK mirrors were refused');
    Require(not ParseIBKMirror(Server.Metadata,'99.0',Source),'IBK mirror silently changed version');
    Require(not ParseIBKMirror(Server.Metadata.Replace(IBK_PACKAGE_SHA256,StringOfChar('0',64)),IBK_VERSION,Source),
      'Unverified original IBK mirror digest accepted');
    Source:=Info; Source.DownloadURL:='https://www.bestfree.ru/soft/office/ICE_Book_Reader_v9.6.5.Rus.zip?e=1793200000&s='+StringOfChar('a',64);
    Source.SecondaryURL:=IBK_EXTRACTOR_URL; Server.OriginalURL:=Source.DownloadURL;
    Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-ibk-original-mirror');
    Worker:=TCMDownload.Create(0,CreateHTTPClientGlobal,Source,Job); Worker.Server:=Server; Worker.RuntimePath:=Settings.AppPath;
    Worker.Start; Started:=GetTickCount64;
    while not Worker.Finished do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); Require(GetTickCount64-Started<30000,'IBK mirror transfer timed out'); end;
    Worker.WaitFor;
    Require(Worker.Successful,'Original IBK mirror transfer failed: '+Worker.ErrorText);
    Require((Server.OriginalRequests=1) and (Server.MetadataRequests=1) and (Server.MirrorRequests=1),
      'Original IBK source did not fall back exactly once');
    Require(not ComponentNeedsRepair(TPath.Combine(Job,'payload'),'IBK'),'Original mirror did not prepare complete IBK data');
    Require(not FileExists(TPath.Combine(Job,'payload/tools/ibk/ICEReaderRus.exe')),
      'Mirror unnecessarily installed the ICE reader executable');
    Require(UpdateSHA256(TPath.Combine(Job,'payload/tools/ibk/ICEBookReader-original.zip'))=IBK_PACKAGE_SHA256,
      'IBK mirror changed the original distribution');
    Writeln('PASS IBK mirror preserves unchanged complete original distributions and prepares verified local read data without running ICE'); Flush(Output);
  finally
    if Assigned(Worker) then begin Worker.Terminate; Worker.WaitFor; Worker.Free; CleanProgramUpdate(Job); end;
    Server.Free;
  end;
end;

procedure TestLocalMirrorPackages;
var Folder, Metadata, Feed, ID, Version, Name, Job: string; Root: TJSONValue;
  Entries: TJSONArray; Info, Original: TProgramRelease; Count: Integer;
  Server: TCMServer; Worker: TCMDownload; Started: UInt64;
begin
  Folder:=GetEnvironmentVariable('HOMELIB_COMPONENT_MIRROR_PACKAGES');
  if Folder='' then Exit;
  Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
  Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
  Root:=TJSONObject.ParseJSONValue(Feed); Count:=0;
  try
    Require((Root is TJSONObject) and Root.TryGetValue<TJSONArray>('components',Entries),'Local mirror feed is invalid');
    for var Entry in Entries do
    begin
      if Entry.GetValue<string>('platform','')<>ProgramUpdatePlatform then Continue;
      ID:=Entry.GetValue<string>('id'); Version:=Entry.GetValue<string>('version');
      Require(ParseComponentMirror(Metadata,Feed,ID,Version,Info),'Local mirror metadata failed: '+ID);
      Name:=ComponentVersionedArchiveName(ID,Version,ProgramUpdatePlatform);
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-package-'+ID.Replace(' ',''));
      try
        PrepareProgramUpdate(TPath.Combine(Folder,Name),Info.SHA256,Info.Tag,ProgramUpdatePlatform,Job,True,ID,Version);
        Require(InstalledComponentVersion(TPath.Combine(Job,'payload'),ID)=Version,
          'Prepared mirror identity differs from the verified version: '+ID);
        Writeln('PASS local mirror package native validation ',ID,' ',Version,' ',ProgramUpdatePlatform); Flush(Output); Inc(Count);
      finally CleanProgramUpdate(Job); end;
    end;
    Require(Count=6,'Native local mirror validation did not exercise all six components');
    // DocSharp author downloads consist of four archives. Switching to one
    // complete mirror archive must reset every previous part size and offset.
    Require(ParseComponentMirror(Metadata,Feed,'DocSharp','',Info),'Compound mirror fixture is missing');
    Server:=TCMServer.Create; Worker:=nil;
    try
      Server.Metadata:=Metadata; Server.Feed:=Feed; Server.MirrorURL:=Info.DownloadURL;
      Server.FeedURL:=ComponentMirrorFeedURL(Metadata);
      Server.PackageBytes:=TFile.ReadAllBytes(TPath.Combine(Folder,ComponentVersionedArchiveName('DocSharp',Info.ComponentVersion,ProgramUpdatePlatform)));
      Original:=Default(TProgramRelease); Original.ComponentID:='DocSharp'; Original.ComponentVersion:='0.21.0';
      Original.DownloadURL:='https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/0.21.0/docsharp.binary.doc.0.21.0.nupkg';
      Server.OriginalURL:=Original.DownloadURL; Original.OfficialComponent:=True; Original.Size:=256;
      Original.SecondaryURL:='https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/0.21.0/docsharp.binary.common.0.21.0.nupkg';
      Original.SecondarySize:=64;
      Original.AdditionalURLs:=TArray<string>.Create(
        'https://api.nuget.org/v3-flatcontainer/docsharp.binary.ppt/0.21.0/docsharp.binary.ppt.0.21.0.nupkg',
        'https://api.nuget.org/v3-flatcontainer/docsharp.binary.xls/0.21.0/docsharp.binary.xls.0.21.0.nupkg');
      Original.AdditionalSizes:=TArray<Int64>.Create(64,64);
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-compound-mirror');
      Worker:=TCMDownload.Create(0,CreateHTTPClientGlobal,Original,Job); Worker.Server:=Server; Worker.RuntimePath:=Settings.AppPath;
      Worker.Start; Started:=GetTickCount64;
      while not Worker.Finished do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); Require(GetTickCount64-Started<30000,'Compound mirror timeout'); end;
      Worker.WaitFor;
      Require(Worker.Successful,'Four-part author to single mirror transition failed: '+Worker.ErrorText);
      Require(not ComponentNeedsRepair(TPath.Combine(Job,'payload'),'DocSharp'),'Compound mirror left an incomplete component');
      Writeln('PASS compound component transfer switches to one verified mirror archive without stale part sizes'); Flush(Output);
    finally
      if Assigned(Worker) then begin Worker.Terminate; Worker.WaitFor; Worker.Free; CleanProgramUpdate(Job); end;
      Server.Free;
    end;

  finally Root.Free; end;
end;

procedure TestComponentMirrors;
var Server: TCMServer; Zip: TZipFile; Manifest, FileInfo: TJSONObject; FileList: TJSONArray;
  Stream: TMemoryStream; Data: TBytes; Version, Name, Archive, Job, SourceHash: string;
  Release, Parsed: TProgramRelease; Checker: TCMCheck; Worker: TCMDownload;
  Started: UInt64;
  procedure CheckMirrorUI;
  var Dialog: TCMForm; View: TListView; Row: TListItem; Status: TLabel; Page: TButton;
  begin
    Dialog:=TCMForm.Create(nil);
    try
      Dialog.Metadata:=Server.Metadata; Dialog.Feed:=Server.Feed;
      Dialog.CheckComponents(False);
      View:=Dialog.FindComponent('UpdateComponents') as TListView;
      Status:=Dialog.FindComponent('UpdateStatus') as TLabel;
      Page:=Dialog.FindComponent('UpdateReleasePage') as TButton;
      Started:=GetTickCount64; Row:=nil;
      repeat
        Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
        for var Item in View.Items do if Item.Caption.EndsWith(' · SQLite') then Row:=Item;
      until (Assigned(Row) and (Row.SubItems[2]='Запасная копия')) or (GetTickCount64-Started>10000);
      Require(Assigned(Row) and (Row.SubItems[1]=ComponentDisplayVersion('SQLite',Version)) and
        (Row.SubItems[2]='Запасная копия'),'Mirror UI hid the confirmed fallback version');
      Row.Selected:=True; View.OnSelectItem(View,Row,True);
      Require(string(Status.Caption).Contains('Сайт автора недоступен') and
        (Page.Caption='Компоненты на GitHub'),'Mirror UI misidentified a fallback as a successful author check');
      Writeln('PASS component mirror native UI shows exact fallback version and GitHub source without claiming author availability'); Flush(Output);
    finally Dialog.Free; end;
  end;
  procedure WaitDownload;
  begin
    Worker.Start; Started:=GetTickCount64;
    while not Worker.Finished do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      Require(GetTickCount64-Started<20000,'Mirror fixture worker timed out'); end;
    Worker.WaitFor;
  end;
  procedure ResetRequests;
  begin Server.OriginalRequests:=0; Server.MetadataRequests:=0; Server.FeedRequests:=0; Server.MirrorRequests:=0; end;
  procedure StartWorker(const Suffix: string);
  begin
    ResetRequests; Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-mirror-'+Suffix);
    Worker:=TCMDownload.Create(0,CreateHTTPClientGlobal,Release,Job);
    Worker.Server:=Server; Worker.RuntimePath:=Settings.AppPath;
  end;
  procedure StopWorker;
  begin Worker.Terminate; Worker.WaitFor; Worker.Free; Worker:=nil; CleanProgramUpdate(Job); end;
begin
  RequireIsolatedRegression;
  SourceHash:=UpdateSHA256(Settings.AppPath+'sqlite3.dll');
  Version:=UpdateFileVersion(Settings.AppPath+'sqlite3.dll');
  Require(Version<>'','Native mirror fixture needs actual SQLite');
  Name:=ComponentVersionedArchiveName('SQLite',Version,ProgramUpdatePlatform);
  Server:=TCMServer.Create; Worker:=nil;
  try
    Server.MirrorURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+Name;
    Server.FeedURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+COMPONENT_FEED_NAME;
    Archive:=Settings.AppPath+'owned-sqlite-mirror.zip'; Manifest:=TJSONObject.Create;
    try
      Manifest.AddPair('format',TJSONNumber.Create(1)); Manifest.AddPair('release',ALREADER_FIXED_TAG);
      Manifest.AddPair('platform',ProgramUpdatePlatform); Manifest.AddPair('component','SQLite'); Manifest.AddPair('version',Version);
      FileList:=TJSONArray.Create; Manifest.AddPair('files',FileList); FileInfo:=TJSONObject.Create; FileList.AddElement(FileInfo);
      FileInfo.AddPair('path','sqlite3.dll'); FileInfo.AddPair('size',TJSONNumber.Create(TFile.GetSize(Settings.AppPath+'sqlite3.dll')));
      FileInfo.AddPair('sha256',SourceHash); Stream:=TMemoryStream.Create; Zip:=TZipFile.Create;
      try
        Data:=TEncoding.UTF8.GetBytes(Manifest.ToJSON); Stream.WriteBuffer(Data[0],Length(Data)); Stream.Position:=0;
        Zip.Open(Archive,zmWrite); Zip.Add(Stream,UPDATE_MANIFEST); Zip.Add(Settings.AppPath+'sqlite3.dll','sqlite3.dll'); Zip.Close;
      finally Zip.Free; Stream.Free; end;
    finally Manifest.Free; end;
    Server.PackageBytes:=TFile.ReadAllBytes(Archive);
    Server.Metadata:='{"draft":false,"tag_name":"'+ALREADER_FIXED_TAG+'","assets":['+
      '{"name":"'+COMPONENT_FEED_NAME+'","size":600,"browser_download_url":"'+Server.FeedURL+'"},'+
      '{"name":"'+Name+'","size":'+IntToStr(Length(Server.PackageBytes))+',"digest":"sha256:'+UpdateSHA256(Archive)+
      '","browser_download_url":"'+Server.MirrorURL+'"}]}';
    Server.Feed:='{"format":1,"components":[{"id":"SQLite","version":"'+Version+'","platform":"'+ProgramUpdatePlatform+
      '","archive":"'+Name+'","history":[{"version":"'+Version+'","notes":"Owned exact-version native mirror"}]}]}';
    Require(ParseComponentMirror(Server.Metadata,Server.Feed,'SQLite',Version,Parsed),'Valid versioned mirror was refused');
    Require(not ParseComponentMirror(Server.Metadata,Server.Feed,'SQLite','999.0',Parsed),'Mirror silently changed the requested version');
    Require(not ParseComponentMirror(Server.Metadata.Replace('"draft":false','"draft":true'),Server.Feed,'SQLite',Version,Parsed),'Draft mirror accepted');
    Require(not ParseComponentMirror(Server.Metadata.Replace('https://github.com/Dicur3x/MyHomeLib/','https://foreign.example/'),Server.Feed,'SQLite',Version,Parsed),'Foreign mirror accepted');
    Require(not ParseComponentMirror(Server.Metadata,Server.Feed.Replace(Name,'../'+Name),'SQLite',Version,Parsed),'Unsafe mirror asset name accepted');
    Require(not ParseComponentMirror(Server.Metadata,Server.Feed,'DocSharp',Version,Parsed),'Wrong mirror component accepted');
    Checker:=TCMCheck.Create(0,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
    try
      Checker.Metadata:=Server.Metadata; Checker.Feed:=Server.Feed; Checker.OnlyIDs:=TArray<string>.Create('SQLite'); Checker.Start;
      Started:=GetTickCount64;
      while not Checker.Finished do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); Require(GetTickCount64-Started<10000,'Mirror source fallback timed out'); end;
      Checker.WaitFor;
      Require(Checker.TryGetRelease(0,Parsed) and (Parsed.DownloadURL=Server.MirrorURL) and
        (Parsed.ComponentWarning<>'') and (Parsed.ComponentError='') and (Checker.Requests=3),
        'Publisher source failure did not expose the verified mirror and its version');
    finally Checker.Terminate; Checker.WaitFor; Checker.Free; end;
    CheckMirrorUI;
    Release:=Default(TProgramRelease); Release.ComponentID:='SQLite'; Release.ComponentVersion:=Version;
    // This is the exact current author URL shape; only transport is mapped to loopback.
    Release.DownloadURL:='https://www.sqlite.org/2026/sqlite-dll-win-';
    if ProgramUpdatePlatform='Win64' then Release.DownloadURL:=Release.DownloadURL+'x64-' else Release.DownloadURL:=Release.DownloadURL+'x86-';
    Release.DownloadURL:=Release.DownloadURL+'3540100.zip'; Server.OriginalURL:=Release.DownloadURL;
    Release.Size:=Length(Server.PackageBytes); Release.OfficialComponent:=True;
    Require(IsOfficialComponentURL('SQLite',Version,Release.DownloadURL,ProgramUpdatePlatform,False),'Native SQLite publisher URL is invalid');
    var OriginalArchive:=Settings.AppPath+'owned-sqlite-original.zip'; Zip:=TZipFile.Create;
    try Zip.Open(OriginalArchive,zmWrite); Zip.Add(Settings.AppPath+'sqlite3.dll','sqlite3.dll'); Zip.Close;
    finally Zip.Free; end;
    Server.Original:=TFile.ReadAllBytes(OriginalArchive); Release.Size:=Length(Server.Original);
    Release.SourceSHA3:=UpdateSHA3(OriginalArchive); Server.OriginalStatus:=200;
    StartWorker('publisher');
    try
      WaitDownload; Require(Worker.Successful,'Working publisher transfer failed: '+Worker.ErrorText);
      Require((Server.OriginalRequests=1) and (Server.MetadataRequests=0) and (Server.MirrorRequests=0),
        'Working publisher unexpectedly contacted the mirror');
    finally StopWorker; end;
    Server.OriginalStatus:=503;
    StartWorker('success');
    try
      WaitDownload;
      Require(Worker.Successful,'Native mirror transfer failed: '+Worker.ErrorText);
      Require((Server.OriginalRequests=1) and (Server.MetadataRequests=1) and (Server.FeedRequests=1) and (Server.MirrorRequests=1),
        'Mirror did not follow a single failed publisher transfer');
      Require(UpdateSHA256(TPath.Combine(Job,'payload\sqlite3.dll'))=SourceHash,'Mirror payload differs from the verified original library');
    finally StopWorker; end;
    Server.CorruptMirror:=True; StartWorker('corrupt');
    try
      WaitDownload; Require(not Worker.Successful and (Server.MirrorRequests=1),'Changed mirror archive accepted or retried');
      Require(not DirectoryExists(TPath.Combine(Job,'payload')),'Corrupt mirror produced an installable payload');
    finally StopWorker; end;
    Server.CorruptMirror:=False; var GoodFeed:=Server.Feed;
    Server.Feed:=Server.Feed.Replace('"version":"'+Version+'"','"version":"999.0"'); StartWorker('version');
    try WaitDownload; Require(not Worker.Successful and (Server.MirrorRequests=0),'Mismatched mirror version was downloaded');
    finally StopWorker; Server.Feed:=GoodFeed; end;
    StartWorker('cancel'); Worker.CancelOriginal:=True;
    try WaitDownload; Require(not Worker.Successful and (Server.MetadataRequests=0) and (Server.MirrorRequests=0),'Cancel started a mirror request');
    finally StopWorker; end;
    Require(UpdateSHA256(Settings.AppPath+'sqlite3.dll')=SourceHash,'Mirror test changed installed SQLite');
    TestIBKOriginalMirror; TestLocalMirrorPackages;
    Writeln('PASS component mirror source and real download fallback preserve exact version architecture and bytes, reject changed archives foreign URLs and cancellation, and leave installed files untouched');
    Flush(Output);
  finally Server.Free; end;
end;
