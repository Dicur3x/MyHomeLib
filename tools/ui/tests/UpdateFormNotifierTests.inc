// Actual updater form owns real worker descendants; only their transport maps
// the unchanged official requests to this fixture's paused loopback server.
// Extra DPR uses: existing System.Net.HttpClient / Indy units; include after MainLiveInputFavoriteTests.
type
  TUFNServer = class
  private
    HTTP: TIdHTTPServer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  public
    Requested, Released: TEvent;
    Originals, TransportTrace: TStringList;
    Payload: TBytes;
    URL, Failure: string;
    FailChecks: Boolean;
    Requests, CreatedWorkers, FreedWorkers: Integer;
    constructor Create;
    destructor Destroy; override;
    function TextURL(const Official: string): string;
    function HeadURL(const Official: string): string;
  end;

  TUFNComponentWorker = class(TComponentUpdateThread)
  private
    FServer: TUFNServer;
  protected
    function FetchText(const URL: string): string; override;
    function FetchHead(const URL: string): IHTTPResponse; override;
  public
    constructor Create(Window: HWND; Server: TUFNServer);
    destructor Destroy; override;
  end;

  TUFNDownloadWorker = class(TProgramDownloadThread)
  private
    FServer: TUFNServer;
  protected
    function FetchDownload(const URL: string; Content: TStream): IHTTPResponse; override;
  public
    constructor Create(Window: HWND; const ReleaseInfo: TProgramRelease; const Job: string; Server: TUFNServer);
    destructor Destroy; override;
  end;

  TUFNForm = class(TfrmProgramUpdate)
  private
    FServer: TUFNServer;
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
      const Job: string): TProgramDownloadThread; override;
  public
    Notifier: HWND;
    constructor CreateForServer(Server: TUFNServer);
    procedure RecreateActualWindow;
  end;

  TUFNPrestartProbe = class
  public
    Original: TWndMethod;
    Calls: Integer;
    procedure WindowMessage(var Message: TMessage);
  end;

  TUFNProbe = class
  public
    InitialWindow, Notifier: HWND;
    Destroyed, Checked, Progress, Completed: Integer;
  end;

var UFNProbe: TUFNProbe; UFNQueueHook, UFNWindowHook: HHOOK;

function UFNMessageObserver(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var Item: PMsg;
begin
  if (Code>=0) and (WParam=PM_REMOVE) and Assigned(UFNProbe) then
  begin
    Item:=PMsg(LParam);
    if Item.hwnd=UFNProbe.Notifier then
      case Item.message of
        WM_COMPONENT_UPDATE_CHECKED: Inc(UFNProbe.Checked);
        WM_PROGRAM_UPDATE_PROGRESS: Inc(UFNProbe.Progress);
        WM_PROGRAM_UPDATE_DOWNLOADED: Inc(UFNProbe.Completed);
      end;
  end;
  Result:=CallNextHookEx(UFNQueueHook,Code,WParam,LParam);
end;

function UFNWindowObserver(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  if (Code=HCBT_DESTROYWND) and Assigned(UFNProbe) and (HWND(WParam)=UFNProbe.InitialWindow) then
    Inc(UFNProbe.Destroyed);
  Result:=CallNextHookEx(UFNWindowHook,Code,WParam,LParam);
end;

procedure TUFNPrestartProbe.WindowMessage(var Message: TMessage);
begin
  // CheckComponents assigns the real Create(True) factory result before it
  // disables this button and updates the UI, then calls Start afterwards.
  if (Message.Msg=CM_ENABLEDCHANGED) and (Calls=0) then
  begin Inc(Calls); raise Exception.Create('OWN_UPDATER_PRESTART_UI_FAILURE'); end;
  Original(Message);
end;

constructor TUFNServer.Create;
begin
  inherited;
  Requested:=TEvent.Create(nil,True,False,''); Released:=TEvent.Create(nil,True,False,'');
  Originals:=TStringList.Create; TransportTrace:=TStringList.Create; Payload:=TEncoding.UTF8.GetBytes(StringOfChar('x',65536));
  HTTP:=TIdHTTPServer.Create(nil); HTTP.KeepAlive:=False; HTTP.MaxConnections:=2;
  HTTP.OnCommandGet:=Command; HTTP.OnCommandOther:=Command;
  HTTP.Bindings.Clear;
  with HTTP.Bindings.Add do begin IP:='127.0.0.1'; Port:=0; end;
  HTTP.Active:=True; URL:=Format('http://127.0.0.1:%d/',[HTTP.Bindings[0].Port]);
  Require(HTTP.Bindings[0].Port>0,'Updater notifier fixture did not acquire an owned loopback port');
end;

destructor TUFNServer.Destroy;
begin
  if Assigned(Released) then Released.SetEvent;
  if Assigned(HTTP) then begin HTTP.Active:=False; HTTP.Free; end;
  Originals.Free; TransportTrace.Free; Requested.Free; Released.Free; inherited;
end;

function TUFNServer.TextURL(const Official: string): string;
begin
  if Originals.Count>=64 then raise Exception.Create('Updater fixture exceeded its bounded request log');
  Originals.Add(Official);
  if Official=PROGRAM_RELEASES_API then Exit(URL+'empty-releases');
  if Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/index.json' then Exit(URL+'doc-index');
  if Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/index.json' then Exit(URL+'common-index');
  if (Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.ppt/index.json') or
    (Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.xls/index.json') then Exit(URL+'common-index');
  if Official='https://api.github.com/repos/manfromarce/DocSharp/releases?per_page=30' then Exit(URL+'notes');
  if (Official='https://www.sqlite.org/download.html') or (Official='https://www.sqlite.org/changes.html') or
    (Official='https://www.alreader.com/') or
    (Official='https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases?per_page=30') or
    (Official='https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/') or
    (Official='https://api.github.com/repos/ip7z/7zip/releases/latest') then Exit(URL+'unavailable');
  Failure:='Updater fixture refused an unexpected official route: '+Official; raise Exception.Create(Failure);
end;

function TUFNServer.HeadURL(const Official: string): string;
begin
  if Originals.Count>=64 then raise Exception.Create('Updater fixture exceeded its bounded request log');
  Originals.Add(Official);
  if Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/0.99.0/docsharp.binary.doc.0.99.0.nupkg' then Exit(URL+'head-doc');
  if Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/0.99.0/docsharp.binary.common.0.99.0.nupkg' then Exit(URL+'head-common');
  if (Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.ppt/0.99.0/docsharp.binary.ppt.0.99.0.nupkg') or
    (Official='https://api.nuget.org/v3-flatcontainer/docsharp.binary.xls/0.99.0/docsharp.binary.xls.0.99.0.nupkg') then Exit(URL+'head-common');
  Failure:='Updater fixture refused an unexpected official HEAD route: '+Official; raise Exception.Create(Failure);
end;

procedure TUFNServer.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
var Body: TMemoryStream;
begin
  InterlockedIncrement(Requests); Requested.SetEvent;
  if Released.WaitFor(10000)<>wrSignaled then
  begin Failure:='Owned loopback response was never released'; Response.ResponseNo:=408; Exit; end;
  if Request.Document='/download' then
  begin
    Body:=TMemoryStream.Create;
    try
      Body.WriteBuffer(Payload[0],Length(Payload)); Body.Position:=0;
      Response.ContentType:='application/zip'; Response.ContentStream:=Body; Response.FreeContentStream:=True; Body:=nil;
    finally Body.Free; end;
  end
  else if FailChecks or (Request.Document='/unavailable') then
  begin Response.ResponseNo:=503; Response.ContentText:='Owned unavailable author response'; end
  else if (Request.Document='/doc-index') or (Request.Document='/common-index') then
  begin Response.ContentType:='application/json; charset=utf-8'; Response.ContentText:='{"versions":["0.99.0"]}'; end
  else if (Request.Document='/notes') or (Request.Document='/empty-releases') then
  begin Response.ContentType:='application/json'; Response.ContentText:='[]'; end
  else if (Request.Document='/head-doc') or (Request.Document='/head-common') then
  begin Response.ContentType:='application/octet-stream'; Response.ContentText:=StringOfChar('n',64); Response.ContentLength:=64; end
  else
  begin Failure:='Unexpected owned loopback route: '+Request.Document; Response.ResponseNo:=404; end;
end;

constructor TUFNComponentWorker.Create(Window: HWND; Server: TUFNServer);
begin
  inherited Create(Window,THTTPClient.Create,PROGRAM_RELEASES_API,''); FServer:=Server;
  InterlockedIncrement(Server.CreatedWorkers);
end;

destructor TUFNComponentWorker.Destroy;
var Server: TUFNServer;
begin Server:=FServer; inherited; InterlockedIncrement(Server.FreedWorkers); end;

function TUFNComponentWorker.FetchText(const URL: string): string;
begin
  try
    Result:=inherited FetchText(FServer.TextURL(URL));
    if FServer.TransportTrace.Count<64 then
      FServer.TransportTrace.Add('GET '+URL+' chars='+IntToStr(Length(Result))+' body='+Copy(Result,1,200));
  except
    on E: Exception do
    begin
      if FServer.TransportTrace.Count<64 then
        FServer.TransportTrace.Add('GET '+URL+' '+E.ClassName+': '+Copy(E.Message,1,300));
      raise;
    end;
  end;
end;

function TUFNComponentWorker.FetchHead(const URL: string): IHTTPResponse;
begin
  try
    Result:=inherited FetchHead(FServer.HeadURL(URL));
    if FServer.TransportTrace.Count<64 then
      FServer.TransportTrace.Add('HEAD '+URL+' status='+IntToStr(Result.StatusCode)+' bytes='+IntToStr(Result.ContentLength));
  except
    on E: Exception do
    begin
      if FServer.TransportTrace.Count<64 then
        FServer.TransportTrace.Add('HEAD '+URL+' '+E.ClassName+': '+Copy(E.Message,1,300));
      raise;
    end;
  end;
end;

constructor TUFNDownloadWorker.Create(Window: HWND; const ReleaseInfo: TProgramRelease;
  const Job: string; Server: TUFNServer);
begin
  inherited Create(Window,THTTPClient.Create,ReleaseInfo,Job); FServer:=Server;
  InterlockedIncrement(Server.CreatedWorkers);
end;

destructor TUFNDownloadWorker.Destroy;
var Server: TUFNServer;
begin Server:=FServer; inherited; InterlockedIncrement(Server.FreedWorkers); end;

function TUFNDownloadWorker.FetchDownload(const URL: string; Content: TStream): IHTTPResponse;
begin
  if not URL.StartsWith(FServer.URL) then raise Exception.Create('Download fixture refused a non-owned release URL');
  Result:=inherited FetchDownload(FServer.URL+'download',Content);
end;

constructor TUFNForm.CreateForServer(Server: TUFNServer);
begin
  FServer:=Server; inherited Create(nil); Caption:='Обновление HomeLib Ru — тестовые данные notifier';
end;

function TUFNForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin Notifier:=Window; Result:=TUFNComponentWorker.Create(Window,FServer); end;

function TUFNForm.CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
  const Job: string): TProgramDownloadThread;
begin Notifier:=Window; Result:=TUFNDownloadWorker.Create(Window,ReleaseInfo,Job,FServer); end;

procedure TUFNForm.RecreateActualWindow;
begin RecreateWnd; end;

procedure TestUpdateFormNotifier;
var Dialog: TUFNForm; Server: TUFNServer; Probe: TUFNProbe;
  CheckButton, Primary, Later: TButton; View: TListView; Status: TLabel; Progress: TProgressBar;
  OriginalTheme: Boolean; CatalogBefore, SourceHash: string; Notifier: HWND; Started: UInt64;
  ReleaseInfo: TProgramRelease; ReleaseThread: TThread; OriginalForms: Integer;
  Prestart: TUFNPrestartProbe; CaughtPrestart: Boolean; CardsBefore: string;
  SavedLocalAppData, OwnedLocalAppData: string; HadLocalAppData, Restored: Boolean;
  OldEnvLength: DWORD; EmptyEnvValue: WideChar;

  function ReadCards: string;
  var Database: TSQLiteDatabase; Query: TSQLiteQuery; TableName, Value: string; I: Integer;
  begin
    Result:=''; Database:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try
      for TableName in TArray<string>.Create('Books','BookGroups','Groups') do
      begin
        Query:=Database.NewQuery('SELECT * FROM "'+TableName+'" ORDER BY rowid');
        try
          Query.Open; Result:=Result+TableName+#10;
          while not Query.Eof do
          begin
            for I:=0 to Query.ColCount-1 do
            begin Value:=Query.FieldAsString(I); Result:=Result+IntToStr(Length(Value))+':'+Value; end;
            Result:=Result+#10; Query.Next;
          end;
        finally Query.Free; end;
      end;
    finally Database.Free; end;
  end;

  procedure Controls;
  begin
    CheckButton:=nil; Primary:=nil; Later:=nil; View:=nil; Status:=nil; Progress:=nil;
    for var Component in Dialog do
    begin
      if Component is TButton then
      begin
        if TButton(Component).Caption='Проверить всё' then CheckButton:=TButton(Component);
        if TButton(Component).Default then Primary:=TButton(Component);
        if TButton(Component).Caption='Позже' then Later:=TButton(Component);
      end;
      if Component is TListView then View:=TListView(Component);
      if (Component is TLabel) and (Component.Name='UpdateStatus') then Status:=TLabel(Component);
      if Component is TProgressBar then Progress:=TProgressBar(Component);
    end;
    Require(Assigned(CheckButton) and Assigned(Primary) and Assigned(Later) and Assigned(View) and
      Assigned(Status) and Assigned(Progress),'Actual updater form controls are incomplete');
  end;

  procedure Attach;
  begin
    Probe:=TUFNProbe.Create; UFNProbe:=Probe;
    Probe.InitialWindow:=Dialog.Handle; Probe.Notifier:=Dialog.Notifier;
    Require((Probe.Notifier<>Probe.InitialWindow) and IsWindow(Probe.Notifier),
      'Actual updater worker still targets its recyclable form HWND');
    UFNQueueHook:=SetWindowsHookExW(WH_GETMESSAGE,UFNMessageObserver,0,GetCurrentThreadID);
    UFNWindowHook:=SetWindowsHookExW(WH_CBT,UFNWindowObserver,0,GetCurrentThreadID);
    Require((UFNQueueHook<>0) and (UFNWindowHook<>0),'Cannot observe own updater form lifecycle');
  end;

  procedure Detach;
  begin
    if UFNQueueHook<>0 then begin UnhookWindowsHookEx(UFNQueueHook); UFNQueueHook:=0; end;
    if UFNWindowHook<>0 then begin UnhookWindowsHookEx(UFNWindowHook); UFNWindowHook:=0; end;
    UFNProbe:=nil; FreeAndNil(Probe);
  end;

  procedure PumpUntilRequested;
  begin
    Started:=GetTickCount64;
    while Server.Requested.WaitFor(0)<>wrSignaled do
    begin
      Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
      Require(GetTickCount64-Started<10000,'Actual updater worker never requested its delayed owned transport');
    end;
  end;

  procedure PumpCheck;
  begin
    while not CheckButton.Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
      Require(GetTickCount64-Started<10000,'Actual updater component completion was lost');
    end;
    Require((Probe.Checked=1) and (Probe.Destroyed>0) and (Server.CreatedWorkers=Server.FreedWorkers) and
      (Server.Failure=''),'Actual component worker did not finish through its surviving notifier');
  end;

  procedure TraceComponentResult;
  begin
    Writeln('TRACE updater component result requests=',Server.Requests,' originals=',Server.Originals.Count,
      ' rows=',View.Items.Count,' checked=',Probe.Checked,' destroyed=',Probe.Destroyed,
      ' created=',Server.CreatedWorkers,' freed=',Server.FreedWorkers,' failure=',Copy(Server.Failure,1,400));
    for var I:=0 to Min(View.Items.Count-1,9) do
    begin
      Writeln('TRACE updater row ',I,' caption=',Copy(string(View.Items[I].Caption),1,200));
      for var J:=0 to Min(View.Items[I].SubItems.Count-1,3) do
        Writeln('TRACE updater cell ',I,',',J,' value=',Copy(View.Items[I].SubItems[J],1,300));
    end;
    for var I:=0 to Min(Server.Originals.Count-1,31) do Writeln('TRACE updater official ',I,' ',Server.Originals[I]);
    for var I:=0 to Min(Server.TransportTrace.Count-1,31) do Writeln('TRACE updater transport ',I,' ',Server.TransportTrace[I]);
    if View.Items.Count=Length(UPDATE_COMPONENTS)+1 then
    begin
      View.Selected:=View.Items[Length(UPDATE_COMPONENTS)];
      Writeln('TRACE updater selected Doc status=',Copy(string(Status.Caption),1,700));
    end;
    Flush(Output);
  end;

  procedure PumpDownload;
  begin
    while not Primary.Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
      Require(GetTickCount64-Started<10000,'Actual updater download completion was lost');
    end;
    Require((Probe.Completed=1) and (Probe.Destroyed>0) and (Server.CreatedWorkers=Server.FreedWorkers) and
      (Server.Failure='') and not Dialog.PendingInstall,
      'Actual download did not complete/cancel through its surviving notifier');
  end;

  procedure NewForm;
  begin
    Server:=TUFNServer.Create; Dialog:=TUFNForm.CreateForServer(Server);
    Dialog.Show; Application.ProcessMessages; Controls;
  end;

  procedure CloseForm;
  begin
    Notifier:=Dialog.Notifier;
    Server.Released.SetEvent; FreeAndNil(Dialog); Application.ProcessMessages;
    Require((Notifier=0) or not IsWindow(Notifier),'Updater form leaked its owned notifier');
    Require(Server.CreatedWorkers=Server.FreedWorkers,'Updater form leaked a worker after teardown');
    Require(Screen.FormCount=OriginalForms,'Updater notifier fixture left an orphan form');
    Detach; FreeAndNil(Server);
  end;

  procedure StartDownload;
  var Hash: THashSHA2;
  begin
    ReleaseInfo:=Default(TProgramRelease); ReleaseInfo.Tag:='2.7.0_pre5.999';
    ReleaseInfo.Size:=Length(Server.Payload); ReleaseInfo.DownloadURL:=Server.URL+'download';
    // Deliberately invalid ZIP bytes produce a real verification failure after
    // download progress. Existing package UI tests cover verified-ready install.
    Hash:=THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
    Hash.Update(Server.Payload); ReleaseInfo.SHA256:=Hash.HashAsString;
    ReleaseInfo.Changelog:='Owned notifier fixture'; Dialog.SetRelease(ReleaseInfo);
    Primary.Click; Require(not Primary.Enabled,'Actual updater did not start its download');
    Attach; PumpUntilRequested;
    Dialog.RecreateActualWindow; Require(Probe.Destroyed>0,'Actual updater download HWND was not recreated');
  end;

begin
  RequireIsolatedRegression; OriginalForms:=Screen.FormCount;
  OriginalTheme:=MHLThemeDark; CatalogBefore:=MLIReadCatalogData(Settings.ActiveCollection); CardsBefore:=ReadCards;
  SourceHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll');
  Dialog:=nil; Server:=nil; Probe:=nil; ReleaseThread:=nil;
  SavedLocalAppData:=GetEnvironmentVariable('LOCALAPPDATA');
  SetLastError(ERROR_SUCCESS);
  OldEnvLength:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
  HadLocalAppData:=(OldEnvLength<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND);
  OwnedLocalAppData:=TPath.Combine(Settings.AppPath,'owned-updater-local-appdata');
  ForceDirectories(OwnedLocalAppData);
  if not SetEnvironmentVariableW('LOCALAPPDATA',PChar(OwnedLocalAppData)) then RaiseLastOSError;
  try
    Require(ProgramUpdateCache(Settings.AppPath).StartsWith(IncludeTrailingPathDelimiter(OwnedLocalAppData),True),
      'Updater fixture cache is outside its owned process-local directory');
    NewForm;
    Dialog.CheckComponents(False); Require(not CheckButton.Enabled,'Actual component worker did not start');
    Attach; PumpUntilRequested; Dialog.RecreateActualWindow;
    Server.Released.SetEvent; PumpCheck; TraceComponentResult;
    Require((View.Items.Count=Length(UPDATE_COMPONENTS)+1) and (View.Items[6].SubItems[1]='0.99.0') and
      (View.Items[6].SubItems[2]<>'Не удалось проверить'),
      'Actual successful DocSharp metadata check did not reach its form');
    Writeln('PASS updater component check actual success survives form HWND recreation with owned loopback transport'); Flush(Output);
    CloseForm;

    NewForm; Server.FailChecks:=True;
    Dialog.CheckComponents(False); Attach; PumpUntilRequested; Dialog.RecreateActualWindow;
    Server.Released.SetEvent; PumpCheck;
    for var I in CheckedComponentIndices do
      Require(View.Items[I+1].SubItems[2]='Не удалось проверить','Unavailable author response falsely marked its component checked');
    Writeln('PASS updater component check actual failures release checking state after form HWND recreation'); Flush(Output);
    CloseForm;

    NewForm;
    Prestart:=TUFNPrestartProbe.Create;
    try
      Prestart.Original:=CheckButton.WindowProc; CheckButton.WindowProc:=Prestart.WindowMessage;
      CaughtPrestart:=False;
      try Dialog.CheckComponents(False);
      except
        on E: Exception do
          if E.Message='OWN_UPDATER_PRESTART_UI_FAILURE' then CaughtPrestart:=True else raise;
      end;
      CheckButton.WindowProc:=Prestart.Original;
      Require(CaughtPrestart and (Prestart.Calls=1) and (Server.CreatedWorkers=1) and
        (Server.FreedWorkers=0) and (Server.Requests=0),
        'Controlled updater failure did not leave its real factory-owned worker before Start');
      Notifier:=Dialog.Notifier;
      FreeAndNil(Dialog); Application.ProcessMessages;
      Require((Server.Requests=0) and (Server.CreatedWorkers=Server.FreedWorkers) and not IsWindow(Notifier) and
        (Screen.FormCount=OriginalForms),
        'Canceled suspended worker did not join without HTTP before notifier teardown');
      Detach; FreeAndNil(Server);
      Writeln('PASS updater pre-Start UI failure frees its real canceled suspended worker without waiting forever or making HTTP requests'); Flush(Output);
    finally
      if Assigned(Dialog) then CheckButton.WindowProc:=Prestart.Original;
      Prestart.Free;
    end;

    NewForm;
    Dialog.CheckComponents(False); Attach; PumpUntilRequested; Dialog.RecreateActualWindow;
    ReleaseThread:=TThread.CreateAnonymousThread(procedure begin TThread.Sleep(100); Server.Released.SetEvent; end);
    ReleaseThread.FreeOnTerminate:=False; ReleaseThread.Start;
    Notifier:=Dialog.Notifier; FreeAndNil(Dialog);
    ReleaseThread.WaitFor; FreeAndNil(ReleaseThread); Application.ProcessMessages;
    Require(not IsWindow(Notifier) and (Server.CreatedWorkers=Server.FreedWorkers) and
      (Screen.FormCount=OriginalForms),'In-flight component teardown did not join before notifier destruction');
    Writeln('PASS updater component in-flight teardown joins its actual worker before removing the notifier'); Flush(Output);
    Detach; FreeAndNil(Server);

    NewForm; StartDownload; Server.Released.SetEvent; PumpDownload;
    Require((Probe.Progress>0) and (Progress.Position>0) and (Primary.Caption='Повторить загрузку') and
      Later.Enabled and (Later.Caption='Позже') and (Status.Caption<>'') and CheckButton.Enabled,
      'Actual failed download lost progress or left its form controls disabled');
    Writeln('PASS updater download actual progress and verification failure survive form HWND recreation'); Flush(Output);
    CloseForm;

    NewForm; StartDownload; Later.Click;
    Require(not Later.Enabled,'Actual download cancellation was not requested');
    Server.Released.SetEvent; PumpDownload;
    Require(ContainsText(Status.Caption,'отмен') and Later.Enabled and (Later.Caption='Позже') and CheckButton.Enabled,
      'Actual canceled download retained checking/install state');
    Writeln('PASS updater download actual cancel completes through the stable form notifier'); Flush(Output);
    CloseForm;

    NewForm; StartDownload;
    // Keep the server blocked until the destructor has entered Cancel+Join.
    ReleaseThread:=TThread.CreateAnonymousThread(procedure begin TThread.Sleep(100); Server.Released.SetEvent; end);
    ReleaseThread.FreeOnTerminate:=False; ReleaseThread.Start;
    Notifier:=Dialog.Notifier; FreeAndNil(Dialog);
    ReleaseThread.WaitFor; FreeAndNil(ReleaseThread); Application.ProcessMessages;
    Require(not IsWindow(Notifier) and (Server.CreatedWorkers=Server.FreedWorkers) and
      (Screen.FormCount=OriginalForms),'In-flight updater destruction did not join the producer before notifier teardown');
    Writeln('PASS updater form in-flight teardown joins its actual download worker and removes its notifier without orphan windows'); Flush(Output);
    Detach; FreeAndNil(Server);

    Require((MLIReadCatalogData(Settings.ActiveCollection)=CatalogBefore) and (ReadCards=CardsBefore) and
      (THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll')=SourceHash) and (MHLThemeDark=OriginalTheme),
      'Updater notifier testing changed catalog/personal cards, installed component bytes or application theme');
    Writeln('PASS updater notifier lifecycle leaves catalog, personal cards and installed component source bytes unchanged'); Flush(Output);
  finally
    try
      if Assigned(Server) then Server.Released.SetEvent;
      if Assigned(Dialog) then Dialog.Free;
      if Assigned(ReleaseThread) then begin ReleaseThread.WaitFor; ReleaseThread.Free; end;
      Detach; Server.Free;
    finally
      EmptyEnvValue:=#0;
      if not HadLocalAppData then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',nil)
      else if SavedLocalAppData='' then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',@EmptyEnvValue)
      else Restored:=SetEnvironmentVariableW('LOCALAPPDATA',PChar(SavedLocalAppData));
      if not Restored then RaiseLastOSError;
      Require(GetEnvironmentVariable('LOCALAPPDATA')=SavedLocalAppData,
        'Updater fixture did not restore its original process environment value');
      SetLastError(ERROR_SUCCESS);
      OldEnvLength:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
      Require(((OldEnvLength<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND))=HadLocalAppData,
        'Updater fixture did not restore original process environment presence');
      Writeln('PASS updater fixture restores the original process-local cache environment'); Flush(Output);
    end;
  end;
end;
