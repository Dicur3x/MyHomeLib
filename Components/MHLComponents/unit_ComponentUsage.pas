unit unit_ComponentUsage;

interface

uses System.SysUtils;

procedure ConfigureComponentUsage(const AppPath: string);
procedure RecordComponentUse(const ID: string; NowUTC: TDateTime = 0);
procedure RecordComponentToolUse(const ToolPath: string); overload;
procedure RecordComponentToolUse(const ToolPath: string; const Arguments: array of string); overload;
function ComponentLastUse(const AppPath, ID: string): TDateTime;
procedure ObserveInstalledComponents(const AppPath: string; const IDs: TArray<string>; NowUTC: TDateTime = 0);
procedure RecordComponentInstallation(const AppPath, ID: string; NowUTC: TDateTime = 0);
function ReserveUnusedComponentOffer(const AppPath: string; const IDs: TArray<string>;
  out Unused: TArray<string>; NowUTC: TDateTime = 0): Boolean;
procedure SetComponentCleanupSuppressed(const AppPath: string; Suppressed: Boolean);
function ComponentCleanupSuppressed(const AppPath: string): Boolean;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash, System.DateUtils, System.Generics.Collections,
  System.SyncObjs, Winapi.Windows;

var UsageRoot: string; UsageLock: TCriticalSection;
  LastUseAttempts: TDictionary<string,UInt64>;

function Clock(Value: TDateTime): TDateTime;
begin if Value=0 then Result:=TTimeZone.Local.ToUniversalTime(Now) else Result:=Value; end;

function StateFile(const AppPath: string): string;
var Folder: string; Attributes: DWORD;
begin
  Folder:=IncludeTrailingPathDelimiter(TPath.GetFullPath(AppPath));
  for var Part in ['tools','component-state'] do
  begin
    Folder:=TPath.Combine(Folder,Part); Attributes:=GetFileAttributes(PChar(Folder));
    if (Attributes<>INVALID_FILE_ATTRIBUTES) and (Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
      raise Exception.Create('Папка сведений о модулях содержит ссылку.');
  end;
  Result:=TPath.Combine(Folder,'usage.json'); Attributes:=GetFileAttributes(PChar(Result));
  if (Attributes<>INVALID_FILE_ATTRIBUTES) and (Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
    raise Exception.Create('Файл сведений о модулях содержит ссылку.');
end;

function StateMutex(const AppPath: string): TMutex;
var Identity: string; Handle: THandle; Size: DWORD;
begin
  Identity:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(AppPath));
  // The reader and updater can reach the same portable folder through a
  // junction or with different trailing separators. Lock its physical identity.
  Handle:=CreateFile(PChar(Identity),0,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,0);
  if Handle<>INVALID_HANDLE_VALUE then
  try
    var Buffer: string; SetLength(Buffer,32768);
    Size:=GetFinalPathNameByHandle(Handle,PChar(Buffer),Length(Buffer),0);
    if (Size>0) and (Size<DWORD(Length(Buffer))) then
    begin SetLength(Buffer,Size); Identity:=ExcludeTrailingPathDelimiter(Buffer); end;
  finally CloseHandle(Handle); end;
  Result:=TMutex.Create(nil,False,'Local\HomeLibre-ModuleUsage-'+THashSHA2.GetHashString(LowerCase(Identity)));
end;

function ReadState(const Name: string): TJSONObject;
var Value: TJSONValue;
begin
  if not FileExists(Name) then
  begin Result:=TJSONObject.Create; Result.AddPair('format',TJSONNumber.Create(1)); Result.AddPair('modules',TJSONObject.Create); Exit; end;
  if TFile.GetSize(Name)>512*1024 then raise Exception.Create('Повреждены сведения об использовании модулей.');
  Value:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Name,TEncoding.UTF8));
  if not (Value is TJSONObject) then
  begin Value.Free; raise Exception.Create('Не удалось прочитать сведения об использовании модулей.'); end;
  Result:=TJSONObject(Value);
  if (Result.GetValue<Integer>('format',0)<>1) or not (Result.GetValue('modules') is TJSONObject) then
  begin Result.Free; raise Exception.Create('Неизвестный формат сведений об использовании модулей.'); end;
end;

procedure SetText(Root: TJSONObject; const Name, Value: string);
begin Root.RemovePair(Name).Free; Root.AddPair(Name,Value); end;

function DateValue(Root: TJSONObject; const Name: string): TDateTime;
begin
  Result:=0;
  try TryISO8601ToDate(Root.GetValue<string>(Name,''),Result,True);
  except Result:=0; end;
end;

procedure SaveState(const Name: string; Root: TJSONObject);
var Temporary: string; Stream: TFileStream; Bytes: TBytes;
begin
  ForceDirectories(ExtractFileDir(Name)); Temporary:=Name+'.'+TGUID.NewGuid.ToString+'.tmp';
  Bytes:=TEncoding.UTF8.GetBytes(Root.ToJSON);
  try
    Stream:=TFileStream.Create(Temporary,fmCreate or fmShareExclusive);
    try
      if Length(Bytes)>0 then Stream.WriteBuffer(Bytes,Length(Bytes));
      if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
    finally Stream.Free; end;
    if not MoveFileEx(PChar(Temporary),PChar(Name),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  finally if FileExists(Temporary) then System.SysUtils.DeleteFile(Temporary); end;
end;

function ModuleRow(Root: TJSONObject; const ID: string; Time: TDateTime): TJSONObject;
var Modules: TJSONObject;
begin
  Modules:=TJSONObject(Root.GetValue('modules'));
  if not (Modules.GetValue(ID) is TJSONObject) then
  begin Modules.RemovePair(ID).Free; Modules.AddPair(ID,TJSONObject.Create); end;
  Result:=TJSONObject(Modules.GetValue(ID));
  if DateValue(Result,'firstSeenUtc')=0 then SetText(Result,'firstSeenUtc',DateToISO8601(Time,True));
end;

procedure ConfigureComponentUsage(const AppPath: string);
begin
  UsageLock.Acquire;
  try if AppPath='' then UsageRoot:='' else UsageRoot:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(AppPath));
  finally UsageLock.Release; end;
end;

procedure RecordComponentUse(const ID: string; NowUTC: TDateTime);
var AppPath, Name, Key: string; Mutex: TMutex; Root, Row: TJSONObject; Time: TDateTime;
  Tick, Previous: UInt64;
begin
  // Usage metadata must never make a read/conversion fail.
  try
    UsageLock.Acquire;
    try
      AppPath:=UsageRoot;
      if (AppPath='') or (ID='') or (ID.Length>64) then Exit;
      if NowUTC=0 then
      begin
        // An illustrated book can decode thousands of images. Even reading
        // the ledger and taking a cross-process lock for each would slow it.
        Tick:=GetTickCount64; Key:=LowerCase(AppPath)+'|'+LowerCase(ID);
        if LastUseAttempts.TryGetValue(Key,Previous) and (Tick-Previous<60000) then Exit;
        if LastUseAttempts.Count>=256 then LastUseAttempts.Clear;
        LastUseAttempts.AddOrSetValue(Key,Tick);
      end;
    finally UsageLock.Release; end;
    Name:=StateFile(AppPath); Mutex:=StateMutex(AppPath);
    try
      if not (Mutex.WaitFor(250) in [wrSignaled,wrAbandoned]) then Exit;
      try
        Root:=ReadState(Name);
        try
          Time:=Clock(NowUTC); Row:=ModuleRow(Root,ID,Time);
          if Abs(Time-DateValue(Row,'lastUsedUtc'))<1/1440 then Exit;
          SetText(Row,'lastUsedUtc',DateToISO8601(Time,True)); SaveState(Name,Root);
        finally Root.Free; end;
      finally Mutex.Release; end;
    finally Mutex.Free; end;
  except end;
end;

procedure RecordComponentToolUse(const ToolPath: string);
var AppPath, Relative: string;
begin
 try
  UsageLock.Acquire; try AppPath:=UsageRoot; finally UsageLock.Release; end;
  if (AppPath='') or not TPath.GetFullPath(ToolPath).StartsWith(AppPath+PathDelim,True) then Exit;
  Relative:=Copy(TPath.GetFullPath(ToolPath),Length(AppPath)+2,MaxInt).Replace('\','/');
  if SameText(Relative,'libzstd.dll') then begin RecordComponentUse('Zstandard'); Exit; end;
  if SameText(Relative,'MHLMcpServer.exe') then begin RecordComponentUse('MHLMcpServer'); Exit; end;
  for var Pair in TArray<string>.Create('tools/python/|BookProcessing','tools/images/|ImageProcessing',
    'tools/kindle-export/|KindleExport','tools/kindle/python/|BookConverter','tools/office/|LegacyOffice',
    'tools/xps/|XPS','tools/pdfium/|PDFium','tools/djvu/|DjVuLibre','tools/doc/|DocSharp',
    'tools/jpeg-xl/|JPEG XL','tools/7zip/|7-Zip','tools/webp/|WebP','tools/ibk/|IBK',
    'Readers/AlReader/|AlReader','Readers/SumatraPDF/|SumatraPDF') do
    if Relative.StartsWith(Pair.Split(['|'])[0],True) then
    begin RecordComponentUse(Pair.Split(['|'])[1]); Exit; end;
 except end;
end;

procedure RecordComponentToolUse(const ToolPath: string; const Arguments: array of string);
begin
  for var Argument in Arguments do
    if SameText(Argument,'--version') or SameText(Argument,'-version') or
      SameText(Argument,'--help') or SameText(Argument,'-h') or (Argument='-V') then Exit;
  RecordComponentToolUse(ToolPath);
end;

function ComponentLastUse(const AppPath, ID: string): TDateTime;
var Mutex: TMutex; Root: TJSONObject; Modules: TJSONObject;
begin
  Result:=0; Mutex:=StateMutex(AppPath);
  try
    if not (Mutex.WaitFor(1000) in [wrSignaled,wrAbandoned]) then Exit;
    try
      Root:=ReadState(StateFile(AppPath));
      try
        Modules:=TJSONObject(Root.GetValue('modules'));
        if Modules.GetValue(ID) is TJSONObject then Result:=DateValue(TJSONObject(Modules.GetValue(ID)),'lastUsedUtc');
      finally Root.Free; end;
    finally Mutex.Release; end;
  finally Mutex.Free; end;
end;

procedure ObserveInstalledComponents(const AppPath: string; const IDs: TArray<string>; NowUTC: TDateTime);
var Mutex: TMutex; Root: TJSONObject;
begin
  Mutex:=StateMutex(AppPath);
  try
    if not (Mutex.WaitFor(1000) in [wrSignaled,wrAbandoned]) then Exit;
    try
      Root:=ReadState(StateFile(AppPath));
      try for var ID in IDs do ModuleRow(Root,ID,Clock(NowUTC)); SaveState(StateFile(AppPath),Root);
      finally Root.Free; end;
    finally Mutex.Release; end;
  finally Mutex.Free; end;
end;

function ReserveUnusedComponentOffer(const AppPath: string; const IDs: TArray<string>;
  out Unused: TArray<string>; NowUTC: TDateTime): Boolean;
var Mutex: TMutex; Root, Row: TJSONObject; Time, Last: TDateTime;
begin
  Result:=False; Unused:=nil; Mutex:=StateMutex(AppPath);
  try
    if not (Mutex.WaitFor(1000) in [wrSignaled,wrAbandoned]) then Exit;
    try
      Root:=ReadState(StateFile(AppPath));
      try
        Time:=Clock(NowUTC);
        if Root.GetValue<Boolean>('suppressed',False) or (DateValue(Root,'nextOfferUtc')>Time) then Exit;
        for var ID in IDs do
        begin
          Row:=ModuleRow(Root,ID,Time); Last:=DateValue(Row,'lastUsedUtc');
          if DateValue(Row,'firstSeenUtc')>Last then Last:=DateValue(Row,'firstSeenUtc');
          if (Time>=Last) and (Time-Last>=30) then Unused:=Unused+TArray<string>.Create(ID);
        end;
        Result:=Length(Unused)>0;
        if Result then SetText(Root,'nextOfferUtc',DateToISO8601(IncMonth(Time),True));
        SaveState(StateFile(AppPath),Root);
      finally Root.Free; end;
    finally Mutex.Release; end;
  finally Mutex.Free; end;
end;

procedure SetComponentCleanupSuppressed(const AppPath: string; Suppressed: Boolean);
var Mutex: TMutex; Root: TJSONObject;
begin
  Mutex:=StateMutex(AppPath);
  try
    if not (Mutex.WaitFor(1000) in [wrSignaled,wrAbandoned]) then Exit;
    try
      Root:=ReadState(StateFile(AppPath));
      try Root.RemovePair('suppressed').Free; Root.AddPair('suppressed',TJSONBool.Create(Suppressed)); SaveState(StateFile(AppPath),Root);
      finally Root.Free; end;
    finally Mutex.Release; end;
  finally Mutex.Free; end;
end;

procedure RecordComponentInstallation(const AppPath, ID: string; NowUTC: TDateTime);
var Mutex: TMutex; Root, Row: TJSONObject;
begin
  if ID='SQLite' then Exit;
  try
    Mutex:=StateMutex(AppPath);
    try
      if not (Mutex.WaitFor(1000) in [wrSignaled,wrAbandoned]) then Exit;
      try
        Root:=ReadState(StateFile(AppPath));
        try
          Row:=ModuleRow(Root,ID,Clock(NowUTC));
          SetText(Row,'firstSeenUtc',DateToISO8601(Clock(NowUTC),True)); SaveState(StateFile(AppPath),Root);
        finally Root.Free; end;
      finally Mutex.Release; end;
    finally Mutex.Free; end;
  except end;
end;

function ComponentCleanupSuppressed(const AppPath: string): Boolean;
var Root: TJSONObject;
begin Root:=ReadState(StateFile(AppPath)); try Result:=Root.GetValue<Boolean>('suppressed',False); finally Root.Free; end; end;

initialization
  UsageLock:=TCriticalSection.Create;
  LastUseAttempts:=TDictionary<string,UInt64>.Create;
finalization
  LastUseAttempts.Free;
  UsageLock.Free;
end.
