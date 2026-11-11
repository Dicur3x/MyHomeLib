unit unit_BookCompressionOperation;

interface

uses System.Classes, System.SysUtils, System.SyncObjs, System.Generics.Collections,
  unit_BookCompressionPlan, unit_BookCompressionJob;

type
  TCompressionReview = (crNone, crApply, crApplyRemaining, crSkip);
  TCompressionPlanFactory = reference to function(const Cancelled:TFunc<Boolean>;
    const Progress:TProc<Int64>):TBookCompressionPlan;
  TBookCompressionOperationOptions = record
    WorkRoot, Python, Script, SevenZip, ToolsRoot, Profile: string;
    Grayscale, ReviewResults: Boolean;
  end;
  TBookCompressionOperationStatus = record
    Stage, Source, Member, Error, Warning, ReportFile, PendingJob: string;
    Current, Total, FilesDone, FilesTotal, BooksDone, BooksTotal: Int64;
    ChangedFiles, UnchangedFiles, SkippedFiles, SavedBytes: Int64;
    InputBytes, OutputBytes, WorkingBytes: Int64;
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
    FWork, FCancelFile, FLastError: string;
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
    function Review: Boolean;
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

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.StrUtils, unit_AtomicIniFile,
  unit_MHLExternalTools, unit_ZipMemberDeletion;

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
      FLine:=FLine+AnsiChar(Bytes[I]);
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
  FState.SavingsKnown:=True;
end;

constructor TBookCompressionOperation.Recover(const Options:TBookCompressionOperationOptions);
begin
  Create(Options,nil); FRecovery:=True;
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
begin Result:=TPath.Combine(FOptions.WorkRoot,'jobs'); end;

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
      if not MatchText(Name,['prepared-book.bin','prepared-archive.bin']) or
        (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
        raise EReadError.Create('Незавершённые рабочие файлы сохранены для проверки.');
    end;
    for Name in ['prepared-book.bin','prepared-archive.bin'] do RemoveFile(TPath.Combine(Payload,Name));
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

function TBookCompressionOperation.Review:Boolean;
var Decision:Integer;
begin
  Result:=True;
  if not FOptions.ReviewResults or FReviewRemaining then Exit;
  TInterlocked.Exchange(FDecision,Ord(crNone)); FReviewEvent.ResetEvent;
  TMonitor.Enter(FLock);
  try FState.AwaitingReview:=True; FState.Stage:='Сжатая копия готова к проверке. Исходник ещё не изменён.';
  finally TMonitor.Exit(FLock); end;
  try
    repeat
      CheckStop;
      Decision:=TInterlocked.CompareExchange(FDecision,0,0);
      if Decision<>Ord(crNone) then Break;
      FReviewEvent.WaitFor(50);
    until False;
    Result:=Decision<>Ord(crSkip);
    FReviewRemaining:=Decision=Ord(crApplyRemaining);
  finally
    TMonitor.Enter(FLock);
    try FState.AwaitingReview:=False; finally TMonitor.Exit(FLock); end;
  end;
end;

procedure TBookCompressionOperation.RunFile(FilePlan:TCompressionFilePlan);
var Request, Report, Receipt, Expected:TJSONObject; Output:TCompressionEventStream;
    Job:TBookCompressionJob; Candidate, ReportFile:string; KeepWork:Boolean;
    InputBytes, OutputBytes:Int64;
begin
  CheckStop; Job:=nil; KeepWork:=False;
  TMonitor.Enter(FLock);
  try
    FState.Source:=FilePlan.Source; FState.Member:='';
    FState.InputBytes:=0; FState.OutputBytes:=0; FState.WorkingBytes:=0;
  finally TMonitor.Exit(FLock); end;
  try
    CreateWork;
    ReportFile:=TPath.Combine(FWork,'report.json');
    Request:=FilePlan.CreateRequest(TPath.Combine(FWork,'payload'),ReportFile,
      FOptions.SevenZip,FOptions.ToolsRoot,FOptions.Profile,FOptions.Grayscale);
    try SaveText(TPath.Combine(FWork,'request.json'),Request.ToJSON); finally Request.Free; end;
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
      finally TMonitor.Exit(FLock); end;
      Candidate:='';
      if Report.GetValue('candidate') is TJSONString then Candidate:=Report.GetValue<string>('candidate');
      if Candidate='' then
      begin
        if OutputBytes<>InputBytes then
          raise EReadError.Create('В отчёте указан выигрыш, но нет подготовленного файла.');
        TMonitor.Enter(FLock);
        try Inc(FState.UnchangedFiles); finally TMonitor.Exit(FLock); end;
        Exit;
      end;
      if not SameFileName(ExtractFileDir(Candidate),TPath.Combine(FWork,'payload')) or
        not MatchText(ExtractFileName(Candidate),['prepared-book.bin','prepared-archive.bin']) or
        (OutputBytes>=InputBytes) then raise EReadError.Create('Неверный путь подготовленного файла сжатия.');
      Receipt:=Report.GetValue<TJSONObject>('receipt');
      Expected:=TJSONObject.ParseJSONValue(FilePlan.ReceiptTemplate) as TJSONObject;
      try
        for var Pair in Expected do
        begin
          var Captured:=Receipt.GetValue(Pair.JsonString.Value);
          if (Captured=nil) or (Captured.ToJSON<>Pair.JsonValue.ToJSON) then
            raise EReadError.Create('Обработчик изменил привязку выбранной книги. Исходный файл сохранён.');
        end;
      finally Expected.Free; end;
      if not Review then
      begin
        TMonitor.Enter(FLock);
        try Inc(FState.SkippedFiles); finally TMonitor.Exit(FLock); end;
        Exit;
      end;
      CheckStop;
      // Publication can have succeeded even if a subsequent constructor
      // check fails. Keep its candidate for recovery, never remove it here.
      KeepWork:=True;
      Job:=TBookCompressionJob.CreatePrepared(QueueRoot,Receipt.ToJSON,Candidate);
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
    Job.Free;
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
var Plan:TBookCompressionPlan;
begin
  try
    if FRecovery then RunRecovery
    else
    begin
      if Length(TBookCompressionJob.Pending(QueueRoot))>0 then
        raise EInvalidOperation.Create('Сначала нужно завершить прежнее сжатие из сохранённого журнала.');
      CheckStop;
      if not Assigned(FFactory) then raise EArgumentException.Create('Не задан выбор книг для сжатия.');
      SetStage('Проверяем расположение выбранных книг');
      Plan:=FFactory(Stopping,
        procedure(Done:Int64) begin SetStage('Проверяем расположение выбранных книг',Done,0); end);
      try
        if Plan=nil then raise EReadError.Create('Не удалось подготовить выбор книг для сжатия.');
        TMonitor.Enter(FLock);
        try
          FState.FilesTotal:=Plan.Files.Count;
          for var FilePlan in Plan.Files do Inc(FState.BooksTotal,FilePlan.MemberCount);
        finally TMonitor.Exit(FLock); end;
        for var FilePlan in Plan.Files do
        begin
          RunFile(FilePlan);
          TMonitor.Enter(FLock);
          try Inc(FState.FilesDone); Inc(FState.BooksDone,FilePlan.MemberCount);
          finally TMonitor.Exit(FLock); end;
        end;
      finally Plan.Free; end;
    end;
    SetStage('Сжатие завершено');
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
