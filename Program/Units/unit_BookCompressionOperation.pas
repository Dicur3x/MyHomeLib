unit unit_BookCompressionOperation;

interface

uses System.Classes, System.SysUtils, System.SyncObjs, System.Generics.Collections,
  unit_BookCompressionPlan, unit_BookCompressionJob;

type
  TCompressionReview = (crNone, crApply, crApplyRemaining, crSkip);
  TCompressionPlanFactory = reference to function(const Cancelled:TFunc<Boolean>;
    const Progress:TProc<Int64>):TBookCompressionPlan;
  TBookCompressionOperationOptions = record
    WorkRoot, QueueName, Python, Script, SevenZip, ToolsRoot, Profile, BackupFolder: string;
    Grayscale, ReviewResults, BackupOriginals, EstimateFirst: Boolean;
  end;
  TBookCompressionOperationStatus = record
    Stage, Source, Member, Error, Warning, ReportFile, PendingJob, BackupFolder: string;
    PreviewFile, PreviewSHA256: string;
    Current, Total, FilesDone, FilesTotal, BooksDone, BooksTotal: Int64;
    ChangedFiles, UnchangedFiles, SkippedFiles, SavedBytes: Int64;
    InputBytes, OutputBytes, WorkingBytes: Int64;
    BackupFiles: Int64;
    ImageChanges: Int64;
    EstimateInputBytes, EstimateKnownInputBytes, EstimateOutputBytes, EstimateArchiveBytes: Int64;
    EstimateUnknownBooks: Int64;
    Estimating, AwaitingEstimate, EstimateOnly: Boolean;
    Finished, Stopping, AwaitingReview, Recovery, SavingsKnown: Boolean;
  end;

  // The factory runs on this worker and owns its own SQLite connections.
  // Completed durable jobs stay leased until the application refreshes its
  // catalogue/caches and explicitly acknowledges them on the finished thread.
  TBookCompressionOperation = class(TThread)
  private
    FOptions: TBookCompressionOperationOptions;
    FFactory: TCompressionPlanFactory;
    FLock: TObject;
    FReviewEvent: TEvent;
    FStop, FDecision: Integer;
    FReviewRemaining, FRecovery: Boolean;
    FState: TBookCompressionOperationStatus;
    FCompleted: TObjectList<TBookCompressionJob>;
    FWork, FCancelFile, FLastError, FEngineSHA256: string;
    FCancelStarted: UInt64;
    FWorkGuard: THandle;
    function Stopping: Boolean;
    procedure CheckStop;
    procedure SetStage(const Stage: string; Current: Int64 = 0; Total: Int64 = 0);
    procedure Warn(const MessageText: string);
    procedure ReceiveEvent(const Value: string);
    function CancelProducer: Boolean;
    procedure CreateWork;
    procedure CleanWork;
    function EngineFingerprint: string;
    function Review(Estimate: Boolean = False): Boolean;
    procedure EstimateFile(FilePlan: TCompressionFilePlan);
    procedure RunFile(FilePlan: TCompressionFilePlan);
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

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.StrUtils, System.Hash, unit_AtomicIniFile,
  unit_MHLExternalTools, unit_ZipMemberDeletion, unit_BookCompressionBackup, unit_BookCompressionReceipt;

const WorkMarker='HomeLibre selected compression work v1';

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
  if FWorkGuard<>0 then CloseHandle(FWorkGuard);
  FCompleted.Free; FReviewEvent.Free; FLock.Free;
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

procedure TBookCompressionOperation.CreateWork;
var Actual:string; Count:DWORD; Path:TArray<Char>;
begin
  ForceDirectories(DeletionNativePath(FOptions.WorkRoot));
  FWork:=TPath.Combine(FOptions.WorkRoot,'prepare-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(DeletionNativePath(FWork)),nil) then RaiseLastOSError;
  FWorkGuard:=CreateFile(PChar(DeletionNativePath(FWork)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FWorkGuard=INVALID_HANDLE_VALUE then begin FWorkGuard:=0; RaiseLastOSError; end;
  SetLength(Path,32768);
  Count:=GetFinalPathNameByHandle(FWorkGuard,@Path[0],Length(Path),0);
  if (Count=0) or (Count>=DWORD(Length(Path))) then RaiseLastOSError;
  SetString(Actual,PChar(@Path[0]),Count);
  if not SameFileName(Actual,DeletionNativePath(FWork)) then
    raise EReadError.Create('Рабочая папка сжатия проходит через ссылку.');
  SaveText(TPath.Combine(FWork,'owner.txt'),WorkMarker);
  if not CreateDirectory(PChar(DeletionNativePath(TPath.Combine(FWork,'payload'))),nil) then RaiseLastOSError;
  FCancelFile:=TPath.Combine(FWork,'cancel.marker'); FCancelStarted:=0; FLastError:='';
end;

procedure TBookCompressionOperation.CleanWork;
var Allowed:TArray<string>; Name, Payload:string; Attr:DWORD;
  procedure RemoveFile(const Path:string);
  begin
    if FileExists(DeletionNativePath(Path)) and
      not Winapi.Windows.DeleteFile(PChar(DeletionNativePath(Path))) then RaiseLastOSError;
  end;
begin
  if FWork='' then Exit;
  if FWorkGuard<>0 then begin CloseHandle(FWorkGuard); FWorkGuard:=0; end;
  try
    if TFile.ReadAllText(DeletionNativePath(TPath.Combine(FWork,'owner.txt')),TEncoding.UTF8)<>WorkMarker then
      raise EReadError.Create('Нет метки рабочей папки сжатия.');
    Allowed:=TArray<string>.Create('owner.txt','request.json','report.json','cancel.marker','payload');
    for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(FWork)) do
    begin
      Name:=ExtractFileName(Path);
      if not MatchText(Name,Allowed) then raise EReadError.Create('В рабочей папке появился посторонний файл.');
      Attr:=GetFileAttributes(PChar(Path));
      if (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
        raise EReadError.Create('Рабочий файл заменён ссылкой.');
      if ((Attr and FILE_ATTRIBUTE_DIRECTORY)<>0)<>(Name='payload') then
        raise EReadError.Create('Тип рабочего файла изменился.');
    end;
    Payload:=TPath.Combine(FWork,'payload');
    for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Payload)) do
    begin
      Name:=ExtractFileName(Path);
      Attr:=GetFileAttributes(PChar(Path));
      if not MatchText(Name,['prepared-book.bin','prepared-archive.bin','original-books.zip','comparison.zip']) or
        (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
        raise EReadError.Create('Незавершённые рабочие файлы сохранены для проверки.');
    end;
    for Name in ['prepared-book.bin','prepared-archive.bin','original-books.zip','comparison.zip'] do RemoveFile(TPath.Combine(Payload,Name));
    if not RemoveDirectory(PChar(DeletionNativePath(Payload))) then RaiseLastOSError;
    for Name in ['request.json','report.json','cancel.marker','owner.txt'] do RemoveFile(TPath.Combine(FWork,Name));
    if not RemoveDirectory(PChar(DeletionNativePath(FWork))) then RaiseLastOSError;
  except on E:Exception do Warn(E.Message+sLineBreak+'Рабочая папка: '+FWork); end;
  FWork:=''; FCancelFile:='';
end;

procedure TBookCompressionOperation.Approve(Decision:TCompressionReview);
begin
  if Decision=crNone then Exit;
  TMonitor.Enter(FLock);
  try
    if not FState.AwaitingReview then Exit;
    TInterlocked.CompareExchange(FDecision,Ord(Decision),Ord(crNone));
  finally TMonitor.Exit(FLock); end;
  FReviewEvent.SetEvent;
end;

function TBookCompressionOperation.Review(Estimate:Boolean):Boolean;
var Decision:Integer;
begin
  Result:=True;
  if not Estimate and (not FOptions.ReviewResults or FReviewRemaining) then Exit;
  TInterlocked.Exchange(FDecision,Ord(crNone)); FReviewEvent.ResetEvent;
  TMonitor.Enter(FLock);
  try
    FState.AwaitingReview:=True; FState.AwaitingEstimate:=Estimate;
    if Estimate then FState.Stage:='Предварительная оценка готова. Книги ещё не изменены.'
    else FState.Stage:='Сжатая копия готова к проверке. Исходник ещё не изменён.';
  finally TMonitor.Exit(FLock); end;
  try
    repeat
      CheckStop;
      Decision:=TInterlocked.CompareExchange(FDecision,0,0);
      if Decision<>Ord(crNone) then Break;
      FReviewEvent.WaitFor(50);
    until False;
    Result:=Decision<>Ord(crSkip);
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
  for var Name in ['convert_book.py','pack_collection.py','image_quality.py','MODULAR_RUNTIME.json'] do
    Add('bookconvert/'+Name,TPath.Combine(FOptions.ToolsRoot,'bookconvert/'+Name));
  Add('image-engine',TPath.Combine(FOptions.ToolsRoot,'images/HomeLibImages.exe'));
  Add('image-config',TPath.Combine(FOptions.ToolsRoot,'images/HomeLibImages.exe.config'));
  for var Folder in ['images','pdfium','djvu','jpegxl','kindle'] do
    for var Name in ['RUNTIME.json','COMPONENT.json','MODULAR_RUNTIME.json'] do
      Add(Folder+'/'+Name,TPath.Combine(FOptions.ToolsRoot,Folder+'/'+Name));
  FEngineSHA256:=Hash.HashAsString; Result:=FEngineSHA256;
end;

procedure TBookCompressionOperation.RunFile(FilePlan:TCompressionFilePlan);
var Request, Report, Receipt, Expected:TJSONObject; Output:TCompressionEventStream;
    Job:TBookCompressionJob; Candidate, ReportFile:string; KeepWork:Boolean;
    InputBytes, OutputBytes:Int64;
    Backup:TCompressionOriginalBackup; BackupJSON:string;
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
  CheckStop; Job:=nil; Backup:=nil; KeepWork:=False;
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
      TMonitor.Enter(FLock);
      try Inc(FState.UnchangedFiles); finally TMonitor.Exit(FLock); end;
      Exit;
    end;
    CreateWork;
    ReportFile:=TPath.Combine(FWork,'report.json');
    Request:=FilePlan.CreateRequest(TPath.Combine(FWork,'payload'),ReportFile,
      FOptions.SevenZip,FOptions.ToolsRoot,FOptions.Profile,FOptions.Grayscale);
    try
      Request.AddPair('backup_originals',TJSONBool.Create(FOptions.BackupOriginals));
      Request.AddPair('preview_images',TJSONBool.Create(FOptions.ReviewResults and not FReviewRemaining));
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
      Candidate:='';
      if Report.GetValue('candidate') is TJSONString then Candidate:=Report.GetValue<string>('candidate');
      if Candidate='' then
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
      if not SameFileName(ExtractFileDir(Candidate),TPath.Combine(FWork,'payload')) or
        not MatchText(ExtractFileName(Candidate),['prepared-book.bin','prepared-archive.bin']) or
        (OutputBytes>=InputBytes) then raise EReadError.Create('Неверный путь подготовленного файла сжатия.');
      Receipt:=Report.GetValue<TJSONObject>('receipt');
      BindReceipt;
      if not Review then
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
      Job:=TBookCompressionJob.CreatePrepared(QueueRoot,Receipt.ToJSON,Candidate,nil,BackupJSON);
      TMonitor.Enter(FLock);
      try FState.PendingJob:=Job.Directory; finally TMonitor.Exit(FLock); end;
      Job.Execute(Stopping,
        procedure(const Stage:string; Done,Total:Int64) begin SetStage(Stage,Done,Total); end);
      KeepWork:=False;
      FCompleted.Add(Job); Job:=nil;
      TMonitor.Enter(FLock);
      try
        FState.PendingJob:=''; Inc(FState.ChangedFiles);
        Inc(FState.SavedBytes,InputBytes-OutputBytes);
      finally TMonitor.Exit(FLock); end;
    finally Report.Free; end;
  finally
    Job.Free; Backup.Free;
    if KeepWork then
    begin
      if FWorkGuard<>0 then begin CloseHandle(FWorkGuard); FWorkGuard:=0; end;
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
      FCompleted.Add(Job); Job:=nil;
      TMonitor.Enter(FLock);
      try FState.PendingJob:=''; Inc(FState.FilesDone); Inc(FState.ChangedFiles);
      finally TMonitor.Exit(FLock); end;
    finally Job.Free; end;
  end;
end;

procedure TBookCompressionOperation.Execute;
var Plan:TBookCompressionPlan; ApplyCompression:Boolean;
begin
  try
    if FRecovery then RunRecovery
    else
    begin
      if Length(TBookCompressionJob.Pending(QueueRoot))>0 then
        raise EInvalidOperation.Create('Сначала нужно завершить прежнее сжатие из сохранённого журнала.');
      CheckStop;
      if not Assigned(FFactory) then raise EArgumentException.Create('Не задан выбор книг для сжатия.');
      SetStage('Проверяем расположение книг');
      Plan:=FFactory(Stopping,
        procedure(Done:Int64) begin SetStage('Проверяем расположение книг',Done,0); end);
      try
        if Plan=nil then raise EReadError.Create('Не удалось подготовить выбор книг для сжатия.');
        TMonitor.Enter(FLock);
        try
          FState.FilesTotal:=Plan.FileCount;
          FState.BooksTotal:=Plan.BookCount;
        finally TMonitor.Exit(FLock); end;
        if Plan.Warning<>'' then Warn(Plan.Warning);
        if FState.FilesTotal=0 then
          raise EReadError.Create('В коллекции не найдены доступные местные файлы книг. Проверьте папки её источников.');
        ApplyCompression:=True;
        if FOptions.EstimateFirst then
        begin
          TMonitor.Enter(FLock);
          try FState.Estimating:=True; finally TMonitor.Exit(FLock); end;
          Plan.ForEachFile(procedure(FilePlan:TCompressionFilePlan) begin EstimateFile(FilePlan); end);
          TMonitor.Enter(FLock);
          try FState.Estimating:=False; FState.Source:=''; FState.Member:='';
          finally TMonitor.Exit(FLock); end;
          ApplyCompression:=Review(True);
          TMonitor.Enter(FLock);
          try FState.FilesDone:=0; FState.BooksDone:=0;
          finally TMonitor.Exit(FLock); end;
          if not ApplyCompression then
          begin
            TMonitor.Enter(FLock);
            try FState.EstimateOnly:=True; finally TMonitor.Exit(FLock); end;
            SetStage('Оценка завершена. Книги не изменены.');
          end;
        end;
        if ApplyCompression then
          Plan.ForEachFile(
            procedure(FilePlan:TCompressionFilePlan)
            begin
              RunFile(FilePlan);
              TMonitor.Enter(FLock);
              try Inc(FState.FilesDone); Inc(FState.BooksDone,FilePlan.MemberCount);
              finally TMonitor.Exit(FLock); end;
            end);
      finally Plan.Free; end;
    end;
    if not FState.EstimateOnly then SetStage('Сжатие завершено');
  except
    on E:EAbort do SetStage('Сжатие остановлено. Выполненные изменения сохранены.');
    on E:Exception do
    begin
      TMonitor.Enter(FLock);
      try FState.Error:=E.Message; FState.Stage:='Не удалось завершить сжатие.';
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
