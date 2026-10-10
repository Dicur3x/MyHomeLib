unit unit_BookCache;

interface

uses System.Classes, System.SysUtils;

type
  TBookCacheWrite = class
  private
    FSource: string;
    FValid: Boolean;
    FPending: TArray<string>;
  public
    constructor Create(const Source: string);
    destructor Destroy; override;
    function TemporaryName(const Destination: string): string;
    procedure Publish(const Temporary: string; var Destination: string; const TemporaryStamp: string = '');
  end;

function BookCachePath: string;
function CurrentBookCacheFile(const FileName: string): string;
function ExistingBookCacheFile(const FileName: string): string;
function BookCacheMigrationBusy: Boolean;
function BookCacheMigrationError: string;
function BookCacheMigrationPending: Boolean;
procedure RetryBookCacheMigration;
procedure StopBookCacheMigration;
procedure ChangeBookCacheDirectory(const Directory: string);
procedure RefreshBookCache(const Wait: Boolean = False);
procedure ScheduleBookCacheMaintenance;
function BookCacheIndexReady: Boolean;
function BookCacheUsage: Int64;
function BookCacheSizeText(Bytes: Int64): string;
function OpenCachedBookFile(const FileName: string): TStream;
function BookCacheSource(const FileName: string): string;
procedure RegisterBookCacheFile(const FileName, Source: string);
procedure PinReaderCacheFile(const FileName: string);
procedure TrimBookCache(const KeepFile: string = '');
procedure ClearBookCache;
procedure FinishBookCacheSession;
procedure RemoveBookCacheSource(const Root: string; const RetainedRoots: TArray<string>);

implementation

uses Winapi.Windows, System.IOUtils, System.Generics.Collections,
  System.Generics.Defaults, System.SyncObjs, System.JSON,
  unit_Settings, unit_Consts, dm_user;

type
  TCacheEntry = record
    Name, Mirror, Source: string;
    Size: Int64;
    Used, WriteRevision: UInt64;
    Temporary, Retired: Boolean;
  end;
  TCacheReadStream = class(TFileStream)
  public destructor Destroy; override;
  end;
  TCacheMigration = class(TThread)
  protected procedure Execute; override;
  public OldRoots: TArray<string>; NewRoot: string; Error: string;
  end;
  TCacheMaintenance = class(TThread)
  protected procedure Execute; override;
  end;

var CacheGuard: TObject; SessionCachePath, LegacyRoot: string;
  PendingRoots: TList<string>; RootHistory: TDictionary<string,string>;
  Migration: TCacheMigration; Maintenance: TCacheMaintenance;
  CacheEpoch, CacheRevision, LastRefresh: UInt64; LastMigrationError: string;
  IndexReady, Closing, CacheRetired: Boolean; IndexBytes: Int64; MaintenanceWaiters: Integer;
  CacheIndex: TDictionary<string,TCacheEntry>;
  ReaderPins: TDictionary<string,UInt64>; Writers: TList<TBookCacheWrite>;
procedure StartCacheMigration; forward;
procedure StartMaintenance; forward;

function WithinRoot(const Source, Root: string): Boolean;
begin
  Result:=(Root<>'') and TPath.GetFullPath(Source).StartsWith(
    IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),True);
end;

function SafeFolder(const Folder: string): Boolean;
var Attributes: DWORD;
begin
  Attributes:=GetFileAttributes(PChar(Folder));
  Result:=(Attributes<>INVALID_FILE_ATTRIBUTES) and
    (Attributes and FILE_ATTRIBUTE_DIRECTORY<>0) and (Attributes and FILE_ATTRIBUTE_REPARSE_POINT=0);
end;

function PrivateRoot(const Root: string): Boolean;
begin
  Result:=SameFileName(Root,TPath.Combine(Settings.DataPath,'BookCache')) or
    SameText(ExtractFileName(ExcludeTrailingPathDelimiter(Root)),'HomeLibRu-BookCache') or
    ((LegacyRoot<>'') and SameFileName(Root,LegacyRoot));
end;

procedure SavePendingRoots;
var ArrayValue: TJSONArray; Root: string;
begin
  if PendingRoots.Count=0 then Settings.BookCachePreviousPath:=''
  else if PendingRoots.Count=1 then Settings.BookCachePreviousPath:=PendingRoots[0]
  else
  begin
    ArrayValue:=TJSONArray.Create;
    try for Root in PendingRoots do ArrayValue.Add(Root);
      Settings.BookCachePreviousPath:=ArrayValue.ToJSON;
    finally ArrayValue.Free; end;
  end;
  Settings.SaveSettings;
end;

procedure AddPendingRoot(const Root: string);
var Existing, Normalized: string;
begin
  if Root='' then Exit;
  Normalized:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Root));
  if SameFileName(Normalized,SessionCachePath) or not PrivateRoot(Normalized) then Exit;
  for Existing in PendingRoots do if SameFileName(Existing,Normalized) then Exit;
  PendingRoots.Add(Normalized); RootHistory.AddOrSetValue(Normalized,SessionCachePath);
end;

function BookCachePath: string;
var Value: TJSONValue; Item: TJSONValue; Root: string;
begin
  TMonitor.Enter(CacheGuard);
  try
    if SessionCachePath='' then
    begin
      if Settings.BookCacheDirectory='' then SessionCachePath:=TPath.Combine(Settings.DataPath,'BookCache')
      else SessionCachePath:=TPath.Combine(TPath.GetFullPath(Settings.BookCacheDirectory),'HomeLibRu-BookCache');
      if Settings.ReadDir<>'' then LegacyRoot:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Settings.ReadPath));
      Root:=Settings.BookCachePreviousPath;
      if Root.StartsWith('[') then
      begin
        Value:=TJSONObject.ParseJSONValue(Root);
        try if Value is TJSONArray then
          for Item in TJSONArray(Value) do if Item is TJSONString then AddPendingRoot(Item.Value);
        finally Value.Free; end;
      end else AddPendingRoot(Root);
      // Only owned, stamped homelib-* files in the legacy reading directory move.
      if (LegacyRoot<>'') and SafeFolder(LegacyRoot) then AddPendingRoot(LegacyRoot);
      if PendingRoots.Count>0 then begin SavePendingRoots; StartCacheMigration; end;
      StartMaintenance;
    end;
    Result:=SessionCachePath;
  finally TMonitor.Exit(CacheGuard); end;
end;

function ManagedFile(const FileName: string): Boolean;
var Parent, Name, Root, Base: string; Attributes: DWORD; IsLegacy: Boolean;
begin
  Result:=False; Parent:=TPath.GetDirectoryName(TPath.GetFullPath(FileName));
  Name:=LowerCase(ExtractFileName(FileName)); if not Name.StartsWith('homelib-') then Exit;
  Root:=''; TMonitor.Enter(CacheGuard);
  try
    BookCachePath;
    if SameFileName(Parent,SessionCachePath) or
      SameFileName(Parent,TPath.Combine(SessionCachePath,WEBP_READER_CACHE_FOLDER)) then Root:=SessionCachePath
    else for Base in PendingRoots do
      if SameFileName(Parent,Base) or SameFileName(Parent,TPath.Combine(Base,WEBP_READER_CACHE_FOLDER)) then
      begin Root:=Base; Break; end;
    IsLegacy:=(Root<>'') and (LegacyRoot<>'') and SameFileName(Root,LegacyRoot);
  finally TMonitor.Exit(CacheGuard); end;
  if (Root='') or not SafeFolder(Root) or not SafeFolder(Parent) then Exit;
  if IsLegacy then
  begin
    Base:=FileName;
    if Base.EndsWith('.origin',True) then Delete(Base,Length(Base)-6,7)
    else if Base.EndsWith('.source',True) then Delete(Base,Length(Base)-6,7)
    else if Base.EndsWith('.retire',True) then Delete(Base,Length(Base)-6,7);
    if not FileExists(Base+'.source') and not FileExists(Base+'.origin') then Exit;
  end;
  Attributes:=GetFileAttributes(PChar(FileName));
  Result:=(Attributes=INVALID_FILE_ATTRIBUTES) or
    (Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)=0);
end;

function PendingOwnerActive(const Name: string): Boolean;
var Text: string; P, I: Integer; PID: Cardinal; Handle: THandle;
begin
  Result:=True; Text:=ExtractFileName(Name); P:=Pos('.pending-',Text);
  if P=0 then Exit; Text:=Copy(Text,P+9,MaxInt);
  if Text.StartsWith('transfer-') then Delete(Text,1,9);
  I:=1; while (I<=Length(Text)) and CharInSet(Text[I],['0'..'9']) do Inc(I);
  if not TryStrToUInt(Copy(Text,1,I-1),PID) or (PID=0) then Exit;
  Handle:=OpenProcess(SYNCHRONIZE,False,PID);
  if Handle=0 then Exit(GetLastError<>ERROR_INVALID_PARAMETER);
  try Result:=WaitForSingleObject(Handle,0)<>WAIT_OBJECT_0; finally CloseHandle(Handle); end;
end;

function DeleteStalePending(const Name: string): Boolean;
var Handle: THandle;
begin
  Result:=False; if PendingOwnerActive(Name) or not ManagedFile(Name) then Exit;
  Handle:=CreateFile(PChar(Name),$00010000,0,nil,OPEN_EXISTING,
    FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE,0);
  if Handle=INVALID_HANDLE_VALUE then Exit;
  CloseHandle(Handle); Result:=True;
end;

function ReadEntry(const Name: string; out Entry: TCacheEntry): Boolean;
var Attributes: TWin32FileAttributeData;
begin
  Entry:=Default(TCacheEntry); Result:=False;
  if not GetFileAttributesEx(PChar(Name),GetFileExInfoStandard,@Attributes) then Exit;
  if Attributes.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then Exit;
  Entry.Name:=Name;
  Entry.Size:=Int64(Attributes.nFileSizeHigh) shl 32 or Attributes.nFileSizeLow;
  Entry.Used:=UInt64(Attributes.ftLastWriteTime.dwHighDateTime) shl 32 or Attributes.ftLastWriteTime.dwLowDateTime;
  Entry.Temporary:=LowerCase(ExtractFileName(Name)).Contains('.pending');
  if not Entry.Temporary then
  begin
    if FileExists(Name+'.origin') then
    begin
      Inc(Entry.Size,TFile.GetSize(Name+'.origin'));
      try Entry.Source:=TFile.ReadAllText(Name+'.origin',TEncoding.UTF8); except end;
    end;
    if FileExists(Name+'.source') then Inc(Entry.Size,TFile.GetSize(Name+'.source'));
    Entry.Retired:=FileExists(Name+'.retire');
  end;
  Result:=True;
end;

function Entries(const Root: string): TList<TCacheEntry>;
var Folder, Name: string; Search: TSearchRec; Entry: TCacheEntry;
begin
  Result:=TList<TCacheEntry>.Create; if not SafeFolder(Root) then Exit;
  for Folder in [Root,TPath.Combine(Root,WEBP_READER_CACHE_FOLDER)] do
    if SafeFolder(Folder) and (FindFirst(TPath.Combine(Folder,'homelib-*'),faAnyFile,Search)=0) then
    try
      repeat
        Name:=TPath.Combine(Folder,Search.Name);
        if (Search.Attr and faDirectory<>0) or not ManagedFile(Name) then Continue;
        if Name.Contains('.pending') and DeleteStalePending(Name) then Continue;
        if Name.EndsWith('.origin',True) or Name.EndsWith('.source',True) or Name.EndsWith('.retire',True) then Continue;
        if ReadEntry(Name,Entry) then Result.Add(Entry);
      until FindNext(Search)<>0;
    finally System.SysUtils.FindClose(Search); end;
end;

procedure RemoveIndex(const Name: string);
var Entry: TCacheEntry;
begin
  if CacheIndex.TryGetValue(Name,Entry) then
  begin TInterlocked.Add(IndexBytes,-Entry.Size); CacheIndex.Remove(Name); Inc(CacheRevision); end;
  ReaderPins.Remove(Name);
end;

procedure UpdateIndex(const Name: string; const Written: Boolean = False);
var Entry, Old: TCacheEntry;
begin
  if not ReadEntry(Name,Entry) then begin RemoveIndex(Name); Exit; end;
  if CacheIndex.TryGetValue(Name,Old) then
  begin TInterlocked.Add(IndexBytes,-Old.Size); Entry.WriteRevision:=Old.WriteRevision; end;
  Inc(CacheRevision); if Written then Entry.WriteRevision:=CacheRevision;
  if Entry.Retired then CacheRetired:=True;
  CacheIndex.AddOrSetValue(Name,Entry); TInterlocked.Add(IndexBytes,Entry.Size);
end;

procedure TCacheMaintenance.Execute;
var Roots: TArray<string>; List, Part: TList<TCacheEntry>; Entry, Old: TCacheEntry;
  Root: string; Revision: UInt64; Total: Int64; Attempt: Integer;
  Replacement, RetiredIndex: TDictionary<string,TCacheEntry>;
begin
  try
    for Attempt:=1 to 3 do
    begin
      TMonitor.Enter(CacheGuard);
      try Roots:=PendingRoots.ToArray; Roots:=Roots+[SessionCachePath]; Revision:=CacheRevision;
      finally TMonitor.Exit(CacheGuard); end;
      List:=TList<TCacheEntry>.Create;
      try
        for Root in Roots do
        begin
          if Terminated then Exit;
          Part:=Entries(Root); try List.AddRange(Part); finally Part.Free; end;
        end;
        Replacement:=TDictionary<string,TCacheEntry>.Create(TIStringComparer.Ordinal);
        RetiredIndex:=nil;
        try
          Total:=0;
          for Entry in List do begin Replacement.AddOrSetValue(Entry.Name,Entry); Inc(Total,Entry.Size); end;
          TMonitor.Enter(CacheGuard);
          try
            if Revision<>CacheRevision then Continue;
            for Root in Replacement.Keys.ToArray do
              if CacheIndex.TryGetValue(Root,Old) then
              begin Entry:=Replacement[Root]; Entry.WriteRevision:=Old.WriteRevision; Replacement[Root]:=Entry; end;
            RetiredIndex:=CacheIndex; CacheIndex:=Replacement; Replacement:=nil;
            TInterlocked.Exchange(IndexBytes,Total); IndexReady:=True; LastRefresh:=GetTickCount64;
            CacheRetired:=False; for Entry in CacheIndex.Values do if Entry.Retired then begin CacheRetired:=True; Break; end;
          finally TMonitor.Exit(CacheGuard); end;
        finally Replacement.Free; RetiredIndex.Free; end;
        TrimBookCache; Exit;
      finally List.Free; end;
    end;
  except
    // An unavailable cache directory must never take down the main application.
  end;
end;

procedure StartMaintenance;
begin
  if Closing then Exit;
  if Assigned(Maintenance) and Maintenance.Finished and (MaintenanceWaiters=0) then FreeAndNil(Maintenance);
  if Assigned(Maintenance) then Exit;
  Maintenance:=TCacheMaintenance.Create(True); Maintenance.FreeOnTerminate:=False; Maintenance.Start;
end;

procedure RefreshBookCache(const Wait: Boolean);
var Worker: TCacheMaintenance;
begin
  BookCachePath; TMonitor.Enter(CacheGuard);
  try
    StartMaintenance; Worker:=Maintenance;
    if Wait and Assigned(Worker) then Inc(MaintenanceWaiters);
  finally TMonitor.Exit(CacheGuard); end;
  if Wait and Assigned(Worker) then
  try Worker.WaitFor;
  finally TMonitor.Enter(CacheGuard); try Dec(MaintenanceWaiters); finally TMonitor.Exit(CacheGuard); end; end;
end;

procedure ScheduleBookCacheMaintenance;
begin
  BookCachePath; TMonitor.Enter(CacheGuard);
  try if not IndexReady or (GetTickCount64-LastRefresh>=60000) then StartMaintenance;
  finally TMonitor.Exit(CacheGuard); end;
end;

function BookCacheIndexReady: Boolean;
begin TMonitor.Enter(CacheGuard); try Result:=IndexReady; finally TMonitor.Exit(CacheGuard); end; end;

function AllEntries: TList<TCacheEntry>;
begin Result:=TList<TCacheEntry>.Create(CacheIndex.Values); end;

function LogicalEntries: TList<TCacheEntry>;
var Seen: TDictionary<string,Integer>; Entry, Combined: TCacheEntry; Key: string; Index: Integer;
begin
  Result:=TList<TCacheEntry>.Create; Seen:=TDictionary<string,Integer>.Create(TIStringComparer.Ordinal);
  try
    for Entry in CacheIndex.Values do
    begin
      Key:=CurrentBookCacheFile(Entry.Name);
      if Seen.TryGetValue(Key,Index) then
      begin
        Combined:=Result[Index]; Combined.Mirror:=Entry.Name;
        if Entry.Size>Combined.Size then Combined.Size:=Entry.Size;
        if Entry.Used>Combined.Used then Combined.Used:=Entry.Used;
        Combined.Retired:=Combined.Retired or Entry.Retired; Result[Index]:=Combined;
      end else begin Seen.Add(Key,Result.Count); Result.Add(Entry); end;
    end;
  finally Seen.Free; end;
end;

function DeleteEntry(const Name: string): Boolean;
var Suffix: string;
begin
  Result:=ManagedFile(Name) and (not FileExists(Name) or System.SysUtils.DeleteFile(Name));
  if Result then
  begin
    for Suffix in ['.origin','.source','.retire'] do
      if ManagedFile(Name+Suffix) then System.SysUtils.DeleteFile(Name+Suffix);
    RemoveIndex(Name);
  end;
end;

procedure RetireEntry(const Name: string);
var Entry: TCacheEntry;
begin
  if not ManagedFile(Name) then Exit;
  TFile.WriteAllText(Name+'.retire','',TEncoding.UTF8); CacheRetired:=True;
  if CacheIndex.TryGetValue(Name,Entry) then begin Entry.Retired:=True; CacheIndex[Name]:=Entry; end;
end;

procedure TrimBookCache(const KeepFile: string);
var List: TList<TCacheEntry>; Entry: TCacheEntry; Total, Limit: Int64; PinUntil: UInt64;
  Removed, MirrorRemoved: Boolean;
begin
  if Closing then Exit;
  TMonitor.Enter(CacheGuard);
  try
    if not IndexReady then Exit;
    Limit:=Int64(Settings.BookCacheLimitMB)*1024*1024;
    if (IndexBytes<=Limit) and not CacheRetired then Exit;
    List:=LogicalEntries;
    try
      Total:=0; CacheRetired:=False; for Entry in List do
      begin Inc(Total,Entry.Size); if Entry.Retired then CacheRetired:=True; end;
      Limit:=Int64(Settings.BookCacheLimitMB)*1024*1024;
      if Total<=Limit then
      begin
        Removed:=False; for Entry in List do if Entry.Retired then begin Removed:=True; Break; end;
        if not Removed then Exit;
      end;
      List.Sort(TComparer<TCacheEntry>.Construct(
        function(const A,B: TCacheEntry): Integer
        begin if A.Used<B.Used then Result:=-1 else if A.Used>B.Used then Result:=1 else Result:=0; end));
      for Entry in List do
        if not Entry.Temporary and not SameFileName(Entry.Name,KeepFile) and
          ((Entry.Mirror='') or not SameFileName(Entry.Mirror,KeepFile)) and
          ((Total>Limit) or Entry.Retired) then
          if (Entry.Retired or not ReaderPins.TryGetValue(Entry.Name,PinUntil) or (GetTickCount64>=PinUntil)) and
            ((Entry.Mirror='') or Entry.Retired or not ReaderPins.TryGetValue(Entry.Mirror,PinUntil) or (GetTickCount64>=PinUntil)) then
          begin
            Removed:=DeleteEntry(Entry.Name); MirrorRemoved:=True;
            if Entry.Mirror<>'' then
            begin
              MirrorRemoved:=DeleteEntry(Entry.Mirror);
              if not MirrorRemoved then RetireEntry(Entry.Mirror);
              if not Removed then RetireEntry(Entry.Name);
            end;
            if Removed and MirrorRemoved then Dec(Total,Entry.Size);
          end;
    finally List.Free; end;
  finally TMonitor.Exit(CacheGuard); end;
end;

function BookCacheUsage: Int64;
begin ScheduleBookCacheMaintenance; Result:=TInterlocked.CompareExchange(IndexBytes,0,0); end;

function BookCacheSizeText(Bytes: Int64): string;
begin
  if Bytes>=Int64(1024)*1024*1024 then Result:=FormatFloat('0.00',Bytes/(Int64(1024)*1024*1024))+' ГБ'
  else Result:=FormatFloat('0.00',Bytes/(1024*1024))+' МБ';
end;

procedure Touch(const Name: string);
var Handle: THandle; Used: TFileTime;
begin
  Handle:=CreateFile(PChar(Name),FILE_WRITE_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then Exit;
  try GetSystemTimeAsFileTime(Used); SetFileTime(Handle,nil,nil,@Used); finally CloseHandle(Handle); end;
end;

function OpenCachedBookFile(const FileName: string): TStream;
var Name: string;
begin
  BookCachePath; if not BookCacheIndexReady then RefreshBookCache(True);
  TMonitor.Enter(CacheGuard);
  try
    Name:=ExistingBookCacheFile(FileName);
    if ManagedFile(Name) then
    begin
      Result:=TCacheReadStream.Create(Name,fmOpenRead or fmShareDenyWrite);
      Touch(Name); UpdateIndex(Name); TrimBookCache(Name);
    end else Result:=TFileStream.Create(Name,fmOpenRead or fmShareDenyWrite);
  finally TMonitor.Exit(CacheGuard); end;
end;

destructor TCacheReadStream.Destroy;
begin inherited; TrimBookCache; end;

function BookCacheSource(const FileName: string): string;
var Entry: TCacheEntry; Name: string;
begin
  Result:=FileName; BookCachePath;
  TMonitor.Enter(CacheGuard);
  try
    Name:=ExistingBookCacheFile(FileName);
    if CacheIndex.TryGetValue(Name,Entry) and (Entry.Source<>'') then Result:=Entry.Source;
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure RegisterBookCacheFile(const FileName, Source: string);
begin
  BookCachePath;
  TMonitor.Enter(CacheGuard);
  try
    if not ManagedFile(FileName) or not FileExists(FileName) then Exit;
    TFile.WriteAllText(FileName+'.origin',TPath.GetFullPath(Source),TEncoding.UTF8);
    System.SysUtils.DeleteFile(FileName+'.retire'); Touch(FileName); UpdateIndex(FileName,True);
    TrimBookCache(FileName);
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure PinReaderCacheFile(const FileName: string);
begin
  TMonitor.Enter(CacheGuard);
  try if ManagedFile(FileName) then ReaderPins.AddOrSetValue(FileName,GetTickCount64+30000);
  finally TMonitor.Exit(CacheGuard); end;
end;

constructor TBookCacheWrite.Create(const Source: string);
begin
  inherited Create; BookCachePath; FSource:=TPath.GetFullPath(Source);
  TMonitor.Enter(CacheGuard); try FValid:=not Closing; Writers.Add(Self); finally TMonitor.Exit(CacheGuard); end;
end;

destructor TBookCacheWrite.Destroy;
var Name: string;
begin
  TMonitor.Enter(CacheGuard);
  try
    Writers.Remove(Self);
    for Name in FPending do
    begin if ManagedFile(Name) then System.SysUtils.DeleteFile(Name); RemoveIndex(Name); end;
  finally TMonitor.Exit(CacheGuard); end;
  inherited;
end;

function TBookCacheWrite.TemporaryName(const Destination: string): string;
begin
  Result:=Destination+'.pending-'+IntToStr(GetCurrentProcessId)+'-'+IntToStr(GetCurrentThreadId)+'-'+TGUID.NewGuid.ToString;
  TMonitor.Enter(CacheGuard); try FPending:=FPending+[Result]; finally TMonitor.Exit(CacheGuard); end;
end;

procedure TBookCacheWrite.Publish(const Temporary: string; var Destination: string; const TemporaryStamp: string);
begin
  // The first scan must not be waited for while holding the publish lock.
  if not BookCacheIndexReady then RefreshBookCache(True);
  TMonitor.Enter(CacheGuard);
  try
    if not FValid or Closing then raise EAbort.Create('Подготовка отменена: кэш очищен или источник отключён.');
    Destination:=CurrentBookCacheFile(Destination); ForceDirectories(ExtractFileDir(Destination));
    if not ManagedFile(Destination) then raise Exception.Create('Папка кэша недоступна.');
    if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    if TemporaryStamp<>'' then
      if not MoveFileEx(PChar(TemporaryStamp),PChar(Destination+'.source'),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      begin System.SysUtils.DeleteFile(Destination+'.source'); RaiseLastOSError; end;
    RemoveIndex(Temporary); if TemporaryStamp<>'' then RemoveIndex(TemporaryStamp);
    RegisterBookCacheFile(Destination,FSource);
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure ClearBookCache;
var List: TList<TCacheEntry>; Entry: TCacheEntry; Writer: TBookCacheWrite;
begin
  RefreshBookCache(True); TMonitor.Enter(CacheGuard);
  try
    Inc(CacheEpoch); Inc(CacheRevision); for Writer in Writers do Writer.FValid:=False;
    List:=AllEntries;
    try for Entry in List do
      if Entry.Temporary then begin if DeleteStalePending(Entry.Name) then RemoveIndex(Entry.Name); end
      else if not DeleteEntry(Entry.Name) then RetireEntry(Entry.Name);
    finally List.Free; end;
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure RemoveBookCacheSource(const Root: string; const RetainedRoots: TArray<string>);
var List: TList<TCacheEntry>; Entry: TCacheEntry; Writer: TBookCacheWrite;
  function Needed(const Source: string): Boolean;
  var Retained: string;
  begin
    Result:=not WithinRoot(Source,Root);
    if not Result then for Retained in RetainedRoots do if WithinRoot(Source,Retained) then Exit(True);
  end;
begin
  if Root='' then Exit;
  RefreshBookCache(True); TMonitor.Enter(CacheGuard);
  try
    Inc(CacheEpoch); Inc(CacheRevision);
    for Writer in Writers do if not Needed(Writer.FSource) then Writer.FValid:=False;
    List:=AllEntries;
    try for Entry in List do
      if (Entry.Source<>'') and not Needed(Entry.Source) then
        if not DeleteEntry(Entry.Name) then RetireEntry(Entry.Name);
    finally List.Free; end;
  finally TMonitor.Exit(CacheGuard); end;
end;

function CurrentBookCacheFile(const FileName: string): string;
var OldRoot, BestRoot, Relative, Name: string;
begin
  Result:=FileName; Name:=TPath.GetFullPath(FileName);
  if not LowerCase(ExtractFileName(Name)).StartsWith('homelib-') then Exit;
  TMonitor.Enter(CacheGuard);
  try
    BookCachePath; if WithinRoot(Name,SessionCachePath) then Exit;
    BestRoot:=''; for OldRoot in RootHistory.Keys do
      if WithinRoot(Name,OldRoot) and (Length(OldRoot)>Length(BestRoot)) then BestRoot:=OldRoot;
    if BestRoot<>'' then
    begin Relative:=Copy(Name,Length(IncludeTrailingPathDelimiter(BestRoot))+1,MaxInt);
      Result:=TPath.Combine(SessionCachePath,Relative); end;
  finally TMonitor.Exit(CacheGuard); end;
end;

function ExistingBookCacheFile(const FileName: string): string;
var Candidate, Relative, Root: string;
begin
  TMonitor.Enter(CacheGuard);
  try
    Result:=CurrentBookCacheFile(FileName); if FileExists(Result) then Exit;
    if FileExists(FileName) then Exit(FileName);
    if not WithinRoot(Result,BookCachePath) then Exit;
    Relative:=Copy(Result,Length(IncludeTrailingPathDelimiter(SessionCachePath))+1,MaxInt);
    for Root in PendingRoots do
    begin Candidate:=TPath.Combine(Root,Relative);
      if ManagedFile(Candidate) and FileExists(Candidate) then Exit(Candidate); end;
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure TCacheMigration.Execute;
var List: TList<TCacheEntry>; Entry, TargetEntry: TCacheEntry; Root, Destination, Suffix: string;
  Pending: TArray<string>; Started, PinUntil, Epoch, Revision: UInt64;
  Remaining, PublishAllowed, PreferDestination: Boolean; I: Integer;
begin
  Started:=GetTickCount64;
  try
    RefreshBookCache(True); TMonitor.Enter(CacheGuard);
    try Revision:=CacheRevision; finally TMonitor.Exit(CacheGuard); end;
    repeat
      Remaining:=False; TMonitor.Enter(CacheGuard);
      try List:=AllEntries; Epoch:=CacheEpoch; finally TMonitor.Exit(CacheGuard); end;
      // Newest source data wins if recovery retained several previous roots.
      List.Sort(TComparer<TCacheEntry>.Construct(
        function(const A,B: TCacheEntry): Integer
        begin if A.Used>B.Used then Result:=-1 else if A.Used<B.Used then Result:=1 else Result:=0; end));
      try
        for Entry in List do
        begin
          if Terminated then Exit;
          PublishAllowed:=False; for Root in OldRoots do
            if WithinRoot(Entry.Name,Root) then begin PublishAllowed:=True; Break; end;
          if not PublishAllowed or Entry.Temporary then Continue;
          if Entry.Retired then
          begin TMonitor.Enter(CacheGuard); try if not DeleteEntry(Entry.Name) then Remaining:=True;
            finally TMonitor.Exit(CacheGuard); end; Continue; end;
          Destination:=TPath.Combine(NewRoot,Copy(Entry.Name,Length(IncludeTrailingPathDelimiter(Root))+1,MaxInt));
          TMonitor.Enter(CacheGuard);
          try PreferDestination:=CacheIndex.TryGetValue(Destination,TargetEntry) and
            (TargetEntry.WriteRevision>Revision);
          finally TMonitor.Exit(CacheGuard); end;
          if not PreferDestination then
          begin
            ForceDirectories(ExtractFilePath(Destination));
            if not SafeFolder(NewRoot) or not SafeFolder(ExtractFileDir(Destination)) then
              raise Exception.Create('Папка кэша не должна быть ссылкой на другую папку.');
            Pending:=nil;
            try
              // Stage the whole entry before replacing an existing destination.
              for Suffix in ['','.origin','.source'] do
              begin
                if not FileExists(Entry.Name+Suffix) then Continue;
                Pending:=Pending+[Destination+Suffix+'.pending-transfer-'+IntToStr(GetCurrentProcessId)];
                if not CopyFile(PChar(Entry.Name+Suffix),PChar(Pending[High(Pending)]),False) then RaiseLastOSError;
              end;
              TMonitor.Enter(CacheGuard);
              try
                PublishAllowed:=(Epoch=CacheEpoch) and FileExists(Entry.Name) and not Entry.Retired;
                if CacheIndex.TryGetValue(Destination,TargetEntry) and (TargetEntry.WriteRevision>Revision) then PublishAllowed:=False;
                if PublishAllowed and not Terminated then
                begin
                  for I:=0 to High(Pending) do
                  begin
                    Suffix:=Copy(Pending[I],Length(Destination)+1,MaxInt);
                    Suffix:=Copy(Suffix,1,Pos('.pending-transfer-',Suffix)-1);
                    if not MoveFileEx(PChar(Pending[I]),PChar(Destination+Suffix),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
                    begin System.SysUtils.DeleteFile(Destination+'.source'); RaiseLastOSError; end;
                  end;
                  if not FileExists(Entry.Name+'.source') then System.SysUtils.DeleteFile(Destination+'.source');
                  if not FileExists(Entry.Name+'.origin') then System.SysUtils.DeleteFile(Destination+'.origin');
                  UpdateIndex(Destination,True);
                end;
              finally TMonitor.Exit(CacheGuard); end;
            finally for Suffix in Pending do System.SysUtils.DeleteFile(Suffix); end;
          end;
          TMonitor.Enter(CacheGuard);
          try
            if (Epoch<>CacheEpoch) or not FileExists(Destination) or
              (GetTickCount64-Started<30000) or
              (ReaderPins.TryGetValue(Entry.Name,PinUntil) and (GetTickCount64<PinUntil)) or
              not DeleteEntry(Entry.Name) then Remaining:=True;
          finally TMonitor.Exit(CacheGuard); end;
        end;
      finally List.Free; end;
      if not Remaining then Exit;
      Sleep(250);
    until Terminated;
  except on E: Exception do Error:=E.Message; end;
end;

procedure StartCacheMigration;
begin
  if Assigned(Migration) or (PendingRoots.Count=0) or Closing then Exit;
  Migration:=TCacheMigration.Create(True); Migration.OldRoots:=PendingRoots.ToArray;
  Migration.NewRoot:=SessionCachePath; Migration.FreeOnTerminate:=False; Migration.Start;
end;

function BookCacheMigrationBusy: Boolean;
begin
  BookCachePath; TMonitor.Enter(CacheGuard);
  try
    if Assigned(Migration) and Migration.Finished then
    begin
      Migration.WaitFor; LastMigrationError:=Migration.Error;
      if Migration.Terminated and (LastMigrationError='') then LastMigrationError:='Перенос остановлен. Можно продолжить или выбрать другую папку.';
      if (Migration.Error='') and not Migration.Terminated then
      begin
        PendingRoots.Clear;
        if LegacyRoot<>'' then Settings.ReadDir:='';
        SavePendingRoots; Inc(CacheRevision);
      end;
      FreeAndNil(Migration);
    end;
    Result:=Assigned(Migration);
  finally TMonitor.Exit(CacheGuard); end;
end;

function BookCacheMigrationError: string;
begin TMonitor.Enter(CacheGuard); try Result:=LastMigrationError; finally TMonitor.Exit(CacheGuard); end; end;

function BookCacheMigrationPending: Boolean;
begin BookCacheMigrationBusy; TMonitor.Enter(CacheGuard);
  try Result:=PendingRoots.Count>0; finally TMonitor.Exit(CacheGuard); end; end;

procedure RetryBookCacheMigration;
begin
  if BookCacheMigrationBusy then Exit;
  TMonitor.Enter(CacheGuard); try LastMigrationError:=''; StartCacheMigration; finally TMonitor.Exit(CacheGuard); end;
end;

procedure StopBookCacheMigration;
begin TMonitor.Enter(CacheGuard); try if Assigned(Migration) then Migration.Terminate; finally TMonitor.Exit(CacheGuard); end; end;

procedure ChangeBookCacheDirectory(const Directory: string);
var OldRoot, NewRoot, Root: string; Handle: THandle; Probe: string;
begin
  OldRoot:=BookCachePath;
  if Directory='' then NewRoot:=TPath.Combine(Settings.DataPath,'BookCache')
  else if SameFileName(TPath.GetFullPath(Directory),OldRoot) then NewRoot:=OldRoot
  else NewRoot:=TPath.Combine(TPath.GetFullPath(Directory),'HomeLibRu-BookCache');
  if SameFileName(OldRoot,NewRoot) then begin if not BookCacheMigrationBusy then RetryBookCacheMigration; Exit; end;
  if BookCacheMigrationBusy then raise Exception.Create('Дождитесь завершения переноса кэша или остановите его.');
  for Root in PendingRoots.ToArray+[OldRoot] do
    if WithinRoot(NewRoot,Root) or WithinRoot(Root,NewRoot) then
      raise Exception.Create('Новая папка кэша не должна быть вложена в прежнюю папку или содержать её.');
  ForceDirectories(NewRoot); if not SafeFolder(NewRoot) then raise Exception.Create('Выберите обычную папку для кэша.');
  Probe:=TPath.Combine(NewRoot,'homelib-write-probe-'+TGUID.NewGuid.ToString);
  Handle:=CreateFile(PChar(Probe),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError; CloseHandle(Handle);
  TMonitor.Enter(CacheGuard);
  try
    LastMigrationError:=''; SessionCachePath:=NewRoot; AddPendingRoot(OldRoot);
    RootHistory.Remove(NewRoot);
    for Root in PendingRoots do RootHistory.AddOrSetValue(Root,SessionCachePath);
    // Returning to a former root is safe; it is the destination, not a source.
    for Probe in PendingRoots.ToArray do if SameFileName(Probe,NewRoot) then PendingRoots.Remove(Probe);
    Settings.BookCacheDirectory:=Directory; SavePendingRoots; Inc(CacheRevision);
    StartCacheMigration; StartMaintenance;
  finally TMonitor.Exit(CacheGuard); end;
end;

procedure FinishBookCacheSession;
begin
  if Assigned(Migration) then begin Migration.Terminate; Migration.WaitFor; FreeAndNil(Migration); end;
  if Settings.ClearBookCacheOnExit then ClearBookCache else TrimBookCache;
end;

initialization
  CacheGuard:=TObject.Create; PendingRoots:=TList<string>.Create;
  RootHistory:=TDictionary<string,string>.Create(TIStringComparer.Ordinal);
  CacheIndex:=TDictionary<string,TCacheEntry>.Create(TIStringComparer.Ordinal);
  ReaderPins:=TDictionary<string,UInt64>.Create(TIStringComparer.Ordinal);
  Writers:=TList<TBookCacheWrite>.Create;
finalization
  Closing:=True;
  if Assigned(Migration) then begin Migration.Terminate; Migration.WaitFor; Migration.Free; end;
  if Assigned(Maintenance) then begin Maintenance.Terminate; Maintenance.WaitFor; Maintenance.Free; end;
  Writers.Free; CacheIndex.Free; PendingRoots.Free; RootHistory.Free; ReaderPins.Free; CacheGuard.Free;
end.
