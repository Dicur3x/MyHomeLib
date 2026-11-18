type
  TTransferBusyProbe=class
    Timer:TTimer;
    Opened,Refused:Boolean;
    Failure:string;
    procedure Tick(Sender:TObject);
    procedure Invoke(ExpectWindow:Boolean; const StatusPrefix:string='');
  end;

procedure TTransferBusyProbe.Tick(Sender:TObject);
var Dialog:HWND; PID:Cardinal; Text:array[0..2047] of Char;
begin
  Dialog:=FindWindow('#32770','Перенос файлов коллекции'); PID:=0;
  if Dialog<>0 then GetWindowThreadProcessId(Dialog,@PID);
  if (Dialog<>0) and (PID=GetCurrentProcessId) then
  begin
    Text[0]:=#0;
    GetDlgItemText(Dialog,$FFFF,Text,Length(Text));
    Refused:=string(PChar(@Text[0])).Contains('Закройте читалки, открытые из HomeLibre');
    if not Refused then Failure:='Unexpected transfer refusal: '+string(PChar(@Text[0]));
    // Do not depend on activation of a hidden regression host or enter the
    // native modal loop again synchronously from its timer callback.
    Timer.Enabled:=False;
    if GetEnvironmentVariable('HL_TRANSFER_BUSY_MANUAL')<>'1' then
      PostMessage(Dialog,WM_CLOSE,0,0);
    Exit;
  end;
  for var I:=Screen.FormCount-1 downto 0 do
    if Screen.Forms[I].Visible and (Screen.Forms[I].Name='CollectionTransferWindow') then
    begin
      Opened:=True;
      TButton(Screen.Forms[I].FindComponent('CloseCollectionTransfer')).Click; Exit;
    end;
end;

procedure TTransferBusyProbe.Invoke(ExpectWindow:Boolean; const StatusPrefix:string);
begin
  Opened:=False; Refused:=False; Failure:=''; Timer.Enabled:=True;
  if StatusPrefix<>'' then frmMain.StatusMessage:='Owned transfer guard sentinel';
  Writeln('TRACE transfer busy expect window=',Ord(ExpectWindow)); Flush(Output);
  try
    var Menu:=frmMain.FindComponent('miTransferCollection') as TMenuItem;
    Require(Assigned(Menu),'Ordinary collection transfer command is absent'); Menu.Click;
  finally Timer.Enabled:=False; end;
  if StatusPrefix<>'' then Refused:=frmMain.StatusMessage.StartsWith(StatusPrefix);
  Require(Failure='',Failure);
  Require((Opened=ExpectWindow) and (Refused<>ExpectWindow),
    Format('Transfer availability differs: expect window=%d opened=%d refused=%d',
      [Ord(ExpectWindow),Ord(Opened),Ord(Refused)]));
end;

procedure VerifyTransferJobGuard(ExpectWindow:Boolean; const Kind,Source:string;
  const StatusPrefix:string='');
var Probe:TTransferBusyProbe; Catalogue,Personal:TSQLiteDatabase;
  Rows,PersonalRows,SourceHash:string;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Job guard fixture requires G:');
  Catalogue:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Settings.ActiveCollection).DBFileName);
  Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
  Probe:=TTransferBusyProbe.Create; Probe.Timer:=TTimer.Create(nil);
  Probe.Timer.Enabled:=False; Probe.Timer.Interval:=20; Probe.Timer.OnTimer:=Probe.Tick;
  try
    Rows:=ReaderAllCatalogRows(Catalogue); PersonalRows:=ReaderAllCatalogRows(Personal);
    SourceHash:=THashSHA2.GetHashStringFromFile(Source);
    Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=0,
      'Job guard started with a registered transfer');
    Probe.Invoke(ExpectWindow,StatusPrefix);
    Require(ReaderAllCatalogRows(Catalogue)=Rows,'Transfer attempt during '+Kind+' changed catalogue rows/schema');
    Require(ReaderAllCatalogRows(Personal)=PersonalRows,'Transfer attempt during '+Kind+' changed personal rows/schema');
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Transfer attempt during '+Kind+' changed protected input');
    Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=0,
      'Transfer attempt during '+Kind+' registered an operation');
    Writeln('PASS transfer job guard ',Kind,' available=',Ord(ExpectWindow),
      ' preserves catalogue personal rows protected input and registry'); Flush(Output);
  finally Probe.Timer.Free; Probe.Free; Personal.Free; Catalogue.Free; end;
end;

type
  TTransferDownloadFixture=class
    Entered,Release:TEvent;
    Body:string;
    procedure Command(Context:TIdContext; Request:TIdHTTPRequestInfo; Response:TIdHTTPResponseInfo);
  end;

procedure TTransferDownloadFixture.Command(Context:TIdContext; Request:TIdHTTPRequestInfo;
  Response:TIdHTTPResponseInfo);
begin
  Entered.SetEvent;
  if Release.WaitFor(30000)<>wrSignaled then begin Response.ResponseNo:=503; Exit; end;
  Response.ResponseNo:=200; Response.ContentType:='application/octet-stream';
  Response.CustomHeaders.Values['Content-Disposition']:='attachment; filename="download.fb2"';
  Response.ContentStream:=TBytesStream.Create(TEncoding.UTF8.GetBytes(Body));
  Response.FreeContentStream:=True;
end;

procedure TestTransferDownloadLifetime(Target:IBookCollection);
var Fixture:TTransferDownloadFixture; HTTP:TIdHTTPServer; Online:IBookCollection;
  CID,BID:Integer; Node:PVirtualNode; Data:PDownloadData; Book:TBookRecord;
  Source:string; Deadline:UInt64;
begin
  RequireIsolatedRegression;
  var Choice:=TMenuItem.Create(nil);
  try Choice.Tag:=Target.CollectionID; frmMain.miActiveCollectionClick(Choice); finally Choice.Free; end;
  Deadline:=GetTickCount64+20000;
  while frmMain.tvBooksA.GetFirst=nil do
  begin
    Require(GetTickCount64<Deadline,'Local transfer fixture did not finish loading');
    Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
  end;
  Source:=Settings.AppPath+'transfer-download-protected.fb2';
  TFile.WriteAllText(Source,'Protected transfer input',TEncoding.UTF8);
  VerifyTransferJobGuard(True,'before-download',Source);
  Fixture:=TTransferDownloadFixture.Create; HTTP:=nil;
  Fixture.Entered:=TEvent.Create(nil,True,False,''); Fixture.Release:=TEvent.Create(nil,True,False,'');
  Fixture.Body:='<?xml version="1.0" encoding="utf-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<author><first-name>Owned</first-name><last-name>Download</last-name></author>'+
    '<book-title>Owned download</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Real loopback download preserved exactly.</p></section></body></FictionBook>';
  try
    HTTP:=TIdHTTPServer.Create(nil); HTTP.OnCommandGet:=Fixture.Command;
    HTTP.Bindings.Add.IP:='127.0.0.1'; HTTP.Bindings[0].Port:=0; HTTP.Active:=True;
    CID:=SystemDB.CreateCollection('Owned transfer download',Settings.AppPath,
      'transfer-download-online.hlc2',CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
    Online:=SystemDB.GetCollection(CID);
    Online.SetProperty(PROP_URL,'http://127.0.0.1:'+IntToStr(HTTP.Bindings[0].Port)+'/');
    Online.SetProperty(PROP_CONNECTIONSCRIPT,'GET %URL%b/%LIBID%/get'+sLineBreak+'CHECK');
    BID:=AddOnlineBook(Online,'Owned transfer download','900004',False);
    Settings.UseIESettings:=False; Settings.ProxyType:=0;
    Settings.TimeOut:=5000; Settings.ReadTimeOut:=15000; Settings.DwnldInterval:=0;
    Settings.OverwriteFB2Info:=False; Settings.ConvertWebPToPNG:=False;
    frmMain.tvDownloadList.Clear;
    Node:=frmMain.tvDownloadList.AddChild(nil); Data:=frmMain.tvDownloadList.GetNodeData(Node);
    Data^:=Default(TDownloadData); Data^.BookKey:=CreateBookKey(BID,CID);
    Data^.Title:='Owned transfer download'; Data^.Author:='Owned Download'; Data^.State:=dsWait;
    Online.GetBookRecord(Data^.BookKey,Book,False);
    Data^.HasExpectedIdentity:=True; Data^.ExpectedLibID:=Book.LibID;
    Data^.ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Book);
    frmMain.btnStartDownloadClick(nil);
    Deadline:=GetTickCount64+15000;
    while Fixture.Entered.WaitFor(0)<>wrSignaled do
    begin
      Require(GetTickCount64<Deadline,'Real download did not reach loopback response');
      Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    end;
    Require(frmMain.btnPauseDownload.Enabled,'Real download was not running');
    VerifyTransferJobGuard(False,'active-download',Source);
    Require(Fixture.Release.WaitFor(0)<>wrSignaled,'Transfer released the held download');
    Fixture.Release.SetEvent; Deadline:=GetTickCount64+15000;
    while (frmMain.tvDownloadList.GetFirst<>nil) or not frmMain.btnStartDownload.Enabled do
    begin
      Require(GetTickCount64<Deadline,'Actual queue did not finish its released download');
      Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    end;
    // Queue completion is announced before Execute returns. Give its tiny
    // private cache cleanup time to finish; the production guard itself uses
    // the thread lifetime and must not rely on the toolbar's earlier state.
    Deadline:=GetTickCount64+750;
    while GetTickCount64<Deadline do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Online.GetBookRecord(CreateBookKey(BID,CID),Book,False);
    Require((bpIsLocal in Book.BookProps) and FileExists(Book.GetBookFileName),
      'Completed real queue did not publish its local book');
    Require(TFile.ReadAllText(Book.GetBookFileName,TEncoding.UTF8)=Fixture.Body,
      'Downloaded book differs from the served fixture');
    VerifyTransferJobGuard(True,'completed-download',Source);
    Writeln('PASS completed real download retains its manager without permanently blocking transfer'); Flush(Output);
  finally
    Fixture.Release.SetEvent;
    Deadline:=GetTickCount64+1500;
    while GetTickCount64<Deadline do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    HTTP.Free; Fixture.Release.Free; Fixture.Entered.Free; Fixture.Free;
  end;
end;

procedure TestTransferBusyReaders(Target:IBookCollection; SeedID:Integer);
var Probe:TTransferBusyProbe; Host:TfrmReaderHost; Request:TReaderSessionRequest;
  Book:TBookRecord; Reply:TReaderSessionReply; Completed:Boolean;
  Source,ReleaseFile,OriginalMode,OriginalRelease,SourceHash,Rows,PersonalRows:string;
  Catalogue,Personal:TSQLiteDatabase;
  procedure Unchanged;
  begin
    Require(ReaderAllCatalogRows(Catalogue)=Rows,'Busy transfer changed catalogue rows/schema');
    Require(ReaderAllCatalogRows(Personal)=PersonalRows,'Busy transfer changed personal rows/schema');
    Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=0,
      'Busy transfer registered an operation');
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Busy transfer changed the reader input');
  end;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Transfer busy fixture requires G:');
  var Choice:=TMenuItem.Create(nil);
  try Choice.Tag:=Target.CollectionID; frmMain.miActiveCollectionClick(Choice); finally Choice.Free; end;
  var Deadline:=GetTickCount64+20000;
  while (frmMain.tvBooksA.GetFirst=nil) and (GetTickCount64<Deadline) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  Source:=Settings.AppPath+'transfer-reader-busy.fb2'; ReleaseFile:=Settings.AppPath+'transfer-reader-release.marker';
  TFile.WriteAllText(Source,'<FictionBook><body><section><p>Unchanged reader source</p></section></body></FictionBook>',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(Source);
  Probe:=TTransferBusyProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=20; Probe.Timer.OnTimer:=Probe.Tick;
  Catalogue:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(Target.CollectionID).DBFileName);
  Personal:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]); Host:=nil;
  OriginalMode:=GetEnvironmentVariable('HLRU_SESSION_TEST_MODE');
  OriginalRelease:=GetEnvironmentVariable('HLRU_TRANSFER_READER_RELEASE'); Completed:=False;
  try
    // A positive entry first proves a later refusal is not just startup loading.
    Probe.Invoke(True); Rows:=ReaderAllCatalogRows(Catalogue); PersonalRows:=ReaderAllCatalogRows(Personal);
    Target.GetBookRecord(CreateBookKey(SeedID,Target.CollectionID),Book,False);
    Book.CollectionRoot:=Settings.AppPath; Book.Folder:='';
    Book.FileName:='transfer-reader-busy'; Book.FileExt:='.fb2';
    Request:=CreateReaderSession(Settings.AppPath,Book,'transfer-busy',Settings.AppPath+'busy-reader.ini',True);
    SetEnvironmentVariable('HLRU_SESSION_TEST_MODE','transfer-hold');
    SetEnvironmentVariable('HLRU_TRANSFER_READER_RELEASE',PChar(ReleaseFile));
    LaunchReaderSession(frmMain,ParamStr(0),Settings.AppPath+'busy-reader-profile',Request,
      procedure(Value:TReaderSessionReply) begin Reply:=Value; Completed:=True; end);
    Require(ReaderSessionRunnersPending(frmMain),'Real independent reader was not tracked');
    Writeln('TRACE transfer refusal while independent reader is tracked'); Flush(Output);
    Probe.Invoke(False); Unchanged;
    Require(ReaderSessionRunnersPending(frmMain) and not Completed,'Transfer closed the independent reader');
    TFile.WriteAllText(ReleaseFile,'release',TEncoding.UTF8); Deadline:=GetTickCount64+20000;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    until Completed or (GetTickCount64>=Deadline);
    Require(Completed and (Reply.State='closed') and (Reply.Progress=42) and
      not ReaderSessionRunnersPending(frmMain),'Independent reader did not close normally');
    Unchanged; Probe.Invoke(True); Unchanged;
    Writeln('PASS ordinary transfer refuses a tracked live reader without closing it or changing catalogue personal rows source or registry; reopens after reader exit');
    Host:=TfrmReaderHost.Create(frmMain);
    Writeln('TRACE transfer refusal while built-in host exists'); Flush(Output);
    Probe.Invoke(False); Unchanged;
    Require(Assigned(Host) and not (csDestroying in Host.ComponentState),'Transfer destroyed the reader host');
    FreeAndNil(Host); Probe.Invoke(True); Unchanged;
    Writeln('PASS ordinary transfer refuses a built-in reader host and becomes available after explicit host close');
  finally
    Host.Free;
    if ReaderSessionRunnersPending(frmMain) then
    begin
      TFile.WriteAllText(ReleaseFile,'release',TEncoding.UTF8); Deadline:=GetTickCount64+20000;
      while ReaderSessionRunnersPending(frmMain) and (GetTickCount64<Deadline) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
      Require(not ReaderSessionRunnersPending(frmMain),'Busy test left a reader process monitor');
    end;
    SetEnvironmentVariable('HLRU_SESSION_TEST_MODE',PChar(OriginalMode));
    SetEnvironmentVariable('HLRU_TRANSFER_READER_RELEASE',PChar(OriginalRelease));
    Personal.Free; Catalogue.Free; Probe.Timer.Free; Probe.Free;
  end;
end;
