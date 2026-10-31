// Synthetic windows for the production updater's multi-instance protocol.
// Their test-only file controls never operate another application's windows.
var
  RelatedFixtureState, RelatedFixtureSource, RelatedFixturePurge, RelatedFixtureProfile,
    RelatedFixtureRestartRequest: string;
  RelatedFixturePage: Integer;
  RelatedFixtureHidden, RelatedFixtureRefuse: Boolean;

function RelatedFixtureArgument(const Name, DefaultValue: string): string;
begin
  Result:=DefaultValue;
  for var I:=2 to ParamCount do
    if ParamStr(I).StartsWith(Name+'=') then Exit(Copy(ParamStr(I),Length(Name)+2,MaxInt));
end;

function RelatedFixtureJSON(Window: HWND): TJSONObject;
var Placement: TWindowPlacement;
begin
  Result:=TJSONObject.Create;
  Result.AddPair('protocol',TJSONNumber.Create(2));
  Result.AddPair('pid',TJSONNumber.Create(GetCurrentProcessId));
  Result.AddPair('page',TJSONNumber.Create(RelatedFixturePage));
  Result.AddPair('source',RelatedFixtureSource);
  Placement:=Default(TWindowPlacement); Placement.length:=SizeOf(Placement);
  if GetWindowPlacement(Window,Placement) then
  begin
    Result.AddPair('left',TJSONNumber.Create(Placement.rcNormalPosition.Left));
    Result.AddPair('top',TJSONNumber.Create(Placement.rcNormalPosition.Top));
    Result.AddPair('width',TJSONNumber.Create(Placement.rcNormalPosition.Width));
    Result.AddPair('height',TJSONNumber.Create(Placement.rcNormalPosition.Height));
  end;
end;

procedure RelatedFixtureWrite(const FileName: string; State: TJSONObject);
var Temporary: string; Error: Cardinal;
begin
  Temporary:=FileName+'.new';
  try TFile.WriteAllText(Temporary,State.ToJSON,TEncoding.UTF8); finally State.Free; end;
  if not MoveFileEx(PChar(Temporary),PChar(FileName),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
  begin
    Error:=GetLastError;
    Winapi.Windows.DeleteFile(PChar(Temporary));
    // A polling observer may briefly have the old live file open. Keep its
    // complete last observation and publish the next timer tick instead.
    if (Error=ERROR_SHARING_VIOLATION) or (Error=ERROR_LOCK_VIOLATION) or
      ((Error=ERROR_ACCESS_DENIED) and FileExists(FileName)) then Exit;
    SetLastError(Error); RaiseLastOSError;
  end;
end;

function RelatedFixtureWindowProc(Window: HWND; Message: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var Value: Integer; State: TJSONObject; Deleted: Boolean; Purged: TJSONArray;
begin
  Result:=0;
  case Message of
    WM_TIMER:
      begin
        if FileExists(RelatedFixtureState+'.page') and
          TryStrToInt(Trim(TFile.ReadAllText(RelatedFixtureState+'.page')),Value) then
        begin
          RelatedFixturePage:=Value;
          Winapi.Windows.DeleteFile(PChar(RelatedFixtureState+'.page'));
        end;
        RelatedFixtureWrite(RelatedFixtureState+'.live',RelatedFixtureJSON(Window));
        if FileExists(RelatedFixtureState+'.stop') then PostMessage(Window,WM_CLOSE,0,0);
      end;
    WM_CLOSE:
      begin
        if RelatedFixtureRefuse and not FileExists(RelatedFixtureState+'.allow-close') then Exit;
        RelatedFixtureWrite(RelatedFixtureState,RelatedFixtureJSON(Window));
        Deleted:=False;
        // Simulate removal of a cached input at shutdown. The updater's lease
        // must prevent it while the book is being carried across installation.
        if (RelatedFixtureSource<>'') and FileExists(RelatedFixtureSource) then
          Deleted:=Winapi.Windows.DeleteFile(PChar(RelatedFixtureSource));
        State:=RelatedFixtureJSON(Window); State.AddPair('cached_input_deleted',TJSONBool.Create(Deleted));
        State.AddPair('closed_tick',TJSONNumber.Create(GetTickCount64));
        Purged:=TJSONArray.Create; State.AddPair('purged',Purged);
        if RelatedFixturePurge<>'' then
          for var FileName in TDirectory.GetFiles(RelatedFixturePurge,'*.book') do
            if Winapi.Windows.DeleteFile(PChar(FileName)) then Purged.Add(FileName);
        RelatedFixtureWrite(RelatedFixtureState+'.closed',State);
        RemoveReaderRestart(RelatedFixtureProfile);
        CleanupReaderRestartSession(RelatedFixtureProfile,RelatedFixtureRestartRequest);
        DestroyWindow(Window);
      end;
    WM_DESTROY: begin KillTimer(Window,1); PostQuitMessage(0); end;
  else Result:=DefWindowProc(Window,Message,WParam,LParam);
  end;
end;

procedure RunRelatedInstanceFixture;
var ClassInfo: TWndClass; ClassName, Source, Session, Previous, Current, Origin, Folder: string;
  Window: HWND; Message: TMsg; State: TJSONValue; Left, Top: Integer;
begin
  RelatedFixtureState:=RelatedFixtureArgument('--fixture-state',''); Guard(RelatedFixtureState);
  RelatedFixtureHidden:=RelatedFixtureArgument('--fixture-hidden','0')='1';
  RelatedFixtureRefuse:=RelatedFixtureArgument('--fixture-refuse','0')='1';
  RelatedFixturePurge:=RelatedFixtureArgument('--fixture-purge','');
  if RelatedFixturePurge<>'' then Guard(RelatedFixturePurge);
  RelatedFixturePage:=StrToInt(RelatedFixtureArgument('--fixture-page','1'));
  Source:=RelatedFixtureArgument('--open',''); Session:=RelatedFixtureArgument('--session','');
  if Session<>'' then
  begin
    Guard(Session); State:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Session));
    try
      if not (State is TJSONObject) then raise Exception.Create('Invalid fixture session');
      Source:=TJSONObject(State).GetValue<string>('source');
    finally State.Free; end;
  end;
  RelatedFixtureProfile:=RelatedFixtureArgument('--profile',ExtractFileDir(ParamStr(0)));
  Guard(RelatedFixtureProfile);
  Current:=RelatedFixtureArgument('--fixture-current','');
  if Current<>'' then
  begin
    Guard(Current); Source:=Current;
    Origin:=RelatedFixtureArgument('--fixture-origin',''); if Origin<>'' then Guard(Origin);
    Folder:=TPath.Combine(ReaderRestartDirectory(RelatedFixtureProfile),'HomeLibReader-session-'+
      LowerCase(TGUID.NewGuid.ToString.Replace('{','').Replace('}','').Replace('-','')));
    ForceDirectories(Folder); RelatedFixtureRestartRequest:=TPath.Combine(Folder,'request.json');
    State:=TJSONObject.Create;
    TJSONObject(State).AddPair('source',Source);
    if Origin<>'' then TJSONObject(State).AddPair('original_source',Origin);
    RelatedFixtureWrite(RelatedFixtureRestartRequest,TJSONObject(State));
    PublishReaderRestart(RelatedFixtureProfile,RelatedFixtureRestartRequest);
  end;
  RelatedFixtureSource:=Source; if Source<>'' then Guard(Source);
  if FileExists(RelatedFixtureState) then
  begin
    Previous:=TFile.ReadAllText(RelatedFixtureState); State:=TJSONObject.ParseJSONValue(Previous);
    try if State is TJSONObject then RelatedFixturePage:=TJSONObject(State).GetValue<Integer>('page');
    finally State.Free; end;
  end;
  ClassName:='TStandaloneBookReader';
  if RelatedFixtureHidden then ClassName:='TfrmReaderHost'
  else if SameText(ExtractFileName(ParamStr(0)),'HomeLibRu.exe') then ClassName:='TfrmMain';
  ClassInfo:=Default(TWndClass); ClassInfo.lpfnWndProc:=@RelatedFixtureWindowProc;
  ClassInfo.hInstance:=HInstance; ClassInfo.lpszClassName:=PChar(ClassName);
  ClassInfo.hbrBackground:=COLOR_WINDOW+1;
  if Winapi.Windows.RegisterClass(ClassInfo)=0 then RaiseLastOSError;
  Left:=StrToInt(RelatedFixtureArgument('--fixture-left','120'));
  Top:=StrToInt(RelatedFixtureArgument('--fixture-top','120'));
  Window:=CreateWindow(PChar(ClassName),PChar('Owned update fixture: '+ExtractFileName(RelatedFixtureState)),
    WS_OVERLAPPEDWINDOW,Left,Top,420,260,0,0,HInstance,nil);
  if Window=0 then RaiseLastOSError;
  if not RelatedFixtureHidden then ShowWindow(Window,SW_SHOWNOACTIVATE);
  SetTimer(Window,1,100,nil);
  RelatedFixtureWrite(RelatedFixtureState+'.live',RelatedFixtureJSON(Window));
  while Integer(GetMessage(Message,0,0,0))>0 do
  begin TranslateMessage(Message); DispatchMessage(Message); end;
end;

procedure RunRelatedInstanceCycle(const Target, Job: string; TimeoutMS: Cardinal);
var Instances: TUpdateRelatedInstances; State: TJSONObject;
begin
  Guard(Target); Guard(Job); ForceDirectories(Job);
  Instances:=TUpdateRelatedInstances.Create(Target,Job,GetCurrentProcessId);
  try
    if ParamStr(5)<>'' then
    begin
      Guard(ParamStr(5));
      Instances.KeepCallerInput('HomeLibReader.exe',TFile.ReadAllText(ParamStr(5),TEncoding.UTF8));
    end;
    try Instances.CloseAndWait(TimeoutMS);
    finally Instances.RestartClosed(10000); end;
    // A second call must not create another copy of any window.
    Instances.RestartClosed(1000);
    State:=Instances.Describe;
    try Writeln(State.ToJSON); finally State.Free; end;
  finally Instances.Free; end;
end;
