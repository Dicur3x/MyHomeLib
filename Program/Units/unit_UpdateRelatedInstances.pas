unit unit_UpdateRelatedInstances;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Winapi.Windows;

type
  TUpdateRelatedInstance = class
  public
    PID, RestartPID: Cardinal;
    ProcessHandle, RestartHandle: THandle;
    Executable, CommandLine, WindowClass, SessionFile: string;
    HasWindow, HasPlacement, CloseRequested, Restarted, PlacementRestored: Boolean;
    Placement: TWindowPlacement;
    SourceLease, RequestLease, OriginalSourceLease: TFileStream;
    destructor Destroy; override;
  end;

  // Only the catalogue and reader EXEs in this exact installation participate.
  // Normal WM_CLOSE preserves their own reading/profile state. No process is
  // terminated, and the original argv is reused without passing through a shell.
  TUpdateRelatedInstances = class
  private
    FTarget, FJob, FPhase: string;
    FInstances: TObjectList<TUpdateRelatedInstance>;
    FCallerInput: TUpdateRelatedInstance;
    procedure Capture(ExcludedPID: Cardinal);
    procedure CaptureCommandLines;
    procedure PinInput(Instance: TUpdateRelatedInstance; UsePending: Boolean = False);
    procedure SaveState;
  public
    constructor Create(const Target, Job: string; ExcludedPID: Cardinal);
    destructor Destroy; override;
    procedure KeepCallerInput(const ApplicationName, CommandLine: string);
    procedure CloseAndWait(TimeoutMS: Cardinal = 60000);
    procedure RestartClosed(WaitMS: Cardinal = 15000);
    function Describe: TJSONObject;
  end;

implementation

uses System.IOUtils, System.StrUtils, System.Variants, System.Win.ComObj, System.IniFiles,
  Winapi.ActiveX, Winapi.TlHelp32, Winapi.Messages, Winapi.ShellAPI,
  unit_ProgramUpdateInstaller, unit_ReaderStartup, unit_ReaderRestartState;

const RELATED_QUERY_LIMITED = $1000;
function RelatedProcessImage(Process: THandle; Flags: DWORD;
  Name: PChar; var Size: DWORD): BOOL; stdcall;
  external kernel32 name 'QueryFullProcessImageNameW';

type
  TWindowAction = (waCapture, waClose, waRestore);
  PWindowContext = ^TWindowContext;
  TWindowContext = record
    Instance: TUpdateRelatedInstance;
    Action: TWindowAction;
    Restored: Boolean;
  end;
  TArgumentPointers = array[0..32767] of PWideChar;
  PArgumentPointers = ^TArgumentPointers;

function RelatedWindow(Window: HWND; Data: LPARAM): BOOL; stdcall;
var Context: PWindowContext; PID: Cardinal; Name: array[0..255] of Char;
  ClassName: string; ReaderWindow, VisibleApp: Boolean;
begin
  Result:=True; Context:=PWindowContext(Data);
  GetWindowThreadProcessId(Window,@PID);
  if Context.Action=waRestore then
  begin
    if PID<>Context.Instance.RestartPID then Exit;
    if not IsWindowVisible(Window) then Exit;
  end
  else if (PID<>Context.Instance.PID) or
    (WaitForSingleObject(Context.Instance.ProcessHandle,0)<>WAIT_TIMEOUT) then Exit;
  if GetClassName(Window,Name,Length(Name))=0 then Exit;
  ClassName:=Name;
  // Do not close the VCL application's hidden message window: that bypasses
  // the reader form's close/save lifecycle.
  if SameText(ClassName,'TApplication') then Exit;
  ReaderWindow:=ContainsText(ClassName,'Reader');
  VisibleApp:=IsWindowVisible(Window) and (GetWindowTextLength(Window)>0) and
    ((GetWindow(Window,GW_OWNER)=0) or ReaderWindow or
      ((GetWindowLongPtr(Window,GWL_EXSTYLE) and WS_EX_APPWINDOW)<>0));
  case Context.Action of
    waCapture:
      if VisibleApp and (not Context.Instance.HasWindow or ReaderWindow) then
      begin
        Context.Instance.HasWindow:=True; Context.Instance.WindowClass:=ClassName;
        Context.Instance.Placement.length:=SizeOf(TWindowPlacement);
        Context.Instance.HasPlacement:=GetWindowPlacement(Window,Context.Instance.Placement);
      end;
    waClose:
      if IsWindowVisible(Window) or SameText(ClassName,'TfrmReaderHost') then
        PostMessage(Window,WM_CLOSE,0,0);
    waRestore:
      if SameText(ClassName,Context.Instance.WindowClass) then
      begin
        if Context.Instance.HasPlacement then
          Context.Restored:=SetWindowPlacement(Window,Context.Instance.Placement)
        else Context.Restored:=True;
        Result:=False;
      end;
  end;
end;

destructor TUpdateRelatedInstance.Destroy;
begin
  OriginalSourceLease.Free; SourceLease.Free; RequestLease.Free;
  if ProcessHandle<>0 then CloseHandle(ProcessHandle);
  if RestartHandle<>0 then CloseHandle(RestartHandle);
  inherited;
end;

constructor TUpdateRelatedInstances.Create(const Target, Job: string; ExcludedPID: Cardinal);
begin
  inherited Create;
  FInstances:=TObjectList<TUpdateRelatedInstance>.Create(True);
  FTarget:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Target));
  FJob:=TPath.GetFullPath(Job); AssertUpdatePath(FTarget); AssertUpdatePath(FJob);
  FPhase:='capturing'; Capture(ExcludedPID);
  for var Instance in FInstances do
    if Instance.HasWindow then begin CaptureCommandLines; Break; end;
  for var Instance in FInstances do
    if Instance.HasWindow then PinInput(Instance);
  FPhase:='captured'; SaveState;
end;

destructor TUpdateRelatedInstances.Destroy;
begin
  FCallerInput.Free;
  FInstances.Free;
  inherited;
end;

procedure TUpdateRelatedInstances.Capture(ExcludedPID: Cardinal);
var Snapshot, Process: THandle; Entry: TProcessEntry32; Image: string;
  Size: DWORD; Instance: TUpdateRelatedInstance; Context: TWindowContext;
begin
  Snapshot:=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
  if Snapshot=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Entry:=Default(TProcessEntry32); Entry.dwSize:=SizeOf(Entry);
    if Process32First(Snapshot,Entry) then repeat
      if (Entry.th32ProcessID=ExcludedPID) or (Entry.th32ProcessID=GetCurrentProcessId) then Continue;
      if not SameText(Entry.szExeFile,'HomeLibRu.exe') and
         not SameText(Entry.szExeFile,'HomeLibReader.exe') then Continue;
      Process:=OpenProcess(SYNCHRONIZE or RELATED_QUERY_LIMITED,False,Entry.th32ProcessID);
      if Process=0 then Continue;
      try
        SetLength(Image,32768); Size:=Length(Image);
        if not RelatedProcessImage(Process,0,PChar(Image),Size) then Continue;
        SetLength(Image,Size);
        if not SameFileName(ExtractFileDir(Image),FTarget) then Continue;
        if WaitForSingleObject(Process,0)<>WAIT_TIMEOUT then Continue;
        if FInstances.Count>=64 then raise Exception.Create('Слишком много экземпляров HomeLibre для обновления.');
        Instance:=TUpdateRelatedInstance.Create;
        FInstances.Add(Instance); Instance.ProcessHandle:=Process; Process:=0;
        Instance.PID:=Entry.th32ProcessID; Instance.Executable:=Image;
        Context:=Default(TWindowContext); Context.Instance:=Instance;
        Context.Action:=waCapture; EnumWindows(@RelatedWindow,LPARAM(@Context));
      finally if Process<>0 then CloseHandle(Process); end;
    until not Process32Next(Snapshot,Entry);
  finally CloseHandle(Snapshot); end;
end;

procedure TUpdateRelatedInstances.CaptureCommandLines;
var Initialized: HRESULT;
  procedure ReadCommandLines;
  var Locator, Service, Rows, Row: OleVariant;
    Enumerator: IEnumVARIANT; Fetched: LongWord; ID: Cardinal;
  begin
    Locator:=CreateOleObject('WbemScripting.SWbemLocator');
    Service:=Locator.ConnectServer('.', 'root\cimv2');
    Rows:=Service.ExecQuery('SELECT ProcessId,CommandLine FROM Win32_Process WHERE '+
      'Name=''HomeLibReader.exe'' OR Name=''HomeLibRu.exe''','WQL',48);
    Enumerator:=IUnknown(Rows._NewEnum) as IEnumVARIANT;
    while Enumerator.Next(1,Row,Fetched)=S_OK do
    begin
      ID:=Row.ProcessId;
      for var Instance in FInstances do
        if Instance.PID=ID then Instance.CommandLine:=VarToStr(Row.CommandLine);
      VarClear(Row);
    end;
    for var Instance in FInstances do
      if Instance.HasWindow and (WaitForSingleObject(Instance.ProcessHandle,0)=WAIT_TIMEOUT) and
        ((Instance.CommandLine='') or (Length(Instance.CommandLine)>32767)) then
        raise Exception.CreateFmt('Не удалось сохранить параметры запуска HomeLibre (процесс %d).',[Instance.PID]);
  end;
begin
  Initialized:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  if Failed(Initialized) and (Initialized<>RPC_E_CHANGED_MODE) then OleCheck(Initialized);
  try
    // A separate scope also finalizes the compiler's hidden OleVariant and
    // interface temporaries before COM is uninitialized in the GUI updater.
    ReadCommandLines;
  finally
    if Succeeded(Initialized) then CoUninitialize;
  end;
end;

procedure TUpdateRelatedInstances.PinInput(Instance: TUpdateRelatedInstance; UsePending: Boolean);
var Arguments: PPWideChar; Count, Comparison: Integer;
  Source, PendingFile, PendingSession, CurrentRequest, OriginalSource: string;
  JSON: TJSONValue; Values: TArray<string>; Startup: TReaderStartup; Ini: TMemIniFile;
begin
  if not SameText(ExtractFileName(Instance.Executable),'HomeLibReader.exe') then Exit;
  Arguments:=CommandLineToArgvW(PWideChar(Instance.CommandLine),Count);
  if Arguments=nil then RaiseLastOSError;
  Source:='';
  try
    if Count>1024 then raise Exception.Create('Слишком много параметров запуска читалки.');
    SetLength(Values,Count-1);
    for var I:=1 to Count-1 do Values[I-1]:=PArgumentPointers(Arguments)^[I];
  finally LocalFree(HLOCAL(Arguments)); end;
  Startup:=ResolveReaderStartup(Instance.Executable,Values);
  Source:=Startup.Source; Instance.SessionFile:=Startup.SessionFile;
  if Instance.ProcessHandle<>0 then
  begin
    CurrentRequest:=ReadReaderRestart(Startup.Profile,Instance.PID,ReaderProcessStamp(Instance.ProcessHandle));
    if CurrentRequest<>'' then
    begin
      Instance.SessionFile:=CurrentRequest;
      // Session options take priority over an original --open argument.
      // Preserve existing quoting and all other launch options verbatim.
      Instance.CommandLine:=Instance.CommandLine+' "--session='+CurrentRequest+'"';
      if Length(Instance.CommandLine)>32767 then
        raise Exception.Create('Current-book restart command is too long');
    end;
    if (CurrentRequest='') and
      (SameText(Instance.WindowClass,'TStandaloneBookReader') or
       SameText(Instance.WindowClass,'TStandaloneStoryReader')) and
      CompareComponentVersions(UpdateFileVersion(Instance.Executable),'3.0.0.2',Comparison) and
      (Comparison>=0) then
      raise Exception.Create('Не удалось сохранить текущую книгу для перезапуска. Обновление отменено до закрытия читалки.');
  end;
  if UsePending and FileExists(TPath.Combine(Startup.Profile,'HomeLibReader.ini')) then
  begin
    Ini:=TMemIniFile.Create(TPath.Combine(Startup.Profile,'HomeLibReader.ini'),TEncoding.UTF8);
    try
      PendingSession:=Ini.ReadString('ReaderSession','PendingSession','');
      PendingFile:=Ini.ReadString('ReaderSession','PendingFile','');
    finally Ini.Free; end;
    if PendingSession<>'' then Instance.SessionFile:=PendingSession
    else if PendingFile<>'' then begin Instance.SessionFile:=''; Source:=PendingFile; end;
  end;
  if Instance.SessionFile<>'' then
  begin
    Instance.RequestLease:=TFileStream.Create(Instance.SessionFile,fmOpenRead or fmShareDenyWrite);
    if Instance.RequestLease.Size>1024*1024 then
      raise Exception.Create('Слишком большой файл параметров открытой книги.');
    JSON:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Instance.SessionFile,TEncoding.UTF8));
    try
      if not (JSON is TJSONObject) or
        not TJSONObject(JSON).TryGetValue<string>('source',Source) then
        raise Exception.Create('Не удалось сохранить путь открытой книги.');
      OriginalSource:='';
      if TJSONObject(JSON).TryGetValue<string>('original_source',OriginalSource) and
        (OriginalSource<>'') and not SameFileName(OriginalSource,Source) then
        Instance.OriginalSourceLease:=TFileStream.Create(OriginalSource,fmOpenRead or fmShareDenyWrite);
    finally JSON.Free; end;
  end;
  if Source<>'' then Instance.SourceLease:=TFileStream.Create(Source,fmOpenRead or fmShareDenyWrite);
end;

procedure TUpdateRelatedInstances.KeepCallerInput(const ApplicationName, CommandLine: string);
begin
  if not SameText(ApplicationName,'HomeLibReader.exe') then Exit;
  if Assigned(FCallerInput) then raise Exception.Create('Повторная подготовка открытой книги к обновлению.');
  FCallerInput:=TUpdateRelatedInstance.Create;
  FCallerInput.Executable:=TPath.Combine(FTarget,ApplicationName);
  FCallerInput.CommandLine:=CommandLine;
  if FCallerInput.CommandLine='' then FCallerInput.CommandLine:='"'+FCallerInput.Executable+'"';
  PinInput(FCallerInput,True);
  SaveState;
end;

function TUpdateRelatedInstances.Describe: TJSONObject;
var List: TJSONArray; Item: TJSONObject;
begin
  Result:=TJSONObject.Create; Result.AddPair('target',FTarget); Result.AddPair('phase',FPhase);
  Result.AddPair('caller_input_pinned',TJSONBool.Create(Assigned(FCallerInput) and Assigned(FCallerInput.SourceLease)));
  List:=TJSONArray.Create; Result.AddPair('instances',List);
  for var Instance in FInstances do
  begin
    Item:=TJSONObject.Create; List.AddElement(Item);
    Item.AddPair('pid',TJSONNumber.Create(Instance.PID));
    Item.AddPair('executable',Instance.Executable); Item.AddPair('command_line',Instance.CommandLine);
    Item.AddPair('restore_window',TJSONBool.Create(Instance.HasWindow));
    Item.AddPair('close_requested',TJSONBool.Create(Instance.CloseRequested));
    Item.AddPair('restarted',TJSONBool.Create(Instance.Restarted));
    Item.AddPair('restart_pid',TJSONNumber.Create(Instance.RestartPID));
    Item.AddPair('source_pinned',TJSONBool.Create(Assigned(Instance.SourceLease)));
    Item.AddPair('window_class',Instance.WindowClass);
    Item.AddPair('placement_restored',TJSONBool.Create(Instance.PlacementRestored));
  end;
end;

procedure TUpdateRelatedInstances.SaveState;
var State: TJSONObject; Destination, Temporary: string;
begin
  if (FInstances.Count=0) and not Assigned(FCallerInput) then Exit;
  Destination:=TPath.Combine(FJob,'restart-instances.json'); Temporary:=Destination+'.new';
  AssertUpdatePath(Destination); AssertUpdatePath(Temporary);
  State:=Describe;
  try TFile.WriteAllText(Temporary,State.ToJSON,TEncoding.UTF8); finally State.Free; end;
  if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

procedure TUpdateRelatedInstances.CloseAndWait(TimeoutMS: Cardinal);
var Deadline, NextPost: UInt64; Context: TWindowContext; AllClosed: Boolean;
begin
  if (TimeoutMS<250) or (TimeoutMS>120000) then raise Exception.Create('Некорректный срок закрытия HomeLibre.');
  FPhase:='closing'; SaveState;
  // Close catalogues before their reader sessions, so session completion cannot
  // make a live catalogue remove request files needed for relaunch.
  for var ReaderPass:=0 to 1 do
  begin
    Deadline:=GetTickCount64+TimeoutMS; NextPost:=0;
    repeat
      AllClosed:=True;
      for var Instance in FInstances do
      begin
        if Ord(SameText(ExtractFileName(Instance.Executable),'HomeLibReader.exe'))<>ReaderPass then Continue;
        if WaitForSingleObject(Instance.ProcessHandle,0)=WAIT_OBJECT_0 then Continue;
        AllClosed:=False;
        if GetTickCount64>=NextPost then
        begin
          Instance.CloseRequested:=True;
          Context:=Default(TWindowContext); Context.Instance:=Instance; Context.Action:=waClose;
          EnumWindows(@RelatedWindow,LPARAM(@Context));
        end;
      end;
      if AllClosed then Break;
      if GetTickCount64>=Deadline then
        raise Exception.Create('Не все окна HomeLibre смогли закрыться. Файлы обновления не заменены.');
      if GetTickCount64>=NextPost then NextPost:=GetTickCount64+250;
      Sleep(50);
    until False;
  end;
  FPhase:='closed'; SaveState;
end;

procedure TUpdateRelatedInstances.RestartClosed(WaitMS: Cardinal);
var Startup: TStartupInfo; Process: TProcessInformation; Command: string;
  Context: TWindowContext; Deadline: UInt64;
begin
  if WaitMS>60000 then raise Exception.Create('Некорректный срок восстановления окон.');
  FPhase:='restarting'; SaveState;
  for var Instance in FInstances do
  begin
    if not Instance.CloseRequested or not Instance.HasWindow or Instance.Restarted or
      (WaitForSingleObject(Instance.ProcessHandle,0)<>WAIT_OBJECT_0) then Continue;
    Command:=Instance.CommandLine; UniqueString(Command);
    Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
    Startup.dwFlags:=STARTF_USESHOWWINDOW; Startup.wShowWindow:=SW_SHOWNORMAL;
    if Instance.HasPlacement then Startup.wShowWindow:=Instance.Placement.showCmd;
    if not CreateProcess(PChar(Instance.Executable),PChar(Command),nil,nil,False,
      CREATE_NO_WINDOW,nil,PChar(FTarget),Startup,Process) then RaiseLastOSError;
    CloseHandle(Process.hThread); Instance.RestartHandle:=Process.hProcess;
    Instance.RestartPID:=Process.dwProcessId; Instance.Restarted:=True; SaveState;
  end;
  // Start every book before waiting for any one of them. The bounded wait is
  // for restoring window placement; slow document preparation may continue.
  Deadline:=GetTickCount64+WaitMS;
  for var Instance in FInstances do
    if Instance.Restarted then
    begin
      repeat
        Context:=Default(TWindowContext); Context.Instance:=Instance; Context.Action:=waRestore;
        EnumWindows(@RelatedWindow,LPARAM(@Context));
        if Context.Restored then Instance.PlacementRestored:=True;
        if Context.Restored or (GetTickCount64>=Deadline) or
          (WaitForSingleObject(Instance.RestartHandle,0)=WAIT_OBJECT_0) then Break;
        Sleep(50);
      until False;
    end;
  FPhase:='restored';
  for var Instance in FInstances do
    if Instance.Restarted and not Instance.PlacementRestored then
      FPhase:='restarted-waiting-for-windows';
  SaveState;
end;

end.
