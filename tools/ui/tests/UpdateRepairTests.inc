// Real download workers and update form. Only the transport is redirected to
// an owned loopback server; release identities, hashes and preparation stay real.
type
  TRepairServer = class
  private
    HTTP: TIdHTTPServer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  public
    URLs, Files: TStringList;
    URL, Failure: string;
    Requests: Integer;
    constructor Create;
    destructor Destroy; override;
  end;
  TRepairWorker = class(TProgramDownloadThread)
  private FServer: TRepairServer;
  protected function FetchDownload(const URL: string; Content: TStream): IHTTPResponse; override;
  public constructor Create(Window: HWND; const Info: TProgramRelease; const Job: string; Server: TRepairServer);
  end;
  TRepairForm = class(TfrmProgramUpdate)
  private FServer: TRepairServer;
  protected
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread; override;
    procedure OpenReleasePage(const URL: string); override;
  public
    RequestedComponent, OpenedPage: string;
    StopBeforeDownload: Boolean;
    Rechecks, Restarts: Integer;
    procedure RepairCheckRequested(Sender: TObject);
    procedure RepairRestartRequested(Sender: TObject);
    function HelperSource: string;
    constructor CreateForServer(Server: TRepairServer);
  end;

constructor TRepairServer.Create;
begin
  inherited;
  URLs:=TStringList.Create; Files:=TStringList.Create;
  HTTP:=TIdHTTPServer.Create(nil); HTTP.KeepAlive:=False; HTTP.MaxConnections:=2;
  HTTP.OnCommandGet:=Command; HTTP.Bindings.Clear;
  with HTTP.Bindings.Add do begin IP:='127.0.0.1'; Port:=0; end;
  HTTP.Active:=True;
  URL:=Format('http://127.0.0.1:%d/',[HTTP.Bindings[0].Port]);
  Require(HTTP.Bindings[0].Port>0,'Repair server did not acquire a private loopback port');
end;

destructor TRepairServer.Destroy;
begin
  if Assigned(HTTP) then begin HTTP.Active:=False; HTTP.Free; end;
  URLs.Free; Files.Free; inherited;
end;

procedure TRepairServer.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
var Index: Integer;
begin
  if not Request.Document.StartsWith('/part-') or
    not TryStrToInt(Copy(Request.Document,7,MaxInt),Index) or
    (Index<0) or (Index>=Files.Count) then
  begin Failure:='Unexpected owned repair route: '+Request.Document; Response.ResponseNo:=404; Exit; end;
  InterlockedIncrement(Requests);
  Response.ContentType:='application/octet-stream';
  Response.ContentStream:=TFileStream.Create(Files[Index],fmOpenRead or fmShareDenyWrite);
  Response.FreeContentStream:=True;
end;

constructor TRepairWorker.Create(Window: HWND; const Info: TProgramRelease; const Job: string; Server: TRepairServer);
begin inherited Create(Window,THTTPClient.Create,Info,Job); FServer:=Server; end;

function TRepairWorker.FetchDownload(const URL: string; Content: TStream): IHTTPResponse;
var Index: Integer;
begin
  Index:=FServer.URLs.IndexOf(URL);
  if Index<0 then raise Exception.Create('Repair transport refused a non-fixture request: '+URL);
  Result:=inherited FetchDownload(FServer.URL+'part-'+IntToStr(Index),Content);
end;

constructor TRepairForm.CreateForServer(Server: TRepairServer);
begin FServer:=Server; inherited Create(nil); Caption:='Обновление HomeLib Ru — проверка восстановления'; end;

function TRepairForm.CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin
  if StopBeforeDownload then
  begin RequestedComponent:=Info.ComponentID; raise Exception.Create('OWN_REPAIR_QUEUE_OBSERVED'); end;
  Result:=TRepairWorker.Create(Window,Info,Job,FServer);
end;

procedure TRepairForm.RepairCheckRequested(Sender: TObject);
begin Inc(Rechecks); Require(StartCheckCycle(False),'Cached repair did not restart a check cycle'); end;

procedure TRepairForm.RepairRestartRequested(Sender: TObject);
begin Inc(Restarts); end;

function TRepairForm.HelperSource: string;
begin Result := InstallationHelperSource; end;

procedure TRepairForm.OpenReleasePage(const URL: string);
begin OpenedPage:=URL; end;

procedure TestUnavailableApplicationArchive(const Component: TProgramRelease);
var Dialog: TRepairForm; App: TProgramRelease; Releases: TComponentReleases;
  Primary: TButton; Observed: Boolean;
begin
  Dialog:=TRepairForm.CreateForServer(nil);
  try
    Dialog.StopBeforeDownload:=True; Primary:=nil;
    for var Control in Dialog do
      if (Control is TButton) and TButton(Control).Default then Primary:=TButton(Control);
    Require(Assigned(Primary),'Missing archive test has no primary action');
    App:=Default(TProgramRelease); App.Tag:='2.7.0_pre5.999';
    App.URL:='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+App.Tag;
    Releases:=Default(TComponentReleases);
    Require(Dialog.StartCheckCycle(False),'Web-only app check did not start');
    Dialog.ApplicationChecked(App,True,''); Dialog.ComponentsReceived(Releases,True,'');
    Require(Primary.Caption='Скачать со страницы выпуска',
      'Web-only application update was incorrectly presented as current');
    Primary.Click;
    Require((Dialog.OpenedPage=App.URL) and (Dialog.RequestedComponent=''),
      'Web-only application update lost its release page');
    Dialog.OpenedPage:='';
    Writeln('PASS application-only web release remains visible and opens its own release page');
    Releases[4]:=Component;
    // This test observes request selection only. No fabricated package is fetched.
    Releases[4].ComponentVersion:='65535.0'; Releases[4].Tag:='65535.0';
    Releases[4].DownloadURL:='https://github.com/ip7z/7zip/releases/download/65535.0/7z655350';
    if ProgramUpdatePlatform='Win64' then Releases[4].DownloadURL:=Releases[4].DownloadURL+'-x64';
    Releases[4].DownloadURL:=Releases[4].DownloadURL+'.exe';
    Require(Dialog.StartCheckCycle(False),'Missing archive check did not start');
    Dialog.ApplicationChecked(App,True,''); Dialog.ComponentsReceived(Releases,True,'');
    Observed:=False;
    try Primary.Click;
    except on E: Exception do
      if E.Message='OWN_REPAIR_QUEUE_OBSERVED' then Observed:=True else raise;
    end;
    Require(Observed and (Dialog.RequestedComponent='7-Zip') and (Dialog.OpenedPage=''),
      'Missing app archive opened a web page instead of starting an independent component update');
    Writeln('PASS unavailable application archive does not block an independent component download or open its web page');
  finally Dialog.Free; end;
end;

procedure TestCachedComponentWithoutUpdater(const Fixture, Cache: string);
var Job, Version, Archive, Installed: string; SavedReady: TBytes; Root: TJSONObject;
  Probe: TRepairForm; Primary: TButton;
begin
  Require(not FileExists(Settings.AppPath+'HomeLibRuUpdater.exe'),'Cached helper regression requires an absent installed helper');
  Job:=TPath.Combine(Cache,'HomeLibRu-update-cached-component-'+IntToStr(GetCurrentProcessId));
  Require(not DirectoryExists(Job),'Cached helper regression would overwrite an existing job');
  ForceDirectories(Job); Archive:=TPath.Combine(Job,'release.zip');
  TFile.Copy(TPath.Combine(Fixture,'sevenzip.zip'),Archive);
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Fixture,'fixtures.json'),TEncoding.UTF8)) as TJSONObject;
  try Version:=Root.GetValue<string>('sevenzip_version'); finally Root.Free; end;
  PrepareOfficialComponent(Archive,Job,'7-Zip',Version,ProgramUpdatePlatform,'',Settings.AppPath);
  SavedReady:=TFile.ReadAllBytes(TPath.Combine(Cache,'ready.json'));
  Installed:=Settings.AppPath+'tools/7zip/7z.exe'; TFile.Move(Installed,Installed+'.repair-held');
  Probe:=nil;
  try
    Root:=TJSONObject.Create;
    try
      Root.AddPair('job',Job); Root.AddPair('tag',Version); Root.AddPair('version',Version);
      Root.AddPair('component','7-Zip'); Root.AddPair('sha256',UpdateSHA256(Archive));
      Root.AddPair('size',TJSONNumber.Create(TFile.GetSize(Archive)));
      TFile.WriteAllText(TPath.Combine(Cache,'ready.json'),Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
    Probe:=TRepairForm.CreateForServer(nil); Probe.OnCheck:=Probe.RepairCheckRequested;
    Probe.OnRestart:=Probe.RepairRestartRequested;
    Require(Probe.RestoreReady,'Actual prepared component cache could not be reopened');
    Primary:=nil;
    for var Component in Probe do
      if (Component is TButton) and TButton(Component).Default then Primary:=TButton(Component);
    Require(Assigned(Primary),'Cached component has no primary action');
    Primary.Click;
    Require((Probe.Rechecks=1) and (Probe.Restarts=0) and not Probe.PendingInstall,
      'Missing updater on a cached component closed the application instead of requesting full repair');
    Require(not FileExists(Installed),'Cached repair modified installed files before a verified application download');
    Writeln('PASS cached component with a vanished updater requests full repair before restart and preserves installed files');
  finally
    Probe.Free; TFile.WriteAllBytes(TPath.Combine(Cache,'ready.json'),SavedReady);
    if FileExists(Installed+'.repair-held') then TFile.Move(Installed+'.repair-held',Installed);
    CleanProgramUpdate(Job);
  end;
end;

procedure TestUpdateRepair;
var Server: TRepairServer; Dialog: TRepairForm; Current: TProgramRelease;
  Releases: TComponentReleases; Index: TJSONObject; Root, Ready: TJSONValue;
  Primary: TButton; View: TListView; Status: TLabel; Notes: TUpdateNotesView;
  Fixture, CacheRoot, Cache, Job, SavedLocal, Helper, Digest, SourceHash, Reader, ReaderHash: string;
  Names, Hashes: TArray<string>; Moved: Integer; Deadline, Started, SelectionMS: UInt64;
  OriginalTheme, HadLocal, Restored, Rejected: Boolean; EnvLength: DWORD; EmptyValue: Char;
  HelperBytes, Broken: TBytes;

  procedure Controls;
  begin
    Primary:=nil; View:=nil; Status:=nil; Notes:=nil;
    for var Component in Dialog do
    begin
      if (Component is TButton) and TButton(Component).Default then Primary:=TButton(Component);
      if Component is TListView then View:=TListView(Component);
      if (Component is TLabel) and (Component.Name='UpdateStatus') then Status:=TLabel(Component);
      if Component is TUpdateNotesView then Notes:=TUpdateNotesView(Component);
    end;
    Require(Assigned(Primary) and Assigned(View) and Assigned(Status) and Assigned(Notes),'Repair form controls absent');
  end;
  procedure Route(const Address, Name: string);
  begin Server.URLs.Add(Address); Server.Files.Add(TPath.Combine(Fixture,Name)); end;
  procedure RestoreInputs(IncludeHelper: Boolean);
  begin
    if (Reader<>'') and FileExists(Reader+'.repair-held') then TFile.Move(Reader+'.repair-held',Reader);
    for var I:=0 to Moved-1 do
      if IncludeHelper or (I<Moved-1) then
        if FileExists(Settings.AppPath+Names[I]+'.repair-held') then
          TFile.Move(Settings.AppPath+Names[I]+'.repair-held',Settings.AppPath+Names[I]);
  end;
begin
  RequireIsolatedRegression;
  Fixture:=TPath.Combine(Settings.AppPath,'repair-fixtures');
  Index:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Fixture,'fixtures.json'),TEncoding.UTF8)) as TJSONObject;
  Server:=nil; Dialog:=nil; Moved:=0; OriginalTheme:=MHLThemeDark;
  SavedLocal:=GetEnvironmentVariable('LOCALAPPDATA'); SetLastError(ERROR_SUCCESS);
  EnvLength:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
  HadLocal:=(EnvLength<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND);
  CacheRoot:=TPath.Combine(Settings.AppPath,'repair-owned-cache'); ForceDirectories(CacheRoot);
  if not SetEnvironmentVariableW('LOCALAPPDATA',PChar(CacheRoot)) then RaiseLastOSError;
  Names:=TArray<string>.Create('tools/7zip/7z.exe','tools/doc/HomeLibDoc.exe',
    'tools/djvu/HomeLibDjvu.exe','HomeLibRuUpdater.exe'); SetLength(Hashes,Length(Names));
  SourceHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll');
  try
    Require(Assigned(Index) and (Index.GetValue<string>('tag')=PROGRAM_RELEASE_VERSION),'Repair fixture release differs from compiled release');
    for var ID in ComponentIDs do Require(not ComponentNeedsRepair(Settings.AppPath,ID),'Repair baseline incomplete: '+ID);
    for var I:=0 to High(Names) do
    begin
      Hashes[I]:=THashSHA2.GetHashStringFromFile(Settings.AppPath+Names[I]);
      TFile.Move(Settings.AppPath+Names[I],Settings.AppPath+Names[I]+'.repair-held'); Inc(Moved);
    end;
    Require(ComponentNeedsRepair(Settings.AppPath,'7-Zip') and ComponentNeedsRepair(Settings.AppPath,'DocSharp') and
      ComponentNeedsRepair(Settings.AppPath,'DjVuLibre'),'Missing bootstrap files were falsely complete');
    Server:=TRepairServer.Create;
    Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
    Current.DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+Current.Tag+'/'+Index.GetValue<string>('application_name');
    Current.SHA256:=Index.GetValue<string>('application_sha256'); Current.Size:=TFile.GetSize(TPath.Combine(Fixture,'application.zip'));
    Current.URL:='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+Current.Tag;
    Current.History:=Current.Tag+sLineBreak+'Восстановление отсутствующих компонентов.';
    Route(Current.DownloadURL,'application.zip');
    Releases:=Default(TComponentReleases);
    Releases[4].ComponentID:='7-Zip'; Releases[4].ComponentVersion:=Index.GetValue<string>('sevenzip_version');
    Releases[4].Tag:=Releases[4].ComponentVersion; Releases[4].OfficialComponent:=True;
    Releases[4].DownloadURL:=Index.GetValue<string>('sevenzip_url');
    Releases[4].SHA256:=THashSHA2.GetHashStringFromFile(TPath.Combine(Fixture,'sevenzip.zip'));
    Releases[4].Size:=TFile.GetSize(TPath.Combine(Fixture,'sevenzip.zip'));
    Route(Releases[4].DownloadURL,'sevenzip.zip');
    Releases[5].ComponentID:='DocSharp'; Releases[5].ComponentVersion:=Index.GetValue<string>('doc_version');
    Releases[5].Tag:=Releases[5].ComponentVersion; Releases[5].OfficialComponent:=True;
    Releases[5].DownloadURL:=Index.GetValue<string>('doc_url'); Releases[5].SecondaryURL:=Index.GetValue<string>('common_url');
    Releases[5].AdditionalURLs:=TArray<string>.Create(Index.GetValue<string>('ppt_url'),Index.GetValue<string>('xls_url'));
    Releases[5].AdditionalSizes:=TArray<Int64>.Create(TFile.GetSize(TPath.Combine(Fixture,'ppt.nupkg')),TFile.GetSize(TPath.Combine(Fixture,'xls.nupkg')));
    Releases[5].SecondarySize:=TFile.GetSize(TPath.Combine(Fixture,'common.nupkg'));
    Releases[5].Size:=TFile.GetSize(TPath.Combine(Fixture,'doc.nupkg'))+Releases[5].SecondarySize+
      Releases[5].AdditionalSizes[0]+Releases[5].AdditionalSizes[1];
    Route(Releases[5].DownloadURL,'doc.nupkg'); Route(Releases[5].SecondaryURL,'common.nupkg');
    Route(Releases[5].AdditionalURLs[0],'ppt.nupkg'); Route(Releases[5].AdditionalURLs[1],'xls.nupkg');
    Dialog:=TRepairForm.CreateForServer(Server); Controls;
    Require(Dialog.StartCheckCycle(False),'Repair check did not start');
    Dialog.ApplicationChecked(Current,True,''); Dialog.ComponentsReceived(Releases,True,'');
    Require(Primary.Enabled and (Primary.Caption='Скачать и восстановить') and
      not string(Status.Caption).Contains('7-Zip') and not string(Status.Caption).Contains('DjVuLibre') and
      not string(Status.Caption).Contains('DocSharp'),
      'Same-release repair was hidden or lacked an explanation');
    Require(View.Items[0].SubItems[2]='Восстановление компонентов','Repair row falsely says current');
    if Assigned(Dialog.ActiveControl) then
      Writeln('PROFILE updater initial focus ',Dialog.ActiveControl.ClassName,'/',Dialog.ActiveControl.Name);
    {$IFDEF MHL_RELEASE_PERFORMANCE}ProgramUpdateProfile:=Default(TProgramUpdateProfile);{$ENDIF}
    {$IFDEF MHL_RELEASE_PERFORMANCE}
    UpdateNotesParseMS:=0; UpdateNotesControlsMS:=0; UpdateNotesFormatMS:=0;
    UpdateNotesThemeMS:=0; UpdateNotesLayoutMS:=0;
    {$ENDIF}
    Started:=GetTickCount64;
    for var I:=0 to 99 do
    begin
      View.Items[I mod 7].Selected:=True;
      View.OnSelectItem(View,View.Items[I mod 7],True);
    end;
    SelectionMS:=GetTickCount64-Started;
    Writeln('PROFILE updater 100 cached component selections ms=',SelectionMS);
    {$IFDEF MHL_RELEASE_PERFORMANCE}
    Writeln('PROFILE updater stages selections=',ProgramUpdateProfile.Selections,
      ' total_ms=',ProgramUpdateProfile.SelectionMS,' notes_ms=',ProgramUpdateProfile.NotesMS,
      ' rows_ms=',ProgramUpdateProfile.RowsMS,' layout_ms=',ProgramUpdateProfile.LayoutMS,
      ' changes_ms=',ProgramUpdateProfile.ChangesMS,' release_ms=',ProgramUpdateProfile.ReleaseMS);
    Writeln('PROFILE updater notes parse_ms=',UpdateNotesParseMS,' controls_ms=',UpdateNotesControlsMS,
      ' format_ms=',UpdateNotesFormatMS,' theme_ms=',UpdateNotesThemeMS,' layout_ms=',UpdateNotesLayoutMS);
    {$ENDIF}
    if GetEnvironmentVariable('HOMELIB_UPDATE_PROFILE')='1' then
      Writeln('DIAGNOSTIC updater speed gate omitted only for stage profiling; not a final performance pass')
    else
    begin
      Require(SelectionMS<5000,'Updater component selection exceeds 5 seconds for 100 changes');
      Writeln('PASS updater component selection respects the 5000ms budget for 100 changes');
    end;
    View.Items[0].Selected:=True; View.OnSelectItem(View,View.Items[0],True);
    // Restore the baseline inventory for the separate no-archive decision test.
    RestoreInputs(True); TestUnavailableApplicationArchive(Releases[4]);
    for var I:=0 to High(Names) do TFile.Move(Settings.AppPath+Names[I],Settings.AppPath+Names[I]+'.repair-held');
    // A file disappears after the first check, and its author is unavailable.
    // Missing optional readers must not turn their unavailable author row
    // into a full-application repair action; required runtime repair stays on HomeLib Ru.
    Reader:=Settings.AppPath+'Readers/AlReader/AlReader2.exe';
    ReaderHash:=THashSHA2.GetHashStringFromFile(Reader); TFile.Move(Reader,Reader+'.repair-held');
    Releases[1].ComponentID:='AlReader'; Releases[1].ComponentError:='Сайт автора недоступен. Повторите проверку.';
    Releases[1].ComponentErrorDetails:='Owned author HTTP 503 fixture';
    Require(Dialog.StartCheckCycle(False),'Second repair check did not refresh its local inventory');
    Dialog.ApplicationChecked(Current,True,''); Dialog.ComponentsReceived(Releases,True,'');
    View.Items[2].Selected:=True; View.OnSelectItem(View,View.Items[2],True);
    Require(Primary.Enabled and (Primary.Caption='Повторить проверку') and
      string(Status.Caption).Contains(Releases[1].ComponentError) and
      View.Items[2].Caption.Contains('AlReader') and (View.Items[2].SubItems[2]='Не удалось проверить'),
      'Missing optional reader forced full-application repair or lost its author error');
    View.Items[0].Selected:=True; View.OnSelectItem(View,View.Items[0],True);
    Require(Primary.Caption='Скачать и восстановить','Required runtime repair disappeared from the application row');
    Primary.Click; Deadline:=GetTickCount64+120000;
    repeat
      Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
      Require(GetTickCount64<Deadline,'Repair download/prepare exceeded bounded deadline: '+string(Status.Caption));
      if Primary.Enabled and (Primary.Caption='Повторить загрузку') then
        raise Exception.Create('Repair queue failed: '+string(Status.Caption));
    until Primary.Enabled and (Primary.Caption='Установить и перезапустить');
    Require((Server.Requests=1) and (Server.Failure=''),'Application repair downloaded an unused optional component or used an unexpected source');
    for var Name in Names do Require(not FileExists(Settings.AppPath+Name),'Preparation modified installed files before installation');
    Writeln('PASS same-release repair downloads minimal verified application without forcing optional archive or DOC components');
    Require(not FileExists(Reader),'Author repair changed installed files before installation');
    Cache:=ProgramUpdateCache(Settings.AppPath);
    Ready:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Cache,'ready.json'),TEncoding.UTF8));
    try Job:=TJSONObject(Ready).GetValue<string>('job'); Digest:=TJSONObject(Ready).GetValue<string>('sha256'); finally Ready.Free; end;
    Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Job,'manifest.json'),TEncoding.UTF8));
    try
      var Bundle:=TJSONObject(Root).GetValue('bundle') as TJSONArray;
      Require((TJSONObject(Root).GetValue<string>('component','')='') and not Assigned(Bundle),
        'Application repair unexpectedly queued an absent optional component');
    finally Root.Free; end;
    Require(not FileExists(TPath.Combine(Job,'payload/Readers/AlReader/AlReader2.exe')),
      'Minimal repair forced a missing optional reader back into the payload');
    Writeln('PASS unavailable optional reader author does not force installation or block required runtime repair');
    Helper:=PreparedProgramUpdateHelper(Job,PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,Digest);
    Require(SameFileName(Dialog.HelperSource,Helper),'Repair did not choose its verified staged installer');
    TFile.Copy(Settings.AppPath+Names[High(Names)]+'.repair-held',Settings.AppPath+Names[High(Names)]);
    try
      Require(SameFileName(Dialog.HelperSource,Helper),'Existing older installer replaced the matching staged installer');
    finally TFile.Delete(Settings.AppPath+Names[High(Names)]); end;
    Writeln('PASS application repair uses the verified matching installer even when an installed helper exists');
    HelperBytes:=TFile.ReadAllBytes(Helper); Broken:=Copy(HelperBytes,0,Length(HelperBytes)); Broken[0]:=Broken[0] xor 1;
    TFile.WriteAllBytes(Helper,Broken); Rejected:=False;
    try
      try PreparedProgramUpdateHelper(Job,PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,Digest);
      except on E: Exception do Rejected:=True; end;
    finally TFile.WriteAllBytes(Helper,HelperBytes); end;
    Require(Rejected,'A modified extracted helper was accepted for execution');
    Rejected:=False;
    try PreparedProgramUpdateHelper(Job,PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,StringOfChar('0',64));
    except on E: Exception do Rejected:=True; end;
    Require(Rejected,'A helper from an unverified source archive was accepted');
    Writeln('PASS missing updater fallback is bound to exact archive bytes and rejects changed helpers or source digests');
    FreeAndNil(Dialog); RestoreInputs(False);
    for var ID in ComponentIDs do Require(not ComponentNeedsRepair(Settings.AppPath,ID),'Restored component input changed: '+ID);
    Dialog:=TRepairForm.CreateForServer(Server); Controls;
    Require(Dialog.RestoreReady,'Same-release ready repair was discarded when only updater helper was absent');
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark); Application.ProcessMessages;
      for var DPI in [96,144,192] do
      begin
        Dialog.ScaleForPPI(DPI); Dialog.Show; Dialog.Update; Application.ProcessMessages;
        Require(Primary.Visible and (Primary.BoundsRect.Bottom<=Dialog.ClientHeight) and
          (Primary.BoundsRect.Right<=Dialog.ClientWidth),'Repair install button clipped by theme or scale');
        Require(Status.BoundsRect.Bottom<=Notes.Top,'Repair status overlaps history');
        CheckUpdateComponentTable(Dialog,'repair-ready');
      end;
    end;
    Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll')=SourceHash,'Repair test changed original SQLite bytes');
    Writeln('PASS same-version ready repair survives reopening with a missing updater and preserves readable controls in two themes and three DPI settings');
    TestCachedComponentWithoutUpdater(Fixture,Cache);
  finally
    try
      FreeAndNil(Dialog); Server.Free;
      RestoreInputs(True);
      for var I:=0 to Moved-1 do Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+Names[I])=Hashes[I],'Repair fixture changed a held source');
      if ReaderHash<>'' then Require(THashSHA2.GetHashStringFromFile(Reader)=ReaderHash,'Repair fixture changed its AlReader source');
      if Job<>'' then CleanProgramUpdate(Job);
      if (Cache<>'') and FileExists(TPath.Combine(Cache,'ready.json')) then TFile.Delete(TPath.Combine(Cache,'ready.json'));
    finally
      Index.Free; SetMHLTheme(OriginalTheme);
      EmptyValue:=#0;
      if not HadLocal then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',nil)
      else if SavedLocal='' then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',@EmptyValue)
      else Restored:=SetEnvironmentVariableW('LOCALAPPDATA',PChar(SavedLocal));
      Require(Restored,'Repair fixture failed to restore its process environment');
    end;
  end;
end;
