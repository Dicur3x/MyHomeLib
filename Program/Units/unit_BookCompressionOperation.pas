unit unit_BookCompressionOperation;

interface

uses System.Classes, System.SysUtils, System.SyncObjs, System.JSON, System.Generics.Collections,
  unit_BookCompressionPlan, unit_BookCompressionJob;

type
  TCompressionReview = (crNone, crApply, crApplyRemaining, crSkip, crTrial);
  TCompressionPlanFactory = reference to function(const Cancelled:TFunc<Boolean>;
    const Progress:TProc<Int64>):TBookCompressionPlan;
  TBookCompressionOperationOptions = record
    WorkRoot, QueueName, Python, Script, SevenZip, ToolsRoot, Profile, BackupFolder: string;
    Grayscale, ReviewResults, BackupOriginals, EstimateFirst, OnlyNew: Boolean;
  end;
  TBookCompressionOperationStatus = record
    Stage, Source, Member, Error, Warning, ReportFile, PendingJob, BackupFolder: string;
    PreviewFile, PreviewSHA256: string;
    Current, Total, FilesDone, FilesTotal, BooksDone, BooksTotal: Int64;
    ChangedFiles, UnchangedFiles, SkippedFiles, SavedBytes: Int64;
    PreviouslyProcessedBooks: Int64;
    InputBytes, OutputBytes, WorkingBytes: Int64;
    BackupFiles, DiscardedPreparations: Int64;
    ImageChanges: Int64;
    EstimateInputBytes, EstimateKnownInputBytes, EstimateOutputBytes, EstimateArchiveBytes: Int64;
    EstimateUnknownBooks: Int64;
    TrialInputBytes, TrialOutputBytes, TrialSharedFiles: Int64;
    TrialRunning, TrialReady: Boolean;
    Estimating, AwaitingEstimate, EstimateOnly: Boolean;
    Finished, Stopping, AwaitingReview, Recovery, SavingsKnown: Boolean;
  end;

  // The factory runs on this worker and owns its own SQLite connections.
  // Completed durable jobs stay leased until the application refreshes its
  // catalogue/caches and explicitly acknowledges them on the finished thread.
  TBookCompressionOperation = class(TThread)
  private type
    TTrialFile = record
      InputBytes, OutputBytes: Int64;
      Shared: Boolean;
    end;
  private
    FTrialFiles: TDictionary<string,TTrialFile>;
    FOptions: TBookCompressionOperationOptions;
    FFactory: TCompressionPlanFactory;
    FLock: TObject;
    FReviewEvent: TEvent;
    FStop, FDecision: Integer;
    FReviewRemaining, FRecovery, FWorkRegistered: Boolean;
    FState: TBookCompressionOperationStatus;
    FCompleted: TObjectList<TBookCompressionJob>;
    FWork, FCancelFile, FLastError, FEngineSHA256: string;
    FCancelStarted: UInt64;
    FWorkGuard, FWorkLease: THandle;
    function Stopping: Boolean;
    procedure CheckStop;
    procedure SetStage(const Stage: string; Current: Int64 = 0; Total: Int64 = 0);
    procedure Warn(const MessageText: string);
    procedure ReceiveEvent(const Value: string);
    function CancelProducer: Boolean;
    procedure CreateWork;
    procedure OpenWorkGuard;
    procedure OpenWorkLease;
    procedure ReleaseWorkHandles;
    procedure CleanWork;
    procedure CleanRecoveredWork(const Candidate: string);
    procedure CleanAbandonedWork;
    function EngineFingerprint: string;
    function Review(Estimate: Boolean = False): TCompressionReview;
    procedure MeasureTrialFiles(FilePlan:TCompressionFilePlan; Images:TJSONArray; Report:TJSONObject);
    procedure EstimateFile(FilePlan: TCompressionFilePlan);
    function ValidateRestored(JobRequest: TJSONObject): TJSONObject;
    procedure RunFile(FilePlan: TCompressionFilePlan; Trial:Boolean);
    procedure RunRecovery;
  protected
    procedure Execute; override;
  public
    constructor Create(const Options: TBookCompressionOperationOptions;
      const Factory: TCompressionPlanFactory);
    constructor Recover(const Options: TBookCompressionOperationOptions);
    destructor Destroy; override;
    procedure RequestStop;
    procedure Approve(Decision: TCompressionReview);
    function Status: TBookCompressionOperationStatus;
    function QueueRoot: string;
    // Call only after WaitFor and after refreshing affected application views.
    procedure AcknowledgeCompletedJobs;
  end;

function CompressionQueueRoot(const Options: TBookCompressionOperationOptions): string;
function CompressionHasAbandonedPreparation(const Options: TBookCompressionOperationOptions): Boolean;

{$IFDEF MHL_COMPRESSION_TEST}
// Only the guarded native regression executable defines this symbol. Its
// callback terminates that private process at an existing durable job stage.
var CompressionOperationTestFault: TProc<string>;
// Observe decoded producer stages without depending on a GUI timer tick.
var CompressionOperationTestStage: TProc<string>;
{$ENDIF}

implementation

uses Winapi.Windows, System.IOUtils, System.StrUtils, System.Hash, unit_AtomicIniFile,
  unit_MHLExternalTools, unit_ZipMemberDeletion, unit_BookCompressionBackup, unit_BookCompressionReceipt,
  unit_BookCompressionImages, unit_BookCompressionRestored;

const WorkMarker='HomeLibre selected compression work v1';
  RegisteredWorkKind='HomeLibre compression preparation';

type
  TCompressionEventStream = class(TStream)
  private
    FOwner: TBookCompressionOperation;
    FLine: UTF8String;
  public
    constructor Create(Owner: TBookCompressionOperation);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TCompressionEventStream.Create(Owner: TBookCompressionOperation);
begin inherited Create; FOwner:=Owner; end;
function TCompressionEventStream.Read(var Buffer; Count: Longint): Longint;
begin Result:=0; end;
function TCompressionEventStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin Result:=0; end;
function TCompressionEventStream.Write(const Buffer; Count: Longint): Longint;
var Bytes:PByte;
begin
  Bytes:=@Buffer;
  for var I:=0 to Count-1 do
    if Bytes[I]=10 then
    begin
      if FLine<>'' then FOwner.ReceiveEvent(UTF8ToString(FLine));
      FLine:='';
    end
    else
    begin
      if Length(FLine)>=65536 then raise EReadError.Create('Слишком длинный ответ обработчика сжатия.');
      // Append raw UTF-8 bytes; concatenating an ACP AnsiChar transcodes it.
      SetLength(FLine,Length(FLine)+1); FLine[Length(FLine)]:=AnsiChar(Bytes[I]);
    end;
  Result:=Count;
end;

function ReadObject(const FileName:string):TJSONObject;
var Stream:TFileStream; Bytes:TBytes; Value:TJSONValue;
begin
  Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size<=0) or (Stream.Size>16*1024*1024) then
      raise EReadError.Create('Некорректный размер отчёта сжатия.');
    SetLength(Bytes,Integer(Stream.Size)); Stream.ReadBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
  Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  if not (Value is TJSONObject) then
  begin Value.Free; raise EReadError.Create('Не удалось прочитать отчёт сжатия.'); end;
  Result:=TJSONObject(Value);
end;

procedure SaveText(const FileName, Text:string);
var Stream:TStringStream;
begin
  Stream:=TStringStream.Create(Text,TEncoding.UTF8);
  try SaveStreamAtomically(Stream,DeletionNativePath(FileName)); finally Stream.Free; end;
end;

function CompressionQueueRoot(const Options:TBookCompressionOperationOptions):string;
var ID:TGUID;
begin
  Result:=TPath.Combine(Options.WorkRoot,'jobs');
  if Options.QueueName='' then Exit; // Existing isolated native callers.
  try ID:=StringToGUID(Options.QueueName);
  except on E:EConvertError do
    raise EArgumentException.Create('Некорректный идентификатор профиля сжатия.'); end;
  if GUIDToString(ID)<>Options.QueueName then
    raise EArgumentException.Create('Некорректный идентификатор профиля сжатия.');
  Result:=Result+'-'+Options.QueueName;
end;

function IsPreparationName(const Name:string):Boolean;
var ID:TGUID;
begin
  Result:=False;
  if not Name.StartsWith('prepare-') then Exit;
  try ID:=StringToGUID(Copy(Name,9,MaxInt)); except on E:EConvertError do Exit; end;
  Result:=Name='prepare-'+GUIDToString(ID);
end;

function PreparationJobName(const Folder:string):string;
begin
  if not IsPreparationName(ExtractFileName(Folder)) then
    raise EReadError.Create('Некорректная папка подготовки сжатия.');
  Result:='compress-'+Copy(ExtractFileName(Folder),9,MaxInt);
end;

function PreparationDirectoryKey(Handle:THandle):string;
var Info:TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  Result:=Format('%.8x:%.8x%.8x',[Info.dwVolumeSerialNumber,Info.nFileIndexHigh,Info.nFileIndexLow]);
end;

function GuardPreparationDirectory(const Folder:string):THandle;
var Info:TByHandleFileInformation; Actual:string; Count:DWORD; Path:TArray<Char>;
begin
  Result:=CreateFile(PChar(DeletionNativePath(Folder)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Result=INVALID_HANDLE_VALUE then begin Result:=0; RaiseLastOSError; end;
  try
    if not GetFileInformationByHandle(Result,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
      (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) then
      raise EReadError.Create('Рабочая папка сжатия заменена ссылкой или файлом.');
    SetLength(Path,32768);
    Count:=GetFinalPathNameByHandle(Result,@Path[0],Length(Path),0);
    if (Count=0) or (Count>=DWORD(Length(Path))) then RaiseLastOSError;
    SetString(Actual,PChar(@Path[0]),Count);
    if not SameFileName(Actual,DeletionNativePath(Folder)) then
      raise EReadError.Create('Рабочая папка сжатия проходит через ссылку.');
  except CloseHandle(Result); Result:=0; raise; end;
end;

function CheckPreparationMarker(Lease,Guard:THandle; const Folder,QueueName:string;
  AllowLegacy:Boolean):Boolean;
var Info:TByHandleFileInformation; Bytes:TBytes; Count:DWORD; Marker:string; Value:TJSONValue;
begin
  Result:=False;
  if not GetFileInformationByHandle(Lease,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or (Info.nFileSizeHigh<>0) or
    (Info.nFileSizeLow=0) or (Info.nFileSizeLow>4096) or
    (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
    raise EReadError.Create('Некорректная метка рабочей папки сжатия.');
  SetLength(Bytes,Info.nFileSizeLow);
  if not ReadFile(Lease,Bytes[0],Length(Bytes),Count,nil) then RaiseLastOSError;
  if Count<>DWORD(Length(Bytes)) then raise EReadError.Create('Метка рабочей папки прочитана не полностью.');
  Marker:=TEncoding.UTF8.GetString(Bytes);
  if (Marker<>'') and (Marker[1]=#$FEFF) then Delete(Marker,1,1);
  if AllowLegacy and (Marker=WorkMarker) then Exit;
  Value:=TJSONObject.ParseJSONValue(Marker);
  try
    if not (Value is TJSONObject) or
      (Value.GetValue<string>('kind','')<>RegisteredWorkKind) or
      (Value.GetValue<Integer>('version',0)<>2) or
      (Value.GetValue<string>('folder','')<>ExtractFileName(Folder)) or
      (Value.GetValue<string>('queue','')<>QueueName) or
      (Value.GetValue<string>('job','')<>PreparationJobName(Folder)) or
      (Value.GetValue<string>('directory_id','')<>PreparationDirectoryKey(Guard)) then
      raise EReadError.Create('Нет проверенной метки этой рабочей папки сжатия.');
    Result:=True;
  finally Value.Free; end;
end;

function PreparationJobPublished(const Options:TBookCompressionOperationOptions; const Folder:string):Boolean;
var Job,Path:string; Attr,Code:DWORD;
begin
  Job:=TPath.Combine(CompressionQueueRoot(Options),PreparationJobName(Folder));
  Result:=False;
  for var Name in ['job.json','file','completed.json'] do
  begin
    Path:=DeletionNativePath(TPath.Combine(Job,Name)); Attr:=GetFileAttributes(PChar(Path));
    if Attr<>INVALID_FILE_ATTRIBUTES then Exit(True);
    Code:=GetLastError;
    if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
  end;
end;

function RegisteredPreparations(const Options:TBookCompressionOperationOptions):TArray<string>;
var Search:TSearchRec; Folder,Base:string; Guard,Lease:THandle; Items:TList<string>;
begin
  Result:=nil;
  if (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) then Exit;
  Base:=ExcludeTrailingPathDelimiter(ExpandFileName(Options.WorkRoot));
  if not DirectoryExists(DeletionNativePath(Base)) then Exit;
  Items:=TList<string>.Create;
  try
    if FindFirst(DeletionNativePath(TPath.Combine(Base,'prepare-*')),faDirectory,Search)<>0 then Exit;
    try
      repeat
        if (Search.Attr and faDirectory=0) or not IsPreparationName(Search.Name) then Continue;
        Folder:=TPath.Combine(Base,Search.Name); Guard:=0; Lease:=0;
        try
          try
            Guard:=GuardPreparationDirectory(Folder);
            Lease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(Folder,'owner.txt'))),GENERIC_READ,
              0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
            if Lease=INVALID_HANDLE_VALUE then begin Lease:=0; Continue; end;
            if CheckPreparationMarker(Lease,Guard,Folder,Options.QueueName,False) and
              not PreparationJobPublished(Options,Folder) then Items.Add(Folder);
          except
            // A name or old marker alone never authorizes abandoned cleanup.
            // Busy, foreign, copied or damaged preparations stay untouched.
            on E:Exception do Continue;
          end;
        finally if Lease<>0 then CloseHandle(Lease); if Guard<>0 then CloseHandle(Guard); end;
        if Items.Count>=1024 then Break;
      until FindNext(Search)<>0;
    finally System.SysUtils.FindClose(Search); end;
    Result:=Items.ToArray;
  finally Items.Free; end;
end;

function CompressionHasAbandonedPreparation(const Options:TBookCompressionOperationOptions):Boolean;
begin Result:=Length(RegisteredPreparations(Options))>0; end;

constructor TBookCompressionOperation.Create(const Options:TBookCompressionOperationOptions;
  const Factory:TCompressionPlanFactory);
begin
  inherited Create(True); FreeOnTerminate:=False; Priority:=tpLower;
  FLock:=TObject.Create; FReviewEvent:=TEvent.Create(nil,True,False,'');
  FCompleted:=TObjectList<TBookCompressionJob>.Create(True);
  FOptions:=Options; FFactory:=Factory;
  if (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) then
    raise EArgumentException.Create('Нужна папка для временных файлов сжатия.');
  FOptions.WorkRoot:=ExcludeTrailingPathDelimiter(ExpandFileName(Options.WorkRoot));
  CompressionQueueRoot(FOptions);
  if Options.BackupOriginals and
    ((Options.BackupFolder='') or not TPath.IsPathRooted(Options.BackupFolder) or
      not DirectoryExists(DeletionNativePath(Options.BackupFolder))) then
    raise EArgumentException.Create('Выберите существующую папку для оригиналов книг.');
  FState.SavingsKnown:=True;
end;

constructor TBookCompressionOperation.Recover(const Options:TBookCompressionOperationOptions);
var RecoveryOptions:TBookCompressionOperationOptions;
begin
  // Recovery uses the original job's durable backup reference. A later
  // preference for new backups must not prevent finishing an old file job.
  RecoveryOptions:=Options; RecoveryOptions.BackupOriginals:=False;
  Create(RecoveryOptions,nil); FRecovery:=True;
  FState.Recovery:=True; FState.SavingsKnown:=False;
end;

destructor TBookCompressionOperation.Destroy;
begin
  // Let TThread finish while its worker state and callbacks are still alive.
  // Never forget a durable job merely because its window/owner is released.
  if Assigned(FLock) and Assigned(FReviewEvent) and not Finished then RequestStop;
  inherited;
  ReleaseWorkHandles;
  FTrialFiles.Free; FCompleted.Free; FReviewEvent.Free; FLock.Free;
end;

function TBookCompressionOperation.QueueRoot:string;
begin Result:=CompressionQueueRoot(FOptions); end;

function TBookCompressionOperation.Stopping:Boolean;
begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end;

procedure TBookCompressionOperation.CheckStop;
begin if Stopping then raise EAbort.Create('Сжатие остановлено.'); end;

procedure TBookCompressionOperation.RequestStop;
begin
  TInterlocked.Exchange(FStop,1);
  TMonitor.Enter(FLock);
  try FState.Stopping:=True; finally TMonitor.Exit(FLock); end;
  FReviewEvent.SetEvent;
end;

function TBookCompressionOperation.Status:TBookCompressionOperationStatus;
begin
  TMonitor.Enter(FLock);
  try Result:=FState; finally TMonitor.Exit(FLock); end;
end;

procedure TBookCompressionOperation.SetStage(const Stage:string; Current,Total:Int64);
begin
  TMonitor.Enter(FLock);
  try FState.Stage:=Stage; FState.Current:=Current; FState.Total:=Total;
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookCompressionOperation.Warn(const MessageText:string);
begin
  TMonitor.Enter(FLock);
  try
    if Length(FState.Warning)<4096 then
      FState.Warning:=Copy(FState.Warning+sLineBreak+MessageText,1,4096).Trim;
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookCompressionOperation.ReceiveEvent(const Value:string);
var Data:TJSONObject; Stage:string;
begin
  Data:=TJSONObject.ParseJSONValue(Value) as TJSONObject;
  if Data=nil then raise EReadError.Create('Некорректный ответ обработчика сжатия.');
  try
    Stage:=Data.GetValue<string>('stage','');
    {$IFDEF MHL_COMPRESSION_TEST}
    var Observer:=CompressionOperationTestStage;
    if Assigned(Observer) then Observer(Stage);
    {$ENDIF}
    if Stage='error' then FLastError:=Copy(Data.GetValue<string>('message',''),1,2048);
    if (Stage='error') or (Stage='cancelled') or (Stage='ready') then Exit;
    TMonitor.Enter(FLock);
    try
      FState.Stage:=Copy(Stage,1,512);
      FState.Member:=Copy(Data.GetValue<string>('member',''),1,512);
      FState.Current:=Data.GetValue<Int64>('current',0);
      FState.Total:=Data.GetValue<Int64>('total',0);
      FState.WorkingBytes:=Data.GetValue<Int64>('working_bytes',FState.WorkingBytes);
    finally TMonitor.Exit(FLock); end;
  finally Data.Free; end;
end;

function TBookCompressionOperation.CancelProducer:Boolean;
begin
  Result:=False;
  if not Stopping then Exit;
  if FCancelStarted=0 then
  begin FCancelStarted:=GetTickCount64; SaveText(FCancelFile,'cancel'); end;
  Result:=GetTickCount64-FCancelStarted>=3000;
end;

procedure TBookCompressionOperation.OpenWorkGuard;
begin
  if FWorkGuard<>0 then Exit;
  FWorkGuard:=GuardPreparationDirectory(FWork);
end;

procedure TBookCompressionOperation.OpenWorkLease;
begin
  if FWorkLease<>0 then Exit;
  // An active worker owns the marker exclusively. Recovery cannot clean a
  // second live preparation even when its result bytes happen to match.
  FWorkLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FWork,'owner.txt'))),
    GENERIC_READ,0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FWorkLease=INVALID_HANDLE_VALUE then begin FWorkLease:=0; RaiseLastOSError; end;
  try FWorkRegistered:=CheckPreparationMarker(FWorkLease,FWorkGuard,FWork,FOptions.QueueName,True);
  except CloseHandle(FWorkLease); FWorkLease:=0; raise; end;
end;

procedure TBookCompressionOperation.ReleaseWorkHandles;
begin
  if FWorkLease<>0 then begin CloseHandle(FWorkLease); FWorkLease:=0; end;
  if FWorkGuard<>0 then begin CloseHandle(FWorkGuard); FWorkGuard:=0; end;
end;

procedure TBookCompressionOperation.CreateWork;
var Marker:TJSONObject;
begin
  ForceDirectories(DeletionNativePath(FOptions.WorkRoot));
  FWork:=TPath.Combine(FOptions.WorkRoot,'prepare-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(DeletionNativePath(FWork)),nil) then RaiseLastOSError;
  OpenWorkGuard;
  Marker:=TJSONObject.Create;
  try
    Marker.AddPair('kind',RegisteredWorkKind); Marker.AddPair('version',TJSONNumber.Create(2));
    Marker.AddPair('folder',ExtractFileName(FWork)); Marker.AddPair('queue',FOptions.QueueName);
    Marker.AddPair('job',PreparationJobName(FWork));
    Marker.AddPair('directory_id',PreparationDirectoryKey(FWorkGuard));
    SaveText(TPath.Combine(FWork,'owner.txt'),Marker.ToJSON);
  finally Marker.Free; end;
  OpenWorkLease;
  if not CreateDirectory(PChar(DeletionNativePath(TPath.Combine(FWork,'payload'))),nil) then RaiseLastOSError;
  FCancelFile:=TPath.Combine(FWork,'cancel.marker'); FCancelStarted:=0; FLastError:='';
end;

function IsPreparationScratch(const Name:string):Boolean;
var Prefix:string;
begin
  Result:=False; Prefix:='';
  if Name.StartsWith('.selected-') then Prefix:='.selected-'
  else if Name.StartsWith('.estimate-') then Prefix:='.estimate-';
  if (Prefix='') or (Length(Name)<>Length(Prefix)+8) then Exit;
  for var I:=Length(Prefix)+1 to Length(Name) do
    if not CharInSet(Name[I],['a'..'z','0'..'9','_']) then Exit;
  Result:=True;
end;

function IsPreparationPartial(const Name:string):Boolean;
const Prefix='.homelib-data-';
var Token,Ext:string; ID:TGUID;
begin
  Result:=False; Ext:=ExtractFileExt(Name);
  if Name.StartsWith(Prefix) and ((Ext='.tmp') or (Ext='.bak')) then
  begin
    Token:=Copy(Name,Length(Prefix)+1,Length(Name)-Length(Prefix)-Length(Ext));
    try ID:=StringToGUID(Token); except on E:EConvertError do Exit; end;
    Exit(Token=GUIDToString(ID));
  end;
  if (Length(Name)<>52) or not Name.StartsWith('report.json.') or not Name.EndsWith('.partial') then Exit;
  for var I:=13 to 44 do if not CharInSet(Name[I],['a'..'f','0'..'9']) then Exit;
  Result:=True;
end;

procedure WalkPreparationScratch(const Folder:string; Remove:Boolean; Depth:Integer; var Count:Integer);
var Guard,FileHandle:THandle; Info:TByHandleFileInformation; Attr:DWORD; Entries:TArray<string>;
begin
  if Depth>64 then raise EReadError.Create('Слишком глубокая рабочая папка сжатия. Она сохранена.');
  Guard:=GuardPreparationDirectory(Folder);
  try
    Entries:=TDirectory.GetFileSystemEntries(DeletionNativePath(Folder));
    for var Path in Entries do
    begin
      Inc(Count);
      if Count>1000000 then raise EReadError.Create('Слишком много временных файлов. Рабочая папка сохранена.');
      Attr:=GetFileAttributes(PChar(Path));
      if (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
        raise EReadError.Create('Во временных файлах появилась ссылка. Рабочая папка сохранена.');
      if Attr and FILE_ATTRIBUTE_DIRECTORY<>0 then WalkPreparationScratch(Path,Remove,Depth+1,Count)
      else
      begin
        FileHandle:=CreateFile(PChar(Path),FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE,
          nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
        if FileHandle=INVALID_HANDLE_VALUE then RaiseLastOSError;
        try
          if not GetFileInformationByHandle(FileHandle,Info) then RaiseLastOSError;
          if (Info.nNumberOfLinks<>1) or
            (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
            raise EReadError.Create('Тип временного файла изменился. Рабочая папка сохранена.');
        finally CloseHandle(FileHandle); end;
        if Remove and not Winapi.Windows.DeleteFile(PChar(Path)) then RaiseLastOSError;
      end;
    end;
  finally CloseHandle(Guard); end;
  if Remove and not RemoveDirectory(PChar(DeletionNativePath(Folder))) then RaiseLastOSError;
end;

procedure TBookCompressionOperation.CleanWork;
var Allowed,Partials:TArray<string>; Name, Payload:string; Attr:DWORD; ScratchEntries:Integer;
  procedure RemoveFile(const Path:string);
  begin
    if FileExists(DeletionNativePath(Path)) and
      not Winapi.Windows.DeleteFile(PChar(DeletionNativePath(Path))) then RaiseLastOSError;
  end;
begin
  if FWork='' then Exit;
  try
    OpenWorkGuard; OpenWorkLease;
    Allowed:=TArray<string>.Create('owner.txt','request.json','report.json','restored-request.json',
      'restored-report.json','cancel.marker','payload','external-images'); Partials:=nil;
    for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(FWork)) do
    begin
      Name:=ExtractFileName(Path);
      if not MatchText(Name,Allowed) then
        if FWorkRegistered and IsPreparationPartial(Name) then Partials:=Partials+[Path]
        else raise EReadError.Create('В рабочей папке появился посторонний файл.');
      Attr:=GetFileAttributes(PChar(Path));
      if (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
        raise EReadError.Create('Рабочий файл заменён ссылкой.');
      if ((Attr and FILE_ATTRIBUTE_DIRECTORY)<>0)<>MatchText(Name,['payload','external-images']) then
        raise EReadError.Create('Тип рабочего файла изменился.');
    end;
    Payload:=TPath.Combine(FWork,'payload');
    if DirectoryExists(DeletionNativePath(Payload)) then
    begin
      ScratchEntries:=0;
      for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Payload)) do
      begin
        Name:=ExtractFileName(Path);
        Attr:=GetFileAttributes(PChar(Path));
        if FWorkRegistered and (IsPreparationScratch(Name) or (Name='full-books')) and (Attr<>INVALID_FILE_ATTRIBUTES) and
          (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)=FILE_ATTRIBUTE_DIRECTORY) then
        begin WalkPreparationScratch(Path,False,0,ScratchEntries); Continue; end;
        if not MatchText(Name,['prepared-book.bin','prepared-archive.bin','original-books.zip','comparison.zip']) or
          (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
          raise EReadError.Create('Незавершённые рабочие файлы сохранены для проверки.');
      end;
      for Name in ['prepared-book.bin','prepared-archive.bin','original-books.zip','comparison.zip'] do RemoveFile(TPath.Combine(Payload,Name));
      ScratchEntries:=0;
      if FWorkRegistered then
        for var Path in TDirectory.GetDirectories(DeletionNativePath(Payload)) do
        begin
          if not (IsPreparationScratch(ExtractFileName(Path)) or (ExtractFileName(Path)='full-books')) then
            raise EReadError.Create('В рабочей папке появились посторонние данные. Они сохранены.');
          WalkPreparationScratch(Path,True,0,ScratchEntries);
        end;
      if not RemoveDirectory(PChar(DeletionNativePath(Payload))) then RaiseLastOSError;
    end;
    var Images:=TPath.Combine(FWork,'external-images');
    if DirectoryExists(DeletionNativePath(Images)) then
    begin
      ScratchEntries:=0;
      for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Images)) do
      begin
        Name:=ExtractFileName(Path); Attr:=GetFileAttributes(PChar(Path));
        if (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
          raise EReadError.Create('Рабочие изображения заменены ссылкой.');
        if ((Attr and FILE_ATTRIBUTE_DIRECTORY)<>0) then
        begin
          if not Name.StartsWith('.external-images-') then raise EReadError.Create('Посторонние рабочие изображения сохранены.');
          WalkPreparationScratch(Path,False,0,ScratchEntries);
        end
        else if not MatchText(Name,['prepared-covers.bin','prepared-images.bin']) then
          raise EReadError.Create('Посторонний файл среди подготовленных изображений.');
      end;
      for Name in ['prepared-covers.bin','prepared-images.bin'] do RemoveFile(TPath.Combine(Images,Name));
      ScratchEntries:=0;
      for var Path in TDirectory.GetDirectories(DeletionNativePath(Images)) do
        WalkPreparationScratch(Path,True,0,ScratchEntries);
      if not RemoveDirectory(PChar(DeletionNativePath(Images))) then RaiseLastOSError;
    end;
    for Name in ['request.json','report.json','restored-request.json','restored-report.json','cancel.marker'] do RemoveFile(TPath.Combine(FWork,Name));
    for var Path in Partials do RemoveFile(Path);
    CloseHandle(FWorkLease); FWorkLease:=0;
    RemoveFile(TPath.Combine(FWork,'owner.txt'));
    CloseHandle(FWorkGuard); FWorkGuard:=0;
    if not RemoveDirectory(PChar(DeletionNativePath(FWork))) then RaiseLastOSError;
  except on E:Exception do Warn(E.Message+sLineBreak+'Рабочая папка: '+FWork); end;
  ReleaseWorkHandles;
  FWork:=''; FCancelFile:=''; FWorkRegistered:=False;
end;

procedure TBookCompressionOperation.CleanRecoveredWork(const Candidate:string);
var Payload, Folder, Name:string; ID:TGUID;
begin
  // Only the completed job's exact native preparation is eligible. Never
  // scan prefixes or infer ownership of arbitrary producer output folders.
  if not MatchText(ExtractFileName(Candidate),['prepared-book.bin','prepared-archive.bin','prepared-covers.bin','prepared-images.bin']) then Exit;
  Payload:=ExtractFileDir(Candidate);
  if not MatchText(ExtractFileName(Payload),['payload','external-images']) then Exit;
  Folder:=ExtractFileDir(Payload); Name:=ExtractFileName(Folder);
  if not SameFileName(ExtractFileDir(Folder),FOptions.WorkRoot) or not Name.StartsWith('prepare-') then Exit;
  try ID:=StringToGUID(Copy(Name,9,MaxInt)); except on E:EConvertError do Exit; end;
  if Name<>'prepare-'+GUIDToString(ID) then Exit;
  if not DirectoryExists(DeletionNativePath(Folder)) then Exit;
  if FWork<>'' then raise EInvalidOperation.Create('Рабочая папка сжатия ещё используется.');
  FWork:=Folder;
  CleanWork;
end;

procedure TBookCompressionOperation.CleanAbandonedWork;
var JobDirectory,Folder:string;
begin
  for Folder in RegisteredPreparations(FOptions) do
  begin
    CheckStop;
    if FWork<>'' then raise EInvalidOperation.Create('Рабочая папка сжатия ещё используется.');
    FWork:=Folder; FWorkRegistered:=False;
    try
      try
        OpenWorkGuard; OpenWorkLease;
        if not FWorkRegistered or PreparationJobPublished(FOptions,Folder) then Continue;
        JobDirectory:=TPath.Combine(QueueRoot,PreparationJobName(Folder));
        if DirectoryExists(DeletionNativePath(JobDirectory)) and
          not TBookCompressionJob.DiscardUnpublished(JobDirectory) then
          raise EReadError.Create('Незавершённое задание содержит неизвестные файлы. Подготовка сохранена.');
        SetStage('Убираем незавершённую подготовку сжатия');
        CleanWork;
        if not DirectoryExists(DeletionNativePath(Folder)) then
        begin
          TMonitor.Enter(FLock);
          try Inc(FState.DiscardedPreparations); finally TMonitor.Exit(FLock); end;
        end;
      except on E:Exception do Warn(E.Message+sLineBreak+'Рабочая папка: '+Folder); end;
    finally
      ReleaseWorkHandles; FWork:=''; FCancelFile:=''; FWorkRegistered:=False;
    end;
  end;
end;

procedure TBookCompressionOperation.Approve(Decision:TCompressionReview);
begin
  if Decision=crNone then Exit;
  TMonitor.Enter(FLock);
  try
    if not FState.AwaitingReview or ((Decision=crTrial) and
      (not FState.AwaitingEstimate or FState.TrialReady)) then Exit;
    TInterlocked.CompareExchange(FDecision,Ord(Decision),Ord(crNone));
  finally TMonitor.Exit(FLock); end;
  FReviewEvent.SetEvent;
end;

function TBookCompressionOperation.Review(Estimate:Boolean):TCompressionReview;
var Decision:Integer;
begin
  Result:=crApply;
  if not Estimate and (not FOptions.ReviewResults or FReviewRemaining) then Exit;
  TInterlocked.Exchange(FDecision,Ord(crNone)); FReviewEvent.ResetEvent;
  TMonitor.Enter(FLock);
  try
    FState.AwaitingReview:=True; FState.AwaitingEstimate:=Estimate;
    if Estimate and FState.TrialReady then FState.Stage:='Пробная упаковка завершена. Книги ещё не изменены.'
    else if Estimate then FState.Stage:='Предварительная оценка готова. Книги ещё не изменены.'
    else FState.Stage:='Сжатая копия готова к проверке. Исходник ещё не изменён.';
  finally TMonitor.Exit(FLock); end;
  try
    repeat
      CheckStop;
      Decision:=TInterlocked.CompareExchange(FDecision,0,0);
      if Decision<>Ord(crNone) then Break;
      FReviewEvent.WaitFor(50);
    until False;
    Result:=TCompressionReview(Decision);
    if not Estimate then FReviewRemaining:=Decision=Ord(crApplyRemaining);
  finally
    TMonitor.Enter(FLock);
    try FState.AwaitingReview:=False; FState.AwaitingEstimate:=False;
    finally TMonitor.Exit(FLock); end;
  end;
end;

procedure TBookCompressionOperation.EstimateFile(FilePlan:TCompressionFilePlan);
var Request,Report:TJSONObject; Output:TCompressionEventStream;
    Script,ReportFile:string; Input,KnownInput,KnownOutput,Unknown,ArchiveSize:Int64;
begin
  CheckStop;
  try
    CreateWork;
    TMonitor.Enter(FLock);
    try FState.Source:=FilePlan.Source; FState.Member:='';
    finally TMonitor.Exit(FLock); end;
    ReportFile:=TPath.Combine(FWork,'report.json');
    Request:=FilePlan.CreateRequest(TPath.Combine(FWork,'payload'),ReportFile,
      FOptions.SevenZip,FOptions.ToolsRoot,FOptions.Profile,FOptions.Grayscale);
    try SaveText(TPath.Combine(FWork,'request.json'),Request.ToJSON);
    finally Request.Free; end;
    // The module namespace uses '/' in paths; ExtractFileDir on Windows
    // does not reliably treat those as separators. ToolsRoot is canonical.
    Script:=TPath.Combine(FOptions.ToolsRoot,'bookconvert\estimate_book_compression.py');
    Output:=TCompressionEventStream.Create(Self);
    try
      try
        RunExternalToolToStream(FOptions.Python,
          ['-I','-B','-X','utf8',Script,'--job',TPath.Combine(FWork,'request.json'),'--cancel',FCancelFile],
          Output,CancelProducer,0,True,NativeUInt(512)*1024*1024);
      except on E:EMHLExternalToolError do
        begin CheckStop; if FLastError<>'' then raise EReadError.Create(FLastError); raise; end;
      end;
    finally Output.Free; end;
    CheckStop; FilePlan.CheckSource;
    Report:=ReadObject(ReportFile);
    try
      Input:=Report.GetValue<Int64>('input_bytes'); KnownInput:=Report.GetValue<Int64>('known_input_bytes');
      KnownOutput:=Report.GetValue<Int64>('known_output_bytes'); Unknown:=Report.GetValue<Int64>('unknown_books');
      ArchiveSize:=Report.GetValue<Int64>('archive_bytes');
      if (Report.GetValue<Integer>('schema',0)<>1) or
        (Report.GetValue<string>('size_basis','')<>'selected-book-payloads') or
        not SameFileName(Report.GetValue<string>('source',''),FilePlan.Source) or
        (Input<0) or (KnownInput<0) or (KnownInput>Input) or (KnownOutput<0) or (KnownOutput>KnownInput) or
        (Unknown<0) or (Unknown>FilePlan.MemberCount) or
        not (Report.GetValue('books') is TJSONArray) or
        (Report.GetValue<TJSONArray>('books').Count<>FilePlan.MemberCount) or
        (ArchiveSize<>TFile.GetSize(DeletionNativePath(FilePlan.Source))) then
        raise EReadError.Create('Отчёт оценки не соответствует выбранным книгам.');
      TMonitor.Enter(FLock);
      try
        Inc(FState.EstimateInputBytes,Input); Inc(FState.EstimateKnownInputBytes,KnownInput);
        Inc(FState.EstimateOutputBytes,KnownOutput); Inc(FState.EstimateUnknownBooks,Unknown);
        Inc(FState.EstimateArchiveBytes,ArchiveSize);
        Inc(FState.FilesDone); Inc(FState.BooksDone,FilePlan.MemberCount);
      finally TMonitor.Exit(FLock); end;
    finally Report.Free; end;
  finally CleanWork; end;
end;

function TBookCompressionOperation.EngineFingerprint: string;
var Hash: THashSHA2;
  procedure Add(const Tag, FileName: string);
  var Digest: string;
  begin
    CheckStop; Digest:='missing';
    if FileExists(FileName) then Digest:=THashSHA2.GetHashStringFromFile(FileName);
    Hash.Update(TEncoding.UTF8.GetBytes(Tag+#0+Digest+#10));
  end;
begin
  if FEngineSHA256<>'' then Exit(FEngineSHA256);
  Hash:=THashSHA2.Create;
  Add('worker',FOptions.Script); Add('archive-engine',FOptions.SevenZip);
  for var Name in ['convert_book.py','pack_collection.py','image_quality.py','image_input.py','external_image_preparation.py',
    'restored_book_validation.py','nested_epub_compression.py','container_image_quality.py','MODULAR_RUNTIME.json'] do
    Add('bookconvert/'+Name,TPath.Combine(FOptions.ToolsRoot,'bookconvert/'+Name));
  Add('image-engine',TPath.Combine(FOptions.ToolsRoot,'images/HomeLibImages.exe'));
  Add('image-config',TPath.Combine(FOptions.ToolsRoot,'images/HomeLibImages.exe.config'));
  Add('jpeg-xl-decoder',TPath.Combine(FOptions.ToolsRoot,'jpeg-xl/djxl.exe'));
  Add('webp-decoder',TPath.Combine(FOptions.ToolsRoot,'webp/libwebp.dll'));
  for var Folder in ['images','pdfium','djvu','jpeg-xl','jpegxl','webp','kindle'] do
    for var Name in ['RUNTIME.json','COMPONENT.json','MODULAR_RUNTIME.json'] do
      Add(Folder+'/'+Name,TPath.Combine(FOptions.ToolsRoot,Folder+'/'+Name));
  FEngineSHA256:=Hash.HashAsString; Result:=FEngineSHA256;
end;

function TBookCompressionOperation.ValidateRestored(JobRequest:TJSONObject):TJSONObject;
  var Events:TCompressionEventStream; Name:string;
  begin
    Name:=TPath.Combine(FWork,'restored-report.json');
    JobRequest.AddPair('report',Name);
    SaveText(TPath.Combine(FWork,'restored-request.json'),JobRequest.ToJSON);
    Events:=TCompressionEventStream.Create(Self);
    try
      try
        RunExternalToolToStream(FOptions.Python,
          ['-I','-B','-X','utf8',TPath.Combine(FOptions.ToolsRoot,'bookconvert\restored_book_validation.py'),
           '--job',TPath.Combine(FWork,'restored-request.json'),'--cancel',FCancelFile],
          Events,CancelProducer,0,True,NativeUInt(512)*1024*1024);
      except on E:EMHLExternalToolError do
        begin CheckStop; if FLastError<>'' then raise EReadError.Create(FLastError); raise; end;
      end;
    finally Events.Free; end;
    CheckStop; Result:=ReadObject(Name);
  end;

procedure TBookCompressionOperation.MeasureTrialFiles(FilePlan:TCompressionFilePlan; Images:TJSONArray;
  Report:TJSONObject);
var Related:TJSONArray; Saved:Int64; Candidate:string;
  procedure CountFile(const Path,Identity,Prepared:string);
  var Item,Prior:TTrialFile;
  begin
    CheckStop;
    if (Identity='') or (ArchiveDeletionSourceIdentity(Path)<>Identity) then
      raise EReadError.Create('Во время пробной упаковки изменился файл: '+Path);
    Item.InputBytes:=TFile.GetSize(DeletionNativePath(Path));
    Item.OutputBytes:=Item.InputBytes; Item.Shared:=False;
    if Prepared<>'' then Item.OutputBytes:=TFile.GetSize(DeletionNativePath(Prepared));
    if (Item.OutputBytes<=0) or (Item.OutputBytes>Item.InputBytes) then
      raise EReadError.Create('Некорректный размер файла пробной упаковки.');
    Inc(Saved,Item.InputBytes-Item.OutputBytes);
    // One physical side archive may be used by several sources. Independent
    // trials on its original contents cannot predict a sequence of changes.
    var Key:=Copy(Identity,1,25);
    TMonitor.Enter(FLock);
    try
      if FTrialFiles.TryGetValue(Key,Prior) then
      begin
        if (Prior.InputBytes<>Item.InputBytes) then
          raise EReadError.Create('Размер общего файла изменился во время расчёта.');
        if not Prior.Shared and ((Prior.InputBytes<>Prior.OutputBytes) or (Prepared<>'')) then
        begin
          Dec(FState.TrialInputBytes,Prior.InputBytes); Dec(FState.TrialOutputBytes,Prior.OutputBytes);
          Prior.Shared:=True; FTrialFiles[Key]:=Prior; Inc(FState.TrialSharedFiles);
        end;
      end
      else
      begin
        FTrialFiles.Add(Key,Item);
        Inc(FState.TrialInputBytes,Item.InputBytes); Inc(FState.TrialOutputBytes,Item.OutputBytes);
      end;
    finally TMonitor.Exit(FLock); end;
  end;
begin
  Saved:=0; Related:=nil; Candidate:='';
  if Report<>nil then
  begin
    if Report.GetValue('candidate') is TJSONString then
    begin
      Candidate:=Report.GetValue<string>('candidate');
      if not SameFileName(ExtractFileDir(Candidate),TPath.Combine(FWork,'payload')) or
        not MatchText(ExtractFileName(Candidate),['prepared-book.bin','prepared-archive.bin']) then
        raise EReadError.Create('Некорректный файл пробной упаковки.');
    end;
    var Receipt:=Report.GetValue<TJSONObject>('receipt',nil);
    if Receipt<>nil then Related:=Receipt.GetValue<TJSONArray>('group_files',nil);
  end;
  CountFile(FilePlan.Source,FilePlan.SourceIdentity,Candidate);
  for var Image in Images do
  begin
    var Path:=Image.GetValue<string>('path','');
    if Path='' then Continue;
    Candidate:='';
    if Related<>nil then
      for var Ref in Related do
        if SameFileName(Ref.GetValue<string>('source'),Path) then Candidate:=Ref.GetValue<string>('candidate');
    CountFile(Path,Image.GetValue<string>('source_identity'),Candidate);
  end;
  if (Report<>nil) and (Saved<>Report.GetValue<Int64>('input_bytes')-Report.GetValue<Int64>('output_bytes')) then
    raise EReadError.Create('Размер пробной упаковки не совпал с проверенными файлами.');
end;

procedure TBookCompressionOperation.RunFile(FilePlan:TCompressionFilePlan; Trial:Boolean);
var Request, Report, Receipt, Expected:TJSONObject; Output:TCompressionEventStream;
    Job:TBookCompressionJob; Candidate, ReportFile:string; KeepWork:Boolean;
    InputBytes, OutputBytes:Int64;
    Backup:TCompressionOriginalBackup; BackupJSON:string; Fault:TProc<string>;
    CapturedImages:TJSONArray;
  procedure BindReceipt;
  var Choice:TJSONObject;
  begin
    Expected:=TJSONObject.ParseJSONValue(FilePlan.ReceiptTemplate) as TJSONObject;
    try
      for var Pair in Expected do
      begin
        var Captured:=Receipt.GetValue(Pair.JsonString.Value);
        if (Captured=nil) or (Captured.ToJSON<>Pair.JsonValue.ToJSON) then
          raise EReadError.Create('Обработчик изменил привязку выбранной книги. Исходный файл сохранён.');
      end;
    finally Expected.Free; end;
    if Receipt.GetValue('compression_options')<>nil then
      raise EReadError.Create('Обработчик вернул посторонние настройки сжатия.');
    Choice:=TJSONObject.Create;
    Choice.AddPair('version',TJSONNumber.Create(1));
    Choice.AddPair('profile',FOptions.Profile);
    Choice.AddPair('grayscale',TJSONBool.Create(FOptions.Grayscale));
    Choice.AddPair('source_identity',FilePlan.SourceIdentity);
    Choice.AddPair('engine_sha256',EngineFingerprint);
    Receipt.AddPair('compression_options',Choice);
  end;
  procedure WarnIncompleteBooks;
  var Count: Integer; Details, Name, Reason: string;
  begin
    if not (Report.GetValue('books') is TJSONArray) then Exit;
    Count:=0; Details:='';
    for var Value in Report.GetValue<TJSONArray>('books') do
      if (Value is TJSONObject) and not Value.GetValue<Boolean>('checked',True) then
      begin
        Inc(Count);
        if Count>8 then Continue;
        Name:=Value.GetValue<string>('member','');
        if Name='' then Name:=ExtractFileName(FilePlan.Source);
        Reason:=Value.GetValue<string>('reason','Обработка не завершена.');
        Details:=Details+sLineBreak+Copy(Name,1,160)+': '+Copy(Reason,1,240);
      end;
    if Count>0 then
    begin
      if Count>8 then Details:=Details+sLineBreak+'Ещё книг: '+IntToStr(Count-8)+'.';
      Warn('Не удалось обработать иллюстрации в '+IntToStr(Count)+
        ' книгах. Их содержимое сохранено. Повторите сжатие после устранения причины.'+Details);
    end;
  end;
begin
  CheckStop; Job:=nil; Backup:=nil; KeepWork:=False; CapturedImages:=nil;
  TMonitor.Enter(FLock);
  try
    FState.Source:=FilePlan.Source; FState.Member:='';
    FState.InputBytes:=0; FState.OutputBytes:=0; FState.WorkingBytes:=0;
    FState.PreviewFile:=''; FState.PreviewSHA256:=''; FState.ImageChanges:=0;
  finally TMonitor.Exit(FLock); end;
  try
    SetStage('Проверяем ранее обработанный файл');
    if FilePlan.AlreadyChecked(FOptions.Profile,FOptions.Grayscale,EngineFingerprint,Stopping,
      procedure(Done,Total:Int64) begin SetStage('Проверяем ранее обработанный файл',Done,Total); end) then
    begin
      SetStage('Уже проверено с этими настройками. Файл не изменился.');
      if Trial then
      begin
        CapturedImages:=CaptureCompressionImageSources(FilePlan.Source);
        MeasureTrialFiles(FilePlan,CapturedImages,nil);
      end
      else begin
        TMonitor.Enter(FLock);
        try Inc(FState.UnchangedFiles); finally TMonitor.Exit(FLock); end;
      end;
      Exit;
    end;
    CreateWork;
    CapturedImages:=CaptureCompressionImageSources(FilePlan.Source);
    ReportFile:=TPath.Combine(FWork,'report.json');
    Request:=FilePlan.CreateRequest(TPath.Combine(FWork,'payload'),ReportFile,
      FOptions.SevenZip,FOptions.ToolsRoot,FOptions.Profile,FOptions.Grayscale);
    try
      Request.AddPair('backup_originals',TJSONBool.Create(not Trial and FOptions.BackupOriginals));
      Request.AddPair('preview_images',TJSONBool.Create(not Trial and FOptions.ReviewResults and not FReviewRemaining));
      Request.AddPair('external_images',TJSONBool.Create(True));
      Request.AddPair('jpeg_xl_decoder',FindExternalTool('djxl.exe','jpeg-xl'));
      SaveText(TPath.Combine(FWork,'request.json'),Request.ToJSON);
    finally Request.Free; end;
    Output:=TCompressionEventStream.Create(Self);
    try
      try
        RunExternalToolToStream(FOptions.Python,
          ['-I','-B','-X','utf8',FOptions.Script,'--job',TPath.Combine(FWork,'request.json'),'--cancel',FCancelFile],
          Output,CancelProducer,0,True,NativeUInt(512)*1024*1024);
      except on E:EMHLExternalToolError do
        begin CheckStop; if FLastError<>'' then raise EReadError.Create(FLastError); raise; end;
      end;
    finally Output.Free; end;
    CheckStop; FilePlan.CheckSource;
    Report:=ReadObject(ReportFile);
    try
      InputBytes:=Report.GetValue<Int64>('input_bytes'); OutputBytes:=Report.GetValue<Int64>('output_bytes');
      if not SameFileName(Report.GetValue<string>('source'),FilePlan.Source) or
        (InputBytes<=0) or (OutputBytes<=0) or (OutputBytes>InputBytes) then
        raise EReadError.Create('Отчёт не соответствует исходному файлу сжатия.');
      CompleteExternalCompressionReport(FilePlan.Source,FilePlan.SourceIdentity,TPath.Combine(FWork,'payload'),
        CapturedImages,Report,not Trial and FOptions.BackupOriginals,not Trial and FOptions.ReviewResults and not FReviewRemaining,
        function(JobRequest:TJSONObject):TJSONObject begin Result:=ValidateRestored(JobRequest); end,
        Stopping,procedure(Done,Total:Int64) begin SetStage('Проверяем полные книги с иллюстрациями',Done,Total); end);
      InputBytes:=Report.GetValue<Int64>('input_bytes'); OutputBytes:=Report.GetValue<Int64>('output_bytes');
      TMonitor.Enter(FLock);
      try
        FState.InputBytes:=InputBytes; FState.OutputBytes:=OutputBytes;
        FState.WorkingBytes:=Report.GetValue<Int64>('working_bytes',FState.WorkingBytes);
        FState.ReportFile:=ReportFile;
        if Report.GetValue('books') is TJSONArray then
          for var Book in Report.GetValue<TJSONArray>('books') do
            if Book.GetValue<Boolean>('optimized',False) then Inc(FState.ImageChanges);
        if Report.GetValue('preview') is TJSONObject then
        begin
          var Preview:=Report.GetValue<TJSONObject>('preview');
          var PreviewPath:=Preview.GetValue<string>('path','');
          if not SameFileName(PreviewPath,TPath.Combine(TPath.Combine(FWork,'payload'),'comparison.zip')) then
            raise EReadError.Create('Некорректный путь сравнения изображений.');
          FState.PreviewFile:=PreviewPath;
          FState.PreviewSHA256:=Preview.GetValue<string>('sha256','');
        end;
      finally TMonitor.Exit(FLock); end;
      WarnIncompleteBooks;
      if Trial then
      begin
        MeasureTrialFiles(FilePlan,CapturedImages,Report);
        Exit; // CleanWork discards the candidate before the next physical file.
      end;
      Candidate:='';
      if Report.GetValue('candidate') is TJSONString then Candidate:=Report.GetValue<string>('candidate');
      if (Candidate='') and (Report.GetValue<TJSONObject>('receipt',nil)=nil) then
      begin
        if OutputBytes<>InputBytes then
          raise EReadError.Create('В отчёте указан выигрыш, но нет подготовленного файла.');
        Receipt:=Report.GetValue<TJSONObject>('inspection_receipt'); BindReceipt;
        SetStage('Запоминаем проверенные книги');
        var Inspection:=TBookCompressionReceipt.Create(Receipt.ToJSON);
        try Inspection.RecordInspection(Stopping); finally Inspection.Free; end;
        TMonitor.Enter(FLock);
        try Inc(FState.UnchangedFiles); finally TMonitor.Exit(FLock); end;
        Exit;
      end;
      if ((Candidate<>'') and (not SameFileName(ExtractFileDir(Candidate),TPath.Combine(FWork,'payload')) or
        not MatchText(ExtractFileName(Candidate),['prepared-book.bin','prepared-archive.bin']))) or
        (OutputBytes>=InputBytes) then raise EReadError.Create('Неверный путь подготовленного файла сжатия.');
      Receipt:=Report.GetValue<TJSONObject>('receipt');
      BindReceipt;
      if Review=crSkip then
      begin
        TMonitor.Enter(FLock);
        try Inc(FState.SkippedFiles); finally TMonitor.Exit(FLock); end;
        Exit;
      end;
      CheckStop;
      BackupJSON:='';
      if FOptions.BackupOriginals then
      begin
        SetStage('Сохраняем выбранные оригиналы перед заменой');
        if not (Report.GetValue('originals') is TJSONObject) then
          raise EReadError.Create('Обработчик не подготовил оригиналы. Книги не изменены.');
        Backup:=TCompressionOriginalBackup.Publish(Report.GetValue('originals').ToJSON,
          Receipt.ToJSON,TPath.Combine(FWork,'payload'),FOptions.BackupFolder,Stopping);
        BackupJSON:=Backup.ReferenceJSON;
        TMonitor.Enter(FLock);
        try
          Inc(FState.BackupFiles); FState.BackupFolder:=FOptions.BackupFolder;
        finally TMonitor.Exit(FLock); end;
      end;
      CheckStop;
      // Publication can have succeeded even if a subsequent constructor
      // check fails. Keep its candidate for recovery, never remove it here.
      KeepWork:=True;
      Fault:=nil;
{$IFDEF MHL_COMPRESSION_TEST}
      Fault:=CompressionOperationTestFault;
{$ENDIF}
      Job:=TBookCompressionJob.CreatePrepared(QueueRoot,Receipt.ToJSON,Candidate,Fault,BackupJSON,PreparationJobName(FWork));
      TMonitor.Enter(FLock);
      try FState.PendingJob:=Job.Directory; finally TMonitor.Exit(FLock); end;
      Job.Execute(Stopping,
        procedure(const Stage:string; Done,Total:Int64) begin SetStage(Stage,Done,Total); end,Fault);
      KeepWork:=False;
      FCompleted.Add(Job); Job:=nil;
      TMonitor.Enter(FLock);
      try
        FState.PendingJob:=''; Inc(FState.ChangedFiles);
        Inc(FState.SavedBytes,InputBytes-OutputBytes);
      finally TMonitor.Exit(FLock); end;
    finally Report.Free; end;
  finally
    Job.Free; Backup.Free; CapturedImages.Free;
    if KeepWork then
    begin
      ReleaseWorkHandles;
      Warn('Журнал и подготовленные файлы сохранены для продолжения: '+FWork);
      FWork:=''; FCancelFile:='';
    end
    else CleanWork;
  end;
end;

procedure TBookCompressionOperation.RunRecovery;
var Job:TBookCompressionJob;
begin
  var Pending:=TBookCompressionJob.Pending(QueueRoot);
  TMonitor.Enter(FLock);
  try FState.FilesTotal:=Length(Pending); finally TMonitor.Exit(FLock); end;
  for var Directory in Pending do
  begin
    CheckStop; Job:=TBookCompressionJob.OpenExisting(Directory);
    try
      TMonitor.Enter(FLock);
      try FState.Source:=Job.Source; FState.PendingJob:=Directory;
      finally TMonitor.Exit(FLock); end;
      Job.Execute(Stopping,
        procedure(const Stage:string; Done,Total:Int64) begin SetStage(Stage,Done,Total); end);
      CleanRecoveredWork(Job.PreparedCandidate);
      FCompleted.Add(Job); Job:=nil;
      TMonitor.Enter(FLock);
      try FState.PendingJob:=''; Inc(FState.FilesDone); Inc(FState.ChangedFiles);
      finally TMonitor.Exit(FLock); end;
    finally Job.Free; end;
  end;
  CleanAbandonedWork;
end;

procedure TBookCompressionOperation.Execute;
var Plan:TBookCompressionPlan; ApplyCompression,NoNew:Boolean;
  procedure ProcessFiles(Trial:Boolean);
  begin
    TMonitor.Enter(FLock);
    try FState.FilesDone:=0; FState.BooksDone:=0; finally TMonitor.Exit(FLock); end;
    Plan.ForEachFile(
      procedure(FilePlan:TCompressionFilePlan)
      begin
        RunFile(FilePlan,Trial);
        TMonitor.Enter(FLock);
        try Inc(FState.FilesDone); Inc(FState.BooksDone,FilePlan.MemberCount);
        finally TMonitor.Exit(FLock); end;
      end);
  end;
begin
  NoNew:=False;
  try
    if FRecovery then RunRecovery
    else
    begin
      if Length(TBookCompressionJob.Pending(QueueRoot))>0 then
        raise EInvalidOperation.Create('Сначала нужно завершить прежнее сжатие из сохранённого журнала.');
      CheckStop;
      CleanAbandonedWork;
      if not Assigned(FFactory) then raise EArgumentException.Create('Не задан выбор книг для сжатия.');
      SetStage('Проверяем расположение книг');
      Plan:=FFactory(Stopping,
        procedure(Done:Int64) begin SetStage('Проверяем расположение книг',Done,0); end);
      try
        if Plan=nil then raise EReadError.Create('Не удалось подготовить выбор книг для сжатия.');
        if FOptions.OnlyNew then
        begin
          SetStage('Находим новые и изменившиеся книги');
          Plan.SelectUnprocessed(FOptions.Profile,FOptions.Grayscale,EngineFingerprint,
            procedure(Done,Total:Int64) begin SetStage('Находим новые и изменившиеся книги',Done,Total); end);
        end;
        TMonitor.Enter(FLock);
        try
          FState.FilesTotal:=Plan.FileCount;
          FState.BooksTotal:=Plan.BookCount;
          FState.PreviouslyProcessedBooks:=Plan.PreviouslyProcessedBooks;
        finally TMonitor.Exit(FLock); end;
        if Plan.Warning<>'' then Warn(Plan.Warning);
        if FState.FilesTotal=0 then
          if FOptions.OnlyNew and (FState.PreviouslyProcessedBooks>0) then NoNew:=True
          else raise EReadError.Create('В коллекции не найдены доступные местные файлы книг. Проверьте папки её источников.');
        ApplyCompression:=not NoNew;
        if FOptions.EstimateFirst and ApplyCompression then
        begin
          TMonitor.Enter(FLock);
          try FState.Estimating:=True; finally TMonitor.Exit(FLock); end;
          Plan.ForEachFile(procedure(FilePlan:TCompressionFilePlan) begin EstimateFile(FilePlan); end);
          TMonitor.Enter(FLock);
          try FState.Estimating:=False; FState.Source:=''; FState.Member:='';
          finally TMonitor.Exit(FLock); end;
          var Decision:=Review(True);
          if Decision=crTrial then
          begin
            FTrialFiles:=TDictionary<string,TTrialFile>.Create;
            TMonitor.Enter(FLock);
            try FState.TrialRunning:=True; finally TMonitor.Exit(FLock); end;
            try ProcessFiles(True); finally FreeAndNil(FTrialFiles); end;
            TMonitor.Enter(FLock);
            try
              FState.TrialRunning:=False; FState.TrialReady:=True; FState.WorkingBytes:=0;
              FState.Source:=''; FState.Member:=''; FState.ReportFile:='';
            finally TMonitor.Exit(FLock); end;
            Decision:=Review(True);
          end;
          ApplyCompression:=Decision=crApply;
          if not ApplyCompression then
          begin
            TMonitor.Enter(FLock);
            try FState.EstimateOnly:=True; finally TMonitor.Exit(FLock); end;
            SetStage('Оценка завершена. Книги не изменены.');
          end;
        end;
        if ApplyCompression then ProcessFiles(False);
      finally Plan.Free; end;
    end;
    if NoNew then SetStage('Новых книг для сжатия не найдено. Полная проверка — «Сжать текущую коллекцию».')
    else if FRecovery and (FState.FilesDone=0) and (FState.DiscardedPreparations>0) then
      SetStage('Незавершённая подготовка очищена. Книги не изменены.')
    else if not FState.EstimateOnly then SetStage('Сжатие завершено');
  except
    on E:EAbort do
      if FState.TrialRunning then SetStage('Пробная упаковка остановлена. Книги не изменены.')
      else SetStage('Сжатие остановлено. Выполненные изменения сохранены.');
    on E:Exception do
    begin
      TMonitor.Enter(FLock);
      try FState.Error:=E.Message;
        if FState.TrialRunning then FState.Stage:='Не удалось закончить пробную упаковку. Книги не изменены.'
        else FState.Stage:='Не удалось завершить сжатие.';
      finally TMonitor.Exit(FLock); end;
    end;
  end;
  TMonitor.Enter(FLock);
  try FState.Finished:=True; FState.Stopping:=Stopping; FState.AwaitingReview:=False;
    FState.AwaitingEstimate:=False; FState.Estimating:=False;
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookCompressionOperation.AcknowledgeCompletedJobs;
begin
  if not Finished then raise EInvalidOperation.Create('Сжатие ещё выполняется.');
  for var I:=FCompleted.Count-1 downto 0 do
    try
      FCompleted[I].Forget; FCompleted.Delete(I);
    except on E:Exception do Warn('Не удалось убрать завершённый журнал: '+E.Message); end;
end;

end.
