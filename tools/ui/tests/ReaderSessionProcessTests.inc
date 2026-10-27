// This child entry is available only in the isolated regression executable.
// Rendering uses the same host, document and paging code as HomeLibReader.exe.
type
  TSessionRenderDriver = class
    Timer: TTimer;
    Started, PageStarted, VisibleAt: UInt64;
    Pages, InitialPosition: Integer;
    OpenMS, MaxPageMS, TotalPageMS: Int64;
    TextHash, Error: string;
    Done: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TSessionRenderDriver.Tick(Sender: TObject);
var View: TfrmBuiltinReader; Elapsed: Int64; Report: TMemIniFile;
begin
  if Done then Exit;
  View:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBuiltinReader) and Screen.Forms[I].Visible then
    begin View:=TfrmBuiltinReader(Screen.Forms[I]); Break; end;
  try
    Require(GetTickCount64-Started<20000,'Independent reader opening deadline exceeded');
    if not Assigned(View) then Exit;
    if VisibleAt=0 then VisibleAt:=GetTickCount64;
    Require(not string(View.ReaderStatus.Caption).StartsWith('Не удалось'),View.ReaderStatus.Caption);
    if not View.Ready or View.PageLoading then Exit;
    if Pages=0 then
    begin
      OpenMS:=GetTickCount64-Started; InitialPosition:=View.TextPosition;
      Require(InitialPosition=0,'Independent reader lost the original history position');
      Require(View.BookText.Length>10000,'Independent reader has no complete test book body');
      TextHash:=THashSHA2.GetHashString(View.BookText);
      Pages:=1; PageStarted:=GetTickCount64; View.NextPage; Exit;
    end;
    Elapsed:=GetTickCount64-PageStarted; MaxPageMS:=Max(MaxPageMS,Elapsed); Inc(TotalPageMS,Elapsed);
    Require(Elapsed<1500,'Independent reader page turn blocks for seconds');
    if Pages<5 then
    begin Inc(Pages); PageStarted:=GetTickCount64; View.NextPage; Exit; end;
    Require(View.TextPosition>InitialPosition,'Independent reader did not move through the text');
  except on E: Exception do Error:=E.ClassName+': '+E.Message; end;
  Done:=True; Timer.Enabled:=False;
  Report:=TMemIniFile.Create(GetEnvironmentVariable('HLRU_READER_TEST_REPORT'),TEncoding.UTF8);
  try
    Report.WriteString('Reader','run',GetEnvironmentVariable('HLRU_READER_TEST_RUN'));
    Report.WriteString('Reader','error',Error); Report.WriteString('Reader','hash',TextHash);
    if Assigned(View) then Report.WriteString('Reader','caption',View.Caption);
    Report.WriteInteger('Reader','pid',GetCurrentProcessId);
    Report.WriteInteger('Reader','pages',Pages); Report.WriteInteger('Reader','position',InitialPosition);
    Report.WriteInteger('Reader','open_ms',OpenMS);
    Report.WriteInteger('Reader','visible_ms',Int64(VisibleAt)-Int64(Started));
    Report.WriteInteger('Reader','max_page_ms',MaxPageMS); Report.WriteInteger('Reader','total_page_ms',TotalPageMS);
    SaveMemIniFileAtomically(Report);
  finally Report.Free; end;
  if Assigned(View) then View.Close;
end;

procedure RunNativeReaderSessionChild;
var Request: TReaderSessionRequest; Reply, Previous: TReaderSessionReply;
  Lease: TReaderSessionLease; Host: TfrmReaderHost; Driver: TSessionRenderDriver;
  Profile, Mode, Command: string; Startup: TStartupInfo; Process: TProcessInformation;
begin
  RequireIsolatedRegression;
  Request:=LoadReaderSession(ParamStr(1).Substring(10));
  Mode:=GetEnvironmentVariable('HLRU_SESSION_TEST_MODE');
  if Mode<>'render' then
  begin
    if Mode='crash' then Exit;
    Lease:=TReaderSessionLease.Create(Request);
    try
      Reply:=Default(TReaderSessionReply); Reply.State:='closed'; Reply.ProcessID:=GetCurrentProcessId;
      Reply.OriginProcessID:=Reply.ProcessID; Reply.HasProgress:=True; Reply.Progress:=42;
      if Mode='foreign' then begin Reply.ProcessID:=High(Cardinal); Reply.OriginProcessID:=0; end;
      if Mode='detach' then begin Sleep(1000); Reply.Progress:=73; end;
      if (Mode='restart') and (ParamStr(3)<>'--native-restarted') then
      begin
        Reply.State:='restarting'; WriteReaderSessionReply(Request,Reply); FreeAndNil(Lease);
        Command:=QuoteCommandLineArgument(ParamStr(0))+' '+QuoteCommandLineArgument(ParamStr(1))+' '+
          QuoteCommandLineArgument(ParamStr(2))+' --native-restarted'; UniqueString(Command);
        Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
        Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,0,nil,nil,Startup,Process),'Restart child failed');
        CloseHandle(Process.hThread); CloseHandle(Process.hProcess); Exit;
      end;
      if (Mode='restart') and TryReadReaderSessionReply(Request,Previous) then
        Reply.OriginProcessID:=Previous.OriginProcessID;
      WriteReaderSessionReply(Request,Reply);
    finally Lease.Free; end;
    Exit;
  end;
  Profile:=ParamStr(2).Substring(10);
  ConfigureMHLHostProfile(Profile,'HomeLibReader.ini','reader-user.dbs2');
  Application.Initialize;
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  Driver:=TSessionRenderDriver.Create; Host:=TfrmReaderHost.Create(nil);
  try
    Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=20; Driver.Timer.OnTimer:=Driver.Tick;
    Host.OpenInitialSession(Request.RequestFile); Host.Show;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(2);
    until (TryReadReaderSessionReply(Request,Reply) and ((Reply.State='closed') or (Reply.State='failed'))) or
      (GetTickCount64-Driver.Started>25000);
    Require(Driver.Done and (Driver.Error=''),'Independent rendering failed: '+Driver.Error);
  finally Driver.Timer.Free; Driver.Free; Host.Free; FreeAndNil(DMUser); end;
end;

procedure TestReaderFormatByteSignatures;
var Bytes, Header: TBytes; FileName: string; Index: Integer;
begin
  Index:=0;
  for var CaseValue in TArray<string>.Create('.fb2=<FictionBook>', '.pdf=%PDF-1.7',
    '.ibk=ICEContainer 1.0', '.sm=ASMJS[::]', '.pdb=SDocSilX') do
  begin
    Inc(Index); SetLength(Bytes,5000); FillChar(Bytes[0],Length(Bytes),$98);
    var Expected:=Copy(CaseValue,1,Pos('=',CaseValue)-1);
    Header:=TEncoding.ASCII.GetBytes(Copy(CaseValue,Pos('=',CaseValue)+1,MaxInt));
    var Offset:=0; if Expected='.pdb' then Offset:=60;
    Move(Header[0],Bytes[Offset],Length(Header));
    FileName:=TPath.Combine(Settings.AppPath,'signature-'+IntToStr(Index)+'.wrong');
    TFile.WriteAllBytes(FileName,Bytes);
    Require(DetectReaderExtension(FileName)=Expected,'Binary signature depends on the system ANSI code page '+Expected);
    if Expected='.sm' then
    begin
      Bytes[0]:=$EF; Bytes[1]:=$BB; Bytes[2]:=$BF; Move(Header[0],Bytes[3],Length(Header));
      Bytes[4098]:=$D0; // A partial UTF-8 code point at the former decode boundary.
      FileName:=TPath.Combine(Settings.AppPath,'signature-sm-bom.wrong'); TFile.WriteAllBytes(FileName,Bytes);
      Require(DetectReaderExtension(FileName)='.sm','BOM signature decoded an incomplete UTF-8 prefix');
    end;
  end;
  Writeln('PASS binary and UTF8 book signatures are independent of ANSI decoding and partial prefix characters');
end;

procedure TestReaderSessionProcess;
var Book: TBookRecord; Request: TReaderSessionRequest; Owner: TComponent;
  Reply: TReaderSessionReply; Completed: Boolean; Source, Hash: string; Started: UInt64;
begin
  RequireIsolatedRegression; TestReaderFormatByteSignatures;
  Source:=TPath.Combine(Settings.AppPath,'process-source.fb2'); TFile.WriteAllText(Source,'original source bytes');
  Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Book.CollectionRoot:=Settings.AppPath;
  Book.FileName:='process-source'; Book.FileExt:='.fb2'; Book.BookKey:=CreateBookKey(1,1); Book.Title:='Process source';
  Hash:=THashSHA2.GetHashStringFromFile(Source);
  for var Mode in TArray<string>.Create('closed','crash','foreign','restart','detach') do
  begin
    SetEnvironmentVariable('HLRU_SESSION_TEST_MODE',PChar(Mode)); Completed:=False;
    Request:=CreateReaderSession(Settings.AppPath,Book,'process-test',TPath.Combine(Settings.DataDir,'reader.ini'),True);
    Owner:=TComponent.Create(nil);
    try
      LaunchReaderSession(Owner,ParamStr(0),TPath.Combine(Settings.DataDir,'process-profile'),Request,
        procedure(Value: TReaderSessionReply) begin Reply:=Value; Completed:=True; end);
      if Mode='detach' then
      begin
        FreeAndNil(Owner); Started:=GetTickCount64;
        repeat Sleep(20); until TryReadReaderSessionReply(Request,Reply) or (GetTickCount64-Started>5000);
        Require((Reply.State='closed') and (Reply.Progress=73) and not Completed,
          'Closing the catalogue killed its reader or invoked a destroyed owner callback');
        // The reader writes before releasing its lease; wait for normal exit.
        Sleep(100); Require(RemoveReaderSessionFiles(Request),'Detached session cleanup failed');
      end
      else
      begin
        Started:=GetTickCount64;
        repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
        until Completed or (GetTickCount64-Started>8000);
        Require(Completed,'Reader process monitor did not finish '+Mode);
        if (Mode='closed') or (Mode='restart') then
          Require((Reply.ErrorText='') and (Reply.State='closed') and (Reply.Progress=42),'Valid reader result lost '+Mode)
        else Require((Reply.ErrorText<>'') and (Reply.State='failed') and not Reply.HasProgress,'Invalid child result accepted '+Mode);
        Require(not FileExists(Request.RequestFile),'Finished reader left its own request file '+Mode);
      end;
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Reader process transport changed original book');
    finally Owner.Free; end;
  end;
  SetEnvironmentVariable('HLRU_SESSION_TEST_MODE',nil);
  Writeln('PASS independent reader process returns progress across restart rejects foreign and missing replies survives catalogue close and removes only session files');
end;
