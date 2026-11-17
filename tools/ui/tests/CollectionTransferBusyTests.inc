type
  TTransferBusyProbe=class
    Timer:TTimer;
    Opened,Refused:Boolean;
    Failure:string;
    procedure Tick(Sender:TObject);
    procedure Invoke(ExpectWindow:Boolean);
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

procedure TTransferBusyProbe.Invoke(ExpectWindow:Boolean);
begin
  Opened:=False; Refused:=False; Failure:=''; Timer.Enabled:=True;
  Writeln('TRACE transfer busy expect window=',Ord(ExpectWindow)); Flush(Output);
  try
    var Menu:=frmMain.FindComponent('miTransferCollection') as TMenuItem;
    Require(Assigned(Menu),'Ordinary collection transfer command is absent'); Menu.Click;
  finally Timer.Enabled:=False; end;
  Require(Failure='',Failure);
  Require((Opened=ExpectWindow) and (Refused<>ExpectWindow),
    Format('Transfer availability differs: expect window=%d opened=%d refused=%d',
      [Ord(ExpectWindow),Ord(Opened),Ord(Refused)]));
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
