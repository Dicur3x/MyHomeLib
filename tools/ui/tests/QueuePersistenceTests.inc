// Include after GroupBookIdentityTests: shares its bounded dialog text helpers.
// The parent runner owns real Main construction/closure and all native execution.
type
  TQPUnloadedMain = class(TfrmMain)
  protected
    procedure DoCreate; override;
  end;
  TQPSaveNodeEvent = procedure(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream) of object;
  TQPNodeWriter = class
    Original: TQPSaveNodeEvent;
    FaultKind: string;
    procedure Save(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);
  end;
  TQPReadFault = class(TStream)
  private
    Storage: TMemoryStream;
  protected
    function GetSize: Int64; override;
  public
    Fail, DidRead: Boolean; ReadCalls, FirstReadCount: Integer;
    constructor Create;
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;
  TQPCallWndData = record
    LParam: LPARAM; WParam: WPARAM; Message: UINT; Window: HWND;
  end;
  PQPCallWndData = ^TQPCallWndData;
  TQPProbe = class
    Hook, CallHook: HHOOK; Timer: TTimer; Messages: TStringList;
    LastWindow, DiagnosticWindow: HWND; Failure: string; Requests, ClassicCorrections: Integer;
    OldDialogs, Capturing: Boolean; Server: TIdHTTPServer;
    procedure KeepClassicForControl(Window: HWND);
    procedure Capture(Window: HWND);
    procedure Tick(Sender: TObject);
    procedure Request(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
  end;

var QPProbe: TQPProbe; QPFile, QPHash, QPVariant, QPSnapshot: string;

procedure TQPUnloadedMain.DoCreate;
begin
  // This intentional pre-DFM fixture has no pgControl or other Main controls.
  // Keep it uninitialized; the real Save action must exit at its Ready guard.
end;

function QPNativeHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result:=CallNextHookEx(0,Code,WParam,LParam);
  if Assigned(QPProbe) then
    try
      if Code=HCBT_CREATEWND then QPProbe.KeepClassicForControl(HWND(WParam))
      else if Code=HCBT_ACTIVATE then QPProbe.Capture(HWND(WParam));
    except on E: Exception do QPProbe.Failure:=E.ClassName+': '+E.Message; end;
end;

function QPCallWndHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result:=CallNextHookEx(0,Code,WParam,LParam);
  if (Code=HC_ACTION) and Assigned(QPProbe) and (LParam<>0) then
    try QPProbe.KeepClassicForControl(PQPCallWndData(LParam)^.Window);
    except on E: Exception do QPProbe.Failure:=E.ClassName+': '+E.Message; end;
end;

procedure TQPProbe.KeepClassicForControl(Window: HWND);
var PID: DWORD; Root: HWND; ClassName: array[0..255] of Char;
begin
  if not Vcl.Dialogs.UseLatestCommonDialogs then Exit;
  PID:=0; GetWindowThreadProcessId(Window,@PID);
  if PID<>GetCurrentProcessId then Exit;
  Root:=GetAncestor(Window,GA_ROOT); if Root=0 then Exit;
  if (GetClassName(Root,ClassName,Length(ClassName))=0) or
    (string(PChar(@ClassName[0]))='#32770') then Exit;
  // Main.InitFormFields resets this global during construction. Restore the
  // controlled fixture backend on its own non-dialog control messages BEFORE
  // MHLShowError chooses a backend, including queue Clear / toolbar disable.
  // Never pretend to switch an already-selected native TaskDialog backend.
  Vcl.Dialogs.UseLatestCommonDialogs:=False; Inc(ClassicCorrections);
  Writeln('TRACE queue scoped classic restored before dialog control root=',string(PChar(@ClassName[0]))); Flush(Output);
end;

procedure TQPProbe.Capture(Window: HWND);
var Parts: TStringList; ClassName: array[0..255] of Char; PID: DWORD;
begin
  PID:=0; GetWindowThreadProcessId(Window,@PID);
  if Capturing or (PID<>GetCurrentProcessId) or (LastWindow=Window) or
    (GetClassName(Window,ClassName,Length(ClassName))=0) or
    (string(PChar(@ClassName[0]))<>'#32770') then Exit;
  Capturing:=True; Parts:=TStringList.Create;
  try
    EnumChildWindows(Window,@GBINativeChildText,LPARAM(Pointer(Parts)));
    if not (Parts.Text.Contains('Не удалось восстановить очередь загрузок') or
      Parts.Text.Contains('Не удалось сохранить очередь загрузок')) then
    begin
      if DiagnosticWindow<>Window then
      begin DiagnosticWindow:=Window; Writeln('TRACE queue native dialog awaiting exact error text ',Copy(Parts.Text,1,1200)); Flush(Output); end;
      Exit;
    end;
    LastWindow:=Window; Messages.Add(Parts.Text);
    Writeln('TRACE queue native persistence message ',Copy(Parts.Text,1,1500)); Flush(Output);
    var Button:=GetDlgItem(Window,IDOK);
    if Button<>0 then PostMessage(Button,BM_CLICK,0,0)
    else PostMessage(Window,WM_USER+102,IDOK,0);
  finally Parts.Free; Capturing:=False; end;
end;

procedure TQPProbe.Tick(Sender: TObject);
var Window, Next: HWND;
begin
  // TaskDialog DirectUI is not a Screen.Forms entry. Recheck native dialogs
  // after activation, when accessibility text has completed initialization.
  Window:=GetTopWindow(0);
  while Window<>0 do
  begin Next:=GetWindow(Window,GW_HWNDNEXT); if IsWindowVisible(Window) then Capture(Window); Window:=Next; end;
  // MessageDlg can use an ordinary VCL message form instead of a native dialog.
  for var I:=0 to Screen.FormCount-1 do
  begin
    var Form:=Screen.Forms[I];
    if not Form.Visible or not Form.HandleAllocated or (Form.Handle=LastWindow) then Continue;
    var Text:=GBIComponentText(Form);
    if not (Text.Contains('Не удалось восстановить очередь загрузок') or
      Text.Contains('Не удалось сохранить очередь загрузок')) then Continue;
    LastWindow:=Form.Handle; Messages.Add(Text);
    Writeln('TRACE queue VCL persistence message ',Copy(Text,1,1500)); Flush(Output);
    // The actual VCL MessageDlg may host TBitBtn instead of TButton. Its
    // documented modal result closes precisely this captured queue error.
    Form.ModalResult:=mrOk;
  end;
end;

procedure TQPProbe.Request(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  TInterlocked.Increment(Requests); ResponseInfo.ResponseNo:=404; ResponseInfo.ContentText:='Unexpected queue request';
end;

procedure QPStartProbe;
begin
  Require(not Assigned(QPProbe),'Queue persistence dialog probe already exists');
  QPProbe:=TQPProbe.Create; QPProbe.Messages:=TStringList.Create;
  QPProbe.OldDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  // Backend selection is deterministic only within this fixture lifetime.
  // Actual production Main load/save, errors and persistence remain unchanged.
  Vcl.Dialogs.UseLatestCommonDialogs:=False;
  QPProbe.Timer:=TTimer.Create(nil); QPProbe.Timer.Interval:=15; QPProbe.Timer.OnTimer:=QPProbe.Tick;
  QPProbe.Hook:=SetWindowsHookEx(WH_CBT,@QPNativeHook,0,GetCurrentThreadId);
  Require(QPProbe.Hook<>0,'Cannot install queue persistence dialog capture');
  QPProbe.CallHook:=SetWindowsHookEx(WH_CALLWNDPROC,@QPCallWndHook,0,GetCurrentThreadId);
  Require(QPProbe.CallHook<>0,'Cannot install own-thread scoped classic backend guard');
end;

procedure QPStopProbe;
var RestoreDialogs: Boolean;
begin
  if not Assigned(QPProbe) then Exit;
  RestoreDialogs:=QPProbe.OldDialogs;
  if QPProbe.Hook<>0 then UnhookWindowsHookEx(QPProbe.Hook);
  if QPProbe.CallHook<>0 then UnhookWindowsHookEx(QPProbe.CallHook);
  QPProbe.Timer.Free; QPProbe.Server.Free; QPProbe.Messages.Free;
  Vcl.Dialogs.UseLatestCommonDialogs:=RestoreDialogs; FreeAndNil(QPProbe);
  Require(Vcl.Dialogs.UseLatestCommonDialogs=RestoreDialogs,
    'Queue persistence dialog probe did not restore the previous dialog setting');
end;

constructor TQPReadFault.Create;
begin inherited; Storage:=TMemoryStream.Create; end;

destructor TQPReadFault.Destroy;
begin Storage.Free; inherited; end;

function TQPReadFault.GetSize: Int64;
begin Result:=Storage.Size; end;

function TQPReadFault.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin Result:=Storage.Seek(Offset,Origin); end;

function TQPReadFault.Write(const Buffer; Count: Longint): Longint;
begin Result:=Storage.Write(Buffer,Count); end;

function TQPReadFault.Read(var Buffer; Count: Longint): Longint;
begin
  Inc(ReadCalls);
  if Fail and DidRead then raise EReadError.Create('Injected failure after a partial source read');
  // A TStream adapter prevents the RTL's direct-Memory shortcut. A 3MiB
  // payload exceeds CopyFrom's documented default 1MiB buffer: return a full
  // first buffer, then fail only after that complete block has been written.
  Result:=Storage.Read(Buffer,Count);
  if Result>0 then begin DidRead:=True; if ReadCalls=1 then FirstReadCount:=Result; end;
end;

procedure TQPNodeWriter.Save(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);
begin
  if FaultKind='serialize-fail' then
  begin
    Stream.WriteBuffer(Node.Index,SizeOf(Node.Index));
    raise EWriteError.Create('Injected node serialization failure after a partial write');
  end;
  var Data:=PDownloadData(Sender.GetNodeData(Node));
  if Assigned(Data) and (Data^.Title='QUEUE-PERSISTENCE-BAD-LAST') and (FaultKind='zero') then Exit;
  Original(Sender,Node,Stream);
  if Assigned(Data) and (Data^.Title='QUEUE-PERSISTENCE-BAD-LAST') and (FaultKind='truncated') then
  begin Stream.Size:=Stream.Position-1; Stream.Position:=Stream.Size; end;
end;

function QPQueueSnapshot(Tree: TBookTree): string;
var Builder: TStringBuilder; Node: PVirtualNode; Data: PDownloadData;
begin
  Builder:=TStringBuilder.Create;
  try
    Node:=Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data:=Tree.GetNodeData(Node); Require(Assigned(Data),'Queue snapshot has missing data');
      Builder.Append(Data^.BookKey.DatabaseID).Append(':').Append(Data^.BookKey.BookID).Append(':');
      for var S in TArray<string>.Create(Data^.Title,Data^.Author,Data^.FileName,Data^.URL,
        Data^.ExpectedLibID,Data^.ExpectedPhysicalIdentity) do Builder.Append(Length(S)).Append(':').Append(S).Append(':');
      Builder.Append(Data^.Size).Append(':').Append(Ord(Data^.State)).Append(':').Append(Ord(Data^.HasExpectedIdentity)).Append(#13);
      Node:=Tree.GetNext(Node);
    end;
    Result:=THashSHA2.GetHashString(Builder.ToString);
  finally Builder.Free; end;
end;

procedure QPCheckNoTemps;
begin
  Require(Length(TDirectory.GetFiles(ExtractFilePath(QPFile),'*.homelib-data-*'))=0,
    'Queue atomic publication left an owned temporary or backup');
end;

// Call only for queue-load-negative / queue-load-truncated / queue-load-zero,
// AFTER SystemDB initialization but BEFORE Application.CreateForm(TfrmMain,...).
procedure PrepareQueuePersistenceStartup(const FaultKind: string);
var Host: TForm; Tree: TBookTree; Controller: TTreeController; Writer: TQPNodeWriter;
  Stream: TMemoryStream; Collection: IBookCollection; CID, ID, Port: Integer; Book: TBookRecord;
  Data: PDownloadData; Node: PVirtualNode; Bytes, Marker: TBytes; At, Found: Integer;
begin
  RequireIsolatedRegression; Require(Settings.AppPath.StartsWith('G:\',True),'Queue startup must use private G');
  Require((FaultKind='negative') or (FaultKind='truncated') or (FaultKind='zero'),'Unknown startup queue corruption kind');
  QPFile:=Settings.SystemFileName[sfDownloadsStore]; QPVariant:=FaultKind; QPStartProbe;
  QPProbe.Server:=TIdHTTPServer.Create(nil); QPProbe.Server.OnCommandGet:=QPProbe.Request;
  with QPProbe.Server.Bindings.Add do begin IP:='127.0.0.1'; Port:=0; end;
  QPProbe.Server.Active:=True; Port:=QPProbe.Server.Bindings[0].Port;
  Require(Port>0,'Queue startup loopback server has no bound port');
  CID:=SystemDB.CreateCollection('Private queue startup',Settings.AppPath,'queue-startup.hlc2',
    CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=SystemDB.GetCollection(CID);
  Collection.SetProperty(PROP_URL,Format('http://127.0.0.1:%d/',[Port]));
  Collection.SetProperty(PROP_CONNECTIONSCRIPT,'GET %URL%b/%LIBID%/get'+sLineBreak+'CHECK');
  ID:=AddOnlineBook(Collection,'Queue startup real online first','992001',False);
  Book.Clear; Collection.GetBookRecord(CreateBookKey(ID,CID),Book,True);
  Host:=TForm.CreateNew(nil); Tree:=TBookTree.Create(Host); Controller:=TTreeController.Create(SystemDB);
  Writer:=TQPNodeWriter.Create; Stream:=TMemoryStream.Create;
  try
    Tree.Parent:=Host; Controller.ConnectDownloadTree(Tree);
    for var I:=0 to 1 do
    begin
      Node:=Tree.AddChild(nil); Data:=Tree.GetNodeData(Node); Data^:=Default(TDownloadData);
      Data^.BookKey:=Book.BookKey; Data^.Title:='QUEUE-PERSISTENCE-VALID-FIRST';
      if I=1 then Data^.Title:='QUEUE-PERSISTENCE-BAD-LAST';
      Data^.Author:='Очередь — ё ї ў 😀'; Data^.FileName:=Book.GetBookFileName;
      Data^.URL:=Format('http://127.0.0.1:%d/b/992001/get',[Port]); Data^.Size:=100; Data^.State:=dsWait;
      Data^.HasExpectedIdentity:=True; Data^.ExpectedLibID:=Book.LibID;
      Data^.ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Book);
    end;
    Writer.Original:=Tree.OnSaveNode; Writer.FaultKind:=FaultKind; Tree.OnSaveNode:=Writer.Save;
    Tree.SaveToStream(Stream); SetLength(Bytes,Stream.Size); Move(Stream.Memory^,Bytes[0],Length(Bytes));
    if FaultKind='negative' then
    begin
      Marker:=TEncoding.Unicode.GetBytes('QUEUE-PERSISTENCE-BAD-LAST'); Found:=0;
      for var I:=4 to Length(Bytes)-Length(Marker) do
      begin
        At:=0; while (At<Length(Marker)) and (Bytes[I+At]=Marker[At]) do Inc(At);
        if At=Length(Marker) then begin Require(Found=0,'Queue title marker is ambiguous'); Found:=I; end;
      end;
      Require(Found>4,'Queue title marker not found');
      for var I:=Found-4 to Found-1 do Bytes[I]:=$FF;
    end;
    TFile.WriteAllBytes(QPFile,Bytes); QPHash:=THashSHA2.GetHashStringFromFile(QPFile);
    Settings.AutoStartDwnld:=True; Settings.SaveSettings;
    Writeln('TRACE queue startup fixture ',FaultKind,' bytes=',Length(Bytes),' firstKey=',ID,'/',CID); Flush(Output);
  finally
    Tree.OnSaveNode:=Writer.Original; Stream.Free; Writer.Free; Host.Free; Controller.Free;
  end;
end;

procedure TestQueuePersistenceStartup;
begin
  Require(Assigned(QPProbe) and Assigned(frmMain),'Queue startup was not prepared before actual Main construction');
  Require((QPProbe.Failure='') and (QPProbe.Messages.Count=1),
    'Failed queue load did not report exactly one useful error: '+QPProbe.Failure);
  Require((QPProbe.ClassicCorrections>0) and not Vcl.Dialogs.UseLatestCommonDialogs,
    'Startup classic backend was not established before the real queue error');
  Require(frmMain.tvDownloadList.GetFirst=nil,'Failed queue startup retained a partial valid node');
  Require(not frmMain.BtnSave.Enabled,'Failed queue startup still offers an overwriting Save action');
  Require(Settings.AutoStartDwnld,'Failed startup changed the persistent auto-start preference');
  Require(THashSHA2.GetHashStringFromFile(QPFile)=QPHash,'Failed startup rewrote its source queue');
  var Started:=GetTickCount64;
  while GetTickCount64-Started<600 do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
  Require(TInterlocked.CompareExchange(QPProbe.Requests,0,0)=0,'Failed queue startup made an HTTP request');
  Require(frmMain.btnStartDownload.Enabled and not frmMain.btnPauseDownload.Enabled,
    'Failed queue startup started its download manager');
  frmMain.BtnSaveClick(nil);
  Require((QPProbe.Messages.Count=1) and (THashSHA2.GetHashStringFromFile(QPFile)=QPHash),
    'Failed queue session attempted to save an empty replacement'); QPCheckNoTemps;
  Writeln('PASS queue startup ',QPVariant,' clears partial records, disables session save-autostart, preserves preference and makes no HTTP'); Flush(Output);
end;

procedure TestQueuePersistence(OneID: Integer);
var Node: PVirtualNode; Data: PDownloadData; Stream: TMemoryStream; Fault: TQPReadFault;
  Writer: TQPNodeWriter; OldSave: TQPSaveNodeEvent; OldAttributes: DWORD; Lock: TFileStream;
  Bytes: TBytes; Before, Snapshot, Root, Generic, OldGeneric, Oracle: string; Failed: Boolean; BeforeMessages: Integer;

  procedure ActualSaveError;
  begin
    QPProbe.LastWindow:=0;
    BeforeMessages:=QPProbe.Messages.Count; frmMain.BtnSaveClick(nil);
    Require((QPProbe.Messages.Count=BeforeMessages+1) and (QPProbe.Failure=''),
      'Actual queue Save did not report its failure once');
    Require((THashSHA2.GetHashStringFromFile(QPFile)=Before) and (QPQueueSnapshot(frmMain.tvDownloadList)=Snapshot),
      'Failed queue save changed previous raw bytes or live queue records'); QPCheckNoTemps;
  end;

begin
  RequireIsolatedRegression; QPVariant:='normal'; QPFile:=Settings.SystemFileName[sfDownloadsStore];
  Root:=TPath.Combine(Settings.AppPath,'queue-persistence-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  Generic:=TPath.Combine(Root,'generic.bin'); Oracle:=TPath.Combine(Root,'serialized-oracle.queue');
  Stream:=TMemoryStream.Create; Fault:=TQPReadFault.Create; Writer:=TQPNodeWriter.Create; Lock:=nil; QPStartProbe;
  try
    frmMain.tvDownloadList.Clear;
    for var I:=0 to 1 do
    begin
      Node:=frmMain.tvDownloadList.AddChild(nil); Data:=frmMain.tvDownloadList.GetNodeData(Node); Data^:=Default(TDownloadData);
      Data^.BookKey:=CreateBookKey(100+I,OneID); Data^.Title:='Полная очередь — ё ї ў 😀 '+IntToStr(I);
      Data^.Author:='Автор'; Data^.FileName:='source-'+IntToStr(I)+'.fb2'; Data^.Size:=128+I; Data^.State:=dsWait;
      Data^.URL:='https://example.invalid/'+IntToStr(I); Data^.HasExpectedIdentity:=True;
      Data^.ExpectedLibID:='Exact queue identity '+IntToStr(I); Data^.ExpectedPhysicalIdentity:='Exact physical '+IntToStr(I);
    end;
    Writeln('TRACE queue normal before complete snapshot and serializer'); Flush(Output);
    Snapshot:=QPQueueSnapshot(frmMain.tvDownloadList); frmMain.tvDownloadList.SaveToStream(Stream);
    SetLength(Bytes,Stream.Size); Move(Stream.Memory^,Bytes[0],Length(Bytes)); TFile.WriteAllBytes(Oracle,Bytes);
    Writeln('TRACE queue normal before actual first Save'); Flush(Output);
    frmMain.BtnSaveClick(nil); Require(QPProbe.Messages.Count=0,'Normal queue Save reported an error');
    Require(THashSHA2.GetHashStringFromFile(QPFile)=THashSHA2.GetHashStringFromFile(Oracle),
      'Atomic queue bytes differ from the actual native serializer'); QPCheckNoTemps;
    Writeln('TRACE queue normal before deliberately unloaded Main guard'); Flush(Output);
    var Bare:=TQPUnloadedMain.CreateNew(nil);
    try Bare.BtnSaveClick(nil); finally Bare.Free; end;
    Writeln('TRACE queue unloaded Main actual Save guard completed'); Flush(Output);
    Require(THashSHA2.GetHashStringFromFile(QPFile)=THashSHA2.GetHashStringFromFile(Oracle),
      'A Main instance that never loaded its queue replaced old persisted bytes');
    Writeln('PASS queue complete native serialization matches atomic bytes and a not-yet-loaded Main cannot overwrite them'); Flush(Output);
    Data:=frmMain.tvDownloadList.GetNodeData(frmMain.tvDownloadList.GetFirst); Data^.Title:='Retry preserved live edits — ё 😀';
    Snapshot:=QPQueueSnapshot(frmMain.tvDownloadList); Before:=THashSHA2.GetHashStringFromFile(QPFile);
    OldAttributes:=GetFileAttributes(PChar(QPFile)); Require(OldAttributes<>INVALID_FILE_ATTRIBUTES,'Queue attributes unavailable');
    Require(SetFileAttributes(PChar(QPFile),OldAttributes or FILE_ATTRIBUTE_READONLY),'Cannot set read-only queue fixture');
    Writeln('TRACE queue normal before actual readonly Save'); Flush(Output);
    try ActualSaveError; finally SetFileAttributes(PChar(QPFile),OldAttributes); end;
    Writeln('TRACE queue normal before actual locked Save'); Flush(Output);
    Lock:=TFileStream.Create(QPFile,fmOpenRead or fmShareDenyWrite);
    try ActualSaveError; finally FreeAndNil(Lock); end;
    OldSave:=frmMain.tvDownloadList.OnSaveNode; Writer.Original:=OldSave; Writer.FaultKind:='serialize-fail';
    frmMain.tvDownloadList.OnSaveNode:=Writer.Save;
    Writeln('TRACE queue normal before actual serializer fault Save'); Flush(Output);
    try ActualSaveError; finally frmMain.tvDownloadList.OnSaveNode:=OldSave; end;
    frmMain.BtnSaveClick(nil); Require(THashSHA2.GetHashStringFromFile(QPFile)<>Before,'Retry did not publish the retained live edits');
    frmMain.tvDownloadList.Clear; frmMain.tvDownloadList.LoadFromFile(QPFile);
    Require(QPQueueSnapshot(frmMain.tvDownloadList)=Snapshot,'Actual queue reopen lost Unicode, identity, URL or state'); QPCheckNoTemps;
    QPSnapshot:=Snapshot;
    Writeln('PASS queue actual Save read-only-lock-serialization failures retain old raw bytes and live edits, later retry reopens exactly');
    TFile.WriteAllText(Generic,'Protected generic destination — ё',TEncoding.UTF8); OldGeneric:=THashSHA2.GetHashStringFromFile(Generic);
    SetLength(Bytes,3*1024*1024); for var I:=0 to High(Bytes) do Bytes[I]:=Byte(I mod 251);
    Fault.WriteBuffer(Bytes[0],Length(Bytes)); Fault.Position:=17; Fault.Fail:=True; Failed:=False;
    try SaveStreamAtomically(Fault,Generic); except on E: EReadError do Failed:=True; end;
    Writeln('TRACE queue generic fault failed=',BoolToStr(Failed,True),' reads=',Fault.ReadCalls,' first_complete_bytes=',Fault.FirstReadCount,' position=',Fault.Position); Flush(Output);
    Require(Failed and (Fault.ReadCalls>=2) and (Fault.FirstReadCount>0) and (Fault.FirstReadCount<Fault.Size),
      'Generic atomic fault after a completed first copy block was not actually exercised');
    Require(Fault.Position=17,'Generic atomic read failure changed source position');
    Require(THashSHA2.GetHashStringFromFile(Generic)=OldGeneric,'Generic atomic read failure truncated the old file');
    Require(Length(TDirectory.GetFiles(Root,'*.homelib-data-*'))=0,'Generic failure left a temporary file');
    Fault.Fail:=False; Fault.DidRead:=False; SaveStreamAtomically(Fault,Generic);
    Require((Fault.Position=17) and (Length(TFile.ReadAllBytes(Generic))=Length(Bytes)),
      'Generic atomic retry lost stream position or bytes');
    var Actual:=TFile.ReadAllBytes(Generic); Require(CompareMem(@Actual[0],@Bytes[0],Length(Bytes)),'Generic atomic retry changed binary bytes');
    Writeln('PASS queue generic stream read fault preserves old file and caller position, cleans own temporary, full binary retry succeeds'); Flush(Output);
  finally Lock.Free; Writer.Free; Fault.Free; Stream.Free; QPStopProbe; end;
end;

// Call AFTER the parent's real frmMain.Free (and before Settings/DMUser teardown).
procedure CheckQueuePersistenceAfterClose;
var Host: TForm; Tree: TBookTree; Controller: TTreeController; Ini: TMemIniFile;
begin
  if QPVariant='normal' then
  begin
    Host:=TForm.CreateNew(nil); Tree:=TBookTree.Create(Host); Controller:=TTreeController.Create(SystemDB);
    try Tree.Parent:=Host; Controller.ConnectDownloadTree(Tree); Tree.LoadFromFile(QPFile);
      Require(QPQueueSnapshot(Tree)=QPSnapshot,'Main closure lost a previously saved valid queue');
    finally Host.Free; Controller.Free; end;
    Writeln('PASS queue valid records remain complete after actual Main close');
  end
  else
  begin
    Require(Assigned(QPProbe) and (QPProbe.Messages.Count=1) and (QPProbe.Failure=''),
      'Failed-load Main closure retried or reported another queue save');
    Require(THashSHA2.GetHashStringFromFile(QPFile)=QPHash,'Main closure overwrote the original failed-load raw queue');
    Require(TInterlocked.CompareExchange(QPProbe.Requests,0,0)=0,'Failed-load session made an HTTP request while closing');
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try Require(Ini.ReadBool('BEHAVIOR','AutoStartDwnld',False),'Session failure persisted AutoStart=false'); finally Ini.Free; end;
    QPStopProbe;
    Writeln('PASS queue failed startup ',QPVariant,' preserves exact source bytes after actual Main close, no HTTP and saved AutoStart=true');
  end;
  QPCheckNoTemps; Flush(Output);
end;
