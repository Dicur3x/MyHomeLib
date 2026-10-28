type
  TMCPPackageWorker = class(TComponentUpdateThread)
  public Metadata, Feed: string;
  protected function FetchText(const URL: string): string; override;
  end;
  TMCPPackageForm = class(TfrmProgramUpdate)
  public Metadata, Feed, DownloadID: string;
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread; override;
  end;

function TMCPPackageWorker.FetchText(const URL: string): string;
begin
  if URL=COMPONENT_MIRROR_API then Exit(Metadata);
  if URL=ComponentMirrorFeedURL(Metadata) then Exit(Feed);
  raise Exception.Create('MCP first-use check requested unrelated component: '+URL);
end;

function TMCPPackageForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin
  var Worker:=TMCPPackageWorker.Create(Window,THTTPClient.Create);
  Worker.Metadata:=Metadata; Worker.Feed:=Feed; Result:=Worker;
end;

function TMCPPackageForm.CreateDownloadWorker(Window: HWND; const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
begin
  DownloadID:=Info.ComponentID;
  raise Exception.Create('OWN_MCP_DOWNLOAD_OBSERVED');
end;

procedure TestMCPFirstUse(const Metadata, Feed: string);
var Dialog: TMCPPackageForm; Prompt: TForm;
  View: TListView; Started: UInt64; Observed: Boolean;
  procedure WaitCheck;
  begin
    Started:=GetTickCount64;
    while not (Dialog.FindComponent('UpdateCheckComponents') as TButton).Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<10000,'MCP first-use check did not finish');
    end;
    Application.ProcessMessages;
  end;
begin
  Require(ComponentNeedsRepair(Settings.AppPath,'MHLMcpServer'),'First-use fixture already has MCP');
  Dialog:=TMCPPackageForm.Create(nil);
  try
    Dialog.Metadata:=Metadata; Dialog.Feed:=Feed;
    View:=Dialog.FindComponent('UpdateComponents') as TListView;
    for var Item in View.Items do
      Require(not string(Item.Caption).Contains('AI-ассистента'),'Absent MCP appeared during ordinary component checks');
    Dialog.RequestComponent('MHLMcpServer','Подключение только по запросу.',True);
    WaitCheck;
    Prompt:=Dialog.FindComponent('OptionalComponentPrompt') as TForm;
    Require(Assigned(Prompt) and Prompt.Visible and not Dialog.Visible,'MCP first use did not use compact prompt');
    Require(string((Prompt.FindComponent('ComponentPromptReason') as TMemo).Text).Contains('МБ') and
      (Prompt.FindComponent('ComponentPromptDownload') as TButton).Enabled and (Dialog.DownloadID=''),
      'MCP prompt omitted download size or downloaded before a click: '+
      string((Prompt.FindComponent('ComponentPromptReason') as TMemo).Text)+'; '+
      string((Prompt.FindComponent('ComponentPromptDownload') as TButton).Caption));
    (Prompt.FindComponent('ComponentPromptCancel') as TButton).Click;
    Require(not Prompt.Visible and (Dialog.DownloadID='') and not FileExists(Settings.AppPath+'MHLMcpServer.exe'),
      'Cancelling MCP installed or downloaded it');
    Dialog.RequestComponent('MHLMcpServer','Подключение только по запросу.',True); WaitCheck;
    Require(Prompt.Visible,'MCP first-use request did not reopen after cancellation');
    Observed:=False;
    try (Prompt.FindComponent('ComponentPromptDownload') as TButton).Click;
    except on E: Exception do Observed:=E.Message='OWN_MCP_DOWNLOAD_OBSERVED'; end;
    Require(Observed and (Dialog.DownloadID='MHLMcpServer'),'MCP request queued another component');
  finally Dialog.Free; end;
  Writeln('PASS optional MCP is hidden until requested; compact prompt shows size; cancellation installs nothing'); Flush(Output);
end;

procedure TestOptionalMCPModule;
var Folder, Metadata, Feed, Archive, Job, Version, Executable: string;
  Info: TProgramRelease; Root, Server: TJSONObject; Dialog: TfrmMCPSetup;
  Memo: TMemo; CopyButton: TButton; PreviousTheme: Boolean; Reader: TfrmProgramUpdate;
begin
  RequireIsolatedRegression;
  Require(Assigned(frmMain.FindComponent('miMCPSetup')),'Explicit MCP setup menu is missing');
  Require(IsOptionalComponent('MHLMcpServer'),'MCP must remain optional');
  Require(not ComponentNotificationEnabled('MHLMcpServer',''),'MCP update notifications must start disabled');
  Require(SafeComponentFile('MHLMcpServer','MHLMcpServer.exe') and
    SafeComponentFile('MHLMcpServer','MHLMcpServer-LICENSE.txt'),'MCP package members are not allowed');
  for var Name in ['HomeLibRu.exe','HomeLibReader.exe','sqlite3.dll','Data/collections.db','../MHLMcpServer.exe'] do
    Require(not SafeComponentFile('MHLMcpServer',Name),'MCP package gained a foreign file: '+Name);
  Root:=TJSONObject.ParseJSONValue(MCPClientConfiguration('C:\Books with spaces\MHLMcpServer.exe','C:\Books\user.dbs2')) as TJSONObject;
  try
    Server:=Root.GetValue<TJSONObject>('mcpServers').GetValue<TJSONObject>('HomeLibRu');
    Require(Server.GetValue<string>('command')='C:\Books with spaces\MHLMcpServer.exe','MCP executable quoting changed its path');
    Require(Server.GetValue<TJSONArray>('args').Count=0,'Default profile gained unexpected arguments');
  finally Root.Free; end;
  Root:=TJSONObject.ParseJSONValue(MCPClientConfiguration('C:\Книги\MHLMcpServer.exe','C:\Книги\Рабочая библиотека.dbs')) as TJSONObject;
  try
    var Arguments:=Root.GetValue<TJSONObject>('mcpServers').GetValue<TJSONObject>('HomeLibRu').GetValue<TJSONArray>('args');
    Require((Arguments.Count=2) and (Arguments[0].Value='user') and
      (Arguments[1].Value='Рабочая библиотека'),'Custom MCP profile was lost');
  finally Root.Free; end;
  PreviousTheme:=MHLThemeDark;
  try
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark);
      for var PPI in [96,144,192] do
      begin
        Dialog:=TfrmMCPSetup.CreateForProfile(nil,Settings.AppPath+'MHLMcpServer.exe',Settings.SystemFileName[sfSystemDB]);
        try
          Dialog.ScaleForPPI(PPI); Dialog.Show; Application.ProcessMessages;
          Memo:=Dialog.FindComponent('MCPConfiguration') as TMemo;
          CopyButton:=Dialog.FindComponent('MCPCopyConfiguration') as TButton;
          Require(Memo.ReadOnly and (Memo.Height>MulDiv(100,PPI,96)),'MCP configuration is not visible');
          Require((CopyButton.Left>=0) and (CopyButton.Left+CopyButton.Width<=Dialog.ClientWidth),
            Format('MCP copy action clipped at %d DPI: left=%d width=%d form=%d',
              [PPI,CopyButton.Left,CopyButton.Width,Dialog.ClientWidth]));
          Require(Pos('mcpServers',Memo.Text)>0,'MCP setup hid configuration');
        finally Dialog.Free; end;
      end;
    end;
  finally SetMHLTheme(PreviousTheme); end;
  Writeln('PASS optional MCP setup preserves default custom Unicode profiles and fits both themes at96-144-192DPI'); Flush(Output);
  Folder:=GetEnvironmentVariable('HOMELIB_MCP_COMPONENT_PACKAGES');
  Require(Folder<>'','MCP check requires the actual packaged server');
  Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
  Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
  TestMCPFirstUse(Metadata,Feed);
  Require(ParseComponentMirror(Metadata,Feed,'MHLMcpServer','',Info),'MCP feed entry rejected');
  Version:=Info.ComponentVersion; Archive:=TPath.Combine(Folder,ComponentVersionedArchiveName('MHLMcpServer',Version,ProgramUpdatePlatform));
  Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-optional-mcp');
  Executable:=TPath.Combine(Settings.AppPath,'MHLMcpServer.exe');
  try
    PrepareProgramUpdate(Archive,Info.SHA256,Info.Tag,ProgramUpdatePlatform,Job,True,'MHLMcpServer',Version);
    VerifyPreparedProgramUpdate(Job,Info.Tag,ProgramUpdatePlatform);
    TFile.WriteAllText(Settings.AppPath+'HomeLibRu.exe','unchanged catalogue sentinel');
    InstallProgramUpdate(Job,Settings.AppPath);
    Require(not ComponentNeedsRepair(Settings.AppPath,'MHLMcpServer'),'Installed MCP package is incomplete');
    Require(TFile.ReadAllText(Settings.AppPath+'HomeLibRu.exe')='unchanged catalogue sentinel','MCP package replaced catalogue');
    Require(UpdateSHA256(Executable)=UpdateSHA256(TPath.Combine(Job,'payload/MHLMcpServer.exe')),'MCP executable bytes changed');
    // Older core archives already supplied this server without separate notes.
    TFile.Move(Settings.AppPath+'MHLMcpServer-LICENSE.txt',Settings.AppPath+'mcp-license-stored.txt');
    Require(not ComponentNeedsRepair(Settings.AppPath,'MHLMcpServer'),'Missing optional notes blocked an existing executable');
    Reader:=TfrmProgramUpdate.Create(nil);
    try
      Reader.UseReaderComponents;
      for var Item in (Reader.FindComponent('UpdateComponents') as TListView).Items do
        Require(not string(Item.Caption).Contains('AI-ассистента'),'Standalone reader listed catalogue MCP');
      Reader.RequestComponent('MHLMcpServer','',True);
      Require(not Assigned(Reader.FindComponent('OptionalComponentPrompt')),'Standalone reader offered catalogue MCP');
    finally Reader.Free; end;
    Writeln('PASS optional MCP actual package verifies architecture version restricted files and preserves existing catalogue'); Flush(Output);
  finally CleanProgramUpdate(Job); end;
end;
